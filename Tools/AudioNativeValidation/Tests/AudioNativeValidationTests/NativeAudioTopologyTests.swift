import CoreAudio
import Foundation
@testable import MacActivityCore
import XCTest

struct NativeValidationEnvironment {
    let processObjectID: AudioObjectID
    let targetUIDs: [String]
    let outputURL: URL
    let microphoneTCCObservation: String
    let observationSeconds: Double
}

enum NativeValidationConfigurationError: Error {
    case missing(String)
    case invalid(String)
}

struct NativeAudioValidationRecord: Codable, Sendable {
    let processObjectID: AudioObjectID
    let targetUIDs: [String]
    let exactFingerprint: AudioRouteTopologyFingerprint
    let tapResources: [NativeTapResourceObservation]
    let tapFormats: [NativeTapFormatObservation]
    let aggregateResource: NativeAggregateResourceObservation?
    let ioProcResource: NativeIOProcResourceObservation?
    let topology: NativeTopologyObservation?
    let verifiedInputStreamUsage: [UInt32]
    let callbackCountBeforeObservation: Int32?
    let callbackCountAfterObservation: Int32?
    let sustainedCallbacks: Bool
    let teardown: NativeTeardownObservation?
    let microphoneTCCObservation: String
    let rawFailures: [NativeRawFailure]
    let sessionError: String?
    let eligibleForPolicyPromotion: Bool
}

enum NativeValidationError: Error {
    case session(ProcessTapSessionSnapshot)
    case cleanup
    case teardownUnproven(String)
}

func requireNativeOptIn() throws -> NativeValidationEnvironment {
    let environment = ProcessInfo.processInfo.environment
    guard environment["MACACTIVITY_AUDIO_NATIVE_VALIDATION"] == "1" else {
        throw XCTSkip("Set MACACTIVITY_AUDIO_NATIVE_VALIDATION=1 explicitly")
    }
    return try makeNativeValidationEnvironment(
        environment: environment,
        operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion
    )
}

func makeNativeValidationEnvironment(
    environment: [String: String],
    operatingSystemVersion version: OperatingSystemVersion,
    restrictedRoots: [URL] = NativeValidationOutputPath.restrictedRoots,
    makeProcessObjectID: (String) -> AudioObjectID? = { AudioObjectID($0) }
) throws -> NativeValidationEnvironment {
    guard version.majorVersion > 14
            || (version.majorVersion == 14 && version.minorVersion >= 2)
    else {
        throw NativeValidationConfigurationError.invalid("macOS 14.2 or later is required")
    }
    guard let rawProcessID = environment["MACACTIVITY_AUDIO_PROCESS_OBJECT_ID"],
          let rawTargetUIDs = environment["MACACTIVITY_AUDIO_TARGET_UIDS"],
          let rawOutputPath = environment["MACACTIVITY_AUDIO_VALIDATION_OUTPUT"],
          let rawMicrophoneTCCObservation = environment[
              "MACACTIVITY_AUDIO_MIC_TCC_OBSERVATION"
          ]
    else {
        throw NativeValidationConfigurationError.missing(
            "process ID, target UIDs, output path, and microphone TCC observation are required"
        )
    }
    let outputPath = try NativeValidationOutputPath.validate(
        rawOutputPath,
        restrictedRoots: restrictedRoots
    )
    let microphoneTCCObservation = rawMicrophoneTCCObservation
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard microphoneTCCObservation.isEmpty == false else {
        throw NativeValidationConfigurationError.invalid(
            "microphone TCC observation must not be blank"
        )
    }
    let targetUIDs = rawTargetUIDs
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !targetUIDs.isEmpty else {
        throw NativeValidationConfigurationError.invalid("target UIDs must not be empty")
    }
    let observationSeconds = environment["MACACTIVITY_AUDIO_VALIDATION_SECONDS"]
        .flatMap(Double.init) ?? 10
    guard observationSeconds > 0, observationSeconds <= 60 else {
        throw NativeValidationConfigurationError.invalid("validation seconds must be in (0, 60]")
    }
    guard let processObjectID = makeProcessObjectID(rawProcessID),
          processObjectID != kAudioObjectUnknown
    else {
        throw NativeValidationConfigurationError.invalid("process object ID is invalid")
    }
    return NativeValidationEnvironment(
        processObjectID: processObjectID,
        targetUIDs: targetUIDs,
        outputURL: outputPath.url,
        microphoneTCCObservation: microphoneTCCObservation,
        observationSeconds: observationSeconds
    )
}

@MainActor
func makeNativeRequest(_ environment: NativeValidationEnvironment) throws -> AudioRouteRequest {
    let devices = try AudioDeviceVolumeService().routeDevices()
    let process = try XCTUnwrap(
        AudioProcessService.readProcessSnapshotsIfAvailable().first {
            $0.processObjectID == environment.processObjectID && $0.isRunningOutput
        }
    )
    let devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.objectID, $0) })
    let sourceUIDs = try process.outputDeviceIDs.map { id in
        try XCTUnwrap(devicesByID[id]?.uid, "Every process output device must be described")
    }
    guard !sourceUIDs.isEmpty else {
        throw NativeValidationConfigurationError.invalid(
            "selected process has no running output device"
        )
    }
    return AudioRouteRequest(
        processObjectID: environment.processObjectID,
        generation: 1,
        sourceDeviceUIDs: sourceUIDs,
        systemDefaultOutputDeviceUID: nil,
        mode: .explicit(targetDeviceUIDs: environment.targetUIDs),
        devices: devices
    )
}

