import Foundation
import XCTest
@testable import IKeyCore

/// Drives a pipeline like the engine does: every deadline before an input is advanced
/// to first, and each key output is logged as "+code@time" / "-code@time".
fileprivate struct PipelineRun {
    var pipeline: KeyCommitPipeline
    private(set) var outputs: [PipelineOutput] = []
    private(set) var timed: [String] = []

    init(_ resting: RestingFingers = .off, confirm: TimeInterval = 0.045) {
        pipeline = KeyCommitPipeline(settings: TypingSettings(resting: resting), confirmationDelay: confirm)
    }

    var keys: [String] { timed.map { String($0.prefix { $0 != "@" }) } }
    var feedback: [KeyFeedback] {
        outputs.compactMap { if case .feedback(let f) = $0 { return f } else { return nil } }
    }

    private mutating func record(_ time: TimeInterval, _ out: [PipelineOutput]) {
        outputs += out
        for case .key(let code, let down) in out {
            timed.append("\(down ? "+" : "-")\(code)@\(String(format: "%.3f", time))")
        }
    }

    private mutating func until(_ time: TimeInterval) {
        while let d = pipeline.nextDeadline, d < time { record(d, pipeline.advance(to: d)) }
    }

    mutating func land(_ id: Int, _ code: UInt16, _ t: TimeInterval, broad: Bool = false) {
        until(t); record(t, pipeline.land(id: id, code: code, at: t, broadThumb: broad))
    }
    mutating func lift(_ id: Int, _ t: TimeInterval, cancelled: Bool = false) {
        until(t); record(t, pipeline.lift(id: id, at: t, cancelled: cancelled))
    }
    mutating func move(_ id: Int, _ mm: Double, _ t: TimeInterval) {
        until(t); record(t, pipeline.move(id: id, travelMM: mm, at: t))
    }
    mutating func reject(_ id: Int, _ t: TimeInterval) {
        until(t); record(t, pipeline.reject(id: id, at: t))
    }
    mutating func flush(_ t: TimeInterval) {
        until(t); record(t, pipeline.flushModifiersForPointer(at: t))
    }
    mutating func advance(_ t: TimeInterval) {
        until(t); record(t, pipeline.advance(to: t))
    }
}

/// Deterministic generator for the property test.
fileprivate struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

final class KeyPipelineTests: XCTestCase {
    private let a: UInt16 = 0, t: UInt16 = 17, shift: UInt16 = 56, cmd: UInt16 = 55, caps: UInt16 = 57

    func testImmediateTapCommitsAtConfirm() {
        var r = PipelineRun()
        r.land(1, a, 0)
        XCTAssertEqual(r.pipeline.nextDeadline ?? 0, 0.045, accuracy: 1e-9)
        r.advance(0.044)
        XCTAssertEqual(r.timed, [])
        XCTAssertEqual(r.pipeline.phase(of: 1), .pending)
        r.advance(0.045)
        XCTAssertEqual(r.timed, ["+0@0.045"])
        XCTAssertEqual(r.pipeline.phase(of: 1), .down)
        r.lift(1, 0.2)
        XCTAssertEqual(r.timed, ["+0@0.045", "-0@0.200"])
        XCTAssertNil(r.pipeline.phase(of: 1))
        XCTAssertEqual(r.feedback, [.tentative(a), .committed(a), .released(a)])
    }

    func testQuickTapCommitsAtLift() {
        var r = PipelineRun()
        r.land(1, a, 0)
        r.lift(1, 0.03)
        XCTAssertEqual(r.timed, ["+0@0.030", "-0@0.030"])
        XCTAssertNil(r.pipeline.nextDeadline)
    }

    func testZeroConfirmationCommitsAtLanding() {
        var r = PipelineRun(confirm: 0)
        r.land(1, shift, 0)
        r.land(2, a, 0.01)
        XCTAssertEqual(r.timed, ["+56@0.000", "+0@0.010"])
    }

    func testOrderedRolloverAThenT() {
        var r = PipelineRun()
        r.land(1, a, 0)
        r.land(2, t, 0.06)
        r.lift(1, 0.1)
        r.lift(2, 0.14)
        XCTAssertEqual(r.timed, ["+0@0.045", "-0@0.100", "+17@0.105", "-17@0.140"])
    }

    func testShiftChordCapitalizes() {
        var r = PipelineRun()
        r.land(1, shift, 0)
        r.land(2, a, 0.05)
        r.lift(1, 0.12)
        r.lift(2, 0.15)
        XCTAssertEqual(r.timed, ["+56@0.045", "+0@0.095", "-56@0.120", "-0@0.150"])
    }

