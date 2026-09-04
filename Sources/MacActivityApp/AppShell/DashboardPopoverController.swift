import AppKit
import SwiftUI
import MacActivityCore

@MainActor
protocol DashboardPopoverHosting: AnyObject {
    var behavior: NSPopover.Behavior { get set }
    var animates: Bool { get set }
    var contentSize: NSSize { get set }
    var contentViewController: NSViewController? { get set }
    var delegate: NSPopoverDelegate? { get set }
    var isShown: Bool { get }
    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge)
    func performClose(_ sender: Any?)
}

extension NSPopover: DashboardPopoverHosting {}

enum DashboardPopoverLayout {
    static let contentWidth: CGFloat = 420
    static let maximumHeight: CGFloat = 560

    static func contentSize(for measuredSize: NSSize) -> NSSize? {
        guard measuredSize.width.isFinite,
              measuredSize.width > 0,
              measuredSize.height.isFinite,
              measuredSize.height > 0 else {
            return nil
        }

        return NSSize(
            width: contentWidth,
            height: min(measuredSize.height, maximumHeight)
        )
    }
}

enum DashboardContentMeasurementSegment: CaseIterable, Hashable {
    case header
    case headerDivider
    case scrollContent
    case footerDivider
    case footer
}

@MainActor
final class DashboardPopoverContentMeasurement {
    var onContentSizeChange: ((NSSize) -> Void)?
    private(set) var latestContentSize: NSSize?
    private var heights: [DashboardContentMeasurementSegment: CGFloat] = [:]
    private var emissionGeneration = 0

    func seedIfNeeded(_ size: NSSize) {
        guard latestContentSize == nil,
              DashboardPopoverLayout.contentSize(for: size) != nil else {
            return
        }
        latestContentSize = size
    }

    func report(_ height: CGFloat, for segment: DashboardContentMeasurementSegment) {
        guard height.isFinite, height > 0, heights[segment] != height else {
            return
        }
        heights[segment] = height
        guard let size = resolvedContentSize(), latestContentSize != size else {
            return
        }
        latestContentSize = size
        emissionGeneration += 1
        let generation = emissionGeneration
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.latestContentSize == size,
                      self.emissionGeneration == generation else {
                    return
                }
                self.onContentSizeChange?(size)
            }
        }
    }

    func invalidatePendingEmissions() {
        emissionGeneration += 1
    }

    private func resolvedContentSize() -> NSSize? {
        guard DashboardContentMeasurementSegment.allCases.allSatisfy({ heights[$0] != nil }) else {
            return nil
        }
        return NSSize(
            width: DashboardPopoverLayout.contentWidth,
            height: DashboardContentMeasurementSegment.allCases.reduce(0) { total, segment in
                total + (heights[segment] ?? 0)
            }
        )
    }
}

typealias DashboardPopoverFrameAnimator = @MainActor (
    NSWindow,
    NSRect,
    @escaping @MainActor () -> Void
) -> Void

@MainActor
final class DashboardPopoverContentSizeCoordinator {
    private weak var popover: DashboardPopoverHosting?
    private var pendingContentSize: NSSize?
    private var isUpdateScheduled = false
    private var animationGeneration = 0
    private var animatingContentSize: NSSize?
    private var isHeightTransitioning = false
    private var usesPopoverPlacementUntilClose = false
    private let shouldReduceMotion: () -> Bool
    private let onHeightTransitionChange: (Bool) -> Void
    private let visibleFrameForWindow: (NSWindow) -> NSRect?
    private let animateFrame: DashboardPopoverFrameAnimator

    init(
        popover: DashboardPopoverHosting,
        shouldReduceMotion: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        onHeightTransitionChange: @escaping (Bool) -> Void = { _ in },
        visibleFrameForWindow: @escaping (NSWindow) -> NSRect? = { $0.screen?.visibleFrame },
        animateFrame: @escaping DashboardPopoverFrameAnimator = { window, frame, completion in
            NSAnimationContext.runAnimationGroup { _ in
                window.animator().setFrame(frame, display: true)
            } completionHandler: {
                MainActor.assumeIsolated {
                    completion()
                }
            }
        }
    ) {
        self.popover = popover
        self.shouldReduceMotion = shouldReduceMotion
        self.onHeightTransitionChange = onHeightTransitionChange
        self.visibleFrameForWindow = visibleFrameForWindow
        self.animateFrame = animateFrame
    }

    private func setHeightTransitioning(_ isHeightTransitioning: Bool) {
        guard self.isHeightTransitioning != isHeightTransitioning else { return }
        self.isHeightTransitioning = isHeightTransitioning
        onHeightTransitionChange(isHeightTransitioning)
    }

    func invalidateInFlightAnimation() {
        animationGeneration += 1
        animatingContentSize = nil
        setHeightTransitioning(false)
    }

    func resetAfterPopoverCloses() {
        usesPopoverPlacementUntilClose = false
        invalidateInFlightAnimation()
    }

