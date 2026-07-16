import CoreAudio
import Dispatch
import Foundation
@testable import MacActivityCore
import XCTest

final class NativeValidationConfigurationTests: XCTestCase {
    @MainActor
    func testExactRuntimePolicyReachesInjectedHardwareInsteadOfAvailabilityRejection() async throws {
        let hardware = NativeRuntimeWiringProbeHardware()
        let request = nativeRuntimeWiringRequest()

        let runtime = try makeNativeValidationRuntime(
            request: request,
            operatingSystemVersion: supportedVersion,
            hardware: hardware,
            leaseAcquirer: NativeRuntimeWiringProbeLeaseAcquirer()
        )
        let snapshot = await runtime.engine.apply(
            plan: runtime.plan,
            gain: ProcessGainState()
        )
        await runtime.engine.shutdown()

        XCTAssertTrue(runtime.policy.permits(runtime.fingerprint))
        XCTAssertTrue(runtime.availability.supportsProcessControls)
        XCTAssertTrue(runtime.planner.permits(request))
        XCTAssertEqual(runtime.plan.topologyFingerprint, runtime.fingerprint)
        XCTAssertEqual(hardware.createTapCallCount, 1)
        XCTAssertNotEqual(snapshot.error, .processTapsUnavailable)
    }

    func testNativeRuntimeDefaultsToCurrentOperatingSystemForLiveConstruction() throws {
        let current = ProcessInfo.processInfo.operatingSystemVersion

        let runtime = try makeNativeValidationRuntime(
            request: nativeRuntimeWiringRequest(),
            hardware: NativeRuntimeWiringProbeHardware(),
            leaseAcquirer: NativeRuntimeWiringProbeLeaseAcquirer()
        )

        XCTAssertEqual(runtime.availability.operatingSystemVersion.majorVersion, current.majorVersion)
        XCTAssertEqual(runtime.availability.operatingSystemVersion.minorVersion, current.minorVersion)
        XCTAssertEqual(runtime.availability.operatingSystemVersion.patchVersion, current.patchVersion)
    }

    func testNativeEngineFinalizerReturnsValueThenShutsDownExactlyOnce() async throws {
        let events = NativeEngineFinalizerEvents()

        let value = try await withNativeEngineShutdown(
            shutdown: { await events.record("shutdown") },
            operation: {
                await events.record("operation")
                return 42
            }
        )

        let recordedEvents = await events.values()
        XCTAssertEqual(value, 42)
        XCTAssertEqual(recordedEvents, ["operation", "shutdown"])
    }

    func testNativeEngineFinalizerRethrowsAfterShuttingDownExactlyOnce() async {
        let events = NativeEngineFinalizerEvents()

        do {
            let _: Int = try await withNativeEngineShutdown(
                shutdown: { await events.record("shutdown") },
                operation: {
                    await events.record("operation")
                    throw ProcessTapEngineError.leaseUnavailable
                }
            )
            XCTFail("Expected lease failure")
        } catch {
            XCTAssertEqual(error as? ProcessTapEngineError, .leaseUnavailable)
        }

        let recordedEvents = await events.values()
        XCTAssertEqual(recordedEvents, ["operation", "shutdown"])
    }

