import Foundation

/// Which keys a finger may rest on without typing. Rest-capable keys commit on
/// lift instead of after the short confirmation delay.
public enum RestingFingers: String, Codable, CaseIterable, Sendable {
    case off, homeRow, allTypingKeys
}

/// Typing-feel parameters for `KeyCommitPipeline`. Times are seconds.
public struct TypingSettings: Codable, Equatable, Sendable {
    public var resting: RestingFingers
    /// A rest-capable key held longer than this rests instead of typing (used clamped to 0.15...0.35).
    public var restThreshold: Double
    /// Rest threshold for Space (thumbs rest there longer before a deliberate tap ends).
    public var spaceRestThreshold: Double
    /// A rest-capable contact that slides farther than this rests.
    public var restMaxTravelMM: Double
    /// A rest-capable key held alone (nothing else touching) presses at its threshold. Held
    /// modifiers applying to it do not count as touching, except for Space. When off, such a key
    /// still presses at its threshold while an applicable modifier is held (slow Cmd+S).
    public var isolatedHold: Bool
    /// Placement burst: `burstMinContacts` uncommitted contacts, `burstMinRestCapable` of them
    /// on rest-capable keys, landing within `burstWindow`.
    public var burstWindow: Double
    public var burstMinContacts: Int
    public var burstMinRestCapable: Int
    /// A modifier landing up to this long after a key still applies to it.
    public var chordTolerance: Double
    /// A held modifier is posted this long after landing (rest modes).
    public var modifierReveal: Double
    /// A modifier tapped alone for at most this long posts down+up at lift.
    public var loneModifierTapMax: Double
    /// An unused revealed modifier is released after this long while
    /// `staleRestingContacts` other contacts rest.
    public var staleModifier: Double
    public var staleRestingContacts: Int

    public init() {
        self.init(resting: .homeRow)
    }

    public init(resting: RestingFingers = .homeRow, restThreshold: Double = 0.25,
                spaceRestThreshold: Double = 0.30, restMaxTravelMM: Double = 4.0,
                isolatedHold: Bool = true, burstWindow: Double = 0.12, burstMinContacts: Int = 3,
                burstMinRestCapable: Int = 3, chordTolerance: Double = 0.030,
                modifierReveal: Double = 0.30, loneModifierTapMax: Double = 0.25,
                staleModifier: Double = 2.0, staleRestingContacts: Int = 3) {
        self.resting = resting
        self.restThreshold = restThreshold
        self.spaceRestThreshold = spaceRestThreshold
        self.restMaxTravelMM = restMaxTravelMM
        self.isolatedHold = isolatedHold
        self.burstWindow = burstWindow
        self.burstMinContacts = burstMinContacts
        self.burstMinRestCapable = burstMinRestCapable
        self.chordTolerance = chordTolerance
        self.modifierReveal = modifierReveal
        self.loneModifierTapMax = loneModifierTapMax
        self.staleModifier = staleModifier
        self.staleRestingContacts = staleRestingContacts
    }

    /// Missing or unreadable fields keep their defaults, so stored settings survive upgrades.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let d = TypingSettings()
        resting = value(.resting, d.resting)
        restThreshold = value(.restThreshold, d.restThreshold)
        spaceRestThreshold = value(.spaceRestThreshold, d.spaceRestThreshold)
        restMaxTravelMM = value(.restMaxTravelMM, d.restMaxTravelMM)
        isolatedHold = value(.isolatedHold, d.isolatedHold)
        burstWindow = value(.burstWindow, d.burstWindow)
        burstMinContacts = value(.burstMinContacts, d.burstMinContacts)
        burstMinRestCapable = value(.burstMinRestCapable, d.burstMinRestCapable)
        chordTolerance = value(.chordTolerance, d.chordTolerance)
        modifierReveal = value(.modifierReveal, d.modifierReveal)
        loneModifierTapMax = value(.loneModifierTapMax, d.loneModifierTapMax)
        staleModifier = value(.staleModifier, d.staleModifier)
        staleRestingContacts = value(.staleRestingContacts, d.staleRestingContacts)
    }

    /// A S D F J K L ; and Space.
    public static let homeRowCodes: Set<UInt16> = [0, 1, 2, 3, 38, 40, 37, 41, 49]
    /// Letters, digits, punctuation, Space and grave (no Return, Tab, Delete, Escape or modifiers).
    public static let typingKeyCodes: Set<UInt16> =
        Set(UInt16(0)...UInt16(35)).union(UInt16(37)...UInt16(47)).union([49, 50])

    public func isRestCapable(_ code: UInt16) -> Bool {
        switch resting {
        case .off: return false
        case .homeRow: return Self.homeRowCodes.contains(code)
        case .allTypingKeys: return Self.typingKeyCodes.contains(code)
        }
    }
}
