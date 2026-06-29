import XCTest
@testable import MacActivityCore

final class NetworkProviderTests: XCTestCase {
    func testNetworkProviderSamplesCurrentCounters() async throws {
        let provider = NetworkProvider()

        let firstUpdate = await provider.sample()
        let secondUpdate = await provider.sample()

        let firstReading = try XCTUnwrap(Mirror(reflecting: firstUpdate).children.first?.value as? NetworkReading)
        let secondReading = try XCTUnwrap(Mirror(reflecting: secondUpdate).children.first?.value as? NetworkReading)

        XCTAssertEqual(firstReading.downloadBytesPerSecond, 0, accuracy: 0.001)
        XCTAssertEqual(firstReading.uploadBytesPerSecond, 0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(secondReading.downloadBytesPerSecond, 0)
        XCTAssertGreaterThanOrEqual(secondReading.uploadBytesPerSecond, 0)
    }

    func testCounterSampleUsesPreferredInterfaceWithoutSummingVirtualAdapters() {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let sample = NetworkProvider.makeCounterSample(
            from: [
                NetworkInterfaceCounter(
                    name: "en0",
                    isUp: true,
                    isLoopback: false,
                    receivedBytes: 1_000,
                    sentBytes: 9_000
                ),
                NetworkInterfaceCounter(
                    name: "utun4",
                    isUp: true,
                    isLoopback: false,
                    receivedBytes: 9_000,
                    sentBytes: 1_000
                )
            ],
            preferredInterfaceNames: ["en0"],
            timestamp: timestamp
        )

        XCTAssertEqual(
            sample,
            NetworkCounterSample(received: 1_000, sent: 9_000, timestamp: timestamp)
        )
    }

    func testCounterSampleIncludesLocalPhysicalTrafficOutsidePreferredInterface() {
        let timestamp = Date(timeIntervalSince1970: 1_000.5)
        let sample = NetworkProvider.makeCounterSample(
            from: [
                NetworkInterfaceCounter(
                    name: "en0",
                    isUp: true,
                    isLoopback: false,
                    receivedBytes: 1_000,
                    sentBytes: 2_000
                ),
                NetworkInterfaceCounter(
                    name: "en7",
                    isUp: true,
                    isLoopback: false,
                    receivedBytes: 5_000,
                    sentBytes: 7_000
                ),
                NetworkInterfaceCounter(
                    name: "utun4",
                    isUp: true,
                    isLoopback: false,
                    receivedBytes: 20_000,
                    sentBytes: 30_000
                )
            ],
            preferredInterfaceNames: ["en0"],
            timestamp: timestamp
        )

        XCTAssertEqual(
            sample,
            NetworkCounterSample(received: 6_000, sent: 9_000, timestamp: timestamp)
        )
    }

    func testCounterSampleIncludesAppleWirelessDirectLinkTraffic() {
        let timestamp = Date(timeIntervalSince1970: 1_000.75)
        let sample = NetworkProvider.makeCounterSample(
            from: [
                NetworkInterfaceCounter(
                    name: "en0",
                    isUp: true,
                    isLoopback: false,
                    receivedBytes: 1_000,
                    sentBytes: 2_000
                ),
                NetworkInterfaceCounter(
                    name: "awdl0",
                    isUp: true,
                    isLoopback: false,
                    receivedBytes: 7_000,
                    sentBytes: 11_000
                ),
                NetworkInterfaceCounter(
                    name: "utun4",
                    isUp: true,
                    isLoopback: false,
                    receivedBytes: 20_000,
                    sentBytes: 30_000
                )
            ],
            preferredInterfaceNames: ["en0"],
            timestamp: timestamp
        )

        XCTAssertEqual(
            sample,
            NetworkCounterSample(received: 8_000, sent: 13_000, timestamp: timestamp)
        )
    }

    func testCounterSampleFallsBackToPhysicalInterfacesWhenPreferredInterfaceIsUnavailable() {
        let timestamp = Date(timeIntervalSince1970: 1_001)
        let sample = NetworkProvider.makeCounterSample(
            from: [
                NetworkInterfaceCounter(
                    name: "en0",
                    isUp: true,
                    isLoopback: false,
                    receivedBytes: 1_000,
                    sentBytes: 2_000
                ),
                NetworkInterfaceCounter(
                    name: "en1",
                    isUp: true,
                    isLoopback: false,
                    receivedBytes: 3_000,
                    sentBytes: 4_000
                ),
                NetworkInterfaceCounter(
                    name: "utun4",
                    isUp: true,
                    isLoopback: false,
                    receivedBytes: 20_000,
                    sentBytes: 10_000
                )
            ],
            preferredInterfaceNames: ["missing0"],
            timestamp: timestamp
        )

        XCTAssertEqual(
            sample,
            NetworkCounterSample(received: 4_000, sent: 6_000, timestamp: timestamp)
        )
    }

    func testCounterSampleUsesVirtualInterfaceWhenItIsThePreferredPrimaryInterface() {
        let timestamp = Date(timeIntervalSince1970: 1_002)
        let sample = NetworkProvider.makeCounterSample(
            from: [
                NetworkInterfaceCounter(
                    name: "en0",
                    isUp: true,
                    isLoopback: false,
                    receivedBytes: 1_000,
                    sentBytes: 2_000
                ),
                NetworkInterfaceCounter(
                    name: "utun4",
                    isUp: true,
                    isLoopback: false,
                    receivedBytes: 5_000,
                    sentBytes: 7_000
                )
            ],
            preferredInterfaceNames: ["utun4"],
            timestamp: timestamp
        )

        XCTAssertEqual(
            sample,
            NetworkCounterSample(received: 5_000, sent: 7_000, timestamp: timestamp)
        )
    }

    func testCounterSampleIgnoresDownAndLoopbackInterfaces() {
        let timestamp = Date(timeIntervalSince1970: 1_003)
        let sample = NetworkProvider.makeCounterSample(
            from: [
                NetworkInterfaceCounter(
                    name: "lo0",
                    isUp: true,
                    isLoopback: true,
                    receivedBytes: 10_000,
                    sentBytes: 10_000
                ),
                NetworkInterfaceCounter(
                    name: "en0",
                    isUp: false,
                    isLoopback: false,
                    receivedBytes: 20_000,
                    sentBytes: 20_000
                ),
                NetworkInterfaceCounter(
                    name: "en1",
                    isUp: true,
                    isLoopback: false,
                    receivedBytes: 3_000,
                    sentBytes: 4_000
                )
            ],
            preferredInterfaceNames: [],
            timestamp: timestamp
        )

        XCTAssertEqual(
            sample,
            NetworkCounterSample(received: 3_000, sent: 4_000, timestamp: timestamp)
        )
    }

    func testCounterSampleFallsBackToVirtualCountersWhenNoPhysicalInterfacesAreAvailable() {
        let timestamp = Date(timeIntervalSince1970: 1_004)
        let sample = NetworkProvider.makeCounterSample(
            from: [
                NetworkInterfaceCounter(
                    name: "utun4",
                    isUp: true,
                    isLoopback: false,
                    receivedBytes: 3_000,
                    sentBytes: 4_000
                ),
                NetworkInterfaceCounter(
                    name: "bridge100",
                    isUp: true,
                    isLoopback: false,
                    receivedBytes: 5_000,
                    sentBytes: 6_000
                )
            ],
            preferredInterfaceNames: [],
            timestamp: timestamp
        )

        XCTAssertEqual(
            sample,
            NetworkCounterSample(received: 8_000, sent: 10_000, timestamp: timestamp)
        )
    }

    func testVirtualOrAuxiliaryInterfaceClassifierRecognizesCommonMacInterfaces() {
        let virtualNames = [
            "utun0",
            "bridge100",
            "gif0",
            "stf0",
            "anpi0",
            "ap1",
            "vmenet0",
            "vmnet8",
            "tap0",
            "tun0"
        ]

        for name in virtualNames {
            XCTAssertTrue(
                NetworkProvider.isVirtualOrAuxiliaryInterface(name),
                "Expected \(name) to be treated as virtual or auxiliary"
            )
        }

        XCTAssertFalse(NetworkProvider.isVirtualOrAuxiliaryInterface("en0"))
        XCTAssertFalse(NetworkProvider.isVirtualOrAuxiliaryInterface("en10"))
        XCTAssertFalse(NetworkProvider.isVirtualOrAuxiliaryInterface("awdl0"))
        XCTAssertFalse(NetworkProvider.isVirtualOrAuxiliaryInterface("llw0"))
        XCTAssertFalse(NetworkProvider.isVirtualOrAuxiliaryInterface("p2p0"))
    }

    func testByteDeltaClampsCounterResetsToZero() {
        XCTAssertEqual(NetworkProvider.byteDelta(current: 1_500, previous: 1_000), 500)
        XCTAssertEqual(NetworkProvider.byteDelta(current: 500, previous: 1_000), 0)
    }
}
