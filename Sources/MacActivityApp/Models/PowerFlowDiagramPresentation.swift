import Foundation
import MacActivityCore

struct PowerFlowDiagramPresentation: Equatable, Sendable {
    var preferredMode: PowerFlowDiagramMode
    var sources: [PowerFlowDiagramNode]
    var sinks: [PowerFlowDiagramNode]
    var idleEndpoints: [PowerFlowDiagramNode]
    var sourceSummary: PowerFlowDiagramSideSummary
    var sinkSummary: PowerFlowDiagramSideSummary
    var issues: Set<PowerFlowDiagramIssue>
    var status: PowerFlowDiagramStatus
    var accessibilityLabel: String
}

enum PowerFlowDiagramMode: Equatable, Sendable {
    case waiting
    case idle
    case expanded(PowerFlowDiagramTopology)
    case grouped
    case unavailable
}

enum PowerFlowDiagramTopology: Equatable, Sendable {
    case oneToOne
    case oneToMany
    case manyToOne
    case manyToMany
}

struct PowerFlowDiagramNode: Identifiable, Equatable, Sendable {
    var id: String
    var kind: PowerFlowDiagramNodeKind
    var title: String
    var measurement: PowerFlowDisplayMeasurement
    var provenance: PowerFlowDisplayProvenance
    var isSynthetic: Bool
}

struct PowerFlowDiagramSideSummary: Equatable, Sendable {
    var memberCount: Int
    var total: PowerFlowDisplayMeasurement
    var provenance: PowerFlowDisplayProvenance
    var representatives: [PowerFlowDiagramNode]
}

enum PowerFlowDiagramNodeKind: Equatable, Hashable, Sendable {
    case externalPower
    case battery
    case mac
    case other
    case unknown
}

enum PowerFlowDisplayMeasurement: Equatable, Sendable {
    case exact(Double)
    case lowerBound(knownWatts: Double, unavailableCount: Int)
    case unavailable
    case idle

    var exactWatts: Double? {
        guard case .exact(let watts) = self else { return nil }
        return watts
    }
}

enum PowerFlowDisplayProvenance: Equatable, Hashable, Sendable {
    case measured
    case derived
    case mixed
    case absent
}

enum PowerFlowDiagramStatus: Equatable, Sendable {
    case waiting
    case idle
    case unavailable
    case externalPower
    case batteryPower
    case charging
    case multipleSources
    case multipleFlows
    case summary
}

enum PowerFlowDiagramIssue: Equatable, Hashable, Sendable {
    case missingSource
    case missingSink
    case missingMeasurements
    case unbalancedKnownTotals
    case unresolvedIdleMeasurement
}

struct PowerFlowDiagramNormalizedContent: Equatable, Sendable {
    var sources: [PowerFlowDiagramNode]
    var sinks: [PowerFlowDiagramNode]
    var idleEndpoints: [PowerFlowDiagramNode]
    var issues: Set<PowerFlowDiagramIssue>
}

private struct PowerFlowDiagramNodeCandidate {
    var baseID: String
    var kind: PowerFlowDiagramNodeKind
    var title: String
    var measurement: PowerFlowDisplayMeasurement
    var provenance: PowerFlowDisplayProvenance
    var isSynthetic: Bool
}

private enum PowerFlowDiagramSide: String {
    case source
    case sink
    case idle
}

