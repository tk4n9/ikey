import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import IKeyCore

// End-to-end conventions across packages: scripted touches on the true-scale deck go through
// DeckInputEngine, every PadInput is framed with WireV2.encode, re-split at random byte boundaries
// into PadFrameDecoder, and handled by InjectorCore, which they reach 4 ms after they are sent (Mac
// time = iPad time + a one-day epoch offset + 4 ms, so the two clocks share nothing but their
// rate); the resulting SynthEvents are what the Mac would post. The runner also sends heartbeats like
// PadModel (every 0.1 s while a key or button is held, else every 1 s), which keep the Mac's
// repeat lease alive, and ticks the injector at its deadlines (repeats, momentum).
//
// Deviations from the plan's scenario text, following amendments F-H:
// - Scenario 5: a Shift merely held posts nothing (lazy modifiers), so Shift is first used in a
//   Shift+K chord; the Touch ID hold then releases the posted Shift.
// - Scenario 7: J is home-row (rest-capable); it presses only with the opt-in isolatedHold, at its
//   threshold (0.25-0.30 s). With the default settings the same hold posts nothing.
final class EndToEndTests: XCTestCase {
    private static let spec = MacBookAirModel.air13_2022.spec
    private static let screen = CGSize(width: 1376, height: 1032)
    private static let seeds: [UInt64] = [0x1D, 0xBADC0DE, 0x5EED_2026]
    /// One-way network delay: a message reaches InjectorCore this long after it is sent.
    private static let latency = 0.004
    /// The Mac clock's epoch differs from the iPad's (Mac time = iPad time + this + latency), so
    /// any mix of sender timestamps and Mac times (e.g. in tap durations) shows up as an error.
    private static let macEpochOffset = 86_400.0
    /// Mac time for a message sent (or a deadline expressed) at iPad time `t`.
    private static func macTime(_ t: TimeInterval) -> TimeInterval { t + macEpochOffset + latency }

    private let deck = ResolvedDeck(spec: EndToEndTests.spec,
                                    projection: DeckProjection(display: .pro13, spec: EndToEndTests.spec,
                                                               screenSize: EndToEndTests.screen))
    private let env = PointerEnvironment(cursor: CGPoint(x: 500, y: 400),
                                         displays: [CGRect(x: 0, y: 0, width: 1470, height: 956)], capsLockOn: false)
    private let nc = ModifierFlags.nonCoalesced

    /// The user's Mac: left Command → Caps Lock (switches input source), Caps Lock → Escape.
    private let userRemap: [UInt16: UInt16] = [55: 57, 57: 53]

    // MARK: - Scenarios

    // 1. Hands rest on the home row and Space for 5 s, then the left pinky moves to Shift and A is
    // tapped: exactly Shift down, a down/up with Shift flags, Shift up.
    func testShiftChordAfterResting() {
        var s = Script()
        let home: [UInt16] = [0, 1, 2, 3, 38, 40, 37, 41]
        for (i, code) in home.enumerated() {
            s.down(0.012 * Double(i), touch(i + 1, key(code)))
            s.up(i == 0 ? 5.0 : 6.0, touch(i + 1, key(code)))
        }
        s.hold(id: 9, key(49), from: 0.1, until: 6.0, radius: 16)
        s.hold(id: 20, key(56), from: 5.05, until: 5.40)
        s.hold(id: 21, key(0), from: 5.15, until: 5.23)

        let trace = run(s)
        let shift: ModifierFlags = [.shift, .leftShift, nc]
        XCTAssertEqual(trace.input, [
            .flagsChanged(code: 56, flags: shift),
            .key(code: 0, down: true, flags: shift, autorepeat: false),
            .key(code: 0, down: false, flags: shift, autorepeat: false),
            .flagsChanged(code: 56, flags: nc),
        ])
        // The chord is posted at A's lift (rest-capable keys commit on lift), Shift up at its own lift.
        assertTimes(trace.times(of: [0, 3]), [5.23, 5.40])
    }

