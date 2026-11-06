import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import IKeyCore

final class InjectorCoreTests: XCTestCase {
    private let nc = ModifierFlags.nonCoalesced
    private let lctrl: ModifierFlags = [.nonCoalesced, .control, .leftControl]
    private let lshift: ModifierFlags = [.nonCoalesced, .shift, .leftShift]
    private let display = CGRect(x: 0, y: 0, width: 1470, height: 956)
    private lazy var env = PointerEnvironment(cursor: CGPoint(x: 500, y: 400), displays: [display], capsLockOn: false)

    // MARK: - Helpers

    private func send(_ core: inout InjectorCore, _ input: PadInput, at t: TimeInterval,
                      env: PointerEnvironment? = nil) -> [SynthEvent] {
        core.handle(.input(input, t: Int64((t * 1e6).rounded())), at: t, env: env ?? self.env)
    }

    private func key(_ core: inout InjectorCore, _ code: UInt16, _ down: Bool, at t: TimeInterval,
                     env: PointerEnvironment? = nil) -> [SynthEvent] {
        quiet(send(&core, .key(code: code, down: down), at: t, env: env))
    }

    private func heartbeat(_ core: inout InjectorCore, held: [UInt16], buttons: [PointerButton] = [],
                           at t: TimeInterval) -> [SynthEvent] {
        core.handle(.heartbeat(Heartbeat(seq: 1, held: held, buttons: buttons, active: !held.isEmpty),
                               t: Int64((t * 1e6).rounded())), at: t, env: env)
    }

    private func quiet(_ events: [SynthEvent]) -> [SynthEvent] { events.filter { $0 != .declareUserActivity } }

    private func scrollInput(_ phase: WireScrollPhase, dy: Double = 0, releaseVY: Double? = nil) -> PadInput {
        .scroll(ScrollMotion(phase: phase, dx: 0, dy: dy, dt: 1.0 / 120, speed: 100, releaseVX: 0, releaseVY: releaseVY))
    }

    private func frames(_ events: [SynthEvent]) -> [ScrollFrame] {
        events.compactMap { if case .scroll(let f, _) = $0 { return f } else { return nil } }
    }

    private func moves(_ events: [SynthEvent]) -> [(to: CGPoint, dx: Int64, dy: Int64, drag: PointerButton?)] {
        events.compactMap {
            if case let .mouseMove(to, dx, dy, drag, _) = $0 { return (to, dx, dy, drag) } else { return nil }
        }
    }

    /// Ticks at each deadline up to `limit`; returns everything posted.
    private func drain(_ core: inout InjectorCore, until limit: TimeInterval = 60) -> [SynthEvent] {
        var events: [SynthEvent] = []
        var n = 0
        while let d = core.nextDeadline, d <= limit, n < 100_000 {
            events += core.tick(at: d, env: env)
            n += 1
        }
        return events
    }

    private func hotKeys(_ entries: [String: (keyCode: Int, mods: Int, enabled: Bool)]) -> SymbolicHotKeys {
        SymbolicHotKeys(plist: entries.mapValues { e in
            ["enabled": e.enabled, "value": ["parameters": [65535, e.keyCode, e.mods], "type": "standard"]] as [String: Any]
        })
    }

    private func chord(_ code: UInt16, modifier: UInt16, modFlags: ModifierFlags, keyFlags: ModifierFlags,
                       base: ModifierFlags = .nonCoalesced) -> [SynthEvent] {
        [.flagsChanged(code: modifier, flags: base.union(modFlags)),
         .key(code: code, down: true, flags: keyFlags, autorepeat: false),
         .key(code: code, down: false, flags: keyFlags, autorepeat: false),
         .flagsChanged(code: modifier, flags: base)]
    }

    private func settings(_ change: (inout InjectorSettings) -> Void) -> InjectorSettings {
        var s = InjectorSettings()
        change(&s)
        return s
    }

    // MARK: - Keyboard

    func testCtrlUpChordFlags() {
        var core = InjectorCore()
        XCTAssertEqual(key(&core, 59, true, at: 0), [.flagsChanged(code: 59, flags: lctrl)])
        let up = key(&core, 126, true, at: 0.05)
        XCTAssertEqual(up, [.key(code: 126, down: true, flags: ModifierFlags(rawValue: 0xA40000 | 0x1 | 0x100), autorepeat: false)])
        _ = key(&core, 126, false, at: 0.1)
        _ = key(&core, 59, false, at: 0.15)

        // The Mission Control hot key (Ctrl+Up, mask fn|ctrl) as a chord: the arrow carries fn itself.
        let swipe = quiet(send(&core, .gesture(WireGesture(kind: .swipe, fingers: 3, direction: "up")), at: 1))
        let keyFlags = ModifierFlags(rawValue: 0xA40000 | 0x1 | 0x100)
        XCTAssertEqual(swipe, chord(126, modifier: 59, modFlags: [.control, .leftControl], keyFlags: keyFlags))
    }

    func testTopRowF12AuxDefault() {
        var core = InjectorCore()
        XCTAssertEqual(key(&core, 111, true, at: 0), [.aux(nxKeyType: 0, down: true, autorepeat: false, flags: nc)])
        XCTAssertEqual(key(&core, 111, false, at: 0.1), [.aux(nxKeyType: 0, down: false, autorepeat: false, flags: nc)])

        // fn+F12 is the plain F12 key with SecondaryFn.
        _ = key(&core, 63, true, at: 1)
        XCTAssertEqual(key(&core, 111, true, at: 1.05),
                       [.key(code: 111, down: true, flags: [.nonCoalesced, .secondaryFn], autorepeat: false)])
        _ = key(&core, 111, false, at: 1.1)
        _ = key(&core, 63, false, at: 1.15)

        // fnState on reverses the layers.
        core.update(settings: settings { $0.prefs.fnKeysStandard = true })
        XCTAssertEqual(key(&core, 111, true, at: 2),
                       [.key(code: 111, down: true, flags: [.nonCoalesced, .secondaryFn], autorepeat: false)])
        _ = key(&core, 111, false, at: 2.1)
        _ = key(&core, 63, true, at: 3)
        XCTAssertEqual(key(&core, 111, true, at: 3.05),
                       [.aux(nxKeyType: 0, down: true, autorepeat: false, flags: [.nonCoalesced, .secondaryFn])])
    }