enum PowerFlowDiagramPresentationBuilder {
    static func build(
        snapshot: PowerFlowSnapshot,
        isRefreshing: Bool,
        bundle: Bundle? = nil
    ) -> PowerFlowDiagramPresentation {
        if isRefreshing, snapshot.timestamp == .distantPast {
            return terminalPresentation(
                mode: .waiting,
                status: .waiting,
                issues: [],
                bundle: bundle
            )
        }

        let normalized = normalize(snapshot: snapshot, bundle: bundle)
        var sources = normalized.sources
        var sinks = normalized.sinks
        var issues = normalized.issues

        if sources.isEmpty, !sinks.isEmpty {
            sources = [
                syntheticNode(
                    id: "source:synthetic-unknown-input",
                    title: AppLocalization.string(.powerFlowUnknownInput, bundle: bundle)
                ),
            ]
            issues.insert(.missingSource)
        } else if sinks.isEmpty, !sources.isEmpty {
            sinks = [
                syntheticNode(
                    id: "sink:synthetic-unknown-output",
                    title: AppLocalization.string(.powerFlowUnknownOutput, bundle: bundle)
                ),
            ]
            issues.insert(.missingSink)
        }

        let sourceSummary = sideSummary(for: sources)
        let sinkSummary = sideSummary(for: sinks)
        addBalanceIssueIfNeeded(
            sourceSummary: sourceSummary,
            sinkSummary: sinkSummary,
            sources: sources,
            sinks: sinks,
            issues: &issues
        )

        let mode = preferredMode(
            sources: sources,
            sinks: sinks,
            idleEndpoints: normalized.idleEndpoints,
            issues: issues
        )
        let status = status(mode: mode, sources: sources, sinks: sinks)

        return PowerFlowDiagramPresentation(
            preferredMode: mode,
            sources: sources,
            sinks: sinks,
            idleEndpoints: normalized.idleEndpoints,
            sourceSummary: sourceSummary,
            sinkSummary: sinkSummary,
            issues: issues,
            status: status,
            accessibilityLabel: accessibilityLabel(
                mode: mode,
                status: status,
                sources: sources,
                sinks: sinks,
                sourceSummary: sourceSummary,
                sinkSummary: sinkSummary,
                issues: issues,
                bundle: bundle
            )
        )
    }

    static func normalize(
        snapshot: PowerFlowSnapshot,
        bundle: Bundle? = nil
    ) -> PowerFlowDiagramNormalizedContent {
        var sources = [PowerFlowDiagramNodeCandidate]()
        var sinks = [PowerFlowDiagramNodeCandidate]()
        var idle = [PowerFlowDiagramNodeCandidate]()
        var issues = Set<PowerFlowDiagramIssue>()

        for endpoint in snapshot.endpoints {
            let measurement = sanitized(endpoint.measurement)
            let direction: PowerFlowDirection =
                measurement == .exact(0) ? .idle : endpoint.direction
            let candidate = candidate(
                endpoint,
                measurement: direction == .idle && measurement == .exact(0)
                    ? .idle
                    : measurement,
                bundle: bundle
            )

            switch direction {
            case .input:
                sources.append(candidate)
                if measurement == .unavailable {
                    issues.insert(.missingMeasurements)
                }
            case .output:
                sinks.append(candidate)
                if measurement == .unavailable {
                    issues.insert(.missingMeasurements)
                }
            case .idle:
                idle.append(candidate)
                if measurement == .unavailable {
                    issues.insert(.unresolvedIdleMeasurement)
                }
            }
        }

        return PowerFlowDiagramNormalizedContent(
            sources: finalized(sources, side: .source),
            sinks: finalized(sinks, side: .sink),
            idleEndpoints: finalized(idle, side: .idle),
            issues: issues
        )
    }

    static func sideSummary(
        for nodes: [PowerFlowDiagramNode]
    ) -> PowerFlowDiagramSideSummary {
        let real = nodes.filter { !$0.isSynthetic }
        let known = real.compactMap(\.measurement.exactWatts)
        let knownWatts = known.reduce(0, +)
        let unavailableCount = real.count - known.count

        let total: PowerFlowDisplayMeasurement
        if real.isEmpty {
            total = nodes.isEmpty ? .idle : .unavailable
        } else if known.isEmpty || !knownWatts.isFinite {
            total = .unavailable
        } else if unavailableCount > 0 {
            total = .lowerBound(
                knownWatts: knownWatts,
                unavailableCount: unavailableCount
            )
        } else {
            total = .exact(knownWatts)
        }

        let provenances = Set(real.map(\.provenance))
        let provenance: PowerFlowDisplayProvenance
        if real.isEmpty {
            provenance = .absent
        } else if provenances.count == 1 {
            provenance = provenances.first!
        } else {
            provenance = .mixed
        }

        return PowerFlowDiagramSideSummary(
            memberCount: nodes.count,
            total: total,
            provenance: provenance,
            representatives: Array(nodes.prefix(2))
        )
    }