    // 2. Two fingers moving down the glass (UIKit +y) scroll with phases 128, 1, 2..., 4: content
    // follows the fingers (pointY > 0) with natural scrolling, the other way without it. Moving
    // right (UIKit +x) likewise gives pointX > 0 with natural scrolling and pointX < 0 without.
    func testScrollDirectionNaturalOnOff() {
        let mid = padPoint(xMM: 64, yMM: 30)
        for vertical in [true, false] {
            var s = Script()
            if vertical {
                s.slide(ids: [1, 2], from: [offset(mid, dxMM: -10), offset(mid, dxMM: 10)], dxMM: 0, dyMM: 20,
                        start: 0, duration: 0.4)
            } else {
                s.slide(ids: [1, 2], from: [offset(mid, dxMM: -10, dyMM: -6), offset(mid, dxMM: -10, dyMM: 6)],
                        dxMM: 20, dyMM: 0, start: 0, duration: 0.4)
            }
            let along: (ScrollFrame) -> Int32 = vertical ? { $0.pointY } : { $0.pointX }
            let across: (ScrollFrame) -> Int32 = vertical ? { $0.pointX } : { $0.pointY }
            let alongFixed: (ScrollFrame) -> Double = vertical ? { $0.fixedY } : { $0.fixedX }

            for natural in [true, false] {
                let label = "\(vertical ? "fingers down" : "fingers right"), natural \(natural)"
                var settings = InjectorSettings()
                settings.prefs.naturalScrolling = natural
                let trace = run(s, settings: settings)
                let frames = trace.input.compactMap { event -> ScrollFrame? in
                    if case .scroll(let frame, _) = event { return frame }
                    return nil
                }
                XCTAssertEqual(trace.input.count, frames.count, "\(label): only scroll events: \(trace.input)")
                let phased = frames.filter { $0.momentum == 0 }
                let phases = phased.map(\.phase)
                XCTAssertGreaterThanOrEqual(phases.count, 4, "\(label): \(phases)")
                guard phases.count >= 4 else { continue }
                XCTAssertEqual(Array(phases.prefix(2)), [128, 1], label)
                XCTAssertEqual(phases.last, 4, label)
                XCTAssertTrue(phases.dropFirst(2).dropLast().allSatisfy { $0 == 2 }, "\(label): \(phases)")

                let moving = phased.filter { $0.phase == 1 || $0.phase == 2 }
                let total = moving.reduce(0) { $0 + Int(along($1)) }
                let sign: Int32 = natural ? 1 : -1
                XCTAssertEqual(total.signum(), Int(sign), "\(label): total \(total)")
                XCTAssertTrue(moving.allSatisfy { along($0).signum() != -sign && across($0) == 0 }, "\(label): \(moving)")
                XCTAssertTrue(moving.allSatisfy { alongFixed($0).sign == (natural ? .plus : .minus) || alongFixed($0) == 0 },
                              label)

                // Momentum after the flick keeps the direction and ends with 3.
                let momentum = frames.filter { $0.momentum != 0 }
                XCTAssertFalse(momentum.isEmpty, "\(label): no momentum after the flick")
                XCTAssertEqual(momentum.first?.momentum, 1, label)
                XCTAssertEqual(momentum.last?.momentum, 3, label)
                XCTAssertTrue(momentum.allSatisfy { along($0).signum() != -sign && across($0) == 0 }, "\(label): \(momentum)")
            }
        }
    }

