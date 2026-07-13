import Foundation

@testable import MacActivityCore

final class FakeAudioProcessOwnershipLeaseBroker: @unchecked Sendable {
    enum Event: Equatable {
        case acquired(owner: String, leaseID: UInt64)
        case busy(owner: String)
        case released(owner: String, leaseID: UInt64)
        case processDied(owner: String, leaseID: UInt64)
    }

    private final class Acquirer: AudioProcessOwnershipLeaseAcquiring, @unchecked Sendable {
        private let broker: FakeAudioProcessOwnershipLeaseBroker
        private let owner: String

        init(broker: FakeAudioProcessOwnershipLeaseBroker, owner: String) {
            self.broker = broker
            self.owner = owner
        }

        func acquire() throws -> any AudioProcessOwnershipLease {
            try broker.acquire(owner: owner)
        }
    }

    private final class Lease: AudioProcessOwnershipLease, @unchecked Sendable {
        private let broker: FakeAudioProcessOwnershipLeaseBroker
        private let owner: String
        private let leaseID: UInt64

        init(
            broker: FakeAudioProcessOwnershipLeaseBroker,
            owner: String,
            leaseID: UInt64
        ) {
            self.broker = broker
            self.owner = owner
            self.leaseID = leaseID
        }

        deinit {
            broker.release(owner: owner, leaseID: leaseID)
        }
    }

    private let lock = NSLock()
    private var nextLeaseID: UInt64 = 0
    private var current: (owner: String, leaseID: UInt64)?
    private var recordedEvents: [Event] = []
    private var nextError: AudioProcessOwnershipLeaseError?

    var currentOwner: String? { locked { current?.owner } }
    var events: [Event] { locked { recordedEvents } }

    func acquirer(owner: String) -> any AudioProcessOwnershipLeaseAcquiring {
        Acquirer(broker: self, owner: owner)
    }

    func failNextAcquire(with error: AudioProcessOwnershipLeaseError) {
        locked { nextError = error }
    }

    func simulateProcessDeath(owner: String) {
        locked {
            guard current?.owner == owner, let leaseID = current?.leaseID else { return }
            recordedEvents.append(.processDied(owner: owner, leaseID: leaseID))
            current = nil
        }
    }

    private func acquire(owner: String) throws -> any AudioProcessOwnershipLease {
        try locked {
            if let nextError {
                self.nextError = nil
                throw nextError
            }
            guard current == nil else {
                recordedEvents.append(.busy(owner: owner))
                throw AudioProcessOwnershipLeaseError.busy
            }
            nextLeaseID &+= 1
            let leaseID = nextLeaseID
            current = (owner, leaseID)
            recordedEvents.append(.acquired(owner: owner, leaseID: leaseID))
            return Lease(broker: self, owner: owner, leaseID: leaseID)
        }
    }

    private func release(owner: String, leaseID: UInt64) {
        locked {
            guard current?.owner == owner, current?.leaseID == leaseID else { return }
            current = nil
            recordedEvents.append(.released(owner: owner, leaseID: leaseID))
        }
    }

    @discardableResult
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