    private static func syntheticNode(
        id: String,
        title: String
    ) -> PowerFlowDiagramNode {
        PowerFlowDiagramNode(
            id: id,
            kind: .unknown,
            title: title,
            measurement: .unavailable,
            provenance: .absent,
            isSynthetic: true
        )
    }

    private static func preferredMode(
        sources: [PowerFlowDiagramNode],
        sinks: [PowerFlowDiagramNode],
        idleEndpoints: [PowerFlowDiagramNode],
        issues: Set<PowerFlowDiagramIssue>
    ) -> PowerFlowDiagramMode {
        if sources.isEmpty, sinks.isEmpty {
            let confirmedIdle = idleEndpoints.contains { $0.measurement == .idle }
            return confirmedIdle && !issues.contains(.unresolvedIdleMeasurement)
                ? .idle
                : .unavailable
        }

        if sources.count > 2 || sinks.count > 2 {
            return .grouped
        }

        switch (sources.count, sinks.count) {
        case (1, 1): return .expanded(.oneToOne)
        case (1, 2): return .expanded(.oneToMany)
        case (2, 1): return .expanded(.manyToOne)
        case (2, 2): return .expanded(.manyToMany)
        default: return .grouped
        }
    }

    private static func addBalanceIssueIfNeeded(
        sourceSummary: PowerFlowDiagramSideSummary,
        sinkSummary: PowerFlowDiagramSideSummary,
        sources: [PowerFlowDiagramNode],
        sinks: [PowerFlowDiagramNode],
        issues: inout Set<PowerFlowDiagramIssue>
    ) {
        guard sources.contains(where: { !$0.isSynthetic }),
              sinks.contains(where: { !$0.isSynthetic }),
              let input = sourceSummary.total.exactWatts,
              let output = sinkSummary.total.exactWatts else {
            return
        }

        let tolerance = max(1.0, max(input, output) * 0.05)
        if abs(input - output) > tolerance {
            issues.insert(.unbalancedKnownTotals)
        }
    }

    private static func status(
        mode: PowerFlowDiagramMode,
        sources: [PowerFlowDiagramNode],
        sinks: [PowerFlowDiagramNode]
    ) -> PowerFlowDiagramStatus {
        switch mode {
        case .waiting: return .waiting
        case .idle: return .idle
        case .unavailable: return .unavailable
        case .grouped: return .summary
        case .expanded: break
        }

        if sources.contains(where: \.isSynthetic)
            || sinks.contains(where: \.isSynthetic) {
            return .summary
        }

        let realSources = sources.filter { !$0.isSynthetic }
        let realSinks = sinks.filter { !$0.isSynthetic }

        if realSources.contains(where: { $0.kind == .externalPower }),
           realSinks.contains(where: { $0.kind == .battery }) {
            return .charging
        }
        if realSources.count == 1,
           realSources[0].kind == .battery,
           realSinks.count == 1,
           realSinks[0].kind == .mac {
            return .batteryPower
        }
        if realSources.count == 1,
           realSources[0].kind == .externalPower,
           realSinks.count == 1,
           realSinks[0].kind == .mac {
            return .externalPower
        }
        if realSources.count > 1, realSinks.count == 1 {
            return .multipleSources
        }
        return .multipleFlows
    }