    // 3. Three fingers swiping left 25 mm reveal the Space to the right: one Ctrl+Right chord (arrow
    // flags carry fn and keypad, so 0xA40000 is set) with Control pressed and lifted around it.
    // The fingers land in one touch batch; today the recognizer counts them one by one, so two
    // fingers open a may-begin scroll that the third cancels (128 then 8, no distance). Either that
    // pair or no scroll frames at all is accepted (an open W1-PAD/W2-ENGINE question).
    func testThreeFingerSwipeLeftCtrlRight() {
        var s = Script()
        let mid = padPoint(xMM: 70, yMM: 35)
        s.slide(ids: [1, 2, 3], from: [offset(mid, dxMM: -18), mid, offset(mid, dxMM: 18, dyMM: -3)],
                dxMM: -25, dyMM: 0, start: 0, duration: 0.25)

        let trace = run(s)
        let scrolls = trace.input.compactMap { event -> ScrollFrame? in
            if case .scroll(let frame, _) = event { return frame }
            return nil
        }
        XCTAssertTrue(scrolls.isEmpty || scrolls == [ScrollFrame(phase: 128), ScrollFrame(phase: 8)], "\(scrolls)")
        let control: ModifierFlags = [.control, .leftControl, nc]
        let arrow = control.union([.secondaryFn, .numericPad])
        XCTAssertEqual(trace.input.filter { if case .scroll = $0 { return false } else { return true } }, [
            .flagsChanged(code: 59, flags: control),
            .key(code: 124, down: true, flags: arrow, autorepeat: false),
            .key(code: 124, down: false, flags: arrow, autorepeat: false),
            .flagsChanged(code: 59, flags: nc),
        ])
        XCTAssertTrue(arrow.isSuperset(of: ModifierFlags(rawValue: 0xA40000)))
        XCTAssertEqual(trace.sent.filter { if case .gesture = $0 { return true } else { return false } },
                       [.gesture(WireGesture(kind: .swipe, fingers: 3, direction: "left"))])
    }

    // 4. Slow pointing: 10 mm at 10 mm/s moves the Mac pointer 36-44 pt (3.6-4.4 pt/mm at the
    // default tracking speed), entirely along the finger's axis and in its direction (UIKit and the
    // Mac's global display space both grow +y downwards), and the posted deltas match the cursor travel.
    func testSlowPointerGain() {
        for (fx, fy) in [(10.0, 0.0), (0.0, 10.0), (-10.0, 0.0), (0.0, -10.0)] {
            let label = "finger (\(fx), \(fy)) mm"
            var s = Script()
            s.slide(ids: [1], from: [padPoint(xMM: 50, yMM: 40)], dxMM: fx, dyMM: fy, start: 0, duration: 1.0)

            let trace = run(s)
            var dx: Int64 = 0, dy: Int64 = 0
            var last = env.cursor
            for event in trace.input {
                guard case let .mouseMove(to, deltaX, deltaY, drag, _) = event else {
                    XCTFail("\(label): unexpected \(event)")
                    continue
                }
                XCTAssertNil(drag)
                dx += deltaX
                dy += deltaY
                last = to
            }
            let (along, across) = fx != 0 ? (dx, dy) : (dy, dx)
            let sign: Int64 = fx + fy > 0 ? 1 : -1
            XCTAssertTrue((36...44).contains(along * sign), "\(label): total delta (\(dx), \(dy))")
            XCTAssertEqual(across, 0, label)
            XCTAssertEqual(Double(last.x - env.cursor.x), Double(dx), accuracy: 1, label)
            XCTAssertEqual(Double(last.y - env.cursor.y), Double(dy), accuracy: 1, label)
            if fx > 0 { XCTAssertGreaterThan(last.x, env.cursor.x, label) }
            if fx < 0 { XCTAssertLessThan(last.x, env.cursor.x, label) }
            if fy > 0 { XCTAssertGreaterThan(last.y, env.cursor.y, label) }
            if fy < 0 { XCTAssertLessThan(last.y, env.cursor.y, label) }
            if fx == 0 { XCTAssertEqual(last.x, env.cursor.x, label) }
            if fy == 0 { XCTAssertEqual(last.y, env.cursor.y, label) }
        }
    }

    // 5. Holding Touch ID 0.6 s opens the panel and releases everything on the Mac: the Shift that
    // was posted by a Shift+K chord goes up at the hold, and nothing follows.
    func testTouchIDHoldReleasesShift() {
        var s = Script()
        s.hold(id: 1, key(56), from: 0, until: 1.2)
        s.hold(id: 2, key(40), from: 0.1, until: 0.17)
        s.hold(id: 3, touchIDPoint, from: 0.3, until: 1.3)

        let trace = run(s)
        let shift: ModifierFlags = [.shift, .leftShift, nc]
        XCTAssertEqual(trace.input, [
            .flagsChanged(code: 56, flags: shift),
            .key(code: 40, down: true, flags: shift, autorepeat: false),
            .key(code: 40, down: false, flags: shift, autorepeat: false),
            .flagsChanged(code: 56, flags: nc),
        ])
        assertTimes(trace.times(of: [3]), [0.9], accuracy: 0.02)
        XCTAssertTrue(trace.signals.contains(.openPanel))
        XCTAssertEqual(trace.sent.filter { $0 == .releaseAll }.count, 1)
        XCTAssertEqual(trace.sent.last, .releaseAll, "nothing is sent after the release")
    }

