import Foundation

/// Physical layout of the Mac's built-in keyboard, as reported in the welcome.
public enum KeyboardKind: String, Codable, Sendable { case ansi, iso, jis }

/// The Mac's own keyboard and trackpad settings, mirrored to the iPad and to the injector.
/// Defaults are macOS's factory values.
public struct MacInputPreferences: Codable, Equatable, Sendable {
    /// Seconds before a held key repeats; nil means key repeat is off. Valid 0.1...2.0.
    public var keyRepeatDelay: Double? = 0.5
    /// Seconds between repeats. Valid 0.015...2.0.
    public var keyRepeatInterval: Double = 0.083
    public var naturalScrolling = true
    /// com.apple.trackpad.scaling. Valid 0...3.
    public var trackingIndex: Double = 0.6875
    /// "Use F1, F2, etc. keys as standard function keys".
    public var fnKeysStandard = false
    /// Seconds. Valid 0.1...5.
    public var doubleClickInterval: Double = 0.5
    public var threeFingerDrag = false
    public var dragLock = false
    public var tapToClick = true
    public var threeFingerSwipes = true

    public init() {}

    public init(keyRepeatDelay: Double? = 0.5, keyRepeatInterval: Double = 0.083,
                naturalScrolling: Bool = true, trackingIndex: Double = 0.6875,
                fnKeysStandard: Bool = false, doubleClickInterval: Double = 0.5,
                threeFingerDrag: Bool = false, dragLock: Bool = false, tapToClick: Bool = true,
                threeFingerSwipes: Bool = true) {
        self.keyRepeatDelay = keyRepeatDelay
        self.keyRepeatInterval = keyRepeatInterval
        self.naturalScrolling = naturalScrolling
        self.trackingIndex = trackingIndex
        self.fnKeysStandard = fnKeysStandard
        self.doubleClickInterval = doubleClickInterval
        self.threeFingerDrag = threeFingerDrag
        self.dragLock = dragLock
        self.tapToClick = tapToClick
        self.threeFingerSwipes = threeFingerSwipes
    }

    private enum CodingKeys: String, CodingKey {
        case keyRepeatDelay, keyRepeatInterval, naturalScrolling, trackingIndex, fnKeysStandard
        case doubleClickInterval, threeFingerDrag, dragLock, tapToClick, threeFingerSwipes
    }

    /// Absent keys keep their defaults, so either side may add settings later.
    /// An explicit null keyRepeatDelay means repeat off; an absent one means the default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.keyRepeatDelay) {
            keyRepeatDelay = try c.decodeNil(forKey: .keyRepeatDelay)
                ? nil : try c.decode(Double.self, forKey: .keyRepeatDelay)
        }
        keyRepeatInterval = try c.decodeIfPresent(Double.self, forKey: .keyRepeatInterval) ?? keyRepeatInterval
        naturalScrolling = try c.decodeIfPresent(Bool.self, forKey: .naturalScrolling) ?? naturalScrolling
        trackingIndex = try c.decodeIfPresent(Double.self, forKey: .trackingIndex) ?? trackingIndex
        fnKeysStandard = try c.decodeIfPresent(Bool.self, forKey: .fnKeysStandard) ?? fnKeysStandard
        doubleClickInterval = try c.decodeIfPresent(Double.self, forKey: .doubleClickInterval) ?? doubleClickInterval
        threeFingerDrag = try c.decodeIfPresent(Bool.self, forKey: .threeFingerDrag) ?? threeFingerDrag
        dragLock = try c.decodeIfPresent(Bool.self, forKey: .dragLock) ?? dragLock
        tapToClick = try c.decodeIfPresent(Bool.self, forKey: .tapToClick) ?? tapToClick
        threeFingerSwipes = try c.decodeIfPresent(Bool.self, forKey: .threeFingerSwipes) ?? threeFingerSwipes
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let keyRepeatDelay {
            try c.encode(keyRepeatDelay, forKey: .keyRepeatDelay)
        } else {
            try c.encodeNil(forKey: .keyRepeatDelay)
        }
        try c.encode(keyRepeatInterval, forKey: .keyRepeatInterval)
        try c.encode(naturalScrolling, forKey: .naturalScrolling)
        try c.encode(trackingIndex, forKey: .trackingIndex)
        try c.encode(fnKeysStandard, forKey: .fnKeysStandard)
        try c.encode(doubleClickInterval, forKey: .doubleClickInterval)
        try c.encode(threeFingerDrag, forKey: .threeFingerDrag)
        try c.encode(dragLock, forKey: .dragLock)
        try c.encode(tapToClick, forKey: .tapToClick)
        try c.encode(threeFingerSwipes, forKey: .threeFingerSwipes)
    }

    /// The nearest settings that pass `validate()`. Use it on values read from the Mac's
    /// defaults, which `defaults write` can push outside the ranges System Settings offers
    /// (KeyRepeat 0, InitialKeyRepeat below 7, trackpad scaling -1). A repeat delay above 2 s
    /// means repeat off (nil); a non-finite value takes its default.
    public func clamped() -> MacInputPreferences {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        let defaults = MacInputPreferences()
        var result = self
        if let delay = keyRepeatDelay {
            if !delay.isFinite {
                result.keyRepeatDelay = defaults.keyRepeatDelay
            } else {
                result.keyRepeatDelay = delay > 2.0 ? nil : max(delay, 0.1)
            }
        }
        result.keyRepeatInterval = clamp(keyRepeatInterval, 0.015...2.0, defaults.keyRepeatInterval)
        result.trackingIndex = clamp(trackingIndex, 0.0...3.0, defaults.trackingIndex)
        result.doubleClickInterval = clamp(doubleClickInterval, 0.1...5.0, defaults.doubleClickInterval)
        return result
    }

    /// Throws ProtocolError.invalidEvent for a non-finite or out-of-range value.
    public func validate() throws {
        if let keyRepeatDelay, !(0.1...2.0).contains(keyRepeatDelay) { throw ProtocolError.invalidEvent }
        guard (0.015...2.0).contains(keyRepeatInterval),
              (0.0...3.0).contains(trackingIndex),
              (0.1...5.0).contains(doubleClickInterval) else { throw ProtocolError.invalidEvent }
    }
}
