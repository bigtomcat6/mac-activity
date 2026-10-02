import CoreGraphics

struct PowerFlowDiagramLayoutResult: Equatable {
    var effectiveMode: PowerFlowDiagramMode
    var cardFrame: CGRect
    var diagramFrame: CGRect
    var sourceSegment: CGRect
    var sourceSeparator: CGRect
    var middleSegment: CGRect
    var sinkSeparator: CGRect
    var sinkSegment: CGRect
    var outerCornerRadius: CGFloat
    var sourceFrames: [CGRect]
    var sinkFrames: [CGRect]
    var flowLabelFrames: [CGRect]
    var groupedSourceFrame: CGRect?
    var groupedCenterFrame: CGRect?
    var groupedSinkFrame: CGRect?
    /// Reserved bottom strip inside the middle piece when an expanded topology
    /// has to render localized In/Out totals (partial or unbalanced data).
    var totalsFooterFrame: CGRect?

    var busFrame: CGRect? = nil
    var ribbons: [PowerFlowRibbonGeometry] = []

    /// The middle frosted piece is the only flow region.
    var flowFrame: CGRect { middleSegment }
}

enum PowerFlowDiagramLayout {
    static let minimumExpandedWidth: CGFloat = 320
    static let cardHeight: CGFloat = 78
    static let referenceWidth: CGFloat = 384
    // Approved reference: left 52, separator 5, middle 270, separator 5, right 52.
    static let referenceSideWidth: CGFloat = 52
    static let referenceSeparatorWidth: CGFloat = 5
    static let outerCornerRadius: CGFloat = 21
    static let readoutHeight: CGFloat = 18
    /// Minimum width a grouped side gets so counts / representatives stay legible.
    static let groupedMinimumSideWidth: CGFloat = 94
    static let groupedMaximumSideWidth: CGFloat = 112
    /// Reserved bottom strip (within the middle piece) for the In/Out totals footer.
    static let expandedFooterHeight: CGFloat = 20

    /// Grouped summaries need more room than the 1→1 icon columns. The middle
    /// piece absorbs the remainder, but never shrinks below its share.
    ///
    /// Controller-approved readability trade-off: only the grouped mode uses the
    /// wider 94–112 pt sides so counts, representative watt values and the
    /// aggregate stay legible. Every other mode (including the 1→1 reference)
    /// keeps the exact 52/5/270/5/52 ratio and transparent endpoint separators.
    /// Additional branches increase height from the compact 78 pt baseline.
    static func groupedSideWidth(forWidth width: CGFloat) -> CGFloat {
        let proportional = width * 0.26
        let clamped = min(groupedMaximumSideWidth, max(groupedMinimumSideWidth, proportional))
        return min(width * 0.4, clamped)
    }

    static func effectiveMode(
        preferredMode: PowerFlowDiagramMode,
        width: CGFloat
    ) -> PowerFlowDiagramMode {
        if width < minimumExpandedWidth,
           case .expanded = preferredMode {
            return .grouped
        }
        return preferredMode
    }

    static func height(for mode: PowerFlowDiagramMode, sourceCount: Int, sinkCount: Int) -> CGFloat {
        guard case .expanded = mode else { return cardHeight }
        // Preserve the compact single lane; add space only for extra branches.
        return cardHeight * (1 + 0.25 * CGFloat(max(0, max(sourceCount, sinkCount) - 1)))
    }

