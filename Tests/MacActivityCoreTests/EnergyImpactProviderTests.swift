import Darwin
import XCTest
@testable import MacActivityCore

@MainActor
final class EnergyImpactProviderTests: XCTestCase {
    func testServiceForwardsCatalogSnapshotsAndSamplingArguments() async throws {
        let apps = [fixtureApp(processIdentifier: 101, kind: .regular)]
        let catalog = EnergyImpactAppCatalogStub(apps: apps)
        let sampler = EnergyImpactSamplingStub(output: [fixtureEntry()])
        let service = EnergyImpactService(catalog: catalog, sampler: sampler)

        let sessionID = await service.beginSession()
        let sampled = await service.sample(
            sessionID: sessionID,
            limit: 12,
            scope: .regularAndAccessory,
            publicationBoundary: true
        )
        let entries = try XCTUnwrap(sampled)
        await service.endSession(sessionID)
        let snapshot = await sampler.snapshot()

        XCTAssertEqual(entries, [fixtureEntry()])
        XCTAssertEqual(catalog.requestedScopes, [.regularAndAccessory])
        XCTAssertEqual(snapshot.requests, [
            .init(
                sessionID: sessionID,
                apps: apps,
                limit: 12,
                publicationBoundary: true
            ),
        ])
        XCTAssertNil(snapshot.activeSessionID)
    }

    func testServiceRequestsCatalogForEverySample() async {
        let catalog = EnergyImpactAppCatalogStub(apps: [fixtureApp()])
        let sampler = EnergyImpactSamplingStub(output: [])
        let service = EnergyImpactService(catalog: catalog, sampler: sampler)
        let sessionID = await service.beginSession()

        _ = await service.sample(
            sessionID: sessionID,
            limit: 20,
            scope: .regularOnly,
            publicationBoundary: false
        )
        _ = await service.sample(
            sessionID: sessionID,
            limit: 20,
            scope: .regularAndAccessory,
            publicationBoundary: true
        )

        XCTAssertEqual(catalog.requestedScopes, [.regularOnly, .regularAndAccessory])
    }

    func testObsoleteEndCannotClearNewestServiceSession() async {
        let catalog = EnergyImpactAppCatalogStub(apps: [fixtureApp()])
        let sampler = EnergyImpactSamplingStub(output: [fixtureEntry()])
        let service = EnergyImpactService(catalog: catalog, sampler: sampler)
        let oldSessionID = await service.beginSession()
        let currentSessionID = await service.beginSession()

        await service.endSession(oldSessionID)
        let entries = await service.sample(
            sessionID: currentSessionID,
            limit: 20,
            scope: .regularOnly,
            publicationBoundary: false
        )

        XCTAssertEqual(entries, [fixtureEntry()])
        let snapshot = await sampler.snapshot()
        XCTAssertEqual(snapshot.activeSessionID, currentSessionID)
    }

    func testSystemCatalogRefreshesWorkspaceMetadataEveryThreeSeconds() {
        let state = EnergyImpactCatalogTestState()
        let catalog = SystemEnergyImpactAppCatalog(
            snapshotProvider: {
                state.workspaceRequestCount += 1
                return [
                    self.fixtureApp(processIdentifier: 101, kind: .regular),
                    self.fixtureApp(processIdentifier: 102, kind: .accessory),
                ]
            },
            nowSeconds: { state.now },
            refreshIntervalSeconds: 3
        )

        XCTAssertEqual(catalog.snapshots(scope: .regularOnly).map(\.processIdentifier), [101])
        state.now = 1
        XCTAssertEqual(catalog.snapshots(scope: .regularAndAccessory).count, 2)
        state.now = 2
        _ = catalog.snapshots(scope: .regularOnly)
        state.now = 3
        _ = catalog.snapshots(scope: .regularOnly)

        XCTAssertEqual(state.workspaceRequestCount, 2)
    }

    private func fixtureApp(
        processIdentifier: pid_t = 101,
        kind: EnergyImpactAppKind = .regular
    ) -> EnergyImpactAppSnapshot {
        EnergyImpactAppSnapshot(
            processIdentifier: processIdentifier,
            name: "Fixture",
            bundleIdentifier: "example.fixture",
            bundleURL: nil,
            kind: kind
        )
    }

    private func fixtureEntry() -> EnergyImpactEntry {
        EnergyImpactEntry(
            identity: EnergyImpactAppIdentity(
                rootProcessIdentifier: 101,
                rootProcessStartAbsoluteTime: 10
            ),
            name: "Fixture",
            bundleIdentifier: "example.fixture",
            bundleURL: nil,
            currentPowerMicrowatts: 1,
            sustainedPowerMicrowatts: nil,
            rankingScore: 1,
            trend: .steady,
            coverage: .unavailable,
            status: .stable
        )
    }
}

@MainActor
private final class EnergyImpactCatalogTestState {
    var now: TimeInterval = 0
    var workspaceRequestCount = 0
}

@MainActor
private final class EnergyImpactAppCatalogStub: EnergyImpactAppCataloging {
    let apps: [EnergyImpactAppSnapshot]
    private(set) var requestedScopes = [EnergyImpactAppScope]()

    init(apps: [EnergyImpactAppSnapshot]) {
        self.apps = apps
    }

    func snapshots(scope: EnergyImpactAppScope) -> [EnergyImpactAppSnapshot] {
        requestedScopes.append(scope)
        return apps
    }
}

private actor EnergyImpactSamplingStub: EnergyImpactSampling {
    struct Request: Equatable, Sendable {
        let sessionID: EnergyImpactSessionID
        let apps: [EnergyImpactAppSnapshot]
        let limit: Int
        let publicationBoundary: Bool
    }

    struct Snapshot: Sendable {
        let activeSessionID: EnergyImpactSessionID?
        let requests: [Request]
    }

    private let output: [EnergyImpactEntry]
    private var activeSessionID: EnergyImpactSessionID?
    private var requests = [Request]()

    init(output: [EnergyImpactEntry]) {
        self.output = output
    }

    func beginSession() -> EnergyImpactSessionID {
        let sessionID = EnergyImpactSessionID()
        activeSessionID = sessionID
        return sessionID
    }

    func sample(
        sessionID: EnergyImpactSessionID,
        apps: [EnergyImpactAppSnapshot],
        limit: Int,
        publicationBoundary: Bool
    ) -> [EnergyImpactEntry]? {
        guard sessionID == activeSessionID else { return nil }
        requests.append(Request(
            sessionID: sessionID,
            apps: apps,
            limit: limit,
            publicationBoundary: publicationBoundary
        ))
        return Array(output.prefix(max(0, limit)))
    }

    func endSession(_ sessionID: EnergyImpactSessionID) {
        guard sessionID == activeSessionID else { return }
        activeSessionID = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(activeSessionID: activeSessionID, requests: requests)
    }
}