    // 6. fn + Left arrow is Home on the Mac (the fn layer is applied Mac-side), with fn's flag.
    func testFnLeftHome() {
        var s = Script()
        s.hold(id: 1, key(63), from: 0, until: 0.35)
        s.hold(id: 2, key(123), from: 0.1, until: 0.2)

        let trace = run(s)
        let fn: ModifierFlags = [.secondaryFn, nc]
        XCTAssertEqual(trace.input, [
            .flagsChanged(code: 63, flags: fn),
            .key(code: 115, down: true, flags: fn, autorepeat: false),
            .key(code: 115, down: false, flags: fn, autorepeat: false),
            .flagsChanged(code: 63, flags: nc),
        ])
        XCTAssertEqual(trace.sent.filter { if case .key = $0 { return true } else { return false } },
                       [.key(code: 63, down: true), .key(code: 123, down: true),
                        .key(code: 123, down: false), .key(code: 63, down: false)])
    }

    // 7. J held alone for 1 s with isolatedHold: it presses at its threshold, the Mac repeats it
    // (delay 0.25 s, interval 0.05 s, kept alive by heartbeats) and it goes up at 1.0 s.
    func testIsolatedHoldRepeatsOnMac() {
        var s = Script()
        s.hold(id: 1, key(38), from: 0, until: 1.0)
        var settings = InjectorSettings()
        settings.prefs = MacInputPreferences(keyRepeatDelay: 0.25, keyRepeatInterval: 0.05)

        let trace = run(s, typing: TypingSettings(isolatedHold: true), settings: settings)
        let keys = trace.timedInput.compactMap { t, event -> (t: Double, down: Bool, repeats: Bool)? in
            guard case let .key(38, down, _, autorepeat) = event else { return nil }
            return (t, down, autorepeat)
        }
        XCTAssertEqual(keys.count, trace.input.count, "only J events: \(trace.input)")
        guard let first = keys.first, let last = keys.last, keys.count >= 3 else {
            return XCTFail("J did not press and repeat: \(trace.input)")
        }
        XCTAssertTrue(first.down && !first.repeats)
        XCTAssertGreaterThanOrEqual(first.t, 0.25 - 1e-9)
        XCTAssertLessThanOrEqual(first.t, 0.30 + 1e-9)
        XCTAssertTrue(!last.down && !last.repeats)
        XCTAssertEqual(last.t, 1.0, accuracy: 1e-6)

        let repeats = keys.dropFirst().dropLast()
        XCTAssertTrue(repeats.allSatisfy { $0.down && $0.repeats })
        XCTAssertEqual(repeats.first?.t ?? 0, first.t + 0.25, accuracy: 1e-6)
        let gaps = zip(repeats.dropFirst(), repeats).map { $0.t - $1.t }
        XCTAssertTrue(gaps.allSatisfy { abs($0 - 0.05) < 1e-6 }, "\(gaps)")
        // Every repeat slot from the first repeat up to the lift fires (one landing exactly on the
        // lift may go either way).
        let expected = Int(((1.0 - (first.t + 0.25)) / 0.05 + 1e-6).rounded(.down)) + 1
        XCTAssertTrue((expected - 1...expected).contains(repeats.count), "\(repeats.count) repeats, expected ~\(expected)")

        // Policy F default: the same lone hold on a home-row key is a rest and posts nothing.
        XCTAssertEqual(run(s, settings: settings).input, [])
    }

