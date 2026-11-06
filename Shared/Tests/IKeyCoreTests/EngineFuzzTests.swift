import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import IKeyCore

/// Seeded random sessions through `DeckInputEngine` (1-10 fingers on keys incl. modifiers, Caps
/// Lock and Space, the trackpad, Touch ID and the palm rests; 10-1500 ms touches, radii 6-110 pt,
/// 0-30 pt travel; random cancels, resets and suppress toggles; random engine settings) checking:
/// - I1: ordinary key downs come in landing order;
/// - I3: every key down is matched by an up or a releaseAll; nothing is held when all fingers lifted;
/// - I5: a contact rejected (size, invalid, suppressed), cancelled or forgotten by a reset never
///   posts its key;
/// - I6 (rest modes): a modifier goes out only right before what it applies to (a chord key, its
///   own lone tap, a button press, a scroll's start, a gesture, drag motion), never for plain motion;
/// - key and button balance (no double down, no up without down), mirrored by `heldKeyCodes` and
///   `heldButtons`;
/// - a touch-down call made after the timer caught up never presses a button;
/// - `nextDeadline` is in the future, and advancing to just before it changes nothing;
/// - every output encodes on the wire (first 1000 sessions); `.openPanel` comes with `.releaseAll`;
/// - no drawn key is left tentative once every finger lifted (KeyFeedback contract, incl. resets).
/// A failing session is re-run with a log of every call and its output, printed with its seed.
final class EngineFuzzTests: XCTestCase {
    func testRandomSessionsKeepInvariants() {
        let start = Date()
        var failures = 0
        var coverage = FuzzCoverage()
        for i in 0..<10_000 {
            let seed = 0x1CE5_2026 &+ UInt64(i)
            var session = FuzzSession(seed: seed, logging: false, validateWire: i < 1000)
            let result = session.run()
            coverage.add(session.coverage)
            guard let failure = result else { continue }
            var verbose = FuzzSession(seed: seed, logging: true, validateWire: true)
            _ = verbose.run()
            XCTFail("seed \(seed): \(failure)\n" + verbose.log.joined(separator: "\n"))
            failures += 1
            if failures == 3 { break }
        }
        print("EngineFuzzTests: 10000 sessions in \(String(format: "%.2f", Date().timeIntervalSince(start))) s, \(coverage)")
        // The script must keep reaching every path the invariants are about.
        XCTAssertGreaterThan(coverage.ordinaryDowns, 5000)
        XCTAssertGreaterThan(coverage.modifierDowns, 1000)
        XCTAssertGreaterThan(coverage.buttonDowns, 500)
        XCTAssertGreaterThan(coverage.scrolls, 100)
        XCTAssertGreaterThan(coverage.releaseAlls, 10_000 + 500, "beyond each session's final reset")
        XCTAssertGreaterThan(coverage.panels, 100)
        XCTAssertGreaterThan(coverage.deadTouches, 1000)
    }

    /// Key-only sessions (no trackpad, Touch ID or palm contacts, so the engine adds nothing of its
    /// own) must give exactly the timeline of a bare `KeyCommitPipeline` driven by its own
    /// `nextDeadline`: the engine's timer honours every pipeline deadline (confirmations, tap
    /// waits, burst checks, bounce followers, late-modifier waits, stale rests) at its own time.
    func testKeyOnlySessionsMatchThePipelineTimeline() {
        var mismatches = 0
        var keyEvents = 0
        for i in 0..<1500 {
            let seed = 0xDEAD_2026 &+ UInt64(i)
            var rng = SplitMix64(state: seed)
            let script = KeyScript(rng: &rng)
            let engine = script.runEngine()
            let pipeline = script.runPipeline()
            keyEvents += pipeline.count
            guard engine != pipeline else { continue }
            XCTFail("seed \(seed) \(script.typing)\n\(script.touches)\nengine   \(engine)\npipeline \(pipeline)")
            mismatches += 1
            if mismatches == 3 { break }
        }
        XCTAssertGreaterThan(keyEvents, 5000, "the scripts must keep typing")
        print("EngineFuzzTests: 1500 key-only sessions, \(keyEvents) key events, timelines identical")
    }
}

/// Random key touches at key centres (radius 10), with random travel, cancels and settings.
private struct KeyScript {
    struct Touch { let code: UInt16; let down: Double; let up: Double; let travelPt: Double; let cancelled: Bool }

