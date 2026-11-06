import Foundation

/// Where a key remapping on the Mac comes from.
public enum KeyRemapSource: String, Codable, Sendable {
    /// `hidutil property --set '{"UserKeyMapping": ...}'` (read back with `--get UserKeyMapping`).
    case hidutil
    /// System Settings > Keyboard > Modifier Keys (`com.apple.keyboard.modifiermapping.*`).
    case modifierKeys
    /// Karabiner-Elements `simple_modifications` in `karabiner.json`.
    case karabiner
    /// Pairs the user entered in iKey.
    case manual
}

/// The user's Mac key remapping, mirrored by iKey because posted CGEvents bypass every remapping
/// layer (hidutil UserKeyMapping, Modifier Keys, Karabiner). Keys and values are macOS virtual
/// keycodes; a value of `noAction` means the key is disabled and must be dropped.
public struct KeyRemap: Codable, Equatable, Sendable {
    /// Target meaning "No Action": the key produces nothing (HID usage 0x700000000, Karabiner `vk_none`).
    public static let noAction: UInt16 = 0xFFFF

    /// Source keycode → target keycode (or `noAction`). Identity pairs are never stored by `merged`.
    public var map: [UInt16: UInt16]
    /// The sources that have an effect on `map`, in merge order: a source is listed when it supplied
    /// the final value of at least one key, either a remap or an identity pair that cancels an earlier
    /// source's remap. A source whose pairs were all overridden, or that only had no-op identity pairs,
    /// is not listed.
    public var sources: [KeyRemapSource]

    public init(map: [UInt16: UInt16] = [:], sources: [KeyRemapSource] = []) {
        self.map = map
        self.sources = sources
    }

    /// The keycode to post for physical `code`: the mapped code, `noAction`, or `code` itself.
    public func apply(_ code: UInt16) -> UInt16 { map[code] ?? code }

    /// The deck modifier keys that this remap turns into something other than a modifier, e.g. left
    /// Command mapped to Caps Lock (the user's input-source switch) or to Escape, or disabled
    /// (`noAction`). The iPad types them as taps only (TypingSettings.tapOnlyCodes): they never
    /// chord, rest into a press or act as pointer modifiers, matching what the Mac does with them.
    /// Only `KeyCommitPipeline.modifierCodes` sources are considered; a modifier mapped to another
    /// modifier (e.g. Option ↔ Command) and non-modifier sources (e.g. Caps Lock → Escape) give nothing.
    public static func tapOnlyPadCodes(for remap: [UInt16: UInt16]) -> Set<UInt16> {
        Set(remap.compactMap { source, target in
            KeyCommitPipeline.modifierCodes.contains(source) && !KeyCommitPipeline.modifierCodes.contains(target)
                ? source : nil
        })
    }

    /// `tapOnlyPadCodes(for: map)`.
    public var tapOnlyPadCodes: Set<UInt16> { Self.tapOnlyPadCodes(for: map) }

    /// Combines the sources last-wins per source key, in the order hidutil, Modifier Keys,
    /// Karabiner, manual. macOS applies these layers to the hardware event stream only; for posted
    /// events nothing chains them, so iKey does not map a later source's input through an earlier
    /// source's output. A later identity pair (e.g. manual 55 → 55) cancels an earlier remap.
    /// When two sources give a key the same value, the later one is credited in `sources`.
    public static func merged(hidutil: [UInt16: UInt16], modifierKeys: [UInt16: UInt16],
                              karabiner: [UInt16: UInt16], manual: [UInt16: UInt16]?) -> KeyRemap {
        var map: [UInt16: UInt16] = [:]
        var winner: [UInt16: KeyRemapSource] = [:]
        var remappedEarlier: Set<UInt16> = []
        let ordered: [(KeyRemapSource, [UInt16: UInt16])] = [
            (.hidutil, hidutil), (.modifierKeys, modifierKeys), (.karabiner, karabiner), (.manual, manual ?? [:])
        ]
        for (source, pairs) in ordered {
            for (key, value) in pairs {
                if let previous = map[key], previous != key { remappedEarlier.insert(key) }
                map[key] = value
                winner[key] = source
            }
        }
        var effective: Set<KeyRemapSource> = []
        for (key, value) in map where value != key || remappedEarlier.contains(key) {
            if let source = winner[key] { effective.insert(source) }
        }
        return KeyRemap(map: map.filter { $0.key != $0.value },
                        sources: ordered.map { $0.0 }.filter { effective.contains($0) })
    }

