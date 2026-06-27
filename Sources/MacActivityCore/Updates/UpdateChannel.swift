import Foundation

public enum UpdateChannel: String, CaseIterable, Codable, Sendable {
    case alpha
    case beta
    case release

    public var rank: Int {
        switch self {
        case .release:
            return 3
        case .beta:
            return 2
        case .alpha:
            return 1
        }
    }

    public var visibleChannels: Set<UpdateChannel> {
        switch self {
        case .release:
            return [.release]
        case .beta:
            return [.release, .beta]
        case .alpha:
            return [.release, .beta, .alpha]
        }
    }
}
