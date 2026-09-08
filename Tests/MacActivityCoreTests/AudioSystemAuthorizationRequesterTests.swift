import Dispatch
import Foundation
import XCTest
@testable import MacActivityCore

@MainActor
final class AudioSystemAuthorizationRequesterTests: XCTestCase {
    func testInitializationDoesNotInvokeRawRequest() {
        let recorder = RawRequestRecorder()

        _ = supportedRequester(recorder)

        XCTAssertEqual(recorder.callCount, 0)
    }

    func testRequestRemainsPendingUntilAllowedCallback() async {
        let started = expectation(description: "raw request started")
        let completed = expectation(description: "request completed")
        let recorder = RawRequestRecorder(onStart: ExpectationSignal(started).fulfill)
        let requester = supportedRequester(recorder)
        let results = AuthorizationResults()
        let completedSignal = ExpectationSignal(completed)
        _ = Task {
            results.record(await requester.requestAuthorization(), for: "request")
            completedSignal.fulfill()
        }
        defer {
            recorder.complete(false)
            scheduleShutdown(requester)
        }

        await fulfillment(of: [started], timeout: 1)
        XCTAssertNil(results.value(for: "request"))
        XCTAssertEqual(recorder.callCount, 1)

        recorder.complete(true)

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(results.value(for: "request"), .authorized)
    }

    func testDeniedCallbackReturnsDenied() async {
        let started = expectation(description: "raw request started")
        let completed = expectation(description: "request completed")
        let recorder = RawRequestRecorder(onStart: ExpectationSignal(started).fulfill)
        let requester = supportedRequester(recorder)
        let results = AuthorizationResults()
        let completedSignal = ExpectationSignal(completed)
        _ = Task {
            results.record(await requester.requestAuthorization(), for: "request")
            completedSignal.fulfill()
        }
        defer {
            recorder.complete(false)
            scheduleShutdown(requester)
        }

        await fulfillment(of: [started], timeout: 1)
        recorder.complete(false)

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(results.value(for: "request"), .denied)
    }

    func testBackgroundCallbackReturnsAuthorized() async {
        let started = expectation(description: "raw request started")
        let completed = expectation(description: "request completed")
        let recorder = RawRequestRecorder(onStart: ExpectationSignal(started).fulfill)
        let requester = supportedRequester(recorder)
        let results = AuthorizationResults()
        let completedSignal = ExpectationSignal(completed)
        _ = Task {
            results.record(await requester.requestAuthorization(), for: "request")
            completedSignal.fulfill()
        }
        defer {
            recorder.complete(false)
            scheduleShutdown(requester)
        }

        await fulfillment(of: [started], timeout: 1)
        DispatchQueue.global(qos: .userInitiated).async {
            recorder.complete(true)
        }

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(results.value(for: "request"), .authorized)
    }

    func testMissingRequestAPIReportsUnavailable() async {
        let completed = expectation(description: "request completed")
        let calls = CallCounter()
        let requester = AudioSystemAuthorizationRequester(
            availability: supportedAvailability,
            rawRequest: { _ in
                calls.record()
                return nil
            }
        )
        let results = AuthorizationResults()
        let completedSignal = ExpectationSignal(completed)
        _ = Task {
            results.record(await requester.requestAuthorization(), for: "request")
            completedSignal.fulfill()
        }
        defer { scheduleShutdown(requester) }

        await fulfillment(of: [completed], timeout: 1)

        XCTAssertEqual(results.value(for: "request"), .unavailable)
        XCTAssertEqual(calls.count, 1)
    }

    func testUnsupportedSystemDoesNotInvokeRawRequest() async {
        let completed = expectation(description: "request completed")
        let calls = CallCounter()
        let requester = AudioSystemAuthorizationRequester(
            availability: .init(
                operatingSystemVersion: .init(majorVersion: 14, minorVersion: 1, patchVersion: 0)
            ),
            rawRequest: { _ in
                calls.record()
                return .init(retaining: RequestRetentionToken())
            }
        )
        let results = AuthorizationResults()
        let completedSignal = ExpectationSignal(completed)
        _ = Task {
            results.record(await requester.requestAuthorization(), for: "request")
            completedSignal.fulfill()
        }
        defer { scheduleShutdown(requester) }

        await fulfillment(of: [completed], timeout: 1)

        XCTAssertEqual(results.value(for: "request"), .unavailable)
        XCTAssertEqual(calls.count, 0)
    }

