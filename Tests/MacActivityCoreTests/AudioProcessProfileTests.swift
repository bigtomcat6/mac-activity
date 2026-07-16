import Foundation
import XCTest
@testable import MacActivityCore

final class AudioProcessProfileTests: XCTestCase {
    func testFollowOriginalRouteEncodesOnlyItsKind() throws {
        let data = try JSONEncoder().encode(AudioRouteMode.followOriginal)
        let route = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(route["kind"] as? String, "followOriginal")
        XCTAssertNil(route["targetDeviceUIDs"])
    }

    func testExistingPreferencesWithoutProfilesMigratesToEmptyMap() throws {
        let data = Data(#"{"launchAtLoginEnabled":false,"selectedSummaryMetrics":[]}"#.utf8)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertEqual(decoded.audioProcessProfiles, [:])
    }

    func testMalformedSiblingDoesNotDiscardValidProfile() throws {
        let data = Data(#"""
        {
          "launchAtLoginEnabled": false,
          "selectedSummaryMetrics": [],
          "audioProcessProfiles": {
            "com.example.Valid": {
              "schemaVersion": 1,
              "bundleIdentifier": "com.example.Valid",
              "volume": 0.4,
              "isMuted": false,
              "route": {"kind":"explicit","targetDeviceUIDs":["MissingButStable"]}
            },
            "com.example.Invalid": {"schemaVersion":99}
          }
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertEqual(Array(decoded.audioProcessProfiles.keys), ["com.example.Valid"])
        XCTAssertEqual(
            decoded.audioProcessProfiles["com.example.Valid"]?.route,
            .explicit(targetDeviceUIDs: ["MissingButStable"])
        )
    }

    func testBundleKeyMismatchIsDiscarded() throws {
        let data = Data(#"""
        {
          "launchAtLoginEnabled": false,
          "selectedSummaryMetrics": [],
          "audioProcessProfiles": {
            "com.example.DictionaryKey": {
              "schemaVersion": 1,
              "bundleIdentifier": "com.example.Payload",
              "volume": 0.4,
              "isMuted": false,
              "route": {"kind":"followOriginal"}
            }
          }
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertEqual(decoded.audioProcessProfiles, [:])
    }

    func testUnknownSchemaIsDiscarded() throws {
        let data = Data(#"""
        {
          "launchAtLoginEnabled": false,
          "selectedSummaryMetrics": [],
          "audioProcessProfiles": {
            "com.example.Future": {
              "schemaVersion": 99,
              "bundleIdentifier": "com.example.Future",
              "volume": 0.4,
              "isMuted": false,
              "route": {"kind":"followOriginal"}
            }
          }
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertEqual(decoded.audioProcessProfiles, [:])
    }

    func testEmptyBundleIdentifierIsRejected() {
        let data = Data(#"""
        {
          "schemaVersion": 1,
          "bundleIdentifier": "",
          "volume": 0.4,
          "isMuted": false,
          "route": {"kind":"followOriginal"}
        }
        """#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(AudioProcessProfile.self, from: data))
    }

    func testNonfiniteDecodedVolumeIsRejected() {
        let data = Data(#"""
        {
          "schemaVersion": 1,
          "bundleIdentifier": "com.example.Player",
          "volume": "NaN",
          "isMuted": false,
          "route": {"kind":"followOriginal"}
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )

        XCTAssertThrowsError(try decoder.decode(AudioProcessProfile.self, from: data))
    }

    func testDecodedVolumeOutsideUnitRangeIsRejected() {
        let belowRange = Data(#"""
        {
          "schemaVersion": 1,
          "bundleIdentifier": "com.example.Low",
          "volume": -0.1,
          "isMuted": false,
          "route": {"kind":"followOriginal"}
        }
        """#.utf8)
        let aboveRange = Data(#"""
        {
          "schemaVersion": 1,
          "bundleIdentifier": "com.example.High",
          "volume": 1.1,
          "isMuted": false,
          "route": {"kind":"followOriginal"}
        }
        """#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(AudioProcessProfile.self, from: belowRange))
        XCTAssertThrowsError(try JSONDecoder().decode(AudioProcessProfile.self, from: aboveRange))
    }

    func testPublicInitializerClampsVolumeIntoUnitRange() {
        XCTAssertEqual(AudioProcessProfile(bundleIdentifier: "com.example.Low", volume: -0.1).volume, 0)
        XCTAssertEqual(AudioProcessProfile(bundleIdentifier: "com.example.High", volume: 1.1).volume, 1)
        XCTAssertEqual(AudioProcessProfile(bundleIdentifier: "com.example.NaN", volume: .nan).volume, 1)
    }

    func testEmptyExplicitTargetsAreRejectedWhenDecoding() {
        let data = Data(#"{"kind":"explicit","targetDeviceUIDs":[]}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(AudioRouteMode.self, from: data))
    }

    func testDuplicateExplicitTargetsAreNormalizedInOrderWhenDecoding() throws {
        let data = Data(
            #"{"kind":"explicit","targetDeviceUIDs":["UID-A","","UID-A","UID-B"]}"#.utf8
        )

        let decoded = try JSONDecoder().decode(AudioRouteMode.self, from: data)

        XCTAssertEqual(decoded, .explicit(targetDeviceUIDs: ["UID-A", "UID-B"]))
    }

    func testPublicInitializerNormalizesExplicitTargets() {
        let normalized = AudioProcessProfile(
            bundleIdentifier: "com.example.Player",
            route: .explicit(targetDeviceUIDs: ["UID-A", "", "UID-A", "UID-B"])
        )
        let empty = AudioProcessProfile(
            bundleIdentifier: "com.example.Empty",
            route: .explicit(targetDeviceUIDs: [""])
        )

        XCTAssertEqual(normalized.route, .explicit(targetDeviceUIDs: ["UID-A", "UID-B"]))
        XCTAssertEqual(empty.route, .followOriginal)
    }

    func testMissingDeviceUIDRoundTripsWithoutResolution() throws {
        let expected = AudioProcessProfile(
            bundleIdentifier: "com.example.Player",
            volume: 0.4,
            route: .explicit(targetDeviceUIDs: ["MissingButStable"])
        )

        let data = try JSONEncoder().encode(expected)
        let decoded = try JSONDecoder().decode(AudioProcessProfile.self, from: data)

        XCTAssertEqual(decoded, expected)
    }

    func testEncodedProfileUsesVersionedStableRouteRepresentation() throws {
        let profile = AudioProcessProfile(
            bundleIdentifier: "com.example.Player",
            volume: 0.4,
            route: .explicit(targetDeviceUIDs: ["UID-A"])
        )

        let data = try JSONEncoder().encode(profile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let route = try XCTUnwrap(object["route"] as? [String: Any])

        XCTAssertEqual(object["schemaVersion"] as? Int, AudioProcessProfile.currentSchemaVersion)
        XCTAssertEqual(route["kind"] as? String, "explicit")
        XCTAssertEqual(route["targetDeviceUIDs"] as? [String], ["UID-A"])
    }

    func testStoredDefaultProfileIsDiscarded() throws {
        let data = Data(#"""
        {
          "launchAtLoginEnabled": false,
          "selectedSummaryMetrics": [],
          "audioProcessProfiles": {
            "com.example.Player": {
              "schemaVersion": 1,
              "bundleIdentifier": "com.example.Player",
              "volume": 1,
              "isMuted": false,
              "route": {"kind":"followOriginal"}
            }
          }
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertEqual(decoded.audioProcessProfiles, [:])
    }
}