    func testLetterBeforeShiftStaysLowercase() {
        var r = PipelineRun()
        r.land(1, a, 0)
        r.land(2, shift, 0.04)
        r.lift(1, 0.1)
        r.lift(2, 0.2)
        XCTAssertEqual(r.timed, ["+0@0.045", "+56@0.085", "-0@0.100", "-56@0.200"])
    }

    func testShiftLanding20msAfterLetterCapitalizes() {
        var r = PipelineRun()
        r.land(1, a, 0)
        r.land(2, shift, 0.02)
        r.lift(1, 0.1)
        r.lift(2, 0.2)
        XCTAssertEqual(r.timed, ["+56@0.045", "+0@0.045", "-0@0.100", "-56@0.200"])
    }

    func testShiftLiftedBeforeLetterLiftStillCapitalizes() {
        var r = PipelineRun()
        r.land(1, shift, 0)
        r.land(2, a, 0.04)
        r.lift(1, 0.06)
        XCTAssertEqual(r.timed, ["+56@0.045"], "Shift up waits for the letter from its interval")
        r.lift(2, 0.08)
        XCTAssertEqual(r.timed, ["+56@0.045", "+0@0.080", "-0@0.080", "-56@0.080"])
    }

    func testQuickShiftTapBeforeLetterConfirmStillCapitalizes() {
        var r = PipelineRun()
        r.land(1, shift, 0)
        r.land(2, a, 0.02)
        r.lift(1, 0.03)
        XCTAssertEqual(r.timed, [], "A Shift with a partner key is not a lone tap")
        r.lift(2, 0.07)
        XCTAssertEqual(r.timed, ["+56@0.065", "+0@0.065", "-56@0.065", "-0@0.070"])
    }

    func testLoneShiftTapPostsDownUpAtLift() {
        var r = PipelineRun()
        r.land(1, shift, 0)
        r.lift(1, 0.03)
        XCTAssertEqual(r.timed, ["+56@0.030", "-56@0.030"])

        var rest = PipelineRun(.homeRow)
        rest.land(1, shift, 0)
        rest.lift(1, 0.2)
        XCTAssertEqual(rest.timed, ["+56@0.200", "-56@0.200"])

        var slow = PipelineRun(.homeRow)
        slow.land(1, shift, 0)
        slow.lift(1, 0.28)
        XCTAssertEqual(slow.timed, ["+56@0.280", "-56@0.280"],
                       "The lone-tap limit is at least modifierReveal (no silent gap)")

        var long = PipelineRun(.homeRow)
        long.land(1, shift, 0)
        long.advance(0.31)
        XCTAssertEqual(long.timed, [], "Never posted from time alone in rest modes")
        long.lift(1, 0.31)
        XCTAssertEqual(long.timed, [], "A longer lone touch is a resting pinky or thumb")
        XCTAssertEqual(long.feedback.last, .released(shift))
    }

    func testCmdShiftTChord() {
        var r = PipelineRun()
        r.land(1, cmd, 0)
        r.land(2, shift, 0.04)
        r.land(3, t, 0.09)
        r.lift(3, 0.2)
        r.lift(2, 0.3)
        r.lift(1, 0.4)
        XCTAssertEqual(r.timed, ["+55@0.045", "+56@0.085", "+17@0.135", "-17@0.200", "-56@0.300", "-55@0.400"])
    }

    func testFlushForPointerPostsHeldModifier() {
        var r = PipelineRun(.homeRow)
        r.land(1, cmd, 0)
        r.flush(0.1)
        XCTAssertEqual(r.timed, ["+55@0.100"])
        r.advance(0.5)
        XCTAssertEqual(r.timed, ["+55@0.100"], "Already posted; the reveal does nothing")
        r.lift(1, 0.6)
        XCTAssertEqual(r.timed, ["+55@0.100", "-55@0.600"])
    }

    func testTwoFingersSameKey() {
        var r = PipelineRun()
        r.land(1, a, 0)
        r.land(2, a, 0.1)
        r.advance(0.2)
        XCTAssertEqual(r.timed, ["+0@0.045"])
        XCTAssertEqual(r.pipeline.phase(of: 2), .down)
        r.lift(1, 0.3)
        XCTAssertEqual(r.timed, ["+0@0.045"])
        XCTAssertEqual(r.pipeline.postedCodes, [a])
        r.lift(2, 0.4)
        XCTAssertEqual(r.timed, ["+0@0.045", "-0@0.400"])
        XCTAssertEqual(r.pipeline.postedCodes, [])
    }

