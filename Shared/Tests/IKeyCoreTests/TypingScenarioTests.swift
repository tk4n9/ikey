import Foundation
import XCTest
@testable import IKeyCore

// Executable behaviour spec for the resting-finger policy (plan amendments, section F), written
// against KeyCommitPipeline's public API with DEFAULT settings unless a test says otherwise.
//
// The policy in one paragraph: rest-capable keys (home-row letters, Space, every modifier) type
// only as a TAP (lift within tapMax = 0.30 s and within the travel limit); a longer contact is a
// REST and posts nothing, ever (not on press, not while held, not on release). isolatedHold is an
// opt-in (default off). Other keys keep the 45 ms confirmation and normal hold. Modifiers are lazy:
// they post only right before a key that commits while they are held (and then stay down until
// their contact lifts), or as down+up for a lone tap that is not part of a placement burst.
// Pointer modifiers come from an explicit call (proposed name `commitHeldModifiers(at:)`).
// Rollover keeps landing order, fast capitals and quick shortcuts work, and placement bursts never
// produce lone-modifier taps or modifiers from thumbs that then rest.
//
// Times are seconds. Every scenario also checks the I3-style invariants: no double down, no up
// without a down, nothing left posted after every contact lifted.
//
// Judge rulings pinned here (round 2):
// - One tap boundary, tapMax = 0.30 s, for home letters, Space, modifiers, tap-only codes and the
//   burst conversion of non-home keys: 0.29 s types, 0.31 s rests. A stored legacy
//   restThreshold/loneModifierTapMax of 0.25 must not move it.
// - Modifiers follow the tap rule (time and 4 mm travel) but isRestCapable stays false for them.
// - A modifier held past tapMax still chords (F3a has no duration limit), except when it settled
//   with resting contacts (P1, P2, P3b, bursts: F5 intent). PV4 (a modifier pressed after the
//   hands settled) chords. A chord-used modifier stays down until its contact lifts, and keys typed
//   while it is still down keep chording (F3a literal; see the LEAD DECISION test).
// - The user's Mac maps left Command (55) to Caps Lock, so the user's real configuration is
//   TypingSettings(tapOnlyCodes: [55]). Chord tests on 55 under default settings are generic Cmd
//   tests; section 14 runs the user's configuration through the shapes that matter for left Cmd.
// - Resting mode .off keeps today's modifier behaviour (posted at the confirmation delay).
//
// Round 3 (hunter probes tc-hunt-1, section 16):
// - 4+ keys of any kind landing together and staying undecided are a placement burst (a hand put
//   down off the home row), not only 3+ home-row keys.
// - A thumb tap that overlaps a placement (tap-only left Cmd, a lone modifier, Space) posts
//   nothing, also when it lifted before the burst formed; Space (and a tap-only key lifted before
//   the burst) still types when the burst's keys are a roll of taps.
// - A lone modifier tap is posted in landing order, after the keys that landed before it, and
//   still posts when a finger that landed during it rests (posted once that finger rests).
// - Not changed (lead decision needed): a settle bounce of 40 ms among resting hands (H4) still
//   posts its tap, because testDeliberateTapOfEveryRestCapableKeyPostsExactlyOneDownUp pins a
//   30 ms tap among resting hands as typing at its lift with no added delay.
//
// Round 4 (hunter probes tc-hunt-2, section 17):
// - A finger bouncing while the hand is put down never posts the thumb or pinky modifier that
//   settled with it (the bounce may type one plain letter, the earlier ruling).
// - A hand landing one key off with the index first on G or H never leaves that key held for the
//   Mac to repeat. If the other fingers land after G's 45 ms confirmation, one g may type (F2 pins a
//   lone held G as down at 45 ms), but G is released as soon as the burst forms.
// - Thumb taps (Space, tap-only left Cmd) never confirm a roll for each other; one finger's
//   bounce (<= 50 ms) alone does not either. A tap-only tap of <= 50 ms waits 50 ms for a thumb
//   settling onto it or onto Space/Cmd/Option. Still open (as H4): a 30 ms Space graze before the
//   thumb settles on left Cmd types a space.
// - A modifier landing late in a fast roll keeps chording; a tap-only switch held while a roll
//   forms a burst still switches. Hover typists keep Cmd+key after one anchoring finger.
//
// Round 5 (hunter probes tc-hunt-3, section 18):
// - Fingers bouncing (key landing again within 50 ms) never confirm a roll, so two bouncing
//   fingers no longer post a settling thumb's modifier; nor does one finger bouncing while the
//   thumb grazes its modifier.
// - A modifier landing within chordTolerance AFTER a home-row or Space tap applies to it only if
//   it lifts first (a fast capital; the tap waits up to the modifier's tapMax). Still held, it
//   rests (a thumb settling beside the stroke) unless a key lands under it within 0.2 s.
// - Three or more burst keys landing within 25 ms and lifting together (lifts chained <= 8 ms
//   apart) are a hand pat or reposition and type nothing. The pinned 10 ms-spaced rolls still type.
// - A Space or switch tap that leads a placement while typing is in flow types unless the thumb
//   lands on the thumb row within 0.15 s of its lift (the H2/H2b bounces and the silent "placed"
//   control have no typing before them).
// - A key and a modifier landing within chordTolerance of each other and resting are a hand put
//   down: the modifier rests. Space and letter taps in flight are not "settling fingers" for PV4.
// - A short switch or Space tap followed within 50 ms by a thumb-row contact is a bounce only if
//   that contact does not lift as a tap. A modifier pressed after its own hand settled (PV4) is
//   not settled by the OTHER hand landing (a burst or a key resting on the other hand).

// MARK: - Key codes (Mac virtual key codes, ANSI)

fileprivate enum TSKey {
    static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, f: UInt16 = 3, h: UInt16 = 4, g: UInt16 = 5
    static let z: UInt16 = 6, c: UInt16 = 8, q: UInt16 = 12, e: UInt16 = 14, t: UInt16 = 17
    static let one: UInt16 = 18
    static let ret: UInt16 = 36, l: UInt16 = 37, j: UInt16 = 38, k: UInt16 = 40, semicolon: UInt16 = 41
    static let tab: UInt16 = 48, space: UInt16 = 49, delete: UInt16 = 51, escape: UInt16 = 53
    static let rcmd: UInt16 = 54, lcmd: UInt16 = 55, lshift: UInt16 = 56, caps: UInt16 = 57
    static let lopt: UInt16 = 58, lctrl: UInt16 = 59, rshift: UInt16 = 60, ropt: UInt16 = 61
    static let rctrl: UInt16 = 62, fn: UInt16 = 63
    static let leftArrow: UInt16 = 123, upArrow: UInt16 = 126
    static let w: UInt16 = 13, r: UInt16 = 15, u: UInt16 = 32, i: UInt16 = 34, o: UInt16 = 31
    static let p: UInt16 = 35, v: UInt16 = 9, two: UInt16 = 19

    static let leftHand: [UInt16] = [a, s, d, f]
    static let rightHand: [UInt16] = [j, k, l, semicolon]
    static let homeLetters: [UInt16] = leftHand + rightHand
    static let bothHands: [UInt16] = [f, j, d, k, s, l, a, semicolon]
    static let allModifiers: [UInt16] = [rcmd, lcmd, lshift, lopt, lctrl, rshift, ropt, rctrl, fn]
    static let leftSideModifiers: Set<UInt16> = [lcmd, lshift, lopt, lctrl, fn]
    /// Keys a resting thumb or pinky typically lies on.
    static let thumbKeys: [UInt16] = [space, lcmd, rcmd, lshift, rshift, lopt, ropt]
    /// Every key the policy calls rest-capable (default homeRow mode): home row, Space, modifiers.
    static let restCapable: [UInt16] = homeLetters + [space] + allModifiers
}

fileprivate let tsCharCodes: [Character: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
    "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
    "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
]
fileprivate let tsLeftHandChars: Set<Character> = Set("qwertasdfgzxcvb12345`")

// MARK: - Scenario script

fileprivate struct TSScenario {
    enum Action {
        case land(id: Int, code: UInt16, broad: Bool)
        case lift(id: Int, cancelled: Bool)
        case move(id: Int, mm: Double)
        case reject(id: Int)
        case foreignContact
        case commitHeldModifiers
        case flushModifiersForPointer
        case pointerUse
    }
    struct Step { let t: TimeInterval; let seq: Int; let action: Action }

    private(set) var steps: [Step] = []
    private var nextID = 1

    mutating func at(_ t: TimeInterval, _ action: Action) {
        steps.append(Step(t: t, seq: steps.count, action: action))
    }

    /// One contact on `code` from `down` to `up`. `slideMM` is reached halfway through.
    @discardableResult
    mutating func touch(_ code: UInt16, _ down: TimeInterval, _ up: TimeInterval,
                        slideMM: Double? = nil, broad: Bool = false, cancelled: Bool = false) -> Int {
        let id = nextID
        nextID += 1
        at(down, .land(id: id, code: code, broad: broad))
        if let mm = slideMM { at((down + up) / 2, .move(id: id, mm: mm)) }
        at(up, .lift(id: id, cancelled: cancelled))
        return id
    }

    /// Every contact as (code, landing, lift), in landing order (ties by creation order).
    var spans: [(code: UInt16, down: TimeInterval, up: TimeInterval)] {
        var landed: [Int: (UInt16, TimeInterval, Int)] = [:]
        var out: [(code: UInt16, down: TimeInterval, up: TimeInterval, seq: Int)] = []
        for step in steps {
            switch step.action {
            case .land(let id, let code, _): landed[id] = (code, step.t, step.seq)
            case .lift(let id, _):
                if let l = landed[id] { out.append((l.0, l.1, step.t, l.2)) }
            default: break
            }
        }
        return out.sorted { $0.down == $1.down ? $0.seq < $1.seq : $0.down < $1.down }
            .map { ($0.code, $0.down, $0.up) }
    }

    @discardableResult
    mutating func tap(_ code: UInt16, at t: TimeInterval, for duration: TimeInterval = 0.08) -> Int {
        touch(code, t, t + duration)
    }

    /// Fingers landing `spacing` apart from `start` and resting until `end` (lifting 10 ms apart).
    mutating func rest(_ codes: [UInt16], from start: TimeInterval, spacing: TimeInterval = 0.01,
                       until end: TimeInterval) {
        for (i, code) in codes.enumerated() {
            touch(code, start + Double(i) * spacing, end + Double(i) * 0.01)
        }
    }

    /// Rollover typing: one key every 12/wpm s (±8 ms deterministic jitter), each held
    /// `overlap` x that interval (so neighbours overlap), capped at 0.22 s. A repeated key lifts
    /// before it is pressed again. Capitals use the opposite-hand Shift, landing 30 ms before the
    /// letter and lifting 40 ms after it lands (before the letter lifts).
    mutating func type(_ text: String, from start: TimeInterval, wpm: Double, overlap: Double = 1.3,
                       seed: UInt64 = 1) {
        let ioi = 12.0 / wpm
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        func jitter() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(state >> 11) / Double(UInt64(1) << 53) - 0.5) * 0.016
        }
        let chars = Array(text)
        let onsets = chars.indices.map { start + Double($0) * ioi + jitter() }
        for (i, ch) in chars.enumerated() {
            let lower = Character(ch.lowercased())
            guard let code = tsCharCodes[lower] else { continue }
            var hold = min(ioi * overlap, 0.22)
            if i + 1 < chars.count, Character(chars[i + 1].lowercased()) == lower {
                hold = min(hold, onsets[i + 1] - onsets[i] - 0.015)
            }
            touch(code, onsets[i], onsets[i] + hold)
            if ch.isUppercase {
                let shift = tsLeftHandChars.contains(lower) ? TSKey.rshift : TSKey.lshift
                touch(shift, onsets[i] - 0.03, onsets[i] + 0.04)
            }
        }
    }
}

// MARK: - Outcome and Mac-side rendering

fileprivate struct TSOutcome {
    struct Event { let t: TimeInterval; let code: UInt16; let down: Bool }
    var events: [Event] = []
    var violations: [String] = []

    /// "+55@0.300" style, like the other pipeline tests.
    var timed: [String] { events.map { "\($0.down ? "+" : "-")\($0.code)@\(tsFormat($0.t))" } }
    var postedCodes: Set<UInt16> { Set(events.map(\.code)) }
    func downs(of code: UInt16) -> [TimeInterval] { events.filter { $0.code == code && $0.down }.map(\.t) }
    /// What the Mac would type: shifted letters upper-case, other chords as "⌃⌥⇧⌘x", lone
    /// modifier taps as "[LCmd]".
    var text: String { tsRender(events) }
    /// `text` without the lone-modifier tokens.
    var letters: String {
        var out = ""
        var skipping = false
        for ch in text {
            if ch == "[" { skipping = true } else if ch == "]" && skipping { skipping = false } else if !skipping { out.append(ch) }
        }
        return out
    }
}

fileprivate func tsFormat(_ t: TimeInterval) -> String { String(format: "%.3f", t) }

fileprivate func tsModifierName(_ code: UInt16) -> String {
    switch code {
    case 54: return "RCmd"
    case 55: return "LCmd"
    case 56: return "LShift"
    case 58: return "LOpt"
    case 59: return "LCtrl"
    case 60: return "RShift"
    case 61: return "ROpt"
    case 62: return "RCtrl"
    case 63: return "fn"
    default: return "#\(code)"
    }
}

fileprivate func tsKeyName(_ code: UInt16) -> String {
    if let ch = tsCharCodes.first(where: { $0.value == code })?.key { return String(ch) }
    switch code {
    case 36: return "⏎"
    case 48: return "⇥"
    case 51: return "⌫"
    case 53: return "⎋"
    case 57: return "⇪"
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    default: return "#\(code)"
    }
}

fileprivate func tsRender(_ events: [TSOutcome.Event]) -> String {
    var held = Set<UInt16>()
    var unused = Set<UInt16>()
    var out = ""
    for e in events {
        if KeyCommitPipeline.modifierCodes.contains(e.code) {
            if e.down {
                held.insert(e.code)
                unused.insert(e.code)
            } else {
                held.remove(e.code)
                if unused.remove(e.code) != nil { out += "[\(tsModifierName(e.code))]" }
            }
            continue
        }
        guard e.down else { continue }
        unused.removeAll()
        let shift = !held.isDisjoint(with: [56, 60]), cmd = !held.isDisjoint(with: [54, 55])
        let opt = !held.isDisjoint(with: [58, 61]), ctrl = !held.isDisjoint(with: [59, 62])
        let fn = held.contains(63)
        let name = tsKeyName(e.code)
        if shift, !cmd, !opt, !ctrl, !fn, name.count == 1, name.first!.isLetter {
            out += name.uppercased()
        } else {
            out += (ctrl ? "⌃" : "") + (opt ? "⌥" : "") + (shift ? "⇧" : "") + (cmd ? "⌘" : "")
                + (fn ? "fn" : "") + name
        }
    }
    return out
}

// MARK: - Proposed pointer-modifier API shim

/// Policy F3 proposes `commitHeldModifiers(at:) -> [PipelineOutput]` (posts the held, non-suspect
/// modifiers before a trackpad click, scroll or drag). While KeyCommitPipeline does not declare it,
/// this fallback fails the calling test and forwards to `flushModifiersForPointer(at:)` so the rest
/// of the expectations still run. Once the pipeline declares it, its own method is the one called
/// (a type's member wins over a protocol-extension default) and this fallback goes dead.
fileprivate protocol TSPointerModifierAPI {
    mutating func flushModifiersForPointer(at time: TimeInterval) -> [PipelineOutput]
    mutating func commitHeldModifiers(at time: TimeInterval) -> [PipelineOutput]
}

extension TSPointerModifierAPI {
    mutating func commitHeldModifiers(at time: TimeInterval) -> [PipelineOutput] {
        XCTFail("KeyCommitPipeline.commitHeldModifiers(at:) is not declared yet (policy F3 pointer modifiers)")
        return flushModifiersForPointer(at: time)
    }
}

extension KeyCommitPipeline: TSPointerModifierAPI {}

// MARK: - Runner

/// Plays the script as W2-ENGINE would: every deadline before the next input fires at its own
/// time through `advance(to:)`, then the input is applied at its time.
fileprivate func tsPlay(_ scenario: TSScenario, _ settings: TypingSettings = TypingSettings(),
                        confirmationDelay: TimeInterval = 0.045, tail: TimeInterval = 1.5) -> TSOutcome {
    var pipeline = KeyCommitPipeline(settings: settings, confirmationDelay: confirmationDelay)
    var outcome = TSOutcome()
    var down = Set<UInt16>()

    func record(_ t: TimeInterval, _ out: [PipelineOutput]) {
        for case .key(let code, let isDown) in out {
            if isDown {
                if !down.insert(code).inserted { outcome.violations.append("double down \(code)@\(tsFormat(t))") }
            } else if down.remove(code) == nil {
                outcome.violations.append("up without down \(code)@\(tsFormat(t))")
            }
            outcome.events.append(.init(t: t, code: code, down: isDown))
        }
    }
    func drain(before t: TimeInterval) {
        var last = -Double.infinity
        var guardCount = 0
        while let d = pipeline.nextDeadline, d < t, d > last, guardCount < 100_000 {
            record(d, pipeline.advance(to: d))
            last = d
            guardCount += 1
        }
    }

    let steps = scenario.steps.sorted { $0.t == $1.t ? $0.seq < $1.seq : $0.t < $1.t }
    for step in steps {
        let t = step.t
        drain(before: t)
        switch step.action {
        case .land(let id, let code, let broad):
            record(t, pipeline.land(id: id, code: code, at: t, broadThumb: broad))
        case .lift(let id, let cancelled):
            record(t, pipeline.lift(id: id, at: t, cancelled: cancelled))
        case .move(let id, let mm):
            record(t, pipeline.move(id: id, travelMM: mm, at: t))
        case .reject(let id):
            record(t, pipeline.reject(id: id, at: t))
        case .foreignContact:
            pipeline.noteForeignContact(at: t)
        case .commitHeldModifiers:
            record(t, pipeline.commitHeldModifiers(at: t))
        case .flushModifiersForPointer:
            record(t, pipeline.flushModifiersForPointer(at: t))
        case .pointerUse:
            pipeline.notePointerUse(at: t)
        }
    }
    let end = (steps.last?.t ?? 0) + tail
    drain(before: end)
    record(end, pipeline.advance(to: end))
    if !pipeline.postedCodes.isEmpty {
        outcome.violations.append("still posted after every lift: \(pipeline.postedCodes.sorted())")
    }
    return outcome
}

// MARK: - Tests

final class TypingScenarioTests: XCTestCase {
    private typealias K = TSKey

    // MARK: Assertion helpers

    private func assertClean(_ o: TSOutcome, _ label: String, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(o.violations, [], "invariants: \(label)", file: file, line: line)
    }

    /// Nothing at all reaches the Mac.
    private func assertSilent(_ o: TSOutcome, _ label: String, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(o.timed, [], label, file: file, line: line)
        assertClean(o, label, file: file, line: line)
    }

    /// Exactly one down and one up of `code`, both at `t`.
    private func assertTapPosted(_ o: TSOutcome, _ code: UInt16, at t: TimeInterval, _ label: String,
                                 file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(o.timed, ["+\(code)@\(tsFormat(t))", "-\(code)@\(tsFormat(t))"], label, file: file, line: line)
        assertClean(o, label, file: file, line: line)
    }

    private func assertNoModifierPosted(_ o: TSOutcome, _ label: String, file: StaticString = #file, line: UInt = #line) {
        let posted = o.postedCodes.intersection(KeyCommitPipeline.modifierCodes)
        XCTAssertEqual(posted, [], "no modifier may be posted: \(label) \(o.timed)", file: file, line: line)
    }