    // 8. A trackpad tap 0.7 s after typing clicks (tap quiet 0.6 s has passed); 0.4 s after typing
    // it does nothing, although the engine's own typing pause (0.35 s) is over.
    func testTapQuietAfterTyping() {
        for (gap, clicks) in [(0.7, true), (0.4, false)] {
            var s = Script()
            s.hold(id: 1, key(38), from: 0, until: 0.08) // commits at its lift
            s.hold(id: 2, padPoint(xMM: 64, yMM: 40), from: 0.08 + gap, until: 0.16 + gap)

            let trace = run(s)
            let typed: [SynthEvent] = [.key(code: 38, down: true, flags: nc, autorepeat: false),
                                       .key(code: 38, down: false, flags: nc, autorepeat: false)]
            XCTAssertEqual(Array(trace.input.prefix(2)), typed, "gap \(gap)")
            let rest = Array(trace.input.dropFirst(2))
            guard clicks else {
                XCTAssertEqual(rest, [], "gap \(gap)")
                continue
            }
            XCTAssertEqual(rest.count, 2, "gap \(gap): \(rest)")
            for (event, down) in zip(rest, [true, false]) {
                guard case let .mouseButton(button, isDown, at, clickState, flags) = event else {
                    XCTFail("gap \(gap): \(event)")
                    continue
                }
                XCTAssertEqual(button, .left)
                XCTAssertEqual(isDown, down)
                XCTAssertEqual(at, env.cursor)
                XCTAssertEqual(clickState, 1)
                XCTAssertEqual(flags, nc)
            }
        }
    }

    // MARK: - The user's remapped keys (amendments C, H)

    // A tap on the drawn left Command (tap-only on the deck) reaches the Mac as Caps Lock (55→57)
    // in 'switches input source' mode: each tap selects the previous input source, never ⌘.
    func testRemappedLeftCommandTapSwitchesInputSource() {
        var s = Script()
        s.hold(id: 1, key(55), from: 0, until: 0.12)
        s.hold(id: 2, key(55), from: 1.0, until: 1.1)

        let trace = run(s, typing: userTyping, settings: userInjector)
        let fallback: [SynthEvent] = [
            .flagsChanged(code: 59, flags: [.control, .leftControl, nc]),
            .key(code: 49, down: true, flags: [.control, .leftControl, nc], autorepeat: false),
            .key(code: 49, down: false, flags: [.control, .leftControl, nc], autorepeat: false),
            .flagsChanged(code: 59, flags: nc),
        ]
        XCTAssertEqual(trace.input, [.selectPreviousInputSource(fallback: fallback),
                                     .selectPreviousInputSource(fallback: fallback)])
        assertTimes(trace.times(of: [0, 1]), [0.12, 1.1])
        XCTAssertEqual(trace.sent, [.key(code: 55, down: true), .key(code: 55, down: false),
                                    .key(code: 55, down: true), .key(code: 55, down: false)])
    }

    // A thumb resting on the remapped left Command while C is typed never chords, never switches
    // the input source and never touches Caps Lock; a lone long hold posts nothing at all.
    func testRemappedLeftCommandRestingNeverChords() {
        var s = Script()
        s.hold(id: 1, key(55), from: 0, until: 1.0)
        s.hold(id: 2, key(8), from: 0.3, until: 0.36)
        let trace = run(s, typing: userTyping, settings: userInjector)
        XCTAssertEqual(trace.input, [.key(code: 8, down: true, flags: nc, autorepeat: false),
                                     .key(code: 8, down: false, flags: nc, autorepeat: false)])

        var lone = Script()
        lone.hold(id: 1, key(55), from: 0, until: 1.5)
        XCTAssertEqual(run(lone, typing: userTyping, settings: userInjector).input, [])
    }

    // The drawn Caps Lock posts Escape (57→53, a plain key), and right Command stays Command.
    func testRemappedCapsLockPostsEscapeAndRightCommandStaysCommand() {
        var s = Script()
        s.hold(id: 1, key(57), from: 0, until: 0.1)
        s.hold(id: 2, key(54), from: 0.5, until: 0.8)
        s.hold(id: 3, key(8), from: 0.6, until: 0.7)

        let trace = run(s, typing: userTyping, settings: userInjector)
        let command: ModifierFlags = [.command, .rightCommand, nc]
        XCTAssertEqual(trace.input, [
            .key(code: 53, down: true, flags: nc, autorepeat: false),
            .key(code: 53, down: false, flags: nc, autorepeat: false),
            .flagsChanged(code: 54, flags: command),
            .key(code: 8, down: true, flags: command, autorepeat: false),
            .key(code: 8, down: false, flags: command, autorepeat: false),
            .flagsChanged(code: 54, flags: nc),
        ])
    }

