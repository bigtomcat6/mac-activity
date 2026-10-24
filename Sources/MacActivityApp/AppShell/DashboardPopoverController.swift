import AppKit
import Combine
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
    var availableContentHeight: CGFloat { get }
    var onAvailableContentHeightChange: (() -> Void)? { get set }
    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge)
    func performClose(_ sender: Any?)
}

extension DashboardPopoverHosting {
    var availableContentHeight: CGFloat { .greatestFiniteMagnitude }
    var onAvailableContentHeightChange: (() -> Void)? {
        get { nil }
        set { }
    }
}

extension NSPopover: DashboardPopoverHosting {}

enum DashboardPopoverLayout {
    static let contentWidth: CGFloat = 420
    static let maximumHeight: CGFloat = 560

    static func contentSize(
        for measuredSize: NSSize,
        batteryCareHeight: CGFloat = 0,
        availableHeight: CGFloat = .greatestFiniteMagnitude
    ) -> NSSize? {
        guard measuredSize.width.isFinite,
              measuredSize.width > 0,
              measuredSize.height.isFinite,
              measuredSize.height > 0,
              batteryCareHeight.isFinite, batteryCareHeight >= 0,
              availableHeight.isFinite, availableHeight > 0 else {
            return nil
        }

        return NSSize(
            width: contentWidth,
            height: min(measuredSize.height, maximumHeight + batteryCareHeight, availableHeight)
        )
    }
}

enum DashboardContentMeasurementSegment: CaseIterable, Hashable {
    case batteryCare
    case header
    case headerDivider
    case scrollContent
}

@MainActor
final class DashboardPopoverContentMeasurement {
    var onContentSizeChange: ((NSSize) -> Void)?
    private(set) var latestContentSize: NSSize?
    private var heights: [DashboardContentMeasurementSegment: CGFloat] = [:]
    private var emissionGeneration = 0
    private var hasCompleteMeasurement = false

    var batteryCareHeight: CGFloat { heights[.batteryCare] ?? 0 }

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
        guard let size = resolvedContentSize(),
              !hasCompleteMeasurement || latestContentSize != size || segment == .batteryCare else {
            return
        }
        hasCompleteMeasurement = true
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
        let height = DashboardContentMeasurementSegment.allCases.reduce(0) { total, segment in
            total + (heights[segment] ?? 0)
        }
        guard height.isFinite else { return nil }
        return NSSize(width: DashboardPopoverLayout.contentWidth, height: height)
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
    var dashboardRootIdentity: ObjectIdentifier?
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
    private let batteryCareHeight: () -> CGFloat
    private let availableContentHeight: () -> CGFloat

    init(
        popover: DashboardPopoverHosting,
        batteryCareHeight: @escaping () -> CGFloat = { 0 },
        availableContentHeight: (() -> CGFloat)? = nil,
        shouldReduceMotion: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        onHeightTransitionChange: @escaping (Bool) -> Void = { _ in },
        visibleFrameForWindow: @escaping (NSWindow) -> NSRect? = { $0.screen?.visibleFrame },
        animateFrame: DashboardPopoverFrameAnimator? = nil
    ) {
        self.popover = popover
        self.batteryCareHeight = batteryCareHeight
        self.availableContentHeight = availableContentHeight ?? { [weak popover] in
            popover?.availableContentHeight ?? .greatestFiniteMagnitude
        }
        self.shouldReduceMotion = shouldReduceMotion
        self.onHeightTransitionChange = onHeightTransitionChange
        self.visibleFrameForWindow = visibleFrameForWindow
        self.animateFrame = animateFrame ?? { window, frame, completion in
            NSAnimationContext.runAnimationGroup { _ in
                window.animator().setFrame(frame, display: true)
            } completionHandler: {
                MainActor.assumeIsolated {
                    completion()
                }
            }
        }
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

    func applyImmediately(measuredSize: NSSize, allowsAnimation: Bool = true) {
        guard let contentSize = DashboardPopoverLayout.contentSize(for: measuredSize,
            batteryCareHeight: batteryCareHeight(), availableHeight: availableContentHeight()) else {
            return
        }
        pendingContentSize = nil
        apply(contentSize, allowsAnimation: allowsAnimation)
    }

    func schedule(measuredSize: NSSize) {
        guard DashboardPopoverLayout.contentSize(for: measuredSize,
            batteryCareHeight: batteryCareHeight(), availableHeight: availableContentHeight()) != nil else {
            return
        }

        pendingContentSize = measuredSize
        guard !isUpdateScheduled else {
            return
        }

        isUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.isUpdateScheduled = false
            if let identity = self.dashboardRootIdentity,
               self.popover?.contentViewController.map(ObjectIdentifier.init) != identity {
                self.pendingContentSize = nil
                return
            }
            guard let measuredSize = self.pendingContentSize else {
                return
            }
            self.applyImmediately(measuredSize: measuredSize)
        }
    }

