import Dispatch

protocol ProcessTapRetryCancellation: AnyObject, Sendable {
    func cancel()
}

protocol ProcessTapRetryScheduling: Sendable {
    func schedule(
        after delay: DispatchTimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> any ProcessTapRetryCancellation
}

struct ProcessTapRetryBackoff {
    private var milliseconds = 50

    mutating func nextDelay() -> DispatchTimeInterval {
        defer { milliseconds = min(1_000, milliseconds * 2) }
        return .milliseconds(milliseconds)
    }

    mutating func recordProgress() {
        milliseconds = 50
    }
}

struct ProcessTapRuntimeRejectionCache {
    private let capacity: Int
    private var fingerprints: Set<AudioRouteTopologyFingerprint> = []
    private var insertionOrder: [AudioRouteTopologyFingerprint] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func contains(_ fingerprint: AudioRouteTopologyFingerprint) -> Bool {
        fingerprints.contains(fingerprint)
    }

    mutating func insert(_ fingerprint: AudioRouteTopologyFingerprint) {
        guard fingerprints.insert(fingerprint).inserted else { return }
        if insertionOrder.count == capacity {
            fingerprints.remove(insertionOrder.removeFirst())
        }
        insertionOrder.append(fingerprint)
    }
}

final class DispatchProcessTapRetryScheduler: ProcessTapRetryScheduling, @unchecked Sendable {
    private final class Cancellation: ProcessTapRetryCancellation, @unchecked Sendable {
        let workItem: DispatchWorkItem

        init(workItem: DispatchWorkItem) {
            self.workItem = workItem
        }

        func cancel() {
            workItem.cancel()
        }
    }

    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func schedule(
        after delay: DispatchTimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> any ProcessTapRetryCancellation {
        let workItem = DispatchWorkItem(block: action)
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        return Cancellation(workItem: workItem)
    }
}
