import Darwin
import Foundation
import XCTest
@testable import MacActivityCore

@MainActor
final class EnergyImpactNativeValidationTests: XCTestCase {
    func testVisibleFacadeBudget() async throws {
        guard ProcessInfo.processInfo.environment[
            "MACACTIVITY_ENERGY_NATIVE_VALIDATION"
        ] == "1" else {
            throw XCTSkip("Set MACACTIVITY_ENERGY_NATIVE_VALIDATION=1 explicitly")
        }

        let service = EnergyImpactService()
        guard let lease = await service.beginSession() else {
            XCTFail("Native validation could not begin a sampler lease")
            return
        }
        do {
            let metrics = try await measureVisibleFacade(
                service: service,
                lease: lease
            )
            await service.endSession(lease)

            print(String(
                format: "ENERGY_NATIVE_METRICS samples=%d p50_ms=%.3f p95_ms=%.3f cpu_percent=%.4f wall_seconds=%.3f",
                metrics.sampleCount,
                metrics.p50 * 1_000,
                metrics.p95 * 1_000,
                metrics.cpuPercent,
                metrics.wallSeconds
            ))
            XCTAssertLessThan(metrics.cpuPercent, 0.5)
            XCTAssertLessThan(metrics.p95, 0.100)
        } catch {
            await service.endSession(lease)
            throw error
        }
    }

    private func measureVisibleFacade(
        service: EnergyImpactService,
        lease: EnergyImpactSamplingLease
    ) async throws -> NativeMetrics {
        let startCPU = processCPUSeconds()
        let startWall = ProcessInfo.processInfo.systemUptime
        var latencies = [TimeInterval]()
        latencies.reserveCapacity(60)

        for _ in 1...60 {
            try Task.checkCancellation()
            let started = ProcessInfo.processInfo.systemUptime
            _ = await service.observe(
                lease: lease,
                limit: 20,
                scope: .regularOnly
            )
            try Task.checkCancellation()
            latencies.append(ProcessInfo.processInfo.systemUptime - started)
            try await Task.sleep(for: .seconds(1))
        }

        let wallSeconds = ProcessInfo.processInfo.systemUptime - startWall
        let cpuPercent = (processCPUSeconds() - startCPU) / wallSeconds * 100
        let sorted = latencies.sorted()
        let p50Index = max(0, min(
            sorted.count - 1,
            Int(ceil(0.50 * Double(sorted.count))) - 1
        ))
        let p95Index = max(0, min(
            sorted.count - 1,
            Int(ceil(0.95 * Double(sorted.count))) - 1
        ))
        return NativeMetrics(
            sampleCount: sorted.count,
            p50: sorted[p50Index],
            p95: sorted[p95Index],
            cpuPercent: cpuPercent,
            wallSeconds: wallSeconds
        )
    }

    private func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec)
            + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec)
            + Double(usage.ru_stime.tv_usec) / 1_000_000
    }
}

private struct NativeMetrics {
    let sampleCount: Int
    let p50: TimeInterval
    let p95: TimeInterval
    let cpuPercent: Double
    let wallSeconds: TimeInterval
}