    func testRejectReleasesDownKey() {
        var r = PipelineRun()
        r.land(1, a, 0)
        r.advance(0.05)
        r.reject(1, 0.1)
        XCTAssertEqual(r.timed, ["+0@0.045", "-0@0.100"])
        XCTAssertEqual(r.pipeline.phase(of: 1), .rejected)
        XCTAssertEqual(r.feedback.last, .rejected(a))
        r.lift(1, 0.2)
        XCTAssertEqual(r.timed.count, 2)
        XCTAssertNil(r.pipeline.phase(of: 1))
    }

    func testRejectedPendingKeyNeverTypes() {
        var r = PipelineRun()
        r.land(1, a, 0)
        r.reject(1, 0.02)
        r.advance(0.5)
        r.lift(1, 0.6)
        XCTAssertEqual(r.timed, [])
    }

    func testCancelledLiftDoesNotCommit() {
        var r = PipelineRun()
        r.land(1, a, 0)
        r.lift(1, 0.02, cancelled: true)
        XCTAssertEqual(r.timed, [])
        XCTAssertEqual(r.feedback, [.tentative(a), .rejected(a)])
    }

    func testCancelledHeldModifierReleasesAtOnce() {
        var r = PipelineRun()
        r.land(1, shift, 0)
        r.land(2, a, 0.01)
        r.advance(0.05)
        r.lift(1, 0.06, cancelled: true)
        XCTAssertEqual(r.timed, ["+56@0.045", "+0@0.055", "-56@0.060"])
    }

    func testPostedModifierReleasedByReconcileDoesNotTapAgain() {
        var r = PipelineRun()
        r.land(1, a, 0)
        r.land(2, 63, 0.035)                     // fn, too late to apply to a
        r.flush(0.04)
        r.lift(1, 0.08)
        r.lift(2, 0.10)
        XCTAssertEqual(r.timed, ["+63@0.040", "-63@0.045", "+0@0.045", "-0@0.080"])
        XCTAssertNil(r.pipeline.phase(of: 2))
        XCTAssertEqual(r.pipeline.postedCodes, [])
    }

    func testCapsLockIsAnOrdinaryImmediateKey() {
        var r = PipelineRun(.homeRow)
        r.land(1, shift, 0)
        r.land(2, caps, 0.01)
        r.lift(2, 0.1)
        r.lift(1, 0.2)
        XCTAssertEqual(r.timed, ["+56@0.055", "+57@0.055", "-57@0.100", "-56@0.200"])
        XCTAssertFalse(KeyCommitPipeline.modifierCodes.contains(caps))
    }

    func testBroadThumbCommitsOnShortLiftOnly() {
        var r = PipelineRun()
        r.land(1, 49, 0, broad: true)
        r.lift(1, 0.3)
        XCTAssertEqual(r.timed, ["+49@0.300", "-49@0.300"])

        var held = PipelineRun()
        held.land(1, 49, 0, broad: true)
        held.advance(0.35)
        XCTAssertEqual(held.pipeline.phase(of: 1), .resting)
        held.lift(1, 0.5)
        XCTAssertEqual(held.timed, [])

        var slid = PipelineRun()
        slid.land(1, 49, 0, broad: true)
        slid.move(1, 3.6, 0.1)
        slid.lift(1, 0.15)
        XCTAssertEqual(slid.timed, [])
    }

