import Foundation
import XCTest
@testable import IKeyCore

final class GestureActionMapTests: XCTestCase {
    private func entry(enabled: Any = true, ascii: Int = 65535, keyCode: Any, mods: Any) -> [String: Any] {
        ["enabled": enabled, "value": ["parameters": [ascii, keyCode, mods], "type": "standard"] as [String: Any]]
    }

    func testSwipeLeftCtrlRight() throws {
        var map = GestureActionMap()
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .left), at: 0), [.hotKey(81)])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .right), at: 1), [.hotKey(79)])
        let right = try XCTUnwrap(SymbolicHotKeys(plist: nil).hotKey(81))
        XCTAssertEqual(right, HotKey(keyCode: 124, modifierMask: 0x840000, enabled: true))
        XCTAssertEqual(SymbolicHotKeys(plist: nil).hotKey(79)?.keyCode, 123)
        // Fewer fingers do nothing; more fingers count too.
        XCTAssertEqual(map.handle(.swipe(fingers: 2, direction: .up), at: 2), [])
        XCTAssertEqual(map.handle(.swipe(fingers: 4, direction: .left), at: 2), [.hotKey(81)])
        XCTAssertEqual(map.handle(.swipe(fingers: 5, direction: .right), at: 2), [.hotKey(79)])
        // With three-finger drag on, swipes move to four fingers: three fingers drag.
        var four = GestureActionMap(swipeFingers: 4)
        XCTAssertEqual(four.handle(.swipe(fingers: 3, direction: .left), at: 0), [])
        XCTAssertEqual(four.handle(.swipe(fingers: 4, direction: .left), at: 0), [.hotKey(81)])
        XCTAssertEqual(four.handle(.swipe(fingers: 5, direction: .left), at: 0), [.hotKey(81)])
    }

    func testUpThenDownClosesMissionControl() {
        var map = GestureActionMap()
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 10), [.hotKey(32)])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .down), at: 14.9), [.hotKey(32)])
        // Closed again, so the next swipe down is App Exposé.
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .down), at: 15), [.hotKey(33)])

        // A gesture that maps to nothing does not count as another action.
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 20), [.hotKey(32)])
        XCTAssertEqual(map.handle(.swipe(fingers: 2, direction: .down), at: 21), [])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .down), at: 22), [.hotKey(32)])

        // Other input in between means Mission Control may already be gone.
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 30), [.hotKey(32)])
        map.noteOtherInput(at: 31)
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .down), at: 32), [.hotKey(33)])

        // So does a Look Up tap.
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 40), [.hotKey(32)])
        XCTAssertEqual(map.handle(.tap(fingers: 3), at: 41), [.hotKey(70)])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .down), at: 42), [.hotKey(33)])
    }

    /// Regression: switching Spaces inside Mission Control leaves it open, so the swipe down
    /// afterwards still closes it and a swipe up still keeps it open (Ctrl+Up toggles).
    func testSpaceSwipesInsideMissionControlKeepItOpen() {
        var map = GestureActionMap(appExposeEnabled: false)
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 0), [.hotKey(32)])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .left), at: 1), [.hotKey(81)])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .right), at: 2), [.hotKey(79)])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 3), [])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .left), at: 4), [.hotKey(81)])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .down), at: 5), [.hotKey(32)])
        // Closed: the next swipe down is App Exposé (off here), the next swipe up opens it.
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .down), at: 6), [])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 7), [.hotKey(32)])
        // A four-finger swipe is the same gesture.
        XCTAssertEqual(map.handle(.swipe(fingers: 4, direction: .down), at: 8), [.hotKey(32)])
    }

    /// Regression: Mission Control opened with its key (F3) is open too: a swipe down closes it and
    /// a swipe up keeps it open. The key pressed while it is open closes it.
    func testMissionControlKeyToggleIsTracked() {
        var map = GestureActionMap(appExposeEnabled: false)
        map.noteMissionControlToggled(at: 0)
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .down), at: 1), [.hotKey(32)])
        map.noteMissionControlToggled(at: 2)
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 3), [])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .down), at: 4), [.hotKey(32)])
        // Opened by a swipe, closed by the key: the next swipe up opens it again.
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 10), [.hotKey(32)])
        map.noteMissionControlToggled(at: 11)
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .down), at: 12), [])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 13), [.hotKey(32)])
    }

    func testDownAfter15sIsAppExpose() {
        var map = GestureActionMap()
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 0), [.hotKey(32)])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .down), at: 15), [.hotKey(33)])
        XCTAssertEqual(SymbolicHotKeys(plist: nil).hotKey(33)?.keyCode, 125)

        var noExpose = GestureActionMap(appExposeEnabled: false)
        XCTAssertEqual(noExpose.handle(.swipe(fingers: 3, direction: .down), at: 0), [])
        // Closing Mission Control still works without App Exposé.
        XCTAssertEqual(noExpose.handle(.swipe(fingers: 3, direction: .up), at: 1), [.hotKey(32)])
        XCTAssertEqual(noExpose.handle(.swipe(fingers: 3, direction: .down), at: 2), [.hotKey(32)])
    }

    func testTapLookUp() {
        var map = GestureActionMap()
        XCTAssertEqual(map.handle(.tap(fingers: 3), at: 0), [.hotKey(70)])
        XCTAssertEqual(map.handle(.tap(fingers: 2), at: 0), [])
        XCTAssertEqual(map.handle(.tap(fingers: 4), at: 0), [])
        XCTAssertEqual(SymbolicHotKeys(plist: nil).hotKey(70), HotKey(keyCode: 2, modifierMask: 0x140000))

        var off = GestureActionMap(lookUpTap: false)
        XCTAssertEqual(off.handle(.tap(fingers: 3), at: 0), [])
    }

    func testDisabledHotKeySkipped() {
        let keys = SymbolicHotKeys(plist: [
            "81": entry(enabled: false, keyCode: 124, mods: 0x840000),
            "79": entry(enabled: 0, keyCode: 123, mods: 0x840000),
            "32": entry(enabled: NSNumber(value: 1), keyCode: 126, mods: 0x840000),
        ])
        XCTAssertEqual(keys.hotKey(81)?.enabled, false)
        XCTAssertEqual(keys.hotKey(79)?.enabled, false)
        XCTAssertEqual(keys.hotKey(32)?.enabled, true)
        // A consumer posts only enabled shortcuts.
        var map = GestureActionMap()
        let posted = map.handle(.swipe(fingers: 3, direction: .left), at: 0).compactMap { action -> HotKey? in
            guard case let .hotKey(id) = action, let key = keys.hotKey(id), key.enabled else { return nil }
            return key
        }
        XCTAssertEqual(posted, [])
    }

    func testDefaultsOverlay() {
        let keys = SymbolicHotKeys(plist: [
            "32": entry(keyCode: 18, mods: 0x40000),                         // remapped to Ctrl+1
            "33": entry(keyCode: 65535, mods: 0),                            // shortcut cleared
            "36": ["enabled": true] as [String: Any],                        // no value
            "70": entry(keyCode: NSNumber(value: 2), mods: NSNumber(value: 0x100000)),
            "118": entry(ascii: 49, keyCode: 18, mods: 0x40000),             // not in the defaults
            "64": "garbage",
            "not-an-id": entry(keyCode: 1, mods: 0),
        ])
        XCTAssertEqual(keys.hotKey(32), HotKey(keyCode: 18, modifierMask: 0x40000))
        XCTAssertNil(keys.hotKey(33))
        XCTAssertNil(keys.hotKey(36))
        XCTAssertNil(keys.hotKey(64))
        XCTAssertEqual(keys.hotKey(70), HotKey(keyCode: 2, modifierMask: 0x100000))
        XCTAssertEqual(keys.hotKey(118), HotKey(keyCode: 18, modifierMask: 0x40000))
        // Absent ids keep their defaults.
        for id in [53, 54, 60, 61, 79, 81] {
            XCTAssertEqual(keys.hotKey(id), SymbolicHotKeys.defaults[id], "id \(id)")
        }
        XCTAssertNil(keys.hotKey(999))
        XCTAssertEqual(SymbolicHotKeys.defaults.count, 11)
        XCTAssertEqual(SymbolicHotKeys(plist: nil).hotKey(61), HotKey(keyCode: 49, modifierMask: 0xC0000))
        XCTAssertEqual(SymbolicHotKeys(plist: [:]), SymbolicHotKeys(plist: nil))
    }

    func testHotKeysEquatableDetectsChange() {
        let base = SymbolicHotKeys(plist: nil)
        // Restating a default resolves to the same table.
        XCTAssertEqual(SymbolicHotKeys(plist: ["32": entry(keyCode: 126, mods: 0x840000)]), base)
        XCTAssertNotEqual(SymbolicHotKeys(plist: ["32": entry(keyCode: 126, mods: 0x40000)]), base)
        XCTAssertNotEqual(SymbolicHotKeys(plist: ["32": entry(enabled: false, keyCode: 126, mods: 0x840000)]), base)
        XCTAssertNotEqual(SymbolicHotKeys(plist: ["32": entry(keyCode: 65535, mods: 0)]), base)
        XCTAssertNotEqual(SymbolicHotKeys(plist: ["200": entry(keyCode: 1, mods: 0)]), base)
    }

    /// Ctrl+Up toggles, but a real pad keeps Mission Control open on a second swipe up,
    /// so up, up, down opens it and then closes it.
    func testUpWhileOpenKeepsMissionControlOpen() {
        var map = GestureActionMap()
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 0), [.hotKey(32)])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 1), [])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .down), at: 2), [.hotKey(32)])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .down), at: 3), [.hotKey(33)])

        // A second swipe up restarts the window.
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 10), [.hotKey(32)])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 20), [])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .down), at: 30), [.hotKey(32)])

        // After other input or the window, a swipe up opens Mission Control again.
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 40), [.hotKey(32)])
        map.noteOtherInput(at: 41)
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 42), [.hotKey(32)])
        XCTAssertEqual(map.handle(.swipe(fingers: 3, direction: .up), at: 57), [.hotKey(32)])
    }
}
