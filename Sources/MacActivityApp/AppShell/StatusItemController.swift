import AppKit
import Combine
import MacActivityCore

@MainActor
final class StatusItemController: NSObject {
    private static let summaryUpdateInterval: DispatchQueue.SchedulerTimeType.Stride = .seconds(10)

    private let summaryModel: StatusSummaryModel
    private let popoverController: DashboardPopoverControlling
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []
    private var currentSummary: RenderedStatusSummary?

    init(
        summaryModel: StatusSummaryModel,
        popoverController: DashboardPopoverControlling
    ) {
        self.summaryModel = summaryModel
        self.popoverController = popoverController
        super.init()
    }

    func install() {
        guard statusItem == nil else {
            render(
                summaryText: summaryModel.summaryText,
                items: summaryModel.summaryItems
            )
            return
        }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton(for: statusItem)
        render(
            summaryText: summaryModel.summaryText,
            items: summaryModel.summaryItems,
            onto: statusItem
        )

        Publishers.CombineLatest(summaryModel.$summaryText, summaryModel.$summaryItems)
            .throttle(for: Self.summaryUpdateInterval, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] summaryText, items in
                self?.render(summaryText: summaryText, items: items)
            }
            .store(in: &cancellables)

        summaryModel.$summaryItems
            .dropFirst()
            .sink { [weak self] items in
                self?.renderImmediatelyIfStructureChanged(items: items)
            }
            .store(in: &cancellables)

        self.statusItem = statusItem
    }

    func remove() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }

        statusItem = nil
        currentSummary = nil
        cancellables.removeAll()
    }

    private func configureButton(for statusItem: NSStatusItem) {
        guard let button = statusItem.button else {
            return
        }

        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp])
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        togglePopover()
    }

    private func togglePopover() {
        popoverController.toggle(relativeTo: statusItem?.button)
    }

    private func render(
        summaryText: String,
        items: [StatusSummaryItem],
        onto statusItem: NSStatusItem? = nil
    ) {
        let structureKey = StatusBarSummaryStructureKey(items: items)
        let presentation = StatusBarSummaryLayout.imagePresentation(summaryText: summaryText, items: items)
        let nextSummary = RenderedStatusSummary(
            title: presentation.accessibilityTitle,
            length: presentation.length,
            structureKey: structureKey
        )
        guard currentSummary != nextSummary else {
            return
        }

        let targetStatusItem = statusItem ?? self.statusItem
        guard let targetStatusItem else {
            return
        }

        guard let button = targetStatusItem.button else {
            return
        }

        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.image = presentation.image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = presentation.accessibilityTitle
        button.setAccessibilityLabel(presentation.accessibilityTitle)
        if abs(targetStatusItem.length - presentation.length) > 0.5 {
            targetStatusItem.length = presentation.length
        }

        currentSummary = nextSummary
    }

    private func renderImmediatelyIfStructureChanged(items: [StatusSummaryItem]) {
        let structureKey = StatusBarSummaryStructureKey(items: items)
        guard currentSummary?.structureKey != structureKey else {
            return
        }

        render(summaryText: summaryModel.summaryText, items: items)
    }
}

private struct RenderedStatusSummary: Equatable {
    var title: String
    var length: CGFloat
    var structureKey: StatusBarSummaryStructureKey
}

struct StatusBarSummaryStructureKey: Equatable {
    private var components: [Component]

    init(items: [StatusSummaryItem]) {
        components = items.map(Component.init(item:))
    }

    private struct Component: Equatable {
        var kind: MetricKind
        var secondaryText: String
        var style: StatusSummaryItemStyle

        init(item: StatusSummaryItem) {
            self.kind = item.kind
            self.secondaryText = item.secondaryText
            self.style = item.style
        }
    }
}

struct StatusBarSummaryPresentation {
    var image: NSImage
    var length: CGFloat
    var accessibilityTitle: String
}

