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
