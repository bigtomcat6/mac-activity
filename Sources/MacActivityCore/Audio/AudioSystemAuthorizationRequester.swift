import Darwin
import Foundation

public protocol AudioSystemAuthorizationRequesting: AnyObject, Sendable {
    func requestAuthorization() async -> AudioSystemAuthorizationStatus
    func shutdown() async
}

final class AudioSystemAuthorizationRequestLease: @unchecked Sendable {
    private let value: AnyObject

    init(retaining value: AnyObject) {
        self.value = value
    }
}

public actor AudioSystemAuthorizationRequester: AudioSystemAuthorizationRequesting {
    typealias RawRequest = @Sendable (
        @escaping @Sendable (Bool) -> Void
    ) -> AudioSystemAuthorizationRequestLease?

    private struct InFlightRequest {
        let id: UUID
        let lease: AudioSystemAuthorizationRequestLease
        let callbackGate: AudioSystemAuthorizationCallbackGate
        var waiters: [UUID: AudioSystemAuthorizationWaiter]
        var isAbandoned: Bool
    }

    private let availability: AudioFeatureAvailability
    private let rawRequest: RawRequest
    private var inFlightRequest: InFlightRequest?
    private var queuedWaiters: [UUID: AudioSystemAuthorizationWaiter] = [:]
    private var requestAPIUnavailable = false
    private var isShuttingDown = false
    #if DEBUG
    private var queuedWaiterRegistrationObserver: (@Sendable () -> Void)?
    #endif

    public init(availability: AudioFeatureAvailability = .current) {
        self.init(availability: availability) { completion in
            guard let request = TCCAudioAuthorizationRequest() else { return nil }
            request.start(completion)
            return AudioSystemAuthorizationRequestLease(retaining: request)
        }
    }

    init(
        availability: AudioFeatureAvailability,
        rawRequest: @escaping RawRequest
    ) {
        self.availability = availability
        self.rawRequest = rawRequest
    }

    public func requestAuthorization() async -> AudioSystemAuthorizationStatus {
        let waiter = AudioSystemAuthorizationWaiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.install(continuation)
                register(waiter)
            }
        } onCancel: {
            waiter.cancel()
            Task { await self.removeCancelledWaiter(waiter) }
        }
    }

    public func shutdown() async {
        isShuttingDown = true
        finishAllWaiters(with: .unavailable)
    }

    #if DEBUG
    /// Test-only synchronization for callers queued behind an abandoned native request.
    func testingObserveQueuedWaiterRegistration(_ observer: @escaping @Sendable () -> Void) {
        queuedWaiterRegistrationObserver = observer
    }
    #endif

    private func register(_ waiter: AudioSystemAuthorizationWaiter) {
        guard isShuttingDown == false,
              availability.supportsProcessControls,
              requestAPIUnavailable == false,
              waiter.isCancelled == false
        else {
            waiter.finish(with: .unavailable)
            return
        }

        pruneCancelledWaiters()
        if var inFlightRequest {
            if inFlightRequest.isAbandoned {
                // The pending native callback belongs to an invalidated request epoch.
                queuedWaiters[waiter.id] = waiter
                #if DEBUG
                queuedWaiterRegistrationObserver?()
                #endif
            } else {
                inFlightRequest.waiters[waiter.id] = waiter
                self.inFlightRequest = inFlightRequest
            }
            return
        }

        guard waiter.claimsRequestStart else { return }
        startRequest(with: [waiter.id: waiter])
    }

    private func startRequest(with waiters: [UUID: AudioSystemAuthorizationWaiter]) {
        guard waiters.isEmpty == false else { return }
        guard isShuttingDown == false,
              availability.supportsProcessControls,
              requestAPIUnavailable == false else {
            finish(waiters, with: .unavailable)
            return
        }

        let id = UUID()
        let callbackGate = AudioSystemAuthorizationCallbackGate { [self] granted in
            Task { await self.finishRequest(id: id, granted: granted) }
        }
        let callback: @Sendable (Bool) -> Void = { granted in
            // Preserve native callback order before crossing into the actor executor.
            callbackGate.receive(granted)
        }
        guard let lease = rawRequest(callback) else {
            requestAPIUnavailable = true
            finish(waiters, with: .unavailable)
            finishQueuedWaiters(with: .unavailable)
            return
        }
        inFlightRequest = .init(
            id: id,
            lease: lease,
            callbackGate: callbackGate,
            waiters: waiters,
            isAbandoned: false
        )
    }

    private func removeCancelledWaiter(_ waiter: AudioSystemAuthorizationWaiter) {
        if var inFlightRequest {
            inFlightRequest.waiters.removeValue(forKey: waiter.id)
            if inFlightRequest.waiters.isEmpty {
                inFlightRequest.isAbandoned = true
            }
            self.inFlightRequest = inFlightRequest
        }
        queuedWaiters.removeValue(forKey: waiter.id)
    }

    private func finishRequest(id: UUID, granted: Bool) {
        pruneCancelledWaiters()
        guard let request = inFlightRequest, request.id == id else { return }
        inFlightRequest = nil
        guard isShuttingDown == false else { return }
        if request.isAbandoned == false {
            finish(request.waiters, with: granted ? .authorized : .denied)
        }
        startQueuedRequestIfNeeded()
    }

    private func finishAllWaiters(with status: AudioSystemAuthorizationStatus) {
        var pendingWaiters = Array(queuedWaiters.values)
        queuedWaiters.removeAll()
        if var inFlightRequest {
            pendingWaiters += inFlightRequest.waiters.values
            inFlightRequest.waiters.removeAll()
            inFlightRequest.isAbandoned = true
            self.inFlightRequest = inFlightRequest
        }
        pendingWaiters.forEach { $0.finish(with: status) }
    }

    private func finish(
        _ waiters: [UUID: AudioSystemAuthorizationWaiter],
        with status: AudioSystemAuthorizationStatus
    ) {
        waiters.values.forEach { $0.finish(with: status) }
    }

    private func finishQueuedWaiters(with status: AudioSystemAuthorizationStatus) {
        let pendingWaiters = queuedWaiters
        queuedWaiters.removeAll()
        finish(pendingWaiters, with: status)
    }

    private func pruneCancelledWaiters() {
        if var inFlightRequest {
            inFlightRequest.waiters = inFlightRequest.waiters.filter {
                $0.value.isCancelled == false
            }
            if inFlightRequest.waiters.isEmpty {
                inFlightRequest.isAbandoned = true
            }
            self.inFlightRequest = inFlightRequest
        }
        queuedWaiters = queuedWaiters.filter { $0.value.isCancelled == false }
    }

    private func startQueuedRequestIfNeeded() {
        guard inFlightRequest == nil else { return }
        pruneCancelledWaiters()
        guard queuedWaiters.isEmpty == false else { return }
        let waiters = queuedWaiters
        queuedWaiters.removeAll()
        startRequest(with: waiters)
    }
}

