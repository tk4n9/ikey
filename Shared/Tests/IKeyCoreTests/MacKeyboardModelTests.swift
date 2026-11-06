import Foundation
import XCTest
@testable import IKeyCore

final class MacKeyboardModelTests: XCTestCase {
    private let lCtl: UInt16 = 59, rAlt: UInt16 = 61, lCmd: UInt16 = 55, rCmd: UInt16 = 54, lShift: UInt16 = 56
    private let fn = MacKeyCode.fn, caps = MacKeyCode.capsLock
    private let up: UInt16 = 126, left: UInt16 = 123, down: UInt16 = 125, delete: UInt16 = 51, letterE: UInt16 = 14
    private let f8: UInt16 = 100, f12: UInt16 = 111

    private func press(_ m: inout MacKeyboardModel, _ code: UInt16, _ isDown: Bool, at t: TimeInterval,
                       sender: TimeInterval? = nil, capsOn: Bool = false) -> [KeyboardAction] {
        m.key(code, down: isDown, senderTime: sender, at: t, capsLockOn: capsOn)
    }

    /// Drives advance() at every deadline before `end`, sending a frame every `frameEvery` seconds.
    private func run(_ m: inout MacKeyboardModel, until end: TimeInterval, frameEvery: TimeInterval? = 0.1) -> [(TimeInterval, KeyboardAction)] {
        var out: [(TimeInterval, KeyboardAction)] = []
        var nextFrame = frameEvery
        while true {
            let deadline = m.nextDeadline
            let frameAt = nextFrame
            guard let t = [deadline, frameAt].compactMap({ $0 }).min(), t < end - 1e-9 else { break }
            if let f = frameAt, f <= t, let every = frameEvery {
                m.frameReceived(at: f)
                nextFrame = f + every
                continue
            }
            for a in m.advance(to: t, capsLockOn: false) { out.append((t, a)) }
        }
        return out
    }

    // MARK: Flags

    func testCtrlUpFlags() {
        var m = MacKeyboardModel()
        XCTAssertEqual(press(&m, lCtl, true, at: 0), [.flagsChanged(code: lCtl, flags: ModifierFlags(rawValue: 0x40101))])
        let expected = ModifierFlags(rawValue: 0xA40000 | 0x1 | 0x100)
        XCTAssertEqual(press(&m, up, true, at: 0.1), [.key(code: up, down: true, flags: expected, autorepeat: false)])
        XCTAssertEqual(press(&m, up, false, at: 0.2), [.key(code: up, down: false, flags: expected, autorepeat: false)])
        XCTAssertEqual(press(&m, lCtl, false, at: 0.3), [.flagsChanged(code: lCtl, flags: .nonCoalesced)])
    }

    func testRightOptionDeviceBit() {
        var m = MacKeyboardModel()
        let actions = press(&m, rAlt, true, at: 0)
        XCTAssertEqual(actions, [.flagsChanged(code: rAlt, flags: ModifierFlags(rawValue: 0x80000 | 0x40 | 0x100))])
        XCTAssertFalse(m.currentFlags(capsLockOn: false).contains(.leftOption))
        XCTAssertEqual(MacKeyCode.modifierFlags(for: 58), [.option, .leftOption])
    }

    func testRightCmdLetterFlags() {
        var m = MacKeyboardModel()
        _ = press(&m, rCmd, true, at: 0)
        XCTAssertEqual(press(&m, letterE, true, at: 0.1),
                       [.key(code: letterE, down: true, flags: ModifierFlags(rawValue: 0x100010 | 0x100), autorepeat: false)])
        _ = press(&m, letterE, false, at: 0.15)
        _ = press(&m, rCmd, false, at: 0.2)
        _ = press(&m, lCmd, true, at: 0.3)
        XCTAssertEqual(press(&m, letterE, true, at: 0.4),
                       [.key(code: letterE, down: true, flags: ModifierFlags(rawValue: 0x100008 | 0x100), autorepeat: false)])
    }