    func testTopRowHotKeyFallbackSkipsDisabled() {
        // A chosen hot key that is disabled on the Mac falls back to the default chain.
        var s = settings {
            $0.topRowChoices[.missionControl] = .hotKey(32)
            $0.topRowChoices[.spotlight] = .hotKey(64)
            $0.hotKeys = hotKeys(["32": (126, 0x840000, false), "64": (65535, 0, true)])
        }
        var core = InjectorCore(settings: s)
        XCTAssertEqual(key(&core, 99, true, at: 0),
                       [.key(code: 160, down: true, flags: [.nonCoalesced, .secondaryFn], autorepeat: false)])
        XCTAssertEqual(key(&core, 99, false, at: 0.1),
                       [.key(code: 160, down: false, flags: [.nonCoalesced, .secondaryFn], autorepeat: false)])
        // Unassigned (65535) Spotlight shortcut → the Spotlight key code.
        XCTAssertEqual(key(&core, 118, true, at: 0.2), [.key(code: 129, down: true, flags: nc, autorepeat: false)])
        _ = key(&core, 118, false, at: 0.3)

        // Enabled: the chosen hot key posts its chord on the down only.
        s.hotKeys = hotKeys(["32": (126, 0x840000, true)])
        core.update(settings: s)
        let keyFlags = ModifierFlags(rawValue: 0xA40000 | 0x1 | 0x100)
        XCTAssertEqual(key(&core, 99, true, at: 1), chord(126, modifier: 59, modFlags: [.control, .leftControl], keyFlags: keyFlags))
        XCTAssertEqual(key(&core, 99, false, at: 1.1), [])
    }

    func testTopRowStrategyKeptFromDownToUp() {
        var core = InjectorCore()
        _ = key(&core, 111, true, at: 0)
        core.update(settings: settings { $0.topRowChoices[.volumeUp] = .keyCode(72, secondaryFn: false) })
        XCTAssertEqual(key(&core, 111, false, at: 0.1), [.aux(nxKeyType: 0, down: false, autorepeat: false, flags: nc)])
        XCTAssertEqual(key(&core, 111, true, at: 1), [.key(code: 72, down: true, flags: nc, autorepeat: false)])
    }

    func testOpenApplicationStrategyOnDownOnly() {
        let path = "/System/Applications/Mission Control.app"
        var core = InjectorCore(settings: settings { $0.topRowChoices[.missionControl] = .openApplication(path) })
        XCTAssertEqual(key(&core, 99, true, at: 0), [.openApplication(path: path)])
        XCTAssertEqual(key(&core, 99, false, at: 0.1), [])
    }

    func testFnArrowHome() {
        var core = InjectorCore()
        XCTAssertEqual(key(&core, 63, true, at: 0), [.flagsChanged(code: 63, flags: [.nonCoalesced, .secondaryFn])])
        XCTAssertEqual(key(&core, 123, true, at: 0.05),
                       [.key(code: 115, down: true, flags: [.nonCoalesced, .secondaryFn], autorepeat: false)])
        XCTAssertEqual(key(&core, 63, false, at: 0.1), [.flagsChanged(code: 63, flags: nc)])
        XCTAssertEqual(key(&core, 123, false, at: 0.15),
                       [.key(code: 115, down: false, flags: [.nonCoalesced, .secondaryFn], autorepeat: false)])
    }