    private static let deck = ResolvedDeck(spec: MacBookAirModel.air13_2022.spec,
                                           projection: DeckProjection(display: .pro13, screenSize: CGSize(width: 1376, height: 1032)))
    private static let codes: [UInt16] = [0, 1, 2, 3, 38, 40, 37, 41, 49, 49, 56, 60, 59, 58, 55, 54, 61, 63, 57,
                                          12, 13, 14, 15, 17, 4, 5, 32, 34, 31, 35, 6, 8, 9, 11, 45, 46, 51, 36, 48, 18]
    private static let centres: [UInt16: CGPoint] = Dictionary(
        deck.keys.compactMap { k in k.code.map { ($0, CGPoint(x: k.rect.midX, y: k.rect.midY)) } },
        uniquingKeysWith: { a, _ in a })

    let typing: TypingSettings
    let touches: [Touch]

    init(rng: inout SplitMix64) {
        typing = rng.pick([TypingSettings(), TypingSettings(tapOnlyCodes: [55]), TypingSettings(resting: .off),
                           TypingSettings(resting: .allTypingKeys), TypingSettings(isolatedHold: true),
                           TypingSettings(revealHeldModifiers: true, tapOnlyCodes: [55])])
        var touches: [Touch] = []
        let fast = rng.chance(0.5)
        for _ in 0..<(1 + rng.int(10)) {
            let down = fast ? rng.range(0, 0.6) : rng.range(0, 2.5)
            let duration = rng.chance(0.6) ? rng.range(0.01, 0.4) : rng.range(0.01, 1.5)
            touches.append(Touch(code: rng.pick(Self.codes), down: down, up: down + duration,
                                 travelPt: rng.chance(0.2) ? rng.range(0, 40) : 0, cancelled: rng.chance(0.05)))
        }
        self.touches = touches
    }

    private enum Step { case land, move, lift }

    private var steps: [(t: Double, seq: Int, index: Int, step: Step)] {
        var steps: [(t: Double, seq: Int, index: Int, step: Step)] = []
        for (i, touch) in touches.enumerated() {
            steps.append((touch.down, 3 * i, i, .land))
            if touch.travelPt > 0 { steps.append(((touch.down + touch.up) / 2, 3 * i + 1, i, .move)) }
            steps.append((touch.up, 3 * i + 2, i, .lift))
        }
        return steps.sorted { $0.t == $1.t ? $0.seq < $1.seq : $0.t < $1.t }
    }

    private var end: Double { (touches.map(\.up).max() ?? 0) + 2 }

    private func sample(_ i: Int, moved: Bool) -> TouchSample {
        let c = Self.centres[touches[i].code]!
        let x = moved ? c.x + CGFloat(touches[i].travelPt) : c.x
        return TouchSample(id: i + 1, point: CGPoint(x: x, y: c.y), radius: 10)
    }

    private static func stamp(_ t: Double, _ code: UInt16, _ down: Bool) -> String {
        "\(down ? "+" : "-")\(code)@\(String(format: "%.4f", t))"
    }

    func runEngine() -> [String] {
        var e = DeckInputEngine(deck: Self.deck, typing: typing)
        var out: [String] = []
        func record(_ t: Double, _ o: [PadInput]) {
            for case .key(let code, let down) in o { out.append(Self.stamp(t, code, down)) }
        }
        func drain(before t: Double) {
            var n = 0
            while let d = e.nextDeadline, d < t, n < 10_000 { record(d, e.advance(to: d)); n += 1 }
        }
        var moved = Set<Int>()
        for s in steps {
            drain(before: s.t)
            switch s.step {
            case .land: record(s.t, e.begin([sample(s.index, moved: false)], at: s.t))
            case .move:
                moved.insert(s.index)
                record(s.t, e.move([sample(s.index, moved: true)], at: s.t))
            case .lift:
                record(s.t, e.end([sample(s.index, moved: moved.contains(s.index))], at: s.t,
                                  cancelled: touches[s.index].cancelled))
            }
        }
        drain(before: end)
        record(end, e.advance(to: end))
        return out
    }

