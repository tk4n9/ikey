import Foundation

public enum DeckMode: String, Codable, Sendable {
    case drawn, photo
}

public enum KeyboardGlowSetting: String, Codable, CaseIterable, Sendable {
    case off, auto, on
}

/// Stored pressed-key look; raw values equal `PressLook`'s.
public enum PressLookSetting: String, Codable, CaseIterable, Sendable {
    case off, subtle, clear
}

/// How the deck is drawn and placed.
public struct DeckAppearanceSettings: Codable, Equatable, Sendable {
    public var mode: DeckMode = .drawn
    /// Follows the Mac's `hw.model` from the welcome unless `modelIsManual`.
    public var model: MacBookAirModel = MacBookAirModel.defaultModel
    public var modelIsManual = false
    /// Nil uses the model's default finish.
    public var finish: DeckFinish? = nil
    /// Manual iPad display preset id; nil auto-detects.
    public var iPadOverrideID: String? = nil
    public var placement = DeckPlacement()
    public var tone: Double = 0
    public var pressLook: PressLookSetting = .subtle
    public var glow: KeyboardGlowSetting = .auto

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case mode, model, modelIsManual, finish, iPadOverrideID, placement, tone, pressLook, glow
    }

    /// Missing or unreadable fields (e.g. a model or finish from a newer build) keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let d = DeckAppearanceSettings()
        mode = value(.mode, d.mode)
        model = value(.model, d.model)
        modelIsManual = value(.modelIsManual, d.modelIsManual)
        finish = (try? c.decodeIfPresent(DeckFinish.self, forKey: .finish)) ?? nil
        iPadOverrideID = (try? c.decodeIfPresent(String.self, forKey: .iPadOverrideID)) ?? nil
        placement = value(.placement, d.placement)
        tone = value(.tone, d.tone)
        pressLook = value(.pressLook, d.pressLook)
        glow = value(.glow, d.glow)
    }

    /// Like the synthesized encoder, but a non-finite tone or placement value is written as its
    /// default: JSON cannot hold NaN or infinity, and one bad value must not make every save fail.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let d = DeckAppearanceSettings()
        try c.encode(mode, forKey: .mode)
        try c.encode(model, forKey: .model)
        try c.encode(modelIsManual, forKey: .modelIsManual)
        try c.encodeIfPresent(finish, forKey: .finish)
        try c.encodeIfPresent(iPadOverrideID, forKey: .iPadOverrideID)
        let p = DeckPlacement()
        try c.encode(DeckPlacement(offsetXmm: finiteOr(placement.offsetXmm, p.offsetXmm),
                                   offsetYmm: finiteOr(placement.offsetYmm, p.offsetYmm),
                                   scale: finiteOr(placement.scale, p.scale)), forKey: .placement)
        try c.encode(finiteOr(tone, d.tone), forKey: .tone)
        try c.encode(pressLook, forKey: .pressLook)
        try c.encode(glow, forKey: .glow)
    }
}

/// `value` when finite, else `fallback`.
private func finiteOr(_ value: Double, _ fallback: Double) -> Double {
    value.isFinite ? value : fallback
}