    static func resolve(
        width rawWidth: CGFloat,
        preferredMode: PowerFlowDiagramMode,
        sourceCount: Int,
        sinkCount: Int,
        reservesTotalsFooter: Bool = false,
        sourceWatts: [Double?] = [],
        sinkWatts: [Double?] = []
    ) -> PowerFlowDiagramLayoutResult {
        let width = max(rawWidth, 1)
        let mode = effectiveMode(preferredMode: preferredMode, width: width)
        let panelHeight = height(for: mode, sourceCount: sourceCount, sinkCount: sinkCount)
        let card = CGRect(x: 0, y: 0, width: width, height: panelHeight)

        let scale = width / referenceWidth
        // The approved 1→1 ratio is fixed; grouped summaries may widen the sides.
        let side = mode == .grouped
            ? groupedSideWidth(forWidth: width)
            : referenceSideWidth * scale
        let separator = referenceSeparatorWidth * scale
        let middle = max(0, width - side * 2 - separator * 2)

        let sourceSegment = CGRect(x: 0, y: 0, width: side, height: panelHeight)
        let sourceSeparator = CGRect(x: side, y: 0, width: separator, height: panelHeight)
        let middleSegment = CGRect(x: side + separator, y: 0, width: middle, height: panelHeight)
        let sinkSeparator = CGRect(
            x: middleSegment.maxX, y: 0, width: separator, height: panelHeight
        )
        let sinkSegment = CGRect(
            x: width - side, y: 0, width: side, height: panelHeight
        )

        let radius = outerCornerRadius * scale

        if mode == .grouped {
            return PowerFlowDiagramLayoutResult(
                effectiveMode: mode,
                cardFrame: card,
                diagramFrame: card,
                sourceSegment: sourceSegment,
                sourceSeparator: sourceSeparator,
                middleSegment: middleSegment,
                sinkSeparator: sinkSeparator,
                sinkSegment: sinkSegment,
                outerCornerRadius: radius,
                sourceFrames: [],
                sinkFrames: [],
                flowLabelFrames: readoutFrames(
                    mode: .grouped, middle: middleSegment,
                    sourceCount: sourceCount, sinkCount: sinkCount,
                    reservesFooter: false
                ),
                groupedSourceFrame: sourceSegment,
                groupedCenterFrame: middleSegment,
                groupedSinkFrame: sinkSegment,
                totalsFooterFrame: nil
            )
        }

        guard case .expanded(let topology) = mode else {
            return PowerFlowDiagramLayoutResult(
                effectiveMode: mode,
                cardFrame: card,
                diagramFrame: card,
                sourceSegment: sourceSegment,
                sourceSeparator: sourceSeparator,
                middleSegment: middleSegment,
                sinkSeparator: sinkSeparator,
                sinkSegment: sinkSegment,
                outerCornerRadius: radius,
                sourceFrames: [],
                sinkFrames: [],
                flowLabelFrames: [],
                groupedSourceFrame: nil,
                groupedCenterFrame: nil,
                groupedSinkFrame: nil,
                totalsFooterFrame: nil
            )
        }

        let flowHeight = panelHeight - (reservesTotalsFooter ? expandedFooterHeight : 0)
        var sourceFrames = laneFrames(count: sourceCount, watts: sourceWatts, in: CGRect(
            x: sourceSegment.minX, y: 0, width: side, height: flowHeight
        ))
        var sinkFrames = laneFrames(count: sinkCount, watts: sinkWatts, in: CGRect(
            x: sinkSegment.minX, y: 0, width: side, height: flowHeight
        ))
        if topology != .oneToOne {
            let singleHeight = flowHeight * 0.8
            if sourceCount == 1 {
                sourceFrames[0].origin.y = (flowHeight - singleHeight) / 2
                sourceFrames[0].size.height = singleHeight
            }
            if sinkCount == 1 {
                sinkFrames[0].origin.y = (flowHeight - singleHeight) / 2
                sinkFrames[0].size.height = singleHeight
            }
        }
        let footer = reservesTotalsFooter
            ? CGRect(
                x: middleSegment.minX + 4,
                y: middleSegment.maxY - expandedFooterHeight,
                width: max(0, middleSegment.width - 8),
                height: expandedFooterHeight
            )
            : nil

        var result = PowerFlowDiagramLayoutResult(
            effectiveMode: mode,
            cardFrame: card,
            diagramFrame: card,
            sourceSegment: sourceSegment,
            sourceSeparator: sourceSeparator,
            middleSegment: middleSegment,
            sinkSeparator: sinkSeparator,
            sinkSegment: sinkSegment,
            outerCornerRadius: radius,
            sourceFrames: sourceFrames,
            sinkFrames: sinkFrames,
            flowLabelFrames: readoutFrames(
                mode: .expanded(topology),
                middle: middleSegment,
                sourceCount: sourceCount,
                sinkCount: sinkCount,
                reservesFooter: reservesTotalsFooter
            ),
            groupedSourceFrame: nil,
            groupedCenterFrame: nil,
            groupedSinkFrame: nil,
            totalsFooterFrame: footer
        )
        let active = CGRect(x: middleSegment.minX, y: 0, width: middleSegment.width, height: flowHeight)
        result.ribbons = ribbons(topology: topology, area: active,
                                 sources: sourceFrames, sinks: sinkFrames)
        if topology == .manyToMany {
            result.busFrame = result.ribbons.first { $0.role == .bus }?.bounds
        }
        result.flowLabelFrames = labelFrames(topology: topology, ribbons: result.ribbons)
        return result
    }