    /// The hand(s) that stay resting while `code` is tapped deliberately.
    private func oppositeHand(of code: UInt16) -> [UInt16] {
        if K.leftHand.contains(code) || K.leftSideModifiers.contains(code) { return K.rightHand }
        return K.leftHand
    }

    // MARK: 1. Settings

    // Rule F1: isolatedHold is opt-in (default OFF); rest mode defaults to homeRow; stored settings
    // without the field decode to the new default.
    func testPolicyDefaults_IsolatedHoldIsOptInAndRestModeIsHomeRow() throws {
        let defaults = TypingSettings()
        XCTAssertEqual(defaults.resting, .homeRow)
        XCTAssertFalse(defaults.isolatedHold, "isolatedHold must default to OFF (policy F1)")
        let decoded = try JSONDecoder().decode(TypingSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.isolatedHold, "a missing isolatedHold field must decode as OFF")
        for code in K.homeLetters + [K.space] {
            XCTAssertTrue(defaults.isRestCapable(code), "home-row key \(code) is rest-capable")
        }
        for code: UInt16 in [K.e, K.t, K.g, K.h, K.delete, K.ret, K.tab, K.one] {
            XCTAssertFalse(defaults.isRestCapable(code), "key \(code) is not rest-capable")
        }
        // Ruling: modifiers follow the tap rule as BEHAVIOUR only; isRestCapable (and so placement
        // burst counting via burstMinRestCapable) stays unchanged for them.
        for code in K.allModifiers {
            XCTAssertFalse(defaults.isRestCapable(code), "modifier \(code) keeps isRestCapable == false")
        }
    }

    // Ruling (tapMax): the one 0.30 s boundary does not move when stored settings carry the legacy
    // fields at their old values (restThreshold 0.25, loneModifierTapMax 0.25): a 0.29 s tap of a
    // home letter, Space, a modifier and a burst non-home key still types; 0.31 s still rests.
    func testLegacyStoredThresholdsDoNotMoveTheTapBoundary() throws {
        let json = #"{"restThreshold":0.25,"spaceRestThreshold":0.30,"loneModifierTapMax":0.25,"modifierReveal":0.30}"#
        let stored = try JSONDecoder().decode(TypingSettings.self, from: Data(json.utf8))
        for code in [K.f, K.k, K.space, K.lshift, K.rcmd] {
            var under = TSScenario()
            under.tap(code, at: 1.0, for: 0.29)
            assertTapPosted(tsPlay(under, stored), code, at: 1.29, "stored legacy settings, \(code) 0.29 s")
            var over = TSScenario()
            over.tap(code, at: 1.0, for: 0.31)
            assertSilent(tsPlay(over, stored), "stored legacy settings, \(code) 0.31 s")
        }
        // A non-home key converted by a placement burst also uses tapMax: H held 0.27 s in a roll.
        var dash = TSScenario()
        dash.touch(K.d, 0, 0.08); dash.touch(K.a, 0.03, 0.11); dash.touch(K.s, 0.06, 0.14)
        dash.touch(K.h, 0.09, 0.36)
        let o = tsPlay(dash, stored)
        XCTAssertEqual(o.text, "dash", "burst-converted H held 0.27 s types under stored legacy settings")
        assertClean(o, "dash, stored legacy settings")
    }

    // MARK: 2. Resting hands

    // Rule F1: 4 to 10 fingers resting on the home row (thumbs on Space) for seconds post nothing,
    // whether they land together, in a wave, or one by one (a lone first finger also rests).
    func testRestingHomeRow4To10FingersForSecondsPostsNothing() {
        let fingers: [UInt16] = K.bothHands + [K.space, K.space]
        let styles: [(String, TimeInterval)] = [("together", 0.01), ("wave", 0.03), ("one-by-one", 0.4)]
        for n in 4...10 {
            for (style, spacing) in styles {
                var sc = TSScenario()
                for i in 0..<n {
                    let landing = Double(i) * spacing
                    sc.touch(fingers[i], landing, landing + 5.0 + Double(n - i) * 0.01)
                }
                assertSilent(tsPlay(sc), "\(n) fingers, \(style)")
            }
        }
    }

    // Rule F1: resting fingers that drift inside the travel limit, or slide past it, post nothing.
    func testRestingFingersThatDriftOrSlidePostNothing() {
        for slide in [1.0, 3.5, 6.0, 12.0] {
            var sc = TSScenario()
            for (i, code) in K.bothHands.enumerated() {
                sc.touch(code, Double(i) * 0.01, 4.0, slideMM: slide)
            }
            sc.touch(K.space, 0.1, 4.0, slideMM: slide)
            assertSilent(tsPlay(sc), "drift \(slide) mm")
        }
    }

    // Rule F1: hands lifting off and settling again (three cycles) post nothing on any land or lift.
    func testHandsLiftingAndResettlingPostNothing() {
        var sc = TSScenario()
        for cycle in 0..<3 {
            let start = Double(cycle) * 2.0
            sc.rest(K.bothHands, from: start, spacing: 0.015, until: start + 1.5)
            sc.touch(K.space, start + 0.05, start + 1.55)
        }
        assertSilent(tsPlay(sc), "three placement cycles")
    }

    // Amendment B (W2-ENGINE test) and F1: a palm already down, then J held 1 s, posts nothing.
    func testPalmDownThenHeldHomeKeyPostsNothing() {
        var sc = TSScenario()
        sc.at(0, .foreignContact)
        sc.touch(K.j, 0.1, 1.1)
        sc.at(0.1, .foreignContact)
        assertSilent(tsPlay(sc), "palm then J")
    }

    // MARK: 3. Resting thumbs

    // Rule F1/F3: a thumb or pinky resting alone on Space or any modifier posts nothing, including
    // when it finally lifts (verifier P3, P15).
    func testRestingThumbAloneOnAnyThumbKeyPostsNothingEvenOnRelease() {
        for code in [K.space] + K.allModifiers {
            for held in [0.35, 1.0, 3.0, 5.0] {
                var sc = TSScenario()
                sc.touch(code, 0, held)
                assertSilent(tsPlay(sc), "code \(code) held \(held) s")
            }
        }
    }

    // Rules F1/F3/F5: a thumb resting on Space, left/right Cmd, Shift or Option together with resting
    // hands posts nothing, whether it lands first, just before, during or after the placement burst,
    // long after the hands settled, with or without the other thumb on Space, and in either lift order.
    func testRestingThumbWithRestingHandsPostsNothingInEveryLandingOrder() {
        assertRestingThumbMatrixSilent(K.thumbKeys, TypingSettings())
    }

    /// The resting-thumb landing-order matrix (thumb first, just before, during, last, after the
    /// settle, long after; one or both hands; with or without the other thumb on Space; either lift
    /// order) posts nothing.
    private func assertRestingThumbMatrixSilent(_ thumbs: [UInt16], _ settings: TypingSettings,
                                                file: StaticString = #file, line: UInt = #line) {
        let orders: [(String, thumb: TimeInterval, hands: TimeInterval)] = [
            ("thumb first", 0, 0.5), ("thumb just before", 0, 0.05), ("thumb during burst", 0.035, 0),
            ("thumb last", 0.10, 0), ("thumb after settle", 1.0, 0), ("thumb long after", 2.5, 0),
        ]
        let hands: [(String, [UInt16])] = [("both hands", K.bothHands), ("left hand", K.leftHand)]
        for thumb in thumbs {
            for (orderName, thumbAt, handsAt) in orders {
                for (handName, fingers) in hands {
                    for withSpaceThumb in [false, true] {
                        for thumbLiftsFirst in [true, false] {
                            var sc = TSScenario()
                            let thumbUp = thumbLiftsFirst ? 4.0 : 4.6
                            let handsUp = thumbLiftsFirst ? 4.3 : 4.0
                            sc.rest(fingers, from: handsAt, until: handsUp)
                            sc.touch(thumb, thumbAt, thumbUp)
                            if withSpaceThumb { sc.touch(K.space, thumbAt + 0.02, thumbUp + 0.05) }
                            assertSilent(tsPlay(sc, settings), "thumb \(thumb), \(orderName), \(handName), "
                                         + "spaceThumb \(withSpaceThumb), thumbLiftsFirst \(thumbLiftsFirst)",
                                         file: file, line: line)
                        }
                    }
                }
            }
        }
    }

    // Rules F1/F3: two thumbs (or pinky + thumb) resting with no hands on the keys post nothing
    // (verifier P12, P3b without typing, the earlier Cmd+Space / Shift+Space repeat probes).
    func testTwoRestingThumbsWithoutHandsPostNothing() {
        let pairs: [(UInt16, UInt16)] = [(K.space, K.lcmd), (K.lcmd, K.space), (K.space, K.rcmd),
                                         (K.lcmd, K.rcmd), (K.lshift, K.space), (K.lcmd, K.rshift),
                                         (K.lopt, K.space), (K.space, K.space)]
        for (first, second) in pairs {
            for gap in [0.02, 0.5] {
                var sc = TSScenario()
                sc.touch(first, 0, 3.0)
                sc.touch(second, gap, 3.0 + gap)
                assertSilent(tsPlay(sc), "\(first) then \(second) after \(gap) s")
            }
        }
    }

    // Rules F3b/F5: a thumb that bounces on a modifier while the hand is being placed (lifts within
    // tapMax, lands again and rests) never produces a lone-modifier tap (verifier TB1, TB1b, TB1c).
    func testModifierThumbBouncingDuringPlacementPostsNothing() {
        for mod in [K.lcmd, K.rcmd, K.lshift, K.lopt, K.rshift] {
            // TB1 shape: the hand lands first, the thumb lands in the burst and bounces.
            var sc = TSScenario()
            sc.rest(K.leftHand, from: 0, until: 3.0)
            sc.touch(mod, 0.05, 0.11)
            sc.touch(mod, 0.16, 3.0)
            assertSilent(tsPlay(sc), "TB1 bounce of \(mod)")

            // TB1b shape: the thumb lands first, the hand follows, the thumb bounces off and back.
            var sc2 = TSScenario()
            sc2.touch(mod, 0, 0.12)
            sc2.rest(K.leftHand, from: 0.03, until: 3.0)
            sc2.touch(mod, 0.18, 3.0)
            assertSilent(tsPlay(sc2), "TB1b bounce of \(mod)")

            // Thumb bouncing in the middle of a two-hand placement.
            var sc3 = TSScenario()
            sc3.rest(K.bothHands, from: 0, until: 3.0)
            sc3.touch(mod, 0.03, 0.09)
            sc3.touch(mod, 0.14, 3.0)
            assertSilent(tsPlay(sc3), "mid-burst bounce of \(mod)")
        }
    }

    // Rule F3b: a modifier contact that lasts under tapMax but overlaps a placement burst is part
    // of the burst and posts nothing (verifier TB3, pinned as a drop).
    func testModifierTapOverlappingHandPlacementPostsNothing() {
        for mod in [K.lcmd, K.rcmd, K.lshift] {
            var sc = TSScenario()
            sc.touch(mod, 0, 0.15)
            sc.rest(K.leftHand, from: 0.05, until: 3.0)
            assertSilent(tsPlay(sc), "TB3 shape with \(mod)")
        }
    }

    // Rule F1 (movement limit): a thumb sliding on a modifier past the travel limit is not a tap
    // and posts nothing; a small wobble inside the limit still taps.
    func testThumbSlidingOnModifierIsNotATap() {
        for mod in [K.lcmd, K.rcmd, K.lshift] {
            var slide = TSScenario()
            slide.touch(mod, 0, 0.2, slideMM: 6.0)
            assertSilent(tsPlay(slide), "slide 6 mm on \(mod)")

            var wobble = TSScenario()
            wobble.touch(mod, 0, 0.2, slideMM: 2.0)
            assertTapPosted(tsPlay(wobble), mod, at: 0.2, "wobble 2 mm on \(mod)")
        }
    }

    // MARK: 4. Deliberate taps of rest-capable keys

    // Rule F1/F3b: a deliberate tap (≤ tapMax) of EVERY rest-capable key posts exactly one down/up
    // at lift, alone, with the opposite hand resting, and with the hands plus a thumb resting.
    func testDeliberateTapOfEveryRestCapableKeyPostsExactlyOneDownUp() {
        for code in K.restCapable {
            for duration in [0.03, 0.10, 0.20, 0.28] {
                for context in ["alone", "opposite hand resting", "hands and thumb resting"] {
                    var sc = TSScenario()
                    switch context {
                    case "opposite hand resting":
                        sc.rest(oppositeHand(of: code), from: 0, until: 2.0)
                    case "hands and thumb resting":
                        sc.rest(K.bothHands.filter { $0 != code }, from: 0, until: 2.0)
                        sc.touch(K.space, 0.08, 2.1)
                    default:
                        break
                    }
                    sc.tap(code, at: 1.0, for: duration)
                    assertTapPosted(tsPlay(sc), code, at: 1.0 + duration,
                                    "tap of \(code) for \(duration) s, \(context)")
                }
            }
        }
    }

    // Rule F1: tapMax (0.30 s) is the boundary for every rest-capable key: 0.29 s types, 0.31 s rests.
    func testTapJustUnderTapMaxTypesAndJustOverRests() {
        for code in [K.f, K.j, K.semicolon, K.space, K.lcmd, K.rshift, K.lopt] {
            for resting in [false, true] {
                var under = TSScenario()
                var over = TSScenario()
                if resting {
                    under.rest(oppositeHand(of: code), from: 0, until: 2.0)
                    over.rest(oppositeHand(of: code), from: 0, until: 2.0)
                }
                under.tap(code, at: 1.0, for: 0.29)
                over.tap(code, at: 1.0, for: 0.31)
                assertTapPosted(tsPlay(under), code, at: 1.29, "\(code) 0.29 s, resting hand \(resting)")
                assertSilent(tsPlay(over), "\(code) 0.31 s, resting hand \(resting)")
            }
        }
    }

    // Rule F1 (movement limit, 4 mm): a rest-capable tap that moves within the limit types; one
    // that slides past it rests. Ruling: the same limit applies to modifiers.
    func testRestCapableTapWithinTravelLimitTypesButSlideRests() {
        for code in [K.f, K.k, K.space, K.lcmd, K.rcmd, K.rshift, K.lopt] {
            var small = TSScenario()
            small.touch(code, 0, 0.15, slideMM: 3.0)
            assertTapPosted(tsPlay(small), code, at: 0.15, "\(code) moved 3 mm")

            var slide = TSScenario()
            slide.touch(code, 0, 0.15, slideMM: 5.0)
            assertSilent(tsPlay(slide), "\(code) slid 5 mm")
        }
    }

    // Rule F1: quick double taps of the same rest-capable key type twice ("ff", two spaces).
    func testQuickDoubleTapsOfARestCapableKeyTypeTwice() {
        for code in [K.f, K.l, K.space] {
            var sc = TSScenario()
            sc.tap(code, at: 0, for: 0.06)
            sc.tap(code, at: 0.10, for: 0.06)
            let o = tsPlay(sc)
            XCTAssertEqual(o.timed, ["+\(code)@0.060", "-\(code)@0.060", "+\(code)@0.160", "-\(code)@0.160"], "\(code)")
            assertClean(o, "double tap \(code)")
        }
    }

    // MARK: 5. Left Command (the user's input-source switch)

    // Rule F3b + user remap: a deliberate tap of left Command alone posts Cmd down+up at lift.
    func testLeftCommandTapAlonePostsCmdDownUp() {
        for duration in [0.05, 0.12, 0.20, 0.26, 0.28, 0.29] {
            var sc = TSScenario()
            sc.tap(K.lcmd, at: 0, for: duration)
            assertTapPosted(tsPlay(sc), K.lcmd, at: duration, "left Cmd tap \(duration) s (verifier P4)")
        }
    }

    // Rule F3b: a left Command tap while both hands and the right thumb rest still switches.
    func testLeftCommandTapWhileHandsAndRightThumbRestPostsDownUp() {
        for duration in [0.10, 0.24, 0.29] {
            var sc = TSScenario()
            sc.rest(K.bothHands, from: 0, until: 3.0)
            sc.touch(K.space, 0.02, 3.0)
            sc.tap(K.lcmd, at: 1.5, for: duration)
            assertTapPosted(tsPlay(sc), K.lcmd, at: 1.5 + duration, "left Cmd \(duration) s among resting hands")
        }
    }

    // Rule F3b: repeated deliberate left Command taps each post exactly one down+up.
    func testRepeatedLeftCommandTapsSwitchEachTime() {
        var sc = TSScenario()
        sc.rest(K.rightHand, from: 0, until: 3.0)
        for start in [1.0, 1.6, 2.2] { sc.tap(K.lcmd, at: start, for: 0.12) }
        let o = tsPlay(sc)
        XCTAssertEqual(o.timed, ["+55@1.120", "-55@1.120", "+55@1.720", "-55@1.720", "+55@2.320", "-55@2.320"])
        assertClean(o, "three switches")
    }

    // Rule F3b: left Command held past tapMax (a resting thumb) posts nothing, alone or among hands.
    func testLeftCommandHeldPastTapMaxPostsNothing() {
        for held in [0.31, 0.5, 2.0] {
            var alone = TSScenario()
            alone.tap(K.lcmd, at: 0, for: held)
            assertSilent(tsPlay(alone), "left Cmd alone \(held) s")

            var hands = TSScenario()
            hands.rest(K.bothHands, from: 0, until: 4.0)
            hands.tap(K.lcmd, at: 1.0, for: held)
            assertSilent(tsPlay(hands), "left Cmd among hands \(held) s")
        }
    }

    // Rule F3b (resolution): a left Command tap right after typing, or overlapping the end of a
    // letter that landed before it (outside chordTolerance), is still a lone tap and switches.
    func testLeftCommandTapAfterOrOverlappingTypingStillSwitches() {
        var after = TSScenario()
        after.tap(K.a, at: 0, for: 0.08)
        after.tap(K.t, at: 0.12, for: 0.08)
        after.tap(K.lcmd, at: 0.35, for: 0.10)
        let o1 = tsPlay(after)
        XCTAssertEqual(o1.text, "at[LCmd]")
        assertClean(o1, "tap after typing")

        var overlap = TSScenario()
        overlap.tap(K.a, at: 0, for: 0.10)
        overlap.tap(K.lcmd, at: 0.06, for: 0.12)
        let o2 = tsPlay(overlap)
        XCTAssertEqual(o2.text, "a[LCmd]", "'a' landed 60 ms before Cmd: plain a, then a Cmd tap")
        assertClean(o2, "overlapping tap")
    }

    // MARK: 6. Chords

    // Rule F3a: Cmd held, a quick tap of a home-row key (or Space) posts Cmd immediately before the
    // key at the key's lift; Cmd stays down until its own contact lifts.
    func testCmdPlusQuickHomeRowTapPostsChordAtTheKeysLift() {
        for mod in [K.lcmd, K.rcmd] {
            for key in K.homeLetters + [K.space] {
                var sc = TSScenario()
                sc.touch(mod, 0, 0.40)
                sc.touch(key, 0.12, 0.20)
                let o = tsPlay(sc)
                XCTAssertEqual(o.timed, ["+\(mod)@0.200", "+\(key)@0.200", "-\(key)@0.200", "-\(mod)@0.400"],
                               "Cmd \(mod) + \(key)")
                assertClean(o, "Cmd \(mod) + \(key)")
            }
        }
    }

    // Rule F2/F3a: Cmd held + a non-rest-capable key posts the chord at the 45 ms confirmation.
    func testCmdPlusNonHomeKeyPostsChordAtConfirmation() {
        var sc = TSScenario()
        sc.touch(K.lcmd, 0, 0.5)
        sc.touch(K.q, 0.15, 0.25)
        let o = tsPlay(sc)
        XCTAssertEqual(o.timed, ["+55@0.195", "+12@0.195", "-12@0.250", "-55@0.500"])
        assertClean(o, "Cmd+Q")
    }