    func testMacRepeatViaTick() {
        var core = InjectorCore(settings: settings {
            $0.prefs.keyRepeatDelay = 0.3
            $0.prefs.keyRepeatInterval = 0.05
        })
        XCTAssertEqual(key(&core, 14, true, at: 0), [.key(code: 14, down: true, flags: nc, autorepeat: false)])
        // Heartbeats every 100 ms keep the lease alive; ticks run at each deadline.
        var repeats: [TimeInterval] = []
        var nextBeat = 0.1
        while let d = core.nextDeadline, d < 0.99 {
            while nextBeat <= d {
                XCTAssertEqual(heartbeat(&core, held: [14], at: nextBeat), [])
                nextBeat += 0.1
            }
            for e in core.tick(at: d, env: env) {
                XCTAssertEqual(e, .key(code: 14, down: true, flags: nc, autorepeat: true))
                repeats.append(d)
            }
        }
        XCTAssertEqual(repeats.first ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertEqual(repeats.count, 14) // 0.30, 0.35, ..., 0.95
        XCTAssertEqual(key(&core, 14, false, at: 1.0), [.key(code: 14, down: false, flags: nc, autorepeat: false)])
        XCTAssertNil(core.nextDeadline)
    }

    func testLeaseStopsRepeat() {
        var core = InjectorCore()
        _ = key(&core, 51, true, at: 0)
        XCTAssertEqual(core.nextDeadline ?? -1, 0.5, accuracy: 1e-9)
        // No frame since the down: the repeat pauses instead of firing.
        XCTAssertEqual(core.tick(at: 0.5, env: env), [])
        XCTAssertNil(core.nextDeadline)
        // The next frame resumes one interval later.
        _ = heartbeat(&core, held: [51], at: 0.8)
        XCTAssertEqual(core.nextDeadline ?? -1, 0.883, accuracy: 1e-9)
        XCTAssertEqual(core.tick(at: 0.883, env: env), [.key(code: 51, down: true, flags: nc, autorepeat: true)])
    }

    func testDeadManReleasesAfter1sWhenConfigured() {
        var plain = InjectorCore()
        _ = key(&plain, 56, true, at: 0)
        XCTAssertNil(plain.nextDeadline)
        XCTAssertEqual(plain.tick(at: 5, env: env), [])
        XCTAssertTrue(plain.hasHeldInput)

        var core = InjectorCore(settings: settings { $0.deadManTimeout = 1 })
        _ = key(&core, 56, true, at: 0)
        XCTAssertEqual(core.nextDeadline ?? -1, 1.0, accuracy: 1e-9)
        _ = heartbeat(&core, held: [56], at: 0.5)
        XCTAssertEqual(core.nextDeadline ?? -1, 1.5, accuracy: 1e-9)
        XCTAssertEqual(core.tick(at: 1.4, env: env), [])
        XCTAssertEqual(core.tick(at: 1.5, env: env), [.flagsChanged(code: 56, flags: nc)])
        XCTAssertFalse(core.hasHeldInput)
        XCTAssertNil(core.nextDeadline)
    }

    func testUpdateKeepsHeldStateAndAppliesRepeatPrefs() {
        var core = InjectorCore()
        _ = key(&core, 56, true, at: 0)
        _ = key(&core, 0, true, at: 0.01)
        core.update(settings: settings { $0.prefs.keyRepeatDelay = nil })
        XCTAssertTrue(core.hasHeldInput)
        XCTAssertEqual(core.tick(at: 0.6, env: env), [])
        XCTAssertEqual(key(&core, 0, false, at: 0.7), [.key(code: 0, down: false, flags: lshift, autorepeat: false)])
        XCTAssertEqual(key(&core, 56, false, at: 0.8), [.flagsChanged(code: 56, flags: nc)])
    }

    // MARK: - Caps Lock and input sources

    func testCapsSystemSetEvent() {
        var core = InjectorCore()
        // A 40 ms tap does nothing.
        XCTAssertEqual(key(&core, 57, true, at: 0), [])
        XCTAssertEqual(key(&core, 57, false, at: 0.04), [])
        // Held past 75 ms: the deadline turns Caps Lock on.
        _ = key(&core, 57, true, at: 1)
        XCTAssertEqual(core.nextDeadline ?? -1, 1.075, accuracy: 1e-9)
        XCTAssertEqual(core.tick(at: 1.075, env: env), [.setCapsLock(true)])
        XCTAssertEqual(key(&core, 57, false, at: 1.1), [])
        // While on, a press turns it off at once.
        var on = env
        on.capsLockOn = true
        XCTAssertEqual(key(&core, 57, true, at: 2, env: on), [.setCapsLock(false)])
        // Mouse and key events carry the lock flag.
        XCTAssertEqual(key(&core, 0, true, at: 2.1, env: on),
                       [.key(code: 0, down: true, flags: [.nonCoalesced, .alphaShift], autorepeat: false)])
    }

    /// The input-source switch, with the Mac's ^Space shortcut as the poster's fallback.
    private var ctrlSpaceSwitch: SynthEvent {
        .selectPreviousInputSource(fallback: chord(49, modifier: 59, modFlags: [.control, .leftControl], keyFlags: lctrl))
    }

    func testCapsSwitchModeTapPostsCtrlSpaceChord() {
        var core = InjectorCore(settings: settings { $0.capsMode = .switchesInputSource })
        XCTAssertEqual(key(&core, 57, true, at: 0), [])
        XCTAssertEqual(key(&core, 57, false, at: 0.1), [ctrlSpaceSwitch])
        // A long hold toggles Caps Lock instead.
        _ = key(&core, 57, true, at: 1)
        XCTAssertEqual(core.tick(at: 1.5, env: env), [.setCapsLock(true)])
        XCTAssertEqual(key(&core, 57, false, at: 1.6), [])
    }

    func testFnTapChangeInputSourceChord() {
        var core = InjectorCore(settings: settings { $0.fnTapAction = .changeInputSource })
        _ = key(&core, 63, true, at: 0)
        XCTAssertEqual(key(&core, 63, false, at: 0.2), [.flagsChanged(code: 63, flags: nc), ctrlSpaceSwitch])
        // A disabled 'previous input source' shortcut still switches; only the fallback is empty.
        core.update(settings: settings {
            $0.fnTapAction = .changeInputSource
            $0.hotKeys = hotKeys(["60": (49, 0x40000, false)])
        })
        _ = key(&core, 63, true, at: 1)
        XCTAssertEqual(key(&core, 63, false, at: 1.2),
                       [.flagsChanged(code: 63, flags: nc), .selectPreviousInputSource(fallback: [])])
    }

    // MARK: - Key remapping (the user's Mac remap: left ⌘ → Caps Lock, Caps Lock → Escape)

    private var userRemap: InjectorSettings {
        settings {
            $0.keyRemap = [55: 57, 57: 53]
            $0.capsMode = .switchesInputSource
        }
    }

    func testRemapLeftCommandTapSwitchesInputSourceWithoutCommand() {
        var core = InjectorCore(settings: userRemap)
        let down = key(&core, 55, true, at: 0)
        XCTAssertEqual(down, [])
        let up = key(&core, 55, false, at: 0.1)
        XCTAssertEqual(up, [ctrlSpaceSwitch])
        let posted = (down + up).flatMap { event -> [SynthEvent] in
            if case .selectPreviousInputSource(let fallback) = event { return fallback }
            return [event]
        }
        for event in posted {
            if case .flagsChanged(55, _) = event { XCTFail("left command posted") }
            if case let .key(_, _, flags, _) = event { XCTAssertFalse(flags.contains(.command)) }
        }
        // A hold toggles Caps Lock, as on the remapped MacBook.
        _ = key(&core, 55, true, at: 1)
        XCTAssertEqual(core.tick(at: 1.5, env: env), [.setCapsLock(true)])
    }

    /// macOS switches on a Caps Lock tap whether or not the ^Space shortcut is enabled, so the
    /// remapped left Command must too.
    func testRemapTapSwitchesWithHotKey60DisabledOrUnassigned() {
        for entry in [(keyCode: 49, mods: 0x40000, enabled: false), (keyCode: 65535, mods: 0, enabled: true)] {
            var s = userRemap
            s.hotKeys = hotKeys(["60": entry])
            var core = InjectorCore(settings: s)
            XCTAssertEqual(key(&core, 55, true, at: 0), [])
            XCTAssertEqual(key(&core, 55, false, at: 0.1), [.selectPreviousInputSource(fallback: [])])
        }
    }

    /// A held Shift does not stop the switch. The fallback lifts it, posts ^Space with only its
    /// own flags and presses Shift again, so the held state is unchanged afterwards.
    func testRemapTapSwitchesWithShiftHeld() {
        var core = InjectorCore(settings: userRemap)
        XCTAssertEqual(key(&core, 56, true, at: 0), [.flagsChanged(code: 56, flags: lshift)])
        XCTAssertEqual(key(&core, 55, true, at: 0.1), [])
        XCTAssertEqual(key(&core, 55, false, at: 0.2),
                       [.selectPreviousInputSource(fallback: [.flagsChanged(code: 56, flags: nc)]
                           + chord(49, modifier: 59, modFlags: [.control, .leftControl], keyFlags: lctrl)
                           + [.flagsChanged(code: 56, flags: lshift)])])
        XCTAssertEqual(key(&core, 0, true, at: 0.3), [.key(code: 0, down: true, flags: lshift, autorepeat: false)])
    }

    /// A held Command must not turn the fallback ^Space into ^⌘Space (Emoji & Symbols): held
    /// modifiers are lifted in reverse chord order and pressed again in chord order.
    func testInputSourceFallbackExcludesHeldCommandAndRestoresIt() {
        var core = InjectorCore(settings: userRemap)
        let rcmd: ModifierFlags = [.nonCoalesced, .command, .rightCommand]
        let both = rcmd.union(lshift)
        XCTAssertEqual(key(&core, 56, true, at: 0), [.flagsChanged(code: 56, flags: lshift)])
        XCTAssertEqual(key(&core, 54, true, at: 0.05), [.flagsChanged(code: 54, flags: both)])
        XCTAssertEqual(key(&core, 55, true, at: 0.1), [])
        let up = key(&core, 55, false, at: 0.2)
        guard up.count == 1, case .selectPreviousInputSource(let fallback) = up[0] else {
            return XCTFail("expected one input-source switch, got \(up)")
        }
        XCTAssertEqual(fallback,
                       [.flagsChanged(code: 54, flags: lshift), .flagsChanged(code: 56, flags: nc)]
                           + chord(49, modifier: 59, modFlags: [.control, .leftControl], keyFlags: lctrl)
                           + [.flagsChanged(code: 56, flags: lshift), .flagsChanged(code: 54, flags: both)])
        for event in fallback {
            if case let .key(_, _, flags, _) = event {
                XCTAssertFalse(flags.contains(.command))
                XCTAssertFalse(flags.contains(.shift))
            }
        }
        // The held state is back: a key still carries Shift+Command, and the releases match.
        XCTAssertEqual(key(&core, 0, true, at: 0.3), [.key(code: 0, down: true, flags: both, autorepeat: false)])
        _ = key(&core, 0, false, at: 0.35)
        XCTAssertEqual(key(&core, 54, false, at: 0.4), [.flagsChanged(code: 54, flags: lshift)])
        XCTAssertEqual(key(&core, 56, false, at: 0.45), [.flagsChanged(code: 56, flags: nc)])

        // The Caps Lock flag is a lock state, not a held key: it stays on every fallback event.
        var on = env
        on.capsLockOn = true
        let caps: ModifierFlags = [.nonCoalesced, .alphaShift]
        _ = key(&core, 54, true, at: 1, env: on)
        _ = key(&core, 55, true, at: 1.1, env: on)
        XCTAssertEqual(key(&core, 55, false, at: 1.2, env: on),
                       [.selectPreviousInputSource(fallback: [.flagsChanged(code: 54, flags: caps)]
                           + chord(49, modifier: 59, modFlags: [.control, .leftControl],
                                   keyFlags: caps.union(lctrl), base: caps)
                           + [.flagsChanged(code: 54, flags: caps.union(rcmd))])])
    }

    func testRemapCapsLockPostsEscape() {
        var core = InjectorCore(settings: userRemap)
        XCTAssertEqual(key(&core, 57, true, at: 0), [.key(code: 53, down: true, flags: nc, autorepeat: false)])
        XCTAssertEqual(key(&core, 57, false, at: 0.05), [.key(code: 53, down: false, flags: nc, autorepeat: false)])
        XCTAssertNil(core.nextDeadline)
    }

    func testRemapLeavesRightCommandAlone() {
        var core = InjectorCore(settings: userRemap)
        let rcmd: ModifierFlags = [.nonCoalesced, .command, .rightCommand]
        XCTAssertEqual(key(&core, 54, true, at: 0), [.flagsChanged(code: 54, flags: rcmd)])
        XCTAssertEqual(key(&core, 8, true, at: 0.05), [.key(code: 8, down: true, flags: rcmd, autorepeat: false)])
        _ = key(&core, 8, false, at: 0.1)
        XCTAssertEqual(key(&core, 54, false, at: 0.15), [.flagsChanged(code: 54, flags: nc)])
    }

    func testRemapChangeMidPressReleasesOriginalCode() {
        var core = InjectorCore(settings: userRemap)
        XCTAssertEqual(key(&core, 57, true, at: 0), [.key(code: 53, down: true, flags: nc, autorepeat: false)])
        core.update(settings: InjectorSettings())
        XCTAssertEqual(key(&core, 57, false, at: 0.1), [.key(code: 53, down: false, flags: nc, autorepeat: false)])
        XCTAssertFalse(core.hasHeldInput)
        // The new (empty) remap applies to the next press.
        XCTAssertEqual(key(&core, 57, true, at: 1), [])
        XCTAssertEqual(core.tick(at: 1.075, env: env), [.setCapsLock(true)])
    }

    func testTwoKeysRemappedToOneCodeReleaseWithTheLast() {
        var core = InjectorCore(settings: settings { $0.keyRemap = [57: 53] })
        XCTAssertEqual(key(&core, 57, true, at: 0), [.key(code: 53, down: true, flags: nc, autorepeat: false)])
        XCTAssertEqual(key(&core, 53, true, at: 0.05), [])
        XCTAssertEqual(key(&core, 57, false, at: 0.1), [])
        XCTAssertEqual(key(&core, 53, false, at: 0.15), [.key(code: 53, down: false, flags: nc, autorepeat: false)])
    }

    // MARK: - Pointer

    func testMotionAcceleratedAndDeltasSumExactly() {
        var core = InjectorCore()
        let expected = PointerAccelerator(index: 0.6875).apply(dxMM: 2, dyMM: -1, speed: 100)
        let m = moves(send(&core, .motion(PointerMotion(dx: 2, dy: -1, dt: 0.02, speed: 100)), at: 0))
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(Double(m[0].to.x), 500 + expected.dx, accuracy: 1e-9)
        XCTAssertEqual(Double(m[0].to.y), 400 + expected.dy, accuracy: 1e-9)
        XCTAssertGreaterThan(expected.dx / 2, 9) // ~9.4 pt/mm at 100 mm/s, not 1:1
        XCTAssertNil(m[0].drag)

        var cursor = VirtualCursor()
        var e = env
        var sum: Int64 = 0
        var last = CGPoint.zero
        for _ in 0..<1000 {
            let r = cursor.move(by: 0.03, dy: 0, env: e)
            sum += r.deltaX
            XCTAssertEqual(r.deltaY, 0)
            last = r.to
            e.cursor = r.to
        }
        XCTAssertEqual(sum, 30)
        XCTAssertEqual(Double(last.x), 530, accuracy: 1e-6)
    }

    func testLiveCurvesOverrideTable() {
        let linear = [HIDAccelCurve(index: 0, gl: 2, gp: 0, gc: 0, gq: 0, t1: 0, t2: 0)]
        var core = InjectorCore(settings: settings { $0.pointerCurves = linear })
        let motion = PadInput.motion(PointerMotion(dx: 3, dy: 0, dt: 0.02, speed: 150))
        let live = Double(moves(send(&core, motion, at: 0))[0].to.x) - 500
        let expected = PointerAccelerator(curves: linear, index: 0.6875).apply(dxMM: 3, dyMM: 0, speed: 150).dx
        XCTAssertEqual(live, expected, accuracy: 1e-9)
        XCTAssertNotEqual(live, PointerAccelerator(index: 0.6875).apply(dxMM: 3, dyMM: 0, speed: 150).dx, accuracy: 0.5)

        // A live tracking index overrides the preference.
        var fast = InjectorCore(settings: settings { $0.trackingIndexOverride = 3.0 })
        let gained = Double(moves(send(&fast, motion, at: 0))[0].to.x) - 500
        XCTAssertEqual(gained, PointerAccelerator(index: 3.0).apply(dxMM: 3, dyMM: 0, speed: 150).dx, accuracy: 1e-9)
    }

    func testResyncOnExternalJump50pt() {
        var cursor = VirtualCursor()
        var e = env
        let first = cursor.move(by: 10.4, dy: 0, env: e)
        XCTAssertEqual(Double(first.to.x), 510.4, accuracy: 1e-9)
        // The Mac reports a rounded position: within 1 pt the sub-point position is kept.
        e.cursor = CGPoint(x: 510, y: 400)
        XCTAssertEqual(Double(cursor.move(by: 0.3, dy: 0, env: e).to.x), 510.7, accuracy: 1e-9)
        // Another device moved the pointer 50 pt: continue from there.
        e.cursor = CGPoint(x: 560.7, y: 400)
        let r = cursor.move(by: 1, dy: 1, env: e)
        XCTAssertEqual(Double(r.to.x), 561.7, accuracy: 1e-9)
        XCTAssertEqual(Double(r.to.y), 401, accuracy: 1e-9)
    }

    /// The Mac may report the cursor before it has applied the last post (several frames in one
    /// receive callback): a lagging report must not pull the virtual cursor back.
    func testLaggingEnvDoesNotLoseMotion() {
        var cursor = VirtualCursor()
        let first = cursor.move(by: 36.3, dy: 0, env: env)
        let second = cursor.move(by: 36.3, dy: 0, env: env)
        XCTAssertEqual(Double(first.to.x), 536.3, accuracy: 1e-9)
        XCTAssertEqual(Double(second.to.x), 572.6, accuracy: 1e-9)
        XCTAssertEqual(first.deltaX + second.deltaX, 73)
        // Reports of any recent placement keep the virtual position.
        var e = env
        e.cursor = CGPoint(x: 536, y: 400)
        XCTAssertEqual(Double(cursor.move(by: 1, dy: 0, env: e).to.x), 573.6, accuracy: 1e-9)
        // Something else moving the pointer still resyncs.
        e.cursor = CGPoint(x: 700, y: 300)
        XCTAssertEqual(Double(cursor.move(by: 1, dy: 0, env: e).to.x), 701, accuracy: 1e-9)
        // After a resync the old placements no longer count.
        XCTAssertEqual(Double(cursor.move(by: 1, dy: 0, env: env).to.x), 501, accuracy: 1e-9)
    }

    /// Only the newest placement and those still in flight are iKey's own. Once the Mac has
    /// reported a newer placement, another device moving the cursor back onto an older one
    /// (here the clamped left edge) is an external move, not a lagging report.
    func testExternalMoveBackOntoOlderPlacementResyncs() {
        var cursor = VirtualCursor()
        var e = env
        let edge = cursor.move(by: -600, dy: 0, env: e)
        XCTAssertEqual(Double(edge.to.x), 0, accuracy: 1e-9)
        e.cursor = edge.to
        XCTAssertEqual(Double(cursor.move(by: 100, dy: 0, env: e).to.x), 100, accuracy: 1e-9)
        e.cursor = CGPoint(x: 100, y: 400)
        XCTAssertEqual(Double(cursor.move(by: 1, dy: 0, env: e).to.x), 101, accuracy: 1e-9)
        // The built-in trackpad pushes the pointer back to the left edge.
        e.cursor = CGPoint(x: 0, y: 400)
        XCTAssertEqual(Double(cursor.move(by: 1, dy: 0, env: e).to.x), 1, accuracy: 1e-9)

        // In flight: three posts the Mac has not applied yet. A report of the middle one keeps
        // the newest, but the placement before it is now passed and counts as external.
        var lag = VirtualCursor()
        var l = env
        let a = lag.move(by: 10, dy: 0, env: l).to
        let b = lag.move(by: 10, dy: 0, env: l).to
        let c = lag.move(by: 10, dy: 0, env: l).to
        XCTAssertEqual(Double(c.x), 530, accuracy: 1e-9)
        l.cursor = b
        XCTAssertEqual(Double(lag.move(by: 10, dy: 0, env: l).to.x), 540, accuracy: 1e-9)
        l.cursor = c
        XCTAssertEqual(Double(lag.move(by: 10, dy: 0, env: l).to.x), 550, accuracy: 1e-9)
        l.cursor = a
        XCTAssertEqual(Double(lag.move(by: 10, dy: 0, env: l).to.x), 520, accuracy: 1e-9)
    }

    func testClampThenReverseMovesImmediately() {
        var cursor = VirtualCursor()
        let e = PointerEnvironment(cursor: CGPoint(x: 95, y: 50), displays: [CGRect(x: 0, y: 0, width: 100, height: 100)],
                                   capsLockOn: false)
        let out = cursor.move(by: 50, dy: 0, env: e)
        XCTAssertEqual(Double(out.to.x), 99.99, accuracy: 1e-9)
        XCTAssertEqual(out.deltaX, 50)
        var back = e
        back.cursor = out.to
        XCTAssertEqual(Double(cursor.move(by: -10, dy: 0, env: back).to.x), 89.99, accuracy: 1e-9)
    }

    func testClampPicksNearestDisplay() {
        let displays = [CGRect(x: 0, y: 0, width: 1470, height: 956), CGRect(x: 1470, y: -200, width: 1920, height: 1080)]
        XCTAssertEqual(VirtualCursor.clamp(CGPoint(x: 100, y: 100), displays: displays), CGPoint(x: 100, y: 100))
        XCTAssertEqual(VirtualCursor.clamp(CGPoint(x: 2000, y: -500), displays: displays), CGPoint(x: 2000, y: -200))
        let below = VirtualCursor.clamp(CGPoint(x: 1000, y: 1200), displays: displays)
        XCTAssertEqual(Double(below.y), 955.99, accuracy: 1e-9)
        XCTAssertEqual(VirtualCursor.clamp(CGPoint(x: 7, y: 8), displays: []), CGPoint(x: 7, y: 8))
    }

    func testButtonAtVirtualCursorDragAndOrphanUp() {
        var core = InjectorCore()
        let pos = moves(send(&core, .motion(PointerMotion(dx: 0.1, dy: 0, dt: 0.02, speed: 5)), at: 0))[0].to
        XCTAssertNotEqual(pos, env.cursor)
        let down = quiet(send(&core, .button(button: .left, down: true, clickState: 2), at: 0.1))
        XCTAssertEqual(down, [.mouseButton(.left, down: true, at: pos, clickState: 2, flags: nc)])
        XCTAssertTrue(core.hasHeldInput)
        XCTAssertEqual(moves(send(&core, .motion(PointerMotion(dx: 1, dy: 0, dt: 0.02, speed: 50)), at: 0.2))[0].drag, .left)
        _ = quiet(send(&core, .button(button: .left, down: false, clickState: 2), at: 0.3))
        XCTAssertFalse(core.hasHeldInput)
        XCTAssertEqual(quiet(send(&core, .button(button: .right, down: false, clickState: 1), at: 0.4)), [])
    }

    // MARK: - Scroll

    func testScrollPhasesAndMomentumViaTick() {
        var core = InjectorCore()
        var events = send(&core, .contacts(2), at: 0)
        events += send(&core, scrollInput(.mayBegin), at: 0)
        events += send(&core, scrollInput(.began, dy: 2), at: 0.01)
        for i in 1...3 { events += send(&core, scrollInput(.changed, dy: 2), at: 0.01 + Double(i) / 120) }
        XCTAssertTrue(core.hasHeldInput)
        events += send(&core, .contacts(0), at: 0.05)
        events += send(&core, scrollInput(.ended, releaseVY: 300), at: 0.05)
        XCTAssertFalse(core.hasHeldInput)
        XCTAssertEqual(frames(events).map(\.phase), [128, 1, 2, 2, 2, 4])
        XCTAssertTrue(frames(events).filter { $0.phase == 1 || $0.phase == 2 }.allSatisfy { $0.pointY > 0 })

        let glide = frames(drain(&core))
        XCTAssertGreaterThan(glide.count, 3)
        XCTAssertEqual(glide.first?.momentum, 1)
        XCTAssertEqual(glide.last?.momentum, 3)
        XCTAssertTrue(glide.dropFirst().dropLast().allSatisfy { $0.momentum == 2 })
        XCTAssertTrue(glide.allSatisfy { $0.phase == 0 })
        XCTAssertNil(core.nextDeadline)
    }

    /// Only frames the synthesizer posts open a scroll: a zero-delta began/changed while idle
    /// leaves nothing held and nothing to close.
    func testZeroDeltaScrollOpensNothing() {
        var core = InjectorCore()
        XCTAssertEqual(quiet(send(&core, scrollInput(.changed), at: 0)), [])
        XCTAssertFalse(core.hasHeldInput)
        XCTAssertEqual(core.releaseAll(at: 1, env: env), [])
        // A may-begin opens it, a cancel closes it.
        XCTAssertEqual(frames(send(&core, scrollInput(.mayBegin), at: 2)).map(\.phase), [128])
        XCTAssertTrue(core.hasHeldInput)
        XCTAssertEqual(frames(send(&core, scrollInput(.cancelled), at: 2.1)).map(\.phase), [8])
        XCTAssertFalse(core.hasHeldInput)
    }

    func testContactsStopsMomentum() {
        var core = InjectorCore()
        _ = send(&core, scrollInput(.began, dy: 3), at: 0)
        _ = send(&core, scrollInput(.ended, releaseVY: 400), at: 0.02)
        XCTAssertEqual(frames(core.tick(at: core.nextDeadline ?? 0, env: env)).map(\.momentum), [1])
        XCTAssertEqual(send(&core, .contacts(0), at: 0.05), [])
        XCTAssertEqual(frames(send(&core, .contacts(1), at: 0.06)).map(\.momentum), [3])
        XCTAssertNil(core.nextDeadline)
    }

    func testNaturalOffNegates() {
        var natural = InjectorCore()
        let on = frames(send(&natural, scrollInput(.began, dy: 2), at: 0))
        var reversed = InjectorCore(settings: settings { $0.prefs.naturalScrolling = false })
        let off = frames(send(&reversed, scrollInput(.began, dy: 2), at: 0))
        XCTAssertGreaterThan(on.first?.pointY ?? 0, 0)
        XCTAssertEqual(off.first?.pointY, on.first.map { -$0.pointY })
    }

    func testScrollCarriesHeldFlags() {
        var core = InjectorCore()
        _ = key(&core, 55, true, at: 0)
        let events = send(&core, scrollInput(.began, dy: 2), at: 0.1)
        XCTAssertTrue(events.contains { if case .scroll(_, [.nonCoalesced, .command, .leftCommand]) = $0 { return true } else { return false } })
    }

    // MARK: - Gestures

    func testSwipeLeftChordFlags0xA40000() {
        var core = InjectorCore()
        let events = send(&core, .gesture(WireGesture(kind: .swipe, fingers: 3, direction: "left")), at: 0)
        XCTAssertEqual(events.first, .declareUserActivity)
        let keyFlags = ModifierFlags(rawValue: 0xA40000 | 0x1 | 0x100)
        XCTAssertEqual(quiet(events), chord(124, modifier: 59, modFlags: [.control, .leftControl], keyFlags: keyFlags))
        // With three-finger drag on, swipes need four fingers.
        core.update(settings: settings { $0.prefs.threeFingerDrag = true })
        XCTAssertEqual(send(&core, .gesture(WireGesture(kind: .swipe, fingers: 3, direction: "left")), at: 2), [])
        XCTAssertEqual(quiet(send(&core, .gesture(WireGesture(kind: .swipe, fingers: 4, direction: "left")), at: 3)).count, 4)
    }

    func testGestureChordKeepsUserHeldShift() {
        var core = InjectorCore()
        _ = key(&core, 56, true, at: 0)
        let events = quiet(send(&core, .gesture(WireGesture(kind: .swipe, fingers: 3, direction: "right")), at: 0.1))
        let keyFlags = lshift.union([.control, .leftControl, .secondaryFn, .numericPad])
        XCTAssertEqual(events, chord(123, modifier: 59, modFlags: [.control, .leftControl], keyFlags: keyFlags, base: lshift))
        XCTAssertEqual(key(&core, 56, false, at: 0.2), [.flagsChanged(code: 56, flags: nc)])

        // A chord modifier the user already holds is reused, never released.
        _ = key(&core, 59, true, at: 1)
        let held = quiet(send(&core, .gesture(WireGesture(kind: .swipe, fingers: 3, direction: "left")), at: 1.1))
        let heldFlags = lctrl.union([.secondaryFn, .numericPad])
        XCTAssertEqual(held, [.key(code: 124, down: true, flags: heldFlags, autorepeat: false),
                              .key(code: 124, down: false, flags: heldFlags, autorepeat: false)])
    }

    func testThreeFingerTapLooksUp() {
        var core = InjectorCore()
        let events = quiet(send(&core, .gesture(WireGesture(kind: .tap, fingers: 3)), at: 0))
        let both: ModifierFlags = [.nonCoalesced, .control, .leftControl, .command, .leftCommand]
        XCTAssertEqual(events, [.flagsChanged(code: 59, flags: lctrl), .flagsChanged(code: 55, flags: both),
                                .key(code: 2, down: true, flags: both, autorepeat: false),
                                .key(code: 2, down: false, flags: both, autorepeat: false),
                                .flagsChanged(code: 55, flags: lctrl), .flagsChanged(code: 59, flags: nc)])
        XCTAssertEqual(send(&core, .gesture(WireGesture(kind: .swipe, fingers: 3, direction: "sideways")), at: 1), [])
    }

    // MARK: - Heartbeat, user activity, messages

    func testHeartbeatReconcileReleasesStaleKeyNotModifierPress() {
        var core = InjectorCore()
        _ = key(&core, 0, true, at: 0)
        // The iPad reports Shift that the Mac never saw: nothing is pressed; stale A goes up.
        XCTAssertEqual(heartbeat(&core, held: [56], at: 0.1), [.key(code: 0, down: false, flags: nc, autorepeat: false)])
        XCTAssertFalse(core.hasHeldInput)

        // Non-modifiers first, then modifiers; a held key the iPad still reports stays down.
        _ = key(&core, 56, true, at: 1)
        _ = key(&core, 1, true, at: 1.01)
        _ = key(&core, 2, true, at: 1.02)
        XCTAssertEqual(heartbeat(&core, held: [2], at: 1.1),
                       [.key(code: 1, down: false, flags: lshift, autorepeat: false), .flagsChanged(code: 56, flags: nc)])
        XCTAssertEqual(key(&core, 2, false, at: 1.2), [.key(code: 2, down: false, flags: nc, autorepeat: false)])
    }

    func testHeartbeatCancelsLostCapsPressWithoutTouchingLockAndReleasesButtons() {
        var core = InjectorCore()
        _ = key(&core, 57, true, at: 0)
        _ = quiet(send(&core, .button(button: .left, down: true, clickState: 1), at: 0.01))
        let events = heartbeat(&core, held: [], at: 0.02)
        XCTAssertEqual(events, [.mouseButton(.left, down: false, at: CGPoint(x: 500, y: 400), clickState: 1, flags: nc)])
        // The pending press is gone: no deadline turns the lock on later.
        XCTAssertNil(core.nextDeadline)
        XCTAssertFalse(core.hasHeldInput)

        // A press that already turned the lock on keeps it on.
        var held = InjectorCore()
        _ = key(&held, 57, true, at: 0)
        XCTAssertEqual(held.tick(at: 0.075, env: env), [.setCapsLock(true)])
        var on = env
        on.capsLockOn = true
        XCTAssertEqual(held.handle(.heartbeat(Heartbeat(seq: 1, held: [], buttons: [], active: false), t: 100_000),
                                   at: 0.1, env: on), [])
        XCTAssertFalse(held.hasHeldInput)

        // A virtual lock stays as it is.
        var virtual = InjectorCore(settings: settings { $0.capsMode = .virtual })
        XCTAssertEqual(key(&virtual, 57, true, at: 0), [.flagsChanged(code: 57, flags: [.nonCoalesced, .alphaShift])])
        XCTAssertEqual(heartbeat(&virtual, held: [], at: 0.1), [])
        XCTAssertEqual(key(&virtual, 0, true, at: 0.2),
                       [.key(code: 0, down: true, flags: [.nonCoalesced, .alphaShift], autorepeat: false)])
    }

    /// The user's remapped left Command loses its up: the press is cancelled, Caps Lock is not
    /// toggled by its hold deadline, and the next tap switches the input source.
    func testHeartbeatCancelsLostRemappedCapsPress() {
        var core = InjectorCore(settings: userRemap)
        XCTAssertEqual(key(&core, 55, true, at: 0), [])
        XCTAssertEqual(heartbeat(&core, held: [55], at: 0.1), [])
        XCTAssertNotNil(core.nextDeadline)
        XCTAssertEqual(heartbeat(&core, held: [], at: 0.2), [])
        XCTAssertNil(core.nextDeadline)
        XCTAssertFalse(core.hasHeldInput)
        XCTAssertEqual(drain(&core), [])
        XCTAssertEqual(key(&core, 55, true, at: 2), [])
        XCTAssertEqual(key(&core, 55, false, at: 2.1), [ctrlSpaceSwitch])
    }

    func testHeartbeatReleaseOfFnDoesNotTriggerTapAction() {
        var core = InjectorCore(settings: settings { $0.fnTapAction = .changeInputSource })
        _ = key(&core, 63, true, at: 0)
        XCTAssertEqual(heartbeat(&core, held: [], at: 0.1), [.flagsChanged(code: 63, flags: nc)])
    }

    func testHeartbeatReleasesRemappedKeyByPhysicalCode() {
        var core = InjectorCore(settings: settings { $0.keyRemap = [57: 53] })
        _ = key(&core, 57, true, at: 0)
        XCTAssertEqual(heartbeat(&core, held: [57], at: 0.1), [])
        XCTAssertEqual(heartbeat(&core, held: [], at: 0.2), [.key(code: 53, down: false, flags: nc, autorepeat: false)])
        XCTAssertEqual(key(&core, 57, false, at: 0.3), [])
    }

    func testHeldStateReconcilerOrder() {
        let r = HeldStateReconciler.reconcile(macHeldKeys: [63, 0, 57, 55, 12, 56], macButtons: [.right, .left],
                                              padHeld: [56], padButtons: [.right])
        XCTAssertEqual(r.releaseKeys, [0, 12, 55, 63])
        XCTAssertEqual(r.releaseButtons, [.left])
    }

    func testUserActivityThrottled() {
        var core = InjectorCore()
        func activity(_ events: [SynthEvent]) -> Int { events.filter { $0 == .declareUserActivity }.count }
        XCTAssertEqual(activity(send(&core, .key(code: 0, down: true), at: 0)), 1)
        XCTAssertEqual(activity(send(&core, .key(code: 0, down: false), at: 0.1)), 0)
        XCTAssertEqual(activity(send(&core, .key(code: 1, down: true), at: 0.5)), 0)
        XCTAssertEqual(activity(send(&core, .motion(PointerMotion(dx: 1, dy: 0, dt: 0.01, speed: 100)), at: 0.99)), 0)
        XCTAssertEqual(activity(send(&core, .motion(PointerMotion(dx: 1, dy: 0, dt: 0.01, speed: 100)), at: 1.0)), 1)
        XCTAssertEqual(activity(send(&core, .key(code: 1, down: false), at: 2.5)), 0)
        XCTAssertEqual(activity(send(&core, .button(button: .left, down: true, clickState: 1), at: 2.6)), 1)
        let events = send(&core, .key(code: 2, down: true), at: 4)
        XCTAssertEqual(events.first, .declareUserActivity)
    }

    func testLegacyMessageIgnored() {
        var core = InjectorCore()
        XCTAssertEqual(core.handle(.legacy(.key(code: 0, down: true)), at: 0, env: env), [])
        XCTAssertEqual(core.handle(.legacy(.pointer(dx: 10, dy: 0)), at: 0, env: env), [])
        XCTAssertEqual(core.handle(.hello(Hello(proto: 2, client: UUID(), app: "1", device: "iPad", features: [])), at: 0, env: env), [])
        XCTAssertEqual(core.handle(.ping(id: 1, t: 0), at: 0, env: env), [])
        XCTAssertEqual(core.handle(.goodbye(.user), at: 0, env: env), [])
        XCTAssertEqual(core.handle(.unknown("future"), at: 0, env: env), [])
        XCTAssertFalse(core.hasHeldInput)
        XCTAssertNil(core.nextDeadline)
    }

    func testTestTopRowDownUp() {
        var core = InjectorCore()
        XCTAssertEqual(core.testTopRow(.volumeUp, strategy: .aux(0), env: env),
                       [.aux(nxKeyType: 0, down: true, autorepeat: false, flags: nc),
                        .aux(nxKeyType: 0, down: false, autorepeat: false, flags: nc)])
        XCTAssertEqual(core.testTopRow(.brightnessUp, strategy: .keyCode(144, secondaryFn: true), env: env),
                       [.key(code: 144, down: true, flags: [.nonCoalesced, .secondaryFn], autorepeat: false),
                        .key(code: 144, down: false, flags: [.nonCoalesced, .secondaryFn], autorepeat: false)])
        let fnFlags: ModifierFlags = [.nonCoalesced, .secondaryFn]
        XCTAssertEqual(core.testTopRow(.brightnessUp, strategy: .hotKey(54), env: env),
                       [.key(code: 113, down: true, flags: fnFlags, autorepeat: false),
                        .key(code: 113, down: false, flags: fnFlags, autorepeat: false)])
        XCTAssertEqual(core.testTopRow(.missionControl, strategy: .openApplication("/A.app"), env: env),
                       [.openApplication(path: "/A.app")])
        XCTAssertEqual(core.testTopRow(.dictation, strategy: .none, env: env), [])
        XCTAssertFalse(core.hasHeldInput)
    }

    func testReleaseAllEnds4Then3() {
        // An open scroll ends with 4.
        var scrolling = InjectorCore()
        _ = send(&scrolling, scrollInput(.began, dy: 2), at: 0)
        XCTAssertEqual(frames(scrolling.releaseAll(at: 0.1, env: env)).map(\.phase), [4])
        XCTAssertFalse(scrolling.hasHeldInput)

        // Running momentum ends with 3.
        var gliding = InjectorCore()
        _ = send(&gliding, scrollInput(.began, dy: 2), at: 0)
        _ = send(&gliding, scrollInput(.ended, releaseVY: 300), at: 0.02)
        _ = gliding.tick(at: gliding.nextDeadline ?? 0, env: env)
        XCTAssertEqual(frames(gliding.releaseAll(at: 0.05, env: env)).map(\.momentum), [3])
        XCTAssertNil(gliding.nextDeadline)

        // Only may-begin: cancelled (8).
        var touching = InjectorCore()
        _ = send(&touching, scrollInput(.mayBegin), at: 0)
        XCTAssertEqual(frames(send(&touching, .releaseAll, at: 0.1)).map(\.phase), [8])

        // Keys, then modifiers, then buttons.
        var core = InjectorCore()
        _ = key(&core, 56, true, at: 0)
        _ = key(&core, 0, true, at: 0.01)
        _ = key(&core, 111, true, at: 0.02)
        _ = quiet(send(&core, .button(button: .left, down: true, clickState: 1), at: 0.03))
        XCTAssertEqual(core.releaseAll(at: 0.1, env: env),
                       [.key(code: 0, down: false, flags: lshift, autorepeat: false),
                        .aux(nxKeyType: 0, down: false, autorepeat: false, flags: lshift),
                        .flagsChanged(code: 56, flags: nc),
                        .mouseButton(.left, down: false, at: CGPoint(x: 500, y: 400), clickState: 1, flags: nc)])
        XCTAssertFalse(core.hasHeldInput)
        XCTAssertEqual(key(&core, 0, false, at: 0.2), [])
    }

    func testScrollCurveChangeWaitsForIdle() {
        let steep = [HIDAccelCurve(index: 0, gl: 1, gp: 3, gc: 0, gq: 0, t1: 6, t2: 12)]
        var core = InjectorCore()
        _ = send(&core, scrollInput(.began, dy: 2), at: 0)
        core.update(settings: settings { $0.scrollCurves = steep })
        // The open scroll keeps its phase sequence.
        XCTAssertEqual(frames(send(&core, scrollInput(.changed, dy: 2), at: 0.01)).map(\.phase), [2])
        XCTAssertEqual(frames(send(&core, scrollInput(.ended), at: 0.02)).map(\.phase), [4])
        let next = frames(send(&core, scrollInput(.began, dy: 2), at: 1))
        XCTAssertEqual(next.map(\.phase), [1])
        var reference = ScrollSynthesizer(curves: steep)
        let expected = reference.input(.began, dxMM: 0, dyMM: 2, dt: 1.0 / 120, speed: 100, releaseVX: nil, releaseVY: nil, at: 1)
        XCTAssertEqual(next, expected)
    }
}
