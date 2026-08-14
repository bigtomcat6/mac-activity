import AppKit
import Darwin
import Foundation
import XCTest
@testable import MacActivityCore

@MainActor
final class EnergyImpactNativeValidationTests: XCTestCase {
    private struct NativeMetrics {
        let observationCount: Int
        let preRunCatalogAppCount: Int
        let systemSnapshotProcessCount: Int
        let p50Seconds: TimeInterval
        let p95Seconds: TimeInterval
        let cpuPercent: Double
        let wallSeconds: TimeInterval
    }

    private enum NativeValidationError: Error {
        case observationRejected(Int)
        case missedDeadline(index: Int, latenessSeconds: TimeInterval)
    }

    private enum NativeScopeError: Error, Equatable {
        case invalid(String)
    }

    private static func nativeScope(
        environment: [String: String]
    ) throws -> EnergyImpactAppScope {
        switch environment["MACACTIVITY_ENERGY_NATIVE_SCOPE"] {
        case nil, "regularOnly":
            return .regularOnly
        case "regularAndAccessory":
            return .regularAndAccessory
        case let value?:
            throw NativeScopeError.invalid(value)
        }
    }

    private static func nativeMetricLine(
        scope: EnergyImpactAppScope,
        metrics: NativeMetrics
    ) -> String {
        String(
            format: "ENERGY_NATIVE_METRICS scope=\(scope.rawValue) observations=%d pre_run_catalog_apps=%d system_snapshot_processes=%d p50_ms=%.3f p95_ms=%.3f cpu_percent=%.6f wall_seconds=%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            metrics.observationCount,
            metrics.preRunCatalogAppCount,
            metrics.systemSnapshotProcessCount,
            metrics.p50Seconds * 1_000,
            metrics.p95Seconds * 1_000,
            metrics.cpuPercent,
            metrics.wallSeconds
        )
    }

    func testNativeScopeDefaultsAndParsesOnlySupportedValues() throws {
        XCTAssertEqual(try Self.nativeScope(environment: [:]), .regularOnly)
        XCTAssertEqual(
            try Self.nativeScope(environment: ["MACACTIVITY_ENERGY_NATIVE_SCOPE": "regularOnly"]),
            .regularOnly
        )
        XCTAssertEqual(
            try Self.nativeScope(environment: ["MACACTIVITY_ENERGY_NATIVE_SCOPE": "regularAndAccessory"]),
            .regularAndAccessory
        )
        XCTAssertThrowsError(
            try Self.nativeScope(environment: ["MACACTIVITY_ENERGY_NATIVE_SCOPE": "all"])
        ) { error in
            XCTAssertEqual(error as? NativeScopeError, .invalid("all"))
        }
    }

    func testNativeMetricLineIncludesExactlyOneSelectedScope() {
        let line = Self.nativeMetricLine(
            scope: .regularAndAccessory,
            metrics: NativeMetrics(
                observationCount: 21,
                preRunCatalogAppCount: 2,
                systemSnapshotProcessCount: 8,
                p50Seconds: 0.001,
                p95Seconds: 0.002,
                cpuPercent: 0.1,
                wallSeconds: 60
            )
        )

        XCTAssertEqual(
            line.split(separator: " ")
                .filter { $0.hasPrefix("scope=") }
                .map(String.init),
            ["scope=regularAndAccessory"]
        )
    }

