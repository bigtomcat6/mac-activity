import Foundation

public struct AudioProcessProfile: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let bundleIdentifier: String
    public var volume: Double
    public var isMuted: Bool
    public var route: AudioRouteMode

    public init(
        bundleIdentifier: String,
        volume: Double = 1,
        isMuted: Bool = false,
        route: AudioRouteMode = .followOriginal
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.bundleIdentifier = bundleIdentifier
        self.volume = min(1, max(0, volume.isFinite ? volume : 1))
        self.isMuted = isMuted
        switch route {
        case .followOriginal:
            self.route = .followOriginal
        case .explicit(let targetDeviceUIDs):
            let normalized = targetDeviceUIDs.reduce(into: [String]()) { result, uid in
                if uid.isEmpty == false && result.contains(uid) == false {
                    result.append(uid)
                }
            }
            self.route = normalized.isEmpty
                ? .followOriginal
                : .explicit(targetDeviceUIDs: normalized)
        }
    }

    public var isDefault: Bool {
        volume == 1 && isMuted == false && route == .followOriginal
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case bundleIdentifier
        case volume
        case isMuted
        case route
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        let volume = try container.decode(Double.self, forKey: .volume)
        let isMuted = try container.decode(Bool.self, forKey: .isMuted)
        let route = try container.decode(AudioRouteMode.self, forKey: .route)

        guard schemaVersion == Self.currentSchemaVersion,
              bundleIdentifier.isEmpty == false,
              volume.isFinite,
              (0...1).contains(volume) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid audio process profile"
                )
            )
        }

        self.schemaVersion = schemaVersion
        self.bundleIdentifier = bundleIdentifier
        self.volume = volume
        self.isMuted = isMuted
        self.route = route
    }
}
