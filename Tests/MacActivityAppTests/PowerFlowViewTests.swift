import AppKit
import Combine
import SwiftUI
import XCTest
@testable import MacActivityCore
@testable import MacActivityApp

@MainActor
final class PowerFlowViewTests: XCTestCase {
    func testRenderedPowerFlowViewAtRealEnergyWidthStartsVisibleLifecycle() async {
        let provider = PowerFlowViewProviderStub(snapshot: PowerFlowDiagramFixtures.snapshot(
            .init(id: "external", type: .usbC, direction: .input, measurement: .watts(40)),
            .init(id: "battery", type: .battery, direction: .output, measurement: .watts(18)),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(22))
        ))
        let model = PowerFlowModel(
            provider: provider,
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
        let snapshotPublished = expectation(description: "power-flow snapshot published")
        let observation = model.$snapshot.sink { snapshot in
            if snapshot.outputEndpoints.map(\.type) == [.battery, .mac] {
                snapshotPublished.fulfill()
            }
        }
        defer { observation.cancel() }
        let renderer = ImageRenderer(
            content: PowerFlowView(model: model, refreshTrigger: 0)
                .frame(width: 384)
        )
        renderer.scale = 1

        XCTAssertNotNil(renderer.nsImage)
        await fulfillment(of: [snapshotPublished], timeout: 1)
        XCTAssertEqual(provider.snapshotCount, 1)
        XCTAssertEqual(model.snapshot.outputEndpoints.map(\.type), [.battery, .mac])
    }

    func testHiddenPowerFlowViewDoesNotStartARead() async {
        let provider = PowerFlowViewProviderStub(snapshot: PowerFlowDiagramFixtures.snapshot(
            .init(id: "source", type: .usbC, direction: .input, measurement: .watts(20)),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(20))
        ))
        let model = PowerFlowModel(
            provider: provider,
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
        let renderer = ImageRenderer(
            content: PowerFlowView(model: model, refreshTrigger: 0)
                .environment(\.dashboardPresentationIsPresented, false)
                .frame(width: 384)
        )

        XCTAssertNotNil(renderer.nsImage)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(provider.snapshotCount, 0)
    }

    func testPowerFlowViewBuildsWaitingThenMeasuredPresentations() {
        let waiting = PowerFlowView.presentation(
            snapshot: .empty,
            isRefreshing: true,
            bundle: PowerFlowDiagramFixtures.englishBundle
        )
        let measured = PowerFlowView.presentation(
            snapshot: PowerFlowDiagramFixtures.snapshot(
                .init(id: "battery", type: .battery, direction: .input, measurement: .watts(24)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(24))
            ),
            isRefreshing: false,
            bundle: PowerFlowDiagramFixtures.englishBundle
        )

        XCTAssertEqual(waiting.preferredMode, .waiting)
        XCTAssertEqual(measured.preferredMode, .expanded(.oneToOne))
        XCTAssertEqual(measured.status, .batteryPower)
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