    func runPipeline() -> [String] {
        let mmPerPoint = Self.deck.mmPerPoint!
        var p = KeyCommitPipeline(settings: typing, confirmationDelay: 0.045)
        var out: [String] = []
        func record(_ t: Double, _ o: [PipelineOutput]) {
            for case .key(let code, let down) in o { out.append(Self.stamp(t, code, down)) }
        }
        func drain(before t: Double) {
            var n = 0
            while let d = p.nextDeadline, d < t, n < 10_000 { record(d, p.advance(to: d)); n += 1 }
        }
        for s in steps {
            drain(before: s.t)
            switch s.step {
            case .land: record(s.t, p.land(id: s.index, code: touches[s.index].code, at: s.t))
            case .move:
                // The engine's travel: the sample's distance from the landing point, in mm.
                let travel = abs(Double(sample(s.index, moved: true).point.x - sample(s.index, moved: false).point.x))
                record(s.t, p.move(id: s.index, travelMM: travel * mmPerPoint, at: s.t))
            case .lift: record(s.t, p.lift(id: s.index, at: s.t, cancelled: touches[s.index].cancelled))
            }
        }
        drain(before: end)
        record(end, p.advance(to: end))
        return out
    }
}

private struct FuzzCoverage: CustomStringConvertible {
    var ordinaryDowns = 0, modifierDowns = 0, buttonDowns = 0, scrolls = 0, releaseAlls = 0, panels = 0, deadTouches = 0

    mutating func add(_ o: FuzzCoverage) {
        ordinaryDowns += o.ordinaryDowns; modifierDowns += o.modifierDowns; buttonDowns += o.buttonDowns
        scrolls += o.scrolls; releaseAlls += o.releaseAlls; panels += o.panels; deadTouches += o.deadTouches
    }

    var description: String {
        "keys \(ordinaryDowns), modifiers \(modifierDowns), buttons \(buttonDowns), scrolls \(scrolls), "
            + "releaseAll \(releaseAlls), panels \(panels), rejected touches \(deadTouches)"
    }
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }
}

private struct FuzzSession {
    private enum Call {
        case begin(TouchSample), move(TouchSample), end(TouchSample, cancelled: Bool), advance, reset, suppress(Bool)
    }

    private struct Scheduled {
        let t: Double
        let order: Int
        let call: Call
        /// Key code for key touches (I1/I5 attribution).
        let code: UInt16?
    }

    private struct KeyTouch {
        let id: Int
        let code: UInt16
        let land: Double
        var dead: Bool
        var matched = false
    }

    private static let deck = ResolvedDeck(spec: MacBookAirModel.air13_2022.spec,
                                           projection: DeckProjection(display: .pro13, screenSize: CGSize(width: 1376, height: 1032)))
    private static let keyCodes: [UInt16] = [0, 1, 2, 3, 38, 40, 37, 41, 49, 49, 49, 56, 60, 59, 58, 55, 54, 61, 63, 57,
                                             12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 6, 7, 8, 9, 11, 45, 46,
                                             51, 36, 48, 53, 123, 124, 125, 126, 18, 19, 20, 21, 122, 120]
    private static let rects: [UInt16: CGRect] = Dictionary(
        deck.keys.compactMap { k in k.code.map { ($0, k.rect) } }, uniquingKeysWith: { a, _ in a })
    private static let touchIDRect = deck.keys.first { $0.id == "touchid" }!.rect
    private static let keyBottom = deck.keys.map(\.rect.maxY).max()!

    private var rng: SplitMix64
    private let logging: Bool
    private let validateWire: Bool
    private(set) var log: [String] = []
    private(set) var coverage = FuzzCoverage()
    private let protection: TouchProtectionSettings
    private let typing: TypingSettings
    private let trackpad: TrackpadSettings
    private var engine: DeckInputEngine
    private var events: [Scheduled] = []

    private var now = 0.0
    private var suppressed = false
    private var heldKeys: Set<UInt16> = []
    private var heldButtons: Set<PointerButton> = []
    private var keyTouches: [KeyTouch] = []
    private var lastOrdinaryLand = -Double.infinity
    /// Space touches that landed as broad thumbs (tolerated up to thumbRadius).
    private var broadSpaceIDs: Set<Int> = []
    private var visual = KeyVisualState()

