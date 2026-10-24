import AppKit
import MacActivityBatteryControl

@MainActor
final class BatteryCareLifecycleBridge {
    private let model: BatteryCareModel
    private let center: NotificationCenter
    private var removeObservers: (@MainActor @Sendable () -> Void)?
    private var delivery: Task<Void, Never>?
    private var continuation: AsyncStream<BatteryCareLifecycleEvent>.Continuation?

    init(model: BatteryCareModel, workspaceCenter: NotificationCenter) {
        self.model = model
        center = workspaceCenter
    }

    func start() {
        guard delivery == nil else { return }
        let (stream, continuation) = AsyncStream<BatteryCareLifecycleEvent>.makeStream()
        self.continuation = continuation
        // Yield synchronously on the posting thread; one MainActor consumer preserves sleep/wake order.
        let observers = [(NSWorkspace.willSleepNotification, BatteryCareLifecycleEvent.willSleep),
                         (NSWorkspace.didWakeNotification, .didWake)].map { name, event in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                continuation.yield(event)
            }
        }
        removeObservers = { [center] in observers.forEach(center.removeObserver) }
        delivery = Task { @MainActor [model] in
            var previous: BatteryCareLifecycleEvent?
            for await event in stream {
                guard !Task.isCancelled else { return }
                guard previous != event else { continue }
                previous = event
                await model.handleLifecycle(event)
            }
        }
    }

    func stop() {
        removeObservers?()
        removeObservers = nil
        continuation?.finish()
        continuation = nil
        delivery?.cancel()
        delivery = nil
    }

    deinit {
        continuation?.finish()
        delivery?.cancel()
        let removeObservers = removeObservers
        DispatchQueue.main.async { removeObservers?() }
    }
}
