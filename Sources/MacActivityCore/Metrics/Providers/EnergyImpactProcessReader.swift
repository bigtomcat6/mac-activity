import Darwin
import Foundation

public struct ProcessEnergyReading: Equatable, Sendable {
    public let energyNanojoules: UInt64
    public let processStartAbsoluteTime: UInt64
    public let userCPUTime: UInt64
    public let systemCPUTime: UInt64

    public init(
        energyNanojoules: UInt64,
        processStartAbsoluteTime: UInt64 = 0,
        userCPUTime: UInt64 = 0,
        systemCPUTime: UInt64 = 0
    ) {
        self.energyNanojoules = energyNanojoules
        self.processStartAbsoluteTime = processStartAbsoluteTime
        self.userCPUTime = userCPUTime
        self.systemCPUTime = systemCPUTime
    }
}

public enum ProcessEnergyReadFailure: Equatable, Sendable {
    case exited
    case permissionDenied
    case unsupported
    case other(Int32)
}

public enum ProcessEnergyReadResult: Equatable, Sendable {
    case success(ProcessEnergyReading)
    case failure(ProcessEnergyReadFailure)
}

public protocol ProcessEnergyReadingProvider: Sendable {
    func reading(for processIdentifier: pid_t) -> ProcessEnergyReadResult
}

public struct SystemProcessEnergyReader: ProcessEnergyReadingProvider {
    public init() {}

    public func reading(for processIdentifier: pid_t) -> ProcessEnergyReadResult {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(processIdentifier, RUSAGE_INFO_V6, rebound)
            }
        }
        guard result == 0 else {
            let code = errno
            return .failure(Self.failure(for: code))
        }
        return .success(ProcessEnergyReading(
            energyNanojoules: info.ri_energy_nj,
            processStartAbsoluteTime: info.ri_proc_start_abstime,
            userCPUTime: info.ri_user_time,
            systemCPUTime: info.ri_system_time
        ))
    }

    static func failure(for code: Int32) -> ProcessEnergyReadFailure {
        switch code {
        case ESRCH:
            return .exited
        case EPERM, EACCES:
            return .permissionDenied
        case ENOTSUP, EINVAL:
            return .unsupported
        default:
            return .other(code)
        }
    }
}

public struct ProcessParentSnapshot: Equatable, Sendable {
    public let processIdentifier: pid_t
    public let parentProcessIdentifier: pid_t

    public init(processIdentifier: pid_t, parentProcessIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
        self.parentProcessIdentifier = parentProcessIdentifier
    }
}

public protocol ProcessParentSnapshotReading: Sendable {
    func snapshots() -> [ProcessParentSnapshot]
}

public struct SystemProcessParentSnapshotReader: ProcessParentSnapshotReading {
    public init() {}

    public func snapshots() -> [ProcessParentSnapshot] {
        let initialCount = max(Int(proc_listallpids(nil, 0)), 0)
        guard initialCount > 0 else { return [] }
        var processIdentifiers = [pid_t](repeating: 0, count: initialCount + 32)
        let count = processIdentifiers.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }

        return processIdentifiers.prefix(Int(count)).compactMap { processIdentifier in
            guard processIdentifier > 0 else { return nil }
            var info = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            let read = proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                &info,
                Int32(size)
            )
            guard read == Int32(size) else { return nil }
            return ProcessParentSnapshot(
                processIdentifier: processIdentifier,
                parentProcessIdentifier: pid_t(info.pbi_ppid)
            )
        }
    }
}
