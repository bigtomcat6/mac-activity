import Darwin
import Foundation

public protocol AudioProcessOwnershipLease: AnyObject, Sendable {}

public protocol AudioProcessOwnershipLeaseAcquiring: Sendable {
    func acquire() throws -> any AudioProcessOwnershipLease
}

public enum AudioProcessOwnershipLeaseOperation: String, Equatable, Sendable {
    case createDirectory
    case openDirectory
    case inspectDirectory
    case secureDirectory
    case openLockFile
    case inspectLockFile
    case secureLockFile
    case acquireLock
}

public enum AudioProcessOwnershipLeaseError: Error, Equatable, Sendable {
    case busy
    case insecureObject(operation: AudioProcessOwnershipLeaseOperation)
    case system(operation: AudioProcessOwnershipLeaseOperation, code: Int32)
}

@_silgen_name("flock")
private func audioProcessSystemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

public struct DarwinAudioProcessOwnershipLeaseAcquirer:
    AudioProcessOwnershipLeaseAcquiring,
    @unchecked Sendable {
    private static let directoryName = "com.how.macactivity"
    private static let lockFileName = "audio-process-control.lock"
    private static let maximumInterruptedAttempts = 8

    private let applicationSupportDirectory: URL
    private let lockFunction: (Int32, Int32) -> Int32
    private let didAcquireFileDescriptor: ((Int32) -> Void)?

    public init(applicationSupportDirectory: URL? = nil) {
        self.init(
            applicationSupportDirectory: applicationSupportDirectory ?? Self.defaultDirectory,
            lockFunction: audioProcessSystemFlock,
            didAcquireFileDescriptor: nil
        )
    }

    init(
        applicationSupportDirectory: URL,
        lockFunction: @escaping (Int32, Int32) -> Int32 = audioProcessSystemFlock,
        didAcquireFileDescriptor: ((Int32) -> Void)? = nil
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.lockFunction = lockFunction
        self.didAcquireFileDescriptor = didAcquireFileDescriptor
    }

    public func acquire() throws -> any AudioProcessOwnershipLease {
        let baseDescriptor = Darwin.open(
            applicationSupportDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard baseDescriptor >= 0 else {
            throw systemOrInsecureError(operation: .openDirectory, code: errno)
        }
        defer { Darwin.close(baseDescriptor) }

        if mkdirat(baseDescriptor, Self.directoryName, mode_t(0o700)) != 0,
           errno != EEXIST {
            throw AudioProcessOwnershipLeaseError.system(
                operation: .createDirectory,
                code: errno
            )
        }

        let directoryDescriptor = openat(
            baseDescriptor,
            Self.directoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw systemOrInsecureError(operation: .openDirectory, code: errno)
        }
        defer { Darwin.close(directoryDescriptor) }

        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0 else {
            throw AudioProcessOwnershipLeaseError.system(
                operation: .inspectDirectory,
                code: errno
            )
        }
        guard directoryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryStatus.st_uid == geteuid() else {
            throw AudioProcessOwnershipLeaseError.insecureObject(operation: .inspectDirectory)
        }
        guard fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
            throw AudioProcessOwnershipLeaseError.system(
                operation: .secureDirectory,
                code: errno
            )
        }

        let lockDescriptor = openat(
            directoryDescriptor,
            Self.lockFileName,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard lockDescriptor >= 0 else {
            let code = errno
            if code == EISDIR {
                throw AudioProcessOwnershipLeaseError.insecureObject(
                    operation: .inspectLockFile
                )
            }
            throw systemOrInsecureError(operation: .openLockFile, code: code)
        }
        var shouldCloseLock = true
        defer {
            if shouldCloseLock { Darwin.close(lockDescriptor) }
        }

        var lockStatus = stat()
        guard fstat(lockDescriptor, &lockStatus) == 0 else {
            throw AudioProcessOwnershipLeaseError.system(
                operation: .inspectLockFile,
                code: errno
            )
        }
        guard lockStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              lockStatus.st_uid == geteuid() else {
            throw AudioProcessOwnershipLeaseError.insecureObject(operation: .inspectLockFile)
        }
        guard fchmod(lockDescriptor, mode_t(0o600)) == 0 else {
            throw AudioProcessOwnershipLeaseError.system(
                operation: .secureLockFile,
                code: errno
            )
        }

        try acquireLock(lockDescriptor)
        didAcquireFileDescriptor?(lockDescriptor)
        shouldCloseLock = false
        return DarwinAudioProcessOwnershipLease(descriptor: lockDescriptor)
    }
}

private extension DarwinAudioProcessOwnershipLeaseAcquirer {
    static var defaultDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    func acquireLock(_ descriptor: Int32) throws {
        for attempt in 1...Self.maximumInterruptedAttempts {
            if lockFunction(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                throw AudioProcessOwnershipLeaseError.busy
            }
            if code == EINTR, attempt < Self.maximumInterruptedAttempts {
                continue
            }
            throw AudioProcessOwnershipLeaseError.system(
                operation: .acquireLock,
                code: code
            )
        }
    }

    func systemOrInsecureError(
        operation: AudioProcessOwnershipLeaseOperation,
        code: Int32
    ) -> AudioProcessOwnershipLeaseError {
        if code == ELOOP || code == ENOTDIR {
            return .insecureObject(operation: operation)
        }
        return .system(operation: operation, code: code)
    }
}

private final class DarwinAudioProcessOwnershipLease:
    AudioProcessOwnershipLease,
    @unchecked Sendable {
    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }
}
