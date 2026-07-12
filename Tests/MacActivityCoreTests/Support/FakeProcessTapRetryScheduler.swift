import Dispatch
import Foundation

@testable import MacActivityCore

final class FakeProcessTapRetryScheduler: ProcessTapRetryScheduling, @unchecked Sendable {
    private final class Cancellation: ProcessTapRetryCancellation, @unchecked Sendable {
        private let cancelAction: @Sendable () -> Void

        init(_ cancelAction: @escaping @Sendable () -> Void) {
            self.cancelAction = cancelAction
        }

        func cancel() {
            cancelAction()
        }
    }

    private struct Pending {
        let id: UUID
        let action: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var pending: Pending?
    private var capturedActions: [@Sendable () -> Void] = []
    private var delays: [DispatchTimeInterval] = []

    var pendingCount: Int {
        locked { pending == nil ? 0 : 1 }
    }

    var scheduledDelays: [DispatchTimeInterval] {
        locked { delays }
    }

    func schedule(
        after delay: DispatchTimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> any ProcessTapRetryCancellation {
        let id = UUID()
        locked {
            precondition(pending == nil)
            pending = Pending(id: id, action: action)
            capturedActions.append(action)
            delays.append(delay)
        }
        return Cancellation { [weak self] in
            self?.locked {
                guard self?.pending?.id == id else { return }
                self?.pending = nil
            }
        }
    }

    func runNext() {
        let action = locked { () -> (@Sendable () -> Void)? in
            defer { pending = nil }
            return pending?.action
        }
        action?()
    }

    func fireCapturedActionTwice() {
        let action = locked { () -> (@Sendable () -> Void)? in
            pending = nil
            return capturedActions.last
        }
        action?()
        action?()
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