private final class AudioSystemAuthorizationWaiter: @unchecked Sendable {
    let id = UUID()

    private let lock = NSLock()
    private var continuation: CheckedContinuation<AudioSystemAuthorizationStatus, Never>?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var claimsRequestStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled == false
    }

    func install(_ continuation: CheckedContinuation<AudioSystemAuthorizationStatus, Never>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(returning: .unavailable)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func cancel() {
        let result = takeContinuation(markingCancelled: true)
        result.continuation?.resume(returning: .unavailable)
    }

    func finish(with status: AudioSystemAuthorizationStatus) {
        let result = takeContinuation(markingCancelled: false)
        result.continuation?.resume(returning: result.cancelled ? .unavailable : status)
    }

    private func takeContinuation(
        markingCancelled: Bool
    ) -> (
        continuation: CheckedContinuation<AudioSystemAuthorizationStatus, Never>?,
        cancelled: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        if markingCancelled {
            cancelled = true
        }
        let continuation = continuation
        self.continuation = nil
        return (continuation, cancelled)
    }
}

private final class AudioSystemAuthorizationCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private let deliver: @Sendable (Bool) -> Void
    private var didReceiveCallback = false

    init(deliver: @escaping @Sendable (Bool) -> Void) {
        self.deliver = deliver
    }

    func receive(_ granted: Bool) {
        lock.lock()
        guard didReceiveCallback == false else {
            lock.unlock()
            return
        }
        didReceiveCallback = true
        lock.unlock()
        deliver(granted)
    }
}

private typealias TCCAccessRequest = @convention(c) (
    CFString,
    CFDictionary?,
    @convention(block) @escaping (Bool) -> Void
) -> Void

private final class TCCAudioAuthorizationRequest: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    private let request: TCCAccessRequest

    init?() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC",
            RTLD_NOW
        ) else {
            return nil
        }
        guard let symbol = dlsym(handle, "TCCAccessRequest") else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        request = unsafeBitCast(symbol, to: TCCAccessRequest.self)
    }

    deinit {
        dlclose(handle)
    }

    func start(_ completion: @escaping @Sendable (Bool) -> Void) {
        request("kTCCServiceAudioCapture" as CFString, nil) { [self] granted in
            // The native block retains this handle until TCC releases the callback.
            withExtendedLifetime(self) {
                completion(granted)
            }
        }
    }
}
