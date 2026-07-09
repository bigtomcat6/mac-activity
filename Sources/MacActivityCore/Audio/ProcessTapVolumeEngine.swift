import CoreAudio
import Foundation

public struct ProcessAudioVolumeState: Equatable, Sendable {
    public let processIdentifier: pid_t
    public private(set) var volume: Double
    public var isMuted: Bool

    public init(processIdentifier: pid_t, volume: Double = 1, isMuted: Bool = false) {
        self.processIdentifier = processIdentifier
        self.volume = Self.clamped(volume)
        self.isMuted = isMuted
    }

    public var effectiveVolume: Double {
        isMuted ? 0 : volume
    }

    public mutating func setVolume(_ volume: Double) {
        self.volume = Self.clamped(volume)
    }

    private static func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

@MainActor
public final class ProcessTapVolumeEngine {
    public enum Error: Swift.Error, Equatable {
        case processTapsUnavailable
        case tapCreationFailed(OSStatus)
    }

    private let availability: AudioFeatureAvailability
    private var sessions: [pid_t: ProcessTapSession] = [:]
    private var states: [pid_t: ProcessAudioVolumeState] = [:]

    public init(availability: AudioFeatureAvailability = .current) {
        self.availability = availability
    }

    deinit {
        for session in sessions.values {
            if #available(macOS 14.2, *) {
                Self.destroy(session: session)
            }
        }
    }

    public func start(entry: AudioProcessEntry) throws {
        guard availability.supportsProcessVolume else {
            throw Error.processTapsUnavailable
        }

        if #available(macOS 14.2, *) {
            if sessions[entry.processIdentifier] != nil {
                stop(processIdentifier: entry.processIdentifier)
            }

            try startTap(entry: entry)
        } else {
            throw Error.processTapsUnavailable
        }
    }

    public func stop(processIdentifier: pid_t) {
        guard let session = sessions.removeValue(forKey: processIdentifier) else { return }

        if #available(macOS 14.2, *) {
            Self.destroy(session: session)
        }

        states.removeValue(forKey: processIdentifier)
    }

    public func setVolume(_ volume: Double, processIdentifier: pid_t) {
        var state = states[processIdentifier] ?? ProcessAudioVolumeState(processIdentifier: processIdentifier)
        state.setVolume(volume)
        states[processIdentifier] = state
        sessions[processIdentifier]?.gainBox.set(Float32(state.effectiveVolume))
    }

    public func setMuted(_ isMuted: Bool, processIdentifier: pid_t) {
        var state = states[processIdentifier] ?? ProcessAudioVolumeState(processIdentifier: processIdentifier)
        state.isMuted = isMuted
        states[processIdentifier] = state
        sessions[processIdentifier]?.gainBox.set(Float32(state.effectiveVolume))
    }
}

private extension ProcessTapVolumeEngine {
    struct ProcessTapSession {
        let tapID: AudioObjectID
        let aggregateDeviceID: AudioObjectID
        let ioProcID: AudioDeviceIOProcID
        let gainBox: RealtimeProcessGainBox
    }