    func testImplicitFlagsTable() {
        XCTAssertEqual(MacKeyCode.implicitFlags(for: 124), [.secondaryFn, .numericPad])
        XCTAssertEqual(MacKeyCode.implicitFlags(for: 122), .secondaryFn)
        XCTAssertEqual(MacKeyCode.implicitFlags(for: 90), .secondaryFn)
        XCTAssertEqual(MacKeyCode.implicitFlags(for: 117), .secondaryFn)
        XCTAssertEqual(MacKeyCode.implicitFlags(for: 76), .numericPad)
        XCTAssertEqual(MacKeyCode.implicitFlags(for: 84), .numericPad)
        XCTAssertEqual(MacKeyCode.implicitFlags(for: 0), [])
        XCTAssertEqual(MacKeyCode.modifiers, [54, 55, 56, 58, 59, 60, 61, 62, 63])
        XCTAssertNil(MacKeyCode.modifierFlags(for: MacKeyCode.capsLock))
    }

    func testSystemCapsLockStateSetsAlphaShift() {
        var m = MacKeyboardModel()
        XCTAssertEqual(press(&m, letterE, true, at: 0, capsOn: true),
                       [.key(code: letterE, down: true, flags: [.nonCoalesced, .alphaShift], autorepeat: false)])
    }

    // MARK: fn layer

    func testFnLeftHomeEvenIfFnReleasedFirst() {
        var m = MacKeyboardModel()
        XCTAssertEqual(press(&m, fn, true, at: 0), [.flagsChanged(code: fn, flags: [.nonCoalesced, .secondaryFn])])
        XCTAssertEqual(press(&m, left, true, at: 0.05),
                       [.key(code: 115, down: true, flags: [.nonCoalesced, .secondaryFn], autorepeat: false)])
        XCTAssertEqual(press(&m, fn, false, at: 0.1), [.flagsChanged(code: fn, flags: .nonCoalesced)])
        XCTAssertEqual(press(&m, left, false, at: 0.15),
                       [.key(code: 115, down: false, flags: [.nonCoalesced, .secondaryFn], autorepeat: false)])
        XCTAssertTrue(m.heldPhysicalCodes.isEmpty)
    }

    func testFnDeleteForwardDelete() {
        var m = MacKeyboardModel()
        _ = press(&m, fn, true, at: 0)
        XCTAssertEqual(press(&m, delete, true, at: 0.05),
                       [.key(code: 117, down: true, flags: [.nonCoalesced, .secondaryFn], autorepeat: false)])
        XCTAssertEqual(press(&m, delete, false, at: 0.1),
                       [.key(code: 117, down: false, flags: [.nonCoalesced, .secondaryFn], autorepeat: false)])
        _ = press(&m, 36, true, at: 0.2)
        XCTAssertEqual(press(&m, 36, false, at: 0.25),
                       [.key(code: 76, down: false, flags: [.nonCoalesced, .secondaryFn, .numericPad], autorepeat: false)])
        XCTAssertEqual(press(&m, delete, true, at: 0.3).first.flatMap(code), 117)
    }

    func testDeleteWithoutFnIsPlainDelete() {
        var m = MacKeyboardModel()
        XCTAssertEqual(press(&m, delete, true, at: 0), [.key(code: delete, down: true, flags: .nonCoalesced, autorepeat: false)])
    }

    // MARK: Top row

    func testTopRowFnStateFalse() {
        var m = MacKeyboardModel()
        XCTAssertEqual(press(&m, f12, true, at: 0), [.topRow(.volumeUp, down: true, autorepeat: false, flags: .nonCoalesced)])
        XCTAssertEqual(press(&m, f12, false, at: 0.05), [.topRow(.volumeUp, down: false, autorepeat: false, flags: .nonCoalesced)])
        _ = press(&m, fn, true, at: 0.1)
        XCTAssertEqual(press(&m, f12, true, at: 0.15),
                       [.key(code: f12, down: true, flags: [.nonCoalesced, .secondaryFn], autorepeat: false)])
        XCTAssertEqual(press(&m, f12, false, at: 0.2),
                       [.key(code: f12, down: false, flags: [.nonCoalesced, .secondaryFn], autorepeat: false)])
    }