    // Rule F3a + F04 acceptance: Cmd held 3 s with no other contacts, then Tab, posts Cmd+Tab;
    // Cmd is posted only with Tab and released at its own lift (no stale release).
    func testCmdHeld3sAloneThenTabPostsCmdTab() {
        var sc = TSScenario()
        sc.touch(K.lcmd, 0, 3.5)
        sc.touch(K.tab, 3.0, 3.08)
        let o = tsPlay(sc)
        XCTAssertEqual(o.timed, ["+55@3.045", "+48@3.045", "-48@3.080", "-55@3.500"])
        assertClean(o, "Cmd held then Tab")
    }

    // Rule F3a: Cmd held long, then a quick S, still chords (Cmd is never posted before S commits).
    func testCmdHeldLongThenQuickSChords() {
        var sc = TSScenario()
        sc.touch(K.lcmd, 0, 2.0)
        sc.touch(K.s, 1.5, 1.58)
        let o = tsPlay(sc)
        XCTAssertEqual(o.timed, ["+55@1.580", "+1@1.580", "-1@1.580", "-55@2.000"])
        assertClean(o, "Cmd held long then S")
    }

    // Rule F3a: a deliberate Cmd+S typed while the hands and the other thumb rest (the S finger
    // leaves its rest, taps, and rests again) chords exactly once.
    func testCmdSWhileHandsRestChords() {
        var sc = TSScenario()
        sc.touch(K.a, 0, 3.0)
        sc.touch(K.s, 0.01, 0.9)
        sc.touch(K.d, 0.02, 3.0)
        sc.touch(K.f, 0.03, 3.0)
        sc.rest(K.rightHand, from: 0.04, until: 3.0)
        sc.touch(K.space, 0.05, 3.0)
        sc.touch(K.lcmd, 1.0, 1.45)
        sc.touch(K.s, 1.15, 1.23)
        sc.touch(K.s, 1.5, 3.0)
        let o = tsPlay(sc)
        XCTAssertEqual(o.timed, ["+55@1.230", "+1@1.230", "-1@1.230", "-55@1.450"])
        XCTAssertEqual(o.text, "⌘s")
        assertClean(o, "Cmd+S among resting hands")
    }

    // Rule F3a, pins verifier PV4 within the staleModifier window: the hands already rest, a thumb
    // lands on RIGHT Cmd (after the settle, so not a settling thumb), stays unused for 1.5 s, then S
    // is tapped: policy-literal chord, right Cmd posted immediately before S at S's lift and
    // released at its own lift. (On LEFT Cmd this user's configuration is tap-only: see the twin.)
    func testPV4RightCmdPressedAfterHandsSettledChordsWithinStaleWindow() {
        var sc = TSScenario()
        sc.rest(K.rightHand, from: 0, until: 4.0)
        sc.touch(K.rcmd, 1.0, 3.5)
        sc.touch(K.s, 2.5, 2.58)
        let o = tsPlay(sc)
        XCTAssertEqual(o.timed, ["+54@2.580", "+1@2.580", "-1@2.580", "-54@3.500"])
        XCTAssertEqual(o.text, "⌘s")
        assertClean(o, "PV4: right Cmd held 1.5 s among resting hands, then S")
    }

    // User configuration twin of PV4: with tapOnlyCodes [55], a thumb lying on LEFT Cmd for 1.5 s
    // among resting hands never chords; S is plain and no modifier is posted (left Cmd is Caps Lock
    // on the Mac, so a chord would reach it as Caps Lock held down).
    func testPV4LeftCmdTapOnlyStaysPlain() {
        var sc = TSScenario()
        sc.rest(K.rightHand, from: 0, until: 4.0)
        sc.touch(K.lcmd, 1.0, 3.5)
        sc.touch(K.s, 2.5, 2.58)
        let o = tsPlay(sc, TypingSettings(tapOnlyCodes: [K.lcmd]))
        XCTAssertEqual(o.timed, ["+1@2.580", "-1@2.580"])
        XCTAssertEqual(o.text, "s")
        assertNoModifierPosted(o, "PV4 tap-only left Cmd")
        assertClean(o, "PV4 tap-only left Cmd")
    }

    // Rule F1 over F3a (policy reversal of the old slow-Cmd+S probe): S held past tapMax under Cmd
    // is a rest, so neither S nor Cmd posts anything; same for a slow Shift+A.
    func testSlowHomeKeyUnderModifierIsARestAndPostsNothing() {
        var cmdS = TSScenario()
        cmdS.touch(K.lcmd, 0, 1.2)
        cmdS.touch(K.s, 0.6, 0.95)
        assertSilent(tsPlay(cmdS), "slow Cmd+S")

        var shiftA = TSScenario()
        shiftA.touch(K.lshift, 0, 0.9)
        shiftA.touch(K.a, 0.4, 0.75)
        assertSilent(tsPlay(shiftA), "slow Shift+A")

        var cmdSpace = TSScenario()
        cmdSpace.touch(K.lcmd, 0, 0.6)
        cmdSpace.touch(K.space, 0.1, 0.45)
        assertSilent(tsPlay(cmdSpace), "slow Cmd+Space")
    }

    // Rule F3a/F4: Cmd+Shift+Z posts both modifiers before Z and releases them at their own lifts.
    func testCmdShiftZPostsBothModifiersBeforeZ() {
        var sc = TSScenario()
        sc.touch(K.lcmd, 0, 0.5)
        sc.touch(K.lshift, 0.05, 0.45)
        sc.touch(K.z, 0.15, 0.25)
        let o = tsPlay(sc)
        XCTAssertEqual(o.timed, ["+55@0.195", "+56@0.195", "+6@0.195", "-6@0.250", "-56@0.450", "-55@0.500"])
        XCTAssertEqual(o.text, "⇧⌘z")
        assertClean(o, "Cmd+Shift+Z")

        var shiftFirst = TSScenario()
        shiftFirst.touch(K.rshift, 0, 0.3)
        shiftFirst.touch(K.rcmd, 0.03, 0.35)
        shiftFirst.touch(K.z, 0.10, 0.18)
        let o2 = tsPlay(shiftFirst)
        XCTAssertEqual(o2.text, "⇧⌘z", "Shift landing before Cmd")
        XCTAssertEqual(o2.downs(of: K.rshift).count, 1)
        XCTAssertEqual(o2.downs(of: K.rcmd).count, 1)
        assertClean(o2, "Shift then Cmd then Z")
    }

    // Rule F4 (plan testCmdShiftTChord): Cmd 0-0.4, Shift at 0.04, T 0.09-0.2 posts at T's confirm.
    func testCmdShiftTChord() {
        var sc = TSScenario()
        sc.touch(K.lcmd, 0, 0.4)
        sc.touch(K.lshift, 0.04, 0.3)
        sc.touch(K.t, 0.09, 0.2)
        let o = tsPlay(sc)
        XCTAssertEqual(o.timed, ["+55@0.135", "+56@0.135", "+17@0.135", "-17@0.200", "-56@0.300", "-55@0.400"])
        assertClean(o, "Cmd+Shift+T")
    }

    // Rule F4: fast capitals. Shift overlapping a letter tap capitalises it, including when Shift
    // lifts before the letter lifts and when Shift lands within chordTolerance after the letter;
    // Shift is posted exactly once and never as an extra lone tap.
    func testFastCapitalsWithShiftOverlappingTheLetter() {
        let cases: [(String, mod: (UInt16, TimeInterval, TimeInterval), key: (UInt16, TimeInterval, TimeInterval), text: String)] = [
            ("Shift lifts before a lifts", (K.lshift, 0, 0.08), (K.a, 0.03, 0.11), "A"),
            ("Shift spans a", (K.lshift, 0, 0.15), (K.a, 0.05, 0.13), "A"),
            ("Shift lands 25 ms after a", (K.lshift, 0.025, 0.15), (K.a, 0, 0.10), "A"),
            ("Shift lifts before T confirms", (K.lshift, 0, 0.10), (K.t, 0.06, 0.14), "T"),
            ("right Shift + J", (K.rshift, 0, 0.09), (K.j, 0.04, 0.12), "J"),
            ("right Shift + F", (K.rshift, 0, 0.12), (K.f, 0.05, 0.16), "F"),
        ]
        for c in cases {
            var sc = TSScenario()
            sc.touch(c.mod.0, c.mod.1, c.mod.2)
            sc.touch(c.key.0, c.key.1, c.key.2)
            let o = tsPlay(sc)
            XCTAssertEqual(o.text, c.text, c.0)
            XCTAssertEqual(o.downs(of: c.mod.0).count, 1, "Shift posted once: \(c.0) \(o.timed)")
            assertClean(o, c.0)
        }
    }

    // Rule F4 (plan fast capitals): Shift+L+a, Shift+a+s and the burst-shaped Shift+j+a+d keep the
    // modifier for every letter landed while Shift is held, with exact timing.
    func testFastCapitalRolloversFromThePlan() {
        var la = TSScenario()
        la.touch(K.lshift, 0, 0.16)
        la.touch(K.l, 0.06, 0.14)
        la.touch(K.a, 0.12, 0.20)
        XCTAssertEqual(tsPlay(la).timed, ["+56@0.140", "+37@0.140", "-37@0.140", "+0@0.200", "-0@0.200", "-56@0.200"])

        var asx = TSScenario()
        asx.touch(K.lshift, 0, 0.15)
        asx.touch(K.a, 0.05, 0.13)
        asx.touch(K.s, 0.10, 0.18)
        XCTAssertEqual(tsPlay(asx).timed, ["+56@0.130", "+0@0.130", "-0@0.130", "+1@0.180", "-1@0.180", "-56@0.180"])

        var jad = TSScenario()
        jad.touch(K.lshift, 0, 0.16)
        jad.touch(K.j, 0.03, 0.18)
        jad.touch(K.a, 0.06, 0.20)
        jad.touch(K.d, 0.09, 0.22)
        let o = tsPlay(jad)
        XCTAssertEqual(o.timed, ["+56@0.180", "+38@0.180", "-38@0.180", "+0@0.200", "-0@0.200",
                                 "+2@0.220", "-2@0.220", "-56@0.220"])
        XCTAssertEqual(o.text, "JAD")
        assertClean(o, "Shift+j+a+d")
    }

    // Rule F4: a letter that landed before Shift (outside chordTolerance) stays lower-case.
    func testLetterBeforeShiftStaysLowercase() {
        var sc = TSScenario()
        sc.touch(K.a, 0, 0.12)
        sc.touch(K.lshift, 0.06, 0.20)
        let o = tsPlay(sc)
        XCTAssertEqual(o.letters, "a")
        assertClean(o, "a then Shift")
    }

    // Rule F4: capitals typed with one hand while the other hand rests.
    func testShiftCapitalWhileOtherHandRests() {
        var sc = TSScenario()
        sc.rest(K.leftHand, from: 0, until: 3.0)
        sc.touch(K.rshift, 1.0, 1.2)
        sc.touch(K.h, 1.05, 1.12)
        let o = tsPlay(sc)
        XCTAssertEqual(o.text, "H")
        assertClean(o, "right Shift + H with left hand resting")
    }

    // Rule F3a: Cmd held while Tab is tapped three times (other hand and thumb resting) posts one
    // Cmd down before the first Tab and one up at Cmd's lift.
    func testCmdTabRepeatedWhileOtherHandRests() {
        var sc = TSScenario()
        sc.rest(K.rightHand, from: 0, until: 3.0)
        sc.touch(K.space, 0.05, 3.0)
        sc.touch(K.lcmd, 1.0, 2.5)
        for start in [1.2, 1.5, 1.8] { sc.tap(K.tab, at: start, for: 0.08) }
        let o = tsPlay(sc)
        XCTAssertEqual(o.text, "⌘⇥⌘⇥⌘⇥")
        XCTAssertEqual(o.downs(of: K.lcmd).map(tsFormat), ["1.245"], "one Cmd down, before the first Tab")
        XCTAssertEqual(o.timed.last, "-55@2.500")
        assertClean(o, "Cmd-Tab x3")
    }

    // Rule F3a (literal): a modifier that chorded stays down until its contact lifts, even while
    // both hands rest for seconds (the Cmd-Tab switcher stays open; no stale release).
    func testChordedModifierStaysDownUntilItsContactLiftsAmongRestingHands() {
        var sc = TSScenario()
        sc.rest(K.bothHands, from: 0, until: 6.0)
        sc.touch(K.space, 0.08, 6.0)
        sc.touch(K.lcmd, 1.0, 5.0)
        sc.tap(K.tab, at: 1.2, for: 0.08)
        let o = tsPlay(sc)
        XCTAssertEqual(o.timed, ["+55@1.245", "+48@1.245", "-48@1.280", "-55@5.000"])
        assertClean(o, "Cmd-Tab held among resting hands")
    }

    // LEAD DECISION (pinned as F3a literal, escalation hazard on glass): the thumb stays on right
    // Cmd after a deliberate Cmd+S, and typing resumes while it is still down. F3a (a) applies to
    // every key that commits while the modifier contact is down, so every letter chords (⌘h hides
    // the app, ⌘q would quit). A real MacBook differs only because a thumb that rests on its Cmd
    // key does not press it. If the lead adopts a release-after-chord rule, flip this test.
    func testThumbStayingOnCmdAfterAChordKeepsChording_LeadDecision() {
        var sc = TSScenario()
        sc.touch(K.rcmd, 1.0, 4.5)
        sc.tap(K.s, at: 1.2, for: 0.08)
        sc.type("hello", from: 2.5, wpm: 60)
        let o = tsPlay(sc)
        XCTAssertEqual(o.text, "⌘s⌘h⌘e⌘l⌘l⌘o")
        XCTAssertEqual(o.downs(of: K.rcmd).map(tsFormat), ["1.280"], "one Cmd down, before S")
        XCTAssertEqual(o.timed.last, "-54@4.500", "Cmd up only at its own lift")
        assertClean(o, "thumb stays on Cmd after Cmd+S")
    }

    // Capital word under a held Shift at speed (120 wpm, home-row letters committing at lift):
    // all capitals, one Shift down immediately before the first letter, Shift up at its own lift.
    // Runs with nothing else touching and with the non-typing hand already resting before Shift
    // lands (Shift pressed after the settle is deliberate; compare the settle shape in section 7).
    func testCapitalWordUnderHeldShiftAtSpeed() {
        let cases: [(shift: UInt16, word: String, resting: [UInt16])] = [
            (K.lshift, "jkl", [K.s, K.d, K.f]), (K.lshift, "hulk", [K.s, K.d, K.f]),
            (K.rshift, "fads", [K.j, K.k, K.l]), (K.rshift, "sad", [K.j, K.k, K.l]),
        ]
        for c in cases {
            for withRestingHand in [false, true] {
                var sc = TSScenario()
                if withRestingHand {
                    sc.rest(c.resting, from: 0, until: 3.0)
                    sc.touch(K.space, 0.05, 3.0)
                }
                sc.touch(c.shift, 1.0, 2.0)
                sc.type(c.word, from: 1.2, wpm: 120)
                let o = tsPlay(sc)
                let label = "\(c.word) under Shift \(c.shift), resting hand \(withRestingHand)"
                XCTAssertEqual(o.text, c.word.uppercased(), label)
                let shiftDowns = o.downs(of: c.shift)
                XCTAssertEqual(shiftDowns.count, 1, "one Shift down: \(label) \(o.timed)")
                if let first = o.events.firstIndex(where: { $0.down && !KeyCommitPipeline.modifierCodes.contains($0.code) }),
                   first > 0 {
                    XCTAssertEqual(o.events[first - 1].code, c.shift, "Shift immediately before the first letter: \(label)")
                    XCTAssertTrue(o.events[first - 1].down, label)
                    XCTAssertEqual(o.events[first - 1].t, o.events[first].t, accuracy: 1e-9, label)
                }
                XCTAssertEqual(o.timed.last, "-\(c.shift)@2.000", "Shift up at its own lift: \(label)")
                assertClean(o, label)
            }
        }
    }

    // MARK: 7. Rollover typing

    // Rule F4: rollover typing at 100-140 wpm with overlapping keys (home-row letters committing at
    // lift, other keys after 45 ms, Space at lift, Shift capitals) yields exactly the typed text.
    func testRolloverPhrasesAt100To140WpmKeepExactOrder() {
        let phrases = ["the quick", "hello world", "sad lads ask", "jaffa falls fast", "kiss a lass",
                       "The Quick Brown Fox", "Hello World", "Sad Lads Ask; Dallas",
                       "the quick brown fox jumps over the lazy dog"]
        for phrase in phrases {
            for wpm in [100.0, 120.0, 140.0] {
                for overlap in [1.15, 1.6] {
                    for seed in UInt64(1)...3 {
                        var sc = TSScenario()
                        sc.type(phrase, from: 0.5, wpm: wpm, overlap: overlap, seed: seed)
                        let o = tsPlay(sc)
                        let label = "'\(phrase)' at \(wpm) wpm, overlap \(overlap), seed \(seed)"
                        XCTAssertEqual(o.text, phrase, label)
                        assertClean(o, label)
                    }
                }
            }
        }
    }

    // Rules F4/F5: one hand types at speed while the other hand (and possibly a thumb on Space or
    // a thumb that settled on left Cmd with the hand) rests: exact text, no modifier.
    func testRolloverWithTheOtherHandResting() {
        let phrases = ["hull pink", "mill on", "ploy hum"]
        let contexts = ["left hand", "left hand + Space thumb", "left hand + Cmd thumb in burst",
                        "Cmd thumb before hand"]
        for phrase in phrases {
            for context in contexts {
                for wpm in [100.0, 140.0] {
                    var sc = TSScenario()
                    switch context {
                    case "left hand + Space thumb":
                        sc.rest(K.leftHand, from: 0, until: 4.0)
                        sc.touch(K.space, 0.05, 4.0)
                    case "left hand + Cmd thumb in burst":
                        sc.rest(K.leftHand, from: 0, until: 4.0)
                        sc.touch(K.lcmd, 0.05, 4.0)
                    case "Cmd thumb before hand":
                        sc.touch(K.lcmd, 0, 4.0)
                        sc.rest(K.leftHand, from: 0.2, until: 4.0)
                    default:
                        sc.rest(K.leftHand, from: 0, until: 4.0)
                    }
                    // Right-hand-only text; Space typed by the right thumb.
                    sc.type(phrase, from: 1.0, wpm: wpm)
                    let o = tsPlay(sc)
                    let label = "'\(phrase)' with \(context) at \(wpm) wpm"
                    XCTAssertEqual(o.text, phrase, label)
                    assertNoModifierPosted(o, label)
                    assertClean(o, label)
                }
            }
        }
    }

    // Rules F1/F3 (verifier P3b): thumbs resting on Space and left Cmd while the right hand types
    // "hello" produce plain letters.
    func testThumbsOnSpaceAndCmdWhileRightHandTypesStayPlain() {
        var sc = TSScenario()
        sc.touch(K.lcmd, 0, 3.0)
        sc.touch(K.space, 0.02, 3.0)
        sc.type("hello", from: 0.6, wpm: 120)
        let o = tsPlay(sc)
        XCTAssertEqual(o.text, "hello")
        assertNoModifierPosted(o, "P3b")
        assertClean(o, "P3b")
    }

    // Rules F1/F3 (verifier P8): a thumb resting on Space before typing never leads with a space.
    func testThumbOnSpaceBeforeTypingDoesNotTypeASpace() {
        var sc = TSScenario()
        sc.touch(K.space, 0, 3.0)
        sc.type("hi", from: 0.6, wpm: 120)
        let o = tsPlay(sc)
        XCTAssertEqual(o.text, "hi")
        assertClean(o, "P8")
    }