    /// The iPad's typing settings as the Mac's remap reaches it: the Mac announces its tap-only
    /// codes in MacState.tapOnly (as ReceiverModel does), the frame crosses the wire split in two,
    /// and the iPad adds the decoded codes to its tap-only set (as PadModel.effectiveTyping does).
    private var userTyping: TypingSettings {
        let codes = KeyRemap(map: userInjector.keyRemap).tapOnlyPadCodes.sorted()
        XCTAssertEqual(codes, [55])
        var typing = TypingSettings()
        do {
            let frame = try WireV2.encode(MacMessage.state(MacState(caps: false, tapOnly: codes)))
            var decoder = MacFrameDecoder()
            let cut = frame.count / 2
            let received = try decoder.append(frame.subdata(in: 0..<cut))
                + decoder.append(frame.subdata(in: cut..<frame.count))
            guard received.count == 1, case .state(let state) = received[0], let tapOnly = state.tapOnly else {
                XCTFail("MacState.tapOnly did not survive the wire: \(received)")
                return typing
            }
            XCTAssertEqual(tapOnly, codes)
            typing.tapOnlyCodes.formUnion(tapOnly)
        } catch {
            XCTFail("MacState round trip: \(error)")
        }
        return typing
    }

    private var userInjector: InjectorSettings {
        var settings = InjectorSettings()
        settings.keyRemap = userRemap
        settings.capsMode = .switchesInputSource
        return settings
    }

    // MARK: - Touch scripts

    private struct Step {
        enum Kind { case begin, move, end }
        var t: TimeInterval
        var kind: Kind
        var touches: [TouchSample]
    }

    /// Touch phases in iPad seconds; steps at the same time keep the order they were added in.
    private struct Script {
        private(set) var steps: [Step] = []

        mutating func down(_ t: TimeInterval, _ touches: TouchSample...) { add(t, .begin, touches) }
        mutating func up(_ t: TimeInterval, _ touches: TouchSample...) { add(t, .end, touches) }

        /// One still contact from `from` to `until`.
        mutating func hold(id: Int, _ point: CGPoint, from: TimeInterval, until: TimeInterval, radius: Double = 10) {
            let sample = TouchSample(id: id, point: point, radius: radius)
            add(from, .begin, [sample])
            add(until, .end, [sample])
        }

        /// Fingers landing together and moving in a straight line at constant speed, sampled at
        /// 120 Hz, lifting at the end point. `ppm` converts the millimetre travel to points.
        mutating func slide(ids: [Int], from points: [CGPoint], dxMM: Double, dyMM: Double,
                            start: TimeInterval, duration: TimeInterval, ppm: Double = EndToEndTests.ppm) {
            func samples(_ f: Double) -> [TouchSample] {
                zip(ids, points).map { id, p in
                    TouchSample(id: id, point: CGPoint(x: p.x + CGFloat(dxMM * ppm * f), y: p.y + CGFloat(dyMM * ppm * f)),
                                radius: 10)
                }
            }
            add(start, .begin, samples(0))
            let n = max(1, Int((duration * 120).rounded()))
            for i in 1...n { add(start + duration * Double(i) / Double(n), .move, samples(Double(i) / Double(n))) }
            add(start + duration, .end, samples(1))
        }

        private mutating func add(_ t: TimeInterval, _ kind: Step.Kind, _ touches: [TouchSample]) {
            let index = steps.firstIndex { $0.t > t } ?? steps.endIndex
            steps.insert(Step(t: t, kind: kind, touches: touches), at: index)
        }
    }

    private static var ppm: Double {
        DeckProjection(display: .pro13, spec: spec, screenSize: screen).ppm
    }

    private func touch(_ id: Int, _ point: CGPoint) -> TouchSample {
        TouchSample(id: id, point: point, radius: 10)
    }

    /// The key's centre, kept on screen (the outer columns are clipped at true scale).
    private func key(_ code: UInt16) -> CGPoint {
        guard let rect = deck.keys.first(where: { $0.code == code })?.rect else {
            XCTFail("no key \(code) on the deck")
            return .zero
        }
        return onScreen(CGPoint(x: rect.midX, y: rect.midY))
    }