/// Everything the iPad app persists (except the pairing), stored as JSON under `storageKey`.
public struct PadPreferences: Codable, Equatable, Sendable {
    public var appearance = DeckAppearanceSettings()
    public var typing = TypingSettings()
    /// The iPad's own trackpad settings; see `effectiveTrackpad(mac:)`.
    public var trackpad = TrackpadSettings()
    public var trackpadFollowsMac = true
    public var protection = TouchProtectionSettings()
    public var showTouchIndicators = false
    public var panelTriggerRaw = "touchIDHold"
    public var peerToPeer = PeerToPeerPolicy()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case appearance, typing, trackpad, trackpadFollowsMac, protection, showTouchIndicators,
             panelTriggerRaw, peerToPeer
    }

    /// Missing or unreadable fields keep their defaults, so settings from older or newer builds load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let d = PadPreferences()
        appearance = value(.appearance, d.appearance)
        typing = value(.typing, d.typing)
        trackpad = value(.trackpad, d.trackpad)
        trackpadFollowsMac = value(.trackpadFollowsMac, d.trackpadFollowsMac)
        protection = value(.protection, d.protection)
        showTouchIndicators = value(.showTouchIndicators, d.showTouchIndicators)
        panelTriggerRaw = value(.panelTriggerRaw, d.panelTriggerRaw)
        peerToPeer = value(.peerToPeer, d.peerToPeer)
    }

    /// Like the synthesized encoder, but non-finite typing and trackpad values are written as their
    /// defaults (the appearance does the same for its own), so a stray NaN never makes saving throw.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(Self.finiteTyping(typing), forKey: .typing)
        try c.encode(Self.finiteTrackpad(trackpad), forKey: .trackpad)
        try c.encode(trackpadFollowsMac, forKey: .trackpadFollowsMac)
        try c.encode(protection, forKey: .protection)
        try c.encode(showTouchIndicators, forKey: .showTouchIndicators)
        try c.encode(panelTriggerRaw, forKey: .panelTriggerRaw)
        try c.encode(peerToPeer, forKey: .peerToPeer)
    }

    private static func finiteTyping(_ t: TypingSettings) -> TypingSettings {
        var t = t
        let d = TypingSettings()
        let fields: [WritableKeyPath<TypingSettings, Double>] = [
            \.restThreshold, \.spaceRestThreshold, \.restMaxTravelMM, \.burstWindow, \.chordTolerance,
            \.modifierReveal, \.loneModifierTapMax, \.staleModifier,
        ]
        for field in fields { t[keyPath: field] = finiteOr(t[keyPath: field], d[keyPath: field]) }
        return t
    }

    private static func finiteTrackpad(_ t: TrackpadSettings) -> TrackpadSettings {
        var t = t
        let d = TrackpadSettings()
        let fields: [WritableKeyPath<TrackpadSettings, Double>] = [
            \.dragReleaseDelay, \.doubleClickInterval, \.tapQuiet, \.typingBandWindow, \.topBandMM,
            \.sideBandMM, \.palmHeelCornerMM,
        ]
        for field in fields { t[keyPath: field] = finiteOr(t[keyPath: field], d[keyPath: field]) }
        return t
    }

    public static let storageKey = "iKey.preferences.v2"

    /// Defaults plus the v1 app's settings: the JSON stored under "iKey.touchProtection.v1" and the
    /// Bool under "iKey.showTouchIndicators.v1". Unreadable v1 data is ignored.
    public static func migrated(v1TouchProtection: Data?, v1ShowIndicators: Bool?) -> PadPreferences {
        var preferences = PadPreferences()
        if let data = v1TouchProtection,
           let protection = try? JSONDecoder().decode(TouchProtectionSettings.self, from: data) {
            preferences.protection = protection
        }
        preferences.showTouchIndicators = v1ShowIndicators ?? false
        return preferences
    }

    /// The trackpad settings in force: while following the Mac (and its preferences are known) the
    /// drag style, double-click interval and three-finger gestures come from the Mac.
    public func effectiveTrackpad(mac: MacInputPreferences?) -> TrackpadSettings {
        guard trackpadFollowsMac, let mac else { return trackpad }
        var settings = trackpad
        settings.dragStyle = mac.threeFingerDrag ? .threeFinger : (mac.dragLock ? .tapDragLock : .tapDrag)
        settings.doubleClickInterval = mac.doubleClickInterval
        settings.threeFingerGestures = mac.threeFingerSwipes
        return settings
    }

    /// True when the deck must be re-resolved: model, iPad override, placement or mode changed.
    public func isGeometryChange(from old: PadPreferences) -> Bool {
        appearance.model != old.appearance.model
            || appearance.iPadOverrideID != old.appearance.iPadOverrideID
            || appearance.placement != old.appearance.placement
            || appearance.mode != old.appearance.mode
    }
}
