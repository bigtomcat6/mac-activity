import Darwin
import Foundation
@testable import MacActivityCore
import XCTest

@_silgen_name("flock")
private func testSystemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

final class AudioProcessOwnershipLeaseTests: XCTestCase {
    func testTwoAcquirersContendOnTheSameRealLock() throws {
        try withTemporaryApplicationSupport { applicationSupport in
            let firstAcquirer = DarwinAudioProcessOwnershipLeaseAcquirer(
                applicationSupportDirectory: applicationSupport
            )
            let secondAcquirer = DarwinAudioProcessOwnershipLeaseAcquirer(
                applicationSupportDirectory: applicationSupport
            )
            let first = try firstAcquirer.acquire()

            XCTAssertThrowsError(try secondAcquirer.acquire()) { error in
                XCTAssertEqual(error as? AudioProcessOwnershipLeaseError, .busy)
            }
            withExtendedLifetime(first) {}
        }
    }

    func testReleasingLastTokenLetsSuccessorAcquire() throws {
        try withTemporaryApplicationSupport { applicationSupport in
            let acquirer = DarwinAudioProcessOwnershipLeaseAcquirer(
                applicationSupportDirectory: applicationSupport
            )
            var first: (any AudioProcessOwnershipLease)? = try acquirer.acquire()
            XCTAssertNotNil(first)

            first = nil
            let successor = try acquirer.acquire()

            withExtendedLifetime(successor) {}
        }
    }

    func testExistingStaleRegularLockFileCanBeAcquired() throws {
        try withTemporaryApplicationSupport { applicationSupport in
            let leaf = applicationSupport.appendingPathComponent("com.how.macactivity")
            try FileManager.default.createDirectory(
                at: leaf,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let lock = leaf.appendingPathComponent("audio-process-control.lock")
            XCTAssertTrue(FileManager.default.createFile(
                atPath: lock.path,
                contents: Data("stale".utf8),
                attributes: [.posixPermissions: 0o600]
            ))

            let lease = try DarwinAudioProcessOwnershipLeaseAcquirer(
                applicationSupportDirectory: applicationSupport
            ).acquire()

            withExtendedLifetime(lease) {}
        }
    }

    func testCreatedDirectoryAndLockFileHavePrivateModesAndCurrentOwner() throws {
        try withTemporaryApplicationSupport { applicationSupport in
            let lease = try DarwinAudioProcessOwnershipLeaseAcquirer(
                applicationSupportDirectory: applicationSupport
            ).acquire()
            let leaf = applicationSupport.appendingPathComponent("com.how.macactivity")
            let lock = leaf.appendingPathComponent("audio-process-control.lock")

            let directoryStatus = try fileStatus(at: leaf)
            let lockStatus = try fileStatus(at: lock)
            XCTAssertEqual(directoryStatus.st_mode & mode_t(0o777), mode_t(0o700))
            XCTAssertEqual(lockStatus.st_mode & mode_t(0o777), mode_t(0o600))
            XCTAssertEqual(directoryStatus.st_uid, geteuid())
            XCTAssertEqual(lockStatus.st_uid, geteuid())
            withExtendedLifetime(lease) {}
        }
    }

    func testHeldLockDescriptorIsCloseOnExec() throws {
        try withTemporaryApplicationSupport { applicationSupport in
            var acquiredDescriptor: Int32?
            let acquirer = DarwinAudioProcessOwnershipLeaseAcquirer(
                applicationSupportDirectory: applicationSupport,
                didAcquireFileDescriptor: { acquiredDescriptor = $0 }
            )

            let lease = try acquirer.acquire()
            let descriptor = try XCTUnwrap(acquiredDescriptor)

            XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
            withExtendedLifetime(lease) {}
        }
    }

    func testSymlinkLeafDirectoryFailsClosed() throws {
        try withTemporaryApplicationSupport { applicationSupport in
            let target = applicationSupport.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let leaf = applicationSupport.appendingPathComponent("com.how.macactivity")
            try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: target)

            assertInsecureObject(
                tryAcquire(in: applicationSupport),
                operation: .openDirectory
            )
        }
    }

