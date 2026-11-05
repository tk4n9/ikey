import Foundation

public enum TouchSensitivity: String, Codable, CaseIterable, Identifiable, Sendable {
    case strict, balanced, relaxed
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    var fingerRadius: Double {
        switch self {
        case .strict: return 26
        case .balanced: return 32
        case .relaxed: return 40
        }
    }

    var thumbRadius: Double {
        switch self {
        case .strict: return 65
        case .balanced: return 75
        case .relaxed: return 90
        }
    }
}

/// Heuristics based on contact size and timing, not a hardware palm classifier.
public struct TouchProtectionSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var sensitivity: TouchSensitivity
    public var pauseTrackpadWhileTyping: Bool

    public init(enabled: Bool = true, sensitivity: TouchSensitivity = .balanced,
                pauseTrackpadWhileTyping: Bool = true) {
        self.enabled = enabled
        self.sensitivity = sensitivity
        self.pauseTrackpadWhileTyping = pauseTrackpadWhileTyping
    }
}
