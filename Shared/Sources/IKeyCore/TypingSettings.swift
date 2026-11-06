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
    /// modifiers applying to it do not count as touching. When off, such a key still presses at
    /// its threshold while an applicable modifier is held (slow Cmd+S). Space never presses this
    /// way in rest modes: a thumb settling on Space before the hands must not repeat spaces.
    /// Trade-off kept on purpose: a lone finger resting on a home-row letter (nothing else
    /// touching) still presses at its threshold, which gives hold-to-repeat and the accent popup.
    public var isolatedHold: Bool
    /// Placement burst: `burstMinContacts` uncommitted contacts, `burstMinRestCapable` of them
    /// on rest-capable keys, landing within `burstWindow`.
    public var burstWindow: Double
    public var burstMinContacts: Int
    public var burstMinRestCapable: Int
    /// A modifier landing up to this long after a key still applies to it.
    public var chordTolerance: Double
    /// With `revealHeldModifiers`, a held modifier is posted this long after landing (rest
    /// modes). It also bounds a lone tap: see `loneModifierTapMax`.
    public var modifierReveal: Double
    /// A modifier tapped alone (never posted, no partner key) posts down+up at lift when held at
    /// most max(this, `modifierReveal`); a longer lone press is a resting thumb and posts nothing.
    public var loneModifierTapMax: Double
    /// A held modifier rests after this long while `staleRestingContacts` other contacts rest:
    /// counted from landing when unused (one never posted rests silently, one posted by reveal is
    /// released), and from its last chord (or later ordinary key activity) once a key committed
    /// with it, when it is released. Pointer use exempts it.
    public var staleModifier: Double
    public var staleRestingContacts: Int
    /// Rest modes only. Off (default): a held modifier is never posted from time alone, only
    /// before a key that commits with it, before pointer output (`flushModifiersForPointer`) or
    /// as a lone tap. On: it is also posted `modifierReveal` after landing (resting thumbs on
    /// Command or Shift then hold the modifier down until the stale rule or lift).
    public var revealHeldModifiers: Bool
    /// Codes the Mac remaps to a non-modifier, e.g. left Command (55) when the Mac maps it to
    /// Caps Lock. They never chord, are never revealed, flushed or suspect, and are typed like an
    /// ordinary key: in rest modes down+up at lift for a tap up to max(`loneModifierTapMax`,
    /// `modifierReveal`) and nothing for a longer touch, or for any touch made during a placement
    /// burst or held when one starts (a settling thumb's bounce); with resting off down after the
    /// confirmation delay and up at lift.
    public var tapOnlyCodes: Set<UInt16>

    public init() {
        self.init(resting: .homeRow)
    }

    public init(resting: RestingFingers = .homeRow, restThreshold: Double = 0.25,
                spaceRestThreshold: Double = 0.30, restMaxTravelMM: Double = 4.0,
                isolatedHold: Bool = true, burstWindow: Double = 0.12, burstMinContacts: Int = 3,
                burstMinRestCapable: Int = 3, chordTolerance: Double = 0.030,
                modifierReveal: Double = 0.30, loneModifierTapMax: Double = 0.25,
                staleModifier: Double = 2.0, staleRestingContacts: Int = 3,
                revealHeldModifiers: Bool = false, tapOnlyCodes: Set<UInt16> = []) {
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
        self.revealHeldModifiers = revealHeldModifiers
        self.tapOnlyCodes = tapOnlyCodes
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
        revealHeldModifiers = value(.revealHeldModifiers, d.revealHeldModifiers)
        tapOnlyCodes = value(.tapOnlyCodes, d.tapOnlyCodes)
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
