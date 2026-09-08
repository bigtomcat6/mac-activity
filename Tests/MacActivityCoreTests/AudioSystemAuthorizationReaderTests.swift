import Foundation
import XCTest
@testable import MacActivityCore

final class AudioSystemAuthorizationReaderTests: XCTestCase {
    func testDefaultReaderPerformsPassivePreflight() async {
        let status = await AudioSystemAuthorizationReader().authorizationStatus()

        switch status {
        case .authorized, .denied, .notDetermined, .unavailable:
            break
        }
    }

    func testZeroPreflightResultIsAuthorized() async {
        let calls = PreflightCallCounter()
        let reader = supportedReader {
            calls.record()
            return 0
        }

        let status = await reader.authorizationStatus()

        XCTAssertEqual(status, .authorized)
        XCTAssertEqual(calls.count, 1)
    }

    func testOnePreflightResultIsDenied() async {
        let calls = PreflightCallCounter()
        let reader = supportedReader {
            calls.record()
            return 1
        }

        let status = await reader.authorizationStatus()

        XCTAssertEqual(status, .denied)
        XCTAssertEqual(calls.count, 1)
    }

    func testTwoPreflightResultIsNotDetermined() async {
        let calls = PreflightCallCounter()
        let reader = supportedReader {
            calls.record()
            return 2
        }

        let status = await reader.authorizationStatus()

        XCTAssertEqual(status, .notDetermined)
        XCTAssertEqual(calls.count, 1)
    }

    func testNilPreflightResultIsUnavailable() async {
        let calls = PreflightCallCounter()
        let reader = supportedReader {
            calls.record()
            return nil
        }

        let status = await reader.authorizationStatus()

        XCTAssertEqual(status, .unavailable)
        XCTAssertEqual(calls.count, 1)
    }

    func testUnexpectedPreflightResultIsUnavailable() async {
        let calls = PreflightCallCounter()
        let reader = supportedReader {
            calls.record()
            return 99
        }

        let status = await reader.authorizationStatus()

        XCTAssertEqual(status, .unavailable)
        XCTAssertEqual(calls.count, 1)
    }

    func testUnsupportedPlatformDoesNotCallRawPreflight() async {
        let calls = PreflightCallCounter()
        let reader = AudioSystemAuthorizationReader(
            availability: AudioFeatureAvailability(
                operatingSystemVersion: .init(majorVersion: 14, minorVersion: 1, patchVersion: 0)
            ),
            rawPreflight: {
                calls.record()
                return 0
            }
        )

        let status = await reader.authorizationStatus()

        XCTAssertEqual(status, .unavailable)
        XCTAssertEqual(calls.count, 0)
    }

    private func supportedReader(
        rawPreflight: @escaping @Sendable () -> Int?
    ) -> AudioSystemAuthorizationReader {
        AudioSystemAuthorizationReader(
            availability: AudioFeatureAvailability(
                operatingSystemVersion: .init(majorVersion: 14, minorVersion: 2, patchVersion: 0)
            ),
            rawPreflight: rawPreflight
        )
    }
}

private final class PreflightCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }
}
