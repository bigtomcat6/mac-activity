import CoreAudio
import Foundation

public enum AudioHALOperation: String, Equatable, Sendable {
    case hasProperty
    case getDataSize
    case getData
    case setData
    case isSettable
    case addListener
    case removeListener
    case createTap
    case destroyTap
    case createAggregate
    case destroyAggregate
    case createIOProc
    case destroyIOProc
    case startDevice
    case stopDevice
}

public struct AudioHALPropertyAddress: Hashable, Sendable {
    public let selector: AudioObjectPropertySelector
    public let scope: AudioObjectPropertyScope
    public let element: AudioObjectPropertyElement

    public init(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        self.selector = selector
        self.scope = scope
        self.element = element
    }

    var rawValue: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }
}

public struct AudioHALError: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case status(OSStatus)
        case invalidDataSize(byteCount: UInt32, elementStride: Int)
        case retryLimitExceeded
        case missingValue
    }

    public let operation: AudioHALOperation
    public let objectID: AudioObjectID
    public let address: AudioHALPropertyAddress?
    public let reason: Reason

    public var status: OSStatus? {
        guard case .status(let status) = reason else { return nil }
        return status
    }
}

public enum AudioPropertyValue<Value: Equatable & Sendable>: Equatable, Sendable {
    case value(Value, isWritable: Bool)
    case unsupported
    case unavailable
    case failed(AudioHALError)

    public var value: Value? {
        guard case .value(let value, _) = self else { return nil }
        return value
    }

    public var isWritable: Bool {
        guard case .value(_, let isWritable) = self else { return false }
        return isWritable
    }
}

public struct AudioOutputDeviceSnapshot: Identifiable, Equatable, Sendable {
    public let id: String
    public let objectID: AudioDeviceID
    public let name: String
    public let volume: AudioPropertyValue<Double>
    public let mute: AudioPropertyValue<Bool>

    public init(
        id: String,
        objectID: AudioDeviceID,
        name: String,
        volume: AudioPropertyValue<Double>,
        mute: AudioPropertyValue<Bool>
    ) {
        self.id = id
        self.objectID = objectID
        self.name = name
        self.volume = volume
        self.mute = mute
    }
}