    init(seed: UInt64, logging: Bool, validateWire: Bool) {
        var rng = SplitMix64(state: seed)
        self.logging = logging
        self.validateWire = validateWire
        typing = TypingSettings(resting: rng.pick([.off, .homeRow, .homeRow, .allTypingKeys]),
                                revealHeldModifiers: rng.chance(0.25),
                                tapOnlyCodes: rng.chance(0.25) ? [55] : [])
        protection = TouchProtectionSettings(enabled: rng.chance(0.9), sensitivity: rng.pick(TouchSensitivity.allCases),
                                             pauseTrackpadWhileTyping: rng.chance(0.8))
        trackpad = TrackpadSettings(dragStyle: rng.pick(DragStyle.allCases),
                                    dragReleaseDelay: rng.chance(0.2) ? 0.2 : 0)
        engine = DeckInputEngine(deck: Self.deck, protection: protection, typing: typing, trackpad: trackpad,
                                 panelTrigger: rng.pick(PanelTrigger.allCases))
        self.rng = rng
        generate()
    }

    // MARK: - Script

    private mutating func generate() {
        var busy: [UInt16: [(Double, Double)]] = [:]
        var order = 0
        func add(_ t: Double, _ call: Call, _ code: UInt16?) {
            events.append(Scheduled(t: t, order: order, call: call, code: code))
            order += 1
        }
        for id in 1...(1 + rng.int(10)) {
            let t0 = rng.range(0, 2.5), dur = rng.range(0.01, 1.5), t1 = t0 + dur
            var code: UInt16?
            var p: CGPoint
            let region = rng.unit()
            if region < 0.55 {
                // A code is never reused within 2 s, so every key down maps to one touch.
                for _ in 0..<8 {
                    let c = rng.pick(Self.keyCodes)
                    if !(busy[c] ?? []).contains(where: { !(t1 + 2 < $0.0 || $0.1 + 2 < t0) }) { code = c; break }
                }
            }
            if let c = code, let r = Self.rects[c] {
                busy[c, default: []].append((t0, t1))
                p = CGPoint(x: r.midX + r.width * CGFloat(rng.range(-0.3, 0.3)),
                            y: r.midY + r.height * CGFloat(rng.range(-0.3, 0.3)))
            } else if region < 0.85 {
                code = nil
                let r = Self.deck.trackpad.insetBy(dx: 2, dy: 2)
                p = CGPoint(x: r.minX + r.width * CGFloat(rng.unit()), y: r.minY + r.height * CGFloat(rng.unit()))
            } else if region < 0.92 {
                p = CGPoint(x: Self.touchIDRect.midX + CGFloat(rng.range(-5, 5)), y: Self.touchIDRect.midY + CGFloat(rng.range(-5, 5)))
            } else {
                let left = rng.chance(0.7)
                let x = left ? rng.range(5, Double(Self.deck.trackpad.minX) - 5)
                    : rng.range(Double(Self.deck.trackpad.maxX) + 5, 1370)
                p = CGPoint(x: x, y: rng.range(Double(Self.keyBottom) + 30, 1025))
            }
            var radius = rng.chance(0.75) ? rng.range(6, 30) : rng.range(6, 110)
            let tolerance = rng.chance(0.3) ? rng.range(0, 8) : 0
            if rng.chance(0.02) { radius = -1 }
            add(t0, .begin(TouchSample(id: id, point: p, radius: radius, radiusTolerance: tolerance)), code)
            let moves = rng.int(5)
            let travel = rng.range(0, 30), angle = rng.range(0, 2 * .pi)
            var point = p
            for k in 0..<moves {
                let f = Double(k + 1) / Double(moves)
                point = CGPoint(x: p.x + CGFloat(cos(angle) * travel * f), y: p.y + CGFloat(sin(angle) * travel * f))
                if rng.chance(0.1) { radius = rng.range(6, 110) }
                if rng.chance(0.01) { radius = .nan }
                let t = t0 + dur * Double(k + 1) / Double(moves + 1)
                add(t, .move(TouchSample(id: id, point: point, radius: radius, radiusTolerance: tolerance)), code)
            }
            add(t1, .end(TouchSample(id: id, point: point, radius: radius, radiusTolerance: tolerance),
                         cancelled: rng.chance(0.1)), code)
        }
        if rng.chance(0.05) { add(rng.range(0, 4), .reset, nil) }
        if rng.chance(0.05) {
            let on = rng.range(0, 3)
            add(on, .suppress(true), nil)
            add(on + rng.range(0.1, 1), .suppress(false), nil)
        }
        events.sort { $0.t == $1.t ? $0.order < $1.order : $0.t < $1.t }
    }

    // MARK: - Run