    func testNativeEngineFinalizerShutsDownExactlyOnceOnCancellation() async {
        let events = NativeEngineFinalizerEvents()

        do {
            let _: Int = try await withNativeEngineShutdown(
                shutdown: { await events.record("shutdown") },
                operation: {
                    await events.record("operation")
                    throw CancellationError()
                }
            )
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let recordedEvents = await events.values()
        XCTAssertEqual(recordedEvents, ["operation", "shutdown"])
    }

    private var scratchURL: URL!

    override func setUpWithError() throws {
        scratchURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("MacActivityNativeValidation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratchURL,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: scratchURL)
    }

    func testRelativeOutputFailsBeforeProcessObjectIDConstruction() {
        var constructionCount = 0

        XCTAssertThrowsError(try makeNativeValidationEnvironment(
            environment: environment(outputPath: "relative/result.json"),
            operatingSystemVersion: supportedVersion,
            restrictedRoots: [],
            makeProcessObjectID: { value in
                constructionCount += 1
                return AudioObjectID(value)
            }
        ))
        XCTAssertEqual(constructionCount, 0)
    }

    func testRepositoryDocsAndExampleFixtureOutputsAreRejected() {
        let repo = NativeValidationOutputPath.nestedRepositoryRoot
        let docs = NativeValidationOutputPath.outerDocsRoot
        let fixture = repo.appendingPathComponent(
            "Tools/AudioNativeValidation/Fixtures/validation-matrix.example.json"
        )

        for url in [repo.appendingPathComponent("result.json"),
                    docs.appendingPathComponent("result.json"),
                    fixture] {
            XCTAssertThrowsError(try makeNativeValidationEnvironment(
                environment: environment(outputPath: url.path),
                operatingSystemVersion: supportedVersion,
                restrictedRoots: NativeValidationOutputPath.restrictedRoots
            ), url.path)
        }
    }

    func testTargetAndParentSymlinksAreRejected() throws {
        let realDirectory = scratchURL.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false)
        let parentLink = scratchURL.appendingPathComponent("parent-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: parentLink,
            withDestinationURL: realDirectory
        )
        let realTarget = realDirectory.appendingPathComponent("real.json")
        try Data().write(to: realTarget)
        let targetLink = scratchURL.appendingPathComponent("target-link.json")
        try FileManager.default.createSymbolicLink(
            at: targetLink,
            withDestinationURL: realTarget
        )

        for path in [parentLink.appendingPathComponent("result.json").path, targetLink.path] {
            XCTAssertThrowsError(try NativeValidationOutputPath.validate(
                path,
                restrictedRoots: []
            ), path)
        }
    }

    func testWhitespaceOnlyTCCObservationIsRejectedAndValidObservationIsTrimmed() throws {
        let output = scratchURL.appendingPathComponent("result.json")
        XCTAssertThrowsError(try makeNativeValidationEnvironment(
            environment: environment(
                outputPath: output.path,
                microphoneObservation: " \n\t "
            ),
            operatingSystemVersion: supportedVersion,
            restrictedRoots: []
        ))

        let parsed = try makeNativeValidationEnvironment(
            environment: environment(
                outputPath: "  \(output.path)  ",
                microphoneObservation: "  No prompt appeared.  "
            ),
            operatingSystemVersion: supportedVersion,
            restrictedRoots: []
        )
        XCTAssertEqual(parsed.outputURL, output.standardizedFileURL)
        XCTAssertEqual(parsed.microphoneTCCObservation, "No prompt appeared.")
    }

    func testAtomicWriterDoesNotFollowTargetSymlinkCreatedAfterValidation() throws {
        let outputURL = scratchURL.appendingPathComponent("result.json")
        let output = try NativeValidationOutputPath.validate(
            outputURL.path,
            restrictedRoots: []
        )
        let destination = scratchURL.appendingPathComponent("destination.json")
        try Data("original".utf8).write(to: destination)
        try FileManager.default.createSymbolicLink(
            at: outputURL,
            withDestinationURL: destination
        )

        XCTAssertThrowsError(try NativeAtomicOutputWriter.write(
            Data("replacement".utf8),
            to: output
        ))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
    }

    func testAtomicWriterDoesNotFollowIntermediateParentSwappedAfterValidation() throws {
        let ancestor = scratchURL.appendingPathComponent("ancestor", isDirectory: true)
        let parent = ancestor.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let output = try NativeValidationOutputPath.validate(
            parent.appendingPathComponent("result.json").path,
            restrictedRoots: []
        )
        try FileManager.default.removeItem(at: ancestor)
        let replacementParent = scratchURL
            .appendingPathComponent("replacement", isDirectory: true)
            .appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(
            at: replacementParent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: ancestor,
            withDestinationURL: replacementParent.deletingLastPathComponent()
        )

        XCTAssertThrowsError(try NativeAtomicOutputWriter.write(Data("unsafe".utf8), to: output))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: replacementParent.appendingPathComponent("result.json").path
        ))
    }

    func testAtomicWriterReplacesRegularFileAtValidatedPath() throws {
        let outputURL = scratchURL.appendingPathComponent("result.json")
        try Data("old".utf8).write(to: outputURL)
        let output = try NativeValidationOutputPath.validate(
            outputURL.path,
            restrictedRoots: []
        )

        try NativeAtomicOutputWriter.write(Data("new".utf8), to: output)

        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "new")
    }

    private var supportedVersion: OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)
    }

    private func environment(
        outputPath: String,
        microphoneObservation: String = "No prompt appeared."
    ) -> [String: String] {
        [
            "MACACTIVITY_AUDIO_PROCESS_OBJECT_ID": "42",
            "MACACTIVITY_AUDIO_TARGET_UIDS": "output",
            "MACACTIVITY_AUDIO_VALIDATION_OUTPUT": outputPath,
            "MACACTIVITY_AUDIO_MIC_TCC_OBSERVATION": microphoneObservation,
            "MACACTIVITY_AUDIO_VALIDATION_SECONDS": "1",
        ]
    }

    private func nativeRuntimeWiringRequest() -> AudioRouteRequest {
        let format = ProcessTapAudioFormat(
            sampleRate: 48_000,
            channelCount: 2,
            formatID: kAudioFormatLinearPCM,
            formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            bitsPerChannel: 32,
            interleaving: .interleaved
        )
        let device = AudioRouteDevice(
            objectID: 100,
            uid: "probe-output",
            name: "Probe Output",
            isAlive: true,
            isAggregate: false,
            aggregateSubdeviceUIDs: [],
            outputStreams: [AudioRouteStream(
                streamObjectID: 101,
                streamIndex: 0,
                format: format
            )],
            clockDomain: 1,
            transportType: kAudioDeviceTransportTypeUSB,
            modelUID: "probe-model",
            driverIdentity: AudioRouteDriverIdentity(
                plugInBundleID: "probe-driver",
                availableVersion: "1"
            )
        )
        return AudioRouteRequest(
            processObjectID: 42,
            generation: 1,
            sourceDeviceUIDs: [device.uid],
            systemDefaultOutputDeviceUID: nil,
            mode: .followOriginal,
            devices: [device]
        )
    }
}