    func testActivityAndHeldKeyState() {
        var r = PipelineRun()
        XCTAssertNil(r.pipeline.lastOrdinaryActivity)
        r.land(1, shift, 0)
        r.advance(0.1)
        XCTAssertFalse(r.pipeline.hasHeldOrdinaryKey)
        XCTAssertNil(r.pipeline.lastOrdinaryActivity)
        r.land(2, a, 0.2)
        r.advance(0.3)
        XCTAssertTrue(r.pipeline.hasHeldOrdinaryKey)
        XCTAssertEqual(r.pipeline.lastOrdinaryActivity ?? 0, 0.245, accuracy: 1e-9)
        XCTAssertEqual(r.pipeline.postedCodes, [shift, a])
        r.lift(2, 0.4)
        XCTAssertEqual(r.pipeline.lastOrdinaryActivity ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertFalse(r.pipeline.hasHeldOrdinaryKey)
    }

    func testResetClearsEverythingWithoutOutput() {
        var r = PipelineRun()
        r.land(1, shift, 0)
        r.land(2, a, 0.01)
        r.advance(0.1)
        r.pipeline.reset()
        XCTAssertEqual(r.pipeline.postedCodes, [])
        XCTAssertNil(r.pipeline.phase(of: 1))
        XCTAssertNil(r.pipeline.nextDeadline)
        XCTAssertNil(r.pipeline.lastOrdinaryActivity)
        XCTAssertEqual(r.pipeline.lift(id: 2, at: 0.2), [])
    }

    func testSettingsDecodeMissingFieldsAsDefaults() throws {
        let json = #"{"resting":"allTypingKeys","restThreshold":0.2,"burstMinContacts":4}"#
        let s = try JSONDecoder().decode(TypingSettings.self, from: Data(json.utf8))
        var expected = TypingSettings()
        expected.resting = .allTypingKeys
        expected.restThreshold = 0.2
        expected.burstMinContacts = 4
        XCTAssertEqual(s, expected)
        let empty = try JSONDecoder().decode(TypingSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, TypingSettings())
        let roundTrip = try JSONDecoder().decode(TypingSettings.self, from: JSONEncoder().encode(expected))
        XCTAssertEqual(roundTrip, expected)
        var extended = expected
        extended.revealHeldModifiers = true
        extended.tapOnlyCodes = [55]
        extended.tapMax = 0.28
        extended.isolatedHold = true
        let extendedTrip = try JSONDecoder().decode(TypingSettings.self, from: JSONEncoder().encode(extended))
        XCTAssertEqual(extendedTrip, extended)
    }

    func testSettingsDefaultsAndKeySets() {
        let s = TypingSettings()
        XCTAssertEqual(s.resting, .homeRow)
        XCTAssertEqual(s.restThreshold, 0.25)
        XCTAssertEqual(s.spaceRestThreshold, 0.30)
        XCTAssertFalse(s.isolatedHold, "isolated hold is opt-in (policy F1)")
        XCTAssertEqual(s.tapMax, 0.30)
        XCTAssertFalse(s.revealHeldModifiers)
        XCTAssertEqual(s.tapOnlyCodes, [])
        XCTAssertEqual(TypingSettings.homeRowCodes, [0, 1, 2, 3, 38, 40, 37, 41, 49])
        XCTAssertEqual(TypingSettings.typingKeyCodes.count, 36 + 11 + 2)
        for code: UInt16 in [36, 48, 51, 53, 57] { XCTAssertFalse(TypingSettings.typingKeyCodes.contains(code)) }
        XCTAssertTrue(s.isRestCapable(38))
        XCTAssertFalse(s.isRestCapable(14))
        XCTAssertTrue(TypingSettings(resting: .allTypingKeys).isRestCapable(14))
        XCTAssertFalse(TypingSettings(resting: .off).isRestCapable(0))
    }

    func testTapMaxIsClamped() {
        var p = KeyCommitPipeline(settings: TypingSettings(tapMax: 0.05))
        _ = p.land(id: 1, code: 38, at: 0)
        XCTAssertEqual(p.nextDeadline ?? 0, 0.15, accuracy: 1e-9)
        var q = KeyCommitPipeline(settings: TypingSettings(tapMax: 1.0))
        _ = q.land(id: 1, code: 38, at: 0)
        XCTAssertEqual(q.nextDeadline ?? 0, 0.35, accuracy: 1e-9)
        var legacy = KeyCommitPipeline(settings: TypingSettings(restThreshold: 0.15, spaceRestThreshold: 0.2))
        _ = legacy.land(id: 1, code: 38, at: 0)
        _ = legacy.land(id: 2, code: 49, at: 0)
        XCTAssertEqual(legacy.nextDeadline ?? 0, 0.30, accuracy: 1e-9, "legacy thresholds do not move tapMax")
    }

    func testCommitHeldModifiersPostsOnceAndReleasesAtLift() {
        var r = PipelineRun(.homeRow)
        r.land(1, shift, 0)
        XCTAssertEqual(r.pipeline.commitHeldModifiers(at: 0.5), [.key(code: shift, down: true),
                                                                 .feedback(.committed(shift))])
        XCTAssertEqual(r.pipeline.commitHeldModifiers(at: 0.6), [], "already posted")
        r.land(2, a, 0.7)
        r.lift(2, 0.75)
        r.lift(1, 1.0)
        XCTAssertEqual(r.timed, ["+0@0.750", "-0@0.750", "-56@1.000"])
        XCTAssertEqual(r.pipeline.postedCodes, [])
    }

    /// advance(to: d - 1 ms) never changes anything; advance(to: d) always does and consumes d.
    func testNextDeadlineProperty() {
        let codes: [UInt16] = [0, 1, 2, 3, 38, 40, 37, 41, 49, 14, 17, 31, 51, 57, 48, 36, 55, 56, 58, 59, 60]
        let modes: [RestingFingers] = [.off, .homeRow, .allTypingKeys]
        for seed in 0..<500 {
            var rng = SplitMix64(seed: UInt64(seed) &* 7919 &+ 1)
            let mode = modes[rng.below(3)]
            let confirm = rng.chance(0.2) ? 0 : 0.045
            let settings = TypingSettings(resting: mode, isolatedHold: rng.chance(0.3),
                                          tapOnlyCodes: rng.chance(0.3) ? [55] : [])
            var p = KeyCommitPipeline(settings: settings, confirmationDelay: confirm)
            var time = 0.0
            var nextID = 1
            var held: [Int] = []
            var ids: [Int] = []
            var down: Set<UInt16> = []
            var log: [String] = []
            var failed = false

            func phases() -> [KeyContactPhase?] { ids.map { p.phase(of: $0) } }
            func check(_ ok: Bool, _ what: String) {
                guard ok, !failed else {
                    if !failed { XCTFail("seed \(seed): \(what)\n" + log.joined(separator: "\n")) }
                    failed = true
                    return
                }
            }
            func absorb(_ out: [PipelineOutput]) {
                for case .key(let code, let isDown) in out {
                    log.append("  \(isDown ? "+" : "-")\(code)")
                    if isDown { check(down.insert(code).inserted, "double down \(code)") }
                    else { check(down.remove(code) != nil, "up without down \(code)") }
                }
            }
            func runDeadlines(through target: TimeInterval) {
                while !failed, let d = p.nextDeadline, d <= target {
                    check(d > time, "deadline \(d) not after \(time)")
                    if d - 0.001 > time {
                        let before = phases()
                        let early = p.advance(to: d - 0.001)
                        check(early.isEmpty && phases() == before, "early advance changed state at \(d)")
                        check(p.nextDeadline == d, "early advance moved the deadline \(d)")
                    }
                    let before = phases()
                    log.append("advance \(d)")
                    let out = p.advance(to: d)
                    absorb(out)
                    check(!out.isEmpty || phases() != before, "deadline \(d) produced no transition")
                    check(p.nextDeadline.map { $0 > d } ?? true, "deadline \(d) not consumed")
                    time = d
                }
            }

            for _ in 0..<40 where !failed {
                let step = rng.chance(0.1) ? rng.unit() * 3 : rng.unit() * 0.15
                let target = time + step
                runDeadlines(through: target)
                time = max(time, target)
                let roll = rng.below(100)
                if roll < 35 || held.isEmpty {
                    let code = codes[rng.below(codes.count)]
                    let broad = code == 49 && rng.chance(0.3)
                    log.append("\(time) land \(nextID) code \(code)\(broad ? " broad" : "")")
                    absorb(p.land(id: nextID, code: code, at: time, broadThumb: broad))
                    held.append(nextID); ids.append(nextID); nextID += 1
                } else if roll < 70 {
                    let id = held.remove(at: rng.below(held.count))
                    let cancelled = rng.chance(0.1)
                    log.append("\(time) lift \(id)\(cancelled ? " cancelled" : "")")
                    absorb(p.lift(id: id, at: time, cancelled: cancelled))
                } else if roll < 80 {
                    let id = held[rng.below(held.count)]
                    let mm = rng.unit() * 8
                    log.append("\(time) move \(id) \(mm)")
                    absorb(p.move(id: id, travelMM: mm, at: time))
                } else if roll < 84 {
                    let id = held[rng.below(held.count)]
                    log.append("\(time) reject \(id)")
                    absorb(p.reject(id: id, at: time))
                } else if roll < 90 {
                    log.append("\(time) flush")
                    absorb(p.flushModifiersForPointer(at: time))
                } else if roll < 95 {
                    log.append("\(time) pointer use")
                    p.notePointerUse(at: time)
                } else {
                    log.append("\(time) foreign")
                    p.noteForeignContact(at: time)
                }
                check(p.nextDeadline.map { $0 > time } ?? true, "deadline not in the future after input")
            }
            for id in held where !failed {
                let target = time + 0.05
                runDeadlines(through: target)
                time = target
                log.append("\(time) lift \(id)")
                absorb(p.lift(id: id, at: time))
            }
            runDeadlines(through: time + 10)
            check(down.isEmpty && p.postedCodes.isEmpty, "keys left down: \(down)")
            check(p.nextDeadline == nil, "deadline left after everything lifted")
            if failed { return }
        }
    }
}
