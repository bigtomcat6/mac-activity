import CoreGraphics

struct PowerFlowDiagramLayoutResult: Equatable {
    var effectiveMode: PowerFlowDiagramMode
    var cardFrame: CGRect
    var statusFrame: CGRect
    var diagramFrame: CGRect
    var sourceFrames: [CGRect]
    var sinkFrames: [CGRect]
    var flowFrame: CGRect
    var flowLabelFrames: [CGRect]
    var busFrame: CGRect?
    var groupedSourceFrame: CGRect?
    var groupedCenterFrame: CGRect?
    var groupedSinkFrame: CGRect?

    var sourceRibbons: [PowerFlowDiagramRibbonLayout] {
        ribbons(isSource: true)
    }

    var sinkRibbons: [PowerFlowDiagramRibbonLayout] {
        ribbons(isSource: false)
    }

    private func ribbons(isSource: Bool) -> [PowerFlowDiagramRibbonLayout] {
        guard case .expanded = effectiveMode else { return [] }
        let nodes = isSource ? sourceFrames : sinkFrames
        let startX = isSource ? flowFrame.minX : (busFrame?.maxX ?? flowFrame.midX)
        let endX = isSource ? (busFrame?.minX ?? flowFrame.midX) : flowFrame.maxX
        let frame = CGRect(x: startX, y: flowFrame.minY, width: endX - startX, height: flowFrame.height)
        // Equal lanes communicate membership, never a watt-proportional allocation.
        let trunkHeight: CGFloat = 24
        let joinHeight = trunkHeight / CGFloat(max(1, nodes.count))
        return nodes.enumerated().map { index, node in
            let nodeY = node.midY - frame.minY
            let joinY = frame.height / 2 - trunkHeight / 2 + joinHeight * (CGFloat(index) + 0.5)
            return PowerFlowDiagramRibbonLayout(
                frame: frame,
                startCenterY: isSource ? nodeY : joinY,
                startHeight: isSource ? trunkHeight : joinHeight,
                endCenterY: isSource ? joinY : nodeY,
                endHeight: isSource ? joinHeight : trunkHeight
            )
        }
    }
}

struct PowerFlowDiagramRibbonLayout: Equatable {
    var frame: CGRect
    var startCenterY: CGFloat
    var startHeight: CGFloat
    var endCenterY: CGFloat
    var endHeight: CGFloat
}

enum PowerFlowDiagramLayout {
    static let minimumExpandedWidth: CGFloat = 320
    static let cardHeight: CGFloat = 104
    static let outerPadding: CGFloat = 8
    static let statusHeight: CGFloat = 16
    static let statusDiagramSpacing: CGFloat = 6
    static let diagramHeight: CGFloat = 64
    static let nodeToFlowGap: CGFloat = 4
    static let minimumLaneGap: CGFloat = 8
    static let minimumNodeWidth: CGFloat = 40
    static let maximumNodeWidth: CGFloat = 48
    static let minimumFlowLabelWidth: CGFloat = 58
    static let flowLabelHeight: CGFloat = 16

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

    static func resolve(
        width rawWidth: CGFloat,
        preferredMode: PowerFlowDiagramMode,
        sourceCount: Int,
        sinkCount: Int
    ) -> PowerFlowDiagramLayoutResult {
        let width = max(rawWidth, 1)
        let mode = effectiveMode(preferredMode: preferredMode, width: width)
        let card = CGRect(x: 0, y: 0, width: width, height: cardHeight)
        let status = CGRect(
            x: outerPadding,
            y: outerPadding,
            width: max(0, width - outerPadding * 2),
            height: statusHeight
        )
        let diagram = CGRect(
            x: outerPadding,
            y: status.maxY + statusDiagramSpacing,
            width: max(0, width - outerPadding * 2),
            height: diagramHeight
        )

        if mode == .grouped {
            return groupedResult(mode: mode, card: card, status: status, diagram: diagram)
        }

        guard case .expanded(let topology) = mode else {
            return emptyResult(mode: mode, card: card, status: status, diagram: diagram)
        }

        let nodeWidth = min(
            maximumNodeWidth,
            max(
                minimumNodeWidth,
                minimumNodeWidth
                    + (width - minimumExpandedWidth)
                    / (384 - minimumExpandedWidth)
                    * (maximumNodeWidth - minimumNodeWidth)
            )
        )
        let sourceColumn = CGRect(
            x: diagram.minX,
            y: diagram.minY,
            width: nodeWidth,
            height: diagram.height
        )
        let sinkColumn = CGRect(
            x: diagram.maxX - nodeWidth,
            y: diagram.minY,
            width: nodeWidth,
            height: diagram.height
        )
        let flow = CGRect(
            x: sourceColumn.maxX + nodeToFlowGap,
            y: diagram.minY,
            width: max(0, sinkColumn.minX - sourceColumn.maxX - nodeToFlowGap * 2),
            height: diagram.height
        )
        let sourceFrames = laneFrames(count: sourceCount, in: sourceColumn)
        let sinkFrames = laneFrames(count: sinkCount, in: sinkColumn)

        return PowerFlowDiagramLayoutResult(
            effectiveMode: mode,
            cardFrame: card,
            statusFrame: status,
            diagramFrame: diagram,
            sourceFrames: sourceFrames,
            sinkFrames: sinkFrames,
            flowFrame: flow,
            flowLabelFrames: flowLabelFrames(
                topology: topology,
                flowFrame: flow,
                sourceFrames: sourceFrames,
                sinkFrames: sinkFrames
            ),
            busFrame: busFrame(topology: topology, flowFrame: flow),
            groupedSourceFrame: nil,
            groupedCenterFrame: nil,
            groupedSinkFrame: nil
        )
    }