    private func apply(_ contentSize: NSSize, allowsAnimation: Bool = true) {
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

        guard allowsAnimation, !shouldReduceMotion() else {
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
        let rootIdentity = popover.contentViewController.map(ObjectIdentifier.init)
        setHeightTransitioning(true)

        animateFrame(window, animatedFrame) { [weak self] in
            guard let self, self.animationGeneration == generation else {
                return
            }
            self.animatingContentSize = nil
            guard let popover = self.popover else {
                return
            }
            guard popover.contentViewController.map(ObjectIdentifier.init) == rootIdentity else { return }
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
        guard popover.isShown, let window = popover.contentViewController?.view.window else { return }
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak popover, weak window] in
            guard let popover, let window, popover.isShown,
                  popover.contentViewController?.view.window === window else { return }
            window.makeKeyAndOrderFront(nil)
        }
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

    var dashboardTabSelection: DashboardTabSelectionState {
        rootView.content.tabSelectionState
    }
}

struct DashboardPopoverRootView: View {
    let content: DashboardView
    @ObservedObject var presentationState: DashboardPresentationState

    var body: some View {
        content
            .frame(width: DashboardPopoverLayout.contentWidth, alignment: .topLeading)
            .environment(\.dashboardPresentationIsPresented, presentationState.isPresented)
    }
}

@MainActor
final class DashboardPopoverController: NSObject, NSPopoverDelegate {
    private let popover: DashboardPopoverHosting
    private let focusController: DashboardPopoverFocusControlling
    private let onVisibilityChange: @MainActor (Bool) -> Void
    private let contentSizeCoordinator: DashboardPopoverContentSizeCoordinator
    private let dashboardHostingController: DashboardPopoverHostingController
    private let contentMeasurement: DashboardPopoverContentMeasurement
    private let scrollIndicatorState: DashboardPopoverScrollIndicatorState
    private let presentationState: DashboardPresentationState
    private var reportedVisible = false
    private let cleanupOnDeinit: @MainActor @Sendable (Bool) -> Void

    convenience init(
        dashboardModel: DashboardModel,
        preferencesController: PreferencesController,
        audioDashboardModel: AudioDashboardModel,
        batteryCareModel: BatteryCareModel,
        onVisibilityChange: @escaping @MainActor (Bool) -> Void
    ) {
        self.init(
            popover: DashboardAdaptivePopoverHost(),
            focusController: SharedDashboardPopoverFocusController(),
            dashboardModel: dashboardModel,
            preferencesController: preferencesController,
            audioDashboardModel: audioDashboardModel,
            batteryCareModel: batteryCareModel,
            onVisibilityChange: onVisibilityChange
        )
    }