    // MARK: - HID usage ↔ keycode

    /// Mac virtual keycode for a HID usage: a full usage (`page << 32 | usage`, e.g. 0x7000000E3 for
    /// left GUI) or a bare keyboard-page usage ID (≤ 0xFFFF, e.g. 0xE3). fn is the Apple vendor
    /// top-case usage 0xFF00000003 (0xFF0100000003 is accepted too). Unknown usages give nil.
    public static func keyCode(forHIDUsage usage: UInt64) -> UInt16? {
        Table.codeByUsage[fullUsage(usage)]
    }

    /// The full HID usage for a Mac virtual keycode, or nil when the keycode has no keyboard usage.
    public static func hidUsage(forKeyCode code: UInt16) -> UInt64? {
        Table.usageByCode[code]
    }

    /// Mac virtual keycode for a Karabiner-Elements `key_code` name (`left_command`, `caps_lock`,
    /// `escape`, legacy `left_gui` ...). `vk_none` gives `noAction`; unknown names give nil.
    public static func keyCode(forKarabinerName name: String) -> UInt16? {
        if name == "vk_none" { return noAction }
        return Table.codeByKarabinerName[name]
    }

    // MARK: - hidutil

    /// Parses the output of `hidutil property --get UserKeyMapping`: the NSArray description
    /// `({HIDKeyboardModifierMappingDst = 30064771113; HIDKeyboardModifierMappingSrc = 30064771299;})`,
    /// also `(null)`, `()`, hex numbers and the JSON-like `--set` form. Unknown usages are skipped.
    public static func parseHidutil(_ text: String) -> [UInt16: UInt16] {
        var result: [UInt16: UInt16] = [:]
        for block in text.split(separator: "{", omittingEmptySubsequences: false).dropFirst() {
            guard let body = block.split(separator: "}", omittingEmptySubsequences: false).first else { continue }
            var fields: [String: UInt64] = [:]
            for item in body.split(whereSeparator: { $0 == ";" || $0 == "," || $0.isNewline }) {
                guard let sep = item.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
                let key = trimmed(item[..<sep])
                if let value = number(from: trimmed(item[item.index(after: sep)...])) { fields[key] = value }
            }
            if let src = fields[srcKey], let dst = fields[dstKey] { insert(src: src, dst: dst, into: &result) }
        }
        return result
    }

    // MARK: - Modifier Keys preferences

