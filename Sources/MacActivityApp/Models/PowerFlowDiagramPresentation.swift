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