    func testSynchronousDuplicateCallbacksUseOnlyTheFirstDecision() async {
        let completed = expectation(description: "request completed")
        let calls = CallCounter()
        let requester = AudioSystemAuthorizationRequester(
            availability: supportedAvailability,
            rawRequest: { callback in
                calls.record()
                callback(true)
                callback(false)
                return .init(retaining: RequestRetentionToken())
            }
        )
        let results = AuthorizationResults()
        let completedSignal = ExpectationSignal(completed)
        _ = Task {
            results.record(await requester.requestAuthorization(), for: "request")
            completedSignal.fulfill()
        }
        defer { scheduleShutdown(requester) }

        await fulfillment(of: [completed], timeout: 1)

        XCTAssertEqual(results.value(for: "request"), .authorized)
        XCTAssertEqual(calls.count, 1)
    }

    func testConcurrentCallersShareOneRawRequest() async {
        let started = expectation(description: "raw request started")
        let secondInvoked = expectation(description: "second caller invoked")
        let completed = expectation(description: "both callers completed")
        completed.expectedFulfillmentCount = 2
        let recorder = RawRequestRecorder(onStart: ExpectationSignal(started).fulfill)
        let requester = supportedRequester(recorder)
        let results = AuthorizationResults()
        let completedSignal = ExpectationSignal(completed)
        let secondInvokedSignal = ExpectationSignal(secondInvoked)
        _ = Task {
            results.record(await requester.requestAuthorization(), for: "first")
            completedSignal.fulfill()
        }
        defer {
            recorder.complete(false)
            scheduleShutdown(requester)
        }

        await fulfillment(of: [started], timeout: 1)
        _ = Task {
            secondInvokedSignal.fulfill()
            results.record(await requester.requestAuthorization(), for: "second")
            completedSignal.fulfill()
        }
        await fulfillment(of: [secondInvoked], timeout: 1)
        await Task.yield()
        XCTAssertEqual(recorder.callCount, 1)

        recorder.complete(true)

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(results.value(for: "first"), .authorized)
        XCTAssertEqual(results.value(for: "second"), .authorized)
        XCTAssertEqual(recorder.callCount, 1)
    }

    func testCancelingOneCallerDoesNotCancelAnotherCaller() async {
        let started = expectation(description: "raw request started")
        let canceledInvoked = expectation(description: "cancelable caller invoked")
        let canceledCompleted = expectation(description: "cancelable caller completed")
        let retainedCompleted = expectation(description: "retained caller completed")
        let recorder = RawRequestRecorder(onStart: ExpectationSignal(started).fulfill)
        let requester = supportedRequester(recorder)
        let results = AuthorizationResults()
        let canceledInvokedSignal = ExpectationSignal(canceledInvoked)
        let canceledCompletedSignal = ExpectationSignal(canceledCompleted)
        let retainedCompletedSignal = ExpectationSignal(retainedCompleted)
        _ = Task {
            results.record(await requester.requestAuthorization(), for: "retained")
            retainedCompletedSignal.fulfill()
        }
        defer {
            recorder.complete(false)
            scheduleShutdown(requester)
        }

        await fulfillment(of: [started], timeout: 1)
        let canceled = Task {
            canceledInvokedSignal.fulfill()
            results.record(await requester.requestAuthorization(), for: "canceled")
            canceledCompletedSignal.fulfill()
        }
        await fulfillment(of: [canceledInvoked], timeout: 1)
        await Task.yield()
        canceled.cancel()

        await fulfillment(of: [canceledCompleted], timeout: 1)
        XCTAssertEqual(results.value(for: "canceled"), .unavailable)
        XCTAssertNil(results.value(for: "retained"))
        XCTAssertEqual(recorder.callCount, 1)

        recorder.complete(true)

        await fulfillment(of: [retainedCompleted], timeout: 1)
        XCTAssertEqual(results.value(for: "retained"), .authorized)
        XCTAssertEqual(recorder.callCount, 1)
    }

