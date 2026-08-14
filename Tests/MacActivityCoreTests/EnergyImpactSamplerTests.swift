import Darwin
import XCTest
@testable import MacActivityCore

@MainActor
final class EnergyImpactSamplerTests: XCTestCase {
    private func require<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func sortedByImpact(
        _ entries: [EnergyImpactEntry],
        limit: Int
    ) -> [EnergyImpactEntry] {
        var publicationState = EnergyImpactPublicationState()
        return publicationState.publish(entries, at: 0, limit: limit)
    }

    private func reading(
        energy: UInt64,
        start: UInt64 = 10,
        userCPU: UInt64 = 0,
        systemCPU: UInt64 = 0
    ) -> ProcessEnergyReading {
        ProcessEnergyReading(
            energyNanojoules: energy,
            processStartAbsoluteTime: start,
            userCPUTime: userCPU,
            systemCPUTime: systemCPU
        )
    }

    private func makeService(
        results: [ProcessEnergyReadResult],
        times: [TimeInterval]
    ) -> EnergyImpactSamplerTestSession {
        EnergyImpactSamplerTestSession(
            reader: ProcessEnergyReadingProviderStub(results: [101: results]),
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            appSnapshotProvider: { [
                .init(processIdentifier: 101, name: "Fixture", bundleIdentifier: nil, bundleURL: nil),
            ] },
            clock: EnergyImpactClockStub(times: times)
        )
    }

