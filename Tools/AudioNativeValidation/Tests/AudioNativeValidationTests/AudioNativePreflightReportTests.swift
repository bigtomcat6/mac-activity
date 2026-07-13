import CoreAudio
import Foundation
import MacActivityCore
@testable import AudioNativePreflightKit
import XCTest

final class AudioNativePreflightReportTests: XCTestCase {
    func testStrictOutputDeviceDiscoveryPropagatesStreamReadFailure() {
        enum ReadFailure: Error { case failed }

        XCTAssertThrowsError(try AudioNativePreflightHALDiscovery.outputDevices(
            deviceIDs: [101, 202],
            outputStreams: { deviceID in
                if deviceID == 202 { throw ReadFailure.failed }
                return [801]
            }
        )) { error in
            XCTAssertTrue(error is ReadFailure)
        }
    }

    func testStrictOutputDeviceDiscoveryOmitsOnlyConfirmedEmptyStreamLists() throws {
        let devices = AudioNativePreflightHALDiscovery.outputDevices(
            deviceIDs: [101, 202],
            outputStreams: { deviceID in deviceID == 101 ? [] : [802, 803] }
        )

        XCTAssertEqual(devices.map(\.deviceID), [202])
        XCTAssertEqual(devices.map(\.outputStreamIDs), [[802, 803]])
    }

    func testOptionalMetadataPropagatesReadFailureWhenPropertyExists() {
        enum ReadFailure: Error { case failed }

        XCTAssertThrowsError(try AudioNativePreflightHALDiscovery.optionalProperty(
            isPresent: true,
            read: { () throws -> UInt32 in throw ReadFailure.failed }
        )) { error in
            XCTAssertTrue(error is ReadFailure)
        }
    }

    func testOptionalMetadataDoesNotReadAbsentProperty() throws {
        var didRead = false

        let value: UInt32? = AudioNativePreflightHALDiscovery.optionalProperty(
            isPresent: false,
            read: {
                didRead = true
                return 42
            }
        )

        XCTAssertNil(value)
        XCTAssertFalse(didRead)
    }

    func testRequiredAggregateMetadataRejectsAbsentProperty() {
        XCTAssertThrowsError(try AudioNativePreflightHALDiscovery.requiredProperty(
            isPresent: false,
            name: "FullSubDeviceList",
            read: { ["leaf-a"] }
        )) { error in
            XCTAssertEqual(
                error as? AudioNativePreflightHALDiscoveryError,
                .missingRequiredProperty("FullSubDeviceList")
            )
        }
    }

    func testRequiredAggregateMetadataPropagatesReadFailure() {
        enum ReadFailure: Error { case failed }

        XCTAssertThrowsError(try AudioNativePreflightHALDiscovery.requiredProperty(
            isPresent: true,
            name: "TapList",
            read: { () throws -> [String] in throw ReadFailure.failed }
        )) { error in
            XCTAssertTrue(error is ReadFailure)
        }
    }

    func testRouteMappingRejectsControlSnapshotFromDifferentDeviceGeneration() {
        let format = ProcessTapAudioFormat(
            sampleRate: 48_000,
            channelCount: 2,
            formatID: kAudioFormatLinearPCM,
            formatFlags: kAudioFormatFlagIsFloat,
            bitsPerChannel: 32,
            interleaving: .interleaved
        )
        let route = AudioRouteDevice(
            objectID: 101,
            uid: "uid-a",
            name: "Output",
            isAlive: true,
            isAggregate: false,
            aggregateSubdeviceUIDs: [],
            outputStreams: [
                AudioRouteStream(streamObjectID: 801, streamIndex: 0, format: format),
            ]
        )
        let controls = AudioOutputDeviceSnapshot(
            id: "uid-a",
            objectID: 202,
            name: "Output",
            volume: .unsupported,
            mute: .unsupported
        )

        XCTAssertThrowsError(try AudioNativePreflightDeviceObservation(
            routeDevice: route,
            controlSnapshot: controls,
            exactFormat: { _ in AudioStreamBasicDescription() }
        )) { error in
            XCTAssertEqual(
                error as? AudioNativePreflightObservationError,
                .deviceChanged(uid: "uid-a", routeObjectID: 101, controlObjectID: 202)
            )
        }
    }

    func testProcessDiscoveryPropagatesInjectedSnapshotFailure() {
        enum ReadFailure: Error { case failed }

        XCTAssertThrowsError(try AudioNativePreflightProcessDiscovery.observations(
            processObjectIDs: [501],
            apps: [],
            snapshot: { _ in throw ReadFailure.failed }
        )) { error in
            XCTAssertTrue(error is ReadFailure)
        }
    }