    private static func laneFrames(count: Int, in column: CGRect) -> [CGRect] {
        switch count {
        case 0:
            return []
        case 1:
            return [column]
        default:
            let laneHeight = (column.height - minimumLaneGap) / 2
            return [
                CGRect(
                    x: column.minX,
                    y: column.minY,
                    width: column.width,
                    height: laneHeight
                ),
                CGRect(
                    x: column.minX,
                    y: column.maxY - laneHeight,
                    width: column.width,
                    height: laneHeight
                ),
            ]
        }
    }

    private static func flowLabelFrames(
        topology: PowerFlowDiagramTopology,
        flowFrame: CGRect,
        sourceFrames: [CGRect],
        sinkFrames: [CGRect]
    ) -> [CGRect] {
        let labelWidth = min(
            max(minimumFlowLabelWidth, flowFrame.width * 0.34),
            max(minimumFlowLabelWidth, flowFrame.width / 2 - 4)
        )

        func frame(centerX: CGFloat, centerY: CGFloat) -> CGRect {
            CGRect(
                x: min(
                    max(centerX - labelWidth / 2, flowFrame.minX),
                    max(flowFrame.minX, flowFrame.maxX - labelWidth)
                ),
                y: min(
                    max(centerY - flowLabelHeight / 2, flowFrame.minY),
                    flowFrame.maxY - flowLabelHeight
                ),
                width: labelWidth,
                height: flowLabelHeight
            )
        }

        switch topology {
        case .oneToOne:
            return [frame(centerX: flowFrame.midX, centerY: flowFrame.midY)]

        case .oneToMany:
            return sinkFrames.map {
                frame(centerX: flowFrame.maxX - labelWidth / 2, centerY: $0.midY)
            }

        case .manyToOne:
            let branchLabels = sourceFrames.map {
                frame(centerX: flowFrame.minX + labelWidth / 2, centerY: $0.midY)
            }
            return branchLabels + [
                frame(centerX: flowFrame.maxX - labelWidth / 2, centerY: flowFrame.midY),
            ]

        case .manyToMany:
            let sourceLabels = sourceFrames.map {
                frame(centerX: flowFrame.minX + labelWidth / 2, centerY: $0.midY)
            }
            let sinkLabels = sinkFrames.map {
                frame(centerX: flowFrame.maxX - labelWidth / 2, centerY: $0.midY)
            }
            return sourceLabels + sinkLabels
        }
    }

    private static func busFrame(
        topology: PowerFlowDiagramTopology,
        flowFrame: CGRect
    ) -> CGRect? {
        guard topology == .manyToMany else { return nil }
        return CGRect(
            x: flowFrame.midX - 14,
            y: flowFrame.midY - 12,
            width: 28,
            height: 24
        )
    }

    private static func groupedResult(
        mode: PowerFlowDiagramMode,
        card: CGRect,
        status: CGRect,
        diagram: CGRect
    ) -> PowerFlowDiagramLayoutResult {
        let gap: CGFloat = 6
        let sideWidth = min(112, max(80, (diagram.width - 56 - gap * 2) * 0.36))
        let source = CGRect(
            x: diagram.minX,
            y: diagram.minY,
            width: sideWidth,
            height: diagram.height
        )
        let sink = CGRect(
            x: diagram.maxX - sideWidth,
            y: diagram.minY,
            width: sideWidth,
            height: diagram.height
        )
        let center = CGRect(
            x: source.maxX + gap,
            y: diagram.minY,
            width: max(56, sink.minX - source.maxX - gap * 2),
            height: diagram.height
        )

        return PowerFlowDiagramLayoutResult(
            effectiveMode: mode,
            cardFrame: card,
            statusFrame: status,
            diagramFrame: diagram,
            sourceFrames: [],
            sinkFrames: [],
            flowFrame: center,
            flowLabelFrames: [center.insetBy(dx: 4, dy: 20)],
            busFrame: center.insetBy(dx: 0, dy: 20),
            groupedSourceFrame: source,
            groupedCenterFrame: center,
            groupedSinkFrame: sink
        )
    }

    private static func emptyResult(
        mode: PowerFlowDiagramMode,
        card: CGRect,
        status: CGRect,
        diagram: CGRect
    ) -> PowerFlowDiagramLayoutResult {
        PowerFlowDiagramLayoutResult(
            effectiveMode: mode,
            cardFrame: card,
            statusFrame: status,
            diagramFrame: diagram,
            sourceFrames: [],
            sinkFrames: [],
            flowFrame: diagram,
            flowLabelFrames: [],
            busFrame: nil,
            groupedSourceFrame: nil,
            groupedCenterFrame: nil,
            groupedSinkFrame: nil
        )
    }
}