    @available(macOS 14.2, *)
    func startTap(entry: AudioProcessEntry) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: [entry.processObjectID])
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            throw Error.tapCreationFailed(status)
        }

        do {
            let aggregateDeviceID = try Self.createAggregateDevice(
                tapUUID: description.uuid,
                processIdentifier: entry.processIdentifier
            )
            let gainBox = RealtimeProcessGainBox()
            let ioProcID = try Self.startIOProc(
                aggregateDeviceID: aggregateDeviceID,
                gainBox: gainBox
            )
            let session = ProcessTapSession(
                tapID: tapID,
                aggregateDeviceID: aggregateDeviceID,
                ioProcID: ioProcID,
                gainBox: gainBox
            )
            sessions[entry.processIdentifier] = session
            states[entry.processIdentifier] = ProcessAudioVolumeState(
                processIdentifier: entry.processIdentifier
            )
        } catch let error as Error {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw Error.tapCreationFailed(kAudioHardwareUnspecifiedError)
        }
    }

    @available(macOS 14.2, *)
    static func createAggregateDevice(
        tapUUID: UUID,
        processIdentifier: pid_t
    ) throws -> AudioObjectID {
        let defaultOutputDeviceID = try defaultOutputDeviceID()
        let defaultOutputDeviceUID = try deviceUID(for: defaultOutputDeviceID)
        let uid = "com.haozhe.macactivity.process-tap.\(processIdentifier).\(tapUUID.uuidString)"
        let subDeviceDescription: [String: Any] = [
            kAudioSubDeviceUIDKey: defaultOutputDeviceUID,
        ]
        let tapDescription: [String: Any] = [
            kAudioSubTapUIDKey: tapUUID.uuidString,
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationHighQuality,
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceNameKey: "MacActivity Process Tap \(processIdentifier)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [subDeviceDescription],
            kAudioAggregateDeviceMainSubDeviceKey: defaultOutputDeviceUID,
            kAudioAggregateDeviceClockDeviceKey: defaultOutputDeviceUID,
            kAudioAggregateDeviceTapListKey: [tapDescription],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]

        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateDeviceID
        )
        guard status == noErr else {
            throw Error.tapCreationFailed(status)
        }

        return aggregateDeviceID
    }

    static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = propertyAddress(
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw Error.tapCreationFailed(status == noErr ? kAudioHardwareUnspecifiedError : status)
        }

        return deviceID
    }

    static func deviceUID(for deviceID: AudioDeviceID) throws -> String {
        var address = propertyAddress(
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let pointer = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        pointer.initialize(to: nil)
        defer { pointer.deinitialize(count: 1) }
        var byteCount = UInt32(MemoryLayout<CFString?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &byteCount,
            pointer
        )
        guard status == noErr, let value = pointer.pointee else {
            throw Error.tapCreationFailed(status == noErr ? kAudioHardwareUnspecifiedError : status)
        }

        return value as String
    }

    @available(macOS 14.2, *)
    static func startIOProc(
        aggregateDeviceID: AudioObjectID,
        gainBox: RealtimeProcessGainBox
    ) throws -> AudioDeviceIOProcID {
        var ioProcID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcID(
            aggregateDeviceID,
            processTapVolumeIOProc,
            UnsafeMutableRawPointer(mutating: gainBox.pointer),
            &ioProcID
        )
        guard status == noErr, let ioProcID else {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            throw Error.tapCreationFailed(status)
        }

        status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            throw Error.tapCreationFailed(status)
        }

        return ioProcID
    }

    @available(macOS 14.2, *)
    nonisolated static func destroy(session: ProcessTapSession) {
        AudioDeviceStop(session.aggregateDeviceID, session.ioProcID)
        AudioDeviceDestroyIOProcID(session.aggregateDeviceID, session.ioProcID)
        AudioHardwareDestroyAggregateDevice(session.aggregateDeviceID)
        AudioHardwareDestroyProcessTap(session.tapID)
    }

    static func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

final class RealtimeProcessGainBox: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float32>

    init(initialValue: Float32 = 1) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: initialValue)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    func set(_ value: Float32) {
        storage.pointee = value
    }

    var pointer: UnsafePointer<Float32> {
        UnsafePointer(storage)
    }
}

private let processTapVolumeIOProc: AudioDeviceIOProc = { _, _, inputData, _, outputData, _, clientData in
    guard let clientData else {
        return noErr
    }

    let gain = clientData.assumingMemoryBound(to: Float32.self).pointee
    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
    let bufferCount = min(inputBuffers.count, outputBuffers.count)

    for bufferIndex in 0..<bufferCount {
        let inputBuffer = inputBuffers[bufferIndex]
        var outputBuffer = outputBuffers[bufferIndex]
        guard let inputPointer = inputBuffer.mData, let outputPointer = outputBuffer.mData else {
            continue
        }

        let byteCount = min(Int(inputBuffer.mDataByteSize), Int(outputBuffer.mDataByteSize))
        let sampleCount = byteCount / MemoryLayout<Float32>.stride
        let inputSamples = inputPointer.assumingMemoryBound(to: Float32.self)
        let outputSamples = outputPointer.assumingMemoryBound(to: Float32.self)

        for sampleIndex in 0..<sampleCount {
            outputSamples[sampleIndex] = inputSamples[sampleIndex] * gain
        }

        outputBuffer.mDataByteSize = UInt32(sampleCount * MemoryLayout<Float32>.stride)
        outputBuffers[bufferIndex] = outputBuffer
    }

    return noErr
}