    func testRouteAndControlSnapshotsMapUsingInjectedExactFormatReader() throws {
        let partialFormat = ProcessTapAudioFormat(
            sampleRate: 44_100,
            channelCount: 2,
            formatID: kAudioFormatLinearPCM,
            formatFlags: kAudioFormatFlagIsFloat,
            bitsPerChannel: 32,
            interleaving: .interleaved
        )
        let route = AudioRouteDevice(
            objectID: 101,
            uid: "uid-a",
            name: "Output",
            isAlive: true,
            isAggregate: false,
            aggregateSubdeviceUIDs: [],
            inputStreams: [
                AudioRouteStream(streamObjectID: 801, streamIndex: 4, format: partialFormat),
            ],
            outputStreams: [
                AudioRouteStream(streamObjectID: 802, streamIndex: 7, format: partialFormat),
            ],
            clockDomain: 9,
            transportType: kAudioDeviceTransportTypeBuiltIn,
            modelUID: "model-a",
            driverIdentity: nil,
            aggregateComposition: nil
        )
        let controls = AudioOutputDeviceSnapshot(
            id: "uid-a",
            objectID: 101,
            name: "Output",
            volume: .value(0.5, isWritable: false),
            mute: .unsupported
        )
        var readStreamIDs: [AudioStreamID] = []

        let observation = try AudioNativePreflightDeviceObservation(
            routeDevice: route,
            controlSnapshot: controls,
            exactFormat: { streamID in
                readStreamIDs.append(streamID)
                return AudioStreamBasicDescription(
                    mSampleRate: 96_000,
                    mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                    mBytesPerPacket: 16,
                    mFramesPerPacket: 1,
                    mBytesPerFrame: 16,
                    mChannelsPerFrame: 4,
                    mBitsPerChannel: 32,
                    mReserved: 0
                )
            }
        )

        XCTAssertEqual(readStreamIDs, [801, 802])
        XCTAssertEqual(observation.diagnosticObjectID, 101)
        XCTAssertEqual(observation.uid, "uid-a")
        XCTAssertEqual(observation.inputStreams.first?.index, 4)
        XCTAssertEqual(observation.outputStreams.first?.index, 7)
        XCTAssertEqual(observation.outputStreams.first?.format.sampleRate, 96_000)
        XCTAssertEqual(observation.outputStreams.first?.format.channelsPerFrame, 4)
        XCTAssertEqual(observation.volume, .value(0.5, isWritable: false))
        XCTAssertEqual(observation.mute, .unsupported)
    }

