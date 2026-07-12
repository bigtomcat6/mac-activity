import CoreAudio
import Foundation
import XCTest

final class NativeValidationConfigurationTests: XCTestCase {
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
}