    func testLastCancelledCallerWaitsForAFreshRequestAfterTheOldCallbackDrains() async {
        let firstStarted = expectation(description: "first raw request started")
        let freshStarted = expectation(description: "fresh raw request started")
        let firstCompleted = expectation(description: "first caller completed")
        let secondCompleted = expectation(description: "second caller completed")
        let recorder = RawRequestRecorder()
        let firstStartedSignal = ExpectationSignal(firstStarted)
        let freshStartedSignal = ExpectationSignal(freshStarted)
        recorder.observeStarts { count in
            if count == 1 {
                firstStartedSignal.fulfill()
            } else if count == 2 {
                freshStartedSignal.fulfill()
            }
        }
        let requester = supportedRequester(recorder)
        let results = AuthorizationResults()
        let firstCompletedSignal = ExpectationSignal(firstCompleted)
        let secondCompletedSignal = ExpectationSignal(secondCompleted)
        let secondQueued = expectation(description: "second caller queued behind abandoned request")
        let secondQueuedSignal = ExpectationSignal(secondQueued)
        await requester.testingObserveQueuedWaiterRegistration {
            secondQueuedSignal.fulfill()
        }
        let first = Task {
            results.record(await requester.requestAuthorization(), for: "first")
            firstCompletedSignal.fulfill()
        }
        defer {
            recorder.complete(false, request: 0)
            recorder.complete(false, request: 1)
            scheduleShutdown(requester)
        }

        await fulfillment(of: [firstStarted], timeout: 1)
        first.cancel()
        await fulfillment(of: [firstCompleted], timeout: 1)
        await first.value
        XCTAssertEqual(results.value(for: "first"), .unavailable)

        let second = Task {
            results.record(await requester.requestAuthorization(), for: "second")
            secondCompletedSignal.fulfill()
        }
        await fulfillment(of: [secondQueued], timeout: 1)
        XCTAssertEqual(recorder.callCount, 1)

        recorder.complete(true, request: 0)
        await fulfillment(of: [freshStarted], timeout: 1)
        XCTAssertNil(results.value(for: "second"))
        XCTAssertEqual(recorder.callCount, 2)

        recorder.complete(false, request: 1)
        await fulfillment(of: [secondCompleted], timeout: 1)
        await second.value
        XCTAssertEqual(results.value(for: "second"), .denied)
    }

