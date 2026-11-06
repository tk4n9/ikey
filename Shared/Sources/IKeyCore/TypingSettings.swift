import Foundation

/// Which keys a finger may rest on without typing. Rest-capable keys (and, in rest modes, every
/// modifier) type only as a short tap, committed at lift; a longer touch is a rest.
public enum RestingFingers: String, Codable, CaseIterable, Sendable {
    case off, homeRow, allTypingKeys
}

/// Typing-feel parameters for `KeyCommitPipeline`. Times are seconds.
///
/// Rest-mode policy (plan amendments, section F): a rest-capable key, Space, a modifier or a
/// tap-only code types only as a TAP, a contact lifted within `tapMax` and `restMaxTravelMM`. A
/// longer or sliding contact is a REST and posts nothing, ever. Modifiers are lazy: they post only
/// right before a key that commits while they are held, for pointer output
/// (`KeyCommitPipeline.commitHeldModifiers(at:)`), or as down+up for a lone tap.
public struct TypingSettings: Codable, Equatable, Sendable {
    public var resting: RestingFingers
    /// Legacy (ignored by `KeyCommitPipeline` since the tap policy): the old rest threshold for
    /// home-row letters. Kept so stored settings and existing call sites still work; `tapMax` is
    /// the one tap boundary now.
    public var restThreshold: Double
    /// Legacy (ignored): the old rest threshold for Space. `tapMax` applies to Space too.
    public var spaceRestThreshold: Double
    /// A tap that slides farther than this (largest distance from its landing point) is a rest.
    /// Applies to rest-capable keys, Space, modifiers and tap-only codes.
    public var restMaxTravelMM: Double
    /// Opt-in (default off). On: a home-row letter (not Space, not a modifier) held alone past
    /// `tapMax`, with no other contact on the deck at any moment since it landed and no foreign
    /// contact, presses at that deadline (hold-to-repeat, the accent popup) and releases at lift.
    /// Off: a rest-capable contact held longer than `tapMax` never types.
    public var isolatedHold: Bool
    /// Placement burst: `burstMinContacts` uncommitted contacts, `burstMinRestCapable` of them
    /// on rest-capable keys, landing within `burstWindow`; or `burstMinKeys` uncommitted key
    /// contacts (any keys, not modifiers) landing within `burstWindow`: a hand put down off the
    /// home row (no tactile bumps on glass). Fast rollover never has that many keys landing that
    /// close together and all still undecided.
    public var burstWindow: Double
    public var burstMinContacts: Int
    public var burstMinRestCapable: Int
    public var burstMinKeys: Int
    /// A modifier landing up to this long after a key still applies to it.
    public var chordTolerance: Double
    /// Legacy (ignored): rest modes never post a held modifier from time alone, and resting
    /// `.off` posts it after the confirmation delay. Kept for stored settings.
    public var modifierReveal: Double
    /// Legacy (ignored): the old lone-modifier tap limit. Modifiers use `tapMax`.
    public var loneModifierTapMax: Double
    /// A held modifier that has never been posted or used rests silently (never chords) after
    /// this long while at least `staleRestingContacts` other contacts rest: a thumb lying among
    /// resting hands. A posted modifier stays down until its contact lifts.
    public var staleModifier: Double
    public var staleRestingContacts: Int
    /// Legacy (ignored): rest modes never reveal held modifiers (the lazy-modifier policy).
    public var revealHeldModifiers: Bool
    /// Codes the Mac remaps to a non-modifier, e.g. left Command (55) when the Mac maps it to
    /// Caps Lock. They never chord and are never committed for the pointer. In rest modes they type
    /// down+up at lift for a tap (within `tapMax` and the travel limit) and nothing for a longer
    /// touch. A tap that overlaps a placement burst (touched in it, held when it starts, or lifted
    /// while a hand is landing) types only if a key of the burst types (a roll), not if they all
    /// rest (a settling thumb's bounce), unless it led the burst while typing was in flow and the
    /// thumb did not settle right after it (the switch tapped while the typing hand returns home).
    /// A tap of at most 50 ms waits 50 ms and posts nothing when the thumb then lands on it again
    /// or on Space, Command or Option and stays (a graze on its way to rest); when that contact is
    /// itself a tap (a typed Space, a quick second switch) both type.
    /// With resting off: down after the confirmation delay and up at lift.
    public var tapOnlyCodes: Set<UInt16>
    /// The one tap boundary (rest modes): a rest-capable key, Space, modifier, tap-only code, or a
    /// non-home key turned lift-committed by a placement burst types only when lifted sooner than
    /// this after landing. Used clamped to 0.15...0.35.
    public var tapMax: Double

    public init() {
        self.init(resting: .homeRow)
    }

    public init(resting: RestingFingers = .homeRow, restThreshold: Double = 0.25,
                spaceRestThreshold: Double = 0.30, restMaxTravelMM: Double = 4.0,
                isolatedHold: Bool = false, burstWindow: Double = 0.12, burstMinContacts: Int = 3,
                burstMinRestCapable: Int = 3, burstMinKeys: Int = 4, chordTolerance: Double = 0.030,
                modifierReveal: Double = 0.30, loneModifierTapMax: Double = 0.25,
                staleModifier: Double = 2.0, staleRestingContacts: Int = 3,
                revealHeldModifiers: Bool = false, tapOnlyCodes: Set<UInt16> = [],
                tapMax: Double = 0.30) {
        self.resting = resting
        self.restThreshold = restThreshold
        self.spaceRestThreshold = spaceRestThreshold
        self.restMaxTravelMM = restMaxTravelMM
        self.isolatedHold = isolatedHold
        self.burstWindow = burstWindow
        self.burstMinContacts = burstMinContacts
        self.burstMinRestCapable = burstMinRestCapable
        self.burstMinKeys = burstMinKeys
        self.chordTolerance = chordTolerance
        self.modifierReveal = modifierReveal
        self.loneModifierTapMax = loneModifierTapMax
        self.staleModifier = staleModifier
        self.staleRestingContacts = staleRestingContacts
        self.revealHeldModifiers = revealHeldModifiers
        self.tapOnlyCodes = tapOnlyCodes
        self.tapMax = tapMax
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
        burstMinKeys = value(.burstMinKeys, d.burstMinKeys)
        chordTolerance = value(.chordTolerance, d.chordTolerance)
        modifierReveal = value(.modifierReveal, d.modifierReveal)
        loneModifierTapMax = value(.loneModifierTapMax, d.loneModifierTapMax)
        staleModifier = value(.staleModifier, d.staleModifier)
        staleRestingContacts = value(.staleRestingContacts, d.staleRestingContacts)
        revealHeldModifiers = value(.revealHeldModifiers, d.revealHeldModifiers)
        tapOnlyCodes = value(.tapOnlyCodes, d.tapOnlyCodes)
        tapMax = value(.tapMax, d.tapMax)
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