    private static func laneFrames(count: Int, watts: [Double?], in segment: CGRect) -> [CGRect] {
        guard count > 0, segment.height > 0 else { return [] }
        if count == 1 { return [segment] }
        // Reference: 240 px total ribbon thickness + 60 px open gap.
        let gap = segment.height * 0.2
        let usable = segment.height - gap * CGFloat(count - 1)
        var heights = Array(repeating: usable / CGFloat(count), count: count)
        let known = watts.compactMap { $0 }
        if count == 2, known.count == count, known.allSatisfy({ $0.isFinite && $0 > 0 }),
           known.reduce(0, +).isFinite {
            // Keep tiny branches readable, and never invent a ratio when a
            // measurement is missing. Width is not a pairwise allocation.
            let minimum = min(readoutHeight + 4, usable / 2)
            let first = usable * CGFloat(known[0] / known.reduce(0, +))
            heights[0] = min(usable - minimum, max(minimum, first))
            heights[1] = usable - heights[0]
        }
        var top = segment.minY
        return heights.map { height in
            defer { top += height + gap }
            return CGRect(x: segment.minX, y: top, width: segment.width, height: height)
        }
    }

    private static func ribbons(
        topology: PowerFlowDiagramTopology, area: CGRect, sources: [CGRect], sinks: [CGRect]
    ) -> [PowerFlowRibbonGeometry] {
        let packedHeight = area.height * 0.8
        let packedTop = area.midY - packedHeight / 2
        func band(_ role: PowerFlowRibbonRole, _ x0: CGFloat, _ x1: CGFloat,
                  _ y0: CGFloat, _ h0: CGFloat, _ y1: CGFloat, _ h1: CGFloat) -> PowerFlowRibbonGeometry {
            PowerFlowRibbonGeometry(role: role, startX: x0, endX: x1,
                                    startCenterY: y0, endCenterY: y1,
                                    startHeight: h0, endHeight: h1)
        }
        func packedCenters(_ lanes: [CGRect]) -> [CGFloat] {
            var top = packedTop
            return lanes.map { lane in
                defer { top += lane.height }
                return top + lane.height / 2
            }
        }
        switch topology {
        case .oneToOne:
            return [band(.direct, area.minX, area.maxX, area.midY, area.height, area.midY, area.height)]
        case .oneToMany:
            let centers = packedCenters(sinks)
            return sinks.enumerated().map { index, lane in
                band(.sink(index), area.minX, area.maxX,
                     centers[index], lane.height, lane.midY, lane.height)
            }
        case .manyToOne:
            let centers = packedCenters(sources)
            return sources.enumerated().map { index, lane in
                band(.source(index), area.minX, area.maxX,
                     lane.midY, lane.height, centers[index], lane.height)
            }
        case .manyToMany:
            let left = area.minX + area.width * 0.45
            let right = area.minX + area.width * 0.55
            let sourceCenters = packedCenters(sources)
            let sinkCenters = packedCenters(sinks)
            return sources.enumerated().map { index, lane in
                band(.source(index), area.minX, left, lane.midY, lane.height,
                     sourceCenters[index], lane.height)
            } + [band(.bus, left, right, area.midY, packedHeight, area.midY, packedHeight)]
                + sinks.enumerated().map { index, lane in
                    band(.sink(index), right, area.maxX,
                         sinkCenters[index], lane.height, lane.midY, lane.height)
                }
        }
    }

    private static func labelFrames(
        topology: PowerFlowDiagramTopology, ribbons: [PowerFlowRibbonGeometry]
    ) -> [CGRect] {
        ribbons.compactMap { ribbon in
            if ribbon.role == .bus { return nil }

            let inset: CGFloat = 4
            let width: CGFloat
            let x: CGFloat
            switch ribbon.role {
            case .source where topology != .manyToMany, .sink where topology != .manyToMany:
                width = max(0, ribbon.bounds.width - inset * 2)
                x = ribbon.startX + inset
            case .source:
                width = max(0, ribbon.bounds.width * 0.76 - inset * 2)
                x = ribbon.startX + inset
            case .sink where topology != .manyToOne:
                width = max(0, ribbon.bounds.width * 0.76 - inset * 2)
                x = ribbon.endX - inset - width
            default:
                width = max(0, ribbon.bounds.width - inset * 2)
                x = ribbon.startX + inset
            }
            return CGRect(x: x, y: ribbon.centerY(atX: x + width / 2) - readoutHeight / 2,
                          width: width, height: readoutHeight)
        }
    }

