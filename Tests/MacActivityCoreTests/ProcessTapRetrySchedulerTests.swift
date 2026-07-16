import Dispatch
import XCTest

@testable import MacActivityCore

final class ProcessTapRetrySchedulerTests: XCTestCase {
    func testBackoffStartsAtFiftyMillisecondsAndCapsAtOneSecond() {
        var backoff = ProcessTapRetryBackoff()

        XCTAssertEqual(backoff.nextDelay(), .milliseconds(50))
        XCTAssertEqual(backoff.nextDelay(), .milliseconds(100))
        XCTAssertEqual(backoff.nextDelay(), .milliseconds(200))
        XCTAssertEqual(backoff.nextDelay(), .milliseconds(400))
        XCTAssertEqual(backoff.nextDelay(), .milliseconds(800))
        XCTAssertEqual(backoff.nextDelay(), .milliseconds(1_000))
        XCTAssertEqual(backoff.nextDelay(), .milliseconds(1_000))
    }

    func testBackoffResetsOnProgress() {
        var backoff = ProcessTapRetryBackoff()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()

        backoff.recordProgress()

        XCTAssertEqual(backoff.nextDelay(), .milliseconds(50))
    }

    func testRuntimeRejectionCacheIsExactBoundedAndOldestFirst() {
        var cache = ProcessTapRuntimeRejectionCache(capacity: 2)
        let first = fingerprint(osBuild: "first")
        let second = fingerprint(osBuild: "second")
        let third = fingerprint(osBuild: "third")

        cache.insert(first)
        cache.insert(second)
        cache.insert(first)
        cache.insert(third)

        XCTAssertFalse(cache.contains(first))
        XCTAssertTrue(cache.contains(second))
        XCTAssertTrue(cache.contains(third))
    }

    private func fingerprint(osBuild: String) -> AudioRouteTopologyFingerprint {
        AudioRouteTopologyFingerprint(
            osBuild: osBuild,
            sourceDeviceUIDs: ["source"],
            selectedTargetUIDs: ["target"],
            devices: []
        )
    }
}