@MainActor
func runNativeValidation(
    _ environment: NativeValidationEnvironment
) async throws -> NativeAudioValidationRecord {
    let request = try makeNativeRequest(environment)
    let fingerprint = try AudioRoutePlanner().topologyFingerprint(for: request)
    let plan = try AudioRoutePlanner(policy: AudioRouteNativeValidationPolicy(
        validatedFingerprints: [fingerprint]
    )).plan(request)
    let hardware = NativeRecordingAudioTapHardware()
    let engine = ProcessTapVolumeEngine(hardware: hardware)

    do {
        try await runNativeSession(
            environment: environment,
            plan: plan,
            hardware: hardware,
            engine: engine
        )
        let record = makeRecord(
            environment: environment,
            fingerprint: fingerprint,
            hardware: hardware,
            sessionError: nil
        )
        try write(record, to: environment.outputURL)
        return record
    } catch {
        if case .teardownUnproven = error as? NativeValidationError {
            throw error
        }
        let record = makeRecord(
            environment: environment,
            fingerprint: fingerprint,
            hardware: hardware,
            sessionError: String(describing: error)
        )
        try write(record, to: environment.outputURL)
        throw error
    }
}

private func runNativeSession(
    environment: NativeValidationEnvironment,
    plan: AudioRoutePlan,
    hardware: NativeRecordingAudioTapHardware,
    engine: ProcessTapVolumeEngine
) async throws {
    var sessionError: Error?
    do {
        let running = await engine.apply(plan: plan, gain: ProcessGainState())
        guard running.state == .running else {
            throw NativeValidationError.session(running)
        }
        try hardware.sampleCallbackCountBeforeObservation()
        try await Task.sleep(for: .seconds(environment.observationSeconds))
        try hardware.sampleCallbackCountAfterObservation()
    } catch {
        sessionError = error
    }

    let stopped = await engine.stop(
        processObjectID: plan.processObjectID,
        generation: plan.generation
    )
    if stopped.state != .idle {
        hardware.recordSessionFailure(stopped)
        sessionError = sessionError ?? NativeValidationError.cleanup
    }
    do {
        _ = try await waitForNativeTeardownRelease(
            maxAttempts: 200,
            sleep: { try await Task.sleep(for: .milliseconds(10)) },
            advance: {
                let failures = await engine.cleanupOrphans()
                hardware.record(failures, seam: "retainedCleanup")
                return failures
            },
            observe: hardware.observeTeardown
        )
    } catch {
        throw NativeValidationError.teardownUnproven(String(describing: error))
    }
    guard hardware.snapshot().rawFailures.isEmpty else {
        throw NativeValidationError.cleanup
    }
    if let sessionError {
        throw sessionError
    }
}

private func makeRecord(
    environment: NativeValidationEnvironment,
    fingerprint: AudioRouteTopologyFingerprint,
    hardware: NativeRecordingAudioTapHardware,
    sessionError: String?
) -> NativeAudioValidationRecord {
    let snapshot = hardware.snapshot()
    let before = snapshot.callbackCountBeforeObservation
    let after = snapshot.callbackCountAfterObservation
    return NativeAudioValidationRecord(
        processObjectID: environment.processObjectID,
        targetUIDs: environment.targetUIDs,
        exactFingerprint: fingerprint,
        tapResources: snapshot.taps,
        tapFormats: snapshot.tapFormats,
        aggregateResource: snapshot.aggregate,
        ioProcResource: snapshot.ioProc,
        topology: snapshot.topology,
        verifiedInputStreamUsage: snapshot.verifiedInputStreamUsage,
        callbackCountBeforeObservation: before,
        callbackCountAfterObservation: after,
        sustainedCallbacks: before != nil && after != nil && before != after,
        teardown: snapshot.teardown,
        microphoneTCCObservation: environment.microphoneTCCObservation,
        rawFailures: snapshot.rawFailures,
        sessionError: sessionError,
        eligibleForPolicyPromotion: false
    )
}

private func write(_ record: NativeAudioValidationRecord, to outputURL: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let output = try NativeValidationOutputPath.validate(outputURL.path)
    try NativeAtomicOutputWriter.write(encoder.encode(record), to: output)
}

final class NativeAudioTopologyTests: XCTestCase {
    @MainActor
    func testNativeAudioTopology() async throws {
        let environment = try requireNativeOptIn()
        let record = try await runNativeValidation(environment)
        let topology = try XCTUnwrap(record.topology)
        XCTAssertTrue(record.sustainedCallbacks)
        XCTAssertTrue(record.rawFailures.isEmpty)
        XCTAssertTrue(topology.hasExactlyOneInput)
        XCTAssertTrue(topology.fullSubdeviceOrderMatchesExpected)
        XCTAssertTrue(topology.activeSubdeviceMembershipMatchesExpected)
        XCTAssertTrue(topology.mainSubdeviceMatchesExpected)
        XCTAssertTrue(topology.isStackedMatchesExpected)
        XCTAssertTrue(topology.subdevices.allSatisfy {
            $0.diagnosticOnlyObjectID != nil
        })
        XCTAssertTrue(topology.subdevices.allSatisfy(\.driftMatchesExpected))
        XCTAssertEqual(topology.tapUUIDs, [topology.subTap.tapUUID])
        XCTAssertTrue(topology.subTap.driftMatchesExpected)
        XCTAssertTrue(try XCTUnwrap(record.teardown).isReleased)
        XCTAssertFalse(record.eligibleForPolicyPromotion)
    }
}
