import CoreAudio
import Foundation

enum AudioIOProcStreamUsage {
    static func ioProcPointer(
        _ ioProcID: AudioDeviceIOProcID
    ) -> UnsafeMutableRawPointer {
        unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self)
    }

    static func byteCount(streamCount: Int) -> Int {
        precondition(streamCount > 0)
        return MemoryLayout<AudioHardwareIOProcStreamUsage>.size
            + (streamCount - 1) * MemoryLayout<UInt32>.stride
    }

    static func withEncoded<R>(
        ioProcID: AudioDeviceIOProcID,
        flags: [UInt32],
        _ body: (UnsafeMutableRawBufferPointer) throws -> R
    ) rethrows -> R {
        precondition(flags.isEmpty == false)
        let count = byteCount(streamCount: flags.count)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: count,
            alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
        )
        let usage = storage.bindMemory(
            to: AudioHardwareIOProcStreamUsage.self,
            capacity: 1
        )
        usage.initialize(to: AudioHardwareIOProcStreamUsage(
            mIOProc: ioProcPointer(ioProcID),
            mNumberStreams: UInt32(flags.count),
            mStreamIsOn: (flags[0])
        ))
        defer {
            usage.deinitialize(count: 1)
            storage.deallocate()
        }
        let flagOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>
            .offset(of: \AudioHardwareIOProcStreamUsage.mStreamIsOn)!
        for (index, flag) in flags.enumerated().dropFirst() {
            storage.advanced(
                by: flagOffset + index * MemoryLayout<UInt32>.stride
            ).storeBytes(of: flag, as: UInt32.self)
        }
        return try body(UnsafeMutableRawBufferPointer(start: storage, count: count))
    }

    static func decode(
        _ bytes: UnsafeRawBufferPointer,
        expectedIOProcID: AudioDeviceIOProcID,
        expectedStreamCount: Int
    ) throws -> [UInt32] {
        guard expectedStreamCount > 0 else {
            throw AudioIOProcStreamUsageError.streamCountMismatch
        }
        guard bytes.count == byteCount(streamCount: expectedStreamCount),
              let baseAddress = bytes.baseAddress
        else {
            throw AudioIOProcStreamUsageError.byteCountMismatch
        }
        let usage = baseAddress.load(as: AudioHardwareIOProcStreamUsage.self)
        guard usage.mIOProc == ioProcPointer(expectedIOProcID) else {
            throw AudioIOProcStreamUsageError.ioProcMismatch
        }
        guard usage.mNumberStreams == UInt32(expectedStreamCount) else {
            throw AudioIOProcStreamUsageError.streamCountMismatch
        }
        let flagOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>
            .offset(of: \AudioHardwareIOProcStreamUsage.mStreamIsOn)!
        return (0..<expectedStreamCount).map { index in
            baseAddress.load(
                fromByteOffset: flagOffset + index * MemoryLayout<UInt32>.stride,
                as: UInt32.self
            )
        }
    }
}

enum AudioIOProcStreamUsageError: Error, Equatable, Sendable {
    case propertyMissing
    case propertyNotSettable
    case writeFailed(OSStatus)
    case readFailed(OSStatus)
    case byteCountMismatch
    case ioProcMismatch
    case streamCountMismatch
    case flagsMismatch
}