private actor NativeEngineFinalizerEvents {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func values() -> [String] {
        events
    }
}

private final class NativeRuntimeWiringProbeLease: AudioProcessOwnershipLease, @unchecked Sendable {}

private struct NativeRuntimeWiringProbeLeaseAcquirer: AudioProcessOwnershipLeaseAcquiring {
    func acquire() throws -> any AudioProcessOwnershipLease {
        NativeRuntimeWiringProbeLease()
    }
}

private final class NativeRuntimeWiringProbeHardware: AudioTapHardware, @unchecked Sendable {
    private let lock = NSLock()
    private var createTapCallCountStorage = 0

    var createTapCallCount: Int {
        lock.withLock { createTapCallCountStorage }
    }

    func createTap(
        processObjectID: AudioObjectID,
        source: AudioTapSource,
        uuid: UUID
    ) throws -> AudioTapResource {
        lock.withLock { createTapCallCountStorage += 1 }
        throw NativeRuntimeWiringProbeError.reachedHardware
    }

    func readTapFormat(_ tap: AudioTapResource) throws -> ProcessTapAudioFormat {
        fatalError("unreachable")
    }

    func readMuteState(for tap: AudioTapResource) throws -> AudioTapMuteState {
        fatalError("unreachable")
    }

    func createAggregate(
        plan: AudioRoutePlan,
        taps: [AudioTapResource]
    ) throws -> AudioAggregateResource {
        fatalError("unreachable")
    }

    func waitForStableTopology(
        _ aggregate: AudioAggregateResource,
        deadline: DispatchTime,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> AudioAggregateTopologySnapshot {
        fatalError("unreachable")
    }

    func createIOProc(
        aggregate: AudioAggregateResource,
        context: ProcessTapDSPContext
    ) throws -> AudioIOProcResource {
        fatalError("unreachable")
    }

    func start(_ ioProc: AudioIOProcResource) throws {
        fatalError("unreachable")
    }

    func configureInputStreamUsage(
        _ usage: [UInt32],
        for ioProc: AudioIOProcResource
    ) throws -> [UInt32] {
        fatalError("unreachable")
    }

    func setMuteState(
        _ state: AudioTapMuteState,
        for tap: AudioTapResource
    ) throws {
        fatalError("unreachable")
    }

    func restoreOriginalAudio(for tap: AudioTapResource) -> OSStatus {
        fatalError("unreachable")
    }

    func stop(_ ioProc: AudioIOProcResource) -> OSStatus {
        fatalError("unreachable")
    }

    func destroyIOProc(_ ioProc: AudioIOProcResource) -> OSStatus {
        fatalError("unreachable")
    }

    func destroyAggregate(_ aggregate: AudioAggregateResource) -> OSStatus {
        fatalError("unreachable")
    }

    func aggregateIdentityIsPresent(_ aggregate: AudioAggregateResource) throws -> Bool {
        false
    }

    func destroyTap(_ tap: AudioTapResource) -> OSStatus {
        fatalError("unreachable")
    }

}

private enum NativeRuntimeWiringProbeError: Error {
    case reachedHardware
}