    /// Parses Modifier Keys preference data: a property list holding either one mapping array or a
    /// ByHost global-preferences dictionary. Modifier Keys settings are stored per keyboard, under
    /// `com.apple.keyboard.modifiermapping.<vendorID>-<productID>-<n>`, and only for keyboards the
    /// user has configured. iKey emulates only the built-in keyboard, so an external keyboard's
    /// settings are NEVER used, whatever the data holds:
    /// - `keyboard` names the built-in keyboard. Callers pass the built-in IOHIDDevice's decimal
    ///   `"<vendorID>-<productID>"`, which matches `<vendorID>-<productID>-*` (Intel-style storage);
    ///   a full `"<vendorID>-<productID>-<n>"` or `com.apple.keyboard.modifiermapping.*` key matches
    ///   exactly. Without a match, `0-0-0` (how Apple silicon Macs store the built-in keyboard) is
    ///   used when present, else the result is [:].
    /// - `keyboard == nil` (built-in unknown), and any other form (a vendor ID alone, non-decimal
    ///   parts, "") which is treated as unknown: only `0-0-0` is used; without it the result is [:],
    ///   even when other keyboards are listed, since none of them is known to be the built-in one.
    /// An entry whose value is not a mapping array counts as a configured keyboard with no mappings
    /// (a malformed `0-0-0` gives [:], never another keyboard's pairs).
    /// `keyboard` is ignored when the data is a bare mapping array.
    public static func parseModifierMappings(_ plistData: Data, keyboard: String? = nil) -> [UInt16: UInt16] {
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        else { return [:] }
        if let array = plist as? [Any] { return parseModifierMappings(array.compactMap { $0 as? [String: Any] }) }
        guard let dict = plist as? [String: Any] else { return [:] }
        var perKeyboard: [String: [UInt16: UInt16]] = [:]
        for (key, value) in dict where key.hasPrefix(modifierMappingPrefix) {
            // A malformed value still marks the keyboard as configured, with no usable pairs.
            let entries = (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            perKeyboard[String(key.dropFirst(modifierMappingPrefix.count))] = parseModifierMappings(entries)
        }
        let builtInFallback = perKeyboard[builtInModifierMappingSuffix] ?? [:]
        guard let wanted = builtInKeyboardSuffix(keyboard) else { return builtInFallback }
        if wanted.count == 3 { return perKeyboard[wanted.joined(separator: "-")] ?? builtInFallback }
        let prefix = wanted.joined(separator: "-") + "-"
        if let match = perKeyboard.keys.sorted().first(where: { $0.hasPrefix(prefix) }) {
            return perKeyboard[match] ?? [:]
        }
        return builtInFallback
    }

    /// Parses Modifier Keys mapping entries (`HIDKeyboardModifierMappingSrc`/`Dst` full usages).
    /// A destination of 0x700000000 ("No Action") maps to `noAction`.
    public static func parseModifierMappings(_ entries: [[String: Any]]) -> [UInt16: UInt16] {
        var result: [UInt16: UInt16] = [:]
        for entry in entries {
            guard let src = unsigned(entry[srcKey]), let dst = unsigned(entry[dstKey]) else { continue }
            insert(src: src, dst: dst, into: &result)
        }
        return result
    }

    // MARK: - Karabiner-Elements

    /// Parses `karabiner.json` simple modifications that apply to the built-in keyboard: the chosen
    /// profile's global list, then (overriding it) every `devices[]` entry with
    /// `identifiers.is_built_in_keyboard == true` or without identifiers. The profile is the one
    /// named `profileName` when given (none matching gives [:]), else the `selected` one, else the
    /// first. A built-in device entry with `ignore: true` means Karabiner leaves it alone ([:]).
    /// Only one-to-one `key_code` pairs are mirrored; pointing buttons, consumer keys, modifiers in
    /// `to` and multi-event `to` lists are skipped. The legacy `{"from": "to"}` object form is accepted.
    public static func parseKarabiner(_ json: Data, profileName: String? = nil) -> [UInt16: UInt16] {
        guard let root = try? JSONSerialization.jsonObject(with: json, options: []) as? [String: Any],
              let profiles = (root["profiles"] as? [Any])?.compactMap({ $0 as? [String: Any] }),
              let profile = chooseProfile(profiles, named: profileName)
        else { return [:] }

        var result = karabinerPairs(profile["simple_modifications"])
        for device in (profile["devices"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
            let rawIdentifiers = device["identifiers"]
            let identifiers = rawIdentifiers as? [String: Any]
            let builtIn = flag(identifiers?["is_built_in_keyboard"])
            guard builtIn || rawIdentifiers == nil || identifiers?.isEmpty == true else { continue }
            if builtIn && flag(device["ignore"]) { return [:] }
            result.merge(karabinerPairs(device["simple_modifications"])) { _, later in later }
        }
        return result
    }
}

// MARK: - Private helpers

extension KeyRemap {
    private static let srcKey = "HIDKeyboardModifierMappingSrc"
    private static let dstKey = "HIDKeyboardModifierMappingDst"
    private static let modifierMappingPrefix = "com.apple.keyboard.modifiermapping."
    /// The ByHost key suffix under which Apple silicon Macs usually store the built-in keyboard.
    private static let builtInModifierMappingSuffix = "0-0-0"
    /// Keyboard page usage 0: "No Action" as a mapping destination.
    private static let noActionUsage: UInt64 = 0x7_0000_0000

    /// The decimal parts of a built-in keyboard id ("<vid>-<pid>" or "<vid>-<pid>-<n>", optionally
    /// prefixed with `modifierMappingPrefix`), or nil when the id is absent or malformed.
    private static func builtInKeyboardSuffix(_ keyboard: String?) -> [String]? {
        guard let keyboard else { return nil }
        let wanted = keyboard.hasPrefix(modifierMappingPrefix)
            ? String(keyboard.dropFirst(modifierMappingPrefix.count)) : keyboard
        let parts = wanted.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ part in !part.isEmpty && part.allSatisfy { ("0"..."9").contains($0) } })
        else { return nil }
        return parts
    }