    private func makeTwoProcessService(
        rootResults: [ProcessEnergyReadResult],
        helperResults: [ProcessEnergyReadResult],
        times: [TimeInterval]
    ) -> EnergyImpactSamplerTestSession {
        EnergyImpactSamplerTestSession(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: rootResults,
                101: helperResults,
            ]),
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: [
                .init(processIdentifier: 101, parentProcessIdentifier: 100),
            ]),
            appSnapshotProvider: { [
                .init(processIdentifier: 100, name: "Fixture", bundleIdentifier: nil, bundleURL: nil),
            ] },
            clock: EnergyImpactClockStub(times: times)
        )
    }

    private func makeReparentingService(
        ownersBySample: [pid_t],
        energies: [UInt64],
        times: [TimeInterval]
    ) -> EnergyImpactSamplerTestSession {
        EnergyImpactSamplerTestSession(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: ownersBySample.map { _ in .failure(.permissionDenied) },
                200: ownersBySample.map { _ in .failure(.permissionDenied) },
                300: energies.map { .success(reading(energy: $0, start: 30)) },
            ]),
            processSnapshotReader: SequencedProcessParentSnapshotReaderStub(
                snapshotsByCall: ownersBySample.map { owner in
                    [.init(processIdentifier: 300, parentProcessIdentifier: owner)]
                }
            ),
            appSnapshotProvider: { [
                .init(processIdentifier: 100, name: "First", bundleIdentifier: nil, bundleURL: nil),
                .init(processIdentifier: 200, name: "Second", bundleIdentifier: nil, bundleURL: nil),
            ] },
            clock: EnergyImpactClockStub(times: times)
        )
    }

    private func makeMixedGapService(
        rootEnergies: [UInt64],
        helperResults: [ProcessEnergyReadResult],
        times: [TimeInterval]
    ) -> EnergyImpactSamplerTestSession {
        makeTwoProcessService(
            rootResults: rootEnergies.map { .success(reading(energy: $0, start: 10)) },
            helperResults: helperResults,
            times: times
        )
    }

    private func entry(
        processIdentifier: pid_t,
        name: String,
        power: Double?,
        status: EnergyImpactStatus
    ) -> EnergyImpactEntry {
        EnergyImpactEntry(
            identity: EnergyImpactAppIdentity(
                rootProcessIdentifier: processIdentifier,
                rootProcessStartAbsoluteTime: UInt64(processIdentifier)
            ),
            name: name,
            bundleIdentifier: nil,
            bundleURL: nil,
            currentPowerMicrowatts: power,
            sustainedPowerMicrowatts: power,
            rankingScore: power,
            trend: .steady,
            coverage: .unavailable,
            status: status
        )
    }

    private func makeSamplerForPowerSeries(
        _ powers: [Double],
        interval: TimeInterval
    ) -> (EnergyImpactSampler, [EnergyImpactAppSnapshot], Int) {
        var cumulativeNanojoules: UInt64 = 0
        var readings = [reading(energy: 0)]
        for power in powers {
            cumulativeNanojoules += UInt64(power * interval * 1_000)
            readings.append(reading(energy: cumulativeNanojoules))
        }
        let sampler = EnergyImpactSampler(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: readings.map(ProcessEnergyReadResult.success),
            ]),
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            clock: EnergyImpactClockStub(
                times: (0...powers.count).map { Double($0) * interval }
            )
        )
        return (
            sampler,
            [
                EnergyImpactAppSnapshot(
                    processIdentifier: 100,
                    name: "Fixture",
                    bundleIdentifier: nil,
                    bundleURL: nil
                ),
            ],
            powers.count + 1
        )
    }

    private func consumeAllObservations(
        sampler: EnergyImpactSampler,
        apps: [EnergyImpactAppSnapshot],
        count: Int,
        limit: Int = 20
    ) async throws -> [[EnergyImpactEntry]] {
        let lease = try require(
            await sampler.beginSession(.init(generation: 1))
        )
        var observations: [[EnergyImpactEntry]] = []
        for _ in 0..<count {
            observations.append(try require(
                await sampler.observe(lease: lease, apps: apps, limit: limit)
            ))
        }
        await sampler.endSession(lease)
        return observations
    }

    private func entryAfter(
        observedSeconds: Int,
        coverage targetCoverage: Double
    ) async throws -> EnergyImpactEntry {
        let processCount = targetCoverage == 1 ? 1 : 100
        let readableCount = Int((targetCoverage * Double(processCount)).rounded())
        let observationCount = observedSeconds / 3 + 1
        let rootPID: pid_t = 100
        let processIdentifiers = (0..<processCount).map { rootPID + pid_t($0) }
        let snapshots = processIdentifiers.dropFirst().map {
            ProcessParentSnapshot(
                processIdentifier: $0,
                parentProcessIdentifier: rootPID
            )
        }
        var results: [pid_t: [ProcessEnergyReadResult]] = [:]
        for (index, processIdentifier) in processIdentifiers.enumerated() {
            if index < readableCount {
                results[processIdentifier] = (0..<observationCount).map { sample in
                    .success(reading(
                        energy: UInt64(sample * 3_000),
                        start: UInt64(processIdentifier)
                    ))
                }
            } else {
                results[processIdentifier] = Array(
                    repeating: .failure(.permissionDenied),
                    count: observationCount
                )
            }
        }
        let sampler = EnergyImpactSampler(
            reader: ProcessEnergyReadingProviderStub(results: results),
            processSnapshotReader: ProcessParentSnapshotReaderStub(
                snapshots: Array(snapshots)
            ),
            clock: EnergyImpactClockStub(
                times: (0..<observationCount).map { Double($0 * 3) }
            )
        )
        let observations = try await consumeAllObservations(
            sampler: sampler,
            apps: [
                .init(
                    processIdentifier: rootPID,
                    name: "Fixture",
                    bundleIdentifier: nil,
                    bundleURL: nil
                ),
            ],
            count: observationCount
        )
        return try require(observations.last?.first)
    }

    func testFastAndSustainedValuesUseLockedWeights() async throws {
        let fixture = makeSamplerForPowerSeries(
            Array(repeating: 100.0, count: 7)
                + Array(repeating: 400.0, count: 4),
            interval: 3
        )
        let entries = try await consumeAllObservations(
            sampler: fixture.0,
            apps: fixture.1,
            count: fixture.2
        )
        let entry = try require(entries.last?.first)

        XCTAssertNotNil(entry.currentPowerMicrowatts)
        XCTAssertNotNil(entry.sustainedPowerMicrowatts)
        XCTAssertEqual(
            try require(entry.rankingScore),
            0.4 * (try require(entry.currentPowerMicrowatts))
                + 0.6 * (try require(entry.sustainedPowerMicrowatts)),
            accuracy: 0.001
        )
        XCTAssertEqual(entry.trend, .rising)
    }

    func testStableRequiresFifteenValidSecondsAndNinetyPercentCoverage() async throws {
        let twelveSeconds = try await entryAfter(observedSeconds: 12, coverage: 1)
        let lowCoverage = try await entryAfter(observedSeconds: 18, coverage: 0.89)
        let stable = try await entryAfter(observedSeconds: 15, coverage: 0.9)

        XCTAssertEqual(twelveSeconds.status, .collecting)
        XCTAssertEqual(lowCoverage.status, .partial)
        XCTAssertEqual(stable.status, .stable)
    }

    func testAllCandidatesUpdateBeforeTopTwentyLimit() async throws {
        let apps = (1...21).map { index in
            EnergyImpactAppSnapshot(
                processIdentifier: pid_t(index),
                name: "App \(index)",
                bundleIdentifier: nil,
                bundleURL: nil
            )
        }
        let results = Dictionary(uniqueKeysWithValues: (1...21).map { index in
            let firstDelta = index == 21 ? 1_000 : 3_000
            let secondDelta = index == 21 ? 300_000 : 3_000
            return (
                pid_t(index),
                [
                    ProcessEnergyReadResult.success(reading(
                        energy: 0,
                        start: UInt64(index)
                    )),
                    .success(reading(
                        energy: UInt64(firstDelta),
                        start: UInt64(index)
                    )),
                    .success(reading(
                        energy: UInt64(firstDelta + secondDelta),
                        start: UInt64(index)
                    )),
                ]
            )
        })
        let sampler = EnergyImpactSampler(
            reader: ProcessEnergyReadingProviderStub(results: results),
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            clock: EnergyImpactClockStub(times: [0, 3, 6])
        )
        let observations = try await consumeAllObservations(
            sampler: sampler,
            apps: apps,
            count: 3,
            limit: 20
        )
        let entries = try require(observations.last)

        XCTAssertEqual(entries.count, 20)
        XCTAssertEqual(entries.first?.name, "App 21")
    }

    func testAllPIDFailureRecoveryCommitsMatchingEnergyAndWallTime() async throws {
        let sampler = EnergyImpactSampler(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: [
                    .success(reading(energy: 0)),
                    .failure(.permissionDenied),
                    .success(reading(energy: 6_000)),
                ],
            ]),
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            clock: EnergyImpactClockStub(times: [0, 3, 6])
        )
        let observations = try await consumeAllObservations(
            sampler: sampler,
            apps: [
                .init(
                    processIdentifier: 100,
                    name: "Fixture",
                    bundleIdentifier: nil,
                    bundleURL: nil
                ),
            ],
            count: 3
        )
        let last = try require(observations.last?.first)

        XCTAssertEqual(
            try require(last.sustainedPowerMicrowatts),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(last.observedWindowSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(last.coverage.fraction, 1, accuracy: 0.001)
    }

    func testStaleIntervalDoesNotAdvanceEstimatorState() async throws {
        let service = makeService(
            results: [
                .success(reading(energy: 0)),
                .success(reading(energy: 300_000)),
                .failure(.permissionDenied),
                .success(reading(energy: 300_000)),
            ],
            times: [0, 3, 6, 9]
        )

        _ = await service.observe(limit: 1)
        let estimated = try require(await service.observe(limit: 1).first)
        let stale = try require(await service.observe(limit: 1).first)
        let recovered = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(try require(estimated.currentPowerMicrowatts), 100)
        XCTAssertEqual(stale.status, .stale)
        XCTAssertNil(stale.rankingScore)
        XCTAssertEqual(
            try require(recovered.currentPowerMicrowatts),
            35.355_339_06,
            accuracy: 0.000_001
        )
        XCTAssertEqual(recovered.observedWindowSeconds, 9, accuracy: 0.001)
    }

    func testMissingRootGenerationPublishesOnlyCurrentIntervalData() async throws {
        let sampler = EnergyImpactSampler(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: [
                    .failure(.permissionDenied),
                    .failure(.permissionDenied),
                ],
                101: [
                    .success(reading(energy: 0, start: 11)),
                    .success(reading(energy: 3_000, start: 11)),
                ],
            ]),
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: [
                .init(processIdentifier: 101, parentProcessIdentifier: 100),
            ]),
            clock: EnergyImpactClockStub(times: [0, 3])
        )
        let publications = try await consumeAllObservations(
            sampler: sampler,
            apps: [
                .init(
                    processIdentifier: 100,
                    name: "Fixture",
                    bundleIdentifier: nil,
                    bundleURL: nil
                ),
            ],
            count: 2
        )
        let row = try require(publications.last?.first)

        XCTAssertNil(row.identity.rootProcessStartAbsoluteTime)
        XCTAssertEqual(row.status, .collecting)
        XCTAssertEqual(try require(row.currentPowerMicrowatts), 1, accuracy: 0.001)
        XCTAssertNil(row.sustainedPowerMicrowatts)
        XCTAssertNil(row.rankingScore)
        XCTAssertEqual(row.observedWindowSeconds, 3, accuracy: 0.001)
    }

    func testNewerBeginRequestWinsWhenItArrivesBeforeOlderRequest() async throws {
        let sampler = EnergyImpactSampler(
            reader: ProcessEnergyReadingProviderStub(results: [:]),
            processSnapshotReader:
                ProcessParentSnapshotReaderStub(snapshots: []),
            clock: EnergyImpactClockStub(times: [0]),
            configuration: .production
        )

        let newer = await sampler.beginSession(
            EnergyImpactSessionRequest(generation: 2)
        )
        let older = await sampler.beginSession(
            EnergyImpactSessionRequest(generation: 1)
        )

        XCTAssertNotNil(newer)
        XCTAssertNil(older)
        let lease = try require(newer)
        let observed = await sampler.observe(
            lease: lease,
            apps: [],
            limit: 20
        )
        XCTAssertNotNil(observed)
    }

    func testOldEndCannotClearNewLease() async throws {
        let sampler = EnergyImpactSampler(
            reader: ProcessEnergyReadingProviderStub(results: [:]),
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            clock: EnergyImpactClockStub(times: [0])
        )
        let first = try require(await sampler.beginSession(.init(generation: 1)))
        let second = try require(await sampler.beginSession(.init(generation: 2)))

        await sampler.endSession(first)

        let observed = await sampler.observe(lease: second, apps: [], limit: 20)
        XCTAssertNotNil(observed)
    }

    func testEndingCurrentLeaseInvalidatesOldLeaseAndRestartsCollecting() async throws {
        let sampler = EnergyImpactSampler(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: [
                    .success(reading(energy: 1_000)),
                    .success(reading(energy: 4_000)),
                ],
            ]),
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            clock: EnergyImpactClockStub(times: [0, 3])
        )
        let lease = try require(
            await sampler.beginSession(.init(generation: 1))
        )
        let apps = [
            EnergyImpactAppSnapshot(
                processIdentifier: 100,
                name: "Fixture App",
                bundleIdentifier: "example.fixture",
                bundleURL: nil
            ),
        ]
        _ = await sampler.observe(lease: lease, apps: apps, limit: 20)

        await sampler.endSession(lease)
        let invalidated = await sampler.observe(
            lease: lease,
            apps: apps,
            limit: 20
        )

        XCTAssertNil(invalidated)

        let replacement = try require(
            await sampler.beginSession(.init(generation: 2))
        )
        let restarted = try require(
            await sampler.observe(
                lease: replacement,
                apps: apps,
                limit: 20
            )?.first
        )

        XCTAssertEqual(restarted.status, .collecting)
        XCTAssertNil(restarted.currentPowerMicrowatts)
        XCTAssertNil(restarted.sustainedPowerMicrowatts)
        XCTAssertNil(restarted.rankingScore)
    }

    func testFirstCoherentObservationPublishesCollectingWithoutFalseZero() async throws {
        let sampler = EnergyImpactSampler(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: [.success(reading(energy: 1_000))],
            ]),
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            clock: EnergyImpactClockStub(times: [0])
        )
        let lease = try require(await sampler.beginSession(.init(generation: 1)))

        let rows = try require(await sampler.observe(
            lease: lease,
            apps: [.init(processIdentifier: 100, name: "Root", bundleIdentifier: nil, bundleURL: nil)],
            limit: 20
        ))
        let row = try require(rows.first)

        XCTAssertEqual(row.status, .collecting)
        XCTAssertNil(row.currentPowerMicrowatts)
        XCTAssertNil(row.sustainedPowerMicrowatts)
        XCTAssertNil(row.rankingScore)
    }

    func testSecondCoherentObservationMatchesPartThreePartialAggregate() async throws {
        let sampler = EnergyImpactSampler(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: [
                    .success(reading(energy: 1_000)),
                    .success(reading(energy: 4_000)),
                ],
                101: [
                    .failure(.permissionDenied),
                    .failure(.permissionDenied),
                ],
            ]),
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: [
                .init(processIdentifier: 101, parentProcessIdentifier: 100),
            ]),
            clock: EnergyImpactClockStub(times: [0, 3])
        )
        let lease = try require(await sampler.beginSession(.init(generation: 1)))
        let apps = [EnergyImpactAppSnapshot(
            processIdentifier: 100,
            name: "Root",
            bundleIdentifier: nil,
            bundleURL: nil
        )]

        _ = await sampler.observe(lease: lease, apps: apps, limit: 20)
        let row = try require(
            await sampler.observe(lease: lease, apps: apps, limit: 20)?.first
        )

        XCTAssertEqual(row.status, .collecting)
        XCTAssertEqual(try require(row.currentPowerMicrowatts), 1, accuracy: 0.001)
        XCTAssertEqual(row.coverage.readableProcessCount, 1)
        XCTAssertEqual(row.coverage.discoveredProcessCount, 2)
        XCTAssertEqual(row.coverage.validProcessSeconds, 3, accuracy: 0.001)
        XCTAssertEqual(row.coverage.discoveredProcessSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(row.coverage.fraction, 0.5, accuracy: 0.001)
    }

    func testEveryObserveReadsOneFreshOwnershipSnapshotAndCurrentCounters() async throws {
        let snapshots = SequencedProcessParentSnapshotReaderStub(snapshotsByCall: [
            [.init(processIdentifier: 101, parentProcessIdentifier: 100)],
            [.init(processIdentifier: 101, parentProcessIdentifier: 100)],
        ])
        let reader = ProcessEnergyReadingProviderStub(results: [
            100: [.success(reading(energy: 1_000)), .success(reading(energy: 4_000))],
            101: [
                .success(reading(energy: 1_000, start: 11)),
                .success(reading(energy: 4_000, start: 11)),
            ],
        ])
        let sampler = EnergyImpactSampler(
            reader: reader,
            processSnapshotReader: snapshots,
            clock: EnergyImpactClockStub(times: [0, 3])
        )
        let lease = try require(await sampler.beginSession(.init(generation: 1)))
        let apps = [EnergyImpactAppSnapshot(
            processIdentifier: 100,
            name: "Root",
            bundleIdentifier: nil,
            bundleURL: nil
        )]

        _ = await sampler.observe(lease: lease, apps: apps, limit: 20)
        _ = await sampler.observe(lease: lease, apps: apps, limit: 20)

        XCTAssertEqual(snapshots.callCount, 2)
        XCTAssertEqual(reader.readCount(for: 100), 2)
        XCTAssertEqual(reader.readCount(for: 101), 2)
    }

    func testOwnershipMoveRebaselinesBothRootsWithoutTransitionAttribution() async throws {
        let sampler = EnergyImpactSampler(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: [.failure(.permissionDenied), .failure(.permissionDenied)],
                200: [.failure(.permissionDenied), .failure(.permissionDenied)],
                300: [
                    .success(reading(energy: 1_000, start: 30)),
                    .success(reading(energy: 9_000, start: 30)),
                ],
            ]),
            processSnapshotReader: SequencedProcessParentSnapshotReaderStub(snapshotsByCall: [
                [.init(processIdentifier: 300, parentProcessIdentifier: 100)],
                [.init(processIdentifier: 300, parentProcessIdentifier: 200)],
            ]),
            clock: EnergyImpactClockStub(times: [0, 3])
        )
        let lease = try require(await sampler.beginSession(.init(generation: 1)))
        let apps = [
            EnergyImpactAppSnapshot(processIdentifier: 100, name: "A", bundleIdentifier: nil, bundleURL: nil),
            EnergyImpactAppSnapshot(processIdentifier: 200, name: "B", bundleIdentifier: nil, bundleURL: nil),
        ]

        _ = await sampler.observe(lease: lease, apps: apps, limit: 20)
        let rows = try require(await sampler.observe(lease: lease, apps: apps, limit: 20))

        XCTAssertTrue(rows.allSatisfy { $0.currentPowerMicrowatts == nil })
    }

    func testReorderedEquivalentOwnershipRemainsNumeric() async throws {
        let sampler = EnergyImpactSampler(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: [.success(reading(energy: 1_000)), .success(reading(energy: 4_000))],
                101: [
                    .success(reading(energy: 1_000, start: 11)),
                    .success(reading(energy: 4_000, start: 11)),
                ],
            ]),
            processSnapshotReader: SequencedProcessParentSnapshotReaderStub(snapshotsByCall: [
                [
                    .init(processIdentifier: 100, parentProcessIdentifier: 1),
                    .init(processIdentifier: 101, parentProcessIdentifier: 100),
                ],
                [
                    .init(processIdentifier: 101, parentProcessIdentifier: 100),
                    .init(processIdentifier: 100, parentProcessIdentifier: 1),
                ],
            ]),
            clock: EnergyImpactClockStub(times: [0, 3])
        )
        let lease = try require(await sampler.beginSession(.init(generation: 1)))
        let apps = [EnergyImpactAppSnapshot(processIdentifier: 100, name: "A", bundleIdentifier: nil, bundleURL: nil)]

        _ = await sampler.observe(lease: lease, apps: apps, limit: 20)
        let row = try require(
            await sampler.observe(lease: lease, apps: apps, limit: 20)?.first
        )

        XCTAssertEqual(row.status, .collecting)
        XCTAssertNotNil(row.currentPowerMicrowatts)
    }

    func testCancelledObserveReturnsNilWithoutCommittingWorkingState() async throws {
        let reader = ProcessEnergyReadingProviderStub(
            results: [
                100: [
                    .success(reading(energy: 1_000)),
                    .success(reading(energy: 10_000)),
                    .success(reading(energy: 7_000)),
                ],
            ],
            blockedReadNumber: 2
        )
        let sampler = EnergyImpactSampler(
            reader: reader,
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            clock: EnergyImpactClockStub(times: [0, 3, 6])
        )
        let lease = try require(await sampler.beginSession(.init(generation: 1)))
        let apps = [EnergyImpactAppSnapshot(processIdentifier: 100, name: "A", bundleIdentifier: nil, bundleURL: nil)]
        _ = await sampler.observe(lease: lease, apps: apps, limit: 20)

        let cancelled = Task.detached {
            await sampler.observe(lease: lease, apps: apps, limit: 20)
        }
        XCTAssertTrue(reader.waitUntilBlocked())
        cancelled.cancel()
        reader.releaseBlockedRead()

        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)
        let recovered = try require(
            await sampler.observe(lease: lease, apps: apps, limit: 20)?.first
        )
        XCTAssertEqual(recovered.status, .collecting)
        XCTAssertEqual(try require(recovered.currentPowerMicrowatts), 1, accuracy: 0.001)
    }

    func testConcurrentObserveCallsNeverOverlapProcessReads() async throws {
        let reader = ProcessEnergyReadingProviderStub(
            results: [
                100: [
                    .success(reading(energy: 1_000)),
                    .success(reading(energy: 4_000)),
                ],
            ],
            blockedReadNumber: 1
        )
        let sampler = EnergyImpactSampler(
            reader: reader,
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            clock: EnergyImpactClockStub(times: [0, 3])
        )
        guard (sampler as Any) is any Actor else {
            XCTFail("EnergyImpactSampler must remain actor-isolated")
            return
        }
        let lease = try require(
            await sampler.beginSession(.init(generation: 1))
        )
        let apps = [
            EnergyImpactAppSnapshot(
                processIdentifier: 100,
                name: "A",
                bundleIdentifier: nil,
                bundleURL: nil
            ),
        ]
        let startBarrier = ConcurrentObservationStartBarrier(
            participantCount: 2
        )

        let first = Task.detached {
            await startBarrier.arriveAndWait()
            return await sampler.observe(
                lease: lease,
                apps: apps,
                limit: 20
            )
        }
        let second = Task.detached {
            await startBarrier.arriveAndWait()
            return await sampler.observe(
                lease: lease,
                apps: apps,
                limit: 20
            )
        }

        let didBlockFirstRead = reader.waitUntilBlocked()
        reader.releaseBlockedRead()

        let firstResult = await first.value
        let secondResult = await second.value

        XCTAssertTrue(didBlockFirstRead)
        XCTAssertNotNil(firstResult)
        XCTAssertNotNil(secondResult)
        XCTAssertEqual(reader.maximumConcurrentReads, 1)
    }

    func testObservationUpdatesAllCandidatesBeforeTopTwentyLimit() async throws {
        let apps = (1...21).map { index in
            EnergyImpactAppSnapshot(
                processIdentifier: pid_t(index),
                name: "App \(index)",
                bundleIdentifier: nil,
                bundleURL: nil
            )
        }
        var results: [pid_t: [ProcessEnergyReadResult]] = [:]
        for index in 1...21 {
            let delta = index == 21 ? UInt64(100_000) : UInt64(index * 1_000)
            results[pid_t(index)] = [
                .success(reading(energy: 1_000, start: UInt64(index))),
                .success(reading(energy: 1_000 + delta, start: UInt64(index))),
            ]
        }
        let reader = ProcessEnergyReadingProviderStub(results: results)
        let sampler = EnergyImpactSampler(
            reader: reader,
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            clock: EnergyImpactClockStub(times: [0, 3])
        )
        let lease = try require(await sampler.beginSession(.init(generation: 1)))

        _ = await sampler.observe(lease: lease, apps: apps, limit: 20)
        let rows = try require(await sampler.observe(lease: lease, apps: apps, limit: 20))

        XCTAssertEqual(rows.count, 20)
        XCTAssertTrue(rows.contains { $0.processIdentifier == 21 })
        XCTAssertEqual(reader.readCount(for: 21), 2)
    }

    func testConfigurationUsesSingleThreeSecondObservationInterval() async {
        let configuration = EnergyImpactConfiguration.production

        XCTAssertEqual(configuration.observationIntervalSeconds, 3)
    }

    func testIrregularObservationUsesActualElapsedInsteadOfConfiguredInterval() async throws {
        let sampler = EnergyImpactSampler(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: [
                    .success(reading(energy: 1_000)),
                    .success(reading(energy: 6_000)),
                ],
            ]),
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            clock: EnergyImpactClockStub(times: [0, 5]),
            configuration: .production
        )
        let lease = try require(await sampler.beginSession(.init(generation: 1)))
        let apps = [EnergyImpactAppSnapshot(processIdentifier: 100, name: "A", bundleIdentifier: nil, bundleURL: nil)]

        _ = await sampler.observe(lease: lease, apps: apps, limit: 20)
        let row = try require(
            await sampler.observe(lease: lease, apps: apps, limit: 20)?.first
        )

        XCTAssertEqual(try require(row.currentPowerMicrowatts), 1, accuracy: 0.001)
        XCTAssertEqual(row.coverage.validProcessSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(row.coverage.discoveredProcessSeconds, 5, accuracy: 0.001)
    }

    func testEnergyImpactEntryRepresentsCollectingWithoutAFalseZero() async {
        let entry = EnergyImpactEntry(
            identity: EnergyImpactAppIdentity(
                rootProcessIdentifier: 101,
                rootProcessStartAbsoluteTime: 10
            ),
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: nil,
            currentPowerMicrowatts: nil,
            sustainedPowerMicrowatts: nil,
            rankingScore: nil,
            trend: .steady,
            coverage: EnergyImpactCoverage(
                discoveredProcessCount: 1,
                readableProcessCount: 1,
                validProcessSeconds: 0,
                discoveredProcessSeconds: 0
            ),
            status: .collecting
        )

        XCTAssertNil(entry.displayPowerMicrowatts)
        XCTAssertEqual(entry.status, .collecting)
    }

    func testEnergyImpactEntrySanitizesInvalidObservedWindowContext() async {
        let base = EnergyImpactAppIdentity(
            rootProcessIdentifier: 101,
            rootProcessStartAbsoluteTime: 10
        )
        let nonfinite = EnergyImpactEntry(
            identity: base,
            name: "Fixture",
            bundleIdentifier: nil,
            bundleURL: nil,
            currentPowerMicrowatts: nil,
            sustainedPowerMicrowatts: nil,
            rankingScore: nil,
            trend: .steady,
            coverage: .unavailable,
            status: .collecting,
            observedWindowSeconds: .nan
        )
        let negative = EnergyImpactEntry(
            identity: base,
            name: "Fixture",
            bundleIdentifier: nil,
            bundleURL: nil,
            currentPowerMicrowatts: nil,
            sustainedPowerMicrowatts: nil,
            rankingScore: nil,
            trend: .steady,
            coverage: .unavailable,
            status: .collecting,
            observedWindowSeconds: -1
        )

        XCTAssertEqual(nonfinite.observedWindowSeconds, 0)
        XCTAssertEqual(negative.observedWindowSeconds, 0)
    }

    func testEnergyImpactCoverageUsesValidPIDTime() async {
        let coverage = EnergyImpactCoverage(
            discoveredProcessCount: 4,
            readableProcessCount: 3,
            validProcessSeconds: 9,
            discoveredProcessSeconds: 12
        )

        XCTAssertEqual(coverage.fraction, 0.75, accuracy: 0.001)
    }

    func testEnergyImpactCoverageIsZeroWithoutDiscoveredPIDTime() async {
        let coverage = EnergyImpactCoverage(
            discoveredProcessCount: 0,
            readableProcessCount: 0,
            validProcessSeconds: 0,
            discoveredProcessSeconds: 0
        )

        XCTAssertEqual(coverage.fraction, 0)
    }

    func testEnergyImpactSamplerReportsRollingCoverageWhenOneDescendantHasNoValidDelta() async throws {
        let app = EnergyImpactAppSnapshot(
            processIdentifier: 100,
            name: "Browser",
            bundleIdentifier: "com.example.browser",
            bundleURL: nil
        )
        let service = EnergyImpactSamplerTestSession(
            reader: ProcessEnergyReadingProviderStub(readings: [
                100: [
                    .init(energyNanojoules: 1_000, processStartAbsoluteTime: 10),
                    .init(energyNanojoules: 2_000, processStartAbsoluteTime: 10),
                ],
                101: [
                    .init(energyNanojoules: 2_000, processStartAbsoluteTime: 11),
                    .init(energyNanojoules: 3_000, processStartAbsoluteTime: 21),
                ],
            ]),
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: [
                .init(processIdentifier: 101, parentProcessIdentifier: 100),
            ]),
            appSnapshotProvider: { [app] },
            clock: EnergyImpactClockStub(times: [100, 101])
        )

        _ = await service.observe(limit: 1)
        let entry = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(entry.status, .collecting)
        XCTAssertEqual(entry.coverage.validProcessSeconds, 1)
        XCTAssertEqual(entry.coverage.discoveredProcessSeconds, 2)
        XCTAssertEqual(entry.coverage.fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(try require(entry.currentPowerMicrowatts), 1, accuracy: 0.001)
    }

    func testSystemEnergyImpactClockProvidesMonotonicSeconds() async {
        let clock = SystemEnergyImpactClock()
        let first = clock.nowSeconds()

        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThanOrEqual(clock.nowSeconds(), first)
    }

    func testEnergyImpactSamplerUsesPreviousRefreshSnapshotsForImpact() async throws {
        let apps = [
            EnergyImpactAppSnapshot(
                processIdentifier: 101,
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                bundleURL: URL(fileURLWithPath: "/Applications/Safari.app")
            ),
            EnergyImpactAppSnapshot(
                processIdentifier: 102,
                name: "Notes",
                bundleIdentifier: "com.apple.Notes",
                bundleURL: URL(fileURLWithPath: "/Applications/Notes.app")
            ),
        ]
        let reader = ProcessEnergyReadingProviderStub(readings: [
            101: [
                ProcessEnergyReading(energyNanojoules: 1_000),
                ProcessEnergyReading(energyNanojoules: 3_500),
            ],
            102: [
                ProcessEnergyReading(energyNanojoules: 2_000),
                ProcessEnergyReading(energyNanojoules: 2_300),
            ],
        ])
        let service = EnergyImpactSamplerTestSession(
            reader: reader,
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            appSnapshotProvider: { apps },
            clock: EnergyImpactClockStub(times: [100, 101])
        )

        let firstEntries = await service.observe(limit: 2)
        let secondEntries = await service.observe(limit: 2)

        XCTAssertTrue(firstEntries.allSatisfy { $0.status == .collecting })
        XCTAssertTrue(firstEntries.allSatisfy { $0.currentPowerMicrowatts == nil })
        XCTAssertEqual(secondEntries.map(\.name), ["Safari", "Notes"])
        XCTAssertEqual(try require(secondEntries[0].currentPowerMicrowatts), 2.5, accuracy: 0.001)
        XCTAssertEqual(try require(secondEntries[1].currentPowerMicrowatts), 0.3, accuracy: 0.001)
        XCTAssertEqual(reader.readCount(for: 101), 2)
        XCTAssertEqual(reader.readCount(for: 102), 2)
    }

    func testEnergyImpactSamplerNormalizesImpactByElapsedTime() async throws {
        let app = EnergyImpactAppSnapshot(
            processIdentifier: 101,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app")
        )
        let reader = ProcessEnergyReadingProviderStub(readings: [
            101: [
                ProcessEnergyReading(energyNanojoules: 1_000, processStartAbsoluteTime: 10),
                ProcessEnergyReading(energyNanojoules: 3_500, processStartAbsoluteTime: 10),
            ],
        ])
        let service = EnergyImpactSamplerTestSession(
            reader: reader,
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            appSnapshotProvider: { [app] },
            clock: EnergyImpactClockStub(times: [100, 100.5])
        )

        _ = await service.observe(limit: 1)
        let entries = await service.observe(limit: 1)

        XCTAssertEqual(try require(entries.first?.currentPowerMicrowatts), 5.0, accuracy: 0.001)
    }

    func testEnergyImpactSamplerAggregatesDescendantEnergyIntoOwningApp() async throws {
        let app = EnergyImpactAppSnapshot(
            processIdentifier: 100,
            name: "Browser",
            bundleIdentifier: "com.example.browser",
            bundleURL: URL(fileURLWithPath: "/Applications/Browser.app")
        )
        let reader = ProcessEnergyReadingProviderStub(readings: [
            100: [
                ProcessEnergyReading(energyNanojoules: 1_000, processStartAbsoluteTime: 10),
                ProcessEnergyReading(energyNanojoules: 2_000, processStartAbsoluteTime: 10),
            ],
            101: [
                ProcessEnergyReading(energyNanojoules: 2_000, processStartAbsoluteTime: 11),
                ProcessEnergyReading(energyNanojoules: 5_000, processStartAbsoluteTime: 11),
            ],
            102: [
                ProcessEnergyReading(energyNanojoules: 100, processStartAbsoluteTime: 12),
                ProcessEnergyReading(energyNanojoules: 1_100, processStartAbsoluteTime: 12),
            ],
        ])
        let service = EnergyImpactSamplerTestSession(
            reader: reader,
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: [
                ProcessParentSnapshot(processIdentifier: 100, parentProcessIdentifier: 1),
                ProcessParentSnapshot(processIdentifier: 101, parentProcessIdentifier: 100),
                ProcessParentSnapshot(processIdentifier: 102, parentProcessIdentifier: 101),
                ProcessParentSnapshot(processIdentifier: 999, parentProcessIdentifier: 1),
            ]),
            appSnapshotProvider: { [app] },
            clock: EnergyImpactClockStub(times: [100, 102])
        )

        _ = await service.observe(limit: 1)
        let entries = await service.observe(limit: 1)

        XCTAssertEqual(try require(entries.first?.currentPowerMicrowatts), 2.5, accuracy: 0.001)
        XCTAssertEqual(reader.readCount(for: 100), 2)
        XCTAssertEqual(reader.readCount(for: 101), 2)
        XCTAssertEqual(reader.readCount(for: 102), 2)
        XCTAssertEqual(reader.readCount(for: 999), 0)
    }

    func testEnergyImpactSamplerAssignsNestedAccessoryRootProcessesToNearestRootExactlyOnce() async throws {
        let apps = [
            EnergyImpactAppSnapshot(
                processIdentifier: 100,
                name: "Browser",
                bundleIdentifier: "com.example.browser",
                bundleURL: nil
            ),
            EnergyImpactAppSnapshot(
                processIdentifier: 200,
                name: "Nested Accessory",
                bundleIdentifier: "com.example.nested",
                bundleURL: nil,
                kind: .accessory
            ),
        ]
        let reader = ProcessEnergyReadingProviderStub(readings: [
            100: [
                .init(energyNanojoules: 1_000, processStartAbsoluteTime: 10),
                .init(energyNanojoules: 2_000, processStartAbsoluteTime: 10),
            ],
            150: [
                .init(energyNanojoules: 1_000, processStartAbsoluteTime: 15),
                .init(energyNanojoules: 3_000, processStartAbsoluteTime: 15),
            ],
            200: [
                .init(energyNanojoules: 1_000, processStartAbsoluteTime: 20),
                .init(energyNanojoules: 4_000, processStartAbsoluteTime: 20),
            ],
            250: [
                .init(energyNanojoules: 1_000, processStartAbsoluteTime: 25),
                .init(energyNanojoules: 5_000, processStartAbsoluteTime: 25),
            ],
        ])
        let service = EnergyImpactSamplerTestSession(
            reader: reader,
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: [
                .init(processIdentifier: 100, parentProcessIdentifier: 1),
                .init(processIdentifier: 150, parentProcessIdentifier: 100),
                .init(processIdentifier: 200, parentProcessIdentifier: 150),
                .init(processIdentifier: 250, parentProcessIdentifier: 200),
            ]),
            appSnapshotProvider: { apps },
            clock: EnergyImpactClockStub(times: [100, 101])
        )

        _ = await service.observe(limit: 2)
        let entries = await service.observe(limit: 2)
        let powerByProcess = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.processIdentifier, $0.currentPowerMicrowatts)
        })
        let kindByProcess = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.processIdentifier, $0.kind)
        })

        XCTAssertEqual(try require(powerByProcess[100] ?? nil), 3, accuracy: 0.001)
        XCTAssertEqual(try require(powerByProcess[200] ?? nil), 7, accuracy: 0.001)
        XCTAssertEqual(kindByProcess[100], .regular)
        XCTAssertEqual(kindByProcess[200], .accessory)
        XCTAssertEqual(reader.readCount(for: 100), 2)
        XCTAssertEqual(reader.readCount(for: 150), 2)
        XCTAssertEqual(reader.readCount(for: 200), 2)
        XCTAssertEqual(reader.readCount(for: 250), 2)
    }

    func testEnergyImpactSamplerRejectsDeltasWhenPIDIsReused() async {
        let app = EnergyImpactAppSnapshot(
            processIdentifier: 101,
            name: "Reused",
            bundleIdentifier: "com.example.reused",
            bundleURL: nil
        )
        let reader = ProcessEnergyReadingProviderStub(readings: [
            101: [
                ProcessEnergyReading(energyNanojoules: 1_000, processStartAbsoluteTime: 10),
                ProcessEnergyReading(energyNanojoules: 50_000, processStartAbsoluteTime: 20),
            ],
        ])
        let service = EnergyImpactSamplerTestSession(
            reader: reader,
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            appSnapshotProvider: { [app] },
            clock: EnergyImpactClockStub(times: [100, 101])
        )

        _ = await service.observe(limit: 1)
        let entries = await service.observe(limit: 1)

        XCTAssertEqual(entries.first?.status, .collecting)
        XCTAssertNil(entries.first?.currentPowerMicrowatts)
    }

    func testLongGapRebaselinesInsteadOfPublishingADilutedValue() async {
        let clock = EnergyImpactClockStub(times: [0, 3, 20])
        let service = EnergyImpactSamplerTestSession(
            reader: ProcessEnergyReadingProviderStub(readings: [
                101: [
                    .init(energyNanojoules: 1_000, processStartAbsoluteTime: 10),
                    .init(energyNanojoules: 4_000, processStartAbsoluteTime: 10),
                    .init(energyNanojoules: 10_000, processStartAbsoluteTime: 10),
                ],
            ]),
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            appSnapshotProvider: { [
                .init(processIdentifier: 101, name: "Fixture", bundleIdentifier: nil, bundleURL: nil),
            ] },
            clock: clock
        )

        _ = await service.observe(limit: 1)
        let beforeGap = await service.observe(limit: 1).first
        XCTAssertEqual(beforeGap?.currentPowerMicrowatts ?? -1, 1)
        let afterGap = await service.observe(limit: 1).first

        XCTAssertNil(afterGap?.currentPowerMicrowatts)
        XCTAssertEqual(afterGap?.status, .collecting)
    }

    func testEnergyCounterRegressionRebaselinesBeforePublishingSubsequentDelta() async throws {
        let service = makeService(
            results: [
                .success(reading(energy: 4_000)),
                .success(reading(energy: 1_000)),
                .success(reading(energy: 4_000)),
            ],
            times: [0, 3, 6]
        )

        _ = await service.observe(limit: 1)
        let regression = try require(await service.observe(limit: 1).first)
        let recovered = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(regression.status, .collecting)
        XCTAssertNil(regression.currentPowerMicrowatts)
        XCTAssertEqual(recovered.status, .collecting)
        XCTAssertEqual(recovered.currentPowerMicrowatts, 1)
    }

    func testNewRegularRootWithoutSnapshotCannotReuseFormerOwnerBaseline() async throws {
        let root = EnergyImpactAppSnapshot(
            processIdentifier: 100,
            name: "Root",
            bundleIdentifier: nil,
            bundleURL: nil
        )
        let promotedHelper = EnergyImpactAppSnapshot(
            processIdentifier: 200,
            name: "Promoted",
            bundleIdentifier: nil,
            bundleURL: nil
        )
        var appSnapshots = [
            [root],
            [root, promotedHelper],
        ]
        let service = EnergyImpactSamplerTestSession(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: [
                    .success(reading(energy: 1_000)),
                    .success(reading(energy: 4_000)),
                ],
                200: [
                    .success(reading(energy: 1_000, start: 20)),
                    .success(reading(energy: 4_000, start: 20)),
                ],
            ]),
            processSnapshotReader: SequencedProcessParentSnapshotReaderStub(snapshotsByCall: [
                [.init(processIdentifier: 200, parentProcessIdentifier: 100)],
                [],
            ]),
            appSnapshotProvider: { appSnapshots.removeFirst() },
            clock: EnergyImpactClockStub(times: [0, 3])
        )

        _ = await service.observe(limit: 2)
        let promoted = try require(
            await service.observe(limit: 2).first { $0.processIdentifier == 200 }
        )

        XCTAssertEqual(promoted.status, .collecting)
        XCTAssertNil(promoted.currentPowerMicrowatts)
    }

    func testClockRollbackCannotProduceANegativeOrInfinitePower() async {
        let clock = EnergyImpactClockStub(times: [3, 2])
        let service = EnergyImpactSamplerTestSession(
            reader: ProcessEnergyReadingProviderStub(readings: [
                101: [
                    .init(energyNanojoules: 1_000, processStartAbsoluteTime: 10),
                    .init(energyNanojoules: 5_000, processStartAbsoluteTime: 10),
                ],
            ]),
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            appSnapshotProvider: { [
                .init(processIdentifier: 101, name: "Fixture", bundleIdentifier: nil, bundleURL: nil),
            ] },
            clock: clock
        )

        _ = await service.observe(limit: 1)
        let entry = await service.observe(limit: 1).first

        XCTAssertNil(entry?.currentPowerMicrowatts)
        XCTAssertEqual(entry?.status, .collecting)
    }

    func testEnergyImpactSamplerKeepsUnconfirmedRootsAsCollectingRows() async {
        let reader = ProcessEnergyReadingProviderStub(readings: [:])
        let service = EnergyImpactSamplerTestSession(
            reader: reader,
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            appSnapshotProvider: {
                [
                    EnergyImpactAppSnapshot(
                        processIdentifier: 101,
                        name: "Locked App",
                        bundleIdentifier: nil,
                        bundleURL: nil
                    ),
                ]
            }
        )
        let entries = await service.observe(limit: 1)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "Locked App")
        XCTAssertNil(entries[0].currentPowerMicrowatts)
        XCTAssertEqual(entries[0].status, .collecting)
    }

    // Production break caught: an unreadable helper is collapsed into a false full-coverage value.
    func testOneUnreadableHelperProducesPartialCoverageWithoutAFalseZero() async throws {
        let service = makeTwoProcessService(
            rootResults: [
                .success(reading(energy: 1_000)),
                .success(reading(energy: 4_000)),
            ],
            helperResults: [
                .failure(.permissionDenied),
                .failure(.permissionDenied),
            ],
            times: [0, 3]
        )

        _ = await service.observe(limit: 1)
        let entry = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(entry.status, .collecting)
        XCTAssertEqual(try require(entry.currentPowerMicrowatts), 1, accuracy: 0.001)
        XCTAssertEqual(entry.coverage.readableProcessCount, 1)
        XCTAssertEqual(entry.coverage.discoveredProcessCount, 2)
        XCTAssertEqual(entry.coverage.validProcessSeconds, 3, accuracy: 0.001)
        XCTAssertEqual(entry.coverage.discoveredProcessSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(entry.coverage.fraction, 0.5, accuracy: 0.001)
    }

    // Production break caught: a temporary read failure deletes the generation baseline needed for recovery.
    func testTemporaryFailureKeepsBaselineAndRecoveryUsesTheBoundedInterval() async throws {
        let service = makeService(
            results: [
                .success(reading(energy: 1_000)),
                .failure(.exited),
                .success(reading(energy: 7_000)),
            ],
            times: [0, 3, 6]
        )

        _ = await service.observe(limit: 1)
        let failed = try require(await service.observe(limit: 1).first)
        let recovered = try require(await service.observe(limit: 1).first)

        XCTAssertNotEqual(failed.status, .stable)
        XCTAssertEqual(try require(recovered.currentPowerMicrowatts), 1, accuracy: 0.001)
        XCTAssertEqual(recovered.status, .collecting)
    }

    // Production break caught: a baseline older than the ten-second bound still emits a diluted recovery value.
    func testFailurePastTenSecondsExpiresTheBaseline() async throws {
        let service = makeService(
            results: [
                .success(reading(energy: 1_000)),
                .failure(.permissionDenied),
                .success(reading(energy: 20_000)),
            ],
            times: [0, 3, 14]
        )

        _ = await service.observe(limit: 1)
        _ = await service.observe(limit: 1)
        let entry = try require(await service.observe(limit: 1).first)

        XCTAssertNil(entry.currentPowerMicrowatts)
        XCTAssertEqual(entry.status, .collecting)
    }

    // Production break caught: an unsupported zero-only counter is published forever as a confirmed zero.
    func testZeroEnergyCounterWithAdvancingCPUBecomesUnsupportedAfterTenSeconds() async throws {
        let service = makeService(
            results: [
                .success(reading(energy: 0, userCPU: 1_000, systemCPU: 100)),
                .success(reading(energy: 0, userCPU: 2_000, systemCPU: 100)),
                .success(reading(energy: 0, userCPU: 3_000, systemCPU: 100)),
                .success(reading(energy: 0, userCPU: 4_000, systemCPU: 100)),
                .success(reading(energy: 0, userCPU: 5_000, systemCPU: 100)),
            ],
            times: [0, 3, 6, 9, 12]
        )

        _ = await service.observe(limit: 1)
        _ = await service.observe(limit: 1)
        _ = await service.observe(limit: 1)
        let confirmedZero = try require(await service.observe(limit: 1).first)
        let entry = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(try require(confirmedZero.currentPowerMicrowatts), 0, accuracy: 0.001)
        XCTAssertEqual(confirmedZero.status, .collecting)
        XCTAssertNil(entry.currentPowerMicrowatts)
        XCTAssertNil(entry.rankingScore)
        XCTAssertEqual(entry.status, .unavailable)
        XCTAssertEqual(entry.coverage.discoveredProcessCount, 1)
        XCTAssertEqual(entry.coverage.readableProcessCount, 0)
    }

    // Production break caught: a rollback interval advances zero-counter evidence from an older retained baseline.
    func testClockRollbackAfterFailureRebaselinesZeroCounterEvidence() async throws {
        let service = makeService(
            results: [
                .success(reading(energy: 0, userCPU: 1_000)),
                .failure(.permissionDenied),
                .success(reading(energy: 0, userCPU: 2_000)),
                .success(reading(energy: 0, userCPU: 3_000)),
            ],
            times: [0, 3, 2, 11]
        )

        _ = await service.observe(limit: 1)
        _ = await service.observe(limit: 1)
        let rebaselined = try require(await service.observe(limit: 1).first)
        let validInterval = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(rebaselined.status, .collecting)
        XCTAssertNil(rebaselined.currentPowerMicrowatts)
        XCTAssertEqual(validInterval.status, .collecting)
        XCTAssertEqual(try require(validInterval.currentPowerMicrowatts), 0, accuracy: 0.001)
    }

    // Production break caught: a failed rollback leaves a future baseline connected to the next clock epoch.
    func testFailedRollbackInvalidatesRetainedBaselineContinuity() async throws {
        let service = makeService(
            results: [
                .success(reading(energy: 1_000)),
                .failure(.permissionDenied),
                .success(reading(energy: 4_000)),
            ],
            times: [10, 5, 12]
        )

        _ = await service.observe(limit: 1)
        _ = await service.observe(limit: 1)
        let afterRollback = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(afterRollback.status, .collecting)
        XCTAssertNil(afterRollback.currentPowerMicrowatts)
        XCTAssertEqual(afterRollback.coverage.validProcessSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(afterRollback.coverage.discoveredProcessSeconds, 7, accuracy: 0.001)
    }

    // Production break caught: a helper delta spanning an owner change is assigned to the new root.
    func testOwnerChangeDiscardsTheTransitionInterval() async {
        let service = makeReparentingService(
            ownersBySample: [100, 200],
            energies: [1_000, 9_000],
            times: [0, 3]
        )

        _ = await service.observe(limit: 2)
        let entries = await service.observe(limit: 2)

        XCTAssertTrue(entries.allSatisfy { $0.currentPowerMicrowatts == nil })
        XCTAssertTrue(entries.allSatisfy { $0.status != .stable })
    }

    // Production break caught: a failed owner excursion is erased when the helper returns to its old root.
    func testUnreadableOwnerExcursionBreaksRecoveredHelperContinuity() async throws {
        let service = EnergyImpactSamplerTestSession(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: [
                    .failure(.permissionDenied),
                    .failure(.permissionDenied),
                    .failure(.permissionDenied),
                ],
                200: [
                    .failure(.permissionDenied),
                    .failure(.permissionDenied),
                    .failure(.permissionDenied),
                ],
                300: [
                    .success(reading(energy: 1_000, start: 30)),
                    .failure(.permissionDenied),
                    .success(reading(energy: 7_000, start: 30)),
                ],
            ]),
            processSnapshotReader: SequencedProcessParentSnapshotReaderStub(snapshotsByCall: [
                [.init(processIdentifier: 300, parentProcessIdentifier: 100)],
                [.init(processIdentifier: 300, parentProcessIdentifier: 200)],
                [.init(processIdentifier: 300, parentProcessIdentifier: 100)],
            ]),
            appSnapshotProvider: { [
                .init(processIdentifier: 100, name: "First", bundleIdentifier: nil, bundleURL: nil),
                .init(processIdentifier: 200, name: "Second", bundleIdentifier: nil, bundleURL: nil),
            ] },
            clock: EnergyImpactClockStub(times: [0, 3, 6])
        )

        _ = await service.observe(limit: 2)
        _ = await service.observe(limit: 2)
        let entries = await service.observe(limit: 2)
        let returnedOwner = try require(entries.first { $0.processIdentifier == 100 })

        XCTAssertEqual(returnedOwner.status, .collecting)
        XCTAssertNil(returnedOwner.currentPowerMicrowatts)
        XCTAssertEqual(returnedOwner.coverage.validProcessSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(returnedOwner.coverage.discoveredProcessSeconds, 6, accuracy: 0.001)
    }

    // Production break caught: an observed helper temporarily outside every regular root reconnects to its old baseline.
    func testObservedUnownedHelperBreaksRecoveredContinuity() async throws {
        let service = EnergyImpactSamplerTestSession(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: [
                    .failure(.permissionDenied),
                    .failure(.permissionDenied),
                    .failure(.permissionDenied),
                ],
                300: [
                    .success(reading(energy: 1_000, start: 30)),
                    .success(reading(energy: 7_000, start: 30)),
                ],
            ]),
            processSnapshotReader: SequencedProcessParentSnapshotReaderStub(snapshotsByCall: [
                [.init(processIdentifier: 300, parentProcessIdentifier: 100)],
                [.init(processIdentifier: 300, parentProcessIdentifier: 999)],
                [.init(processIdentifier: 300, parentProcessIdentifier: 100)],
            ]),
            appSnapshotProvider: { [
                .init(processIdentifier: 100, name: "Fixture", bundleIdentifier: nil, bundleURL: nil),
            ] },
            clock: EnergyImpactClockStub(times: [0, 3, 6])
        )

        _ = await service.observe(limit: 1)
        _ = await service.observe(limit: 1)
        let returned = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(returned.status, .collecting)
        XCTAssertNil(returned.currentPowerMicrowatts)
        XCTAssertEqual(returned.coverage.validProcessSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(returned.coverage.discoveredProcessSeconds, 6, accuracy: 0.001)
    }

    // Production break caught: recovered helper energy uses six seconds of numerator against three seconds of PID-time.
    func testRootAndRecoveredHelperUseMatchingIntervalEnergyAndCoverage() async throws {
        let service = makeMixedGapService(
            rootEnergies: [1_000, 4_000, 7_000],
            helperResults: [
                .success(reading(energy: 1_000, start: 11)),
                .failure(.permissionDenied),
                .success(reading(energy: 7_000, start: 11)),
            ],
            times: [0, 3, 6]
        )

        _ = await service.observe(limit: 1)
        _ = await service.observe(limit: 1)
        let recovered = try require(await service.observe(limit: 1).first)

        let smoothingAlpha = 1 - pow(0.5, 3.0 / 4.0)
        XCTAssertEqual(
            try require(recovered.currentPowerMicrowatts),
            1 + smoothingAlpha,
            accuracy: 0.001
        )
        XCTAssertEqual(recovered.status, .collecting)
        XCTAssertEqual(
            try require(recovered.sustainedPowerMicrowatts),
            2,
            accuracy: 0.001
        )
        XCTAssertEqual(recovered.coverage.validProcessSeconds, 12, accuracy: 0.001)
        XCTAssertEqual(recovered.coverage.discoveredProcessSeconds, 12, accuracy: 0.001)
    }

    // Production break caught: recovery merges changing discovery counts before rolling-window trimming.
    func testRecoveryPreservesDiscoveryIntervalsAtTheSustainedWindowCutoff() async throws {
        let service = EnergyImpactSamplerTestSession(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: [
                    .success(reading(energy: 0)),
                    .failure(.permissionDenied),
                    .failure(.permissionDenied),
                    .success(reading(energy: 9_000)),
                    .success(reading(energy: 12_000)),
                    .success(reading(energy: 15_000)),
                    .success(reading(energy: 18_000)),
                    .success(reading(energy: 21_000)),
                    .success(reading(energy: 24_000)),
                    .success(reading(energy: 27_000)),
                    .success(reading(energy: 30_000)),
                    .success(reading(energy: 33_000)),
                ],
                101: [.failure(.permissionDenied)],
                102: [.failure(.permissionDenied)],
            ]),
            processSnapshotReader: SequencedProcessParentSnapshotReaderStub(
                snapshotsByCall: [
                    [],
                    [
                        .init(processIdentifier: 101, parentProcessIdentifier: 100),
                        .init(processIdentifier: 102, parentProcessIdentifier: 100),
                    ],
                    [], [], [], [], [], [], [], [], [], [],
                ]
            ),
            appSnapshotProvider: { [
                .init(
                    processIdentifier: 100,
                    name: "Fixture",
                    bundleIdentifier: nil,
                    bundleURL: nil
                ),
            ] },
            clock: EnergyImpactClockStub(
                times: [0, 3, 6, 9, 12, 15, 18, 21, 24, 27, 30, 33]
            )
        )

        var finalEntry: EnergyImpactEntry?
        for _ in 0..<12 {
            finalEntry = await service.observe(limit: 1).first
        }
        let entry = try require(finalEntry)

        XCTAssertEqual(entry.observedWindowSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(entry.coverage.validProcessSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(entry.coverage.discoveredProcessSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(entry.coverage.fraction, 1, accuracy: 0.001)
        XCTAssertEqual(entry.status, .stable)
    }

    // Production break caught: stale output loses the confirmed root generation or refreshes its own grace window.
    func testStableFailureRecoverySequencePreservesFullIdentityWithoutConfirmingStale() async throws {
        let service = makeService(
            results: [
                .success(reading(energy: 1_000, start: 10)),
                .success(reading(energy: 4_000, start: 10)),
                .failure(.permissionDenied),
                .success(reading(energy: 10_000, start: 10)),
            ],
            times: [0, 3, 6, 9]
        )

        let collecting = try require(await service.observe(limit: 1).first)
        let stable = try require(await service.observe(limit: 1).first)
        let stale = try require(await service.observe(limit: 1).first)
        let recovered = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(collecting.status, .collecting)
        XCTAssertEqual(stable.status, .collecting)
        XCTAssertEqual(stable.currentPowerMicrowatts, 1)
        XCTAssertEqual(stale.status, .stale)
        XCTAssertEqual(stale.identity, stable.identity)
        XCTAssertEqual(stale.currentPowerMicrowatts, stable.currentPowerMicrowatts)
        XCTAssertEqual(stale.coverage, stable.coverage)
        XCTAssertNil(stale.rankingScore)
        XCTAssertEqual(recovered.status, .collecting)
        XCTAssertEqual(recovered.identity, stable.identity)
        XCTAssertEqual(try require(recovered.currentPowerMicrowatts), 1, accuracy: 0.001)
    }

    // Production break caught: publishing stale repeatedly extends a three-second observation past ten seconds.
    func testStalePublicationDoesNotExtendItsOwnGrace() async throws {
        let service = makeService(
            results: [
                .success(reading(energy: 1_000)),
                .success(reading(energy: 4_000)),
                .failure(.permissionDenied),
                .failure(.permissionDenied),
                .failure(.permissionDenied),
            ],
            times: [0, 3, 6, 12, 14]
        )

        _ = await service.observe(limit: 1)
        _ = await service.observe(limit: 1)
        let firstStale = await service.observe(limit: 1).first
        let secondStale = await service.observe(limit: 1).first
        XCTAssertEqual(firstStale?.status, .stale)
        XCTAssertEqual(secondStale?.status, .stale)
        let expired = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(expired.status, .collecting)
        XCTAssertNil(expired.currentPowerMicrowatts)
    }

    func testRootGenerationRemainsConfirmedAtMaximumGapBoundary() async throws {
        let service = makeService(
            results: [
                .success(reading(energy: 1_000)),
                .success(reading(energy: 4_000)),
                .failure(.permissionDenied),
            ],
            times: [0, 3, 13]
        )

        _ = await service.observe(limit: 1)
        let stable = try require(await service.observe(limit: 1).first)
        let atBoundary = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(stable.status, .collecting)
        XCTAssertEqual(stable.identity.rootProcessStartAbsoluteTime, 10)
        XCTAssertEqual(atBoundary.status, .stale)
        XCTAssertEqual(atBoundary.identity.rootProcessStartAbsoluteTime, 10)
        XCTAssertEqual(atBoundary.currentPowerMicrowatts, 1)
    }

    // Production break caught: a successful root generation change reuses the prior generation's stale display.
    func testRootGenerationChangeImmediatelyDiscardsOldDisplay() async throws {
        let service = makeTwoProcessService(
            rootResults: [
                .success(reading(energy: 1_000, start: 10)),
                .success(reading(energy: 4_000, start: 10)),
                .success(reading(energy: 1_000, start: 20)),
                .failure(.permissionDenied),
            ],
            helperResults: [
                .success(reading(energy: 1_000, start: 11)),
                .success(reading(energy: 4_000, start: 11)),
                .success(reading(energy: 7_000, start: 11)),
                .failure(.permissionDenied),
            ],
            times: [0, 3, 6, 9]
        )

        _ = await service.observe(limit: 1)
        let old = try require(await service.observe(limit: 1).first)
        let changed = try require(await service.observe(limit: 1).first)
        let stale = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(old.status, .collecting)
        XCTAssertEqual(old.identity.rootProcessStartAbsoluteTime, 10)
        XCTAssertEqual(changed.identity.rootProcessStartAbsoluteTime, 20)
        XCTAssertEqual(changed.status, .collecting)
        XCTAssertNil(changed.currentPowerMicrowatts)
        XCTAssertEqual(stale.status, .unavailable)
        XCTAssertEqual(stale.identity.rootProcessStartAbsoluteTime, 20)
        XCTAssertNil(stale.currentPowerMicrowatts)
    }

    // Production break caught: helper-only partial samples renew an expired root generation.
    func testPartialDescendantSamplesDoNotExtendRootGenerationPastConfirmationGap() async throws {
        let service = makeTwoProcessService(
            rootResults: [
                .success(reading(energy: 1_000, start: 10)),
                .success(reading(energy: 4_000, start: 10)),
                .failure(.permissionDenied),
                .failure(.permissionDenied),
                .failure(.permissionDenied),
                .failure(.permissionDenied),
            ],
            helperResults: [
                .success(reading(energy: 1_000, start: 11)),
                .success(reading(energy: 4_000, start: 11)),
                .success(reading(energy: 7_000, start: 11)),
                .success(reading(energy: 10_000, start: 11)),
                .success(reading(energy: 13_000, start: 11)),
                .success(reading(energy: 16_000, start: 11)),
            ],
            times: [0, 3, 6, 9, 12, 15]
        )

        _ = await service.observe(limit: 1)
        let confirmed = try require(await service.observe(limit: 1).first)
        _ = await service.observe(limit: 1)
        _ = await service.observe(limit: 1)
        let withinConfirmationGap = try require(await service.observe(limit: 1).first)
        let expired = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(confirmed.status, .collecting)
        XCTAssertEqual(confirmed.identity.rootProcessStartAbsoluteTime, 10)
        XCTAssertEqual(withinConfirmationGap.status, .collecting)
        XCTAssertEqual(withinConfirmationGap.identity.rootProcessStartAbsoluteTime, 10)
        XCTAssertNotNil(withinConfirmationGap.currentPowerMicrowatts)
        XCTAssertEqual(expired.status, .collecting)
        XCTAssertNil(expired.identity.rootProcessStartAbsoluteTime)
        XCTAssertEqual(expired.currentPowerMicrowatts, 1)
        XCTAssertEqual(expired.coverage.validProcessSeconds, 3)
        XCTAssertEqual(expired.coverage.discoveredProcessSeconds, 6)
    }

    // Production break caught: an expired root locator assigns helper-only data to a reused PID's old generation.
    func testExpiredRootLocatorDoesNotLabelReusedPIDHelperDataWithOldGeneration() async throws {
        let service = EnergyImpactSamplerTestSession(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: [
                    .success(reading(energy: 1_000, start: 10)),
                    .success(reading(energy: 4_000, start: 10)),
                    .failure(.permissionDenied),
                    .failure(.permissionDenied),
                    .success(reading(energy: 1_000, start: 20)),
                ],
                300: [
                    .success(reading(energy: 1_000, start: 30)),
                    .success(reading(energy: 4_000, start: 30)),
                    .success(reading(energy: 7_000, start: 30)),
                ],
            ]),
            processSnapshotReader: SequencedProcessParentSnapshotReaderStub(snapshotsByCall: [
                [],
                [],
                [.init(processIdentifier: 300, parentProcessIdentifier: 100)],
                [.init(processIdentifier: 300, parentProcessIdentifier: 100)],
                [.init(processIdentifier: 300, parentProcessIdentifier: 100)],
            ]),
            appSnapshotProvider: { [
                .init(processIdentifier: 100, name: "Reused", bundleIdentifier: nil, bundleURL: nil),
            ] },
            clock: EnergyImpactClockStub(times: [0, 3, 14, 17, 20])
        )

        _ = await service.observe(limit: 1)
        let old = try require(await service.observe(limit: 1).first)
        let expired = try require(await service.observe(limit: 1).first)
        let helperOnly = try require(await service.observe(limit: 1).first)
        let established = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(old.status, .collecting)
        XCTAssertEqual(old.identity.rootProcessStartAbsoluteTime, 10)
        XCTAssertEqual(expired.status, .collecting)
        XCTAssertNil(expired.identity.rootProcessStartAbsoluteTime)
        XCTAssertEqual(helperOnly.status, .collecting)
        XCTAssertEqual(helperOnly.currentPowerMicrowatts, 1)
        XCTAssertNil(helperOnly.identity.rootProcessStartAbsoluteTime)
        XCTAssertEqual(established.status, .collecting)
        XCTAssertEqual(established.identity.rootProcessStartAbsoluteTime, 20)
    }

    // Production break caught: stale wins when only some PIDs are unsupported, or survives when all are unsupported.
    func testAllExplicitlyUnsupportedProcessesOverrideBoundedStaleDisplay() async throws {
        let service = makeTwoProcessService(
            rootResults: [
                .success(reading(energy: 1_000)),
                .success(reading(energy: 4_000)),
                .failure(.unsupported),
                .failure(.unsupported),
            ],
            helperResults: [
                .success(reading(energy: 1_000, start: 11)),
                .success(reading(energy: 4_000, start: 11)),
                .failure(.permissionDenied),
                .failure(.unsupported),
            ],
            times: [0, 3, 6, 9]
        )

        _ = await service.observe(limit: 1)
        let stable = await service.observe(limit: 1).first
        XCTAssertEqual(stable?.status, .collecting)
        let mixed = try require(await service.observe(limit: 1).first)
        let unsupported = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(mixed.status, .stale)
        XCTAssertEqual(mixed.currentPowerMicrowatts, 2)
        XCTAssertEqual(unsupported.status, .unavailable)
        XCTAssertNil(unsupported.currentPowerMicrowatts)
        XCTAssertNil(unsupported.rankingScore)
    }

    func testHelperMoveRebaselinesBothRootsWithoutTransitionAttribution() async throws {
        let service = EnergyImpactSamplerTestSession(
            reader: ProcessEnergyReadingProviderStub(results: [
                100: Array(repeating: .failure(.permissionDenied), count: 3),
                200: Array(repeating: .failure(.permissionDenied), count: 3),
                300: [
                    .success(reading(energy: 1_000, start: 30)),
                    .success(reading(energy: 4_000, start: 30)),
                    .success(reading(energy: 7_000, start: 30)),
                ],
            ]),
            processSnapshotReader: SequencedProcessParentSnapshotReaderStub(snapshotsByCall: [
                [.init(processIdentifier: 300, parentProcessIdentifier: 100)],
                [.init(processIdentifier: 300, parentProcessIdentifier: 200)],
                [.init(processIdentifier: 300, parentProcessIdentifier: 200)],
            ]),
            appSnapshotProvider: { [
                .init(processIdentifier: 100, name: "First", bundleIdentifier: nil, bundleURL: nil),
                .init(processIdentifier: 200, name: "Second", bundleIdentifier: nil, bundleURL: nil),
            ] },
            clock: EnergyImpactClockStub(times: [0, 3, 6])
        )

        let first = Dictionary(uniqueKeysWithValues: await service.observe(limit: 2).map {
            ($0.processIdentifier, $0)
        })
        let moved = Dictionary(uniqueKeysWithValues: await service.observe(limit: 2).map {
            ($0.processIdentifier, $0)
        })
        let settled = Dictionary(uniqueKeysWithValues: await service.observe(limit: 2).map {
            ($0.processIdentifier, $0)
        })

        func assertNonnumeric(
            _ row: EnergyImpactEntry,
            status: EnergyImpactStatus,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(row.status, status, file: file, line: line)
            XCTAssertNil(row.currentPowerMicrowatts, file: file, line: line)
            XCTAssertNil(row.sustainedPowerMicrowatts, file: file, line: line)
            XCTAssertNil(row.rankingScore, file: file, line: line)
        }

        assertNonnumeric(try require(first[100]), status: .collecting)
        assertNonnumeric(try require(first[200]), status: .collecting)
        assertNonnumeric(try require(moved[100]), status: .collecting)
        assertNonnumeric(try require(moved[200]), status: .collecting)
        assertNonnumeric(try require(settled[100]), status: .collecting)

        let settledSecondRoot = try require(settled[200])
        XCTAssertEqual(settledSecondRoot.status, .collecting)
        XCTAssertEqual(
            try require(settledSecondRoot.currentPowerMicrowatts),
            1,
            accuracy: 0.001
        )
        XCTAssertNil(settledSecondRoot.sustainedPowerMicrowatts)
        XCTAssertNil(settledSecondRoot.rankingScore)
    }

    func testHelperDisappearancePreservesSameGenerationOwnerContinuityWithinGap() async throws {
        let reader = ProcessEnergyReadingProviderStub(results: [
            100: Array(repeating: .failure(.permissionDenied), count: 3),
            300: [
                .success(reading(energy: 1_000, start: 30)),
                .success(reading(energy: 7_000, start: 30)),
            ],
        ])
        let service = EnergyImpactSamplerTestSession(
            reader: reader,
            processSnapshotReader: SequencedProcessParentSnapshotReaderStub(snapshotsByCall: [
                [.init(processIdentifier: 300, parentProcessIdentifier: 100)],
                [],
                [.init(processIdentifier: 300, parentProcessIdentifier: 100)],
            ]),
            appSnapshotProvider: { [
                .init(processIdentifier: 100, name: "Root", bundleIdentifier: nil, bundleURL: nil),
            ] },
            clock: EnergyImpactClockStub(times: [0, 3, 6])
        )

        _ = await service.observe(limit: 1)
        _ = await service.observe(limit: 1)
        let recovered = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(reader.readCount(for: 100), 3)
        XCTAssertEqual(reader.readCount(for: 300), 2)
        XCTAssertEqual(recovered.status, .collecting)
        XCTAssertEqual(try require(recovered.currentPowerMicrowatts), 1, accuracy: 0.001)
        XCTAssertEqual(recovered.coverage.validProcessSeconds, 3, accuracy: 0.001)
        XCTAssertEqual(recovered.coverage.discoveredProcessSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(recovered.coverage.fraction, 0.5, accuracy: 0.001)
    }

    func testReorderedEquivalentSnapshotPreservesContinuity() async throws {
        func makeService(snapshots: [[ProcessParentSnapshot]]) -> EnergyImpactSamplerTestSession {
            EnergyImpactSamplerTestSession(
                reader: ProcessEnergyReadingProviderStub(readings: [
                    100: [reading(energy: 1_000), reading(energy: 4_000)],
                    300: [reading(energy: 2_000, start: 30), reading(energy: 5_000, start: 30)],
                ]),
                processSnapshotReader: SequencedProcessParentSnapshotReaderStub(
                    snapshotsByCall: snapshots
                ),
                appSnapshotProvider: {
                    [.init(processIdentifier: 100, name: "Root", bundleIdentifier: nil, bundleURL: nil)]
                },
                clock: EnergyImpactClockStub(times: [0, 3])
            )
        }
        let ordered = makeService(snapshots: [
            [
                .init(processIdentifier: 100, parentProcessIdentifier: 1),
                .init(processIdentifier: 300, parentProcessIdentifier: 100),
            ],
            [
                .init(processIdentifier: 100, parentProcessIdentifier: 1),
                .init(processIdentifier: 300, parentProcessIdentifier: 100),
            ],
        ])
        let reordered = makeService(snapshots: [
            [
                .init(processIdentifier: 100, parentProcessIdentifier: 1),
                .init(processIdentifier: 300, parentProcessIdentifier: 100),
            ],
            [
                .init(processIdentifier: 300, parentProcessIdentifier: 100),
                .init(processIdentifier: 100, parentProcessIdentifier: 1),
            ],
        ])

        _ = await ordered.observe(limit: 1)
        let expected = try require(await ordered.observe(limit: 1).first)
        _ = await reordered.observe(limit: 1)
        let actual = try require(await reordered.observe(limit: 1).first)

        XCTAssertEqual(actual.status, .collecting)
        XCTAssertEqual(actual.currentPowerMicrowatts, expected.currentPowerMicrowatts)
        XCTAssertEqual(actual.coverage, expected.coverage)
    }

    func testNestedRegularRootsRemainNearestOwnerAfterReorder() async throws {
        let reader = ProcessEnergyReadingProviderStub(readings: [
            100: [reading(energy: 1_000, start: 10), reading(energy: 4_000, start: 10)],
            200: [reading(energy: 2_000, start: 20), reading(energy: 5_000, start: 20)],
            300: [reading(energy: 3_000, start: 30), reading(energy: 6_000, start: 30)],
        ])
        let service = EnergyImpactSamplerTestSession(
            reader: reader,
            processSnapshotReader: SequencedProcessParentSnapshotReaderStub(snapshotsByCall: [
                [
                    .init(processIdentifier: 100, parentProcessIdentifier: 1),
                    .init(processIdentifier: 200, parentProcessIdentifier: 100),
                    .init(processIdentifier: 300, parentProcessIdentifier: 200),
                ],
                [
                    .init(processIdentifier: 300, parentProcessIdentifier: 200),
                    .init(processIdentifier: 200, parentProcessIdentifier: 100),
                    .init(processIdentifier: 100, parentProcessIdentifier: 1),
                ],
            ]),
            appSnapshotProvider: { [
                .init(processIdentifier: 100, name: "Outer", bundleIdentifier: nil, bundleURL: nil),
                .init(processIdentifier: 200, name: "Inner", bundleIdentifier: nil, bundleURL: nil),
            ] },
            clock: EnergyImpactClockStub(times: [0, 3])
        )

        _ = await service.observe(limit: 2)
        let entries = Dictionary(uniqueKeysWithValues: await service.observe(limit: 2).map {
            ($0.processIdentifier, $0)
        })

        let outer = try require(entries[100])
        let inner = try require(entries[200])
        XCTAssertEqual(
            try require(outer.currentPowerMicrowatts),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try require(inner.currentPowerMicrowatts),
            2,
            accuracy: 0.001
        )
        XCTAssertEqual(reader.readCount(for: 100), 2)
        XCTAssertEqual(reader.readCount(for: 200), 2)
        XCTAssertEqual(reader.readCount(for: 300), 2)
    }

    func testPIDReuseAndLongGapRemainIndependentRebaselineEvents() async throws {
        let service = EnergyImpactSamplerTestSession(
            reader: ProcessEnergyReadingProviderStub(readings: [
                100: [
                    reading(energy: 1_000, start: 10),
                    reading(energy: 4_000, start: 10),
                    reading(energy: 1_000, start: 20),
                    reading(energy: 4_000, start: 20),
                    reading(energy: 7_000, start: 20),
                ],
            ]),
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            appSnapshotProvider: {
                [.init(processIdentifier: 100, name: "Root", bundleIdentifier: nil, bundleURL: nil)]
            },
            clock: EnergyImpactClockStub(times: [0, 3, 6, 17, 20])
        )

        let collecting = try require(await service.observe(limit: 1).first)
        let numeric = try require(await service.observe(limit: 1).first)
        let replacement = try require(await service.observe(limit: 1).first)
        let afterGap = try require(await service.observe(limit: 1).first)
        let recovered = try require(await service.observe(limit: 1).first)

        XCTAssertEqual(collecting.status, .collecting)
        XCTAssertEqual(numeric.status, .collecting)
        XCTAssertEqual(replacement.status, .collecting)
        XCTAssertNil(replacement.currentPowerMicrowatts)
        XCTAssertEqual(afterGap.status, .collecting)
        XCTAssertNil(afterGap.currentPowerMicrowatts)
        XCTAssertEqual(recovered.status, .collecting)
        XCTAssertEqual(try require(recovered.currentPowerMicrowatts), 1, accuracy: 0.001)
    }

    // Production break caught: a large stale numeric value outranks fresh stable or partial rows.
    func testEnergyImpactEntriesSortByStatusBucketBeforeNumericValue() async {
        let entries = [
            entry(processIdentifier: 1, name: "Unavailable", power: nil, status: .unavailable),
            entry(processIdentifier: 2, name: "Stale", power: 1_000, status: .stale),
            entry(processIdentifier: 3, name: "Collecting", power: nil, status: .collecting),
            entry(processIdentifier: 4, name: "Partial", power: 1, status: .partial),
            entry(processIdentifier: 5, name: "Stable", power: 2, status: .stable),
        ]

        XCTAssertEqual(
            sortedByImpact(entries, limit: 5).map(\.name),
            ["Stable", "Partial", "Stale", "Collecting", "Unavailable"]
        )
    }

    func testEnergyImpactEntriesSortTiesByName() async {
        let entries = [
            EnergyImpactEntry(
                identity: EnergyImpactAppIdentity(
                    rootProcessIdentifier: 101,
                    rootProcessStartAbsoluteTime: 10
                ),
                name: "Notes",
                bundleIdentifier: "com.apple.Notes",
                bundleURL: nil,
                currentPowerMicrowatts: 4.2,
                sustainedPowerMicrowatts: nil,
                rankingScore: 4.2,
                trend: .steady,
                coverage: .unavailable,
                status: .stable
            ),
            EnergyImpactEntry(
                identity: EnergyImpactAppIdentity(
                    rootProcessIdentifier: 102,
                    rootProcessStartAbsoluteTime: 11
                ),
                name: "Calendar",
                bundleIdentifier: "com.apple.iCal",
                bundleURL: nil,
                currentPowerMicrowatts: 4.2,
                sustainedPowerMicrowatts: nil,
                rankingScore: 4.2,
                trend: .steady,
                coverage: .unavailable,
                status: .stable
            ),
        ]

        XCTAssertEqual(sortedByImpact(entries, limit: 2).map(\.name), ["Calendar", "Notes"])
    }

    func testUnavailableEntriesStripNumericFieldsBeforeDeterministicOrdering() async {
        let numeric = entry(
            processIdentifier: 1,
            name: "Numeric",
            power: 1,
            status: .unavailable
        )
        let nonnumeric = entry(
            processIdentifier: 2,
            name: "Nonnumeric",
            power: nil,
            status: .unavailable
        )

        XCTAssertEqual(
            sortedByImpact([numeric, nonnumeric], limit: 2)
                .map(\.processIdentifier),
            [2, 1]
        )
        XCTAssertEqual(
            sortedByImpact([nonnumeric, numeric], limit: 2)
                .map(\.processIdentifier),
            [2, 1]
        )
    }

    func testSameNameSameScoreSortsByProcessIdentifier() async {
        let entries = [
            entry(processIdentifier: 2, name: "Same", power: 4.2, status: .stable),
            entry(processIdentifier: 1, name: "Same", power: 4.2, status: .stable),
        ]

        XCTAssertEqual(
            sortedByImpact(entries, limit: 2).map(\.processIdentifier),
            [1, 2]
        )
    }
}

