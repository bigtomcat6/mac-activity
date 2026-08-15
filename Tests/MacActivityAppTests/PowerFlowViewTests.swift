import AppKit
import SwiftUI
import XCTest
@testable import MacActivityCore
@testable import MacActivityApp

@MainActor
final class PowerFlowViewTests: XCTestCase {
    func testRenderedPowerFlowViewAtFourHundredTwentyPointsStartsVisibleLifecycle() async {
        let provider = PowerFlowViewProviderStub(snapshot: PowerFlowSnapshot(endpoints: [
            PowerFlowEndpoint(id: "external", type: .usbC, direction: .input, measurement: .unavailable),
            PowerFlowEndpoint(id: "battery", type: .battery, direction: .output, measurement: .watts(22.1)),
            PowerFlowEndpoint(id: "mac", type: .mac, direction: .output, measurement: .unavailable),
        ]))
        let model = PowerFlowModel(
            provider: provider,
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
        let renderer = ImageRenderer(
            content: PowerFlowView(model: model, refreshTrigger: 0)
                .frame(width: 420, height: 120)
        )
        renderer.scale = 1

        XCTAssertNotNil(renderer.nsImage)
        while provider.snapshotCount == 0 { await Task.yield() }
        XCTAssertEqual(provider.snapshotCount, 1)
        XCTAssertEqual(model.snapshot.outputEndpoints.map(\.type), [.battery, .mac])
    }
}

@MainActor
private final class PowerFlowViewProviderStub: PowerFlowProviding {
    private let response: PowerFlowSnapshot
    private(set) var snapshotCount = 0

    init(snapshot: PowerFlowSnapshot) {
        response = snapshot
    }

    func snapshot() async -> PowerFlowSnapshot {
        snapshotCount += 1
        return response
    }
}