    // Rules F1/F3 (verifier P1, P2): a thumb on left Cmd that settled before or with the hands never
    // turns later letters into shortcuts.
    func testThumbOnCmdSettledWithTheHandsNeverChords() {
        // P1: Cmd first, the left hand rests at 0.2, then h and e are typed.
        var p1 = TSScenario()
        p1.touch(K.lcmd, 0, 3.0)
        p1.rest(K.leftHand, from: 0.2, until: 3.0)
        p1.tap(K.h, at: 0.8, for: 0.06)
        p1.tap(K.e, at: 1.0, for: 0.06)
        let o1 = tsPlay(p1)
        XCTAssertEqual(o1.text, "he", "P1")
        assertClean(o1, "P1")

        // P2: eight fingers land, the thumb settles on Cmd at 0.16, q is typed at 0.9.
        var p2 = TSScenario()
        p2.rest(K.bothHands, from: 0, until: 3.0)
        p2.touch(K.lcmd, 0.16, 3.0)
        p2.tap(K.q, at: 0.9, for: 0.08)
        let o2 = tsPlay(p2)
        XCTAssertEqual(o2.text, "q", "P2")
        assertClean(o2, "P2")
    }

    // Rules F3/F5 (settle rule, generalised from left Cmd): a pinky on left/right Shift or a thumb
    // on right Cmd or either Option, with the same hand settling after it (P1) or with the other
    // thumb settling on Space beside it (P3b), never modifies what the other hand types later.
    //
    // PINNED CONFLICT (lead decision): the Shift rows of P1 are also the shape of a deliberate
    // "pinky holds Shift, the other fingers settle at 0.2, the right hand types capitals". The
    // settle rule wins: lower case. Deliberate capitals need Shift pressed after the hand settled
    // (testCapitalWordUnderHeldShiftAtSpeed) or around the letter (fast capitals).
    func testOtherModifiersSettledWithTheHandNeverModifyLaterTyping() {
        let cases: [(mod: UInt16, settling: [UInt16], text: String)] = [
            (K.lshift, [K.s, K.d, K.f], "hulk"), (K.lopt, K.leftHand, "hulk"),
            (K.rcmd, K.rightHand, "wasted"), (K.rshift, [K.j, K.k, K.l], "wasted"),
            (K.ropt, K.rightHand, "wasted"),
        ]
        for c in cases {
            var p1 = TSScenario()
            p1.touch(c.mod, 0, 4.0)
            p1.rest(c.settling, from: 0.2, until: 4.0)
            p1.type(c.text, from: 1.0, wpm: 120)
            let o1 = tsPlay(p1)
            XCTAssertEqual(o1.text, c.text, "P1 shape, modifier \(c.mod)")
            assertNoModifierPosted(o1, "P1 shape, modifier \(c.mod)")
            assertClean(o1, "P1 shape, modifier \(c.mod)")

            var p3b = TSScenario()
            p3b.touch(c.mod, 0, 4.0)
            p3b.touch(K.space, 0.02, 4.0)
            p3b.type(c.text, from: 0.6, wpm: 120)
            let o3 = tsPlay(p3b)
            XCTAssertEqual(o3.text, c.text, "P3b shape, modifier \(c.mod)")
            assertNoModifierPosted(o3, "P3b shape, modifier \(c.mod)")
            assertClean(o3, "P3b shape, modifier \(c.mod)")
        }
    }

    // Rules F1/F4/F5: typing while fingers come back to rest mid-stream. Home-row fingers return to
    // rest between words while the other hand keeps tapping at 120 wpm, and a hand lands as a
    // placement burst in the middle of a phrase: exact text in landing order, no modifier, and every
    // queued tap commits no later than the tapMax deadline of the resting contact it waits behind.
    func testTypingWhileFingersReturnToRestMidStream() {
        // Left fingers rest between words while the right hand types the next word.
        var between = TSScenario()
        between.type("we ", from: 0.5, wpm: 120)
        between.rest(K.leftHand, from: 0.85, until: 1.6)
        between.type("hulk", from: 0.9, wpm: 120)
        between.type(" sad", from: 1.8, wpm: 120, seed: 2)
        assertMidStream(between, "we hulk sad", "left fingers rest between words")

        // The left hand lands as a placement burst in the middle of a right-hand phrase.
        var burst = TSScenario()
        burst.type("hull pink", from: 0.5, wpm: 120)
        burst.rest(K.leftHand, from: 0.83, until: 3.0)
        assertMidStream(burst, "hull pink", "left hand lands mid-phrase")

        // Right-hand fingers settle on J K L between taps of the left hand, twice.
        var twice = TSScenario()
        twice.type("tea", from: 0.5, wpm: 120)
        twice.rest([K.j, K.k, K.l], from: 0.78, until: 1.5)
        twice.type("set", from: 0.82, wpm: 120, seed: 3)
        twice.rest([K.j, K.k, K.l], from: 1.7, until: 2.6)
        twice.type("cat", from: 1.75, wpm: 120, seed: 4)
        assertMidStream(twice, "teasetcat", "right fingers return to rest twice")
    }

    /// Exact text, no modifier, and each tap's down no later than max(its lift, the previous tap's
    /// commit bound, landing + tapMax of every resting contact that landed before it).
    private func assertMidStream(_ sc: TSScenario, _ expected: String, _ label: String,
                                 file: StaticString = #file, line: UInt = #line) {
        let o = tsPlay(sc)
        XCTAssertEqual(o.text, expected, label, file: file, line: line)
        assertNoModifierPosted(o, label, file: file, line: line)
        assertClean(o, label, file: file, line: line)
        let tapMax = 0.30
        let spans = sc.spans
        let taps = spans.filter { $0.up - $0.down <= tapMax }
        let rests = spans.filter { $0.up - $0.down > tapMax }
        let downs = o.events.filter { $0.down && !KeyCommitPipeline.modifierCodes.contains($0.code) }
        XCTAssertEqual(downs.count, taps.count, "one commit per tap: \(label)", file: file, line: line)
        guard downs.count == taps.count else { return }
        var bound = -Double.infinity
        for (tap, down) in zip(taps, downs) {
            XCTAssertEqual(down.code, tap.code, "landing order: \(label)", file: file, line: line)
            let blocker = rests.filter { $0.down < tap.down }.map { $0.down + tapMax }.max() ?? -Double.infinity
            bound = max(bound, tap.up, tap.down + 0.045, blocker)
            XCTAssertLessThanOrEqual(down.t, bound + 1e-6,
                                     "\(tsKeyName(tap.code)) landed \(tsFormat(tap.down)) committed late: \(label) \(o.timed)",
                                     file: file, line: line)
        }
    }

    // MARK: 8. Taps queued behind pending decisions

    // Rule F4 (I1): a tap queued behind an undecided rest-capable contact commits in landing order:
    // after it if it turns out to be a tap, alone once it rests (no later than its tapMax deadline).
    func testTapQueuedBehindAPendingContactCommitsInLandingOrder() {
        var jTap = TSScenario()
        jTap.rest(K.leftHand, from: 0, until: 3.0)
        jTap.touch(K.j, 1.0, 1.15)
        jTap.tap(K.e, at: 1.05, for: 0.07)
        let o1 = tsPlay(jTap)
        XCTAssertEqual(o1.text, "je")
        assertClean(o1, "J tap then queued e")

        var jRest = TSScenario()
        jRest.rest(K.leftHand, from: 0, until: 3.0)
        jRest.touch(K.j, 1.0, 2.5)
        jRest.tap(K.e, at: 1.05, for: 0.07)
        let o2 = tsPlay(jRest)
        XCTAssertEqual(o2.text, "e")
        if let eDown = o2.downs(of: K.e).first {
            XCTAssertLessThanOrEqual(eDown, 1.30 + 1e-9, "e commits once J's tapMax has passed")
        }
        assertClean(o2, "J rests, queued e")

        var spaceRest = TSScenario()
        spaceRest.touch(K.space, 1.0, 3.0)
        spaceRest.tap(K.h, at: 1.05, for: 0.06)
        let o3 = tsPlay(spaceRest)
        XCTAssertEqual(o3.text, "h")
        assertClean(o3, "Space rests, queued h")

        var spaceTap = TSScenario()
        spaceTap.touch(K.space, 1.0, 1.12)
        spaceTap.tap(K.h, at: 1.05, for: 0.06)
        let o4 = tsPlay(spaceTap)
        XCTAssertEqual(o4.text, " h")
        assertClean(o4, "Space tap, queued h")
    }

    // Rules F3a/F4 (verifier R1, R1b, R2, R3, R4): a shortcut or capital typed right after a finger
    // or thumb came back to rest waits behind that contact and still gets its modifier.
    func testChordQueuedBehindASettlingContactKeepsItsModifier() {
        // R1: J settles at 1.0, Shift at 1.08, T tapped 1.12-1.20.
        var r1 = TSScenario()
        r1.rest(K.leftHand, from: 0, until: 3.0)
        r1.touch(K.j, 1.0, 3.0)
        r1.touch(K.lshift, 1.08, 1.25)
        r1.tap(K.t, at: 1.12, for: 0.08)
        XCTAssertEqual(tsPlay(r1).text, "T", "R1")

        // R1b: J settles at 1.0, right Cmd at 1.05, C tapped 1.10-1.17.
        var r1b = TSScenario()
        r1b.rest(K.leftHand, from: 0, until: 3.0)
        r1b.touch(K.j, 1.0, 3.0)
        r1b.touch(K.rcmd, 1.05, 1.3)
        r1b.tap(K.c, at: 1.10, for: 0.07)
        XCTAssertEqual(tsPlay(r1b).text, "⌘c", "R1b")

        // R2: thumb settles on Space at 1.0, right Shift at 1.1, F tapped 1.15-1.32.
        var r2 = TSScenario()
        r2.rest(K.leftHand, from: 0, until: 3.0)
        r2.touch(K.space, 1.0, 3.0)
        r2.touch(K.rshift, 1.1, 1.35)
        r2.touch(K.f, 1.15, 1.32)
        XCTAssertEqual(tsPlay(r2).letters, "F", "R2")

        // R3: thumb settles on Space at 1.0, left Cmd at 1.1, C tapped 1.15-1.21.
        var r3 = TSScenario()
        r3.rest(K.leftHand, from: 0, until: 3.0)
        r3.touch(K.space, 1.0, 3.0)
        r3.touch(K.lcmd, 1.1, 1.35)
        r3.tap(K.c, at: 1.15, for: 0.06)
        XCTAssertEqual(tsPlay(r3).text, "⌘c", "R3")

        // R4: K and L settle at 1.0 and 1.02, Shift at 1.10, J tapped 1.14-1.22.
        var r4 = TSScenario()
        r4.rest(K.leftHand, from: 0, until: 3.0)
        r4.touch(K.k, 1.0, 3.0)
        r4.touch(K.l, 1.02, 3.0)
        r4.touch(K.lshift, 1.10, 1.30)
        r4.tap(K.j, at: 1.14, for: 0.08)
        XCTAssertEqual(tsPlay(r4).letters, "J", "R4")
    }

    // Rules F1/F3a (verifier S1): a slow K under Shift rests, and the retry tap with Shift still
    // held is capitalised.
    func testSlowShiftKThatRestedKeepsShiftForTheRetry() {
        var sc = TSScenario()
        sc.rest(K.leftHand, from: 0, until: 3.0)
        sc.touch(K.j, 0.04, 3.0)
        sc.touch(K.k, 0.05, 1.9)
        sc.touch(K.l, 0.06, 3.0)
        sc.touch(K.semicolon, 0.07, 1.95)
        sc.touch(K.rshift, 2.0, 2.7)
        sc.touch(K.k, 2.05, 2.40)
        sc.tap(K.k, at: 2.5, for: 0.08)
        let o = tsPlay(sc)
        XCTAssertEqual(o.text, "K")
        assertClean(o, "S1")
    }

    // Rules F3/F5 (verifier P6, P6b, P14, original blocker, quick tap behind burst): a tap queued
    // behind a placement burst never picks up the modifier of a thumb that landed in the burst,
    // and that modifier is never left down for later keys.
    func testTapQueuedBehindPlacementBurstNeverPicksUpTheThumbModifier() {
        for mod in [K.lcmd, K.rcmd, K.lshift, K.lopt, K.lctrl] {
            // P6: A S D land, the thumb lands last, E is tapped inside the burst.
            var p6 = TSScenario()
            p6.touch(K.a, 0, 3.0); p6.touch(K.s, 0.03, 3.0); p6.touch(K.d, 0.06, 3.0)
            p6.touch(mod, 0.09, 3.0)
            p6.touch(K.e, 0.11, 0.16)
            p6.tap(K.h, at: 1.2, for: 0.06)
            let o6 = tsPlay(p6)
            XCTAssertEqual(o6.text, "eh", "P6 \(mod)")
            assertNoModifierPosted(o6, "P6 \(mod)")
            assertClean(o6, "P6 \(mod)")

            // P6b: the thumb lands first, then A S D, E at 0.10.
            var p6b = TSScenario()
            p6b.touch(mod, 0, 3.0)
            p6b.touch(K.a, 0.03, 3.0); p6b.touch(K.s, 0.05, 3.0); p6b.touch(K.d, 0.07, 3.0)
            p6b.touch(K.e, 0.10, 0.15)
            p6b.tap(K.h, at: 1.2, for: 0.06)
            let o6b = tsPlay(p6b)
            XCTAssertEqual(o6b.text, "eh", "P6b \(mod)")
            assertNoModifierPosted(o6b, "P6b \(mod)")
            assertClean(o6b, "P6b \(mod)")

            // P14: a finger landing after the thumb bounces (F) and re-rests; H tapped later.
            var p14 = TSScenario()
            p14.touch(K.a, 0, 3.0); p14.touch(K.s, 0.02, 3.0); p14.touch(K.d, 0.04, 3.0)
            p14.touch(mod, 0.06, 3.0)
            p14.touch(K.f, 0.08, 0.13)
            p14.touch(K.f, 0.16, 3.0)
            p14.tap(K.h, at: 1.2, for: 0.06)
            let o14 = tsPlay(p14)
            // Ruling: a bounce inside a burst may or may not type, but at most one letter.
            XCTAssertTrue(["h", "fh"].contains(o14.text), "P14 \(mod): \(o14.text)")
            assertNoModifierPosted(o14, "P14 \(mod)")
            assertClean(o14, "P14 \(mod)")

            // Original blocker: thumb last, the first finger bounces, H and E typed later.
            var blocker = TSScenario()
            blocker.touch(K.a, 0, 0.12)
            blocker.touch(K.s, 0.03, 3.0); blocker.touch(K.d, 0.06, 3.0)
            blocker.touch(mod, 0.09, 3.0)
            blocker.touch(K.a, 0.20, 3.0)
            blocker.tap(K.h, at: 1.0, for: 0.08)
            blocker.tap(K.e, at: 1.2, for: 0.08)
            let ob = tsPlay(blocker)
            XCTAssertTrue(["he", "ahe"].contains(ob.text), "blocker \(mod): \(ob.text)")
            assertNoModifierPosted(ob, "blocker \(mod)")
            assertClean(ob, "blocker \(mod)")

            // Quick tap behind a thumb-last burst, then H much later.
            var quick = TSScenario()
            quick.touch(K.a, 0, 6.0); quick.touch(K.s, 0.03, 6.0); quick.touch(K.d, 0.06, 6.0)
            quick.touch(mod, 0.09, 6.0)
            quick.tap(K.e, at: 0.15, for: 0.05)
            quick.tap(K.h, at: 3.0, for: 0.08)
            let oq = tsPlay(quick)
            XCTAssertEqual(oq.text, "eh", "quick tap \(mod)")
            assertNoModifierPosted(oq, "quick tap \(mod)")
            assertClean(oq, "quick tap \(mod)")
        }
    }

    // MARK: 9. Placement bursts

    // Rule F5 (plan testPlacementBurstConvertsCmd): A, Cmd, S, D land as a burst and rest; E tapped
    // later is a plain E.
    func testPlacementBurstThumbOnCmdThenLaterTapIsPlain() {
        var sc = TSScenario()
        sc.touch(K.a, 0, 3.0)
        sc.touch(K.lcmd, 0.03, 3.0)
        sc.touch(K.s, 0.06, 3.0)
        sc.touch(K.d, 0.09, 3.0)
        sc.tap(K.e, at: 1.0, for: 0.08)
        let o = tsPlay(sc)
        XCTAssertEqual(o.timed, ["+14@1.045", "-14@1.080"])
        assertClean(o, "burst Cmd then E")
    }

    // Rule F5: fingers that land on non-home keys (G, H, E) during a placement burst and then rest
    // post nothing.
    func testPlacementBurstFingersOnNonHomeKeysThatRestPostNothing() {
        var sc = TSScenario()
        sc.touch(K.a, 0, 3.0)
        sc.touch(K.s, 0.01, 3.0)
        sc.touch(K.g, 0.02, 3.0)
        sc.touch(K.d, 0.03, 3.0)
        sc.touch(K.h, 0.04, 3.0)
        sc.touch(K.e, 0.05, 3.0)
        assertSilent(tsPlay(sc), "G, H, E in a burst")
    }

    // Rules F1/F4/F5: fast "bursty" rolls where 3+ home-row letters land within the burst window
    // (30-40 ms apart), each lifting as a tap, type exactly, in landing order, also when lifts come
    // out of order and when a non-home key in the roll is held up to tapMax (ruling: the burst
    // conversion of a non-home key uses tapMax, not restThreshold 0.25).
    func testBurstyRollsOfHomeRowTapsTypeExactly() {
        typealias Roll = (text: String, keys: [(UInt16, TimeInterval, TimeInterval)])
        let rolls: [Roll] = [
            ("asdf", [(K.a, 0, 0.09), (K.s, 0.035, 0.125), (K.d, 0.07, 0.16), (K.f, 0.105, 0.19)]),
            ("asdf", [(K.a, 0, 0.17), (K.s, 0.03, 0.12), (K.d, 0.06, 0.14), (K.f, 0.09, 0.15)]),
            ("lad", [(K.l, 0, 0.08), (K.a, 0.04, 0.12), (K.d, 0.08, 0.16)]),
            ("jak", [(K.j, 0, 0.09), (K.a, 0.03, 0.11), (K.k, 0.06, 0.13)]),
            ("flask", [(K.f, 0, 0.08), (K.l, 0.03, 0.11), (K.a, 0.06, 0.14), (K.s, 0.09, 0.17),
                       (K.k, 0.12, 0.20)]),
            ("sat", [(K.s, 0, 0.08), (K.a, 0.035, 0.12), (K.t, 0.07, 0.36)]),
            ("dash", [(K.d, 0, 0.08), (K.a, 0.03, 0.11), (K.s, 0.06, 0.14), (K.h, 0.09, 0.35)]),
            ("dash", [(K.d, 0, 0.08), (K.a, 0.03, 0.11), (K.s, 0.06, 0.14), (K.h, 0.09, 0.38)]),
            ("jade", [(K.j, 0, 0.08), (K.a, 0.03, 0.11), (K.d, 0.06, 0.14), (K.e, 0.09, 0.37)]),
        ]
        for roll in rolls {
            for start in [0.5, 2.0] {
                var sc = TSScenario()
                for (code, down, up) in roll.keys { sc.touch(code, start + down, start + up) }
                let o = tsPlay(sc)
                let label = "roll '\(roll.text)' \(roll.keys.map { tsFormat($0.2 - $0.1) })"
                XCTAssertEqual(o.text, roll.text, label)
                assertNoModifierPosted(o, label)
                assertClean(o, label)
            }
        }
        // The same rolls typed by one hand while the other hand rests.
        for roll in rolls {
            var sc = TSScenario()
            let usesLeft = roll.keys.contains { K.leftHand.contains($0.0) }
            sc.rest(usesLeft ? [K.j, K.k, K.l, K.semicolon].filter { c in !roll.keys.contains { $0.0 == c } }
                             : K.leftHand, from: 0, until: 3.0)
            for (code, down, up) in roll.keys { sc.touch(code, 1.0 + down, 1.0 + up) }
            let o = tsPlay(sc)
            XCTAssertEqual(o.text, roll.text, "roll '\(roll.text)' with the other hand resting")
            assertClean(o, "roll '\(roll.text)' with the other hand resting")
        }
    }

