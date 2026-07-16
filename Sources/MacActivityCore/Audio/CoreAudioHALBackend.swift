import CoreAudio
import Dispatch
import Foundation

final class CoreAudioHALBackend: AudioHALBackend, @unchecked Sendable {
    func hasProperty(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) -> Bool {
        var rawAddress = address.rawValue
        return AudioObjectHasProperty(objectID, &rawAddress)
    }

    func getPropertyDataSize(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        byteCount: inout UInt32
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectGetPropertyDataSize(objectID, &rawAddress, 0, nil, &byteCount)
    }

    func getPropertyData(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        byteCount: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectGetPropertyData(
            objectID,
            &rawAddress,
            0,
            nil,
            &byteCount,
            data
        )
    }

    func setPropertyData(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        byteCount: UInt32,
        data: UnsafeRawPointer
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectSetPropertyData(
            objectID,
            &rawAddress,
            0,
            nil,
            byteCount,
            data
        )
    }

    func isPropertySettable(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        isSettable: inout DarwinBoolean
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectIsPropertySettable(objectID, &rawAddress, &isSettable)
    }

    func addPropertyListener(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        queue: DispatchQueue,
        registration: AudioHALListenerRegistration
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectAddPropertyListenerBlock(
            objectID,
            &rawAddress,
            queue,
            registration.block
        )
    }

    func removePropertyListener(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        queue: DispatchQueue,
        registration: AudioHALListenerRegistration
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectRemovePropertyListenerBlock(
            objectID,
            &rawAddress,
            queue,
            registration.block
        )
    }

    func createProcessTap(
        _ description: CATapDescription,
        objectID: inout AudioObjectID
    ) -> OSStatus {
        guard #available(macOS 14.2, *) else {
            return kAudioHardwareUnspecifiedError
        }
        return AudioHardwareCreateProcessTap(description, &objectID)
    }

    func destroyProcessTap(_ objectID: AudioObjectID) -> OSStatus {
        guard #available(macOS 14.2, *) else {
            return kAudioHardwareUnspecifiedError
        }
        return AudioHardwareDestroyProcessTap(objectID)
    }

    func createAggregateDevice(
        _ description: CFDictionary,
        objectID: inout AudioObjectID
    ) -> OSStatus {
        AudioHardwareCreateAggregateDevice(description, &objectID)
    }

    func destroyAggregateDevice(_ objectID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyAggregateDevice(objectID)
    }

    func createIOProc(
        deviceID: AudioDeviceID,
        callback: AudioDeviceIOProc,
        clientData: UnsafeMutableRawPointer?,
        ioProcID: inout AudioDeviceIOProcID?
    ) -> OSStatus {
        AudioDeviceCreateIOProcID(deviceID, callback, clientData, &ioProcID)
    }

    func destroyIOProc(
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID
    ) -> OSStatus {
        AudioDeviceDestroyIOProcID(deviceID, ioProcID)
    }

    func startDevice(
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID
    ) -> OSStatus {
        AudioDeviceStart(deviceID, ioProcID)
    }

    func stopDevice(
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID
    ) -> OSStatus {
        AudioDeviceStop(deviceID, ioProcID)
    }
}
