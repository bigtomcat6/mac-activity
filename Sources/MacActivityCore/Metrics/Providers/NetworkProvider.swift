import Darwin
import Foundation
import SystemConfiguration

struct NetworkInterfaceCounter: Equatable, Sendable {
    var name: String
    var isUp: Bool
    var isLoopback: Bool
    var receivedBytes: UInt64
    var sentBytes: UInt64
}

struct NetworkCounterSample: Equatable, Sendable {
    var received: UInt64
    var sent: UInt64
    var timestamp: Date
}

public actor NetworkProvider: MetricProvider {
    public let kind: MetricKind = .network
    public let cadence: MetricCadenceLane = .fast
    private var previousSample: NetworkCounterSample?

    public init() {}

    public func sample() async -> MetricUpdate {
        let now = Date()
        guard let currentSample = readCounters(at: now) else {
            return .stale(kind: .network, reason: "Unable to read network counters")
        }

        defer {
            previousSample = currentSample
        }

        guard let previousSample else {
            return .network(
                NetworkReading(
                    downloadBytesPerSecond: 0,
                    uploadBytesPerSecond: 0
                )
            )
        }

        let interval = max(0.001, currentSample.timestamp.timeIntervalSince(previousSample.timestamp))
        let downloadRate = Double(Self.byteDelta(current: currentSample.received, previous: previousSample.received)) / interval
        let uploadRate = Double(Self.byteDelta(current: currentSample.sent, previous: previousSample.sent)) / interval

        return .network(
            NetworkReading(
                downloadBytesPerSecond: max(0, downloadRate),
                uploadBytesPerSecond: max(0, uploadRate)
            )
        )
    }

    private func readCounters(at date: Date) -> NetworkCounterSample? {
        Self.makeCounterSample(
            from: Self.readInterfaceCounters(),
            preferredInterfaceNames: Self.primaryInterfaceNames(),
            timestamp: date
        )
    }

    static func makeCounterSample(
        from counters: [NetworkInterfaceCounter],
        preferredInterfaceNames: [String] = [],
        timestamp: Date
    ) -> NetworkCounterSample? {
        let activeCounters = counters.filter { counter in
            counter.isUp && !counter.isLoopback
        }

        guard !activeCounters.isEmpty else {
            return nil
        }

        for preferredInterfaceName in preferredInterfaceNames where !preferredInterfaceName.isEmpty {
            let preferredCounters = activeCounters.filter { counter in
                counter.name == preferredInterfaceName
            }

            if let sample = aggregate(preferredCounters, timestamp: timestamp) {
                return sample
            }
        }

        let physicalCounters = activeCounters.filter { counter in
            !isVirtualOrAuxiliaryInterface(counter.name)
        }

        if let sample = aggregate(physicalCounters, timestamp: timestamp) {
            return sample
        }

        return aggregate(activeCounters, timestamp: timestamp)
    }

    static func byteDelta(current: UInt64, previous: UInt64) -> UInt64 {
        guard current >= previous else {
            return 0
        }

        return current - previous
    }

    static func isVirtualOrAuxiliaryInterface(_ name: String) -> Bool {
        let excludedPrefixes = [
            "utun",
            "awdl",
            "llw",
            "bridge",
            "p2p",
            "gif",
            "stf",
            "anpi",
            "ap",
            "vmenet",
            "vmnet",
            "tap",
            "tun",
        ]

        return excludedPrefixes.contains { prefix in
            name.hasPrefix(prefix)
        }
    }

    private static func primaryInterfaceNames() -> [String] {
        let names = [
            primaryInterfaceName(for: "State:/Network/Global/IPv4"),
            primaryInterfaceName(for: "State:/Network/Global/IPv6"),
        ].compactMap { $0 }

        return uniqueInterfaceNames(names)
    }

    private static func primaryInterfaceName(for dynamicStoreKey: String) -> String? {
        guard let dictionary = SCDynamicStoreCopyValue(nil, dynamicStoreKey as CFString) as? [String: Any],
              let interfaceName = dictionary["PrimaryInterface"] as? String,
              !interfaceName.isEmpty else {
            return nil
        }

        return interfaceName
    }

    private static func uniqueInterfaceNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var uniqueNames: [String] = []
        uniqueNames.reserveCapacity(names.count)

        for name in names where seen.insert(name).inserted {
            uniqueNames.append(name)
        }

        return uniqueNames
    }

    private static func readInterfaceCounters() -> [NetworkInterfaceCounter] {
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let firstInterface = interfaceList else {
            return []
        }
        defer {
            freeifaddrs(firstInterface)
        }

        var counters: [NetworkInterfaceCounter] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface

        while let current = cursor {
            defer {
                cursor = current.pointee.ifa_next
            }

            let family = current.pointee.ifa_addr?.pointee.sa_family
            guard family == UInt8(AF_LINK),
                  let data = current.pointee.ifa_data else {
                continue
            }

            let flags = Int32(current.pointee.ifa_flags)
            let interfaceData = data.assumingMemoryBound(to: if_data.self).pointee
            counters.append(
                NetworkInterfaceCounter(
                    name: String(cString: current.pointee.ifa_name),
                    isUp: (flags & IFF_UP) != 0,
                    isLoopback: (flags & IFF_LOOPBACK) != 0,
                    receivedBytes: UInt64(interfaceData.ifi_ibytes),
                    sentBytes: UInt64(interfaceData.ifi_obytes)
                )
            )
        }

        return counters
    }

    private static func aggregate(
        _ counters: [NetworkInterfaceCounter],
        timestamp: Date
    ) -> NetworkCounterSample? {
        guard !counters.isEmpty else {
            return nil
        }

        return NetworkCounterSample(
            received: counters.reduce(UInt64(0)) { partialResult, counter in
                partialResult &+ counter.receivedBytes
            },
            sent: counters.reduce(UInt64(0)) { partialResult, counter in
                partialResult &+ counter.sentBytes
            },
            timestamp: timestamp
        )
    }
}