    // MARK: 10. Non-rest-capable keys

    // Rule F2: non-rest-capable keys keep the 45 ms confirmation and stay down while held (the Mac
    // repeats them), alone and while the hands rest.
    func testNonRestCapableKeysCommitAfterConfirmationAndHoldUntilLift() {
        let codes: [UInt16] = [K.e, K.t, K.h, K.g, K.q, K.z, K.one, K.delete, K.ret, K.tab, K.escape,
                               K.caps, K.leftArrow, K.upArrow]
        for code in codes {
            var alone = TSScenario()
            alone.touch(code, 0, 1.0)
            let o1 = tsPlay(alone)
            XCTAssertEqual(o1.timed, ["+\(code)@0.045", "-\(code)@1.000"], "\(code) held alone")
            assertClean(o1, "\(code) alone")

            var hands = TSScenario()
            hands.rest(K.bothHands, from: 0, until: 4.0)
            hands.touch(K.space, 0.08, 4.0)
            hands.touch(code, 2.0, 3.0)
            let o2 = tsPlay(hands)
            XCTAssertEqual(o2.timed, ["+\(code)@2.045", "-\(code)@3.000"], "\(code) held among resting hands")
            assertClean(o2, "\(code) among hands")
        }
    }

    // Rule F2/F3a: Cmd held + Delete held posts the chord at confirmation and keeps Delete down.
    func testModifierPlusHeldNonRestCapableKeyHolds() {
        var sc = TSScenario()
        sc.touch(K.lcmd, 0, 1.5)
        sc.touch(K.delete, 0.2, 1.2)
        let o = tsPlay(sc)
        XCTAssertEqual(o.timed, ["+55@0.245", "+51@0.245", "-51@1.200", "-55@1.500"])
        assertClean(o, "Cmd+Delete held")
    }

    // F04 acceptance: resting mode .off keeps today's 45 ms latency for every key.
    func testRestingOffKeepsTodaysLatency() {
        var sc = TSScenario()
        sc.touch(K.f, 0, 1.0)
        let o = tsPlay(sc, TypingSettings(resting: .off))
        XCTAssertEqual(o.timed, ["+3@0.045", "-3@1.000"])
        assertClean(o, "off mode")
    }

    // F04 + plan spec ("Mode .off: ... reveal = confirmationDelay (today's behaviour)"): in .off the
    // lazy-modifier rules do not apply. A lone Cmd held 1 s posts down at 0.045 and up at its lift;
    // a lone Shift tap shorter than the confirmation posts down+up at lift, a longer one is down at
    // 0.045 and up at lift; Cmd+S posts Cmd at 0.045 and S at its own confirmation.
    func testRestingOffKeepsTodaysModifierBehaviour() {
        let off = TypingSettings(resting: .off)
        var cmd = TSScenario()
        cmd.touch(K.lcmd, 0, 1.0)
        let o1 = tsPlay(cmd, off)
        XCTAssertEqual(o1.timed, ["+55@0.045", "-55@1.000"], ".off lone Cmd held 1 s")
        assertClean(o1, ".off lone Cmd")

        var quickShift = TSScenario()
        quickShift.tap(K.lshift, at: 0, for: 0.03)
        assertTapPosted(tsPlay(quickShift, off), K.lshift, at: 0.03, ".off lone Shift tap 30 ms")

        var shift = TSScenario()
        shift.tap(K.lshift, at: 0, for: 0.10)
        let o2 = tsPlay(shift, off)
        XCTAssertEqual(o2.timed, ["+56@0.045", "-56@0.100"], ".off lone Shift tap 100 ms")
        XCTAssertEqual(o2.text, "[LShift]")
        assertClean(o2, ".off lone Shift tap 100 ms")

        var cmdS = TSScenario()
        cmdS.touch(K.lcmd, 0, 0.5)
        cmdS.touch(K.s, 0.15, 0.25)
        let o3 = tsPlay(cmdS, off)
        XCTAssertEqual(o3.timed, ["+55@0.045", "+1@0.195", "-1@0.250", "-55@0.500"], ".off Cmd+S")
        XCTAssertEqual(o3.text, "⌘s")
        assertClean(o3, ".off Cmd+S")
    }

    // Rule F1 in .allTypingKeys mode: every typing key becomes rest-capable (tap types at lift, a
    // hold rests); Delete is still immediate.
    func testAllTypingKeysModeMakesEveryTypingKeyRestCapable() {
        let settings = TypingSettings(resting: .allTypingKeys)
        var tap = TSScenario()
        tap.tap(K.e, at: 0, for: 0.1)
        assertTapPosted(tsPlay(tap, settings), K.e, at: 0.1, "E tap")

        var hold = TSScenario()
        hold.touch(K.e, 0, 1.0)
        assertSilent(tsPlay(hold, settings), "E held")

        var delete = TSScenario()
        delete.touch(K.delete, 0, 1.0)
        XCTAssertEqual(tsPlay(delete, settings).timed, ["+51@0.045", "-51@1.000"])
    }

    // MARK: 11. isolatedHold (opt-in)

    // Rule F1: with the default (isolatedHold off) a lone home-row key held alone never types.
    func testIsolatedHoldOffByDefaultLoneHeldHomeKeyNeverTypes() {
        for code in K.homeLetters {
            var sc = TSScenario()
            sc.touch(code, 0, 1.0)
            assertSilent(tsPlay(sc), "\(code) held alone")
        }
    }

    // Rule F1 opt-in: with isolatedHold on, a home-row key held alone presses once at its
    // threshold (≤ tapMax) and releases at lift.
    func testIsolatedHoldOptInPressesLoneHomeKeyAtThreshold() {
        var sc = TSScenario()
        sc.touch(K.j, 0, 1.0)
        let o = tsPlay(sc, TypingSettings(isolatedHold: true))
        XCTAssertEqual(o.events.count, 2, o.timed.description)
        if o.events.count == 2 {
            XCTAssertTrue(o.events[0].down && o.events[0].code == K.j)
            XCTAssertGreaterThanOrEqual(o.events[0].t, 0.25 - 1e-9)
            XCTAssertLessThanOrEqual(o.events[0].t, 0.30 + 1e-9)
            XCTAssertEqual(o.timed[1], "-38@1.000")
        }
        assertClean(o, "isolated hold J")
    }

    // Rule F1 opt-in: isolated hold never fires among resting fingers, after a foreign contact
    // (palm or trackpad), for Space, or for modifiers.
    func testIsolatedHoldOptInStillRestsWhenNotIsolatedAndNeverForSpaceOrModifiers() {
        let settings = TypingSettings(isolatedHold: true)

        var hands = TSScenario()
        hands.rest(K.leftHand, from: 0, until: 3.0)
        hands.touch(K.j, 1.0, 2.5)
        assertSilent(tsPlay(hands, settings), "J among resting fingers")

        var foreignAfter = TSScenario()
        foreignAfter.touch(K.j, 0, 1.0)
        foreignAfter.at(0.1, .foreignContact)
        assertSilent(tsPlay(foreignAfter, settings), "foreign contact after landing")

        var foreignBefore = TSScenario()
        foreignBefore.at(0, .foreignContact)
        foreignBefore.touch(K.j, 0.1, 1.1)
        foreignBefore.at(0.1, .foreignContact)
        assertSilent(tsPlay(foreignBefore, settings), "palm already down, re-signalled after land")

        for code in [K.space] + K.allModifiers {
            var lone = TSScenario()
            lone.touch(code, 0, 1.5)
            assertSilent(tsPlay(lone, settings), "\(code) held alone with isolatedHold on")
        }
    }

    // MARK: 12. Pointer modifiers (proposed commitHeldModifiers(at:))

    // Rule F3 pointer API: commitHeldModifiers posts a deliberately held modifier before pointer
    // output; it stays down until its contact lifts and never fires an extra lone tap afterwards.
    func testCommitHeldModifiersPostsHeldModifierUntilItsLift() {
        for mod in [K.lcmd, K.rcmd, K.lshift, K.rshift, K.lopt, K.lctrl] {
            var long = TSScenario()
            long.touch(mod, 0, 2.0)
            long.at(1.0, .commitHeldModifiers)
            let o1 = tsPlay(long)
            XCTAssertEqual(o1.timed, ["+\(mod)@1.000", "-\(mod)@2.000"], "Cmd-click after holding \(mod) 1 s")
            assertClean(o1, "long \(mod)")

            var quick = TSScenario()
            quick.touch(mod, 0, 0.2)
            quick.at(0.1, .commitHeldModifiers)
            let o2 = tsPlay(quick)
            XCTAssertEqual(o2.timed, ["+\(mod)@0.100", "-\(mod)@0.200"], "quick \(mod)-click, no second tap")
            assertClean(o2, "quick \(mod)")

            var hand = TSScenario()
            hand.rest(K.rightHand, from: 0, until: 3.5)
            hand.touch(mod, 1.0, 3.0)
            hand.at(1.5, .commitHeldModifiers)
            let o3 = tsPlay(hand)
            XCTAssertEqual(o3.timed, ["+\(mod)@1.500", "-\(mod)@3.000"], "\(mod)-click with a resting hand")
            assertClean(o3, "hand \(mod)")
        }
    }

    // Rule F3 pointer API: a modifier committed for the pointer is not posted again for a key typed
    // while it is still held.
    func testCommitHeldModifiersThenKeyReusesTheSameDown() {
        var sc = TSScenario()
        sc.touch(K.lshift, 0, 1.0)
        sc.at(0.3, .commitHeldModifiers)
        sc.tap(K.a, at: 0.5, for: 0.08)
        let o = tsPlay(sc)
        XCTAssertEqual(o.timed, ["+56@0.300", "+0@0.580", "-0@0.580", "-56@1.000"])
        XCTAssertEqual(o.text, "A")
        assertClean(o, "Shift-click then A")
    }

    // Rules F3/F5 pointer API: a thumb that landed in a placement burst (suspect), nothing held,
    // or a tap-only code gives nothing to commit.
    func testCommitHeldModifiersIgnoresBurstThumbAndEmptyState() {
        var burst = TSScenario()
        burst.rest(K.bothHands, from: 0, until: 3.0)
        burst.touch(K.lcmd, 0.09, 3.0)
        burst.at(1.0, .commitHeldModifiers)
        assertSilent(tsPlay(burst), "burst thumb")

        var empty = TSScenario()
        empty.rest(K.leftHand, from: 0, until: 2.0)
        empty.at(1.0, .commitHeldModifiers)
        assertSilent(tsPlay(empty), "nothing held")

        // tapOnlyCodes [55]: left Command is Caps Lock on the Mac, never a pointer modifier.
        var tapOnly = TSScenario()
        tapOnly.touch(K.lcmd, 0, 2.0)
        tapOnly.at(1.0, .commitHeldModifiers)
        assertSilent(tsPlay(tapOnly, TypingSettings(tapOnlyCodes: [K.lcmd])), "tap-only code held")
    }

    // Rules F3/F5 pointer API (ruling): a modifier that went resting through the settle rule is
    // never committed for the pointer, by commitHeldModifiers or by flushModifiersForPointer, so a
    // resting thumb or Shift pinky never turns every click into Cmd-click or Shift-click. (Control
    // case, a modifier held alone 1 s then a click, is testCommitHeldModifiersPostsHeldModifierUntilItsLift.)
    func testCommitHeldModifiersIgnoresModifiersThatSettledWithTheHand() {
        for call in [TSScenario.Action.commitHeldModifiers, .flushModifiersForPointer] {
            for mod in [K.lcmd, K.rcmd, K.lopt] {
                // P1: thumb first, the same hand settles at 0.2.
                var p1 = TSScenario()
                p1.touch(mod, 0, 3.0)
                p1.rest(K.leftSideModifiers.contains(mod) ? K.leftHand : K.rightHand, from: 0.2, until: 3.0)
                p1.at(1.0, call)
                p1.at(2.0, call)
                assertSilent(tsPlay(p1), "P1 \(mod), \(call)")

                // P2: eight fingers land, the thumb settles at 0.16.
                var p2 = TSScenario()
                p2.rest(K.bothHands, from: 0, until: 3.0)
                p2.touch(mod, 0.16, 3.0)
                p2.at(1.0, call)
                assertSilent(tsPlay(p2), "P2 \(mod), \(call)")

                // P3b: the thumb and the other thumb on Space settle together, no hands.
                var p3b = TSScenario()
                p3b.touch(mod, 0, 3.0)
                p3b.touch(K.space, 0.02, 3.0)
                p3b.at(1.0, call)
                assertSilent(tsPlay(p3b), "P3b \(mod), \(call)")
            }
            // A Shift pinky that settled with its hand.
            for (shift, fingers) in [(K.lshift, [K.s, K.d, K.f]), (K.rshift, [K.j, K.k, K.l])] {
                var settle = TSScenario()
                settle.touch(shift, 0, 3.0)
                settle.rest(fingers, from: 0.2, until: 3.0)
                settle.at(1.0, call)
                assertSilent(tsPlay(settle), "Shift \(shift) pinky settled with the hand, \(call)")

                var inBurst = TSScenario()
                inBurst.rest(fingers, from: 0, until: 3.0)
                inBurst.touch(shift, 0.04, 3.0)
                inBurst.at(1.0, call)
                assertSilent(tsPlay(inBurst), "Shift \(shift) pinky in the burst, \(call)")
            }
        }
    }

    // Rule F3 pointer use: a committed modifier used by the pointer stays down among resting hands
    // until its contact lifts (plan testOptionHeldWithPointerUseStaysDown).
    func testModifierUsedByPointerStaysDownAmongRestingHands() {
        var sc = TSScenario()
        sc.rest(K.leftHand, from: 0, until: 4.5)
        sc.touch(K.ropt, 1.0, 4.0)
        sc.at(1.2, .commitHeldModifiers)
        for t in [1.5, 2.0, 2.5, 3.0, 3.5] { sc.at(t, .pointerUse) }
        let o = tsPlay(sc)
        XCTAssertEqual(o.timed, ["+61@1.200", "-61@4.000"])
        assertClean(o, "Option-scroll")
    }

    // Source compatibility (W2-ENGINE): the existing flushModifiersForPointer(at:) keeps posting a
    // deliberately held modifier the same way.
    func testFlushModifiersForPointerStillWorks() {
        var sc = TSScenario()
        sc.touch(K.lcmd, 0, 2.0)
        sc.at(1.0, .flushModifiersForPointer)
        let o = tsPlay(sc)
        XCTAssertEqual(o.timed, ["+55@1.000", "-55@2.000"])
        assertClean(o, "flush")
    }

    // MARK: 13. Tap-only codes (left Command remapped to Caps Lock on the Mac)

    // tapOnlyCodes [55]: a deliberate tap posts down+up at lift (alone or among resting hands);
    // a rest posts nothing.
    func testTapOnlyLeftCommandTapsButNeverRests() {
        let settings = TypingSettings(tapOnlyCodes: [K.lcmd])
        var tap = TSScenario()
        tap.tap(K.lcmd, at: 0, for: 0.12)
        assertTapPosted(tsPlay(tap, settings), K.lcmd, at: 0.12, "tap-only tap")

        var tapAmongHands = TSScenario()
        tapAmongHands.rest(K.bothHands, from: 0, until: 3.0)
        tapAmongHands.touch(K.space, 0.05, 3.0)
        tapAmongHands.tap(K.lcmd, at: 1.0, for: 0.2)
        assertTapPosted(tsPlay(tapAmongHands, settings), K.lcmd, at: 1.2, "tap-only tap among hands")

        for held in [0.31, 1.0, 3.0] {
            var rest = TSScenario()
            rest.touch(K.lcmd, 0, held)
            assertSilent(tsPlay(rest, settings), "tap-only rest \(held) s")
        }
    }

    // tapOnlyCodes [55]: a thumb resting on left Command while the other fingers type never chords.
    func testTapOnlyLeftCommandNeverChords() {
        let settings = TypingSettings(tapOnlyCodes: [K.lcmd])
        var sc = TSScenario()
        sc.touch(K.lcmd, 0, 2.0)
        sc.tap(K.h, at: 0.1, for: 0.06)
        sc.tap(K.e, at: 0.5, for: 0.06)
        sc.tap(K.s, at: 0.8, for: 0.06)
        let o = tsPlay(sc, settings)
        XCTAssertEqual(o.text, "hes")
        assertNoModifierPosted(o, "tap-only rest while typing")
        assertClean(o, "tap-only rest while typing")
    }

    // tapOnlyCodes [55] (verifier TB1, TB1b, TB3): a bounce or tap of left Command during a
    // placement burst posts nothing; a later deliberate tap still switches.
    func testTapOnlyLeftCommandBounceDuringPlacementPostsNothing() {
        let settings = TypingSettings(tapOnlyCodes: [K.lcmd])
        var tb1 = TSScenario()
        tb1.rest(K.leftHand, from: 0, until: 3.0)
        tb1.touch(K.lcmd, 0.05, 0.11)
        tb1.touch(K.lcmd, 0.16, 2.0)
        tb1.tap(K.lcmd, at: 2.5, for: 0.1)
        assertTapPosted(tsPlay(tb1, settings), K.lcmd, at: 2.6, "TB1 then a deliberate tap")

        var tb1b = TSScenario()
        tb1b.touch(K.lcmd, 0, 0.12)
        tb1b.rest(K.leftHand, from: 0.03, until: 3.0)
        tb1b.touch(K.lcmd, 0.18, 3.0)
        assertSilent(tsPlay(tb1b, settings), "TB1b")

        var tb3 = TSScenario()
        tb3.touch(K.lcmd, 0, 0.15)
        tb3.rest(K.leftHand, from: 0.05, until: 3.0)
        assertSilent(tsPlay(tb3, settings), "TB3")
    }

    // MARK: 14. The user's configuration (tapOnlyCodes [55]: left Command is Caps Lock on the Mac)

    private var userConfig: TypingSettings { TypingSettings(tapOnlyCodes: [K.lcmd]) }

    // A thumb resting on left Command posts nothing in the whole resting-thumb matrix (alone at any
    // length past tapMax; with the hands in every landing order, the other thumb and either lift order).
    func testUserConfig_RestingLeftCmdThumbIsSilentInEveryLandingOrder() {
        for held in [0.31, 0.35, 1.0, 3.0, 5.0] {
            var alone = TSScenario()
            alone.touch(K.lcmd, 0, held)
            assertSilent(tsPlay(alone, userConfig), "left Cmd alone \(held) s")
        }
        assertRestingThumbMatrixSilent([K.lcmd], userConfig)
    }

