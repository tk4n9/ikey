import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import IKeyCore

final class TopRowChoicesTests: XCTestCase {
    private let nc = ModifierFlags.nonCoalesced
    private let env = PointerEnvironment(cursor: CGPoint(x: 500, y: 400),
                                         displays: [CGRect(x: 0, y: 0, width: 1470, height: 956)], capsLockOn: false)

    /// Key down of physical `code` through a core using `choices`, without user-activity events.
    private func press(_ code: UInt16, choices: TopRowChoices,
                       hotKeys: SymbolicHotKeys = SymbolicHotKeys(plist: nil)) -> [SynthEvent] {
        var settings = InjectorSettings()
        settings.topRowChoices = choices.strategies()
        settings.hotKeys = hotKeys
        var core = InjectorCore(settings: settings)
        return core.handle(.input(.key(code: code, down: true), t: 0), at: 0, env: env)
            .filter { $0 != .declareUserActivity }
    }

    func testStorageKey() {
        XCTAssertEqual(TopRowChoices.storageKey, "iKey.topRow.v1")
    }

    func testRoundTrip() throws {
        var choices = TopRowChoices()
        choices.set(.brightnessDown, .keyCode(145, secondaryFn: true))
        choices.set(.missionControl, .openApplication("/System/Applications/Mission Control.app"))
        choices.set(.dictation, .none)
        choices.set(.rewind, .aux(18))

        let data = try JSONEncoder().encode(choices)
        let decoded = try JSONDecoder().decode(TopRowChoices.self, from: data)
        XCTAssertEqual(decoded, choices)
        XCTAssertEqual(decoded.strategies(), [
            .brightnessDown: .keyCode(145, secondaryFn: true),
            .missionControl: .openApplication("/System/Applications/Mission Control.app"),
            .dictation: TopRowStrategy.none,
            .rewind: .aux(18),
        ])
    }

    func testDecodesStoredJSON() throws {
        let json = Data(#"{"choices":{"volumeUp":"aux:0","spotlight":"hot:64"}}"#.utf8)
        let decoded = try JSONDecoder().decode(TopRowChoices.self, from: json)
        XCTAssertEqual(decoded.choices, ["volumeUp": "aux:0", "spotlight": "hot:64"])
        XCTAssertEqual(decoded.strategies(), [.volumeUp: .aux(0), .spotlight: .hotKey(64)])
    }

    func testSetStoresIdAndReplaces() {
        var choices = TopRowChoices()
        choices.set(.missionControl, .hotKey(32))
        XCTAssertEqual(choices.choices, ["missionControl": "hot:32"])
        choices.set(.missionControl, .keyCode(160, secondaryFn: true))
        XCTAssertEqual(choices.choices, ["missionControl": "key:160:1"])
        XCTAssertEqual(choices.strategies(), [.missionControl: .keyCode(160, secondaryFn: true)])
    }

    func testUnknownIdIgnored() {
        var choices = TopRowChoices()
        choices.choices = [
            "volumeUp": "aux:99",              // well-formed, but not in the volume-up chain
            "spotlight": "garbage",            // malformed id
            "missionControl": "hot:64",        // another function's strategy
            "notAFunction": "aux:0",           // unknown function
            "mute": "aux:7",                   // valid
        ]
        XCTAssertEqual(choices.strategies(), [.mute: .aux(7)])

        // An ignored choice falls back to the chain head: F12 still raises the volume.
        XCTAssertEqual(press(111, choices: choices), [.aux(nxKeyType: 0, down: true, autorepeat: false, flags: nc)])
        // F4 (Spotlight) posts its chain head, the Spotlight key code.
        XCTAssertEqual(press(118, choices: choices), [.key(code: 129, down: true, flags: nc, autorepeat: false)])
    }

    func testResolvesHotKeyStrategy() {
        var choices = TopRowChoices()
        choices.set(.missionControl, .hotKey(32))
        choices.set(.brightnessUp, .hotKey(54))
        XCTAssertEqual(choices.strategies(), [.missionControl: .hotKey(32), .brightnessUp: .hotKey(54)])

        // With the Mac's Mission Control shortcut (Ctrl+Up) enabled, F3 posts that chord.
        let hotKeys = SymbolicHotKeys(plist: [
            "32": ["enabled": true, "value": ["parameters": [65535, 126, 0x840000], "type": "standard"]] as [String: Any]
        ])
        let keyFlags = ModifierFlags(rawValue: 0xA40000 | 0x1 | 0x100)
        XCTAssertEqual(press(99, choices: choices, hotKeys: hotKeys), [
            .flagsChanged(code: 59, flags: [.nonCoalesced, .control, .leftControl]),
            .key(code: 126, down: true, flags: keyFlags, autorepeat: false),
            .key(code: 126, down: false, flags: keyFlags, autorepeat: false),
            .flagsChanged(code: 59, flags: nc),
        ])
    }

    func testEmptyMeansDefaultChainHead() {
        let empty = TopRowChoices()
        XCTAssertTrue(empty.choices.isEmpty)
        XCTAssertTrue(empty.strategies().isEmpty)

        // Every function then performs the first strategy of its default chain.
        XCTAssertEqual(press(122, choices: empty), [.aux(nxKeyType: 3, down: true, autorepeat: false, flags: nc)])
        XCTAssertEqual(press(99, choices: empty),
                       [.key(code: 160, down: true, flags: [.nonCoalesced, .secondaryFn], autorepeat: false)])
        XCTAssertEqual(press(96, choices: empty), [.key(code: 176, down: true, flags: nc, autorepeat: false)])
        XCTAssertEqual(press(98, choices: empty), [.aux(nxKeyType: 20, down: true, autorepeat: false, flags: nc)])
        XCTAssertEqual(press(111, choices: empty), [.aux(nxKeyType: 0, down: true, autorepeat: false, flags: nc)])
    }

    func testConfirmedNoneOverridesChain() {
        // A documented 'none' (e.g. dictation that no strategy performs) makes F5 post nothing.
        var choices = TopRowChoices()
        choices.set(.dictation, .none)
        XCTAssertEqual(choices.strategies(), [.dictation: TopRowStrategy.none])
        XCTAssertEqual(press(96, choices: choices), [])
    }

    func testChoiceReplacesChainHead() {
        var choices = TopRowChoices()
        choices.set(.rewind, .aux(18))
        XCTAssertEqual(press(98, choices: choices), [.aux(nxKeyType: 18, down: true, autorepeat: false, flags: nc)])
    }
}
