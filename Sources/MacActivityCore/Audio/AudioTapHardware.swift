import CoreAudio
import Foundation

enum AudioTapMuteState: Equatable, Sendable {
    case unmuted
    case mutedWhenTapped
}

struct AudioTapResource: Equatable, Sendable {
    let objectID: AudioObjectID
    let uuid: UUID
    let source: AudioTapSource
}

struct AudioAggregateResource: Equatable, Sendable {
    let objectID: AudioObjectID
    let uid: String
}

struct AudioIOProcResource: @unchecked Sendable {
    let aggregateDeviceID: AudioObjectID
    let ioProcID: AudioDeviceIOProcID
}

struct AudioAggregateLayout: Equatable, Sendable {
    let inputFormats: [ProcessTapAudioFormat]
    let outputFormats: [ProcessTapAudioFormat]
    let channelMaps: [ProcessTapChannelMap]
}

struct AudioOwnedObject: Equatable, Sendable {
    let id: AudioObjectID
    let classID: AudioClassID
    let uid: String
    let name: String
}

enum AudioTapHardwareError: Error, Equatable, Sendable {
    case aggregateNotReady
}

protocol AudioTapHardware: AnyObject, Sendable {
    func createTap(
        processObjectID: AudioObjectID,
        source: AudioTapSource,
        uuid: UUID
    ) throws -> AudioTapResource
    func readTapFormat(_ tap: AudioTapResource) throws -> ProcessTapAudioFormat
    func createAggregate(
        plan: AudioRoutePlan,
        taps: [AudioTapResource]
    ) throws -> AudioAggregateResource
    func waitUntilReady(
        _ aggregate: AudioAggregateResource,
        deadline: DispatchTime,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws
    func readAggregateLayout(
        _ aggregate: AudioAggregateResource,
        plan: AudioRoutePlan,
        taps: [AudioTapResource]
    ) throws -> AudioAggregateLayout
    func createIOProc(
        aggregate: AudioAggregateResource,
        context: ProcessTapDSPContext
    ) throws -> AudioIOProcResource
    func start(_ ioProc: AudioIOProcResource) throws
    func setMuteState(
        _ state: AudioTapMuteState,
        for tap: AudioTapResource
    ) throws
    func stop(_ ioProc: AudioIOProcResource) -> OSStatus
    func destroyIOProc(_ ioProc: AudioIOProcResource) -> OSStatus
    func destroyAggregate(_ aggregate: AudioAggregateResource) -> OSStatus
    func destroyTap(_ tap: AudioTapResource) -> OSStatus
    func ownedObjects() throws -> [AudioOwnedObject]
}