    // P1, P2, P3b, PV4 and long-hold shapes with typing: plain letters, no modifier ever posted.
    func testUserConfig_RestingLeftCmdThumbWhileTypingGivesPlainLetters() {
        func check(_ sc: TSScenario, _ text: String, _ label: String, file: StaticString = #file, line: UInt = #line) {
            let o = tsPlay(sc, userConfig)
            XCTAssertEqual(o.text, text, label, file: file, line: line)
            assertNoModifierPosted(o, label, file: file, line: line)
            assertClean(o, label, file: file, line: line)
        }
        var p1 = TSScenario()
        p1.touch(K.lcmd, 0, 3.0)
        p1.rest(K.leftHand, from: 0.2, until: 3.0)
        p1.tap(K.h, at: 0.8, for: 0.06)
        p1.tap(K.e, at: 1.0, for: 0.06)
        check(p1, "he", "P1")

        var p2 = TSScenario()
        p2.rest(K.bothHands, from: 0, until: 3.0)
        p2.touch(K.lcmd, 0.16, 3.0)
        p2.tap(K.q, at: 0.9, for: 0.08)
        check(p2, "q", "P2")

        var p3b = TSScenario()
        p3b.touch(K.lcmd, 0, 3.0)
        p3b.touch(K.space, 0.02, 3.0)
        p3b.type("hello", from: 0.6, wpm: 120)
        check(p3b, "hello", "P3b")

        var pv4 = TSScenario()
        pv4.rest(K.leftHand, from: 0, until: 6.0)
        pv4.touch(K.lcmd, 0.5, 6.0)
        pv4.tap(K.h, at: 1.2, for: 0.08)
        pv4.tap(K.q, at: 4.2, for: 0.08)
        check(pv4, "hq", "PV4 (verifier shape: thumb settles at 0.5, h at 1.2, q at 4.2)")

        var longS = TSScenario()
        longS.touch(K.lcmd, 0, 2.0)
        longS.tap(K.s, at: 1.5, for: 0.08)
        check(longS, "s", "left Cmd held long alone, then S")

        var quickS = TSScenario()
        quickS.touch(K.lcmd, 0, 0.40)
        quickS.touch(K.s, 0.12, 0.20)
        check(quickS, "s", "left Cmd held 0.4 s around a quick S")

        var tab = TSScenario()
        tab.touch(K.lcmd, 0, 3.5)
        tab.tap(K.tab, at: 3.0, for: 0.08)
        let oTab = tsPlay(tab, userConfig)
        XCTAssertEqual(oTab.timed, ["+48@3.045", "-48@3.080"], "left Cmd held 3 s then Tab: plain Tab")
        assertClean(oTab, "left Cmd held then Tab")

        var delete = TSScenario()
        delete.touch(K.lcmd, 0, 1.5)
        delete.touch(K.delete, 0.6, 1.2)
        let oDel = tsPlay(delete, userConfig)
        XCTAssertEqual(oDel.timed, ["+51@0.645", "-51@1.200"], "left Cmd held + Delete held: plain Delete")
        assertClean(oDel, "left Cmd + Delete")

        for phrase in ["hull pink", "ploy hum"] {
            for wpm in [100.0, 140.0] {
                var burst = TSScenario()
                burst.rest(K.leftHand, from: 0, until: 4.0)
                burst.touch(K.lcmd, 0.05, 4.0)
                burst.type(phrase, from: 1.0, wpm: wpm)
                check(burst, phrase, "'\(phrase)' at \(wpm) wpm, left Cmd thumb in the burst")

                var before = TSScenario()
                before.touch(K.lcmd, 0, 4.0)
                before.rest(K.leftHand, from: 0.2, until: 4.0)
                before.type(phrase, from: 1.0, wpm: wpm)
                check(before, phrase, "'\(phrase)' at \(wpm) wpm, left Cmd thumb before the hand")
            }
        }
    }

    // The tapMax boundary for the tap-only code: 0.29 s posts +55/-55 at lift, 0.31 s nothing,
    // alone and with the right hand resting. A 6 mm slide is silent; a 2 mm wobble still taps.
    func testUserConfig_LeftCmdTapBoundaryAndTravel() {
        for resting in [false, true] {
            var under = TSScenario()
            var over = TSScenario()
            if resting {
                under.rest(K.rightHand, from: 0, until: 2.0)
                over.rest(K.rightHand, from: 0, until: 2.0)
            }
            under.tap(K.lcmd, at: 1.0, for: 0.29)
            over.tap(K.lcmd, at: 1.0, for: 0.31)
            assertTapPosted(tsPlay(under, userConfig), K.lcmd, at: 1.29, "left Cmd 0.29 s, resting hand \(resting)")
            assertSilent(tsPlay(over, userConfig), "left Cmd 0.31 s, resting hand \(resting)")
        }
        var slide = TSScenario()
        slide.touch(K.lcmd, 0, 0.2, slideMM: 6.0)
        assertSilent(tsPlay(slide, userConfig), "left Cmd slide 6 mm")

        var wobble = TSScenario()
        wobble.touch(K.lcmd, 0, 0.2, slideMM: 2.0)
        assertTapPosted(tsPlay(wobble, userConfig), K.lcmd, at: 0.2, "left Cmd wobble 2 mm")
    }

    // Overlap with typing: 'a' landing 60 ms before an overlapping left Cmd tap gives "a[LCmd]";
    // the most common real use, tapping left Cmd to switch input source and typing at once with
    // overlap, gives the switch first and then the plain letter, in landing order.
    func testUserConfig_LeftCmdTapOverlappingTypingKeepsLandingOrder() {
        var before = TSScenario()
        before.tap(K.a, at: 0, for: 0.10)
        before.tap(K.lcmd, at: 0.06, for: 0.12)
        let o1 = tsPlay(before, userConfig)
        XCTAssertEqual(o1.timed, ["+0@0.100", "-0@0.100", "+55@0.180", "-55@0.180"])
        XCTAssertEqual(o1.text, "a[LCmd]")
        assertClean(o1, "a then overlapping left Cmd tap")

        // Switch, then h (non-home) landing at 0.08 before the switch lifts at 0.10.
        var hAfter = TSScenario()
        hAfter.tap(K.lcmd, at: 0, for: 0.10)
        hAfter.tap(K.h, at: 0.08, for: 0.08)
        let o2 = tsPlay(hAfter, userConfig)
        XCTAssertEqual(o2.timed, ["+55@0.100", "-55@0.100", "+4@0.125", "-4@0.160"])
        XCTAssertEqual(o2.text, "[LCmd]h")
        assertClean(o2, "left Cmd tap, then h overlapping")

        // Switch, then j (home row) landing at 0.08 and lifting after the switch.
        var jAfter = TSScenario()
        jAfter.tap(K.lcmd, at: 0, for: 0.10)
        jAfter.tap(K.j, at: 0.08, for: 0.07)
        let o3 = tsPlay(jAfter, userConfig)
        XCTAssertEqual(o3.timed, ["+55@0.100", "-55@0.100", "+38@0.150", "-38@0.150"])
        XCTAssertEqual(o3.text, "[LCmd]j")
        assertClean(o3, "left Cmd tap, then j overlapping")

        // j lifts before the switch does: it still waits and follows the switch.
        var jInside = TSScenario()
        jInside.tap(K.lcmd, at: 0, for: 0.12)
        jInside.tap(K.j, at: 0.05, for: 0.05)
        let o4 = tsPlay(jInside, userConfig)
        XCTAssertEqual(o4.timed, ["+55@0.120", "-55@0.120", "+38@0.120", "-38@0.120"])
        XCTAssertEqual(o4.text, "[LCmd]j")
        assertClean(o4, "j inside the left Cmd tap")

        // Switch and type a word straight away at 120 wpm, with the right hand.
        var word = TSScenario()
        word.tap(K.lcmd, at: 0, for: 0.10)
        word.type("hull", from: 0.08, wpm: 120)
        let o5 = tsPlay(word, userConfig)
        XCTAssertEqual(o5.text, "[LCmd]hull")
        XCTAssertEqual(o5.downs(of: K.lcmd).count, 1)
        assertClean(o5, "switch then hull")
    }

    // MARK: 15. Cancel and reject paths

    // A home-row or Space tap whose lift is cancelled within tapMax posts nothing; neither does a
    // pending lone-modifier tap that is cancelled or rejected (including a tap-only code).
    func testCancelledOrRejectedTapsPostNothing() {
        for code in [K.f, K.j, K.space, K.lshift, K.rcmd] {
            var cancelled = TSScenario()
            cancelled.touch(code, 0, 0.1, cancelled: true)
            assertSilent(tsPlay(cancelled), "\(code) tap cancelled")

            var cancelledAmongHands = TSScenario()
            cancelledAmongHands.rest(oppositeHand(of: code), from: 0, until: 2.0)
            cancelledAmongHands.touch(code, 1.0, 1.1, cancelled: true)
            assertSilent(tsPlay(cancelledAmongHands), "\(code) tap cancelled, other hand resting")
        }
        for code in [K.lshift, K.rcmd, K.lopt] {
            var rejected = TSScenario()
            let id = rejected.touch(code, 0, 0.12)
            rejected.at(0.05, .reject(id: id))
            assertSilent(tsPlay(rejected), "\(code) rejected during a lone tap")
        }
        var tapOnlyCancelled = TSScenario()
        tapOnlyCancelled.touch(K.lcmd, 0, 0.1, cancelled: true)
        assertSilent(tsPlay(tapOnlyCancelled, userConfig), "tap-only left Cmd tap cancelled")

        var tapOnlyRejected = TSScenario()
        let id = tapOnlyRejected.touch(K.lcmd, 0, 0.12)
        tapOnlyRejected.at(0.05, .reject(id: id))
        assertSilent(tsPlay(tapOnlyRejected, userConfig), "tap-only left Cmd rejected")
    }

    // A modifier that already chorded and is then rejected or cancelled while still held posts its
    // up at once (no stuck Cmd), and the next key is plain.
    func testChordedModifierRejectedOrCancelledReleasesAtOnce() {
        var rejected = TSScenario()
        let cmd = rejected.touch(K.rcmd, 0, 1.2)
        rejected.tap(K.q, at: 0.1, for: 0.1)
        rejected.at(0.5, .reject(id: cmd))
        rejected.tap(K.e, at: 0.8, for: 0.08)
        let o1 = tsPlay(rejected)
        XCTAssertEqual(o1.timed, ["+54@0.145", "+12@0.145", "-12@0.200", "-54@0.500", "+14@0.845", "-14@0.880"])
        XCTAssertEqual(o1.text, "⌘qe")
        assertClean(o1, "chorded Cmd rejected while held")

        var cancelled = TSScenario()
        cancelled.touch(K.rcmd, 0, 0.5, cancelled: true)
        cancelled.tap(K.q, at: 0.1, for: 0.1)
        cancelled.tap(K.e, at: 0.8, for: 0.08)
        let o2 = tsPlay(cancelled)
        XCTAssertEqual(o2.timed, ["+54@0.145", "+12@0.145", "-12@0.200", "-54@0.500", "+14@0.845", "-14@0.880"])
        assertClean(o2, "chorded Cmd cancelled")

        // Shift that capitalised a home-row tap, then rejected while held: next letter is lower case.
        var shift = TSScenario()
        let sh = shift.touch(K.lshift, 0, 1.5)
        shift.tap(K.j, at: 0.1, for: 0.08)
        shift.at(0.4, .reject(id: sh))
        shift.tap(K.k, at: 0.7, for: 0.08)
        let o3 = tsPlay(shift)
        XCTAssertEqual(o3.timed, ["+56@0.180", "+38@0.180", "-38@0.180", "-56@0.400", "+40@0.780", "-40@0.780"])
        XCTAssertEqual(o3.text, "Jk")
        assertClean(o3, "Shift rejected after a capital")
    }

    // A non-home key that is down and then rejected posts its up at the rejection; its lift posts
    // nothing more. A rejected pending home-row contact never types.
    func testRejectedDownKeyPostsItsUp() {
        var sc = TSScenario()
        let e = sc.touch(K.e, 0, 1.0)
        sc.at(0.5, .reject(id: e))
        let o = tsPlay(sc)
        XCTAssertEqual(o.timed, ["+14@0.045", "-14@0.500"])
        assertClean(o, "E rejected while down")

        var home = TSScenario()
        let f = home.touch(K.f, 0, 0.12)
        home.at(0.05, .reject(id: f))
        assertSilent(tsPlay(home), "F rejected before its lift")
    }

    // MARK: 16. Hunter probes (tc-hunt-1), kept as permanent scenarios

    // Rule F5 (H5, H5b, H5c, H7g): a hand landing one row off the home row (no tactile bumps on
    // glass) is a placement too: 4+ keys landing within the burst window and staying down post
    // nothing (no letters, no held keys the Mac would repeat, no chord with a resting thumb).
    func testHunt_MisalignedHandPlacementPostsNothing() {
        var qwer = TSScenario()
        qwer.touch(K.q, 0.00, 3.0); qwer.touch(K.w, 0.01, 3.0); qwer.touch(K.e, 0.02, 3.0)
        qwer.touch(K.r, 0.03, 3.0); qwer.touch(K.space, 0.04, 3.0)
        assertSilent(tsPlay(qwer), "H5: Q W E R + Space thumb")

        var uiop = TSScenario()
        uiop.rest(K.leftHand, from: 0, until: 6.0)
        uiop.touch(K.u, 1.00, 3.0); uiop.touch(K.i, 1.01, 3.0); uiop.touch(K.o, 1.02, 3.0); uiop.touch(K.p, 1.03, 3.0)
        assertSilent(tsPlay(uiop), "H5b: U I O P while the left hand rests")

        var half = TSScenario()
        half.touch(K.a, 0.00, 3.0); half.touch(K.w, 0.01, 3.0); half.touch(K.e, 0.02, 3.0); half.touch(K.f, 0.03, 3.0)
        assertSilent(tsPlay(half), "H5c: A W E F")

        var cmd = TSScenario()
        cmd.touch(K.rcmd, 0.00, 3.0)
        cmd.touch(K.u, 0.01, 3.0); cmd.touch(K.i, 0.02, 3.0); cmd.touch(K.o, 0.03, 3.0); cmd.touch(K.p, 0.04, 3.0)
        assertSilent(tsPlay(cmd), "H7g: right Cmd thumb + U I O P")

        // Control: the same keys typed as a fast roll of taps still type, in order.
        var roll = TSScenario()
        roll.touch(K.q, 1.00, 1.09); roll.touch(K.w, 1.01, 1.10); roll.touch(K.e, 1.02, 1.12); roll.touch(K.r, 1.03, 1.13)
        let o = tsPlay(roll)
        XCTAssertEqual(o.text, "qwer", "a 4-key roll of taps inside the burst window still types")
        assertClean(o, "qwer roll")
    }

    // Rules F3b/F5 (H1, H1b, H7e), user configuration: the tap-only left Cmd thumb bounces off
    // before the third home-row finger completes the placement burst. The bounce overlapped the
    // placement, so no input-source switch; the same shapes with a plain modifier are silent too.
    func testHunt_TapOnlyBounceBeforeTheBurstFormsPostsNothing() {
        var h1 = TSScenario()
        h1.touch(K.lcmd, 0.000, 0.025)
        h1.touch(K.a, 0.010, 3.0); h1.touch(K.s, 0.020, 3.0); h1.touch(K.d, 0.030, 3.0); h1.touch(K.f, 0.040, 3.0)
        h1.touch(K.lcmd, 0.060, 3.0)
        assertSilent(tsPlay(h1, userConfig), "H1 tap-only")
        assertSilent(tsPlay(h1), "H1 plain modifier")

        var h1b = TSScenario()
        h1b.touch(K.lcmd, 0.000, 0.015)
        h1b.touch(K.f, 0.005, 3.0); h1b.touch(K.j, 0.010, 3.0)
        h1b.touch(K.d, 0.020, 3.0); h1b.touch(K.k, 0.030, 3.0); h1b.touch(K.s, 0.04, 3.0); h1b.touch(K.l, 0.05, 3.0)
        h1b.touch(K.lcmd, 0.045, 3.0)
        assertSilent(tsPlay(h1b, userConfig), "H1b tap-only, both hands")
        assertSilent(tsPlay(h1b), "H1b plain modifier")

        var h7e = TSScenario()
        h7e.touch(K.lcmd, 0.0, 0.05)
        h7e.touch(K.a, 0.02, 3.0); h7e.touch(K.s, 0.04, 3.0); h7e.touch(K.d, 0.07, 3.0); h7e.touch(K.f, 0.09, 3.0)
        h7e.touch(K.lcmd, 0.08, 3.0)
        assertSilent(tsPlay(h7e, userConfig), "H7e tap-only, slower roll")
        assertSilent(tsPlay(h7e), "H7e plain modifier")

        // Control: a switch followed at once by a fast roll of home-row taps (two of them landing
        // during the switch) is not a placement: the switch and the letters post, in order.
        var roll = TSScenario()
        roll.touch(K.lcmd, 1.0, 1.08)
        roll.touch(K.a, 1.05, 1.13); roll.touch(K.s, 1.07, 1.15); roll.touch(K.d, 1.10, 1.18)
        let or = tsPlay(roll, userConfig)
        XCTAssertEqual(or.text, "[LCmd]asd")
        assertClean(or, "switch then a roll")

        // Control: a deliberate switch with one finger landing during it still switches at once.
        var one = TSScenario()
        one.touch(K.lcmd, 1.0, 1.10)
        one.touch(K.j, 1.05, 1.13)
        let o = tsPlay(one, userConfig)
        XCTAssertEqual(o.timed, ["+55@1.100", "-55@1.100", "+38@1.130", "-38@1.130"])
        assertClean(o, "switch with one finger landing")
    }

    // Rules F1/F5 (H2, H2b, H7f): a thumb bouncing on Space while the hands are put down types no
    // space (the same shapes are silent for modifiers and tap-only left Cmd).
    func testHunt_SpaceBounceDuringPlacementPostsNothing() {
        var mid = TSScenario()
        for (n, c) in K.bothHands.enumerated() { mid.touch(c, Double(n) * 0.01, 3.0) }
        mid.touch(K.space, 0.03, 0.09); mid.touch(K.space, 0.14, 3.0)
        assertSilent(tsPlay(mid), "H2: Space bounce mid-placement")

        var first = TSScenario()
        first.touch(K.space, 0.0, 0.10)
        for (n, c) in K.bothHands.enumerated() { first.touch(c, 0.03 + Double(n) * 0.01, 3.0) }
        first.touch(K.space, 0.16, 3.0)
        assertSilent(tsPlay(first), "H2b: Space first, hands follow, Space bounces")

        var early = TSScenario()
        early.touch(K.space, 0.0, 0.05)
        early.touch(K.j, 0.02, 3.0); early.touch(K.k, 0.04, 3.0); early.touch(K.l, 0.07, 3.0)
        early.touch(K.semicolon, 0.09, 3.0)
        early.touch(K.space, 0.08, 3.0)
        assertSilent(tsPlay(early), "H7f: Space bounce ends before the burst forms")

        // Controls: Space inside a fast roll of home-row taps still types, in landing order.
        var roll = TSScenario()
        roll.touch(K.space, 1.00, 1.08); roll.touch(K.s, 1.03, 1.11); roll.touch(K.a, 1.06, 1.14)
        roll.touch(K.d, 1.09, 1.17)
        let o = tsPlay(roll)
        XCTAssertEqual(o.text, " sad")
        assertClean(o, "Space in a roll")

        var after = TSScenario()
        after.touch(K.s, 1.00, 1.08); after.touch(K.a, 1.03, 1.11); after.touch(K.space, 1.05, 1.13)
        after.touch(K.d, 1.09, 1.17)
        let o2 = tsPlay(after)
        XCTAssertEqual(o2.text, "sa d")
        assertClean(o2, "Space inside a roll")
    }

    // Rules F3/F5 (H3, H3b, H6): a pinky or thumb that settles with its hand in a staggered
    // placement (fingers 70 ms apart, so no burst) while the other hand rests settles with it:
    // later typing is plain and a click is a plain click.
    func testHunt_ModifierSettlingWithAStaggeredHandNeverChords() {
        var h3 = TSScenario()
        h3.rest(K.rightHand, from: 0, until: 6.0)
        h3.touch(K.lshift, 2.00, 6.0)
        h3.touch(K.a, 2.00, 6.0); h3.touch(K.s, 2.07, 6.0); h3.touch(K.d, 2.14, 6.0); h3.touch(K.f, 2.21, 6.0)
        h3.tap(K.h, at: 3.0, for: 0.07)
        h3.tap(K.u, at: 3.3, for: 0.07)
        let o3 = tsPlay(h3)
        XCTAssertEqual(o3.timed, ["+4@3.045", "-4@3.070", "+32@3.345", "-32@3.370"], "H3")
        assertClean(o3, "H3")

        var h3b = TSScenario()
        h3b.rest(K.leftHand, from: 0, until: 6.0)
        h3b.touch(K.rcmd, 2.00, 6.0)
        h3b.touch(K.j, 2.00, 6.0); h3b.touch(K.k, 2.07, 6.0); h3b.touch(K.l, 2.14, 6.0); h3b.touch(K.semicolon, 2.21, 6.0)
        h3b.tap(K.w, at: 3.0, for: 0.07)
        let ob = tsPlay(h3b)
        XCTAssertEqual(ob.timed, ["+13@3.045", "-13@3.070"], "H3b: no Cmd+W")
        assertClean(ob, "H3b")

        var h6 = TSScenario()
        h6.rest(K.rightHand, from: 0, until: 6.0)
        h6.touch(K.lshift, 2.00, 6.0)
        h6.touch(K.a, 2.00, 6.0); h6.touch(K.s, 2.07, 6.0); h6.touch(K.d, 2.14, 6.0); h6.touch(K.f, 2.21, 6.0)
        h6.at(3.0, .commitHeldModifiers)
        assertSilent(tsPlay(h6), "H6: no Shift-click")
    }