    func applyImmediately(measuredSize: NSSize) {
        guard let contentSize = DashboardPopoverLayout.contentSize(for: measuredSize) else {
            return
        }
        pendingContentSize = nil
        apply(contentSize)
    }

    func schedule(measuredSize: NSSize) {
        guard let contentSize = DashboardPopoverLayout.contentSize(for: measuredSize) else {
            return
        }

        pendingContentSize = contentSize
        guard !isUpdateScheduled else {
            return
        }

        isUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.isUpdateScheduled = false
            guard let contentSize = self.pendingContentSize else {
                return
            }
            self.pendingContentSize = nil
            self.apply(contentSize)
        }
    }

    private func apply(_ contentSize: NSSize) {
        guard let popover else {
            return
        }

        if popover.contentSize == contentSize, animatingContentSize == nil {
            return
        }

        guard popover.isShown, let window = popover.contentViewController?.view.window else {
            invalidateInFlightAnimation()
            popover.contentSize = contentSize
            return
        }

        let proposedFrame = targetFrame(for: contentSize, in: window)
        // AppKit may change the arrow edge while fitting, so keep placement ownership until the next show.
        if usesPopoverPlacementUntilClose {
            applyUsingPopoverPlacement(contentSize, in: window, popover: popover)
            return
        }

        if let visibleFrame = visibleFrameForWindow(window),
           proposedFrame.minY < visibleFrame.minY {
            applyUsingPopoverPlacement(contentSize, in: window, popover: popover)
            return
        }

        guard !shouldReduceMotion() else {
            invalidateInFlightAnimation()
            snapFrame(to: contentSize, in: window)
            popover.contentSize = contentSize
            return
        }

        animateSizeChange(to: contentSize, in: window, popover: popover)
    }

    private func applyUsingPopoverPlacement(
        _ contentSize: NSSize,
        in window: NSWindow,
        popover: DashboardPopoverHosting
    ) {
        let wasAnimatingFrame = animatingContentSize != nil
        invalidateInFlightAnimation()
        if wasAnimatingFrame {
            stopFrameAnimation(in: window)
        }
        usesPopoverPlacementUntilClose = true

        let animates = popover.animates
        popover.animates = false
        popover.contentSize = contentSize
        popover.animates = animates
    }

    private func stopFrameAnimation(in window: NSWindow) {
        let currentFrame = window.frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().setFrame(currentFrame, display: true)
        }
    }

    private func targetFrame(for contentSize: NSSize, in window: NSWindow) -> NSRect {
        let contentFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        let currentFrame = window.frame
        return NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - contentFrame.height,
            width: contentFrame.width,
            height: contentFrame.height
        )
    }

    private func snapFrame(to contentSize: NSSize, in window: NSWindow) {
        let snappedFrame = targetFrame(for: contentSize, in: window)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().setFrame(snappedFrame, display: true)
        }
    }

    private func animateSizeChange(
        to contentSize: NSSize,
        in window: NSWindow,
        popover: DashboardPopoverHosting
    ) {
        guard animatingContentSize != contentSize else {
            return
        }

        let animatedFrame = targetFrame(for: contentSize, in: window)
        let currentFrame = window.frame
        guard animatedFrame != currentFrame else {
            invalidateInFlightAnimation()
            window.animator().setFrame(currentFrame, display: true)
            popover.contentSize = contentSize
            return
        }

        animationGeneration += 1
        animatingContentSize = contentSize
        let generation = animationGeneration
        setHeightTransitioning(true)

        animateFrame(window, animatedFrame) { [weak self] in
            guard let self, self.animationGeneration == generation else {
                return
            }
            self.animatingContentSize = nil
            guard let popover = self.popover else {
                return
            }
            popover.contentSize = contentSize
            self.setHeightTransitioning(false)
        }
    }
}

@MainActor
final class DashboardPopoverScrollIndicatorState: ObservableObject {
    @Published private(set) var isHeightTransitioning = false

    func setHeightTransitioning(_ isHeightTransitioning: Bool) {
        guard self.isHeightTransitioning != isHeightTransitioning else { return }
        self.isHeightTransitioning = isHeightTransitioning
    }
}

@MainActor
protocol DashboardPopoverFocusControlling: AnyObject {
    func activateApplication()
    func focusPresentedPopover(_ popover: DashboardPopoverHosting)
}

@MainActor
final class SharedDashboardPopoverFocusController: DashboardPopoverFocusControlling {
    func activateApplication() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func focusPresentedPopover(_ popover: DashboardPopoverHosting) {
        focusWindowIfAvailable(for: popover)
        DispatchQueue.main.async {
            self.focusWindowIfAvailable(for: popover)
        }
    }