enum StatusBarSummaryLayout {
    static let metricMinimumWidth: CGFloat = 26
    static let networkMinimumWidth: CGFloat = 34
    static let separatorWidth: CGFloat = 2
    static let statusBarHeight: CGFloat = 22
    static let minimumTitleLength: CGFloat = 44
    static var fallbackFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
    }

    static func imagePresentation(
        summaryText: String,
        items: [StatusSummaryItem]
    ) -> StatusBarSummaryPresentation {
        let length = items.isEmpty
            ? fallbackWidth(for: summaryText)
            : preferredWidth(for: items)
        let image = renderImage(summaryText: summaryText, items: items, size: NSSize(width: length, height: statusBarHeight))

        return StatusBarSummaryPresentation(
            image: image,
            length: length,
            accessibilityTitle: accessibilityTitle(summaryText: summaryText, items: items)
        )
    }

    static func preferredWidth(for items: [StatusSummaryItem]) -> CGFloat {
        guard !items.isEmpty else {
            return 0
        }

        let itemWidths = items.reduce(CGFloat(0)) { partialResult, item in
            partialResult + itemWidth(for: item)
        }
        let separatorWidths = CGFloat(items.count - 1) * separatorWidth
        return ceil(itemWidths + separatorWidths)
    }

    static func itemWidth(for item: StatusSummaryItem) -> CGFloat {
        let sizingReference = sizingReference(for: item)
        let minimumWidth = sizingReference.style == .network ? networkMinimumWidth : metricMinimumWidth
        let horizontalPadding: CGFloat = sizingReference.style == .network ? 2 : 0
        let primaryWidth = textWidth(sizingReference.primaryText, font: primaryFont(for: sizingReference.style))
        let secondaryWidth = textWidth(sizingReference.secondaryText, font: secondaryFont(for: sizingReference.style))
        let baseWidth = max(minimumWidth, max(primaryWidth, secondaryWidth) + horizontalPadding)
        return ceil(baseWidth + additionalWidth(for: item))
    }

    static func fallbackWidth(for text: String) -> CGFloat {
        ceil(max(minimumTitleLength, textWidth(text, font: fallbackFont) + 10))
    }

    static func primaryFont(for style: StatusSummaryItemStyle) -> NSFont {
        .monospacedDigitSystemFont(ofSize: style == .network ? 8 : 10, weight: .heavy)
    }

    static func secondaryFont(for style: StatusSummaryItemStyle) -> NSFont {
        .monospacedDigitSystemFont(ofSize: style == .network ? 8 : 6, weight: style == .network ? .heavy : .bold)
    }

    // Use representative max-width samples per metric so the status item width
    // stays stable across live value changes.
    private static func sizingReference(for item: StatusSummaryItem) -> StatusSummaryItem {
        switch item.kind {
        case .cpu:
            return StatusSummaryItem(kind: .cpu, primaryText: "100%", secondaryText: "CPU", style: .metric)
        case .gpu:
            return StatusSummaryItem(kind: .gpu, primaryText: "100%", secondaryText: "GPU", style: .metric)
        case .disk:
            return StatusSummaryItem(kind: .disk, primaryText: "100%", secondaryText: "DISK", style: .metric)
        case .swap:
            return StatusSummaryItem(kind: .swap, primaryText: "100%", secondaryText: "SWAP", style: .metric)
        case .memory:
            return StatusSummaryItem(kind: .memory, primaryText: "100%", secondaryText: "MEM", style: .metric)
        case .vram:
            return StatusSummaryItem(kind: .vram, primaryText: "100%", secondaryText: "VRAM", style: .metric)
        case .network:
            return StatusSummaryItem(kind: .network, primaryText: "↑999.9M", secondaryText: "↓999.9M", style: .network)
        case .battery:
            return StatusSummaryItem(kind: .battery, primaryText: "100%", secondaryText: "BAT", style: .metric)
        case .temperature:
            return StatusSummaryItem(kind: .temperature, primaryText: "100℃", secondaryText: "BAT", style: .metric)
        case .fan:
            return StatusSummaryItem(kind: .fan, primaryText: "9999", secondaryText: "RPM", style: .metric)
        }
    }

    private static func additionalWidth(for item: StatusSummaryItem) -> CGFloat {
        switch item.kind {
        case .fan:
            return ceil(textWidth("0", font: primaryFont(for: .metric)) / 2)
        default:
            return 0
        }
    }

    private static func accessibilityTitle(summaryText: String, items: [StatusSummaryItem]) -> String {
        guard !items.isEmpty else {
            return summaryText
        }

        return items.map(accessibilityComponent(for:)).joined(separator: " | ")
    }

    private static func accessibilityComponent(for item: StatusSummaryItem) -> String {
        switch item.kind {
        case .fan:
            return item.primaryText == "--" ? "FAN --" : "FAN \(item.primaryText)RPM"
        case .network:
            return "\(item.primaryText) \(item.secondaryText)"
        default:
            return "\(item.secondaryText) \(item.primaryText)"
        }
    }

    private static func renderImage(
        summaryText: String,
        items: [StatusSummaryItem],
        size: NSSize
    ) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)

        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        if items.isEmpty {
            drawFallbackText(summaryText, in: NSRect(origin: .zero, size: size))
        } else {
            drawItems(items, in: NSRect(origin: .zero, size: size))
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func drawFallbackText(_ text: String, in rect: NSRect) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: fallbackFont,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraphStyle,
        ]
        let textHeight = ceil((text as NSString).size(withAttributes: attributes).height)
        let drawingRect = NSRect(
            x: rect.minX,
            y: rect.minY + floor((rect.height - textHeight) / 2),
            width: rect.width,
            height: textHeight
        )
        (text as NSString).draw(in: drawingRect, withAttributes: attributes)
    }

    private static func drawItems(_ items: [StatusSummaryItem], in rect: NSRect) {
        var x = rect.minX

        for (index, item) in items.enumerated() {
            let width = itemWidth(for: item)
            let itemRect = NSRect(x: x, y: rect.minY, width: width, height: rect.height)
            drawItem(item, in: itemRect)
            x += width

            if index < items.index(before: items.endIndex) {
                drawSeparator(atX: x, in: rect)
                x += separatorWidth
            }
        }
    }

    private static func drawItem(_ item: StatusSummaryItem, in rect: NSRect) {
        let alignment: NSTextAlignment = item.style == .network ? .left : .center
        let horizontalInset: CGFloat = item.style == .network ? 1 : 0
        let primaryAttributes = textAttributes(
            font: primaryFont(for: item.style),
            alignment: alignment
        )
        let secondaryAttributes = textAttributes(
            font: secondaryFont(for: item.style),
            alignment: alignment
        )
        let contentRect = rect.insetBy(dx: horizontalInset, dy: 0)
        let primaryRect = NSRect(
            x: contentRect.minX,
            y: contentRect.minY + 1,
            width: contentRect.width,
            height: item.style == .network ? 10 : 12
        )
        let secondaryRect = NSRect(
            x: contentRect.minX,
            y: contentRect.minY + (item.style == .network ? 10 : 13),
            width: contentRect.width,
            height: item.style == .network ? 10 : 8
        )

        (item.primaryText as NSString).draw(in: primaryRect, withAttributes: primaryAttributes)
        (item.secondaryText as NSString).draw(in: secondaryRect, withAttributes: secondaryAttributes)
    }

    private static func drawSeparator(atX x: CGFloat, in rect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        let dividerRect = NSRect(
            x: x + floor((separatorWidth - 1) / 2),
            y: rect.minY + floor((rect.height - 16) / 2),
            width: 1,
            height: 16
        )
        dividerRect.fill()
    }

    private static func textAttributes(
        font: NSFont,
        alignment: NSTextAlignment
    ) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byClipping

        return [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraphStyle,
        ]
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