    // Rule F3a (PV4 with a finger re-landing): a modifier pressed after the hands settled chords
    // even when one finger re-landed just before it and then rests.
    func testHunt_ModifierPressedAfterOneFingerReLandsStillChords() {
        var cmdC = TSScenario()
        cmdC.rest([K.a, K.s, K.d, K.f, K.k, K.l, K.semicolon], from: 0, until: 4.0)
        cmdC.touch(K.j, 0.95, 4.0)
        cmdC.touch(K.rcmd, 1.0, 2.0)
        cmdC.tap(K.c, at: 1.45, for: 0.08)
        let o = tsPlay(cmdC)
        XCTAssertEqual(o.timed, ["+54@1.495", "+8@1.495", "-8@1.530", "-54@2.000"])
        XCTAssertEqual(o.text, "⌘c")
        assertClean(o, "Cmd+C after J re-landed")

        var shiftT = TSScenario()
        shiftT.rest([K.s, K.d, K.f, K.k, K.l, K.semicolon], from: 0, until: 4.0)
        shiftT.touch(K.j, 0.95, 4.0)
        shiftT.touch(K.lshift, 1.0, 2.0)
        shiftT.tap(K.t, at: 1.4, for: 0.08)
        XCTAssertEqual(tsPlay(shiftT).text, "T")

        var at = TSScenario()
        at.rest([K.s, K.d, K.f, K.k, K.l, K.semicolon], from: 0, until: 4.0)
        at.touch(K.j, 0.90, 4.0)
        at.touch(K.rshift, 1.0, 2.0)
        at.tap(K.two, at: 1.35, for: 0.08)
        XCTAssertEqual(tsPlay(at).text, "⇧2", "Shift+2")

        var cmdV = TSScenario()
        cmdV.rest([K.a, K.s, K.d, K.k, K.l, K.semicolon], from: 0, until: 4.0)
        cmdV.touch(K.space, 0.05, 4.0)
        cmdV.touch(K.f, 0.85, 4.0)
        cmdV.touch(K.lcmd, 1.0, 2.0)
        cmdV.tap(K.v, at: 1.30, for: 0.08)
        XCTAssertEqual(tsPlay(cmdV).text, "⌘v")

        // Control: two or more fingers still settling when the modifier lands is a hand settling
        // with it (the settle rule): later typing stays plain.
        var settle = TSScenario()
        settle.rest(K.leftHand, from: 0, until: 4.0)
        settle.touch(K.j, 0.93, 4.0); settle.touch(K.k, 0.95, 4.0)
        settle.touch(K.rcmd, 1.0, 4.0)
        settle.tap(K.e, at: 1.6, for: 0.08)
        let os = tsPlay(settle)
        XCTAssertEqual(os.text, "e")
        assertNoModifierPosted(os, "two fingers settling with right Cmd")
    }

    // Rules F3b/F4 (landing order): a lone modifier tap (fn, Shift, Cmd without tapOnly) that
    // lands after a still-undecided home-row letter or Space is posted after it, not ahead of it.
    func testHunt_LoneModifierTapKeepsLandingOrder() {
        var fn = TSScenario()
        fn.touch(K.k, 1.0, 1.14)
        fn.touch(K.fn, 1.05, 1.11)
        let o1 = tsPlay(fn)
        XCTAssertEqual(o1.timed, ["+40@1.140", "-40@1.140", "+63@1.140", "-63@1.140"])
        assertClean(o1, "k then fn tap")

        var cmd = TSScenario()
        cmd.touch(K.j, 1.0, 1.15)
        cmd.touch(K.lcmd, 1.05, 1.12)
        let o2 = tsPlay(cmd)
        XCTAssertEqual(o2.timed, ["+38@1.150", "-38@1.150", "+55@1.150", "-55@1.150"])
        assertClean(o2, "j then left Cmd tap")

        var space = TSScenario()
        space.touch(K.space, 1.0, 1.15)
        space.touch(K.lcmd, 1.06, 1.12)
        let o3 = tsPlay(space)
        XCTAssertEqual(o3.timed, ["+49@1.150", "-49@1.150", "+55@1.150", "-55@1.150"])
        assertClean(o3, "Space then left Cmd tap")

        // A key that lands after the lone tap lifted follows it.
        var next = TSScenario()
        next.touch(K.k, 1.0, 1.14)
        next.touch(K.lshift, 1.05, 1.10)
        next.touch(K.l, 1.115, 1.13)
        let o4 = tsPlay(next)
        XCTAssertEqual(o4.text, "k[LShift]l")
        assertClean(o4, "k, Shift tap, l")
    }

    // Rule F3b: a lone modifier tap during which an unrelated finger lands and rests (nothing
    // committed) is still a lone tap. It is posted once that finger is decided (it rests at its
    // tapMax), because until then the finger could still be a key the modifier applies to.
    func testHunt_LoneModifierTapWithAFingerSettlingDuringIt() {
        var fn = TSScenario()
        fn.touch(K.fn, 1.0, 1.12)
        fn.touch(K.j, 1.05, 4.0)
        XCTAssertEqual(tsPlay(fn).timed, ["+63@1.350", "-63@1.350"])

        var cmd = TSScenario()
        cmd.touch(K.lcmd, 1.0, 1.12)
        cmd.touch(K.space, 1.04, 4.0)
        XCTAssertEqual(tsPlay(cmd).timed, ["+55@1.340", "-55@1.340"])

        var shift = TSScenario()
        shift.touch(K.rshift, 1.0, 1.12)
        shift.touch(K.f, 1.04, 4.0)
        XCTAssertEqual(tsPlay(shift).timed, ["+60@1.340", "-60@1.340"])

        var before = TSScenario()
        before.touch(K.j, 0.98, 4.0)
        before.touch(K.lshift, 1.0, 1.10)
        XCTAssertEqual(tsPlay(before).timed, ["+56@1.280", "-56@1.280"])
    }

    // Rule F5 (H4b): two thumbs settling with no hands, the left Cmd thumb bouncing once (40 ms
    // contact, back 30 ms later) while the Space thumb is undecided, posts nothing, for the
    // tap-only code and for a plain modifier.
    func testHunt_ThumbBounceWhileTheOtherThumbSettlesPostsNothing() {
        var two = TSScenario()
        two.touch(K.space, 0.0, 6.0)
        two.touch(K.lcmd, 0.02, 0.06); two.touch(K.lcmd, 0.09, 6.0)
        assertSilent(tsPlay(two, userConfig), "H4b tap-only")
        assertSilent(tsPlay(two), "H4b plain modifier")

        // Control: two quick deliberate taps queued behind a settling thumb are not a bounce.
        var double = TSScenario()
        double.touch(K.space, 0.0, 6.0)
        double.touch(K.lcmd, 0.02, 0.10); double.touch(K.lcmd, 0.16, 0.24)
        XCTAssertEqual(tsPlay(double, userConfig).timed, ["+55@0.300", "-55@0.300", "+55@0.300", "-55@0.300"])
    }

    // Rule F4 (camelCase rollover): a Shift meant for the next letter does not also modify the
    // letter that landed just before it when that next letter lands under the Shift before the
    // earlier letter commits (home-row letters and Space commit at their lift). A non-home letter
    // commits 45 ms after landing, usually before the next letter lands, so "iPhone" with Shift
    // landing 20 ms after the i can still give "IP" (chordTolerance, testFastCapitals...).
    func testHunt_ShiftForTheNextLetterDoesNotApplyBackwards() {
        var js = TSScenario()
        js.touch(K.a, 1.0, 1.10)
        js.touch(K.lshift, 1.02, 1.12)
        js.touch(K.s, 1.06, 1.15)
        let o1 = tsPlay(js)
        XCTAssertEqual(o1.text, "aS")
        assertClean(o1, "JavaScript")

        var sentence = TSScenario()
        sentence.touch(K.space, 1.0, 1.10)
        sentence.touch(K.rshift, 1.025, 1.13)
        sentence.touch(K.t, 1.07, 1.15)
        let o3 = tsPlay(sentence)
        XCTAssertEqual(o3.timed.first, "+49@1.100")
        XCTAssertEqual(o3.text, " T")
        assertClean(o3, ". T")

        for (i, phrase) in ["sad. All fall", "jasd fkl; Salsa", "the Last Jedi has ads"].enumerated() {
            var sc = TSScenario()
            sc.type(phrase, from: 0.5, wpm: 170, seed: UInt64(i + 1))
            let o = tsPlay(sc)
            XCTAssertEqual(o.text, phrase, "'\(phrase)' at 170 wpm")
            assertClean(o, phrase)
        }
    }

    // MARK: 17. Hunter probes (tc-hunt-2), kept as permanent scenarios

    // Rules F3/F5 (finding A): a finger bouncing as the hand is put down (35 ms contact among
    // fingers that then rest) never posts the thumb or pinky modifier that settled first, so later
    // typing is not chorded (no Cmd+F then Cmd+H, no Shift held for 3 s). Ruling: the bounce
    // itself may type one plain letter.
    func testHunt2_HeadFingerBounceInPlacementNeverPostsTheThumbModifier() {
        for mod in [K.rcmd, K.lshift, K.rshift, K.lopt, K.lctrl, K.fn] {
            var sc = TSScenario()
            sc.touch(mod, 0, 3.0)
            sc.touch(K.f, 0.01, 0.045)
            sc.touch(K.d, 0.02, 3.0); sc.touch(K.s, 0.03, 3.0); sc.touch(K.a, 0.04, 3.0)
            sc.touch(K.f, 0.075, 3.0)
            sc.tap(K.h, at: 1.2, for: 0.07)
            for settings in [userConfig, TypingSettings()] {
                let o = tsPlay(sc, settings)
                XCTAssertFalse(o.postedCodes.contains(mod), "mod \(mod) posted: \(o.timed)")
                XCTAssertTrue(["h", "fh"].contains(o.text), "mod \(mod): \(o.text)")
                assertClean(o, "bounce with mod \(mod)")
            }
        }

        // The bounce lifts before the burst forms.
        var early = TSScenario()
        early.touch(K.rcmd, 0, 3.0)
        early.touch(K.j, 0.01, 0.04)
        early.touch(K.k, 0.05, 3.0); early.touch(K.l, 0.06, 3.0); early.touch(K.semicolon, 0.07, 3.0)
        early.touch(K.j, 0.07, 3.0)
        early.tap(K.e, at: 1.0, for: 0.07)
        let oe = tsPlay(early, userConfig)
        assertNoModifierPosted(oe, "bounce before the burst")
        XCTAssertTrue(["e", "je"].contains(oe.text), "bounce before the burst: \(oe.text)")
        assertClean(oe, "bounce before the burst")

        // Two hands and a thumb on Space.
        var two = TSScenario()
        two.touch(K.rcmd, 0, 3.0); two.touch(K.space, 0.005, 3.0)
        two.touch(K.j, 0.01, 0.04)
        two.touch(K.f, 0.02, 3.0); two.touch(K.k, 0.03, 3.0); two.touch(K.d, 0.04, 3.0)
        two.touch(K.l, 0.05, 3.0); two.touch(K.s, 0.06, 3.0); two.touch(K.j, 0.07, 3.0)
        two.tap(K.h, at: 1.0, for: 0.07)
        two.tap(K.e, at: 1.3, for: 0.07)
        let o2 = tsPlay(two, userConfig)
        assertNoModifierPosted(o2, "two hands and a Space thumb")
        XCTAssertTrue(["he", "jhe"].contains(o2.text), "two hands: \(o2.text)")
        assertClean(o2, "two hands and a Space thumb")

        // The index grazes G, then settles on F.
        var graze = TSScenario()
        graze.touch(K.rcmd, 0, 3.0)
        graze.touch(K.g, 0.01, 0.06)
        graze.touch(K.d, 0.02, 3.0); graze.touch(K.s, 0.03, 3.0); graze.touch(K.a, 0.04, 3.0)
        graze.touch(K.f, 0.075, 3.0)
        graze.tap(K.h, at: 1.2, for: 0.07)
        let og = tsPlay(graze, userConfig)
        assertNoModifierPosted(og, "G graze")
        XCTAssertTrue(["h", "gh"].contains(og.text), "G graze: \(og.text)")
        assertClean(og, "G graze")

        // A Space bounce and a finger bounce in the same placement type no space.
        var space = TSScenario()
        space.touch(K.rcmd, 0, 3.0)
        space.touch(K.f, 0.01, 0.045); space.touch(K.space, 0.015, 0.05)
        space.touch(K.d, 0.02, 3.0); space.touch(K.s, 0.03, 3.0); space.touch(K.a, 0.04, 3.0)
        space.touch(K.f, 0.075, 3.0); space.touch(K.space, 0.08, 3.0)
        let os = tsPlay(space, userConfig)
        assertNoModifierPosted(os, "Space bounce")
        XCTAssertTrue(["", "f"].contains(os.text), "Space bounce: '\(os.text)'")
        assertClean(os, "Space bounce")

        // A left-Cmd graze lifted before the burst, with the finger bouncing: no switch.
        var lcmd = TSScenario()
        lcmd.touch(K.lcmd, 0, 0.02)
        lcmd.touch(K.f, 0.01, 0.045)
        lcmd.touch(K.d, 0.02, 3.0); lcmd.touch(K.s, 0.03, 3.0); lcmd.touch(K.a, 0.04, 3.0)
        lcmd.touch(K.f, 0.075, 3.0); lcmd.touch(K.lcmd, 0.08, 3.0)
        let ol = tsPlay(lcmd, userConfig)
        XCTAssertFalse(ol.postedCodes.contains(K.lcmd), "left Cmd graze: \(ol.timed)")
        assertClean(ol, "left Cmd graze")

        // Controls: a fast capital roll with a burst shape keeps its Shift (testShiftSurvives...),
        // and Cmd held well before a quick home-row tap still chords at once.
        var cap = TSScenario()
        cap.touch(K.lshift, 0, 0.16)
        cap.touch(K.j, 0.03, 0.18); cap.touch(K.a, 0.06, 0.20); cap.touch(K.d, 0.09, 0.22)
        XCTAssertEqual(tsPlay(cap).text, "JAD")
        var cmdJ = TSScenario()
        cmdJ.touch(K.rcmd, 0, 0.5)
        cmdJ.touch(K.j, 0.15, 0.23)
        XCTAssertEqual(tsPlay(cmdJ).timed, ["+54@0.230", "+38@0.230", "-38@0.230", "-54@0.500"])
    }

    // Rule F5 (finding B): a hand landing one key off with the index first on G (or H) never
    // holds that key down for the Mac to repeat. While the other fingers are already landing at
    // its 45 ms confirmation, it waits for the burst and posts nothing. When they land later, G
    // was indistinguishable from a deliberate G at its confirmation (F2 pins G alone held as down
    // at 45 ms), so one g may type, but the key is released as soon as the burst forms, long
    // before any key repeat.
    func testHunt2_LeadingOffHomeFingerOfAPlacementNeverRepeats() {
        for (lead, home) in [(K.g, [K.f, K.d, K.s]), (K.h, [K.j, K.k, K.l])] {
            for gap in [0.03, 0.05, 0.07, 0.09] {
                var sc = TSScenario()
                sc.touch(lead, 0, 3.0)
                for (i, c) in home.enumerated() { sc.touch(c, gap + Double(i) * 0.01, 3.0) }
                let o = tsPlay(sc, userConfig)
                let formed = gap + 0.02
                if gap < 0.045 {
                    XCTAssertEqual(o.timed, [], "lead \(lead) gap \(gap)")
                } else {
                    XCTAssertEqual(o.timed, ["+\(lead)@0.045", "-\(lead)@\(tsFormat(formed))"],
                                   "lead \(lead) gap \(gap)")
                }
                assertClean(o, "lead \(lead) gap \(gap)")
            }
        }
        // Controls: G held alone still repeats (F2), and among resting hands too.
        var alone = TSScenario()
        alone.touch(K.g, 0, 1.0)
        XCTAssertEqual(tsPlay(alone).timed, ["+5@0.045", "-5@1.000"])
        var roll = TSScenario()
        roll.touch(K.g, 0, 0.09); roll.touch(K.a, 0.03, 0.11); roll.touch(K.s, 0.04, 0.12); roll.touch(K.d, 0.05, 0.13)
        XCTAssertEqual(tsPlay(roll).text, "gasd", "a fast roll starting on G still types")
    }

    // Rules F3b/F5 (finding C): a thumb graze on the remapped left Cmd during a placement does not
    // switch the input source because another thumb tapped Space (or a lone non-home finger
    // grazed): thumb taps never confirm a roll; only two tapping keys do.
    func testHunt2_TapOnlyGrazeIgnoresOtherThumbTapsInThePlacement() {
        var sc = TSScenario()
        sc.touch(K.lcmd, 0, 0.035)
        sc.touch(K.j, 0.02, 3.0); sc.touch(K.k, 0.03, 3.0)
        sc.touch(K.space, 0.04, 0.11)
        sc.touch(K.l, 0.05, 3.0)
        assertSilent(tsPlay(sc, userConfig), "left Cmd graze with a Space tap")

        var g = TSScenario()
        g.touch(K.lcmd, 0, 0.035)
        g.touch(K.a, 0.02, 3.0); g.touch(K.s, 0.03, 3.0); g.touch(K.d, 0.04, 3.0)
        g.touch(K.g, 0.05, 0.09)
        g.touch(K.f, 0.12, 3.0)
        let og = tsPlay(g, userConfig)
        XCTAssertFalse(og.postedCodes.contains(K.lcmd), "left Cmd graze with a G graze: \(og.timed)")
        assertClean(og, "left Cmd graze with a G graze")
    }

    // Rule F5 (finding D, user configuration): the thumb grazes left Cmd (30 ms) and settles on
    // Space or on left Cmd itself among resting hands: no input-source switch. A tap-only tap of
    // at most 50 ms waits 50 ms for that settle. Not changed (lead decision, as H4): Space grazed
    // for 30 ms before the thumb settles on left Cmd still types a space, because
    // testDeliberateTapOfEveryRestCapableKeyPostsExactlyOneDownUp pins a 30 ms Space tap among
    // resting hands as typing at its lift.
    func testHunt2_ThumbGrazingLeftCmdOnItsWayToRestPostsNothing() {
        for next in [K.space, K.lcmd, K.lopt] {
            var sc = TSScenario()
            sc.rest(K.homeLetters, from: 0, until: 6.0)
            sc.touch(K.lcmd, 2.0, 2.03)
            sc.touch(next, 2.05, 6.0)
            assertSilent(tsPlay(sc, userConfig), "left Cmd graze, then \(next)")
        }
        // Controls: a deliberate 30 ms switch still switches, 50 ms after its lift at most.
        var quick = TSScenario()
        quick.rest(K.homeLetters, from: 0, until: 6.0)
        quick.touch(K.lcmd, 2.0, 2.03)
        assertTapPosted(tsPlay(quick, userConfig), K.lcmd, at: 2.08, "30 ms switch")
        var normal = TSScenario()
        normal.rest(K.homeLetters, from: 0, until: 6.0)
        normal.touch(K.lcmd, 2.0, 2.10)
        normal.touch(K.space, 2.12, 6.0)
        assertTapPosted(tsPlay(normal, userConfig), K.lcmd, at: 2.10, "100 ms switch, then a resting Space thumb")
    }