    private func focusWindowIfAvailable(for popover: DashboardPopoverHosting) {
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class DashboardPopoverHostingController: NSHostingController<DashboardPopoverRootView> {
    func bootstrapContentSize() -> NSSize {
        _ = view
        view.layoutSubtreeIfNeeded()
        return NSSize(
            width: DashboardPopoverLayout.contentWidth,
            height: preferredContentSize.height
        )
    }

    func layoutContent() {
        _ = view
        view.layoutSubtreeIfNeeded()
    }

    var dashboardView: DashboardView {
        rootView.content
    }
}

struct DashboardPopoverRootView: View {
    let content: DashboardView

    var body: some View {
        content.frame(width: DashboardPopoverLayout.contentWidth, alignment: .topLeading)
    }
}

@MainActor
final class DashboardPopoverController: NSObject, NSPopoverDelegate {
    private let popover: DashboardPopoverHosting
    private let focusController: DashboardPopoverFocusControlling
    private let onVisibilityChange: (Bool) -> Void
    private let contentSizeCoordinator: DashboardPopoverContentSizeCoordinator
    private let dashboardHostingController: DashboardPopoverHostingController
    private let contentMeasurement: DashboardPopoverContentMeasurement
    private let scrollIndicatorState: DashboardPopoverScrollIndicatorState

    convenience init(
        dashboardModel: DashboardModel,
        preferencesController: PreferencesController,
        audioDashboardModel: AudioDashboardModel,
        onVisibilityChange: @escaping (Bool) -> Void,
        openPreferences: @escaping () -> Void,
        quitApplication: @escaping () -> Void
    ) {
        self.init(
            popover: NSPopover(),
            focusController: SharedDashboardPopoverFocusController(),
            dashboardModel: dashboardModel,
            preferencesController: preferencesController,
            audioDashboardModel: audioDashboardModel,
            onVisibilityChange: onVisibilityChange,
            openPreferences: openPreferences,
            quitApplication: quitApplication
        )
    }

    init(
        popover: DashboardPopoverHosting,
        focusController: DashboardPopoverFocusControlling,
        dashboardModel: DashboardModel,
        preferencesController: PreferencesController,
        audioDashboardModel: AudioDashboardModel,
        onVisibilityChange: @escaping (Bool) -> Void,
        openPreferences: @escaping () -> Void,
        quitApplication: @escaping () -> Void
    ) {
        self.popover = popover
        self.focusController = focusController
        self.onVisibilityChange = onVisibilityChange

        let scrollIndicatorState = DashboardPopoverScrollIndicatorState()
        let contentSizeCoordinator = DashboardPopoverContentSizeCoordinator(
            popover: popover,
            onHeightTransitionChange: { [weak scrollIndicatorState] isHeightTransitioning in
                scrollIndicatorState?.setHeightTransitioning(isHeightTransitioning)
            }
        )
        let measurement = DashboardPopoverContentMeasurement()
        let dashboardHostingController = DashboardPopoverHostingController(
            rootView: DashboardPopoverRootView(
                content: DashboardView(
                    dashboardModel: dashboardModel,
                    preferencesController: preferencesController,
                    audioDashboardModel: audioDashboardModel,
                    openPreferences: { [weak popover] in
                        popover?.performClose(nil)
                        openPreferences()
                    },
                    quitApplication: { [weak popover] in
                        popover?.performClose(nil)
                        quitApplication()
                    },
                    onMeasuredSegmentHeight: { [weak measurement] segment, height in
                        measurement?.report(height, for: segment)
                    },
                    scrollIndicatorState: scrollIndicatorState
                )
            )
        )
        measurement.onContentSizeChange = { [weak contentSizeCoordinator] size in
            contentSizeCoordinator?.schedule(measuredSize: size)
        }

        dashboardHostingController.sizingOptions = [.preferredContentSize]
        let bootstrapSize = dashboardHostingController.bootstrapContentSize()
        measurement.seedIfNeeded(bootstrapSize)
        dashboardHostingController.sizingOptions = []

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = dashboardHostingController
        measurement.invalidatePendingEmissions()
        contentSizeCoordinator.applyImmediately(
            measuredSize: measurement.latestContentSize ?? bootstrapSize
        )

        self.contentSizeCoordinator = contentSizeCoordinator
        self.dashboardHostingController = dashboardHostingController
        self.contentMeasurement = measurement
        self.scrollIndicatorState = scrollIndicatorState
        super.init()
        popover.delegate = self
    }

    func toggle(relativeTo view: NSView?) {
        guard let view else {
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            focusController.activateApplication()
            dashboardHostingController.layoutContent()
            contentMeasurement.invalidatePendingEmissions()
            if let latestContentSize = contentMeasurement.latestContentSize {
                contentSizeCoordinator.applyImmediately(measuredSize: latestContentSize)
            }
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            focusController.focusPresentedPopover(popover)
            onVisibilityChange(true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        contentSizeCoordinator.resetAfterPopoverCloses()
        onVisibilityChange(false)
    }

    #if DEBUG
    var testingAudioDashboardModel: AudioDashboardModel? {
        (popover.contentViewController as? DashboardPopoverHostingController)?.dashboardView.audioDashboardModel
    }

    var testingContentSizeCoordinator: DashboardPopoverContentSizeCoordinator {
        contentSizeCoordinator
    }

    var testingScrollIndicatorState: DashboardPopoverScrollIndicatorState {
        scrollIndicatorState
    }
    #endif
}