    func testSymlinkLockFileFailsClosed() throws {
        try withTemporaryApplicationSupport { applicationSupport in
            let leaf = try createSecureLeaf(in: applicationSupport)
            let target = leaf.appendingPathComponent("target")
            XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data()))
            try FileManager.default.createSymbolicLink(
                at: leaf.appendingPathComponent("audio-process-control.lock"),
                withDestinationURL: target
            )

            assertInsecureObject(
                tryAcquire(in: applicationSupport),
                operation: .openLockFile
            )
        }
    }

    func testFIFOAtLockPathFailsClosed() throws {
        try withTemporaryApplicationSupport { applicationSupport in
            let leaf = try createSecureLeaf(in: applicationSupport)
            let lockPath = leaf.appendingPathComponent("audio-process-control.lock").path
            XCTAssertEqual(mkfifo(lockPath, mode_t(0o600)), 0)

            assertInsecureObject(
                tryAcquire(in: applicationSupport),
                operation: .inspectLockFile
            )
        }
    }

    func testDirectoryAtLockPathFailsClosed() throws {
        try withTemporaryApplicationSupport { applicationSupport in
            let leaf = try createSecureLeaf(in: applicationSupport)
            try FileManager.default.createDirectory(
                at: leaf.appendingPathComponent("audio-process-control.lock"),
                withIntermediateDirectories: false
            )

            assertInsecureObject(
                tryAcquire(in: applicationSupport),
                operation: .inspectLockFile
            )
        }
    }

    func testEINTRRetriesBeforeAcquiringRealLock() throws {
        try withTemporaryApplicationSupport { applicationSupport in
            let attempts = LockedCounter()
            let acquirer = DarwinAudioProcessOwnershipLeaseAcquirer(
                applicationSupportDirectory: applicationSupport,
                lockFunction: { descriptor, operation in
                    let attempt = attempts.increment()
                    if attempt < 3 {
                        errno = EINTR
                        return -1
                    }
                    return testSystemFlock(descriptor, operation)
                }
            )

            let lease = try acquirer.acquire()

            XCTAssertEqual(attempts.value, 3)
            withExtendedLifetime(lease) {}
        }
    }

    func testEINTRRetryIsBoundedAndReturnsTypedFailure() throws {
        try withTemporaryApplicationSupport { applicationSupport in
            let attempts = LockedCounter()
            let acquirer = DarwinAudioProcessOwnershipLeaseAcquirer(
                applicationSupportDirectory: applicationSupport,
                lockFunction: { _, _ in
                    _ = attempts.increment()
                    errno = EINTR
                    return -1
                }
            )

            XCTAssertThrowsError(try acquirer.acquire()) { error in
                XCTAssertEqual(
                    error as? AudioProcessOwnershipLeaseError,
                    .system(operation: .acquireLock, code: EINTR)
                )
            }
            XCTAssertEqual(attempts.value, 8)
        }
    }
}

private extension AudioProcessOwnershipLeaseTests {
    final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int { lock.withLock { storage } }

        @discardableResult
        func increment() -> Int {
            lock.withLock {
                storage += 1
                return storage
            }
        }
    }

    func withTemporaryApplicationSupport(
        _ body: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacActivityLeaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func createSecureLeaf(in applicationSupport: URL) throws -> URL {
        let leaf = applicationSupport.appendingPathComponent("com.how.macactivity")
        try FileManager.default.createDirectory(
            at: leaf,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return leaf
    }

    func fileStatus(at url: URL) throws -> stat {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status
    }

    func tryAcquire(in applicationSupport: URL) -> Error? {
        do {
            _ = try DarwinAudioProcessOwnershipLeaseAcquirer(
                applicationSupportDirectory: applicationSupport
            ).acquire()
            return nil
        } catch {
            return error
        }
    }

    func assertInsecureObject(
        _ error: Error?,
        operation: AudioProcessOwnershipLeaseOperation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            error as? AudioProcessOwnershipLeaseError,
            .insecureObject(operation: operation),
            file: file,
            line: line
        )
    }
}
