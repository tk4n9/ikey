import Foundation

/// A keyboard shortcut from System Settings › Keyboard Shortcuts. `modifierMask`
/// uses CGEventFlags bits (0x40000 control, 0x80000 option, 0x100000 command,
/// 0x20000 shift, 0x800000 fn).
public struct HotKey: Equatable, Sendable {
    public var keyCode: UInt16
    public var modifierMask: UInt64
    public var enabled: Bool

    public init(keyCode: UInt16, modifierMask: UInt64, enabled: Bool = true) {
        self.keyCode = keyCode
        self.modifierMask = modifierMask
        self.enabled = enabled
    }
}

/// The Mac's symbolic hot keys (`AppleSymbolicHotKeys` in com.apple.symbolichotkeys)
/// overlaid on the macOS defaults. Equality compares the resolved table, so a
/// changed shortcut is detected by comparing two readings.
public struct SymbolicHotKeys: Equatable, Sendable {
    /// macOS defaults for the ids iKey uses: 32 Mission Control, 33 application
    /// windows, 36 show desktop, 53/54 brightness, 60/61 input sources, 64 Spotlight,
    /// 70 Look Up, 79/81 move a Space left/right.
    public static let defaults: [Int: HotKey] = [
        32: HotKey(keyCode: 126, modifierMask: 0x840000),
        33: HotKey(keyCode: 125, modifierMask: 0x840000),
        36: HotKey(keyCode: 103, modifierMask: 0x800000),
        53: HotKey(keyCode: 107, modifierMask: 0x800000),
        54: HotKey(keyCode: 113, modifierMask: 0x800000),
        60: HotKey(keyCode: 49, modifierMask: 0x40000),
        61: HotKey(keyCode: 49, modifierMask: 0xC0000),
        64: HotKey(keyCode: 49, modifierMask: 0x100000),
        70: HotKey(keyCode: 2, modifierMask: 0x140000),
        79: HotKey(keyCode: 123, modifierMask: 0x840000),
        81: HotKey(keyCode: 124, modifierMask: 0x840000),
    ]

    /// Key code macOS stores for a shortcut that has no key assigned.
    private static let unassignedKeyCode = 65535

    private var table: [Int: HotKey]

    /// Entries present in `plist` replace the defaults; an entry without a usable
    /// `value` or with key code 65535 leaves that id unassigned (nil).
    public init(plist: [String: Any]?) {
        var table = Self.defaults
        for (key, entry) in plist ?? [:] {
            guard let id = Int(key) else { continue }
            table[id] = Self.resolve(entry)
        }
        self.table = table
    }

    public func hotKey(_ id: Int) -> HotKey? { table[id] }

    /// `{"enabled": Bool/Int, "value": {"parameters": [ascii, keycode, mods], ...}}`
    private static func resolve(_ entry: Any) -> HotKey? {
        guard let dict = entry as? [String: Any],
              let value = dict["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any], parameters.count >= 3,
              let keyCode = integer(parameters[1]), let mods = integer(parameters[2]),
              (0..<unassignedKeyCode).contains(keyCode), mods >= 0 else { return nil }
        let enabled = dict["enabled"].map { integer($0).map { $0 != 0 } ?? false } ?? true
        return HotKey(keyCode: UInt16(keyCode), modifierMask: UInt64(mods), enabled: enabled)
    }

    private static func integer(_ value: Any) -> Int? {
        switch value {
        case let v as Bool: return v ? 1 : 0
        case let v as Int: return v
        case let v as Int64: return Int(exactly: v)
        case let v as NSNumber: return Int(exactly: v.int64Value)
        case let v as Double: return Int(exactly: v)
        default: return nil
        }
    }
}
