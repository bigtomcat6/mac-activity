import Darwin
import XCTest
@testable import MacActivityCore

@MainActor
final class EnergyImpactProviderTests: XCTestCase {
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
    ) -> EnergyImpactService {
        EnergyImpactService(
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
    ) -> EnergyImpactService {
        EnergyImpactService(
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
    ) -> EnergyImpactService {
        EnergyImpactService(
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
    ) -> EnergyImpactService {
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
            sustainedPowerMicrowatts: nil,
            rankingScore: power,
            trend: .steady,
            coverage: .unavailable,
            status: status
        )
    }

    func testEnergyImpactEntryRepresentsCollectingWithoutAFalseZero() {
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

    func testEnergyImpactCoverageUsesValidPIDTime() {
        let coverage = EnergyImpactCoverage(
            discoveredProcessCount: 4,
            readableProcessCount: 3,
            validProcessSeconds: 9,
            discoveredProcessSeconds: 12
        )

        XCTAssertEqual(coverage.fraction, 0.75, accuracy: 0.001)
    }

    func testEnergyImpactCoverageIsZeroWithoutDiscoveredPIDTime() {
        let coverage = EnergyImpactCoverage(
            discoveredProcessCount: 0,
            readableProcessCount: 0,
            validProcessSeconds: 0,
            discoveredProcessSeconds: 0
        )

        XCTAssertEqual(coverage.fraction, 0)
    }

    func testEnergyImpactServiceReportsPartialCoverageWhenOneDescendantHasNoValidDelta() throws {
        let app = EnergyImpactAppSnapshot(
            processIdentifier: 100,
            name: "Browser",
            bundleIdentifier: "com.example.browser",
            bundleURL: nil
        )
        let service = EnergyImpactService(
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

        _ = service.topApps(limit: 1)
        let entry = try XCTUnwrap(service.topApps(limit: 1).first)

        XCTAssertEqual(entry.status, .partial)
        XCTAssertEqual(entry.coverage.validProcessSeconds, 1)
        XCTAssertEqual(entry.coverage.discoveredProcessSeconds, 2)
        XCTAssertEqual(entry.coverage.fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(entry.currentPowerMicrowatts), 1, accuracy: 0.001)
    }

    func testSystemEnergyImpactClockProvidesMonotonicSeconds() {
        let clock = SystemEnergyImpactClock()
        let first = clock.nowSeconds()

        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThanOrEqual(clock.nowSeconds(), first)
    }

    func testDefaultWorkspaceSnapshotProviderBuildsEntriesFromRunningApplications() {
        let service = EnergyImpactService(
            reader: ProcessEnergyReadingProviderStub(readings: [:]),
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: [])
        )
        let entries = service.topApps(limit: 1)

        XCTAssertLessThanOrEqual(entries.count, 1)
    }

    func testEnergyImpactServiceUsesPreviousRefreshSnapshotsForImpact() throws {
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
        let service = EnergyImpactService(
            reader: reader,
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            appSnapshotProvider: { apps },
            clock: EnergyImpactClockStub(times: [100, 101])
        )

        let firstEntries = service.topApps(limit: 2)
        let secondEntries = service.topApps(limit: 2)

        XCTAssertTrue(firstEntries.allSatisfy { $0.status == .collecting })
        XCTAssertTrue(firstEntries.allSatisfy { $0.currentPowerMicrowatts == nil })
        XCTAssertEqual(secondEntries.map(\.name), ["Safari", "Notes"])
        XCTAssertEqual(try XCTUnwrap(secondEntries[0].currentPowerMicrowatts), 2.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(secondEntries[1].currentPowerMicrowatts), 0.3, accuracy: 0.001)
        XCTAssertEqual(reader.readCount(for: 101), 2)
        XCTAssertEqual(reader.readCount(for: 102), 2)
    }

    func testEnergyImpactServiceNormalizesImpactByElapsedTime() throws {
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
        let service = EnergyImpactService(
            reader: reader,
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            appSnapshotProvider: { [app] },
            clock: EnergyImpactClockStub(times: [100, 100.5])
        )

        _ = service.topApps(limit: 1)
        let entries = service.topApps(limit: 1)

        XCTAssertEqual(try XCTUnwrap(entries.first?.currentPowerMicrowatts), 5.0, accuracy: 0.001)
    }

    func testEnergyImpactServiceAggregatesDescendantEnergyIntoOwningApp() throws {
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
        let service = EnergyImpactService(
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

        _ = service.topApps(limit: 1)
        let entries = service.topApps(limit: 1)

        XCTAssertEqual(try XCTUnwrap(entries.first?.currentPowerMicrowatts), 2.5, accuracy: 0.001)
        XCTAssertEqual(reader.readCount(for: 100), 2)
        XCTAssertEqual(reader.readCount(for: 101), 2)
        XCTAssertEqual(reader.readCount(for: 102), 2)
        XCTAssertEqual(reader.readCount(for: 999), 0)
    }

    func testEnergyImpactServiceAssignsNestedRegularRootProcessesToNearestRootExactlyOnce() throws {
        let apps = [
            EnergyImpactAppSnapshot(
                processIdentifier: 100,
                name: "Browser",
                bundleIdentifier: "com.example.browser",
                bundleURL: nil
            ),
            EnergyImpactAppSnapshot(
                processIdentifier: 200,
                name: "Nested App",
                bundleIdentifier: "com.example.nested",
                bundleURL: nil
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
        let service = EnergyImpactService(
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

        _ = service.topApps(limit: 2)
        let entries = service.topApps(limit: 2)
        let powerByProcess = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.processIdentifier, $0.currentPowerMicrowatts)
        })

        XCTAssertEqual(try XCTUnwrap(powerByProcess[100] ?? nil), 3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(powerByProcess[200] ?? nil), 7, accuracy: 0.001)
        XCTAssertEqual(reader.readCount(for: 100), 2)
        XCTAssertEqual(reader.readCount(for: 150), 2)
        XCTAssertEqual(reader.readCount(for: 200), 2)
        XCTAssertEqual(reader.readCount(for: 250), 2)
    }

    func testEnergyImpactServiceRejectsDeltasWhenPIDIsReused() {
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
        let service = EnergyImpactService(
            reader: reader,
            processSnapshotReader: ProcessParentSnapshotReaderStub(snapshots: []),
            appSnapshotProvider: { [app] },
            clock: EnergyImpactClockStub(times: [100, 101])
        )

        _ = service.topApps(limit: 1)
        let entries = service.topApps(limit: 1)

        XCTAssertEqual(entries.first?.status, .collecting)
        XCTAssertNil(entries.first?.currentPowerMicrowatts)
    }

    func testLongGapRebaselinesInsteadOfPublishingADilutedValue() {
        let clock = EnergyImpactClockStub(times: [0, 3, 20])
        let service = EnergyImpactService(
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

        _ = service.topApps(limit: 1)
        XCTAssertEqual(service.topApps(limit: 1).first?.currentPowerMicrowatts ?? -1, 1)
        let afterGap = service.topApps(limit: 1).first

        XCTAssertNil(afterGap?.currentPowerMicrowatts)
        XCTAssertEqual(afterGap?.status, .collecting)
    }

    func testClockRollbackCannotProduceANegativeOrInfinitePower() {
        let clock = EnergyImpactClockStub(times: [3, 2])
        let service = EnergyImpactService(
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

        _ = service.topApps(limit: 1)
        let entry = service.topApps(limit: 1).first

        XCTAssertNil(entry?.currentPowerMicrowatts)
        XCTAssertEqual(entry?.status, .collecting)
    }

    func testEnergyImpactServiceKeepsUnreadableAppsAsUnavailableRows() {
        let reader = ProcessEnergyReadingProviderStub(readings: [:])
        let service = EnergyImpactService(
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
        let entries = service.topApps(limit: 1)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "Locked App")
        XCTAssertNil(entries[0].currentPowerMicrowatts)
        XCTAssertEqual(entries[0].status, .unavailable)
    }

    // Production break caught: an unreadable helper is collapsed into a false full-coverage value.
    func testOneUnreadableHelperProducesPartialCoverageWithoutAFalseZero() throws {
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

        _ = service.topApps(limit: 1)
        let entry = try XCTUnwrap(service.topApps(limit: 1).first)

        XCTAssertEqual(entry.status, .partial)
        XCTAssertEqual(try XCTUnwrap(entry.currentPowerMicrowatts), 1, accuracy: 0.001)
        XCTAssertEqual(entry.coverage.readableProcessCount, 1)
        XCTAssertEqual(entry.coverage.discoveredProcessCount, 2)
        XCTAssertEqual(entry.coverage.validProcessSeconds, 3, accuracy: 0.001)
        XCTAssertEqual(entry.coverage.discoveredProcessSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(entry.coverage.fraction, 0.5, accuracy: 0.001)
    }

    // Production break caught: a temporary read failure deletes the generation baseline needed for recovery.
    func testTemporaryFailureKeepsBaselineAndRecoveryUsesTheBoundedInterval() throws {
        let service = makeService(
            results: [
                .success(reading(energy: 1_000)),
                .failure(.exited),
                .success(reading(energy: 7_000)),
            ],
            times: [0, 3, 6]
        )

        _ = service.topApps(limit: 1)
        let failed = try XCTUnwrap(service.topApps(limit: 1).first)
        let recovered = try XCTUnwrap(service.topApps(limit: 1).first)

        XCTAssertNotEqual(failed.status, .stable)
        XCTAssertEqual(try XCTUnwrap(recovered.currentPowerMicrowatts), 1, accuracy: 0.001)
        XCTAssertEqual(recovered.status, .stable)
    }

    // Production break caught: a baseline older than the ten-second bound still emits a diluted recovery value.
    func testFailurePastTenSecondsExpiresTheBaseline() throws {
        let service = makeService(
            results: [
                .success(reading(energy: 1_000)),
                .failure(.permissionDenied),
                .success(reading(energy: 20_000)),
            ],
            times: [0, 3, 14]
        )

        _ = service.topApps(limit: 1)
        _ = service.topApps(limit: 1)
        let entry = try XCTUnwrap(service.topApps(limit: 1).first)

        XCTAssertNil(entry.currentPowerMicrowatts)
        XCTAssertEqual(entry.status, .collecting)
    }

    // Production break caught: an unsupported zero-only counter is published forever as a confirmed zero.
    func testZeroEnergyCounterWithAdvancingCPUBecomesUnsupportedAfterTenSeconds() throws {
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

        _ = service.topApps(limit: 1)
        _ = service.topApps(limit: 1)
        _ = service.topApps(limit: 1)
        let confirmedZero = try XCTUnwrap(service.topApps(limit: 1).first)
        let entry = try XCTUnwrap(service.topApps(limit: 1).first)

        XCTAssertEqual(try XCTUnwrap(confirmedZero.currentPowerMicrowatts), 0, accuracy: 0.001)
        XCTAssertEqual(confirmedZero.status, .stable)
        XCTAssertNil(entry.currentPowerMicrowatts)
        XCTAssertNil(entry.rankingScore)
        XCTAssertEqual(entry.status, .unavailable)
        XCTAssertEqual(entry.coverage.discoveredProcessCount, 1)
        XCTAssertEqual(entry.coverage.readableProcessCount, 0)
    }

    // Production break caught: a rollback interval advances zero-counter evidence from an older retained baseline.
    func testClockRollbackAfterFailureRebaselinesZeroCounterEvidence() throws {
        let service = makeService(
            results: [
                .success(reading(energy: 0, userCPU: 1_000)),
                .failure(.permissionDenied),
                .success(reading(energy: 0, userCPU: 2_000)),
                .success(reading(energy: 0, userCPU: 3_000)),
            ],
            times: [0, 3, 2, 11]
        )

        _ = service.topApps(limit: 1)
        _ = service.topApps(limit: 1)
        let rebaselined = try XCTUnwrap(service.topApps(limit: 1).first)
        let validInterval = try XCTUnwrap(service.topApps(limit: 1).first)

        XCTAssertEqual(rebaselined.status, .collecting)
        XCTAssertNil(rebaselined.currentPowerMicrowatts)
        XCTAssertEqual(validInterval.status, .stable)
        XCTAssertEqual(try XCTUnwrap(validInterval.currentPowerMicrowatts), 0, accuracy: 0.001)
    }

    // Production break caught: a failed rollback leaves a future baseline connected to the next clock epoch.
    func testFailedRollbackInvalidatesRetainedBaselineContinuity() throws {
        let service = makeService(
            results: [
                .success(reading(energy: 1_000)),
                .failure(.permissionDenied),
                .success(reading(energy: 4_000)),
            ],
            times: [10, 5, 12]
        )

        _ = service.topApps(limit: 1)
        _ = service.topApps(limit: 1)
        let afterRollback = try XCTUnwrap(service.topApps(limit: 1).first)

        XCTAssertEqual(afterRollback.status, .collecting)
        XCTAssertNil(afterRollback.currentPowerMicrowatts)
        XCTAssertEqual(afterRollback.coverage.validProcessSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(afterRollback.coverage.discoveredProcessSeconds, 7, accuracy: 0.001)
    }

    // Production break caught: a helper delta spanning an owner change is assigned to the new root.
    func testOwnerChangeDiscardsTheTransitionInterval() {
        let service = makeReparentingService(
            ownersBySample: [100, 200],
            energies: [1_000, 9_000],
            times: [0, 3]
        )

        _ = service.topApps(limit: 2)
        let entries = service.topApps(limit: 2)

        XCTAssertTrue(entries.allSatisfy { $0.currentPowerMicrowatts == nil })
        XCTAssertTrue(entries.allSatisfy { $0.status != .stable })
    }

    // Production break caught: a failed owner excursion is erased when the helper returns to its old root.
    func testUnreadableOwnerExcursionBreaksRecoveredHelperContinuity() throws {
        let service = EnergyImpactService(
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

        _ = service.topApps(limit: 2)
        _ = service.topApps(limit: 2)
        let entries = service.topApps(limit: 2)
        let returnedOwner = try XCTUnwrap(entries.first { $0.processIdentifier == 100 })

        XCTAssertEqual(returnedOwner.status, .collecting)
        XCTAssertNil(returnedOwner.currentPowerMicrowatts)
        XCTAssertEqual(returnedOwner.coverage.validProcessSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(returnedOwner.coverage.discoveredProcessSeconds, 6, accuracy: 0.001)
    }

    // Production break caught: an observed helper temporarily outside every regular root reconnects to its old baseline.
    func testObservedUnownedHelperBreaksRecoveredContinuity() throws {
        let service = EnergyImpactService(
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

        _ = service.topApps(limit: 1)
        _ = service.topApps(limit: 1)
        let returned = try XCTUnwrap(service.topApps(limit: 1).first)

        XCTAssertEqual(returned.status, .collecting)
        XCTAssertNil(returned.currentPowerMicrowatts)
        XCTAssertEqual(returned.coverage.validProcessSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(returned.coverage.discoveredProcessSeconds, 6, accuracy: 0.001)
    }

    // Production break caught: recovered helper energy uses six seconds of numerator against three seconds of PID-time.
    func testRootAndRecoveredHelperUseMatchingIntervalEnergyAndCoverage() throws {
        let service = makeMixedGapService(
            rootEnergies: [1_000, 4_000, 7_000],
            helperResults: [
                .success(reading(energy: 1_000, start: 11)),
                .failure(.permissionDenied),
                .success(reading(energy: 7_000, start: 11)),
            ],
            times: [0, 3, 6]
        )

        _ = service.topApps(limit: 1)
        _ = service.topApps(limit: 1)
        let recovered = try XCTUnwrap(service.topApps(limit: 1).first)

        XCTAssertEqual(try XCTUnwrap(recovered.currentPowerMicrowatts), 2, accuracy: 0.001)
        XCTAssertEqual(recovered.status, .stable)
        XCTAssertEqual(recovered.coverage.validProcessSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(recovered.coverage.discoveredProcessSeconds, 6, accuracy: 0.001)
    }

    // Production break caught: stale output loses the confirmed root generation or refreshes its own grace window.
    func testStableFailureRecoverySequencePreservesFullIdentityWithoutConfirmingStale() throws {
        let service = makeService(
            results: [
                .success(reading(energy: 1_000, start: 10)),
                .success(reading(energy: 4_000, start: 10)),
                .failure(.permissionDenied),
                .success(reading(energy: 10_000, start: 10)),
            ],
            times: [0, 3, 6, 9]
        )

        let collecting = try XCTUnwrap(service.topApps(limit: 1).first)
        let stable = try XCTUnwrap(service.topApps(limit: 1).first)
        let stale = try XCTUnwrap(service.topApps(limit: 1).first)
        let recovered = try XCTUnwrap(service.topApps(limit: 1).first)

        XCTAssertEqual(collecting.status, .collecting)
        XCTAssertEqual(stable.status, .stable)
        XCTAssertEqual(stable.currentPowerMicrowatts, 1)
        XCTAssertEqual(stale.status, .stale)
        XCTAssertEqual(stale.identity, stable.identity)
        XCTAssertEqual(stale.currentPowerMicrowatts, stable.currentPowerMicrowatts)
        XCTAssertEqual(stale.coverage, stable.coverage)
        XCTAssertNil(stale.rankingScore)
        XCTAssertEqual(recovered.status, .stable)
        XCTAssertEqual(recovered.identity, stable.identity)
        XCTAssertEqual(try XCTUnwrap(recovered.currentPowerMicrowatts), 1, accuracy: 0.001)
    }

    // Production break caught: publishing stale repeatedly extends a three-second observation past ten seconds.
    func testStalePublicationDoesNotExtendItsOwnGrace() throws {
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

        _ = service.topApps(limit: 1)
        _ = service.topApps(limit: 1)
        XCTAssertEqual(service.topApps(limit: 1).first?.status, .stale)
        XCTAssertEqual(service.topApps(limit: 1).first?.status, .stale)
        let expired = try XCTUnwrap(service.topApps(limit: 1).first)

        XCTAssertEqual(expired.status, .unavailable)
        XCTAssertNil(expired.currentPowerMicrowatts)
    }

    // Production break caught: a successful root generation change reuses the prior generation's stale display.
    func testRootGenerationChangeImmediatelyDiscardsOldDisplay() throws {
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

        _ = service.topApps(limit: 1)
        let old = try XCTUnwrap(service.topApps(limit: 1).first)
        let changed = try XCTUnwrap(service.topApps(limit: 1).first)
        let stale = try XCTUnwrap(service.topApps(limit: 1).first)

        XCTAssertEqual(old.status, .stable)
        XCTAssertEqual(old.identity.rootProcessStartAbsoluteTime, 10)
        XCTAssertEqual(changed.identity.rootProcessStartAbsoluteTime, 20)
        XCTAssertEqual(changed.status, .partial)
        XCTAssertEqual(changed.currentPowerMicrowatts, 1)
        XCTAssertEqual(stale.status, .stale)
        XCTAssertEqual(stale.identity.rootProcessStartAbsoluteTime, 20)
        XCTAssertEqual(stale.currentPowerMicrowatts, 1)
    }

    // Production break caught: an expired root locator assigns helper-only data to a reused PID's old generation.
    func testExpiredRootLocatorDoesNotLabelReusedPIDHelperDataWithOldGeneration() throws {
        let service = EnergyImpactService(
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

        _ = service.topApps(limit: 1)
        let old = try XCTUnwrap(service.topApps(limit: 1).first)
        let expired = try XCTUnwrap(service.topApps(limit: 1).first)
        let helperOnly = try XCTUnwrap(service.topApps(limit: 1).first)
        let established = try XCTUnwrap(service.topApps(limit: 1).first)

        XCTAssertEqual(old.status, .stable)
        XCTAssertEqual(old.identity.rootProcessStartAbsoluteTime, 10)
        XCTAssertEqual(expired.status, .collecting)
        XCTAssertNil(expired.identity.rootProcessStartAbsoluteTime)
        XCTAssertEqual(helperOnly.status, .partial)
        XCTAssertEqual(helperOnly.currentPowerMicrowatts, 1)
        XCTAssertNil(helperOnly.identity.rootProcessStartAbsoluteTime)
        XCTAssertEqual(established.status, .partial)
        XCTAssertEqual(established.identity.rootProcessStartAbsoluteTime, 20)
    }

    // Production break caught: stale wins when only some PIDs are unsupported, or survives when all are unsupported.
    func testAllExplicitlyUnsupportedProcessesOverrideBoundedStaleDisplay() throws {
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

        _ = service.topApps(limit: 1)
        XCTAssertEqual(service.topApps(limit: 1).first?.status, .stable)
        let mixed = try XCTUnwrap(service.topApps(limit: 1).first)
        let unsupported = try XCTUnwrap(service.topApps(limit: 1).first)

        XCTAssertEqual(mixed.status, .stale)
        XCTAssertEqual(mixed.currentPowerMicrowatts, 2)
        XCTAssertEqual(unsupported.status, .unavailable)
        XCTAssertNil(unsupported.currentPowerMicrowatts)
        XCTAssertNil(unsupported.rankingScore)
    }

    // Production break caught: a large stale numeric value outranks fresh stable or partial rows.
    func testEnergyImpactEntriesSortByStatusBucketBeforeNumericValue() {
        let entries = [
            entry(processIdentifier: 1, name: "Unavailable", power: nil, status: .unavailable),
            entry(processIdentifier: 2, name: "Stale", power: 1_000, status: .stale),
            entry(processIdentifier: 3, name: "Collecting", power: nil, status: .collecting),
            entry(processIdentifier: 4, name: "Partial", power: 1, status: .partial),
            entry(processIdentifier: 5, name: "Stable", power: 2, status: .stable),
        ]

        XCTAssertEqual(
            EnergyImpactService.sortedByImpact(entries, limit: 5).map(\.name),
            ["Stable", "Partial", "Stale", "Collecting", "Unavailable"]
        )
    }

    func testEnergyImpactEntriesSortTiesByName() {
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

        XCTAssertEqual(EnergyImpactService.sortedByImpact(entries, limit: 2).map(\.name), ["Calendar", "Notes"])
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
    private var results: [pid_t: [ProcessEnergyReadResult]]
    private var readCounts: [pid_t: Int] = [:]

    init(readings: [pid_t: [ProcessEnergyReading]]) {
        results = readings.mapValues { $0.map(ProcessEnergyReadResult.success) }
    }

    init(results: [pid_t: [ProcessEnergyReadResult]]) {
        self.results = results
    }

    func reading(for processIdentifier: pid_t) -> ProcessEnergyReadResult {
        readCounts[processIdentifier, default: 0] += 1
        guard var values = results[processIdentifier], values.isEmpty == false else {
            return .failure(.other(0))
        }
        let value = values.removeFirst()
        results[processIdentifier] = values
        return value
    }

    func readCount(for processIdentifier: pid_t) -> Int {
        readCounts[processIdentifier, default: 0]
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

    init(snapshotsByCall: [[ProcessParentSnapshot]]) {
        snapshotValuesByCall = snapshotsByCall
    }

    func snapshots() -> [ProcessParentSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        precondition(snapshotValuesByCall.isEmpty == false, "Process snapshot fixture exhausted")
        return snapshotValuesByCall.removeFirst()
    }
}