    private static func accessibilityLabel(
        mode: PowerFlowDiagramMode,
        status: PowerFlowDiagramStatus,
        sources: [PowerFlowDiagramNode],
        sinks: [PowerFlowDiagramNode],
        sourceSummary: PowerFlowDiagramSideSummary,
        sinkSummary: PowerFlowDiagramSideSummary,
        issues: Set<PowerFlowDiagramIssue>,
        bundle: Bundle?
    ) -> String {
        let statusText = PowerFlowPresentation.statusText(status, bundle: bundle)
        let suffix = issues.isEmpty
            ? ""
            : AppLocalization.string(.powerFlowAccessibilityPartialSuffix, bundle: bundle)

        guard !sources.isEmpty || !sinks.isEmpty else {
            return statusText + suffix
        }

        let sourceText = accessibilitySideText(
            nodes: sources,
            summary: sourceSummary,
            includesSummary: mode == .grouped,
            bundle: bundle
        )
        let sinkText = accessibilitySideText(
            nodes: sinks,
            summary: sinkSummary,
            includesSummary: mode == .grouped,
            bundle: bundle
        )

        return AppLocalization.string(
            .powerFlowAccessibilityComponent,
            statusText,
            AppLocalization.string(.powerFlowInput, bundle: bundle),
            sourceText,
            AppLocalization.string(.powerFlowOutput, bundle: bundle),
            sinkText,
            suffix,
            bundle: bundle
        )
    }

    private static func accessibilitySideText(
        nodes: [PowerFlowDiagramNode],
        summary: PowerFlowDiagramSideSummary,
        includesSummary: Bool,
        bundle: Bundle?
    ) -> String {
        let members = nodes
            .map { accessibilityNodeText($0, bundle: bundle) }
            .joined(separator: "; ")

        guard includesSummary else { return members }

        return AppLocalization.string(
            .powerFlowAccessibilitySideSummary,
            accessibilityAggregateText(
                summary.total,
                provenance: summary.provenance,
                bundle: bundle
            ),
            members,
            bundle: bundle
        )
    }

    private static func accessibilityNodeText(
        _ node: PowerFlowDiagramNode,
        bundle: Bundle?
    ) -> String {
        guard case .exact(let watts) = node.measurement else {
            return AppLocalization.string(
                .powerFlowAccessibilityNodeUnavailable,
                node.title,
                bundle: bundle
            )
        }

        let value = PowerFlowPresentation.powerText(
            .watts(watts),
            locale: AppLocalization.currentLocale(bundle: bundle),
            bundle: bundle
        )
        let key: AppLocalization.Key =
            node.provenance == .derived || node.provenance == .mixed
            ? .powerFlowAccessibilityNodeDerived
            : .powerFlowAccessibilityNodeMeasured

        return AppLocalization.string(key, node.title, value, bundle: bundle)
    }

    private static func accessibilityAggregateText(
        _ measurement: PowerFlowDisplayMeasurement,
        provenance: PowerFlowDisplayProvenance,
        bundle: Bundle?
    ) -> String {
        switch measurement {
        case .exact(let watts):
            let value = PowerFlowPresentation.powerText(
                .watts(watts),
                locale: AppLocalization.currentLocale(bundle: bundle),
                bundle: bundle
            )
            return provenance == .derived || provenance == .mixed
                ? AppLocalization.string(
                    .powerFlowAccessibilityAggregateDerived,
                    value,
                    bundle: bundle
                )
                : value

        case .lowerBound(let knownWatts, let unavailableCount):
            let value = PowerFlowPresentation.powerText(
                .watts(knownWatts),
                locale: AppLocalization.currentLocale(bundle: bundle),
                bundle: bundle
            )
            let lowerBound = AppLocalization.string(
                .powerFlowAccessibilityAggregateLowerBound,
                value,
                Int64(unavailableCount),
                bundle: bundle
            )
            return provenance == .derived || provenance == .mixed
                ? AppLocalization.string(
                    .powerFlowAccessibilityAggregateDerived,
                    lowerBound,
                    bundle: bundle
                )
                : lowerBound

        case .unavailable, .idle:
            return AppLocalization.string(
                .powerFlowAccessibilityAggregateUnavailable,
                bundle: bundle
            )
        }
    }

    private static func terminalPresentation(
        mode: PowerFlowDiagramMode,
        status: PowerFlowDiagramStatus,
        issues: Set<PowerFlowDiagramIssue>,
        bundle: Bundle?
    ) -> PowerFlowDiagramPresentation {
        let empty = sideSummary(for: [])
        return PowerFlowDiagramPresentation(
            preferredMode: mode,
            sources: [],
            sinks: [],
            idleEndpoints: [],
            sourceSummary: empty,
            sinkSummary: empty,
            issues: issues,
            status: status,
            accessibilityLabel: PowerFlowPresentation.statusText(status, bundle: bundle)
        )
    }

