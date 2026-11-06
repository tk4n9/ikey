import Foundation

/// What the MacBook Air top-row icons promise, F1 (brightnessDown) through F12 (volumeUp).
public enum TopRowFunction: String, Codable, CaseIterable, Sendable {
    case brightnessDown, brightnessUp, missionControl, spotlight, dictation, doNotDisturb,
         rewind, playPause, fastForward, mute, volumeDown, volumeUp

    /// The function printed on a physical F1...F12 key code, nil for any other code.
    public static func forPhysicalCode(_ code: UInt16) -> TopRowFunction? {
        guard let index = MacKeyCode.fKeys.firstIndex(of: code) else { return nil }
        return allCases[index]
    }

    /// Only brightness and volume auto-repeat, as on the real keyboard.
    public var repeats: Bool {
        switch self {
        case .brightnessDown, .brightnessUp, .volumeDown, .volumeUp: return true
        default: return false
        }
    }
}

/// One way to perform a top-row function on the Mac. Encoded as its `id` string.
public enum TopRowStrategy: Codable, Equatable, Sendable {
    /// NX_KEYTYPE_* system-defined aux key.
    case aux(Int)
    /// A plain key code, optionally carrying SecondaryFn.
    case keyCode(UInt16, secondaryFn: Bool)
    /// A symbolic hot key id (posted as its current chord).
    case hotKey(Int)
    case openApplication(String)
    case none

    /// Stable id: 'aux:<k>', 'key:<code>:<0|1>', 'hot:<id>', 'app:<path>', 'none'.
    public var id: String {
        switch self {
        case .aux(let k): return "aux:\(k)"
        case .keyCode(let code, let fn): return "key:\(code):\(fn ? 1 : 0)"
        case .hotKey(let id): return "hot:\(id)"
        case .openApplication(let path): return "app:\(path)"
        case .none: return "none"
        }
    }

    /// Parses an `id`; nil when malformed.
    public init?(id: String) {
        if id == "none" { self = .none; return }
        if id.hasPrefix("app:") {
            let path = String(id.dropFirst(4))
            guard !path.isEmpty else { return nil }
            self = .openApplication(path)
            return
        }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        switch (parts.first, parts.count) {
        case ("aux", 2):
            guard let k = Int(parts[1]) else { return nil }
            self = .aux(k)
        case ("hot", 2):
            guard let k = Int(parts[1]) else { return nil }
            self = .hotKey(k)
        case ("key", 3):
            guard let code = UInt16(parts[1]), parts[2] == "0" || parts[2] == "1" else { return nil }
            self = .keyCode(code, secondaryFn: parts[2] == "1")
        default:
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let id = try container.decode(String.self)
        guard let strategy = TopRowStrategy(id: id) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown top-row strategy '\(id)'")
        }
        self = strategy
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

/// Default fallback chains, most faithful strategy first.
public enum TopRowDefaults {
    public static func chain(for f: TopRowFunction) -> [TopRowStrategy] {
        switch f {
        case .brightnessDown: return [.aux(3), .keyCode(145, secondaryFn: true), .hotKey(53)]
        case .brightnessUp: return [.aux(2), .keyCode(144, secondaryFn: true), .hotKey(54)]
        case .missionControl:
            return [.keyCode(160, secondaryFn: true), .hotKey(32), .openApplication("/System/Applications/Mission Control.app")]
        case .spotlight: return [.keyCode(129, secondaryFn: false), .hotKey(64)]
        case .dictation: return [.keyCode(176, secondaryFn: false), .none]
        case .doNotDisturb: return [.keyCode(178, secondaryFn: false), .none]
        case .rewind: return [.aux(20), .aux(18)]
        case .playPause: return [.aux(16)]
        case .fastForward: return [.aux(19), .aux(17)]
        case .mute: return [.aux(7)]
        case .volumeDown: return [.aux(1)]
        case .volumeUp: return [.aux(0)]
        }
    }
}
