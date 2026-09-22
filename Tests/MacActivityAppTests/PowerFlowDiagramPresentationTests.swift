import Foundation
import XCTest
@testable import MacActivityCore
@testable import MacActivityApp

@MainActor
final class PowerFlowDiagramPresentationTests: XCTestCase {
    func testUnknownIdentityWithExactPowerRemainsAnActiveSource() {
        let content = normalize(
            .init(
                id: "mystery",
                type: .unknownExternalInterface,
                direction: .input,
                measurement: .watts(12)
            )
        )

        XCTAssertEqual(content.sources.count, 1)
        XCTAssertEqual(content.sources.first?.kind, .unknown)
        XCTAssertEqual(content.sources.first?.measurement, .exact(12))
        XCTAssertEqual(content.sources.first?.provenance, .measured)
        XCTAssertFalse(content.issues.contains(.missingMeasurements))
    }

    func testKnownActiveEndpointWithUnavailablePowerIsPreservedAndFlagged() {
        let content = normalize(
            .init(id: "usb-c", type: .usbC, direction: .input, measurement: .unavailable)
        )

        XCTAssertEqual(content.sources.map(\.title), ["USB-C"])
        XCTAssertEqual(content.sources.map(\.measurement), [.unavailable])
        XCTAssertEqual(content.issues, [.missingMeasurements])
    }

    func testActiveZeroWattEndpointBecomesIdleAndCreatesNoActiveLane() {
        for direction in [PowerFlowDirection.input, .output, .idle] {
            let content = normalize(
                .init(id: "external", type: .usbC, direction: direction, measurement: .watts(0))
            )

            XCTAssertTrue(content.sources.isEmpty)
            XCTAssertTrue(content.sinks.isEmpty)
            XCTAssertEqual(content.idleEndpoints.map(\.measurement), [.idle])
            XCTAssertTrue(content.issues.isEmpty)
        }
    }

    func testIdleUnavailableEndpointDoesNotPretendToBeConfirmedZero() {
        let content = normalize(
            .init(id: "battery", type: .battery, direction: .idle, measurement: .unavailable)
        )

        XCTAssertTrue(content.sources.isEmpty)
        XCTAssertTrue(content.sinks.isEmpty)
        XCTAssertEqual(content.idleEndpoints.map(\.measurement), [.unavailable])
        XCTAssertEqual(content.issues, [.unresolvedIdleMeasurement])
    }

    func testNonFiniteAndNegativeDefensiveValuesBecomeUnavailable() {
        for value in [Double.nan, Double.infinity, -Double.infinity, -1.0] {
            let content = normalize(
                .init(id: "bad", type: .usbC, direction: .input, measurement: .watts(value))
            )

            XCTAssertEqual(content.sources.first?.measurement, .unavailable)
            XCTAssertTrue(content.issues.contains(.missingMeasurements))
        }
    }

    func testMacPowerIsMarkedDerived() {
        let content = normalize(
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(26.1))
        )