private actor ConcurrentObservationStartBarrier {
    private let participantCount: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(participantCount: Int) {
        precondition(participantCount > 1)
        self.participantCount = participantCount
    }

    func arriveAndWait() async {
        precondition(
            isReleased == false,
            "ConcurrentObservationStartBarrier is one-shot"
        )

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            guard waiters.count == participantCount else { return }

            isReleased = true
            let ready = waiters
            waiters.removeAll()
            ready.forEach { $0.resume() }
        }
    }
}

@MainActor
private final class EnergyImpactSamplerTestSession {
    private let sampler: EnergyImpactSampler
    private let appSnapshotProvider: () -> [EnergyImpactAppSnapshot]
    private var lease: EnergyImpactSamplingLease?

    init(
        reader: any ProcessEnergyReadingProvider,
        processSnapshotReader: any ProcessParentSnapshotReading,
        appSnapshotProvider: @escaping () -> [EnergyImpactAppSnapshot] = { [] },
        clock: any EnergyImpactClock = SystemEnergyImpactClock(),
        configuration: EnergyImpactConfiguration = .production
    ) {
        sampler = EnergyImpactSampler(
            reader: reader,
            processSnapshotReader: processSnapshotReader,
            clock: clock,
            configuration: configuration
        )
        self.appSnapshotProvider = appSnapshotProvider
    }