    private static func readoutFrames(
        mode: PowerFlowDiagramMode,
        middle: CGRect,
        sourceCount: Int,
        sinkCount: Int,
        reservesFooter: Bool
    ) -> [CGRect] {
        let inset: CGFloat = 4
        let columnGap: CGFloat = 6
        let usable = max(0, middle.width - inset * 2)
        let labelWidth = max(0, (usable - columnGap) / 2)
        let leftX = middle.minX + inset
        let rightX = middle.maxX - inset - labelWidth
        // Labels live above the reserved totals footer so the two never overlap.
        let activeHeight = max(0, middle.height - (reservesFooter ? expandedFooterHeight : 0))
        let activeTop = middle.minY

        func centered(_ centerY: CGFloat, width: CGFloat, x: CGFloat) -> CGRect {
            CGRect(x: x, y: centerY - readoutHeight / 2, width: width, height: readoutHeight)
        }

        func rowCenter(_ index: Int, of count: Int) -> CGFloat {
            guard count > 0 else { return activeTop + activeHeight / 2 }
            let laneHeight = activeHeight / CGFloat(count)
            return activeTop + laneHeight * (CGFloat(index) + 0.5)
        }

        func left(_ centerY: CGFloat) -> CGRect {
            centered(centerY, width: labelWidth, x: leftX)
        }

        func right(_ centerY: CGFloat) -> CGRect {
            centered(centerY, width: labelWidth, x: rightX)
        }

        switch mode {
        case .expanded(.oneToOne):
            return [centered(activeTop + activeHeight / 2, width: usable, x: middle.minX + inset)]
        case .expanded(.oneToMany):
            return (0..<max(0, sinkCount)).map { right(rowCenter($0, of: sinkCount)) }
        case .expanded(.manyToOne):
            return (0..<max(0, sourceCount)).map { left(rowCenter($0, of: sourceCount)) }
                + [right(activeTop + activeHeight / 2)]
        case .expanded(.manyToMany):
            return (0..<max(0, sourceCount)).map { left(rowCenter($0, of: sourceCount)) }
                + (0..<max(0, sinkCount)).map { right(rowCenter($0, of: sinkCount)) }
        case .grouped:
            // Input total over output total, centered in the middle piece.
            let stackedWidth = usable
            let rowHeight = readoutHeight
            let gap: CGFloat = 2
            let totalHeight = rowHeight * 2 + gap
            let originY = middle.midY - totalHeight / 2
            return [
                CGRect(x: middle.minX + inset, y: originY, width: stackedWidth, height: rowHeight),
                CGRect(
                    x: middle.minX + inset,
                    y: originY + rowHeight + gap,
                    width: stackedWidth,
                    height: rowHeight
                ),
            ]
        case .waiting, .idle, .unavailable:
            return []
        }
    }
}

/// Roles connect endpoints to a shared region, never one endpoint to another.
enum PowerFlowRibbonRole: Equatable, Hashable {
    case direct
    case source(Int)
    case sink(Int)
    case bus
}

struct PowerFlowRibbonGeometry: Equatable {
    var role: PowerFlowRibbonRole
    var startX: CGFloat
    var endX: CGFloat
    var startCenterY: CGFloat
    var endCenterY: CGFloat
    var startHeight: CGFloat
    var endHeight: CGFloat

    var bounds: CGRect {
        let top = min(startCenterY - startHeight / 2, endCenterY - endHeight / 2)
        let bottom = max(startCenterY + startHeight / 2, endCenterY + endHeight / 2)
        return CGRect(x: startX, y: top, width: endX - startX, height: bottom - top)
    }

    func centerY(atX x: CGFloat) -> CGFloat {
        let unitX = min(1, max(0, (x - startX) / max(1, endX - startX)))
        var low: CGFloat = 0
        var high: CGFloat = 1
        for _ in 0..<20 {
            let t = (low + high) / 2
            let bx = 3 * (1 - t) * (1 - t) * t * 0.5 + 3 * (1 - t) * t * t * 0.5 + t * t * t
            if bx < unitX { low = t } else { high = t }
        }
        let t = (low + high) / 2
        let eased = t * t * (3 - 2 * t)
        return startCenterY + (endCenterY - startCenterY) * eased
    }
}