    init(
        popover: DashboardPopoverHosting,
        focusController: DashboardPopoverFocusControlling,
        dashboardModel: DashboardModel,
        preferencesController: PreferencesController,
        audioDashboardModel: AudioDashboardModel,
        batteryCareModel: BatteryCareModel,
        onVisibilityChange: @escaping @MainActor (Bool) -> Void,
        presentationState: DashboardPresentationState = DashboardPresentationState(),
        frameAnimator: DashboardPopoverFrameAnimator? = nil
    ) {
        self.popover = popover
        self.focusController = focusController
        self.onVisibilityChange = onVisibilityChange
        self.presentationState = presentationState

        let scrollIndicatorState = DashboardPopoverScrollIndicatorState()
        let tabSelectionState = DashboardTabSelectionState()
        let measurement = DashboardPopoverContentMeasurement()
        let contentSizeCoordinator = DashboardPopoverContentSizeCoordinator(
            popover: popover,
            batteryCareHeight: { [weak measurement] in measurement?.batteryCareHeight ?? 0 },
            onHeightTransitionChange: { [weak scrollIndicatorState] isHeightTransitioning in
                scrollIndicatorState?.setHeightTransitioning(isHeightTransitioning)
            },
            animateFrame: frameAnimator
        )
        let dashboardHostingController = DashboardPopoverHostingController(
            rootView: DashboardPopoverRootView(
                content: DashboardView(
                    dashboardModel: dashboardModel,
                    preferencesController: preferencesController,
                    audioDashboardModel: audioDashboardModel,
                    batteryCareModel: batteryCareModel,
                    onMeasuredSegmentHeight: { [weak measurement] segment, height in
                        measurement?.report(height, for: segment)
                    },
                    scrollIndicatorState: scrollIndicatorState,
                    tabSelectionState: tabSelectionState
                ),
                presentationState: presentationState
            )
        )
        measurement.onContentSizeChange = { [weak contentSizeCoordinator] size in
            contentSizeCoordinator?.schedule(measuredSize: size)
        }
        popover.onAvailableContentHeightChange = { [weak contentSizeCoordinator, weak measurement,
                                                    weak dashboardHostingController, weak popover] in
            guard let root = dashboardHostingController, popover?.contentViewController === root,
                  let size = measurement?.latestContentSize else { return }
            contentSizeCoordinator?.applyImmediately(measuredSize: size, allowsAnimation: false)
        }

        dashboardHostingController.sizingOptions = [.preferredContentSize]
        let bootstrapSize = dashboardHostingController.bootstrapContentSize()
        measurement.seedIfNeeded(bootstrapSize)
        dashboardHostingController.sizingOptions = []

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = dashboardHostingController
        let rootIdentity = ObjectIdentifier(dashboardHostingController)
        contentSizeCoordinator.dashboardRootIdentity = rootIdentity
        measurement.invalidatePendingEmissions()
        contentSizeCoordinator.applyImmediately(
            measuredSize: measurement.latestContentSize ?? bootstrapSize
        )

        self.contentSizeCoordinator = contentSizeCoordinator
        self.dashboardHostingController = dashboardHostingController
        self.contentMeasurement = measurement
        self.scrollIndicatorState = scrollIndicatorState
        cleanupOnDeinit = { [weak popover] reportedVisible in
            measurement.invalidatePendingEmissions()
            contentSizeCoordinator.resetAfterPopoverCloses()
            scrollIndicatorState.setHeightTransitioning(false)
            // A live host with a different root belongs to a successor. A released
            // controller-owned host must not prevent its logical model teardown.
            if let popover,
               popover.contentViewController.map(ObjectIdentifier.init) != rootIdentity { return }
            popover?.onAvailableContentHeightChange = nil
            presentationState.setPresented(false)
            batteryCareModel.cancelPreview()
            audioDashboardModel.audioPageDeactivated()
            if let popover {
                popover.delegate = nil
                if let adaptiveHost = popover as? DashboardAdaptivePopoverHost {
                    adaptiveHost.invalidate()
                } else if let nativePopover = popover as? NSPopover {
                    nativePopover.animates = false
                    nativePopover.close()
                } else {
                    popover.animates = false
                    popover.performClose(nil)
                }
            }
            if reportedVisible { onVisibilityChange(false) }
        }
        super.init()
        popover.delegate = self
    }

    deinit {
        let cleanup = cleanupOnDeinit
        let reportedVisible = reportedVisible
        DispatchQueue.main.async { cleanup(reportedVisible) }
    }

    func toggle(relativeTo view: NSView?) {
        guard let view else {
            return
        }

        if popover.isShown {
            dashboardHostingController.dashboardView.batteryCareModel.cancelPreview()
            popover.performClose(nil)
            if !popover.isShown { closePresentation() }
        } else {
            focusController.activateApplication()
            dashboardHostingController.layoutContent()
            contentMeasurement.invalidatePendingEmissions()
            if let latestContentSize = contentMeasurement.latestContentSize {
                contentSizeCoordinator.applyImmediately(measuredSize: latestContentSize)
            }
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            guard popover.isShown else {
                return
            }
            presentationState.setPresented(true)
            focusController.focusPresentedPopover(popover)
            if !reportedVisible {
                reportedVisible = true
                onVisibilityChange(true)
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard !popover.isShown else { return }
        closePresentation()
    }

    func popoverWillClose(_ notification: Notification) {
        closePresentation()
    }

    private func closePresentation() {
        contentMeasurement.invalidatePendingEmissions()
        contentSizeCoordinator.resetAfterPopoverCloses()
        scrollIndicatorState.setHeightTransitioning(false)
        presentationState.setPresented(false)
        dashboardHostingController.dashboardView.batteryCareModel.cancelPreview()
        dashboardHostingController.dashboardView.audioDashboardModel.audioPageDeactivated()
        if reportedVisible {
            reportedVisible = false
            onVisibilityChange(false)
        }
    }

    #if DEBUG
    var testingBatteryCareModel: BatteryCareModel? {
        (popover.contentViewController as? DashboardPopoverHostingController)?.dashboardView.batteryCareModel
    }

    var testingAudioDashboardModel: AudioDashboardModel? {
        (popover.contentViewController as? DashboardPopoverHostingController)?.dashboardView.audioDashboardModel
    }

    var testingContentSizeCoordinator: DashboardPopoverContentSizeCoordinator {
        contentSizeCoordinator
    }

    var testingContentMeasurement: DashboardPopoverContentMeasurement { contentMeasurement }

    var testingScrollIndicatorState: DashboardPopoverScrollIndicatorState {
        scrollIndicatorState
    }
    #endif
}
