import AppKit
import Combine
import MacActivityCore

@MainActor
final class StatusItemController {
    private let summaryModel: StatusSummaryModel
    private let popoverController: DashboardPopoverController
    private var statusItem: NSStatusItem?
    private var summaryView: StatusBarSummaryView?
    private var cancellables: Set<AnyCancellable> = []
    private var currentSummary: RenderedStatusSummary?

    init(
        summaryModel: StatusSummaryModel,
        popoverController: DashboardPopoverController
    ) {
        self.summaryModel = summaryModel
        self.popoverController = popoverController
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
        let summaryView = installSummaryViewIfNeeded(onto: statusItem)
        summaryView.mouseDownHandler = { [weak self] in
            self?.togglePopover()
        }
        render(
            summaryText: summaryModel.summaryText,
            items: summaryModel.summaryItems,
            onto: statusItem
        )

        Publishers.CombineLatest(summaryModel.$summaryText, summaryModel.$summaryItems)
            .sink { [weak self] summaryText, items in
                self?.render(summaryText: summaryText, items: items)
            }
            .store(in: &cancellables)

        self.statusItem = statusItem
    }

    func remove() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }

        statusItem = nil
        summaryView = nil
        currentSummary = nil
        cancellables.removeAll()
    }

    private func togglePopover() {
        popoverController.toggle(relativeTo: summaryView)
    }

    private func render(
        summaryText: String,
        items: [StatusSummaryItem],
        onto statusItem: NSStatusItem? = nil
    ) {
        let nextSummary = RenderedStatusSummary(text: summaryText, items: items)
        guard currentSummary != nextSummary else {
            return
        }

        let targetStatusItem = statusItem ?? self.statusItem
        guard let targetStatusItem else {
            return
        }

        let summaryView = installSummaryViewIfNeeded(onto: targetStatusItem)
        summaryView.update(summaryText: summaryText, items: items)
        targetStatusItem.length = summaryView.frame.width

        currentSummary = nextSummary
    }

    private func installSummaryViewIfNeeded(onto statusItem: NSStatusItem) -> StatusBarSummaryView {
        if let summaryView {
            return summaryView
        }

        let summaryView = StatusBarSummaryView(frame: NSRect(x: 0, y: 0, width: 44, height: 22))
        statusItem.view = summaryView
        self.summaryView = summaryView
        return summaryView
    }
}

private struct RenderedStatusSummary: Equatable {
    var text: String
    var items: [StatusSummaryItem]
}

private final class StatusBarSummaryView: NSView {
    private let stackView: NSStackView
    var mouseDownHandler: (() -> Void)?

    override init(frame frameRect: NSRect) {
        stackView = NSStackView()
        super.init(frame: frameRect)

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .gravityAreas
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownHandler?()
    }

    func update(summaryText: String, items: [StatusSummaryItem]) {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if items.isEmpty {
            stackView.addArrangedSubview(StatusBarFallbackSummaryView(text: summaryText))
            frame.size = NSSize(
                width: StatusBarSummaryLayout.fallbackWidth(for: summaryText),
                height: 22
            )
            return
        }

        for (index, item) in items.enumerated() {
            stackView.addArrangedSubview(StatusBarSummaryItemView(item: item))

            if index < items.index(before: items.endIndex) {
                stackView.addArrangedSubview(StatusBarSummarySeparatorView())
            }
        }
        frame.size = NSSize(width: StatusBarSummaryLayout.preferredWidth(for: items), height: 22)
        invalidateIntrinsicContentSize()
    }
}

private final class StatusBarFallbackSummaryView: NSView {
    init(text: String) {
        super.init(frame: .zero)

        let label = NSTextField(labelWithString: text)
        label.font = StatusBarSummaryLayout.fallbackFont
        label.textColor = .controlTextColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class StatusBarSummaryItemView: NSStackView {
    init(item: StatusSummaryItem) {
        super.init(frame: .zero)

        orientation = .vertical
        alignment = item.style == .network ? .leading : .centerX
        distribution = .gravityAreas
        spacing = -1
        edgeInsets = item.style == .network
            ? NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)
            : NSEdgeInsets(top: 1, left: 0, bottom: 1, right: 0)

        let primaryLabel = NSTextField(labelWithString: item.primaryText)
        primaryLabel.font = StatusBarSummaryLayout.primaryFont(for: item.style)
        primaryLabel.textColor = .controlTextColor
        primaryLabel.alignment = item.style == .network ? .left : .center
        primaryLabel.lineBreakMode = .byClipping
        primaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let secondaryLabel = NSTextField(labelWithString: item.secondaryText)
        secondaryLabel.font = StatusBarSummaryLayout.secondaryFont(for: item.style)
        secondaryLabel.textColor = .controlTextColor
        secondaryLabel.alignment = item.style == .network ? .left : .center
        secondaryLabel.lineBreakMode = .byClipping
        secondaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addArrangedSubview(primaryLabel)
        addArrangedSubview(secondaryLabel)

        widthAnchor.constraint(equalToConstant: StatusBarSummaryLayout.itemWidth(for: item)).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class StatusBarSummarySeparatorView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: StatusBarSummaryLayout.separatorWidth, height: 22)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.controlTextColor.withAlphaComponent(0.35).setFill()
        let dividerRect = NSRect(
            x: floor((bounds.width - 1) / 2),
            y: floor((bounds.height - 16) / 2),
            width: 1,
            height: 16
        )
        dividerRect.fill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

enum StatusBarSummaryLayout {
    static let metricMinimumWidth: CGFloat = 26
    static let networkMinimumWidth: CGFloat = 34
    static let separatorWidth: CGFloat = 2
    static var fallbackFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
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
        ceil(max(44, textWidth(text, font: fallbackFont) + 10))
    }

    static func primaryFont(for style: StatusSummaryItemStyle) -> NSFont {
        .monospacedDigitSystemFont(ofSize: style == .network ? 8 : 10, weight: .semibold)
    }

    static func secondaryFont(for style: StatusSummaryItemStyle) -> NSFont {
        .monospacedDigitSystemFont(ofSize: style == .network ? 7 : 6, weight: .semibold)
    }

    // Use representative max-width samples per metric so the status item width
    // stays stable across live value changes.
    private static func sizingReference(for item: StatusSummaryItem) -> StatusSummaryItem {
        switch item.kind {
        case .cpu:
            return StatusSummaryItem(kind: .cpu, primaryText: "100%", secondaryText: "CPU", style: .metric)
        case .gpu:
            return StatusSummaryItem(kind: .gpu, primaryText: "100%", secondaryText: "GPU", style: .metric)
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

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