    mutating func run() -> String? {
        for e in events {
            let full: Bool
            switch e.call {
            case .begin, .reset, .suppress: full = true
            case .move(let s): full = makesDead(s, code: e.code)
            case .end(let s, let cancelled): full = cancelled || makesDead(s, code: e.code)
            case .advance: full = false
            }
            if full || rng.chance(0.5), let failure = runTimer(through: e.t) { return failure }
            if full, let failure = perform(.advance, at: e.t, code: nil) { return failure }
            if let failure = perform(e.call, at: e.t, code: e.code) { return failure }
        }
        let end = (events.last?.t ?? 0) + 5
        if let failure = runTimer(through: end) { return failure }
        if let failure = perform(.advance, at: end, code: nil) { return failure }
        if !heldKeys.isEmpty || !engine.heldKeyCodes.isEmpty { return "I3: keys held after every lift: \(heldKeys)" }
        if trackpad.dragStyle != .tapDragLock, !heldButtons.isEmpty { return "buttons held after every lift: \(heldButtons)" }
        if engine.hasActiveContacts { return "contacts left after every lift" }
        if !visual.tentative.isEmpty { return "drawn keys left tentative: \(visual.tentative)" }
        coverage.deadTouches += keyTouches.filter(\.dead).count
        return perform(.reset, at: end, code: nil)
    }

    private mutating func runTimer(through t: Double) -> String? {
        while let d = engine.nextDeadline, d <= t {
            if let failure = perform(.advance, at: d, code: nil) { return failure }
        }
        return nil
    }

    private func isOrdinary(_ code: UInt16) -> Bool {
        !KeyCommitPipeline.modifierCodes.contains(code) || typing.tapOnlyCodes.contains(code)
    }

    /// The engine certainly rejects this key sample (size beyond every limit, or invalid). Space
    /// is tolerated up to thumbRadius when it landed broad, or (while pending) in the rest modes.
    private func makesDead(_ s: TouchSample, code: UInt16?) -> Bool {
        guard let code else { return false }
        if !s.isValid { return true }
        guard protection.enabled else { return false }
        let tolerant = code == 49 && (broadSpaceIDs.contains(s.id) || typing.resting != .off)
        return s.minimumRadius > (tolerant ? protection.sensitivity.thumbRadius : protection.sensitivity.fingerRadius)
    }

    private mutating func perform(_ call: Call, at t: Double, code: UInt16?) -> String? {
        var newID: Int?
        let out: [PadInput]
        switch call {
        case .begin(let s):
            if let code {
                let broadOK = code == 49 && s.minimumRadius <= protection.sensitivity.thumbRadius
                let rejected = suppressed || !s.isValid ||
                    (protection.enabled && s.minimumRadius > protection.sensitivity.fingerRadius && !broadOK)
                keyTouches.append(KeyTouch(id: s.id, code: code, land: t, dead: rejected))
                if code == 49, protection.enabled, s.minimumRadius > protection.sensitivity.fingerRadius {
                    broadSpaceIDs.insert(s.id)
                } else {
                    broadSpaceIDs.remove(s.id)
                }
                newID = s.id
            }
            out = engine.begin([s], at: t)
        case .move(let s):
            if makesDead(s, code: code) { markDead(s.id) }
            out = engine.move([s], at: t)
        case .end(let s, let cancelled):
            if cancelled || makesDead(s, code: code) { markDead(s.id) }
            out = engine.end([s], at: t, cancelled: cancelled)
        case .advance:
            out = engine.advance(to: t)
        case .reset:
            out = engine.reset()
        case .suppress(let on):
            suppressed = on
            out = engine.setInputSuppressed(on)
        }
        switch call {
        case .reset, .suppress: break
        default: now = max(now, t)
        }
        let signals = engine.drainSignals()
        if !signals.isEmpty {
            visual.apply(signals.compactMap { if case .feedback(let f) = $0 { return f } else { return nil } }, at: t)
        }
        if logging { log.append(String(format: "%.4f ", t) + "\(call) -> \(out) signals \(signals)") }
        return check(out, signals: signals, call: call, newID: newID)
    }

    private mutating func markDead(_ id: Int) {
        for i in keyTouches.indices where keyTouches[i].id == id { keyTouches[i].dead = true }
    }