    func testInjectedObservationsMapToDeterministicPrettyPrintedJSON() throws {
        let format = AudioNativePreflightStreamFormat(
            sampleRate: 48_000,
            formatID: kAudioFormatLinearPCM,
            formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            bytesPerPacket: 8,
            framesPerPacket: 1,
            bytesPerFrame: 8,
            channelsPerFrame: 2,
            bitsPerChannel: 32,
            reserved: 0
        )
        let devices = [
            AudioNativePreflightDeviceObservation(
                diagnosticObjectID: 202,
                uid: "uid-z",
                name: "USB Output",
                alive: true,
                isAggregate: true,
                aggregateComposition: AudioRouteAggregateComposition(
                    fullSubdeviceUIDs: ["leaf-b", "leaf-a"],
                    activeSubdeviceUIDs: ["leaf-b"],
                    mainSubdeviceUID: "leaf-b",
                    isStacked: false,
                    tapUUIDs: []
                ),
                modelUID: "model-z",
                driverIdentity: AudioRouteDriverIdentity(
                    plugInBundleID: "com.example.driver",
                    availableVersion: "1.2.3"
                ),
                transportType: kAudioDeviceTransportTypeUSB,
                clockDomain: 42,
                inputStreams: [],
                outputStreams: [
                    AudioNativePreflightStreamObservation(
                        diagnosticObjectID: 902,
                        index: 0,
                        format: format
                    ),
                ],
                volume: .unavailable,
                mute: .failed("getData status -66748")
            ),
            AudioNativePreflightDeviceObservation(
                diagnosticObjectID: 101,
                uid: "uid-a",
                name: "Built-in Output",
                alive: true,
                isAggregate: false,
                aggregateComposition: nil,
                modelUID: nil,
                driverIdentity: nil,
                transportType: kAudioDeviceTransportTypeBuiltIn,
                clockDomain: 0,
                inputStreams: [
                    AudioNativePreflightStreamObservation(
                        diagnosticObjectID: 801,
                        index: 0,
                        format: format
                    ),
                ],
                outputStreams: [
                    AudioNativePreflightStreamObservation(
                        diagnosticObjectID: 802,
                        index: 0,
                        format: format
                    ),
                ],
                volume: .value(0.625, isWritable: true),
                mute: .unsupported
            ),
        ]
        let processes = [
            AudioNativePreflightProcessObservation(
                diagnosticProcessObjectID: 501,
                pid: 1234,
                name: "Test Player",
                bundleIdentifier: "com.example.player",
                outputDeviceIDs: [202, 999, 101]
            ),
        ]

        let report = AudioNativePreflightReport.make(
            schemaVersion: 1,
            operatingSystemVersion: "15.5.0",
            osBuild: "24F74",
            processDiscoveryAvailable: true,
            devices: devices,
            processes: processes
        )
        let first = try AudioNativePreflightJSON.encode(report)
        let second = try AudioNativePreflightJSON.encode(report)

        XCTAssertEqual(first, second)
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("{\n"))
        XCTAssertTrue(text.hasSuffix("\n"))

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: first) as? [String: Any]
        )
        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
        XCTAssertEqual(root["processDiscoveryAvailable"] as? Bool, true)
        let operatingSystem = try XCTUnwrap(root["operatingSystem"] as? [String: Any])
        XCTAssertEqual(operatingSystem["version"] as? String, "15.5.0")
        XCTAssertEqual(operatingSystem["build"] as? String, "24F74")

        let encodedDevices = try XCTUnwrap(root["devices"] as? [[String: Any]])
        XCTAssertEqual(encodedDevices.compactMap { $0["uid"] as? String }, ["uid-a", "uid-z"])
        XCTAssertEqual(encodedDevices[0]["diagnosticObjectID"] as? Int, 101)
        XCTAssertEqual(encodedDevices[0]["isAggregate"] as? Bool, false)
        XCTAssertTrue(encodedDevices[0]["aggregateComposition"] is NSNull)
        let valueVolume = try XCTUnwrap(encodedDevices[0]["volume"] as? [String: Any])
        XCTAssertEqual(valueVolume["status"] as? String, "value")
        XCTAssertEqual(valueVolume["value"] as? Double, 0.625)
        XCTAssertEqual(valueVolume["isWritable"] as? Bool, true)
        let unsupportedMute = try XCTUnwrap(encodedDevices[0]["mute"] as? [String: Any])
        XCTAssertEqual(unsupportedMute["status"] as? String, "unsupported")

        let inputStreams = try XCTUnwrap(encodedDevices[0]["inputStreams"] as? [[String: Any]])
        let encodedFormat = try XCTUnwrap(inputStreams[0]["format"] as? [String: Any])
        XCTAssertEqual(encodedFormat["sampleRate"] as? Double, 48_000)
        XCTAssertEqual(encodedFormat["formatID"] as? Int, Int(kAudioFormatLinearPCM))
        XCTAssertEqual(encodedFormat["formatFlags"] as? Int, Int(kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked))
        XCTAssertEqual(encodedFormat["bytesPerPacket"] as? Int, 8)
        XCTAssertEqual(encodedFormat["framesPerPacket"] as? Int, 1)
        XCTAssertEqual(encodedFormat["bytesPerFrame"] as? Int, 8)
        XCTAssertEqual(encodedFormat["channelsPerFrame"] as? Int, 2)
        XCTAssertEqual(encodedFormat["bitsPerChannel"] as? Int, 32)
        XCTAssertEqual(encodedFormat["reserved"] as? Int, 0)

        let unavailableVolume = try XCTUnwrap(encodedDevices[1]["volume"] as? [String: Any])
        XCTAssertEqual(unavailableVolume["status"] as? String, "unavailable")
        let failed = try XCTUnwrap(encodedDevices[1]["mute"] as? [String: Any])
        XCTAssertEqual(failed["status"] as? String, "failed")
        XCTAssertEqual(failed["failure"] as? String, "getData status -66748")
        let aggregate = try XCTUnwrap(
            encodedDevices[1]["aggregateComposition"] as? [String: Any]
        )
        XCTAssertEqual(aggregate["fullSubdeviceUIDs"] as? [String], ["leaf-b", "leaf-a"])
        XCTAssertEqual(aggregate["activeSubdeviceUIDs"] as? [String], ["leaf-b"])
        XCTAssertEqual(aggregate["mainSubdeviceUID"] as? String, "leaf-b")
        XCTAssertEqual(aggregate["isStacked"] as? Bool, false)

        let encodedProcesses = try XCTUnwrap(root["processes"] as? [[String: Any]])
        XCTAssertEqual(encodedProcesses[0]["diagnosticProcessObjectID"] as? Int, 501)
        XCTAssertEqual(encodedProcesses[0]["pid"] as? Int, 1234)
        XCTAssertEqual(encodedProcesses[0]["outputDeviceIDs"] as? [Int], [202, 999, 101])
        XCTAssertEqual(encodedProcesses[0]["outputDeviceUIDs"] as? [String], ["uid-z", "uid-a"])
        XCTAssertEqual(encodedProcesses[0]["unmappedOutputDeviceIDs"] as? [Int], [999])
    }
}
