import Darwin
import Foundation

public actor NetworkProvider: MetricProvider {
    public let kind: MetricKind = .network
    public let cadence: MetricCadenceLane = .fast
    private var previousSample: CounterSample?

    private struct CounterSample {
        let received: UInt64
        let sent: UInt64
        let timestamp: Date
    }

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
        let downloadRate = Double(currentSample.received &- previousSample.received) / interval
        let uploadRate = Double(currentSample.sent &- previousSample.sent) / interval

        return .network(
            NetworkReading(
                downloadBytesPerSecond: max(0, downloadRate),
                uploadBytesPerSecond: max(0, uploadRate)
            )
        )
    }

    private func readCounters(at date: Date) -> CounterSample? {
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let firstInterface = interfaceList else {
            return nil
        }
        defer {
            freeifaddrs(firstInterface)
        }

        var receivedBytes: UInt64 = 0
        var sentBytes: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface

        while let current = cursor {
            defer {
                cursor = current.pointee.ifa_next
            }

            let flags = Int32(current.pointee.ifa_flags)
            let family = current.pointee.ifa_addr?.pointee.sa_family

            guard family == UInt8(AF_LINK),
                  (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let data = current.pointee.ifa_data else {
                continue
            }

            let interfaceData = data.assumingMemoryBound(to: if_data.self).pointee
            receivedBytes += UInt64(interfaceData.ifi_ibytes)
            sentBytes += UInt64(interfaceData.ifi_obytes)
        }

        return CounterSample(
            received: receivedBytes,
            sent: sentBytes,
            timestamp: date
        )
    }
}