    private static func fullUsage(_ usage: UInt64) -> UInt64 {
        usage <= 0xFFFF ? Table.keyboardPage | usage : usage
    }

    private static func insert(src: UInt64, dst: UInt64, into result: inout [UInt16: UInt16]) {
        guard let from = keyCode(forHIDUsage: src) else { return }
        if fullUsage(dst) == noActionUsage {
            result[from] = noAction
        } else if let to = keyCode(forHIDUsage: dst) {
            result[from] = to
        }
    }

    private static func trimmed<S: StringProtocol>(_ s: S) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
    }

    /// Decimal or `0x` hexadecimal.
    private static func number(from text: String) -> UInt64? {
        let lower = text.lowercased()
        if lower.hasPrefix("0x") { return UInt64(lower.dropFirst(2), radix: 16) }
        return UInt64(lower)
    }

    /// A non-negative integer from a property-list or JSON value (bridged or native).
    private static func unsigned(_ value: Any?) -> UInt64? {
        switch value {
        case let v as UInt64: return v
        case let v as Int: return v >= 0 ? UInt64(v) : nil
        case let v as Int64: return v >= 0 ? UInt64(v) : nil
        case let v as NSNumber: return v.int64Value >= 0 ? v.uint64Value : nil
        case let v as String: return number(from: trimmed(v))
        default: return nil
        }
    }

    private static func flag(_ value: Any?) -> Bool {
        switch value {
        case let v as Bool: return v
        case let v as NSNumber: return v.boolValue
        default: return false
        }
    }

    private static func chooseProfile(_ profiles: [[String: Any]], named name: String?) -> [String: Any]? {
        if let name { return profiles.first { $0["name"] as? String == name } }
        return profiles.first { flag($0["selected"]) } ?? profiles.first
    }

    private static func karabinerPairs(_ value: Any?) -> [UInt16: UInt16] {
        var result: [UInt16: UInt16] = [:]
        if let legacy = value as? [String: Any] {
            for (fromName, toName) in legacy {
                guard let toName = toName as? String, let from = keyCode(forKarabinerName: fromName),
                      from != noAction, let to = keyCode(forKarabinerName: toName) else { continue }
                result[from] = to
            }
            return result
        }
        for item in (value as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
            guard let fromEvent = item["from"] as? [String: Any], let from = karabinerKey(fromEvent),
                  from != noAction else { continue }
            let toEvents: [[String: Any]]
            if let list = item["to"] as? [Any] {
                toEvents = list.compactMap { $0 as? [String: Any] }
                guard toEvents.count == list.count else { continue }
            } else if let single = item["to"] as? [String: Any] {
                toEvents = [single]
            } else { continue }
            guard toEvents.count == 1, let event = toEvents.first, !hasModifiers(event["modifiers"]),
                  let to = karabinerKey(event) else { continue }
            result[from] = to
        }
        return result
    }

    /// The keycode of a Karabiner event that names a keyboard key (`key_code`, or fn via
    /// `apple_vendor_top_case_key_code: keyboard_fn`); nil for buttons, consumer keys and the rest.
    private static func karabinerKey(_ event: [String: Any]) -> UInt16? {
        if let name = event["key_code"] as? String { return keyCode(forKarabinerName: name) }
        if event["apple_vendor_top_case_key_code"] as? String == "keyboard_fn" { return MacKeyCode.fn }
        return nil
    }

    private static func hasModifiers(_ value: Any?) -> Bool {
        switch value {
        case nil: return false
        case let list as [Any]: return !list.isEmpty
        case let name as String: return !name.isEmpty
        case let dict as [String: Any]: return !dict.isEmpty
        default: return true
        }
    }

    /// HID keyboard page (0x07) usages, Mac virtual keycodes and Karabiner names. The first name is
    /// Karabiner's current one; later names are legacy aliases.
    private enum Table {
        static let keyboardPage: UInt64 = 0x7_0000_0000
        static let fnUsage: UInt64 = 0xFF_0000_0003
        static let fnUsageAlt: UInt64 = 0xFF01_0000_0003

        static let rows: [(usage: UInt64, code: UInt16, names: [String])] = {
            var rows: [(UInt64, UInt16, [String])] = []
            let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17,
                                     32, 9, 13, 7, 16, 6]
            for (i, code) in letters.enumerated() {
                rows.append((0x04 + UInt64(i), code, [String(UnicodeScalar(UInt8(97 + i)))]))
            }
            let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29] // 1 ... 9, 0
            for (i, code) in digits.enumerated() { rows.append((0x1E + UInt64(i), code, ["\((i + 1) % 10)"])) }
            let fKeys: [UInt16] = MacKeyCode.fKeys + [105, 107, 113, 106, 64, 79, 80, 90] // F1-F12, F13-F20
            for (i, code) in fKeys.enumerated() {
                rows.append((i < 12 ? 0x3A + UInt64(i) : 0x68 + UInt64(i - 12), code, ["f\(i + 1)"]))
            }
            let keypadDigits: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92, 82] // keypad 1 ... 9, 0
            for (i, code) in keypadDigits.enumerated() {
                rows.append((0x59 + UInt64(i), code, ["keypad_\((i + 1) % 10)"]))
            }
            rows += [
                (0x28, 36, ["return_or_enter"]), (0x29, 53, ["escape"]), (0x2A, 51, ["delete_or_backspace"]),
                (0x2B, 48, ["tab"]), (0x2C, 49, ["spacebar"]), (0x2D, 27, ["hyphen"]), (0x2E, 24, ["equal_sign"]),
                (0x2F, 33, ["open_bracket"]), (0x30, 30, ["close_bracket"]), (0x31, 42, ["backslash"]),
                (0x33, 41, ["semicolon"]), (0x34, 39, ["quote"]), (0x35, 50, ["grave_accent_and_tilde"]),
                (0x36, 43, ["comma"]), (0x37, 47, ["period"]), (0x38, 44, ["slash"]), (0x39, 57, ["caps_lock"]),
                (0x49, 114, ["insert"]), (0x4A, 115, ["home"]), (0x4B, 116, ["page_up"]),
                (0x4C, 117, ["delete_forward"]), (0x4D, 119, ["end"]), (0x4E, 121, ["page_down"]),
                (0x4F, 124, ["right_arrow"]), (0x50, 123, ["left_arrow"]), (0x51, 125, ["down_arrow"]),
                (0x52, 126, ["up_arrow"]),
                (0x53, 71, ["keypad_num_lock"]), (0x54, 75, ["keypad_slash"]), (0x55, 67, ["keypad_asterisk"]),
                (0x56, 78, ["keypad_hyphen"]), (0x57, 69, ["keypad_plus"]), (0x58, 76, ["keypad_enter"]),
                (0x63, 65, ["keypad_period"]), (0x64, 10, ["non_us_backslash"]), (0x65, 110, ["application"]),
                (0x67, 81, ["keypad_equal_sign"]),
                (0x7F, 74, ["mute"]), (0x80, 72, ["volume_increment", "volume_up"]),
                (0x81, 73, ["volume_decrement", "volume_down"]),
                (0x85, 95, ["keypad_comma"]), (0x87, 94, ["international1"]), (0x89, 93, ["international3"]),
                (0x90, 104, ["lang1", "japanese_kana"]), (0x91, 102, ["lang2", "japanese_eisuu"]),
                (0xE0, 59, ["left_control"]), (0xE1, 56, ["left_shift"]),
                (0xE2, 58, ["left_option", "left_alt"]), (0xE3, 55, ["left_command", "left_gui"]),
                (0xE4, 62, ["right_control"]), (0xE5, 60, ["right_shift"]),
                (0xE6, 61, ["right_option", "right_alt"]), (0xE7, 54, ["right_command", "right_gui"])
            ]
            return rows.map { (keyboardPage | $0.0, $0.1, $0.2) } + [(fnUsage, MacKeyCode.fn, ["fn"])]
        }()

        static let codeByUsage: [UInt64: UInt16] = {
            var table = Dictionary(rows.map { ($0.usage, $0.code) }, uniquingKeysWith: { first, _ in first })
            table[fnUsageAlt] = MacKeyCode.fn
            return table
        }()
        static let usageByCode = Dictionary(rows.map { ($0.code, $0.usage) }, uniquingKeysWith: { first, _ in first })
        static let codeByKarabinerName = Dictionary(rows.flatMap { row in row.names.map { ($0, row.code) } },
                                                    uniquingKeysWith: { first, _ in first })
    }
}
