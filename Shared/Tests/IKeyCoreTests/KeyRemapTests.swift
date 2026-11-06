import Foundation
import XCTest
@testable import IKeyCore

final class KeyRemapTests: XCTestCase {
    // The user's remap: left Command (55) → Caps Lock (57), Caps Lock → Escape (53).
    private let userRemap: [UInt16: UInt16] = [55: 57, 57: 53]

    // MARK: - HID usage table

    func testKnownUsages() {
        XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 0x7_0000_00E3), 55)
        XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 0xE3), 55, "bare usage ID")
        XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 0x7_0000_0039), 57)
        XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 0x29), 53)
        XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 30_064_771_299), 55)
        XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 30_064_771_113), 53)
        let modifiers: [UInt64: UInt16] = [0xE0: 59, 0xE1: 56, 0xE2: 58, 0xE3: 55, 0xE4: 62, 0xE5: 60, 0xE6: 61, 0xE7: 54]
        for (usage, code) in modifiers {
            XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 0x7_0000_0000 | usage), code, "usage \(usage)")
            XCTAssertEqual(KeyRemap.hidUsage(forKeyCode: code), 0x7_0000_0000 | usage)
        }
        XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 0xFF_0000_0003), 63, "fn (Apple top case)")
        XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 0xFF01_0000_0003), 63, "fn (Apple vendor keyboard)")
        XCTAssertEqual(KeyRemap.hidUsage(forKeyCode: 63), 0xFF_0000_0003)
        XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 0x3A), 122, "F1")
        XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 0x45), 111, "F12")
        XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 0x68), 105, "F13")
        XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 0x6F), 90, "F20")
        XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 0x4F), 124)
        XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 0x50), 123)
        XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 0x51), 125)
        XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: 0x52), 126)
    }

    func testUnknownUsages() {
        XCTAssertNil(KeyRemap.keyCode(forHIDUsage: 0))
        XCTAssertNil(KeyRemap.keyCode(forHIDUsage: 0x7_0000_0000), "No Action is not a key")
        XCTAssertNil(KeyRemap.keyCode(forHIDUsage: 0x7_0000_00FF))
        XCTAssertNil(KeyRemap.keyCode(forHIDUsage: 0xC_0000_00E9), "consumer page")
        XCTAssertNil(KeyRemap.keyCode(forHIDUsage: .max))
        XCTAssertNil(KeyRemap.hidUsage(forKeyCode: 0xFFFF))
        XCTAssertNil(KeyRemap.hidUsage(forKeyCode: 52))
    }

    func testRoundTripForEveryDeckKey() {
        for model in MacBookAirModel.allCases {
            for key in model.spec.keys {
                guard let code = key.keyCode else { continue }
                guard let usage = KeyRemap.hidUsage(forKeyCode: code) else {
                    XCTFail("\(model) \(key.id) (\(code)) has no HID usage"); continue
                }
                XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: usage), code, "\(model) \(key.id)")
            }
        }
        // Right Control is not drawn but is a real modifier.
        XCTAssertEqual(KeyRemap.hidUsage(forKeyCode: 62).flatMap(KeyRemap.keyCode(forHIDUsage:)), 62)
    }

    func testTableIsBijective() {
        for usage in UInt64(0)...0xFF {
            guard let code = KeyRemap.keyCode(forHIDUsage: usage) else { continue }
            XCTAssertEqual(KeyRemap.hidUsage(forKeyCode: code), 0x7_0000_0000 | usage, "usage \(usage)")
        }
        for code in UInt16(0)...127 {
            guard let usage = KeyRemap.hidUsage(forKeyCode: code) else { continue }
            XCTAssertEqual(KeyRemap.keyCode(forHIDUsage: usage), code, "code \(code)")
        }
    }

    func testKarabinerNames() {
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "left_command"), 55)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "left_gui"), 55)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "caps_lock"), 57)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "escape"), 53)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "right_option"), 61)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "right_alt"), 61)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "fn"), 63)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "a"), 0)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "z"), 6)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "1"), 18)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "0"), 29)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "f12"), 111)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "keypad_0"), 82)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "lang1"), 104)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "japanese_kana"), 104)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "lang2"), 102)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "japanese_eisuu"), 102)
        XCTAssertEqual(KeyRemap.keyCode(forKarabinerName: "vk_none"), KeyRemap.noAction)
        XCTAssertNil(KeyRemap.keyCode(forKarabinerName: "display_brightness_decrement"))
        XCTAssertNil(KeyRemap.keyCode(forKarabinerName: ""))
        XCTAssertNil(KeyRemap.keyCode(forKarabinerName: "Escape"))
    }

    // MARK: - hidutil

    func testHidutilUserSample() {
        let text = """
        (
                {
                HIDKeyboardModifierMappingDst = 30064771129;
                HIDKeyboardModifierMappingSrc = 30064771299;
            },
                {
                HIDKeyboardModifierMappingDst = 30064771113;
                HIDKeyboardModifierMappingSrc = 30064771129;
            }
        )
        """
        XCTAssertEqual(KeyRemap.parseHidutil(text), userRemap)
    }

    func testHidutilEmptyForms() {
        XCTAssertEqual(KeyRemap.parseHidutil("(null)"), [:])
        XCTAssertEqual(KeyRemap.parseHidutil("(null)\n"), [:])
        XCTAssertEqual(KeyRemap.parseHidutil("()"), [:])
        XCTAssertEqual(KeyRemap.parseHidutil("(\n)\n"), [:])
        XCTAssertEqual(KeyRemap.parseHidutil(""), [:])
    }

    func testHidutilHexAndDecimal() {
        let oneLine = "({HIDKeyboardModifierMappingDst = 30064771113; HIDKeyboardModifierMappingSrc = 30064771299;})"
        XCTAssertEqual(KeyRemap.parseHidutil(oneLine), [55: 53])
        let hex = "({HIDKeyboardModifierMappingDst = 0x700000039; HIDKeyboardModifierMappingSrc = 0x7000000E3;})"
        XCTAssertEqual(KeyRemap.parseHidutil(hex), [55: 57])
        let json = #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x700000029}]}"#
        XCTAssertEqual(KeyRemap.parseHidutil(json), [57: 53])
        let quoted = #"({"HIDKeyboardModifierMappingSrc" = "0X7000000E3"; "HIDKeyboardModifierMappingDst" = "30064771129";})"#
        XCTAssertEqual(KeyRemap.parseHidutil(quoted), [55: 57])
        XCTAssertEqual(KeyRemap.parseHidutil("{HIDKeyboardModifierMappingSrc=0xE3;HIDKeyboardModifierMappingDst=0x39}"),
                       [55: 57], "bare usage IDs, no array")
    }

    func testHidutilNoActionAndUnknowns() {
        let text = """
        ({HIDKeyboardModifierMappingDst = 30064771072; HIDKeyboardModifierMappingSrc = 30064771129;},
         {HIDKeyboardModifierMappingDst = 30064771113; HIDKeyboardModifierMappingSrc = 30064771327;},
         {HIDKeyboardModifierMappingDst = 30064771327; HIDKeyboardModifierMappingSrc = 30064771299;},
         {HIDKeyboardModifierMappingSrc = 30064771300;})
        """
        XCTAssertEqual(KeyRemap.parseHidutil(text), [57: KeyRemap.noAction])
    }

    func testHidutilMalformed() {
        for text in ["garbage", "({", "({HIDKeyboardModifierMappingSrc = ;})", "}{",
                     "({HIDKeyboardModifierMappingSrc = -5; HIDKeyboardModifierMappingDst = 30064771113;})",
                     "({HIDKeyboardModifierMappingSrc = 999999999999999999999999; HIDKeyboardModifierMappingDst = 1;})",
                     "({HIDKeyboardModifierMappingSrc = 0xZZ; HIDKeyboardModifierMappingDst = 0x29;})"] {
            XCTAssertEqual(KeyRemap.parseHidutil(text), [:], text)
        }
    }

    // MARK: - Modifier Keys preferences

    func testModifierEntries() {
        let entries: [[String: Any]] = [
            ["HIDKeyboardModifierMappingSrc": 30_064_771_299, "HIDKeyboardModifierMappingDst": 30_064_771_129],
            ["HIDKeyboardModifierMappingSrc": NSNumber(value: 30_064_771_129 as Int64),
             "HIDKeyboardModifierMappingDst": NSNumber(value: 30_064_771_113 as Int64)],
            ["HIDKeyboardModifierMappingSrc": UInt64(0x7_0000_00E2), "HIDKeyboardModifierMappingDst": 30_064_771_072],
            ["HIDKeyboardModifierMappingSrc": "1095216660483", "HIDKeyboardModifierMappingDst": Int64(0x7_0000_00E0)],
            ["HIDKeyboardModifierMappingSrc": -1, "HIDKeyboardModifierMappingDst": 30_064_771_113],
            ["HIDKeyboardModifierMappingSrc": 30_064_771_300],
            ["HIDKeyboardModifierMappingSrc": [1], "HIDKeyboardModifierMappingDst": 30_064_771_113],
            [:]
        ]
        XCTAssertEqual(KeyRemap.parseModifierMappings(entries),
                       [55: 57, 57: 53, 58: KeyRemap.noAction, 63: 59])
    }

    func testModifierPlistArray() throws {
        let array: [Any] = [
            ["HIDKeyboardModifierMappingSrc": 30_064_771_299, "HIDKeyboardModifierMappingDst": 30_064_771_129],
            ["HIDKeyboardModifierMappingSrc": 30_064_771_129, "HIDKeyboardModifierMappingDst": 30_064_771_113]
        ]
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let data = try PropertyListSerialization.data(fromPropertyList: array, format: format, options: 0)
            XCTAssertEqual(KeyRemap.parseModifierMappings(data), userRemap, "\(format)")
        }
    }

    private func pair(_ src: UInt64, _ dst: UInt64) -> [String: Any] {
        ["HIDKeyboardModifierMappingSrc": 0x7_0000_0000 | src, "HIDKeyboardModifierMappingDst": 0x7_0000_0000 | dst]
    }

    private func byHost(_ keyboards: [String: [[String: Any]]]) throws -> Data {
        var prefs: [String: Any] = ["com.apple.keyboard.fnState": true, "AppleKeyboardUIMode": 2]
        for (suffix, entries) in keyboards { prefs["com.apple.keyboard.modifiermapping." + suffix] = entries }
        return try PropertyListSerialization.data(fromPropertyList: prefs, format: .xml, options: 0)
    }

    func testModifierByHostSingleKeyboard() throws {
        // An identified keyboard is used; an unidentified lone keyboard is never taken for the built-in.
        let data = try byHost(["1452-641-0": [pair(0xE3, 0x39), pair(0x39, 0x29)]])
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1452-641"), userRemap)
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1452-641-0"), userRemap)
        XCTAssertEqual(KeyRemap.parseModifierMappings(data), [:], "lone keyboard of unknown identity")
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "0-0"), [:], "keyboard without settings")
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1452-641-1"), [:], "exact suffix differs")
        // The built-in stored as 0-0-0 is found with or without the built-in's id.
        let builtInOnly = try byHost(["0-0-0": [pair(0xE3, 0x39), pair(0x39, 0x29)]])
        XCTAssertEqual(KeyRemap.parseModifierMappings(builtInOnly), userRemap)
        XCTAssertEqual(KeyRemap.parseModifierMappings(builtInOnly, keyboard: "1452-641"), userRemap, "0-0-0 fallback")
        XCTAssertEqual(KeyRemap.parseModifierMappings(builtInOnly, keyboard: "1452-641-0"), userRemap)
        XCTAssertEqual(try KeyRemap.parseModifierMappings(byHost([:])), [:])
        XCTAssertEqual(try KeyRemap.parseModifierMappings(byHost([:]), keyboard: "1452-641"), [:])
    }

    /// The common setup: built-in keyboard left untouched (no key written), an external PC keyboard
    /// with Option and Command swapped. Its swap must never reach the iPad's keys.
    func testModifierByHostLoneExternalKeyboardIsNotUsed() throws {
        let external = [pair(0xE2, 0xE3), pair(0xE3, 0xE2)]             // ⌥ ↔ ⌘
        let data = try byHost(["1133-50475-0": external])
        XCTAssertEqual(KeyRemap.parseModifierMappings(data), [:])
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1452-641"), [:])
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1133-50475"), [58: 55, 55: 58])

        // A malformed built-in entry means "built-in configured, nothing usable", not "use the other one".
        var prefs: [String: Any] = ["com.apple.keyboard.modifiermapping.0-0-0": "x",
                                    "com.apple.keyboard.modifiermapping.1133-1-0": [pair(0xE2, 0xE3)]]
        var bad = try PropertyListSerialization.data(fromPropertyList: prefs, format: .xml, options: 0)
        XCTAssertEqual(KeyRemap.parseModifierMappings(bad), [:])
        XCTAssertEqual(KeyRemap.parseModifierMappings(bad, keyboard: "1452-641"), [:])
        prefs = ["com.apple.keyboard.modifiermapping.1133-1-0": [pair(0xE2, 0xE3)],
                 "com.apple.keyboard.modifiermapping.1452-641-0": 7]
        bad = try PropertyListSerialization.data(fromPropertyList: prefs, format: .xml, options: 0)
        XCTAssertEqual(KeyRemap.parseModifierMappings(bad), [:], "two keyboards share nothing")
        XCTAssertEqual(KeyRemap.parseModifierMappings(bad, keyboard: "1452-641"), [:])
    }

    /// Only "<vid>-<pid>" (prefix match) and "<vid>-<pid>-<n>" (exact) select a keyboard; any other
    /// form is treated like nil (built-in unknown).
    func testModifierByHostKeyboardIdentifierForms() throws {
        let data = try byHost(["1452-641-0": [pair(0x39, 0x29)], "1452-834-0": [pair(0x39, 0xE0)]])
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1452-834"), [57: 59])
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "com.apple.keyboard.modifiermapping.1452-641-0"),
                       [57: 53])
        for invalid in ["1452", "1452-", "-641", "1452-641-", "1452--0", "0x5ac-641", "1452-641-0-0", " 1452-641",
                        "1452-64a", "", "com.apple.keyboard.modifiermapping."] {
            XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: invalid), [:], invalid)
        }
        // Invalid forms select no listed keyboard, but still find the built-in stored as 0-0-0.
        let withBuiltIn = try byHost(["0-0-0": [pair(0x39, 0x29)], "1452-834-0": [pair(0x39, 0xE0)]])
        for invalid in ["1452", "1452-", "0x5ac-641", "", "com.apple.keyboard.modifiermapping."] {
            XCTAssertEqual(KeyRemap.parseModifierMappings(withBuiltIn, keyboard: invalid), [57: 53], invalid)
        }
    }

    /// Modifier Keys settings are per keyboard: an external keyboard's remap must not override or
    /// leak into the built-in keyboard's, whatever the key order.
    func testModifierByHostKeyboardsDoNotMix() throws {
        let builtIn = [pair(0xE3, 0x39), pair(0x39, 0x29)]               // ⌘ → Caps Lock, Caps Lock → Esc
        let external = [pair(0x39, 0xE0), pair(0xE2, 0xE3), pair(0xE3, 0xE2)] // Caps → Ctrl, ⌥ ↔ ⌘ (PC keyboard)
        let data = try byHost(["0-0-0": builtIn, "1452-834-0": external])
        XCTAssertEqual(KeyRemap.parseModifierMappings(data), userRemap, "0-0-0 is the built-in candidate")
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "0-0-0"), userRemap)
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "com.apple.keyboard.modifiermapping.0-0-0"),
                       userRemap)
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1452-834"), [57: 59, 58: 55, 55: 58])
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1452-83"), userRemap,
                       "no partial-number match: falls back to 0-0-0, never to 1452-834")
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1452-641"), userRemap, "built-in id, 0-0-0 storage")
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: ""), userRemap, "malformed id: as nil")

        // No built-in candidate and no built-in id: nothing is used, even pairs every keyboard shares
        // (all of them may be external keyboards).
        let unknown = try byHost(["1452-641-0": builtIn, "1452-834-0": external + [pair(0xE7, 0xE4)],
                                  "9999-1-0": [pair(0xE7, 0xE4)]])
        XCTAssertEqual(KeyRemap.parseModifierMappings(unknown), [:])
        let agreeing = try byHost(["1452-641-0": builtIn + [pair(0xE7, 0xE4)], "1452-834-0": [pair(0xE7, 0xE4)]])
        XCTAssertEqual(KeyRemap.parseModifierMappings(agreeing), [:])
        XCTAssertEqual(KeyRemap.parseModifierMappings(agreeing, keyboard: "1452-641-0"), [55: 57, 57: 53, 54: 62])
    }

    // MARK: - Built-in keyboard selection probes (W3 passes "<vid>-<pid>" of the built-in, or nil)

    /// An external keyboard's Modifier Keys remap (here Option ↔ Command on a PC keyboard) must never
    /// reach iKey, whatever W3 passes.
    func testProbeOnlyExternalKeyboard() throws {
        let data = try byHost(["1133-50475-0": [pair(0xE2, 0xE3), pair(0xE3, 0xE2)]])
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: nil), [:], "nil")
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1452-641"), [:], "Apple silicon built-in id")
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "0-0"), [:], "built-in id 0-0")
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1133"), [:], "external's vendor alone")
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1133-5047"), [:], "partial product id")
        // Two external keyboards with the same swap: still not the built-in.
        let two = try byHost(["1133-50475-0": [pair(0xE2, 0xE3)], "1452-834-0": [pair(0xE2, 0xE3)]])
        XCTAssertEqual(KeyRemap.parseModifierMappings(two), [:])
        XCTAssertEqual(KeyRemap.parseModifierMappings(two, keyboard: "1452-641"), [:])
    }

    /// Apple silicon: the built-in is stored as 0-0-0 next to an external keyboard.
    func testProbeBuiltInZeroAndExternal() throws {
        let data = try byHost(["0-0-0": [pair(0xE3, 0x39), pair(0x39, 0x29)],
                               "1133-50475-0": [pair(0xE2, 0xE3), pair(0xE3, 0xE2), pair(0x39, 0xE0)]])
        for keyboard in [nil, "1452-641", "0-0", "0-0-0", "1452", "1133", "", "garbage"] as [String?] {
            XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: keyboard), userRemap, "\(keyboard ?? "nil")")
        }
        // Only the explicit external id selects the external keyboard (W3 never passes it).
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1133-50475"), [58: 55, 55: 58, 57: 59])
    }

    /// A malformed 0-0-0 entry is "built-in configured, nothing usable", never "use another keyboard".
    func testProbeMalformedBuiltInZero() throws {
        let external = [pair(0xE2, 0xE3), pair(0xE3, 0xE2)]
        let malformed: [Any] = ["x", 7, true, ["a": 1], [1, "b"], [["HIDKeyboardModifierMappingSrc": "zz"]],
                                [[String: Any]]()]
        for value in malformed {
            let prefs: [String: Any] = ["com.apple.keyboard.modifiermapping.0-0-0": value,
                                        "com.apple.keyboard.modifiermapping.1133-50475-0": external]
            let data = try PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0)
            XCTAssertEqual(KeyRemap.parseModifierMappings(data), [:], "\(value)")
            XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1452-641"), [:], "\(value)")
            XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1452"), [:], "\(value)")
        }
        // A partly valid 0-0-0 keeps its valid pairs.
        let partial: [String: Any] = ["com.apple.keyboard.modifiermapping.0-0-0":
                                        [pair(0xE3, 0x39), "junk", ["HIDKeyboardModifierMappingSrc": 1], pair(0x39, 0x29)],
                                      "com.apple.keyboard.modifiermapping.1133-50475-0": external]
        let data = try PropertyListSerialization.data(fromPropertyList: partial, format: .xml, options: 0)
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1452-641"), userRemap)
    }

    /// A vendor ID alone names no keyboard: never a prefix match on an external keyboard of the same
    /// vendor (Apple's own Magic Keyboard is 1452 too); the built-in 0-0-0 is still found.
    func testProbeVendorOnlyIdentifier() throws {
        let magic = try byHost(["1452-614-0": [pair(0xE2, 0xE3), pair(0xE3, 0xE2)]])
        XCTAssertEqual(KeyRemap.parseModifierMappings(magic, keyboard: "1452"), [:])
        XCTAssertEqual(KeyRemap.parseModifierMappings(magic, keyboard: "1452-"), [:])
        let both = try byHost(["1452-614-0": [pair(0xE2, 0xE3)], "0-0-0": [pair(0xE3, 0x39), pair(0x39, 0x29)]])
        XCTAssertEqual(KeyRemap.parseModifierMappings(both, keyboard: "1452"), userRemap)
    }

    /// Intel MacBooks store the built-in as "<vid>-<pid>-0"; W3's "<vid>-<pid>" selects it, never the
    /// external keyboards around it, even one with the same vendor or a longer product id.
    func testProbeIntelStyleBuiltIn() throws {
        let data = try byHost(["1452-641-0": [pair(0xE3, 0x39), pair(0x39, 0x29)],
                               "1452-6410-0": [pair(0xE3, 0xE2)],
                               "1452-834-0": [pair(0xE2, 0xE3), pair(0xE3, 0xE2)],
                               "1133-50475-0": [pair(0x39, 0xE0)]])
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1452-641"), userRemap)
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1452-641-0"), userRemap)
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "com.apple.keyboard.modifiermapping.1452-641-0"),
                       userRemap)
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: nil), [:], "built-in unknown: no keyboard used")
        XCTAssertEqual(KeyRemap.parseModifierMappings(data, keyboard: "1452"), [:])
        // A built-in "<vid>-<pid>-0" entry wins over a 0-0-0 entry; an exact id that is absent falls
        // back to 0-0-0.
        let mixed = try byHost(["1452-641-0": [pair(0xE3, 0x39), pair(0x39, 0x29)], "0-0-0": [pair(0xE7, 0xE4)]])
        XCTAssertEqual(KeyRemap.parseModifierMappings(mixed, keyboard: "1452-641"), userRemap)
        XCTAssertEqual(KeyRemap.parseModifierMappings(mixed, keyboard: "1452-641-1"), [54: 62])
        // The built-in configured back to defaults (empty array) masks nothing else.
        let reset = try byHost(["1452-641-0": [], "1452-834-0": [pair(0xE2, 0xE3)]])
        XCTAssertEqual(KeyRemap.parseModifierMappings(reset, keyboard: "1452-641"), [:])
    }

    func testModifierMalformedData() throws {
        XCTAssertEqual(KeyRemap.parseModifierMappings(Data()), [:])
        XCTAssertEqual(KeyRemap.parseModifierMappings(Data("not a plist".utf8)), [:])
        XCTAssertEqual(KeyRemap.parseModifierMappings(Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30, 0xFF])), [:])
        let string = try PropertyListSerialization.data(fromPropertyList: "x", format: .xml, options: 0)
        XCTAssertEqual(KeyRemap.parseModifierMappings(string), [:])
        let wrongShape = try PropertyListSerialization.data(fromPropertyList: [1, "a", ["b": 2]] as [Any],
                                                            format: .xml, options: 0)
        XCTAssertEqual(KeyRemap.parseModifierMappings(wrongShape), [:])
    }

    // MARK: - Karabiner-Elements

    private let karabinerSample = """
    {
      "global": {"show_in_menu_bar": true},
      "profiles": [
        {
          "name": "Gaming",
          "selected": false,
          "simple_modifications": [
            {"from": {"key_code": "escape"}, "to": [{"key_code": "caps_lock"}]}
          ]
        },
        {
          "name": "Default profile",
          "selected": true,
          "complex_modifications": {"rules": []},
          "simple_modifications": [
            {"from": {"key_code": "left_command"}, "to": [{"key_code": "caps_lock"}]},
            {"from": {"key_code": "caps_lock"}, "to": [{"key_code": "escape"}]},
            {"from": {"key_code": "right_option"}, "to": [{"key_code": "left_command", "modifiers": ["left_shift"]}]},
            {"from": {"key_code": "right_command"}, "to": [{"key_code": "a"}, {"key_code": "b"}]},
            {"from": {"pointing_button": "button4"}, "to": [{"key_code": "escape"}]},
            {"from": {"consumer_key_code": "mute"}, "to": [{"key_code": "f1"}]},
            {"from": {"key_code": "f1"}, "to": [{"consumer_key_code": "display_brightness_decrement"}]},
            {"from": {"key_code": "no_such_key"}, "to": [{"key_code": "escape"}]},
            {"from": {"key_code": "tab"}, "to": [{"key_code": "vk_none"}]}
          ],
          "devices": [
            {
              "identifiers": {"is_keyboard": true, "is_built_in_keyboard": true, "product_id": 0, "vendor_id": 0},
              "simple_modifications": [
                {"from": {"key_code": "right_command"}, "to": [{"key_code": "right_control"}]},
                {"from": {"apple_vendor_top_case_key_code": "keyboard_fn"}, "to": [{"key_code": "left_control"}]}
              ]
            },
            {
              "identifiers": {"is_keyboard": true, "product_id": 832, "vendor_id": 1452},
              "simple_modifications": [
                {"from": {"key_code": "a"}, "to": [{"key_code": "b"}]}
              ]
            },
            {
              "identifiers": {"is_keyboard": true, "is_built_in_keyboard": false, "product_id": 1, "vendor_id": 2},
              "ignore": true,
              "simple_modifications": [
                {"from": {"key_code": "c"}, "to": [{"key_code": "d"}]}
              ]
            }
          ]
        }
      ]
    }
    """

    func testKarabinerSelectedProfile() {
        XCTAssertEqual(KeyRemap.parseKarabiner(Data(karabinerSample.utf8)),
                       [55: 57, 57: 53, 54: 62, 63: 59, 48: KeyRemap.noAction])
    }

    func testKarabinerProfileByName() {
        XCTAssertEqual(KeyRemap.parseKarabiner(Data(karabinerSample.utf8), profileName: "Gaming"), [53: 57])
        XCTAssertEqual(KeyRemap.parseKarabiner(Data(karabinerSample.utf8), profileName: "Missing"), [:])
    }

    func testKarabinerFallsBackToFirstProfileAndDeviceOverrides() {
        let json = """
        {"profiles": [
          {"name": "A",
           "simple_modifications": [{"from": {"key_code": "caps_lock"}, "to": [{"key_code": "left_control"}]}],
           "devices": [
             {"simple_modifications": [{"from": {"key_code": "caps_lock"}, "to": [{"key_code": "escape"}]}]},
             {"identifiers": {}, "simple_modifications": [{"from": {"key_code": "left_gui"}, "to": {"key_code": "caps_lock"}}]}
           ]},
          {"name": "B", "simple_modifications": [{"from": {"key_code": "a"}, "to": [{"key_code": "b"}]}]}
        ]}
        """
        XCTAssertEqual(KeyRemap.parseKarabiner(Data(json.utf8)), userRemap)
    }

    func testKarabinerLegacyObjectForm() {
        let json = """
        {"profiles": [{"name": "Default", "selected": true,
          "simple_modifications": {"left_command": "caps_lock", "caps_lock": "escape", "mystery": "a", "b": 3}}]}
        """
        XCTAssertEqual(KeyRemap.parseKarabiner(Data(json.utf8)), userRemap)
    }

    func testKarabinerIgnoredBuiltInKeyboard() {
        let json = """
        {"profiles": [{"selected": true,
          "simple_modifications": [{"from": {"key_code": "caps_lock"}, "to": [{"key_code": "escape"}]}],
          "devices": [{"identifiers": {"is_built_in_keyboard": true}, "ignore": true}]}]}
        """
        XCTAssertEqual(KeyRemap.parseKarabiner(Data(json.utf8)), [:])
    }

    func testKarabinerMalformed() {
        for json in ["", "not json", "[]", "{}", #"{"profiles": 3}"#, #"{"profiles": []}"#, #"{"profiles": [1, "x"]}"#,
                     #"{"profiles": [{"selected": true, "simple_modifications": 7, "devices": "x"}]}"#,
                     #"{"profiles": [{"simple_modifications": [{"from": "caps_lock", "to": "escape"}, 5, {"to": []}]}]}"#,
                     #"{"profiles": [{"simple_modifications": [{"from": {"key_code": "caps_lock"}, "to": []}]}]}"#,
                     #"{"profiles": [{"simple_modifications": [{"from": {"key_code": "caps_lock"}, "to": [{"key_code": 5}]}]}]}"#,
                     #"{"profiles": [{"simple_modifications": [{"from": {"key_code": "vk_none"}, "to": [{"key_code": "a"}]}]}]}"#,
                     #"{"profiles": [{"devices": [{"identifiers": 4, "simple_modifications": [{"from": {"key_code": "a"}, "to": [{"key_code": "b"}]}]}]}]}"#] {
            XCTAssertEqual(KeyRemap.parseKarabiner(Data(json.utf8)), [:], json)
        }
    }

    // MARK: - Merge and apply

    func testMergePrecedence() {
        let remap = KeyRemap.merged(hidutil: [55: 57, 57: 53, 0: 11],
                                    modifierKeys: [57: 59, 58: KeyRemap.noAction],
                                    karabiner: [57: 53, 54: 62],
                                    manual: [54: 54, 1: 2])
        XCTAssertEqual(remap.map, [55: 57, 57: 53, 0: 11, 58: KeyRemap.noAction, 1: 2],
                       "last wins; manual 54 → 54 cancels Karabiner's remap and is not stored")
        XCTAssertEqual(remap.sources, [.hidutil, .modifierKeys, .karabiner, .manual])
    }

    func testMergeDoesNotChain() {
        let remap = KeyRemap.merged(hidutil: [55: 57], modifierKeys: [57: 53], karabiner: [:], manual: nil)
        XCTAssertEqual(remap.apply(55), 57, "left Command still yields Caps Lock, not Escape")
        XCTAssertEqual(remap.apply(57), 53)
        XCTAssertEqual(remap.sources, [.hidutil, .modifierKeys])
    }

    /// `sources` lists only the sources that supply a final value.
    func testMergeSourcesAttribution() {
        let overridden = KeyRemap.merged(hidutil: [55: 57], modifierKeys: [:], karabiner: [55: 58], manual: nil)
        XCTAssertEqual(overridden.map, [55: 58])
        XCTAssertEqual(overridden.sources, [.karabiner])
        let identityOnly = KeyRemap.merged(hidutil: [55: 55], modifierKeys: [:], karabiner: [:], manual: nil)
        XCTAssertEqual(identityOnly, KeyRemap())
        let cancelled = KeyRemap.merged(hidutil: [57: KeyRemap.noAction], modifierKeys: [:], karabiner: [:],
                                        manual: [57: 57])
        XCTAssertEqual(cancelled.map, [:])
        XCTAssertEqual(cancelled.sources, [.manual], "the manual cancel is what took effect")
        let same = KeyRemap.merged(hidutil: [55: 57], modifierKeys: [:], karabiner: [55: 57, 57: 53], manual: [:])
        XCTAssertEqual(same.map, userRemap)
        XCTAssertEqual(same.sources, [.karabiner], "the later source is credited for an equal value")
    }

    func testMergeEmpty() {
        XCTAssertEqual(KeyRemap.merged(hidutil: [:], modifierKeys: [:], karabiner: [:], manual: nil), KeyRemap())
        XCTAssertEqual(KeyRemap.merged(hidutil: [:], modifierKeys: [:], karabiner: [:], manual: [:]).sources, [])
    }

    func testApply() {
        let remap = KeyRemap(map: [55: 57, 57: 53, 48: KeyRemap.noAction], sources: [.manual])
        XCTAssertEqual(remap.apply(55), 57)
        XCTAssertEqual(remap.apply(57), 53)
        XCTAssertEqual(remap.apply(54), 54, "right Command unaffected")
        XCTAssertEqual(remap.apply(0), 0)
        XCTAssertEqual(remap.apply(48), KeyRemap.noAction)
        XCTAssertEqual(KeyRemap().apply(55), 55)
    }

    func testCodableRoundTrip() throws {
        let remap = KeyRemap(map: [55: 57, 57: 53], sources: [.karabiner, .manual])
        let decoded = try JSONDecoder().decode(KeyRemap.self, from: JSONEncoder().encode(remap))
        XCTAssertEqual(decoded, remap)
        XCTAssertEqual(KeyRemapSource(rawValue: "modifierKeys"), .modifierKeys)
    }

    /// The same remap read from each source format yields the same map.
    func testUserRemapFromEverySource() {
        let hidutil = KeyRemap.parseHidutil(
            "({HIDKeyboardModifierMappingSrc = 0x7000000E3; HIDKeyboardModifierMappingDst = 0x700000039;}," +
            " {HIDKeyboardModifierMappingSrc = 0x700000039; HIDKeyboardModifierMappingDst = 0x700000029;})")
        let modifier = KeyRemap.parseModifierMappings([
            ["HIDKeyboardModifierMappingSrc": 30_064_771_299, "HIDKeyboardModifierMappingDst": 30_064_771_129],
            ["HIDKeyboardModifierMappingSrc": 30_064_771_129, "HIDKeyboardModifierMappingDst": 30_064_771_113]
        ])
        let karabiner = KeyRemap.parseKarabiner(Data(karabinerSample.utf8))
            .filter { [55, 57].contains($0.key) }
        XCTAssertEqual(hidutil, userRemap)
        XCTAssertEqual(modifier, userRemap)
        XCTAssertEqual(karabiner, userRemap)
    }

    // MARK: - The user's actual setup

    /// Real `hidutil property --get UserKeyMapping` output for left ⌘ → Caps Lock, Caps Lock → Esc,
    /// in the order hidutil prints it (Dst before Src), and the minimal karabiner.json the
    /// Karabiner-Elements UI writes for the same pair, merged into the remap iKey applies.
    func testUserSetupFromHidutilAndKarabiner() {
        let hidutilText = """
        (
                {
                HIDKeyboardModifierMappingDst = 30064771129;
                HIDKeyboardModifierMappingSrc = 30064771299;
            },
                {
                HIDKeyboardModifierMappingDst = 30064771113;
                HIDKeyboardModifierMappingSrc = 30064771129;
            }
        )

        """
        let karabinerJSON = """
        {
          "profiles": [
            {
              "name": "Default profile",
              "selected": true,
              "virtual_hid_keyboard": {"keyboard_type_v2": "ansi"},
              "simple_modifications": [
                {"from": {"key_code": "left_command"}, "to": [{"key_code": "caps_lock"}]},
                {"from": {"key_code": "caps_lock"}, "to": [{"key_code": "escape"}]}
              ]
            }
          ]
        }
        """
        let hidutil = KeyRemap.parseHidutil(hidutilText)
        let karabiner = KeyRemap.parseKarabiner(Data(karabinerJSON.utf8))
        XCTAssertEqual(hidutil, [55: 57, 57: 53])
        XCTAssertEqual(karabiner, [55: 57, 57: 53])

        typealias Case = (hidutil: [UInt16: UInt16], karabiner: [UInt16: UInt16], sources: [KeyRemapSource])
        let cases: [Case] = [(hidutil, [:], [.hidutil]), ([:], karabiner, [.karabiner]),
                             (hidutil, karabiner, [.karabiner])]
        for (h, k, sources) in cases {
            let remap = KeyRemap.merged(hidutil: h, modifierKeys: [:], karabiner: k, manual: nil)
            XCTAssertEqual(remap.map, [55: 57, 57: 53])
            XCTAssertEqual(remap.sources, sources)
            XCTAssertEqual(remap.apply(55), 57)
            XCTAssertEqual(remap.apply(57), 53)
            XCTAssertEqual(remap.apply(54), 54, "right Command unaffected")
            XCTAssertEqual(remap.tapOnlyPadCodes, [55])
        }
    }

    // MARK: - Tap-only pad codes (amendment H)

    func testTapOnlyPadCodes() {
        XCTAssertEqual(KeyRemap.tapOnlyPadCodes(for: [55: 57, 57: 53]), [55], "user setup")
        XCTAssertEqual(KeyRemap.tapOnlyPadCodes(for: [55: 57]), [55])
        XCTAssertEqual(KeyRemap.tapOnlyPadCodes(for: [57: 53]), [], "Caps Lock is not a deck modifier")
        XCTAssertEqual(KeyRemap.tapOnlyPadCodes(for: [58: 55, 55: 58]), [], "modifier swap")
        XCTAssertEqual(KeyRemap.tapOnlyPadCodes(for: [57: 59]), [], "Caps Lock → Control")
        XCTAssertEqual(KeyRemap.tapOnlyPadCodes(for: [55: 55]), [], "identity")
        XCTAssertEqual(KeyRemap.tapOnlyPadCodes(for: [:]), [])
        XCTAssertEqual(KeyRemap.tapOnlyPadCodes(for: [54: 53, 63: 59, 59: KeyRemap.noAction, 61: 0, 56: 60]),
                       [54, 59, 61], "Escape, disabled and letter targets; fn → Control, Shift → Shift stay modifiers")
        // Every modifier source mapped to a non-modifier is tap-only; nothing else ever is.
        for source in KeyCommitPipeline.modifierCodes {
            XCTAssertEqual(KeyRemap.tapOnlyPadCodes(for: [source: 53]), [source])
            for target in KeyCommitPipeline.modifierCodes {
                XCTAssertEqual(KeyRemap.tapOnlyPadCodes(for: [source: target]), [])
            }
        }
        let plainKeys = InputEvent.supportedKeyCodes.subtracting(KeyCommitPipeline.modifierCodes).subtracting([53])
        for source in plainKeys {
            XCTAssertEqual(KeyRemap.tapOnlyPadCodes(for: [source: 53, 53: source]), [], "\(source)")
        }
        XCTAssertEqual(KeyRemap(map: [55: 57, 57: 53]).tapOnlyPadCodes, [55])
    }
}
