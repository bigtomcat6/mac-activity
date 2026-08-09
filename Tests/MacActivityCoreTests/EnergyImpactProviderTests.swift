import XCTest
@testable import MacActivityCore

@MainActor
final class EnergyImpactProviderTests: XCTestCase {
    func testBeginSessionAllocatesGenerationsBeforeAwaitingSampler() async {
        let sampler = ReorderingSamplingSpy()
        let service = EnergyImpactService(
            catalog: EnergyImpactAppCatalogStub(responses: [[]]),
            sampler: sampler
        )

        let first = Task { await service.beginSession() }
        await sampler.waitForRequestCount(1)
        let second = Task { await service.beginSession() }
        await sampler.waitForRequestCount(2)

        let requestGenerations = await sampler.requestGenerations
        XCTAssertEqual(requestGenerations, [1, 2])
        await sampler.releaseFirstRequest()
        _ = await first.value
        _ = await second.value
    }

    func testReorderedBeginLeavesNewerRequestAuthoritative() async throws {
        let sampler = ReorderingSamplingSpy()
        let service = EnergyImpactService(
            catalog: EnergyImpactAppCatalogStub(responses: [[]]),
            sampler: sampler
        )

        let first = Task { await service.beginSession() }
        await sampler.waitForRequestCount(1)
        let second = Task { await service.beginSession() }
        await sampler.waitForRequestCount(2)
        let newer = await second.value
        await sampler.releaseFirstRequest()
        let older = await first.value

        XCTAssertNil(older)
        XCTAssertEqual(try XCTUnwrap(newer).requestGeneration, 2)
        let activeRequestGeneration = await sampler.activeRequestGeneration
        XCTAssertEqual(activeRequestGeneration, 2)
    }

    func testObserveCapturesOneCurrentCatalogArrayForOneSamplerCall() async throws {
        let expected = [EnergyImpactAppSnapshot(
            processIdentifier: 101,
            name: "First",
            bundleIdentifier: "com.example.first",
            bundleURL: nil
        )]
        let catalog = EnergyImpactAppCatalogStub(responses: [
            expected,
            [.init(processIdentifier: 202, name: "Later", bundleIdentifier: nil, bundleURL: nil)],
        ])
        let sampler = SamplingSpy()
        let service = EnergyImpactService(catalog: catalog, sampler: sampler)
        let optionalLease = await service.beginSession()
        let lease = try XCTUnwrap(optionalLease)

        _ = await service.observe(
            lease: lease,
            limit: 20,
            scope: .regularAndAccessory
        )

        XCTAssertEqual(catalog.callCount, 1)
        let observedApps = await sampler.observedApps
        let observeCount = await sampler.observeCount
        XCTAssertEqual(observedApps, [expected])
        XCTAssertEqual(observeCount, 1)
    }

    func testObserveForwardsRegularOnlyScopeUnchanged() async throws {
        let catalog = EnergyImpactAppCatalogStub(responses: [[]])
        let sampler = SamplingSpy()
        let service = EnergyImpactService(catalog: catalog, sampler: sampler)
        let optionalLease = await service.beginSession()
        let lease = try XCTUnwrap(optionalLease)

        _ = await service.observe(
            lease: lease,
            limit: 7,
            scope: .regularOnly
        )

        XCTAssertEqual(catalog.scopes, [.regularOnly])
        let observedLimits = await sampler.observedLimits
        XCTAssertEqual(observedLimits, [7])
    }

    func testFacadeStoresNoAlgorithmOrProcessState() {
        let service = EnergyImpactService(
            catalog: EnergyImpactAppCatalogStub(responses: [[]]),
            sampler: SamplingSpy()
        )

        let labels = Mirror(reflecting: service).children.compactMap(\.label)
        let forbiddenFragments = [
            "baseline", "owner", "snapshot", "smoother", "ranker", "raw",
        ]

        XCTAssertEqual(Set(labels), ["catalog", "sampler", "nextRequestGeneration"])
        XCTAssertTrue(labels.allSatisfy { label in
            forbiddenFragments.allSatisfy { label.localizedCaseInsensitiveContains($0) == false }
        })
    }
}

@MainActor
private final class EnergyImpactAppCatalogStub: EnergyImpactAppCataloging {
    private var responses: [[EnergyImpactAppSnapshot]]
    private(set) var scopes: [EnergyImpactAppScope] = []

    init(responses: [[EnergyImpactAppSnapshot]]) {
        self.responses = responses
    }

    var callCount: Int { scopes.count }

    func snapshots(scope: EnergyImpactAppScope) -> [EnergyImpactAppSnapshot] {
        scopes.append(scope)
        guard responses.isEmpty == false else { return [] }
        return responses.removeFirst()
    }
}

private actor SamplingSpy: EnergyImpactSampling {
    private(set) var observedApps: [[EnergyImpactAppSnapshot]] = []
    private(set) var observedLimits: [Int] = []
    private(set) var observeCount = 0

    func beginSession(
        _ request: EnergyImpactSessionRequest
    ) -> EnergyImpactSamplingLease? {
        EnergyImpactSamplingLease(requestGeneration: request.generation)
    }

    func observe(
        lease: EnergyImpactSamplingLease,
        apps: [EnergyImpactAppSnapshot],
        limit: Int
    ) -> [EnergyImpactEntry]? {
        observedApps.append(apps)
        observedLimits.append(limit)
        observeCount += 1
        return []
    }

    func endSession(_ lease: EnergyImpactSamplingLease) {}
}

private actor ReorderingSamplingSpy: EnergyImpactSampling {
    private(set) var requestGenerations: [UInt64] = []
    private(set) var activeRequestGeneration: UInt64?
    private var highestSeenGeneration: UInt64 = 0
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?

    func beginSession(
        _ request: EnergyImpactSessionRequest
    ) async -> EnergyImpactSamplingLease? {
        requestGenerations.append(request.generation)
        if request.generation == 1 {
            await withCheckedContinuation { continuation in
                firstRequestContinuation = continuation
            }
        }
        guard request.generation > highestSeenGeneration else { return nil }
        highestSeenGeneration = request.generation
        activeRequestGeneration = request.generation
        return EnergyImpactSamplingLease(requestGeneration: request.generation)
    }

    func observe(
        lease: EnergyImpactSamplingLease,
        apps: [EnergyImpactAppSnapshot],
        limit: Int
    ) -> [EnergyImpactEntry]? {
        []
    }

    func endSession(_ lease: EnergyImpactSamplingLease) {}

    func waitForRequestCount(_ expectedCount: Int) async {
        while requestGenerations.count < expectedCount {
            await Task.yield()
        }
    }

    func releaseFirstRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }
}
