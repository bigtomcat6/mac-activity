import AppKit
import XCTest
@testable import DebugGlassPrototype

@MainActor
final class PrototypeMonitorBagTests: XCTestCase {
    private final class Recorder {
        var installed = 0
        var removed = 0
    }

    private func makeBag(_ recorder: Recorder) -> PrototypeMonitorBag {
        PrototypeMonitorBag(
            installGlobal: { _, _ in
                recorder.installed += 1
                return NSObject()
            },
            installLocal: { _, _ in
                recorder.installed += 1
                return NSObject()
            },
            removeMonitor: { _ in recorder.removed += 1 },
            installObserver: { center, name, object, handler in
                recorder.installed += 1
                return center.addObserver(forName: name, object: object, queue: nil, using: handler)
            }
        )
    }

    func testTracksMonitorsAndRemovesObserverThroughNotificationCenter() {
        let recorder = Recorder()
        let bag = makeBag(recorder)
        let center = NotificationCenter()
        let name = Notification.Name("PrototypeTest")
        var observed = 0

        bag.addGlobal(mask: [.leftMouseDown]) { _ in }
        bag.addLocal(mask: [.keyDown]) { $0 }
        bag.observe(center: center, name: name) { _ in observed += 1 }
        center.post(name: name, object: nil)
        XCTAssertEqual(observed, 1)
        XCTAssertEqual(bag.activeCount, 3)

        bag.removeAll()

        center.post(name: name, object: nil)
        XCTAssertEqual(observed, 1)
        XCTAssertEqual(bag.activeCount, 0)
        XCTAssertEqual(recorder.installed, 3)
        XCTAssertEqual(recorder.removed, 2)
    }

    func testRemoveAllIsIdempotent() {
        let recorder = Recorder()
        let bag = makeBag(recorder)
        bag.addGlobal(mask: [.leftMouseDown]) { _ in }
        bag.removeAll()
        bag.removeAll()
        XCTAssertEqual(recorder.removed, 1)
        XCTAssertEqual(bag.activeCount, 0)
    }

    func testRepeatedOpenCloseCyclesDoNotAccumulate() {
        let recorder = Recorder()
        let bag = makeBag(recorder)
        for _ in 0..<5 {
            bag.addGlobal(mask: [.leftMouseDown]) { _ in }
            bag.addLocal(mask: [.keyDown]) { $0 }
            bag.removeAll()
            XCTAssertEqual(bag.activeCount, 0)
        }
        XCTAssertEqual(recorder.installed, 10)
        XCTAssertEqual(recorder.removed, 10)
    }

    func testNilTokenRegistersNothing() {
        let recorder = Recorder()
        let bag = PrototypeMonitorBag(
            installGlobal: { _, _ in nil },
            installLocal: { _, _ in nil },
            removeMonitor: { _ in recorder.removed += 1 },
            installObserver: { _, _, _, _ in NSObject() }
        )
        bag.addGlobal(mask: [.leftMouseDown]) { _ in }
        bag.addLocal(mask: [.keyDown]) { $0 }
        XCTAssertEqual(bag.activeCount, 0)
        bag.removeAll()
        XCTAssertEqual(recorder.removed, 0)
    }
}