    func testVisibleFacadeBudget() async throws {
        let environment = ProcessInfo.processInfo.environment
        let scope = try Self.nativeScope(environment: environment)
        guard environment["MACACTIVITY_ENERGY_NATIVE_VALIDATION"] == "1" else {
            throw XCTSkip("Set MACACTIVITY_ENERGY_NATIVE_VALIDATION=1 explicitly")
        }

        let candidates = NSWorkspace.shared.runningApplications.map { application in
            EnergyImpactCatalogCandidate(
                processIdentifier: application.processIdentifier,
                activationPolicy: application.activationPolicy,
                name: application.localizedName
                    ?? application.bundleIdentifier
                    ?? "Process \(application.processIdentifier)",
                bundleIdentifier: application.bundleIdentifier,
                bundleURL: application.bundleURL
            )
        }
        let preRunCatalogAppCount = SystemEnergyImpactAppCatalog.appSnapshots(
            from: candidates,
            scope: scope
        ).count
        let systemSnapshotProcessCount = SystemProcessParentSnapshotReader().snapshots().count
        let service = EnergyImpactService()
        guard let lease = await service.beginSession() else {
            XCTFail("Native validation could not begin a sampler lease")
            return
        }

        let metrics: NativeMetrics
        do {
            metrics = try await measureVisibleFacade(
                service: service,
                lease: lease,
                preRunCatalogAppCount: preRunCatalogAppCount,
                systemSnapshotProcessCount: systemSnapshotProcessCount,
                scope: scope
            )
        } catch {
            await service.endSession(lease)
            throw error
        }
        await service.endSession(lease)

        print(Self.nativeMetricLine(scope: scope, metrics: metrics))

        XCTAssertEqual(metrics.observationCount, 21)
        XCTAssertGreaterThan(metrics.preRunCatalogAppCount, 0)
        XCTAssertGreaterThan(metrics.systemSnapshotProcessCount, 0)
        XCTAssertTrue(metrics.p50Seconds.isFinite)
        XCTAssertTrue(metrics.p95Seconds.isFinite)
        XCTAssertTrue(metrics.cpuPercent.isFinite)
        XCTAssertGreaterThanOrEqual(metrics.cpuPercent, 0)
        XCTAssertTrue(metrics.wallSeconds.isFinite)
        XCTAssertGreaterThanOrEqual(metrics.wallSeconds, 60)
        XCTAssertLessThan(metrics.p95Seconds, 0.100)
    }

    private func measureVisibleFacade(
        service: EnergyImpactService,
        lease: EnergyImpactSamplingLease,
        preRunCatalogAppCount: Int,
        systemSnapshotProcessCount: Int,
        scope: EnergyImpactAppScope
    ) async throws -> NativeMetrics {
        let wallStart = ProcessInfo.processInfo.systemUptime
        let cpuStart = processCPUSeconds()
        var latencies = [TimeInterval]()
        latencies.reserveCapacity(21)

        for index in 0..<21 {
            if index > 0 {
                let deadline = wallStart + Double(index) * 3
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining >= 0 else {
                    throw NativeValidationError.missedDeadline(
                        index: index,
                        latenessSeconds: -remaining
                    )
                }
                if remaining > 0 {
                    try await Task.sleep(
                        nanoseconds: UInt64(remaining * 1_000_000_000)
                    )
                }
            }

            let started = ProcessInfo.processInfo.systemUptime
            let observed = await service.observe(
                lease: lease,
                limit: 20,
                scope: scope
            )
            guard observed != nil else {
                throw NativeValidationError.observationRejected(index)
            }
            latencies.append(ProcessInfo.processInfo.systemUptime - started)
        }

        let wall = ProcessInfo.processInfo.systemUptime - wallStart
        let cpuPercent = (processCPUSeconds() - cpuStart) / wall * 100
        let sorted = latencies.sorted()

        return NativeMetrics(
            observationCount: latencies.count,
            preRunCatalogAppCount: preRunCatalogAppCount,
            systemSnapshotProcessCount: systemSnapshotProcessCount,
            p50Seconds: nearestRank(sorted, percentile: 0.50),
            p95Seconds: nearestRank(sorted, percentile: 0.95),
            cpuPercent: cpuPercent,
            wallSeconds: wall
        )
    }

    private func nearestRank(
        _ sorted: [TimeInterval],
        percentile: Double
    ) -> TimeInterval {
        precondition(sorted.isEmpty == false)
        let rawIndex =
            Int(ceil(percentile * Double(sorted.count))) - 1
        let index = min(
            sorted.count - 1,
            max(0, rawIndex)
        )
        return sorted[index]
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