    func testTopRowFnStateTrueReversed() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(fnKeysStandard: true))
        XCTAssertEqual(press(&m, f12, true, at: 0), [.key(code: f12, down: true, flags: [.nonCoalesced, .secondaryFn], autorepeat: false)])
        _ = press(&m, f12, false, at: 0.05)
        _ = press(&m, fn, true, at: 0.1)
        XCTAssertEqual(press(&m, f12, true, at: 0.15),
                       [.topRow(.volumeUp, down: true, autorepeat: false, flags: [.nonCoalesced, .secondaryFn])])
    }

    func testTopRowMidPressFnChangeReleasesSame() {
        var m = MacKeyboardModel()
        _ = press(&m, f12, true, at: 0)
        _ = press(&m, fn, true, at: 0.05)
        XCTAssertEqual(press(&m, f12, false, at: 0.1),
                       [.topRow(.volumeUp, down: false, autorepeat: false, flags: [.nonCoalesced, .secondaryFn])])
        _ = press(&m, f8, true, at: 0.2)
        _ = press(&m, fn, false, at: 0.25)
        XCTAssertEqual(press(&m, f8, false, at: 0.3), [.key(code: f8, down: false, flags: [.nonCoalesced, .secondaryFn], autorepeat: false)])
    }

    func testTopRowCodesAndChains() {
        XCTAssertEqual(MacKeyCode.fKeys.compactMap(TopRowFunction.forPhysicalCode), TopRowFunction.allCases)
        XCTAssertEqual(TopRowFunction.forPhysicalCode(122), .brightnessDown)
        XCTAssertEqual(TopRowFunction.forPhysicalCode(100), .playPause)
        XCTAssertNil(TopRowFunction.forPhysicalCode(105))
        XCTAssertEqual(TopRowFunction.allCases.filter(\.repeats), [.brightnessDown, .brightnessUp, .volumeDown, .volumeUp])
        XCTAssertEqual(TopRowDefaults.chain(for: .brightnessDown).map(\.id), ["aux:3", "key:145:1", "hot:53"])
        XCTAssertEqual(TopRowDefaults.chain(for: .missionControl).map(\.id),
                       ["key:160:1", "hot:32", "app:/System/Applications/Mission Control.app"])
        XCTAssertEqual(TopRowDefaults.chain(for: .dictation).map(\.id), ["key:176:0", "none"])
        XCTAssertEqual(TopRowDefaults.chain(for: .volumeUp), [.aux(0)])
    }

    func testTopRowStrategyCodableUsesId() throws {
        let strategies: [TopRowStrategy] = TopRowFunction.allCases.flatMap(TopRowDefaults.chain(for:))
        let data = try JSONEncoder().encode(strategies)
        XCTAssertEqual(try JSONDecoder().decode([TopRowStrategy].self, from: data), strategies)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([TopRowStrategy.keyCode(145, secondaryFn: true)]), as: UTF8.self),
                       "[\"key:145:1\"]")
        XCTAssertEqual(TopRowStrategy(id: "app:/A:B.app"), .openApplication("/A:B.app"))
        for bad in ["", "aux", "aux:x", "key:1", "key:1:2", "hot:", "app:", "nope:1"] {
            XCTAssertNil(TopRowStrategy(id: bad), bad)
        }
        XCTAssertThrowsError(try JSONDecoder().decode([TopRowStrategy].self, from: Data("[\"bogus\"]".utf8)))
    }

    // MARK: Repeat

    func testRepeatSchedule() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: 0.25, repeatInterval: 0.03))
        _ = press(&m, letterE, true, at: 0)
        XCTAssertEqual(m.nextDeadline ?? -1, 0.25, accuracy: 1e-9)
        let fired = run(&m, until: 0.32)
        XCTAssertEqual(fired.count, 3)
        for (i, expected) in [0.25, 0.28, 0.31].enumerated() {
            XCTAssertEqual(fired[i].0, expected, accuracy: 1e-9)
            XCTAssertEqual(fired[i].1, .key(code: letterE, down: true, flags: .nonCoalesced, autorepeat: true))
        }
        XCTAssertEqual(press(&m, letterE, false, at: 0.32), [.key(code: letterE, down: false, flags: .nonCoalesced, autorepeat: false)])
        XCTAssertNil(m.nextDeadline)
    }

    func testRepeatUsesCurrentFlags() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: 0.25, repeatInterval: 0.05))
        _ = press(&m, letterE, true, at: 0)
        _ = press(&m, lShift, true, at: 0.1)
        XCTAssertEqual(m.advance(to: 0.25, capsLockOn: true),
                       [.key(code: letterE, down: true, flags: [.nonCoalesced, .shift, .leftShift, .alphaShift], autorepeat: true)])
    }

    func testLateAdvanceFiresOnceAndKeepsCadence() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: 0.25, repeatInterval: 0.05, lease: 1))
        _ = press(&m, letterE, true, at: 0)
        XCTAssertEqual(m.advance(to: 0.42, capsLockOn: false).count, 1)
        XCTAssertEqual(m.nextDeadline ?? -1, 0.45, accuracy: 1e-9)
    }

    func testIntervalChangeMidHoldTakesEffectFromLastRepeat() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: 0.25, repeatInterval: 0.05, lease: 100))
        _ = press(&m, letterE, true, at: 0)
        var t = 0.0
        for _ in 0..<10 {
            t = m.nextDeadline!
            XCTAssertEqual(m.advance(to: t, capsLockOn: false).count, 1)
        }
        XCTAssertEqual(t, 0.70, accuracy: 1e-9)
        XCTAssertEqual(m.nextDeadline ?? -1, 0.75, accuracy: 1e-9)
        m.config.repeatInterval = 0.5
        XCTAssertEqual(m.nextDeadline ?? -1, 1.20, accuracy: 1e-9)
        XCTAssertEqual(m.advance(to: 1.20, capsLockOn: false).count, 1)
        XCTAssertEqual(m.nextDeadline ?? -1, 1.70, accuracy: 1e-9)

        // Shorter interval: next repeat one new interval after the last one, not in the past.
        m.config.repeatInterval = 0.03
        XCTAssertEqual(m.nextDeadline ?? -1, 1.23, accuracy: 1e-9)
        // A second change before the next repeat still counts from the last one (1.20).
        m.config.repeatInterval = 0.001
        XCTAssertEqual(m.nextDeadline ?? -1, 1.215, accuracy: 1e-9)
        // Unchanged clamped value (both clamp to 0.015) leaves the schedule alone.
        let before = m.nextDeadline
        m.config.repeatInterval = 0.0001
        XCTAssertEqual(m.nextDeadline, before)
    }

    func testIntervalChangeBeforeFirstRepeatKeepsDelay() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: 0.25, repeatInterval: 0.05))
        _ = press(&m, letterE, true, at: 0)
        m.config.repeatInterval = 0.1
        XCTAssertEqual(m.nextDeadline ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(m.advance(to: 0.25, capsLockOn: false).count, 1)
        XCTAssertEqual(m.nextDeadline ?? -1, 0.35, accuracy: 1e-9)
    }

    func testLateOnGridAdvanceNeverFiresTwiceAtSameTime() {
        var rng = SplitMix(seed: 42)
        for _ in 0..<2000 {
            let delay = 0.1 + rng.unit() * 0.5, interval = 0.015 + rng.unit() * 0.1
            var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: delay, repeatInterval: interval, lease: 100))
            _ = press(&m, letterE, true, at: 0)
            let k = Double(1 + Int(rng.unit() * 20))
            let now = delay + k * interval
            XCTAssertEqual(m.advance(to: now, capsLockOn: false).count, 1)
            XCTAssertEqual(m.advance(to: now, capsLockOn: false), [], "delay \(delay) interval \(interval) k \(k)")
            XCTAssertGreaterThan(m.nextDeadline ?? -1, now)
        }
    }

    func testAbsurdTimeGapDoesNotTrap() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: 0.25, repeatInterval: 0.05, lease: .infinity))
        _ = press(&m, letterE, true, at: 0)
        XCTAssertEqual(m.advance(to: 1e300, capsLockOn: false).count, 1)
        XCTAssertNotNil(m.nextDeadline)
        XCTAssertTrue(m.nextDeadline!.isFinite)
        _ = m.advance(to: .infinity, capsLockOn: false)
        XCTAssertTrue(m.nextDeadline.map(\.isFinite) ?? true)
    }

    func testNonFiniteConfigFallsBackToDefaults() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: 0.25, repeatInterval: .nan, lease: .nan,
                                                           capsDelay: .nan, capsSwitchHold: .nan, fnTapMax: .nan))
        _ = press(&m, letterE, true, at: 0)
        XCTAssertEqual(m.nextDeadline ?? -1, 0.25, accuracy: 1e-9)
        m.frameReceived(at: 0.2)
        XCTAssertEqual(m.advance(to: 0.25, capsLockOn: false).count, 1)
        XCTAssertEqual(m.nextDeadline ?? -1, 0.333, accuracy: 1e-9)
        _ = press(&m, letterE, false, at: 0.3)

        _ = press(&m, caps, true, at: 1)
        XCTAssertEqual(m.nextDeadline ?? -1, 1.075, accuracy: 1e-9)
        XCTAssertEqual(m.advance(to: 1.075, capsLockOn: false), [.setCapsLock(true)])
        _ = press(&m, caps, false, at: 1.2, capsOn: true)

        m.config.capsMode = .switchesInputSource
        _ = press(&m, caps, true, at: 2)
        XCTAssertEqual(m.nextDeadline ?? -1, 2.5, accuracy: 1e-9)
        _ = press(&m, caps, false, at: 2.1)

        m.config.fnTapAction = .changeInputSource
        _ = press(&m, fn, true, at: 3)
        XCTAssertEqual(press(&m, fn, false, at: 3.2), [.flagsChanged(code: fn, flags: .nonCoalesced), .symbolicHotKey(60)])
    }

    func testRepeatLastKeyOnlyNoResume() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: 0.25, repeatInterval: 0.05))
        _ = press(&m, letterE, true, at: 0)
        _ = press(&m, 15, true, at: 0.1)
        let fired = run(&m, until: 0.4)
        XCTAssertFalse(fired.isEmpty)
        XCTAssertTrue(fired.allSatisfy { $0.1 == .key(code: 15, down: true, flags: .nonCoalesced, autorepeat: true) })
        XCTAssertEqual(fired.first?.0 ?? -1, 0.35, accuracy: 1e-9)
        _ = press(&m, 15, false, at: 0.4)
        XCTAssertNil(m.nextDeadline)
        XCTAssertTrue(run(&m, until: 2).isEmpty)
        XCTAssertEqual(m.heldPhysicalCodes, [letterE])
    }

    func testLeasePausesAndResumesWithoutBurst() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: 0.25, repeatInterval: 0.05, lease: 0.25))
        _ = press(&m, letterE, true, at: 0)
        m.frameReceived(at: 0.22)
        var fireTimes: [TimeInterval] = []
        // Frames stop at 0.22: repeats until 0.47, then the lease lapses and the slot pauses.
        while let t = m.nextDeadline, t < 1.5 {
            let actions = m.advance(to: t, capsLockOn: false)
            if !actions.isEmpty { fireTimes.append(t) }
        }
        XCTAssertEqual(fireTimes.count, 5)
        XCTAssertEqual(fireTimes.last ?? -1, 0.45, accuracy: 1e-9)
        XCTAssertNil(m.nextDeadline)
        XCTAssertEqual(m.advance(to: 1.5, capsLockOn: false), [])

        m.frameReceived(at: 2.0)
        XCTAssertEqual(m.nextDeadline ?? -1, 2.05, accuracy: 1e-9)
        XCTAssertEqual(m.advance(to: m.nextDeadline!, capsLockOn: false),
                       [.key(code: letterE, down: true, flags: .nonCoalesced, autorepeat: true)])
        XCTAssertEqual(m.nextDeadline ?? -1, 2.10, accuracy: 1e-9)
    }

    func testVolumeRepeatsF8DoesNot() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: 0.25, repeatInterval: 0.05))
        var actions = press(&m, f12, true, at: 0)
        actions += run(&m, until: 1.0).map(\.1)
        actions += press(&m, f12, false, at: 1.0)
        XCTAssertEqual(actions.filter { $0 == .topRow(.volumeUp, down: true, autorepeat: false, flags: .nonCoalesced) }.count, 1)
        XCTAssertEqual(actions.filter { $0 == .topRow(.volumeUp, down: true, autorepeat: true, flags: .nonCoalesced) }.count, 15)
        XCTAssertEqual(actions.last, .topRow(.volumeUp, down: false, autorepeat: false, flags: .nonCoalesced))

        _ = press(&m, f8, true, at: 2)
        XCTAssertNil(m.nextDeadline)
        XCTAssertTrue(run(&m, until: 3).isEmpty)
    }

    func testFnF8KeyLayerRepeats() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: 0.25, repeatInterval: 0.05))
        _ = press(&m, fn, true, at: 0)
        _ = press(&m, f8, true, at: 0.01)
        XCTAssertEqual(m.advance(to: 0.26, capsLockOn: false),
                       [.key(code: f8, down: true, flags: [.nonCoalesced, .secondaryFn], autorepeat: true)])
    }

    func testModifiersCapsFnNeverRepeat() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: 0.25, repeatInterval: 0.05))
        for (i, code) in [lShift, lCtl, rAlt, lCmd, rCmd, fn, 60, 62, 58].enumerated() {
            _ = press(&m, code, true, at: Double(i) * 0.01)
        }
        XCTAssertNil(m.nextDeadline)
        _ = press(&m, caps, true, at: 0.1)
        // Only the Caps Lock activation deadline is pending; no repeats ever.
        XCTAssertEqual(m.nextDeadline ?? -1, 0.175, accuracy: 1e-9)
        let fired = run(&m, until: 3).map(\.1)
        XCTAssertEqual(fired, [.setCapsLock(true)])
        XCTAssertNil(m.nextDeadline)
    }

    func testFnTranslatedKeyRepeatsAfterFnRelease() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: 0.25, repeatInterval: 0.05))
        _ = press(&m, fn, true, at: 0)
        _ = press(&m, delete, true, at: 0.05)
        _ = press(&m, fn, false, at: 0.1)
        XCTAssertEqual(m.advance(to: 0.30, capsLockOn: false),
                       [.key(code: 117, down: true, flags: [.nonCoalesced, .secondaryFn], autorepeat: true)])
    }

    func testRepeatOffWhenDelayNil() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: nil))
        _ = press(&m, letterE, true, at: 0)
        XCTAssertNil(m.nextDeadline)
        XCTAssertTrue(run(&m, until: 3).isEmpty)

        m.config.repeatDelay = 2.5
        _ = press(&m, 15, true, at: 4)
        XCTAssertNil(m.nextDeadline)
    }

    func testRepeatClamps() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: 0.01, repeatInterval: 0.001, lease: 10))
        _ = press(&m, letterE, true, at: 0)
        XCTAssertEqual(m.nextDeadline ?? -1, 0.1, accuracy: 1e-9)
        _ = m.advance(to: 0.1, capsLockOn: false)
        XCTAssertEqual(m.nextDeadline ?? -1, 0.115, accuracy: 1e-9)
    }

    func testRepeatTurnedOffMidHoldStops() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: 0.25, repeatInterval: 0.05))
        _ = press(&m, letterE, true, at: 0)
        m.config.repeatDelay = nil
        XCTAssertEqual(m.advance(to: 0.25, capsLockOn: false), [])
        XCTAssertNil(m.nextDeadline)
    }

    func testDuplicateDownIgnored() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(repeatDelay: 0.25, repeatInterval: 0.05))
        _ = press(&m, letterE, true, at: 0)
        XCTAssertEqual(press(&m, letterE, true, at: 0.1), [])
        XCTAssertEqual(m.nextDeadline ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(press(&m, lShift, false, at: 0.15), [])
        XCTAssertEqual(press(&m, letterE, false, at: 0.2).count, 1)
        XCTAssertEqual(press(&m, letterE, false, at: 0.3), [])
    }

    // MARK: releaseAll

    func testReleaseAllOrderTranslated() {
        var m = MacKeyboardModel()
        _ = press(&m, lShift, true, at: 0)
        _ = press(&m, fn, true, at: 0.01)
        _ = press(&m, down, true, at: 0.02)
        _ = press(&m, f12, true, at: 0.03)   // fn held, fnState false → key layer F12
        _ = press(&m, letterE, true, at: 0.04)
        _ = press(&m, lCmd, true, at: 0.05)
        let held: ModifierFlags = [.nonCoalesced, .shift, .leftShift, .secondaryFn, .command, .leftCommand]
        XCTAssertEqual(m.releaseAll(capsLockOn: false), [
            .key(code: letterE, down: false, flags: held, autorepeat: false),
            .key(code: f12, down: false, flags: held, autorepeat: false),
            .key(code: 121, down: false, flags: held, autorepeat: false),
            .flagsChanged(code: lCmd, flags: [.nonCoalesced, .shift, .leftShift, .secondaryFn]),
            .flagsChanged(code: lShift, flags: [.nonCoalesced, .secondaryFn]),
            .flagsChanged(code: fn, flags: .nonCoalesced)
        ])
        XCTAssertTrue(m.heldPhysicalCodes.isEmpty)
        XCTAssertNil(m.nextDeadline)
        XCTAssertEqual(press(&m, down, false, at: 0.1), [])
    }

    func testReleaseAllTopRowActionsAndVirtualCaps() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(capsMode: .virtual))
        _ = press(&m, caps, true, at: 0)
        _ = press(&m, f12, true, at: 0.01)
        _ = press(&m, 122, true, at: 0.02)
        _ = press(&m, 1, true, at: 0.03)
        let flags: ModifierFlags = [.nonCoalesced, .alphaShift]
        XCTAssertEqual(m.releaseAll(capsLockOn: false), [
            .key(code: 1, down: false, flags: flags, autorepeat: false),
            .topRow(.brightnessDown, down: false, autorepeat: false, flags: flags),
            .topRow(.volumeUp, down: false, autorepeat: false, flags: flags),
            .flagsChanged(code: caps, flags: .nonCoalesced)
        ])
        XCTAssertEqual(m.currentFlags(capsLockOn: false), .nonCoalesced)
    }

    func testReleaseAllDiscardsPendingCapsAndFnTap() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(fnTapAction: .changeInputSource))
        _ = press(&m, caps, true, at: 0)
        _ = press(&m, fn, true, at: 0.01)
        XCTAssertEqual(m.releaseAll(capsLockOn: false), [.flagsChanged(code: fn, flags: .nonCoalesced)])
        XCTAssertNil(m.nextDeadline)
        XCTAssertEqual(m.advance(to: 1, capsLockOn: false), [])
        XCTAssertEqual(press(&m, caps, false, at: 1.1), [])
    }

    // MARK: Caps through the model

    func testVirtualCapsFlagsChangedCarriesHeldModifiers() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(capsMode: .virtual))
        _ = press(&m, lShift, true, at: 0)
        XCTAssertEqual(press(&m, caps, true, at: 0.1),
                       [.flagsChanged(code: caps, flags: [.nonCoalesced, .shift, .leftShift, .alphaShift])])
        XCTAssertEqual(press(&m, caps, false, at: 0.2), [])
        // System lock state is ignored in virtual mode.
        XCTAssertEqual(press(&m, letterE, true, at: 0.3, capsOn: false).first.flatMap(flags),
                       [.nonCoalesced, .shift, .leftShift, .alphaShift])
    }

    func testSystemCapsViaModelUsesSenderTime() {
        var m = MacKeyboardModel()
        XCTAssertEqual(press(&m, caps, true, at: 0, sender: 10), [])
        XCTAssertTrue(m.heldPhysicalCodes.contains(caps))
        XCTAssertEqual(press(&m, caps, false, at: 0.005, sender: 10.12), [.setCapsLock(true)])
    }

    func testConfigCapsModeChangeAppliesToController() {
        var m = MacKeyboardModel()
        m.config.capsMode = .switchesInputSource
        _ = press(&m, caps, true, at: 0)
        XCTAssertEqual(press(&m, caps, false, at: 0.1), [.symbolicHotKey(60)])
    }

    // MARK: fn tap

    func testFnTapChangeInputSource() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(fnTapAction: .changeInputSource))
        _ = press(&m, fn, true, at: 0)
        XCTAssertEqual(press(&m, fn, false, at: 0.2),
                       [.flagsChanged(code: fn, flags: .nonCoalesced), .symbolicHotKey(60)])
    }

    func testFnTapTooLongIsNotTap() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(fnTapAction: .changeInputSource))
        _ = press(&m, fn, true, at: 0, sender: 5)
        // The sender's own duration decides when present: 0.6 s > fnTapMax.
        XCTAssertEqual(press(&m, fn, false, at: 0.2, sender: 5.6), [.flagsChanged(code: fn, flags: .nonCoalesced)])
        _ = press(&m, fn, true, at: 1)
        XCTAssertEqual(press(&m, fn, false, at: 1.6), [.flagsChanged(code: fn, flags: .nonCoalesced)])
    }

    func testFnWithKeyIsNotTap() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(fnTapAction: .changeInputSource))
        _ = press(&m, fn, true, at: 0)
        _ = press(&m, left, true, at: 0.05)
        _ = press(&m, left, false, at: 0.1)
        XCTAssertEqual(press(&m, fn, false, at: 0.2), [.flagsChanged(code: fn, flags: .nonCoalesced)])

        // A key released (pressed before fn) while fn is down also cancels the tap.
        _ = press(&m, letterE, true, at: 1)
        _ = press(&m, fn, true, at: 1.05)
        _ = press(&m, letterE, false, at: 1.1)
        XCTAssertEqual(press(&m, fn, false, at: 1.2), [.flagsChanged(code: fn, flags: .nonCoalesced)])

        // A modifier pressed with fn cancels it too.
        _ = press(&m, fn, true, at: 2)
        _ = press(&m, lShift, true, at: 2.05)
        XCTAssertEqual(press(&m, fn, false, at: 2.1), [.flagsChanged(code: fn, flags: [.nonCoalesced, .shift, .leftShift])])
    }

    func testFnTapNone() {
        var m = MacKeyboardModel()
        _ = press(&m, fn, true, at: 0)
        XCTAssertEqual(press(&m, fn, false, at: 0.1), [.flagsChanged(code: fn, flags: .nonCoalesced)])
    }

    func testFnTapEmoji() {
        var m = MacKeyboardModel(config: MacKeyboardConfig(fnTapAction: .emojiAndSymbols))
        _ = press(&m, fn, true, at: 0)
        XCTAssertEqual(press(&m, fn, false, at: 0.1),
                       [.flagsChanged(code: fn, flags: .nonCoalesced), .shortcut(keyCode: 49, modifierMask: 0x140000)])
    }

    func testConfigDefaultsMatchMemberwiseDefaults() {
        XCTAssertEqual(MacKeyboardConfig(), MacKeyboardConfig(fnKeysStandard: false))
        let c = MacKeyboardConfig()
        XCTAssertEqual(c.repeatDelay, 0.5)
        XCTAssertEqual(c.repeatInterval, 0.083)
        XCTAssertEqual(c.lease, 0.25)
        XCTAssertEqual(c.capsMode, .system)
        XCTAssertEqual(c.fnTapAction, .none)
    }

    // MARK: Helpers

    private func code(_ action: KeyboardAction) -> UInt16? {
        if case .key(let c, _, _, _) = action { return c }
        return nil
    }

    private func flags(_ action: KeyboardAction) -> ModifierFlags? {
        if case .key(_, _, let f, _) = action { return f }
        return nil
    }
}

/// Deterministic generator for sweep tests.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func unit() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