    func observe(limit: Int) async -> [EnergyImpactEntry] {
        if lease == nil {
            lease = await sampler.beginSession(.init(generation: 1))
        }
        guard let lease else { return [] }
        return await sampler.observe(
            lease: lease,
            apps: appSnapshotProvider(),
            limit: limit
        ) ?? []
    }
}

private final class EnergyImpactClockStub: EnergyImpactClock, @unchecked Sendable {
    private let lock = NSLock()
    private var times: [TimeInterval]

    init(times: [TimeInterval]) { self.times = times }

    func nowSeconds() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        precondition(times.isEmpty == false, "Clock fixture exhausted")
        return times.removeFirst()
    }
}

private final class ProcessEnergyReadingProviderStub: ProcessEnergyReadingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [pid_t: [ProcessEnergyReadResult]]
    private var readCounts: [pid_t: Int] = [:]
    private var totalReadCount = 0
    private var concurrentReads = 0
    private var recordedMaximumConcurrentReads = 0
    private let blockedReadNumber: Int?
    private let blockedReadEntered = DispatchSemaphore(value: 0)
    private let blockedReadRelease = DispatchSemaphore(value: 0)

    init(
        readings: [pid_t: [ProcessEnergyReading]],
        blockedReadNumber: Int? = nil
    ) {
        results = readings.mapValues { $0.map(ProcessEnergyReadResult.success) }
        self.blockedReadNumber = blockedReadNumber
    }

    init(
        results: [pid_t: [ProcessEnergyReadResult]],
        blockedReadNumber: Int? = nil
    ) {
        self.results = results
        self.blockedReadNumber = blockedReadNumber
    }

    func reading(for processIdentifier: pid_t) -> ProcessEnergyReadResult {
        lock.lock()
        totalReadCount += 1
        let currentReadNumber = totalReadCount
        readCounts[processIdentifier, default: 0] += 1
        concurrentReads += 1
        recordedMaximumConcurrentReads = max(
            recordedMaximumConcurrentReads,
            concurrentReads
        )
        lock.unlock()

        if currentReadNumber == blockedReadNumber {
            blockedReadEntered.signal()
            blockedReadRelease.wait()
        }

        lock.lock()
        let value: ProcessEnergyReadResult
        if var values = results[processIdentifier], values.isEmpty == false {
            value = values.removeFirst()
            results[processIdentifier] = values
        } else {
            value = .failure(.other(0))
        }
        concurrentReads -= 1
        lock.unlock()
        return value
    }

    func readCount(for processIdentifier: pid_t) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return readCounts[processIdentifier, default: 0]
    }

    var maximumConcurrentReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedMaximumConcurrentReads
    }

    func waitUntilBlocked() -> Bool {
        blockedReadEntered.wait(timeout: .now() + 2) == .success
    }

    func releaseBlockedRead() {
        blockedReadRelease.signal()
    }
}

private struct ProcessParentSnapshotReaderStub: ProcessParentSnapshotReading {
    let snapshotValues: [ProcessParentSnapshot]

    init(snapshots: [ProcessParentSnapshot]) {
        self.snapshotValues = snapshots
    }

    func snapshots() -> [ProcessParentSnapshot] {
        snapshotValues
    }
}

private final class SequencedProcessParentSnapshotReaderStub: ProcessParentSnapshotReading, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotValuesByCall: [[ProcessParentSnapshot]]
    private var calls = 0

    init(snapshotsByCall: [[ProcessParentSnapshot]]) {
        snapshotValuesByCall = snapshotsByCall
    }

    func snapshots() -> [ProcessParentSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        precondition(snapshotValuesByCall.isEmpty == false, "Process snapshot fixture exhausted")
        calls += 1
        return snapshotValuesByCall.removeFirst()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}