    private var touchIDPoint: CGPoint {
        let rect = deck.keys.first { $0.id == "touchid" }!.rect
        return onScreen(CGPoint(x: rect.midX, y: rect.midY))
    }

    /// A trackpad point in millimetres from its top-left (hinge-side) corner.
    private func padPoint(xMM: Double, yMM: Double) -> CGPoint {
        CGPoint(x: deck.trackpad.minX + CGFloat(xMM * Self.ppm), y: deck.trackpad.minY + CGFloat(yMM * Self.ppm))
    }

    private func offset(_ p: CGPoint, dxMM: Double = 0, dyMM: Double = 0) -> CGPoint {
        CGPoint(x: p.x + CGFloat(dxMM * Self.ppm), y: p.y + CGFloat(dyMM * Self.ppm))
    }

    private func onScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 2), Self.screen.width - 2), y: min(max(p.y, 2), Self.screen.height - 2))
    }

    // MARK: - Pipeline

    private struct Trace {
        /// Every SynthEvent with its time in iPad seconds (Mac time - epoch offset - latency).
        var timeline: [(t: TimeInterval, event: SynthEvent)] = []
        /// Everything the engine sent, in order.
        var sent: [PadInput] = []
        var signals: [EngineSignal] = []

        var events: [SynthEvent] { timeline.map(\.event) }
        /// Without user-activity declarations, which accompany input at most once per second.
        var timedInput: [(t: TimeInterval, event: SynthEvent)] { timeline.filter { $0.event != .declareUserActivity } }
        var input: [SynthEvent] { timedInput.map(\.event) }

        /// Times of the `input` events at these indices (missing ones are left out).
        func times(of inputIndices: [Int]) -> [TimeInterval] {
            let timed = timedInput
            return inputIndices.compactMap { timed.indices.contains($0) ? timed[$0].t : nil }
        }
    }

    /// Runs `script` once per frame-split seed; every seed must give the same events at the same
    /// times (framing never changes meaning). Returns the first run.
    private func run(_ script: Script, typing: TypingSettings = .init(), settings: InjectorSettings = .init(),
                     file: StaticString = #filePath, line: UInt = #line) -> Trace {
        let traces = Self.seeds.map { trace(script, seed: $0, typing: typing, settings: settings, file: file, line: line) }
        for (seed, other) in zip(Self.seeds, traces).dropFirst() {
            XCTAssertEqual(other.events, traces[0].events, "seed \(seed)", file: file, line: line)
            XCTAssertEqual(other.timeline.map(\.t), traces[0].timeline.map(\.t), "seed \(seed)", file: file, line: line)
        }
        return traces[0]
    }

    /// The plan's `pipeline(script)`: the SynthEvents the Mac posts for `script` with one split seed.
    private func pipeline(_ script: Script, seed: UInt64, typing: TypingSettings = .init(),
                          settings: InjectorSettings = .init()) -> [SynthEvent] {
        trace(script, seed: seed, typing: typing, settings: settings).events
    }

    func testPipelineHelperMatchesAcrossSeedsAndRoundTripsEveryFrame() {
        var s = Script()
        s.hold(id: 1, key(56), from: 0, until: 0.3)
        s.hold(id: 2, key(0), from: 0.05, until: 0.12)
        s.slide(ids: [3], from: [padPoint(xMM: 60, yMM: 40)], dxMM: 5, dyMM: -3, start: 1.0, duration: 0.2)
        let results = Self.seeds.map { pipeline(s, seed: $0) }
        XCTAssertFalse(results[0].isEmpty)
        XCTAssertTrue(results.allSatisfy { $0 == results[0] })
    }

    private func trace(_ script: Script, seed: UInt64, typing: TypingSettings, settings: InjectorSettings,
                       file: StaticString = #filePath, line: UInt = #line) -> Trace {
        var engine = DeckInputEngine(deck: deck, typing: typing)
        var injector = InjectorCore(settings: settings)
        var decoder = PadFrameDecoder()
        var rng = SplitMix64(state: seed)
        var env = self.env
        var out = Trace()
        var heartbeatSeq: UInt32 = 0
        var nextHeartbeat: TimeInterval = 1.0
        let steps = script.steps
        let end = (steps.last?.t ?? 0) + 4

        func record(_ events: [SynthEvent], at t: TimeInterval) {
            for event in events {
                switch event {
                case .mouseMove(let to, _, _, _, _): env.cursor = to
                case .setCapsLock(let on): env.capsLockOn = on
                default: break
                }
                out.timeline.append((t, event))
            }
        }

        /// Frames the messages, splits the bytes at random boundaries and hands every decoded
        /// message to the injector at the Mac time they arrive.
        func deliver(_ messages: [PadMessage], at t: TimeInterval) {
            guard !messages.isEmpty else { return }
            var bytes = Data()
            for message in messages {
                do { bytes.append(try WireV2.encode(message)) } catch {
                    XCTFail("encode \(message): \(error)", file: file, line: line)
                }
            }
            var received: [PadMessage] = []
            var offset = 0
            while offset < bytes.count {
                let remaining = bytes.count - offset
                let n = rng.below(4) == 0 ? remaining : 1 + rng.below(min(remaining, 48))
                do {
                    for message in try decoder.append(bytes.subdata(in: offset..<offset + n)) {
                        received.append(message)
                        record(injector.handle(message, at: Self.macTime(t), env: env), at: t)
                    }
                } catch {
                    XCTFail("decode at \(t): \(error)", file: file, line: line)
                }
                offset += n
            }
            XCTAssertEqual(received, messages, "wire round trip at \(t)", file: file, line: line)
        }

        func send(_ inputs: [PadInput], at t: TimeInterval) {
            out.signals += engine.drainSignals()
            guard !inputs.isEmpty else { return }
            out.sent += inputs
            deliver(inputs.map { .input($0, t: Int64((t * 1e6).rounded())) }, at: t)
            if (!engine.heldKeyCodes.isEmpty || !engine.heldButtons.isEmpty) && nextHeartbeat > t + 0.1 {
                nextHeartbeat = t + 0.1
            }
        }

        var i = 0
        var iterations = 0
        while iterations < 100_000 {
            iterations += 1
            let stepAt = i < steps.count ? steps[i].t : nil
            let engineAt = engine.nextDeadline
            let macDeadline = injector.nextDeadline
            let macAt = macDeadline.map { $0 - Self.macEpochOffset - Self.latency }
            let now = [stepAt, engineAt, macAt, nextHeartbeat].compactMap { $0 }.min()!
            if now > end, stepAt == nil { return out }

            if let d = engineAt, d <= now {
                send(engine.advance(to: d), at: d)
            } else if let d = macAt, let deadline = macDeadline, d <= now {
                record(injector.tick(at: deadline, env: env), at: d)
            } else if let t = stepAt, t <= now {
                let step = steps[i]
                i += 1
                switch step.kind {
                case .begin: send(engine.begin(step.touches, at: t), at: t)
                case .move: send(engine.move(step.touches, at: t), at: t)
                case .end: send(engine.end(step.touches, at: t), at: t)
                }
            } else {
                let held = engine.heldKeyCodes.sorted()
                let buttons = engine.heldButtons.sorted { $0.rawValue < $1.rawValue }
                let active = !held.isEmpty || !buttons.isEmpty
                heartbeatSeq &+= 1
                deliver([.heartbeat(Heartbeat(seq: heartbeatSeq, held: held, buttons: buttons, active: active),
                                    t: Int64((now * 1e6).rounded()))], at: now)
                nextHeartbeat = now + (active ? 0.1 : 1.0)
            }
        }
        XCTFail("the pipeline did not settle", file: file, line: line)
        return out
    }
}

/// Deterministic generator for the frame split points.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
}

private func assertTimes(_ a: [TimeInterval], _ b: [TimeInterval], accuracy: Double = 1e-6,
                         file: StaticString = #filePath, line: UInt = #line) {
    guard a.count == b.count else { return XCTFail("\(a) != \(b)", file: file, line: line) }
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, "\(a) != \(b)", file: file, line: line) }
}