    func testShutdownBeforeRequestRejectsWithoutInvokingRawRequest() async {
        let shutdownReturned = expectation(description: "shutdown returned")
        let completed = expectation(description: "request completed")
        let recorder = RawRequestRecorder()
        let requester = supportedRequester(recorder)
        let results = AuthorizationResults()
        let shutdownReturnedSignal = ExpectationSignal(shutdownReturned)
        let completedSignal = ExpectationSignal(completed)
        _ = Task {
            await requester.shutdown()
            shutdownReturnedSignal.fulfill()
        }
        defer { scheduleShutdown(requester) }

        await fulfillment(of: [shutdownReturned], timeout: 1)
        _ = Task {
            results.record(await requester.requestAuthorization(), for: "request")
            completedSignal.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertEqual(results.value(for: "request"), .unavailable)
        XCTAssertEqual(recorder.callCount, 0)
    }

    func testShutdownResolvesInFlightCallerAndRetainsRequestUntilLateCallback() async {
        let started = expectation(description: "raw request started")
        let shutdownReturned = expectation(description: "shutdown returned")
        let completed = expectation(description: "request completed")
        let afterShutdownCompleted = expectation(description: "post-shutdown request completed")
        let released = expectation(description: "request retention released")
        let recorder = RawRequestRecorder(onStart: ExpectationSignal(started).fulfill)
        let completedSignal = ExpectationSignal(completed)
        let shutdownReturnedSignal = ExpectationSignal(shutdownReturned)
        let afterShutdownCompletedSignal = ExpectationSignal(afterShutdownCompleted)
        let releasedSignal = ExpectationSignal(released)
        let retentionToken = WeakReference<RequestRetentionToken>()
        let requester = AudioSystemAuthorizationRequester(
            availability: supportedAvailability,
            rawRequest: { callback in
                let token = RequestRetentionToken(onDeinit: releasedSignal.fulfill)
                retentionToken.store(token)
                recorder.start(callback)
                return .init(retaining: token)
            }
        )
        let results = AuthorizationResults()
        _ = Task {
            results.record(await requester.requestAuthorization(), for: "request")
            completedSignal.fulfill()
        }
        defer {
            recorder.complete(false)
            scheduleShutdown(requester)
        }

        await fulfillment(of: [started], timeout: 1)
        _ = Task {
            await requester.shutdown()
            shutdownReturnedSignal.fulfill()
        }

        await fulfillment(of: [shutdownReturned], timeout: 1)
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(results.value(for: "request"), .unavailable)
        XCTAssertNotNil(retentionToken.value)
        XCTAssertEqual(recorder.callCount, 1)

        _ = Task {
            results.record(await requester.requestAuthorization(), for: "afterShutdown")
            afterShutdownCompletedSignal.fulfill()
        }
        await fulfillment(of: [afterShutdownCompleted], timeout: 1)
        XCTAssertEqual(results.value(for: "afterShutdown"), .unavailable)
        XCTAssertEqual(recorder.callCount, 1)

        recorder.complete(true)

        await fulfillment(of: [released], timeout: 1)
        XCTAssertEqual(results.value(for: "request"), .unavailable)
        XCTAssertNil(retentionToken.value)
    }

    private var supportedAvailability: AudioFeatureAvailability {
        .init(operatingSystemVersion: .init(majorVersion: 14, minorVersion: 2, patchVersion: 0))
    }

    private func supportedRequester(
        _ recorder: RawRequestRecorder
    ) -> AudioSystemAuthorizationRequester {
        AudioSystemAuthorizationRequester(
            availability: supportedAvailability,
            rawRequest: { callback in
                recorder.start(callback)
                return .init(retaining: RequestRetentionToken())
            }
        )
    }

    private func scheduleShutdown(_ requester: AudioSystemAuthorizationRequester) {
        _ = Task { await requester.shutdown() }
    }
}

private final class AuthorizationResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: AudioSystemAuthorizationStatus] = [:]

    func record(_ value: AudioSystemAuthorizationStatus, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func value(for key: String) -> AudioSystemAuthorizationStatus? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }
}

private final class ExpectationSignal: @unchecked Sendable {
    private let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        expectation.fulfill()
    }
}

private final class RawRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let onStart: @Sendable () -> Void
    private var callbacks: [@Sendable (Bool) -> Void] = []
    private var value = 0
    private var startObserver: (@Sendable (Int) -> Void)?

    init(onStart: @escaping @Sendable () -> Void = {}) {
        self.onStart = onStart
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func observeStarts(_ observer: @escaping @Sendable (Int) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        startObserver = observer
    }

    func start(_ callback: @escaping @Sendable (Bool) -> Void) {
        let start = lock.withLock { () -> (count: Int, observer: (@Sendable (Int) -> Void)?) in
            value += 1
            callbacks.append(callback)
            return (value, startObserver)
        }
        onStart()
        start.observer?(start.count)
    }

    func complete(_ allowed: Bool) {
        lock.lock()
        let callbacks = callbacks
        lock.unlock()
        callbacks.forEach { $0(allowed) }
    }

    func complete(_ allowed: Bool, request: Int) {
        let callback = lock.withLock {
            callbacks.indices.contains(request) ? callbacks[request] : nil
        }
        callback?(allowed)
    }
}

private final class RequestRetentionToken {
    private let onDeinit: @Sendable () -> Void

    init(onDeinit: @escaping @Sendable () -> Void = {}) {
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }
}

private final class WeakReference<Object: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var object: Object?

    var value: Object? {
        lock.lock()
        defer { lock.unlock() }
        return object
    }

    func store(_ object: Object) {
        lock.lock()
        defer { lock.unlock() }
        self.object = object
    }
}
