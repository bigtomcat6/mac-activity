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
        let unavailableCount = real.count - known.count

        let total: PowerFlowDisplayMeasurement
        if real.isEmpty {
            total = nodes.isEmpty ? .idle : .unavailable
        } else if known.isEmpty {
            total = .unavailable
        } else if unavailableCount > 0 {
            total = .lowerBound(
                knownWatts: known.reduce(0, +),
                unavailableCount: unavailableCount
            )
        } else {
            total = .exact(known.reduce(0, +))
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
