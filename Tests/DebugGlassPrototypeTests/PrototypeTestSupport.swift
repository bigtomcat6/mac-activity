import AppKit
@testable import DebugGlassPrototype

@available(macOS 26.0, *)
@MainActor
final class PrototypeRecordingBag {
    private(set) var globalHandlers: [(NSEvent) -> Void] = []
    private(set) var localHandlers: [(mask: NSEvent.EventTypeMask, handler: (NSEvent) -> NSEvent?)] = []
    private(set) var observerHandlers: [Notification.Name: [(Notification) -> Void]] = [:]
    private(set) var installedCount = 0
    private(set) var removedCount = 0

    func makeBag() -> PrototypeMonitorBag {
        PrototypeMonitorBag(
            installGlobal: { [self] _, handler in
                installedCount += 1
                globalHandlers.append(handler)
                return NSObject()
            },
            installLocal: { [self] mask, handler in
                installedCount += 1
                localHandlers.append((mask, handler))
                return NSObject()
            },
            removeMonitor: { [self] _ in
                removedCount += 1
            },
            installObserver: { [self] _, name, _, handler in
                installedCount += 1
                observerHandlers[name, default: []].append(handler)
                return NSObject()
            }
        )
    }

    func firstObserver(_ name: Notification.Name) -> ((Notification) -> Void)? {
        observerHandlers[name]?.first
    }

    func lastObserver(_ name: Notification.Name) -> ((Notification) -> Void)? {
        observerHandlers[name]?.last
    }

    func localHandler(for mask: NSEvent.EventTypeMask) -> ((NSEvent) -> NSEvent?)? {
        localHandlers.first { $0.mask.contains(mask) }?.handler
    }
}