    // Rules F3a/F4 (finding E): a modifier landing late in a fast roll (it makes the roll look like
    // a burst) keeps chording the key typed under it once the roll's keys all type.
    func testHunt2_ShortcutOrCapitalRightAfterAFastRollKeepsItsModifier() {
        var cmdV = TSScenario()
        cmdV.touch(K.l, 1.00, 1.14); cmdV.touch(K.a, 1.04, 1.15); cmdV.touch(K.d, 1.08, 1.17)
        cmdV.touch(K.rcmd, 1.115, 1.30); cmdV.touch(K.v, 1.16, 1.22)
        let o1 = tsPlay(cmdV)
        XCTAssertEqual(o1.text, "lad⌘v")
        assertClean(o1, "lad then Cmd+V")
        var cap = TSScenario()
        cap.touch(K.a, 1.00, 1.13); cap.touch(K.d, 1.055, 1.15); cap.touch(K.space, 1.10, 1.17)
        cap.touch(K.rshift, 1.115, 1.22); cap.touch(K.t, 1.16, 1.24)
        let o2 = tsPlay(cap)
        XCTAssertEqual(o2.text, "ad T")
        assertClean(o2, "ad T")
    }

    // Rules F3b/F4 (finding F, user configuration): an input-source switch held while a fast roll
    // forms a burst still switches, in landing order; in a placement it stays silent (H1 pins).
    func testHunt2_InputSourceSwitchInsideAFastRollStillSwitches() {
        var after = TSScenario()
        after.touch(K.d, 1.00, 1.14); after.touch(K.s, 1.04, 1.15); after.touch(K.space, 1.08, 1.16)
        after.touch(K.lcmd, 1.12, 1.22)
        let o1 = tsPlay(after, userConfig)
        XCTAssertEqual(o1.text, "ds [LCmd]")
        assertClean(o1, "ds then switch")
        var before = TSScenario()
        before.touch(K.lcmd, 1.00, 1.15)
        before.touch(K.a, 1.04, 1.13); before.touch(K.s, 1.08, 1.17); before.touch(K.k, 1.12, 1.20)
        let o2 = tsPlay(before, userConfig)
        XCTAssertEqual(o2.text, "[LCmd]ask")
        assertClean(o2, "switch then ask")
        // Control: the same switch held while a hand is put down (keys rest) stays silent.
        var placed = TSScenario()
        placed.touch(K.lcmd, 1.00, 1.15)
        placed.touch(K.a, 1.04, 3.0); placed.touch(K.s, 1.08, 3.0); placed.touch(K.k, 1.12, 3.0)
        assertSilent(tsPlay(placed, userConfig), "switch held while a hand lands")
    }

    // Rule F3a (finding G): without resting hands, one finger anchoring (or a thumb on Space plus
    // one finger) does not make a later deliberate Cmd+key type plain; nor does a slow Shift+K
    // that rested drop Shift for the retry.
    func testHunt2_ChordAfterOneAnchoringFingerWithoutRestingHands() {
        for gap in [0.10, 0.20, 0.28] {
            var cmdC = TSScenario()
            cmdC.touch(K.j, 1.00, 3.0)
            cmdC.touch(K.rcmd, 1.00 + gap, 1.80)
            cmdC.tap(K.c, at: 1.45, for: 0.07)
            let o = tsPlay(cmdC)
            XCTAssertEqual(o.text, "⌘c", "gap \(gap)")
            assertClean(o, "anchor gap \(gap)")
        }
        var spaceThumb = TSScenario()
        spaceThumb.touch(K.space, 0.0, 3.0)
        spaceThumb.touch(K.f, 1.00, 3.0)
        spaceThumb.touch(K.rcmd, 1.15, 1.80)
        spaceThumb.tap(K.c, at: 1.45, for: 0.07)
        XCTAssertEqual(tsPlay(spaceThumb).text, "⌘c")

        var retry = TSScenario()
        retry.touch(K.rshift, 1.0, 1.9)
        retry.touch(K.k, 1.05, 1.40)
        retry.touch(K.k, 1.50, 1.58)
        XCTAssertEqual(tsPlay(retry).text, "K", "slow Shift+K retried")
    }

    // MARK: 18. Hunter probes (tc-hunt-3), kept as permanent scenarios

    // Rules F3/F5 (finding H3A): two fingers bouncing while a hand is put down beside a thumb or
    // pinky that settled first never post that modifier, so later typing is never chorded.
    func testHunt3_TwoFingerBounceInPlacementNeverPostsTheModifier() {
        for mod in [K.rcmd, K.rshift, K.ropt, K.fn] {
            for (on, off) in [(0.03, 0.03), (0.04, 0.03), (0.06, 0.04)] {
                var sc = TSScenario()
                sc.touch(mod, 0, 3.0)
                sc.touch(K.j, 0.01, 0.01 + on); sc.touch(K.j, 0.01 + on + off, 3.0)
                sc.touch(K.k, 0.02, 0.02 + on); sc.touch(K.k, 0.02 + on + off, 3.0)
                sc.touch(K.l, 0.03, 3.0); sc.touch(K.semicolon, 0.04, 3.0)
                sc.type("was", from: 1.2, wpm: 80)
                for settings in [userConfig, TypingSettings()] {
                    let o = tsPlay(sc, settings)
                    assertNoModifierPosted(o, "mod \(mod) bounce \(on)/\(off)")
                    XCTAssertTrue(o.text.hasSuffix("was"), "mod \(mod) bounce \(on)/\(off): \(o.text)")
                    assertClean(o, "two-finger bounce \(mod)")
                }
            }
        }
        // Left hand with left Shift settling first.
        var left = TSScenario()
        left.touch(K.lshift, 0, 3.0)
        left.touch(K.f, 0.01, 0.04); left.touch(K.f, 0.07, 3.0)
        left.touch(K.d, 0.02, 0.05); left.touch(K.d, 0.08, 3.0)
        left.touch(K.s, 0.03, 3.0); left.touch(K.a, 0.04, 3.0)
        left.type("hulk", from: 1.2, wpm: 80)
        let ol = tsPlay(left, userConfig)
        assertNoModifierPosted(ol, "left Shift, two bouncing fingers")
        XCTAssertTrue(ol.text.hasSuffix("hulk"), ol.text)
    }

    // Rules F3/F5 (fuzzing after H3A): a finger bouncing as a hand is put down while the thumb
    // grazes Option, Shift or Command (lifting before the finger) never types a chord.
    func testHunt3_FingerBounceWhileTheThumbGrazesItsModifierTypesPlain() {
        for mod in [K.ropt, K.rshift, K.rcmd] {
            var sc = TSScenario()
            sc.touch(K.k, 1.026, 4.0); sc.touch(K.a, 1.029, 4.0); sc.touch(K.j, 1.044, 4.0)
            sc.touch(K.s, 1.045, 4.0); sc.touch(K.l, 1.051, 4.0); sc.touch(K.semicolon, 1.063, 4.0)
            sc.touch(mod, 1.055, 1.103)
            sc.touch(K.f, 1.078, 1.138); sc.touch(K.f, 1.174, 4.0)
            sc.touch(K.d, 1.098, 4.0)
            sc.touch(K.space, 1.150, 4.0)
            sc.type("was", from: 2.5, wpm: 80)
            let o = tsPlay(sc, userConfig)
            assertNoModifierPosted(o, "graze \(mod)")
            XCTAssertTrue(o.text.hasSuffix("was"), "graze \(mod): \(o.text)")
            assertClean(o, "graze \(mod)")
        }
    }

    // Rules F3a/F5 (finding H3B): a thumb coming to rest on Cmd/Option/Shift just after the other
    // thumb's Space (or a home letter) landed does not chord that tap backwards, and later typing
    // stays plain. The Space went down before the thumb arrived on a real MacBook.
    func testHunt3_ThumbSettlingJustAfterATapLandsDoesNotChordBackwards() {
        for mod in [K.rcmd, K.ropt, K.lopt, K.rshift] {
            for d in [0.005, 0.015, 0.025] {
                var sc = TSScenario()
                sc.type("ok", from: 0.0, wpm: 80)
                sc.touch(K.space, 0.40, 0.48)
                sc.touch(mod, 0.40 + d, 3.0)
                sc.type("the", from: 0.8, wpm: 80)
                let o = tsPlay(sc, userConfig)
                XCTAssertEqual(o.text, "ok the", "mod \(mod) +\(d): \(o.timed)")
                assertClean(o, "thumb settling after Space \(mod)")
            }
        }
        var left = TSScenario()
        left.type("ok", from: 0.0, wpm: 80)
        left.touch(K.space, 0.40, 0.48)
        left.touch(K.lopt, 0.415, 3.0)
        left.type("you", from: 0.8, wpm: 80)
        XCTAssertEqual(tsPlay(left, userConfig).text, "ok you")
        var letter = TSScenario()
        letter.touch(K.a, 0.50, 0.58)
        letter.touch(K.rcmd, 0.52, 3.0)
        letter.type("you", from: 0.8, wpm: 80)
        XCTAssertEqual(tsPlay(letter, userConfig).text, "ayou")
        // Controls: a modifier that lands first (or with the key, within the tolerance, while the
        // key is held long enough to be a deliberate chord) still chords.
        var shiftFirst = TSScenario()
        shiftFirst.touch(K.rshift, 0.39, 0.50)
        shiftFirst.touch(K.a, 0.40, 0.48)
        XCTAssertEqual(tsPlay(shiftFirst, userConfig).text, "A")
    }

    // Rule F5 (finding H3C): a hand patting the home row (all fingers within a few ms, lifting
    // together) or put down and lifted again to reposition types nothing, also with a thumb on Cmd.
    // Rolls (testBurstyRollsOfHomeRowTapsTypeExactly) stay distinguishable.
    func testHunt3_HandPatOrRepositionTypesNothing() {
        for dur in [0.10, 0.15, 0.25] {
            var pat = TSScenario()
            for (i, c) in K.leftHand.enumerated() {
                pat.touch(c, 0.5 + Double(i) * 0.008, 0.5 + dur + Double(i) * 0.005)
            }
            assertSilent(tsPlay(pat, userConfig), "left-hand pat \(dur)")
            var both = TSScenario()
            for (i, c) in K.bothHands.enumerated() {
                both.touch(c, 0.5 + Double(i) * 0.006, 0.5 + dur + Double(i) * 0.004)
            }
            assertSilent(tsPlay(both, userConfig), "two-hand pat \(dur)")
            var reposition = TSScenario()
            for (i, c) in K.rightHand.enumerated() {
                reposition.touch(c, 0.5 + Double(i) * 0.008, 0.5 + dur + Double(i) * 0.005)
            }
            for (i, c) in K.rightHand.enumerated() { reposition.touch(c, 0.9 + Double(i) * 0.008, 3.0) }
            assertSilent(tsPlay(reposition, userConfig), "reposition \(dur)")
            var thumb = TSScenario()
            for (i, c) in K.rightHand.enumerated() {
                thumb.touch(c, 0.5 + Double(i) * 0.008, 0.5 + dur + Double(i) * 0.005)
            }
            thumb.touch(K.rcmd, 0.49, 0.5 + dur + 0.01)
            assertSilent(tsPlay(thumb, userConfig), "pat with thumb on RCmd \(dur)")
        }
    }

    // Rules F1/F5 (finding H3D): a Space or the input-source switch tapped by one thumb while the
    // typing hand returns to the home row types; only fingers that then rest are silenced.
    func testHunt3_SpaceOrSwitchWhileTheTypingHandReturnsHome() {
        func script(_ thumb: UInt16, duration: Double = 0.10) -> TSScenario {
            var sc = TSScenario()
            sc.rest(K.rightHand, from: 0, until: 4)
            sc.rest(K.leftHand, from: 0, until: 0.97)
            sc.tap(K.w, at: 1.05, for: 0.08); sc.tap(K.e, at: 1.15, for: 0.08); sc.tap(11, at: 1.25, for: 0.08)
            sc.touch(thumb, 1.36, 1.36 + duration)
            sc.rest([K.f, K.d, K.s, K.a], from: 1.38, spacing: 0.02, until: 4)
            return sc
        }
        for duration in [0.06, 0.10, 0.14, 0.20] {
            var sc = script(K.space, duration: duration)
            sc.type("is", from: 1.9, wpm: 100)
            let o = tsPlay(sc, userConfig)
            XCTAssertEqual(o.text, "web is", "Space \(duration)")
            assertClean(o, "Space while returning home \(duration)")
        }
        XCTAssertEqual(tsPlay(script(K.lcmd), userConfig).text, "web[LCmd]")
        // Mirror: right hand types "you" and returns home while the left thumb taps Space.
        var mirror = TSScenario()
        mirror.rest(K.leftHand, from: 0, until: 4)
        mirror.rest(K.rightHand, from: 0, until: 0.97)
        mirror.tap(16, at: 1.05, for: 0.08); mirror.tap(K.o, at: 1.15, for: 0.08); mirror.tap(K.u, at: 1.25, for: 0.08)
        mirror.touch(K.space, 1.36, 1.46)
        mirror.rest([K.j, K.k, K.l, K.semicolon], from: 1.38, spacing: 0.02, until: 4)
        XCTAssertEqual(tsPlay(mirror, userConfig).text, "you ")
        // Three fingers returning 40 ms apart.
        var three = TSScenario()
        three.rest(K.rightHand, from: 0, until: 4)
        three.rest(K.leftHand, from: 0, until: 0.97)
        three.tap(K.w, at: 1.05, for: 0.08); three.tap(K.e, at: 1.15, for: 0.08); three.tap(11, at: 1.25, for: 0.08)
        three.touch(K.space, 1.36, 1.46)
        three.rest([K.f, K.d, K.s], from: 1.38, spacing: 0.04, until: 4)
        XCTAssertEqual(tsPlay(three, userConfig).text, "web ")
    }

    // Rules F3a/PV4 (finding H3E): a shortcut or capital typed right after a Space among resting
    // hands keeps its modifier when the modifier lands while the Space is still down and a finger
    // that re-landed earlier then rests.
    func testHunt3_ModifierLandingWhileSpaceIsStillDownAfterAFingerReLanded() {
        for spaceUp in [1.36, 1.32] {
            var cmdF = TSScenario()
            cmdF.rest([K.a, K.s, K.d], from: 0, until: 4); cmdF.touch(K.f, 0.03, 1.5); cmdF.touch(K.f, 1.75, 4)
            cmdF.touch(K.j, 0.01, 4); cmdF.touch(K.l, 0.02, 4); cmdF.touch(K.semicolon, 0.03, 4)
            cmdF.touch(K.k, 0.04, 1.0); cmdF.tap(K.i, at: 1.03, for: 0.08); cmdF.touch(K.k, 1.20, 4)
            cmdF.touch(K.space, 1.25, spaceUp)
            cmdF.touch(K.rcmd, 1.33, 1.9)
            cmdF.tap(K.f, at: 1.55, for: 0.07)
            for settings in [userConfig, TypingSettings()] {
                let o = tsPlay(cmdF, settings)
                XCTAssertEqual(o.text, "i ⌘f", "Space up \(spaceUp)")
                assertClean(o, "Cmd+F after Space \(spaceUp)")
            }
        }
        var cap = TSScenario()
        cap.touch(K.a, 0.0, 1.30); cap.touch(K.a, 1.62, 4); cap.rest([K.s, K.d, K.f], from: 0.01, until: 4)
        cap.touch(K.j, 0.01, 1.42); cap.touch(K.j, 1.65, 4); cap.touch(K.l, 0.02, 4); cap.touch(K.semicolon, 0.03, 4)
        cap.touch(K.k, 0.04, 1.0); cap.tap(K.i, at: 1.03, for: 0.08); cap.touch(K.k, 1.15, 4)
        cap.touch(K.space, 1.30, 1.40); cap.touch(K.lshift, 1.38, 1.56); cap.tap(K.u, at: 1.46, for: 0.07)
        XCTAssertEqual(tsPlay(cap, userConfig).text, "i U")
    }

    // Settle rule (finding H3F): a finger and a thumb or pinky put down together (within 20 ms,
    // either order) and resting are a hand settling; the modifier never chords later typing.
    func testHunt3_FingerAndThumbPutDownTogetherNeverChordLaterTyping() {
        for gap in [-0.02, 0.0, 0.02] {
            var sc = TSScenario()
            sc.touch(K.j, max(0, -gap), 3.0)
            sc.touch(K.rcmd, max(0, gap), 3.0)
            sc.type("was", from: 1.0, wpm: 80)
            XCTAssertEqual(tsPlay(sc, userConfig).text, "was", "J + RCmd gap \(gap)")
            var sh = TSScenario()
            sh.touch(K.a, max(0, -gap), 3.0)
            sh.touch(K.lshift, max(0, gap), 3.0)
            sh.type("hulk", from: 1.0, wpm: 80)
            XCTAssertEqual(tsPlay(sh, userConfig).text, "hulk", "A + LShift gap \(gap)")
        }
    }

    // Rules F1/F3b (finding H3G): a quick input-source switch followed by a typed Space from the
    // other thumb, or a quick double switch, posts every switch.
    func testHunt3_QuickSwitchThenTypedSpaceOrDoubleSwitch() {
        var sc = TSScenario()
        sc.type("dad", from: 0, wpm: 120)
        sc.tap(K.lcmd, at: 0.35, for: 0.045)
        sc.tap(K.space, at: 0.425, for: 0.08)
        sc.type("ask", from: 0.6, wpm: 120)
        let o = tsPlay(sc, userConfig)
        XCTAssertEqual(o.text, "dad[LCmd] ask")
        assertClean(o, "quick switch then Space")
        var near = TSScenario()
        near.tap(K.lcmd, at: 0.0, for: 0.05)
        near.tap(K.space, at: 0.07, for: 0.08)
        XCTAssertEqual(tsPlay(near, userConfig).text, "[LCmd] ")
        var twice = TSScenario()
        twice.tap(K.lcmd, at: 0, for: 0.045); twice.tap(K.lcmd, at: 0.09, for: 0.05)
        XCTAssertEqual(tsPlay(twice, userConfig).text, "[LCmd][LCmd]")
    }

    // Rules F3a/PV4 (finding H3H): a modifier pressed after its own hand settled survives the
    // other hand landing while it is held; the shortcut or capital keeps its modifier.
    func testHunt3_SettledHandModifierSurvivesTheOtherHandLanding() {
        for handAt in [1.05, 1.3, 1.6] {
            var cmdV = TSScenario()
            cmdV.rest([K.a, K.s, K.d], from: 0, until: 4); cmdV.touch(K.f, 0.03, 1.45)
            cmdV.touch(K.lcmd, 1.0, 1.9)
            cmdV.rest(K.rightHand, from: handAt, spacing: 0.015, until: 4)
            cmdV.tap(K.v, at: max(1.5, handAt + 0.15), for: 0.08)
            let o = tsPlay(cmdV)
            XCTAssertEqual(o.text, "⌘v", "right hand at \(handAt)")
            assertClean(o, "Cmd+V right hand at \(handAt)")
        }
        var shiftU = TSScenario()
        shiftU.rest([K.s, K.d, K.f], from: 0, until: 4); shiftU.touch(K.a, 0.02, 0.95)
        shiftU.touch(K.lshift, 1.0, 1.7)
        shiftU.rest(K.rightHand, from: 1.3, spacing: 0.015, until: 4)
        shiftU.tap(K.u, at: 1.5, for: 0.08)
        XCTAssertEqual(tsPlay(shiftU, userConfig).text, "U")
    }
}