    private static func sanitized(
        _ measurement: PowerFlowMeasurement
    ) -> PowerFlowDisplayMeasurement {
        switch measurement {
        case .unavailable:
            return .unavailable
        case .watts(let watts):
            guard watts.isFinite, watts >= 0 else {
                return .unavailable
            }
            return .exact(watts)
        }
    }

    private static func candidate(
        _ endpoint: PowerFlowEndpoint,
        measurement: PowerFlowDisplayMeasurement,
        bundle: Bundle?
    ) -> PowerFlowDiagramNodeCandidate {
        PowerFlowDiagramNodeCandidate(
            baseID: endpoint.id,
            kind: nodeKind(endpoint.type),
            title: PowerFlowPresentation.endpointTitle(endpoint.type, bundle: bundle),
            measurement: measurement,
            provenance: endpoint.type == .mac ? .derived : .measured,
            isSynthetic: false
        )
    }

    private static func nodeKind(
        _ type: PowerFlowEndpointType
    ) -> PowerFlowDiagramNodeKind {
        switch type {
        case .usbC, .magSafe: return .externalPower
        case .battery: return .battery
        case .mac: return .mac
        case .unknownExternalInterface: return .unknown
        }
    }

    private static func finalized(
        _ candidates: [PowerFlowDiagramNodeCandidate],
        side: PowerFlowDiagramSide
    ) -> [PowerFlowDiagramNode] {
        let sorted = candidates.sorted {
            comesBefore($0, $1, side: side)
        }
        // Reserve real IDs before allocating suffixes, even if their nodes sort later.
        var reservedIDs = Set(candidates.map { "\(side.rawValue):\($0.baseID)" })
        var occurrences = [String: Int]()

        return sorted.map { candidate in
            let base = "\(side.rawValue):\(candidate.baseID)"
            var occurrence = occurrences[base, default: 0] + 1
            var id = base
            if occurrence > 1 {
                id = "\(base)#\(occurrence)"
                while reservedIDs.contains(id) {
                    occurrence += 1
                    id = "\(base)#\(occurrence)"
                }
            }
            occurrences[base] = occurrence
            reservedIDs.insert(id)

            return PowerFlowDiagramNode(
                id: id,
                kind: candidate.kind,
                title: candidate.title,
                measurement: candidate.measurement,
                provenance: candidate.provenance,
                isSynthetic: candidate.isSynthetic
            )
        }
    }

    private static func comesBefore(
        _ lhs: PowerFlowDiagramNodeCandidate,
        _ rhs: PowerFlowDiagramNodeCandidate,
        side: PowerFlowDiagramSide
    ) -> Bool {
        let lhsRank = kindRank(lhs.kind, side: side)
        let rhsRank = kindRank(rhs.kind, side: side)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.isSynthetic != rhs.isSynthetic { return !lhs.isSynthetic }

        // Confirmed zero remains known for ordering after its display value becomes idle.
        let lhsWatts = lhs.measurement == .idle ? 0 : lhs.measurement.exactWatts
        let rhsWatts = rhs.measurement == .idle ? 0 : rhs.measurement.exactWatts
        if (lhsWatts != nil) != (rhsWatts != nil) {
            return lhsWatts != nil
        }
        if let lhsWatts, let rhsWatts, lhsWatts != rhsWatts {
            return lhsWatts > rhsWatts
        }
        if lhs.baseID != rhs.baseID { return lhs.baseID < rhs.baseID }
        return lhs.title < rhs.title
    }

    private static func kindRank(
        _ kind: PowerFlowDiagramNodeKind,
        side: PowerFlowDiagramSide
    ) -> Int {
        switch side {
        case .source, .idle:
            switch kind {
            case .externalPower: return 0
            case .battery: return 1
            case .other: return 2
            case .unknown: return 3
            case .mac: return 4
            }
        case .sink:
            switch kind {
            case .battery: return 0
            case .mac: return 1
            case .other: return 2
            case .unknown: return 3
            case .externalPower: return 4
            }
        }
    }
}