    /// I6 under the lazy-modifier policy (rest modes): a modifier is posted only for what it
    /// applies to. After a run of modifier downs comes an ordinary key down (a chord), the up of a
    /// modifier in the run (a lone tap), or a pointer output that takes modifiers: a button press,
    /// a scroll's `.began`, a gesture, or drag motion. Never before plain motion.
    private func lazyModifierViolation(_ out: [PadInput]) -> String? {
        guard typing.resting != .off else { return nil }
        var buttons = heldButtons
        var i = 0
        while i < out.count {
            if case .button(let b, let down, _) = out[i] {
                if down { buttons.insert(b) } else { buttons.remove(b) }
            }
            guard case .key(let code, true) = out[i], !isOrdinary(code) else { i += 1; continue }
            var run: Set<UInt16> = []
            var j = i
            while j < out.count, case .key(let c, true) = out[j], !isOrdinary(c) { run.insert(c); j += 1 }
            let laterPress = out[j...].contains { if case .button(_, true, _) = $0 { return true } else { return false } }
            let ok: Bool
            switch j < out.count ? out[j] : nil {
            case .key(let c, let down)?: ok = down ? isOrdinary(c) : run.contains(c)
            case .button(_, let down, _)?: ok = down
            case .scroll(let m)?: ok = m.phase == .began
            case .gesture?: ok = true
            case .motion?: ok = !buttons.isEmpty || laterPress
            default: ok = false
            }
            if !ok { return "I6: modifiers \(run.sorted()) posted before \(j < out.count ? "\(out[j])" : "nothing") in \(out)" }
            i = j
        }
        return nil
    }

    private mutating func check(_ out: [PadInput], signals: [EngineSignal], call: Call, newID: Int?) -> String? {
        if let failure = lazyModifierViolation(out) { return failure }
        for o in out {
            switch o {
            case .key(let code, let down):
                if !down {
                    if heldKeys.remove(code) == nil { return "key up without down: \(code)" }
                    continue
                }
                if !heldKeys.insert(code).inserted { return "double key down: \(code)" }
                guard isOrdinary(code) else { coverage.modifierDowns += 1; continue }
                coverage.ordinaryDowns += 1
                let candidates = keyTouches.indices.filter {
                    keyTouches[$0].code == code && keyTouches[$0].land <= now + 1e-9 && !keyTouches[$0].matched
                }
                guard let i = candidates.max(by: { keyTouches[$0].land < keyTouches[$1].land }) else {
                    return "ordinary down \(code) matches no touch"
                }
                let k = keyTouches[i]
                if k.dead { return "I5: rejected, cancelled or forgotten touch \(k.id) posted \(code)" }
                if !(k.land > lastOrdinaryLand) { return "I1: \(code) (landed \(k.land)) after a key landed \(lastOrdinaryLand)" }
                lastOrdinaryLand = k.land
                keyTouches[i].matched = true
            case .button(let button, let down, _):
                if down {
                    if case .begin = call { return "button down in a touch-down call" }
                    if !heldButtons.insert(button).inserted { return "double button down" }
                    coverage.buttonDowns += 1
                } else if heldButtons.remove(button) == nil {
                    return "button up without down"
                }
            case .releaseAll:
                coverage.releaseAlls += 1
                heldKeys.removeAll()
                heldButtons.removeAll()
                for i in keyTouches.indices where keyTouches[i].id != newID { keyTouches[i].dead = true }
            case .scroll(let m):
                if m.phase == .began { coverage.scrolls += 1 }
            case .motion, .contacts, .gesture:
                break
            }
            if validateWire {
                do { _ = try WireV2.encode(.input(o, t: 0)) } catch { return "wire rejects \(o)" }
            }
        }
        if signals.contains(.openPanel) {
            coverage.panels += 1
            if !out.contains(.releaseAll) { return "openPanel without releaseAll" }
        }
        if engine.heldKeyCodes != heldKeys { return "heldKeyCodes \(engine.heldKeyCodes) != posted \(heldKeys)" }
        if engine.heldButtons != heldButtons { return "heldButtons \(engine.heldButtons) != posted \(heldButtons)" }
        if engine.isInputSuppressed != suppressed { return "suppression state" }
        if let d = engine.nextDeadline {
            guard d > now else { return "nextDeadline \(d) not after now \(now)" }
            var probe = engine
            let early = probe.advance(to: now + (d - now) / 2)
            if !early.isEmpty || !probe.drainSignals().isEmpty { return "advance before nextDeadline \(d) changed state: \(early)" }
        }
        return nil
    }
}