        XCTAssertEqual(content.sinks.first?.provenance, .derived)
        XCTAssertEqual(content.sinks.first?.measurement, .exact(26.1))
    }

    func testOrderingIsIndependentOfSnapshotOrder() {
        let endpoints = [
            PowerFlowDiagramFixtures.endpoint(
                "unknown", type: .unknownExternalInterface, direction: .input, measurement: .watts(30)
            ),
            PowerFlowDiagramFixtures.endpoint(
                "battery", type: .battery, direction: .input, measurement: .watts(24)
            ),
            PowerFlowDiagramFixtures.endpoint(
                "usb-low", type: .usbC, direction: .input, measurement: .watts(20)
            ),
            PowerFlowDiagramFixtures.endpoint(
                "usb-high", type: .usbC, direction: .input, measurement: .watts(45)
            ),
        ]

        let forward = normalized(endpoints)
        let reversed = normalized(Array(endpoints.reversed()))

        XCTAssertEqual(forward.sources, reversed.sources)
        XCTAssertEqual(
            forward.sources.map(\.measurement),
            [.exact(45), .exact(20), .exact(24), .exact(30)]
        )
    }

    func testDuplicateCoreIDsReceiveUniqueDeterministicRenderIDs() {
        let endpoints = [
            PowerFlowDiagramFixtures.endpoint(
                "duplicate", type: .usbC, direction: .input, measurement: .watts(45)
            ),
            PowerFlowDiagramFixtures.endpoint(
                "duplicate", type: .usbC, direction: .input, measurement: .watts(12)
            ),
        ]

        let forward = normalized(endpoints)
        let reversed = normalized(Array(endpoints.reversed()))

        XCTAssertEqual(forward.sources, reversed.sources)
        XCTAssertEqual(forward.sources.map(\.id), ["source:duplicate", "source:duplicate#2"])
        XCTAssertEqual(Set(forward.sources.map(\.id)).count, 2)
    }

    func testSideSummaryProducesExactLowerBoundAndUnavailableTotals() {
        let exact = PowerFlowDiagramPresentationBuilder.sideSummary(for: [
            node("one", .exact(20), .measured),
            node("two", .exact(24), .derived),
        ])
        let partial = PowerFlowDiagramPresentationBuilder.sideSummary(for: [
            node("one", .exact(20), .measured),
            node("two", .exact(24), .derived),
            node("three", .unavailable, .measured),
        ])
        let unavailable = PowerFlowDiagramPresentationBuilder.sideSummary(for: [
            node("four", .unavailable, .measured),
            node("five", .unavailable, .derived),
        ])

        XCTAssertEqual(exact.total, .exact(44))
        XCTAssertEqual(exact.provenance, .mixed)
        XCTAssertEqual(partial.total, .lowerBound(knownWatts: 44, unavailableCount: 1))
        XCTAssertEqual(partial.provenance, .mixed)
        XCTAssertEqual(partial.memberCount, 3)
        XCTAssertEqual(partial.representatives.map(\.id), ["one", "two"])
        XCTAssertEqual(unavailable.total, .unavailable)
    }

    func testExactSummaryOverflowBecomesUnavailableWithoutChangingMembers() {
        let one = node("one", .exact(Double.greatestFiniteMagnitude), .measured)
        let two = node("two", .exact(Double.greatestFiniteMagnitude), .derived)
        let summary = PowerFlowDiagramPresentationBuilder.sideSummary(for: [one, two])

        XCTAssertEqual(summary.total, .unavailable)
        XCTAssertEqual(summary.provenance, .mixed)
        XCTAssertEqual(summary.memberCount, 2)
        XCTAssertEqual(summary.representatives, [one, two])
    }

    func testLowerBoundSummaryOverflowBecomesUnavailableWithoutChangingMembers() {
        let one = node("one", .exact(Double.greatestFiniteMagnitude), .measured)
        let two = node("two", .exact(Double.greatestFiniteMagnitude), .measured)
        let summary = PowerFlowDiagramPresentationBuilder.sideSummary(for: [
            one, two, node("three", .unavailable, .measured),
        ])

        XCTAssertEqual(summary.total, .unavailable)
        XCTAssertEqual(summary.provenance, .measured)
        XCTAssertEqual(summary.memberCount, 3)
        XCTAssertEqual(summary.representatives, [one, two])
    }

    func testDuplicateSuffixesDoNotCollideWithRealIDsOnAnySide() {
        let cases: [(coreIDs: [String], renderIDs: [String])] = [
            (["duplicate", "duplicate", "duplicate#2"],
             ["duplicate", "duplicate#3", "duplicate#2"]),
            (["duplicate#2", "duplicate", "duplicate", "duplicate#3", "duplicate#2", "duplicate#2#2", "duplicate"],
             ["duplicate#2", "duplicate", "duplicate#4", "duplicate#3", "duplicate#2#3", "duplicate#2#2", "duplicate#5"]),
            (["", "", "#2", "source:", "source:", "source:#2"],
             ["", "#3", "#2", "source:", "source:#3", "source:#2"]),
        ]
        let sides: [(PowerFlowDirection, String)] = [
            (.input, "source"), (.output, "sink"), (.idle, "idle"),
        ]

        for (coreIDs, renderIDs) in cases {
            for (direction, prefix) in sides {
                let endpoints = coreIDs.enumerated().map { index, id in
                    PowerFlowDiagramFixtures.endpoint(
                        id,
                        type: .usbC,
                        direction: direction,
                        measurement: .watts(Double(coreIDs.count - index))
                    )
                }
                let content = normalized(endpoints)
                let nodes = content.sources + content.sinks + content.idleEndpoints

                XCTAssertEqual(content, normalized(Array(endpoints.reversed())))
                XCTAssertEqual(nodes.map(\.id), renderIDs.map { "\(prefix):\($0)" })
                XCTAssertEqual(Set(nodes.map(\.id)).count, coreIDs.count)
            }
        }
    }

    func testMappingPreservesSpecificTitlesAndDoesNotCreateSyntheticNodes() {
        let content = normalized([
            .init(id: "usb", type: .usbC, direction: .input, measurement: .watts(20)),
            .init(id: "mag", type: .magSafe, direction: .input, measurement: .watts(10)),
            .init(id: "battery", type: .battery, direction: .input, measurement: .watts(30)),
            .init(id: "unknown", type: .unknownExternalInterface, direction: .input, measurement: .watts(40)),
            .init(id: "mac", type: .mac, direction: .input, measurement: .watts(50)),
        ])

        XCTAssertEqual(content.sources.map(\.kind), [.externalPower, .externalPower, .battery, .unknown, .mac])
        XCTAssertEqual(content.sources.map(\.title), ["USB-C", "MagSafe", "Battery", "Unknown external interface", "Mac"])
        XCTAssertEqual(content.sources.map(\.provenance), [.measured, .measured, .measured, .measured, .derived])
        XCTAssertTrue(content.sources.allSatisfy { !$0.isSynthetic })
        XCTAssertTrue(content.sinks.isEmpty)
        XCTAssertTrue(content.issues.isEmpty)
    }

    func testSinksSortByKindThenKnownWattsThenStableID() {
        let endpoints: [PowerFlowEndpoint] = [
            .init(id: "external", type: .usbC, direction: .output, measurement: .watts(100)),
            .init(id: "unknown", type: .unknownExternalInterface, direction: .output, measurement: .watts(100)),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(100)),
            .init(id: "unavailable", type: .battery, direction: .output, measurement: .unavailable),
            .init(id: "b", type: .battery, direction: .output, measurement: .watts(10)),
            .init(id: "a", type: .battery, direction: .output, measurement: .watts(10)),
            .init(id: "high", type: .battery, direction: .output, measurement: .watts(20)),
        ]
        let content = normalized(endpoints)

        XCTAssertEqual(content, normalized(Array(endpoints.reversed())))
        XCTAssertEqual(content.sinks.map(\.id), [
            "sink:high", "sink:a", "sink:b", "sink:unavailable", "sink:mac", "sink:unknown", "sink:external",
        ])
        XCTAssertEqual(content.issues, [.missingMeasurements])
    }

    func testIdleEndpointsRetainDirectionAndUseSourceKindOrdering() {
        let endpoints: [PowerFlowEndpoint] = [
            .init(id: "mac", type: .mac, direction: .idle, measurement: .watts(2)),
            .init(id: "unknown", type: .unknownExternalInterface, direction: .idle, measurement: .unavailable),
            .init(id: "battery", type: .battery, direction: .idle, measurement: .watts(0)),
            .init(id: "external", type: .usbC, direction: .idle, measurement: .watts(0)),
        ]
        let content = normalized(endpoints)

        XCTAssertEqual(content, normalized(Array(endpoints.reversed())))
        XCTAssertTrue(content.sources.isEmpty)
        XCTAssertTrue(content.sinks.isEmpty)
        XCTAssertEqual(content.idleEndpoints.map(\.id), ["idle:external", "idle:battery", "idle:unknown", "idle:mac"])
        XCTAssertEqual(content.idleEndpoints.map(\.measurement), [.idle, .idle, .unavailable, .exact(2)])
        XCTAssertEqual(content.issues, [.unresolvedIdleMeasurement])
    }

    func testDuplicateIDAndWattageUseSpecificTitleAsDeterministicTieBreaker() {
        let endpoints: [PowerFlowEndpoint] = [
            .init(id: "same", type: .usbC, direction: .input, measurement: .watts(10)),
            .init(id: "same", type: .magSafe, direction: .input, measurement: .watts(10)),
        ]
        let content = normalized(endpoints)

        XCTAssertEqual(content, normalized(Array(endpoints.reversed())))
        XCTAssertEqual(content.sources.map(\.title), ["MagSafe", "USB-C"])
    }

    func testDuplicateIdleIDsKeepConfirmedZeroBeforeUnavailablePower() {
        let endpoints: [PowerFlowEndpoint] = [
            .init(id: "battery", type: .battery, direction: .idle, measurement: .unavailable),
            .init(id: "battery", type: .battery, direction: .idle, measurement: .watts(0)),
        ]
        let content = normalized(endpoints)

        XCTAssertEqual(content, normalized(Array(endpoints.reversed())))
        XCTAssertEqual(content.idleEndpoints.map(\.measurement), [.idle, .unavailable])
        XCTAssertEqual(content.idleEndpoints.map(\.id), ["idle:battery", "idle:battery#2"])
    }

    func testNormalIDsStayStableAcrossMeasurementChangesAndDistinctAcrossSides() {
        let content = normalized([
            .init(id: "shared", type: .usbC, direction: .input, measurement: .watts(12)),
            .init(id: "shared", type: .mac, direction: .output, measurement: .watts(10)),
            .init(id: "shared", type: .battery, direction: .idle, measurement: .watts(0)),
        ])
        let changed = normalize(
            .init(id: "shared", type: .usbC, direction: .input, measurement: .watts(15))
        )

        XCTAssertEqual(content.sources.map(\.id), changed.sources.map(\.id))
        XCTAssertEqual((content.sources + content.sinks + content.idleEndpoints).map(\.id), [
            "source:shared", "sink:shared", "idle:shared",
        ])
    }

    func testEmptyAndSyntheticOnlySummariesHaveAbsentProvenance() {
        let empty = PowerFlowDiagramPresentationBuilder.sideSummary(for: [])
        var synthetic = node("missing", .unavailable, .absent)
        synthetic.isSynthetic = true
        let missing = PowerFlowDiagramPresentationBuilder.sideSummary(for: [synthetic])

        XCTAssertEqual(empty.total, .idle)
        XCTAssertEqual(empty.provenance, .absent)
        XCTAssertEqual(empty.memberCount, 0)
        XCTAssertTrue(empty.representatives.isEmpty)
        XCTAssertEqual(missing.total, .unavailable)
        XCTAssertEqual(missing.provenance, .absent)
        XCTAssertEqual(missing.memberCount, 1)
        XCTAssertEqual(missing.representatives, [synthetic])
    }

    func testSummaryExcludesSyntheticMembersFromTotalsAndProvenanceButNotCount() {
        var synthetic = node("missing", .unavailable, .absent)
        synthetic.isSynthetic = true
        let summary = PowerFlowDiagramPresentationBuilder.sideSummary(for: [
            node("one", .exact(20), .measured),
            synthetic,
        ])

        XCTAssertEqual(summary.total, .exact(20))
        XCTAssertEqual(summary.provenance, .measured)
        XCTAssertEqual(summary.memberCount, 2)
        XCTAssertEqual(summary.representatives.map(\.id), ["one", "missing"])
    }

    func testBuildSelectsAllFourExpandedTopologies() {
        let cases: [(PowerFlowSnapshot, PowerFlowDiagramMode)] = [
            (
                PowerFlowDiagramFixtures.snapshot(
                    .init(id: "source", type: .usbC, direction: .input, measurement: .watts(21.46)),
                    .init(id: "mac", type: .mac, direction: .output, measurement: .watts(21.46))
                ),
                .expanded(.oneToOne)
            ),
            (
                PowerFlowDiagramFixtures.snapshot(
                    .init(id: "source", type: .usbC, direction: .input, measurement: .watts(56.8)),
                    .init(id: "battery", type: .battery, direction: .output, measurement: .watts(30.7)),
                    .init(id: "mac", type: .mac, direction: .output, measurement: .watts(26.1))
                ),
                .expanded(.oneToMany)
            ),
            (
                PowerFlowDiagramFixtures.snapshot(
                    .init(id: "source", type: .usbC, direction: .input, measurement: .watts(20)),
                    .init(id: "battery", type: .battery, direction: .input, measurement: .watts(24)),
                    .init(id: "mac", type: .mac, direction: .output, measurement: .watts(44))
                ),
                .expanded(.manyToOne)
            ),
            (
                PowerFlowDiagramFixtures.snapshot(
                    .init(id: "source", type: .usbC, direction: .input, measurement: .watts(45)),
                    .init(id: "unknown", type: .unknownExternalInterface, direction: .input, measurement: .watts(12)),
                    .init(id: "battery", type: .battery, direction: .output, measurement: .watts(30)),
                    .init(id: "mac", type: .mac, direction: .output, measurement: .watts(27))
                ),
                .expanded(.manyToMany)
            ),
        ]

        for (snapshot, expected) in cases {
            XCTAssertEqual(build(snapshot).preferredMode, expected)
        }
    }

    func testMoreThanTwoNodesOnEitherSideUsesGroupedMode() {
        let threeSources = PowerFlowDiagramFixtures.snapshot(
            .init(id: "one", type: .usbC, direction: .input, measurement: .watts(20)),
            .init(id: "two", type: .battery, direction: .input, measurement: .watts(10)),
            .init(id: "three", type: .unknownExternalInterface, direction: .input, measurement: .watts(5)),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(35))
        )
        let threeSinks = PowerFlowDiagramFixtures.snapshot(
            .init(id: "source", type: .usbC, direction: .input, measurement: .watts(35)),
            .init(id: "battery", type: .battery, direction: .output, measurement: .watts(10)),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(20)),
            .init(id: "unknown", type: .unknownExternalInterface, direction: .output, measurement: .watts(5))
        )

        for snapshot in [threeSources, threeSinks] {
            XCTAssertEqual(build(snapshot).preferredMode, .grouped)
            XCTAssertEqual(build(snapshot).status, .summary)
        }
    }

    func testMissingSourceInsertsNonNumericUnknownInput() {
        let presentation = build(PowerFlowDiagramFixtures.snapshot(
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(24))
        ))

        XCTAssertEqual(presentation.preferredMode, .expanded(.oneToOne))
        XCTAssertEqual(presentation.sources.map(\.title), ["Unknown Input"])
        XCTAssertEqual(presentation.sources.map(\.measurement), [.unavailable])
        XCTAssertEqual(presentation.sources.map(\.provenance), [.absent])
        XCTAssertEqual(presentation.sources.map(\.kind), [.unknown])
        XCTAssertEqual(presentation.sources.map(\.id), ["source:synthetic-unknown-input"])
        XCTAssertTrue(presentation.sources[0].isSynthetic)
        XCTAssertEqual(presentation.sourceSummary.total, .unavailable)
        XCTAssertEqual(presentation.issues, [.missingSource])
        XCTAssertFalse(presentation.sources.contains { $0.measurement == .exact(24) })
        XCTAssertEqual(presentation.accessibilityLabel,
                       "Power Flow Summary. Input: Unknown Input, power unavailable. Output: Mac, approximately 24 W. Partial data.")
    }

    func testMissingSinkInsertsNonNumericUnknownOutput() {
        let presentation = build(PowerFlowDiagramFixtures.snapshot(
            .init(id: "source", type: .usbC, direction: .input, measurement: .watts(24))
        ))

        XCTAssertEqual(presentation.preferredMode, .expanded(.oneToOne))
        XCTAssertEqual(presentation.sinks.map(\.title), ["Unknown Output"])
        XCTAssertEqual(presentation.sinks.map(\.measurement), [.unavailable])
        XCTAssertEqual(presentation.sinks.map(\.provenance), [.absent])
        XCTAssertEqual(presentation.sinks.map(\.kind), [.unknown])
        XCTAssertEqual(presentation.sinks.map(\.id), ["sink:synthetic-unknown-output"])
        XCTAssertTrue(presentation.sinks[0].isSynthetic)
        XCTAssertEqual(presentation.sinkSummary.total, .unavailable)
        XCTAssertEqual(presentation.issues, [.missingSink])
        XCTAssertEqual(presentation.status, .summary)
    }

    func testMissingSourceWithThreeSinksRemainsGroupedAndNarratesEveryMember() {
        let presentation = build(PowerFlowDiagramFixtures.snapshot(
            .init(id: "battery", type: .battery, direction: .output, measurement: .watts(10)),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(20)),
            .init(id: "unknown", type: .unknownExternalInterface, direction: .output, measurement: .unavailable)
        ))

        XCTAssertEqual(presentation.preferredMode, .grouped)
        XCTAssertEqual(presentation.sources.map(\.title), ["Unknown Input"])
        XCTAssertEqual(presentation.sinks.count, 3)
        XCTAssertTrue(presentation.issues.contains(.missingSource))
        XCTAssertTrue(presentation.accessibilityLabel.contains("Battery"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("Mac"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("Unknown external interface"))
        XCTAssertFalse(presentation.sources.contains { $0.measurement.exactWatts != nil })
    }

    func testMissingSinkWithThreeSourcesRemainsGroupedAndNarratesEveryMember() {
        let presentation = build(PowerFlowDiagramFixtures.snapshot(
            .init(id: "external", type: .usbC, direction: .input, measurement: .watts(20)),
            .init(id: "battery", type: .battery, direction: .input, measurement: .watts(10)),
            .init(id: "unknown", type: .unknownExternalInterface, direction: .input, measurement: .watts(5))
        ))

        XCTAssertEqual(presentation.preferredMode, .grouped)
        XCTAssertEqual(presentation.status, .summary)
        XCTAssertEqual(presentation.sources.count, 3)
        XCTAssertEqual(presentation.sinks.map(\.measurement), [.unavailable])
        XCTAssertTrue(presentation.sinks[0].isSynthetic)
        XCTAssertEqual(presentation.issues, [.missingSink])
        XCTAssertEqual(presentation.accessibilityLabel,
                       "Power Flow Summary. Input: Total: 35 W. USB-C, 20 W; Battery, 10 W; Unknown external interface, 5 W. "
                           + "Output: Total: power unavailable. Unknown Output, power unavailable. Partial data.")
    }

    func testWaitingIdleAndUnavailableModesAreDistinct() {
        let waiting = PowerFlowDiagramPresentationBuilder.build(
            snapshot: .empty,
            isRefreshing: true,
            bundle: PowerFlowDiagramFixtures.englishBundle
        )
        let idle = build(PowerFlowDiagramFixtures.snapshot(
            .init(id: "battery", type: .battery, direction: .idle, measurement: .watts(0))
        ))
        let unavailable = build(PowerFlowDiagramFixtures.snapshot(
            .init(id: "battery", type: .battery, direction: .idle, measurement: .unavailable)
        ))

        XCTAssertEqual(waiting.preferredMode, .waiting)
        XCTAssertEqual(waiting.status, .waiting)
        XCTAssertEqual(waiting.accessibilityLabel, "Waiting for Power Data")
        XCTAssertTrue(waiting.sources.isEmpty && waiting.sinks.isEmpty && waiting.idleEndpoints.isEmpty)
        XCTAssertTrue(waiting.issues.isEmpty)
        XCTAssertEqual(waiting.sourceSummary.total, .idle)
        XCTAssertEqual(waiting.sinkSummary.total, .idle)
        XCTAssertEqual(idle.preferredMode, .idle)
        XCTAssertEqual(idle.status, .idle)
        XCTAssertEqual(idle.accessibilityLabel, "No Active Power Flow")
        XCTAssertEqual(unavailable.preferredMode, .unavailable)
        XCTAssertEqual(unavailable.status, .unavailable)
        XCTAssertEqual(unavailable.accessibilityLabel, "Power Data Unavailable Partial data.")
        for presentation in [idle, unavailable] {
            XCTAssertTrue(presentation.sources.isEmpty && presentation.sinks.isEmpty)
            XCTAssertEqual(presentation.idleEndpoints.count, 1)
        }
    }

    func testWaitingRequiresBothRefreshingAndResetSentinel() {
        let snapshot = PowerFlowDiagramFixtures.snapshot(
            .init(id: "source", type: .usbC, direction: .input, measurement: .watts(24)),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(24))
        )
        let refreshing = PowerFlowDiagramPresentationBuilder.build(
            snapshot: snapshot,
            isRefreshing: true,
            bundle: PowerFlowDiagramFixtures.englishBundle
        )

        XCTAssertEqual(refreshing, build(snapshot))
        XCTAssertEqual(refreshing.preferredMode, .expanded(.oneToOne))
        XCTAssertEqual(refreshing.sources.map(\.measurement), [.exact(24)])
        let stoppedSentinel = build(.empty)
        XCTAssertEqual(stoppedSentinel.preferredMode, .expanded(.oneToOne))
        XCTAssertEqual(stoppedSentinel.status, .summary)
        XCTAssertEqual(stoppedSentinel.sinks.map(\.measurement), [.unavailable])
        XCTAssertEqual(stoppedSentinel.issues, [.missingSource, .missingMeasurements])
        XCTAssertEqual(build(PowerFlowDiagramFixtures.snapshot([])).accessibilityLabel, "Power Data Unavailable")
    }

    func testUnresolvedIdleMeasurementPreventsConfirmedIdleButDoesNotHideActiveFlow() {
        let idle: [PowerFlowEndpoint] = [
            .init(id: "zero", type: .battery, direction: .idle, measurement: .watts(0)),
            .init(id: "missing", type: .usbC, direction: .idle, measurement: .unavailable),
        ]
        let unavailable = build(PowerFlowDiagramFixtures.snapshot(idle))
        let active = build(PowerFlowDiagramFixtures.snapshot(idle + [
            .init(id: "source", type: .usbC, direction: .input, measurement: .watts(24)),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(24)),
        ]))

        XCTAssertEqual(unavailable.preferredMode, .unavailable)
        XCTAssertTrue(unavailable.sources.isEmpty && unavailable.sinks.isEmpty)
        XCTAssertEqual(active.preferredMode, .expanded(.oneToOne))
        XCTAssertEqual(active.status, .externalPower)
        XCTAssertEqual(active.idleEndpoints.count, 2)
        XCTAssertEqual(active.issues, [.unresolvedIdleMeasurement])
        XCTAssertTrue(active.accessibilityLabel.hasSuffix(" Partial data."))
    }

    func testStatusPrecedenceMatchesOperatingPattern() {
        let cases: [([PowerFlowEndpoint], PowerFlowDiagramStatus)] = [
            ([
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(40)),
                .init(id: "battery", type: .battery, direction: .output, measurement: .watts(18)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(22)),
            ], .charging),
            ([
                .init(id: "battery", type: .battery, direction: .input, measurement: .watts(24)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(24)),
            ], .batteryPower),
            ([
                .init(id: "external", type: .usbC, direction: .input, measurement: .watts(20)),
                .init(id: "battery", type: .battery, direction: .input, measurement: .watts(24)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(44)),
            ], .multipleSources),
            ([
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(24)),
            ], .summary),
            ([
                .init(id: "external", type: .magSafe, direction: .input, measurement: .watts(24)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(24)),
            ], .externalPower),
            ([
                .init(id: "unknown", type: .unknownExternalInterface, direction: .input, measurement: .watts(24)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(24)),
            ], .multipleFlows),
            ([
                .init(id: "external", type: .usbC, direction: .input, measurement: .unavailable),
                .init(id: "unknown", type: .unknownExternalInterface, direction: .input, measurement: .watts(12)),
                .init(id: "battery", type: .battery, direction: .output, measurement: .watts(12)),
            ], .charging),
        ]

        for (endpoints, expected) in cases {
            XCTAssertEqual(build(PowerFlowDiagramFixtures.snapshot(endpoints)).status, expected)
        }
    }

    func testKnownTotalToleranceBoundaryIsAcceptedAndJustBeyondIsFlagged() {
        let cases: [(Double, Double, Bool)] = [
            (20, 19, false), (20, 18.99, true),
            (100, 95, false), (100, 94.99, true),
            (95, 100, false), (94.99, 100, true),
            (0.5, 0.1, false),
        ]
        for (input, output, unbalanced) in cases {
            let presentation = build(PowerFlowDiagramFixtures.snapshot(
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(input)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(output))
            ))

            XCTAssertEqual(presentation.issues.contains(.unbalancedKnownTotals), unbalanced)
            XCTAssertEqual(presentation.accessibilityLabel.hasSuffix(" Partial data."), unbalanced)
        }
    }

    func testUnbalancedTotalsNeverCreateAResidualNode() {
        let presentation = build(PowerFlowDiagramFixtures.snapshot(
            .init(id: "source", type: .usbC, direction: .input, measurement: .watts(57)),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(27))
        ))

        XCTAssertEqual(presentation.sources.count, 1)
        XCTAssertEqual(presentation.sinks.count, 1)
        XCTAssertEqual(presentation.sourceSummary.total, .exact(57))
        XCTAssertEqual(presentation.sinkSummary.total, .exact(27))
        XCTAssertEqual(presentation.sources.map(\.measurement), [.exact(57)])
        XCTAssertEqual(presentation.sinks.map(\.measurement), [.exact(27)])
        XCTAssertTrue(presentation.issues.contains(.unbalancedKnownTotals))
        XCTAssertFalse(presentation.sources.contains(where: \.isSynthetic))
        XCTAssertFalse(presentation.sinks.contains(where: \.isSynthetic))
    }

    func testUnknownIdentityAndUnavailablePowerStayExpandedWithoutInventedValues() {
        for measurement in [PowerFlowMeasurement.watts(12), .unavailable] {
            let presentation = build(PowerFlowDiagramFixtures.snapshot(
                .init(id: "unknown", type: .unknownExternalInterface, direction: .input, measurement: measurement),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(12))
            ))

            XCTAssertEqual(presentation.preferredMode, .expanded(.oneToOne))
            XCTAssertFalse(presentation.sources[0].isSynthetic)
            if measurement == .unavailable {
                XCTAssertEqual(presentation.sources[0].measurement, .unavailable)
                XCTAssertEqual(presentation.issues, [.missingMeasurements])
                XCTAssertTrue(presentation.accessibilityLabel.contains("Unknown external interface, power unavailable"))
            } else {
                XCTAssertEqual(presentation.sources[0].measurement, .exact(12))
                XCTAssertTrue(presentation.issues.isEmpty)
            }
        }
    }

    func testPartialTotalsAreNotReconciledAsExact() {
        let presentation = build(PowerFlowDiagramFixtures.snapshot(
            .init(id: "source", type: .usbC, direction: .input, measurement: .watts(10)),
            .init(id: "missing", type: .battery, direction: .input, measurement: .unavailable),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(100))
        ))

        XCTAssertEqual(presentation.sourceSummary.total, .lowerBound(knownWatts: 10, unavailableCount: 1))
        XCTAssertEqual(presentation.issues, [.missingMeasurements])
        XCTAssertEqual(presentation.preferredMode, .expanded(.manyToOne))
        XCTAssertEqual(presentation.status, .multipleSources)
    }

    func testGroupedPartialAggregateHasExactEnglishNarration() {
        let presentation = build(PowerFlowDiagramFixtures.snapshot(
            .init(id: "one", type: .usbC, direction: .input, measurement: .watts(45)),
            .init(id: "two", type: .battery, direction: .input, measurement: .watts(12)),
            .init(id: "three", type: .unknownExternalInterface, direction: .input, measurement: .unavailable),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(57))
        ))

        XCTAssertEqual(presentation.sourceSummary.total, .lowerBound(knownWatts: 57, unavailableCount: 1))
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Power Flow Summary. Input: Total: at least 57 W; unavailable readings: 1. "
                + "USB-C, 45 W; Battery, 12 W; Unknown external interface, power unavailable. "
                + "Output: Total: approximately 57 W. Mac, approximately 57 W. Partial data."
        )
    }

    func testDerivedAndMixedLowerBoundAggregatesNarrateApproximation() {
        let cases: [(PowerFlowEndpointType, PowerFlowDisplayProvenance)] = [
            (.mac, .derived), (.battery, .mixed),
        ]
        for (type, provenance) in cases {
            let presentation = build(PowerFlowDiagramFixtures.snapshot(
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(30)),
                .init(id: "one", type: .mac, direction: .output, measurement: .watts(20)),
                .init(id: "two", type: type, direction: .output, measurement: .watts(10)),
                .init(id: "missing", type: .mac, direction: .output, measurement: .unavailable)
            ))

            XCTAssertEqual(presentation.preferredMode, .grouped)
            XCTAssertEqual(presentation.sinkSummary.provenance, provenance)
            XCTAssertEqual(presentation.sinkSummary.total, .lowerBound(knownWatts: 30, unavailableCount: 1))
            XCTAssertTrue(presentation.accessibilityLabel.contains(
                "Output: Total: approximately at least 30 W; unavailable readings: 1."
            ))
            XCTAssertTrue(presentation.accessibilityLabel.contains("Mac, approximately 20 W"))
            XCTAssertTrue(presentation.accessibilityLabel.contains("Mac, power unavailable"))
        }
    }

    private func build(
        _ snapshot: PowerFlowSnapshot
    ) -> PowerFlowDiagramPresentation {
        PowerFlowDiagramPresentationBuilder.build(
            snapshot: snapshot,
            isRefreshing: false,
            bundle: PowerFlowDiagramFixtures.englishBundle
        )
    }

    private func normalize(
        _ endpoint: PowerFlowEndpoint
    ) -> PowerFlowDiagramNormalizedContent {
        normalized([endpoint])
    }

    private func normalized(
        _ endpoints: [PowerFlowEndpoint]
    ) -> PowerFlowDiagramNormalizedContent {
        PowerFlowDiagramPresentationBuilder.normalize(
            snapshot: PowerFlowDiagramFixtures.snapshot(endpoints),
            bundle: PowerFlowDiagramFixtures.englishBundle
        )
    }

    private func node(
        _ id: String,
        _ measurement: PowerFlowDisplayMeasurement,
        _ provenance: PowerFlowDisplayProvenance
    ) -> PowerFlowDiagramNode {
        PowerFlowDiagramNode(
            id: id,
            kind: .other,
            title: id,
            measurement: measurement,
            provenance: provenance,
            isSynthetic: false
        )
    }
}
