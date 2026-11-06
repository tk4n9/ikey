import Foundation
import XCTest
@testable import IKeyCore

/// Same driver as in KeyPipelineTests (kept file-private so test files stay independent).
fileprivate struct RestRun {
    var pipeline: KeyCommitPipeline
    private(set) var outputs: [PipelineOutput] = []
    private(set) var timed: [String] = []

    init(_ settings: TypingSettings = TypingSettings(resting: .homeRow)) {
        pipeline = KeyCommitPipeline(settings: settings)
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
    mutating func lift(_ id: Int, _ t: TimeInterval) {
        until(t); record(t, pipeline.lift(id: id, at: t))
    }
    mutating func move(_ id: Int, _ mm: Double, _ t: TimeInterval) {
        until(t); record(t, pipeline.move(id: id, travelMM: mm, at: t))
    }
    mutating func flush(_ t: TimeInterval) {
        until(t); record(t, pipeline.flushModifiersForPointer(at: t))
    }
    mutating func advance(_ t: TimeInterval) {
        until(t); record(t, pipeline.advance(to: t))
    }
    /// Four fingers landing on A S D F 10 ms apart (ids firstID...firstID + 3).
    mutating func restLeftHand(at start: TimeInterval = 0, firstID: Int = 101) {
        for (i, code) in [UInt16(0), 1, 2, 3].enumerated() { land(firstID + i, code, start + Double(i) * 0.01) }
    }
}

final class RestingFingersTests: XCTestCase {
    private let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, f: UInt16 = 3, j: UInt16 = 38, l: UInt16 = 37
    private let e: UInt16 = 14, t: UInt16 = 17, tab: UInt16 = 48, delete: UInt16 = 51, space: UInt16 = 49
    private let caps: UInt16 = 57, shift: UInt16 = 56, cmd: UInt16 = 55, option: UInt16 = 58
    private let h: UInt16 = 4, q: UInt16 = 12, o: UInt16 = 31
    /// The opt-in isolated hold (a lone home-row letter held past tapMax presses).
    private let isolated = TypingSettings(resting: .homeRow, isolatedHold: true)

    func testEightHomeRowPlusSpaceRest5sPostsNothing() {
        var r = RestRun()
        let codes: [UInt16] = [0, 1, 2, 3, 38, 40, 37, 41, 49]
        for (i, code) in codes.enumerated() { r.land(i + 1, code, Double(i) * 0.01) }
        r.advance(5)
        for id in 1...9 { XCTAssertEqual(r.pipeline.phase(of: id), .resting) }
        for id in 1...9 { r.lift(id, 5 + Double(id) * 0.01) }
        XCTAssertEqual(r.timed, [])
        XCTAssertEqual(r.feedback.filter { if case .restStarted = $0 { return true } else { return false } }.count, 9)
    }

    func testTapOnFAt90msPostsAtLift() {
        var r = RestRun()
        r.land(1, f, 0)
        r.advance(0.08)
        XCTAssertEqual(r.timed, [])
        r.lift(1, 0.09)
        XCTAssertEqual(r.timed, ["+3@0.090", "-3@0.090"])
    }

    func testRestOn300msPostsNothing() {
        var r = RestRun()
        r.land(1, j, 0)
        r.land(3, 40, 0.01)
        r.land(2, f, 0.5)
        r.advance(0.79)
        XCTAssertEqual(r.pipeline.phase(of: 2), .pending, "still a possible tap before tapMax")
        r.advance(0.80)
        XCTAssertEqual(r.pipeline.phase(of: 2), .resting)
        r.lift(2, 0.8)
        r.lift(1, 1.0)
        r.lift(3, 1.0)
        XCTAssertEqual(r.timed, [])
    }

    func testSlide6mmPostsNothing() {
        var r = RestRun()
        r.land(1, f, 0)
        r.move(1, 6, 0.05)
        XCTAssertEqual(r.pipeline.phase(of: 1), .resting)
        r.lift(1, 0.1)
        XCTAssertEqual(r.timed, [])
    }

    func testETapWithRestsResolvedHasNoWait() {
        var r = RestRun()
        r.restLeftHand()
        r.land(9, e, 1.0)
        r.lift(9, 1.03)
        XCTAssertEqual(r.timed, ["+14@1.030", "-14@1.030"])
        r.land(10, e, 2.0)
        r.lift(10, 2.2)
        XCTAssertEqual(r.timed, ["+14@1.030", "-14@1.030", "+14@2.045", "-14@2.200"])
    }

    func testPendingRestCapableKeyHoldsLaterKeysInOrder() {
        var r = RestRun()
        r.land(1, f, 0)
        r.land(2, e, 0.05)
        r.advance(0.12)
        XCTAssertEqual(r.timed, [], "E waits behind the earlier F")
        r.lift(1, 0.12)
        XCTAssertEqual(r.timed, ["+3@0.120", "-3@0.120", "+14@0.120"])
        r.lift(2, 0.2)
        XCTAssertEqual(r.keys.last, "-14")
    }

    func testPlacementBurstConvertsCmd() {
        var r = RestRun()
        r.land(1, a, 0)
        r.land(2, cmd, 0.03)
        r.land(3, s, 0.06)
        r.land(4, d, 0.09)
        r.advance(0.9)
        XCTAssertEqual(r.timed, [])
        XCTAssertEqual(r.pipeline.phase(of: 2), .resting)
        r.land(5, e, 1.0)
        r.lift(5, 1.05)
        XCTAssertEqual(r.timed, ["+14@1.045", "-14@1.050"])
        for id in 1...4 { r.lift(id, 2.0) }
        XCTAssertEqual(r.timed.count, 2)
    }

    func testSuspectModifierIsNotFlushedForPointer() {
        var r = RestRun()
        r.land(1, a, 0)
        r.land(2, cmd, 0.03)
        r.land(3, s, 0.06)
        r.land(4, d, 0.09)
        r.flush(0.1)
        XCTAssertEqual(r.timed, [])
    }

    func testShiftLaFastCapital() {
        var r = RestRun()
        r.land(1, shift, 0)
        r.land(2, l, 0.06)
        r.land(3, a, 0.12)
        r.lift(2, 0.14)
        r.lift(1, 0.16)
        r.lift(3, 0.20)
        XCTAssertEqual(r.timed, ["+56@0.140", "+37@0.140", "-37@0.140",
                                 "+0@0.200", "-0@0.200", "-56@0.200"])
    }

    func testShiftAsFastCapital() {
        var r = RestRun()
        r.land(1, shift, 0)
        r.land(2, a, 0.05)
        r.land(3, s, 0.10)
        r.lift(2, 0.13)
        r.lift(1, 0.15)
        r.lift(3, 0.18)
        XCTAssertEqual(r.timed, ["+56@0.130", "+0@0.130", "-0@0.130",
                                 "+1@0.180", "-1@0.180", "-56@0.180"])
    }

    func testShiftSurvivesBurstShapedRollover() {
        var r = RestRun()
        r.land(1, shift, 0)
        r.land(2, j, 0.03)
        r.land(3, a, 0.06)
        r.land(4, d, 0.09)
        r.lift(1, 0.16)
        r.lift(2, 0.18)
        r.lift(3, 0.20)
        r.lift(4, 0.22)
        XCTAssertEqual(r.timed, ["+56@0.180", "+38@0.180", "-38@0.180", "+0@0.200", "-0@0.200",
                                 "+2@0.220", "-2@0.220", "-56@0.220"])
    }

    func testCmdShiftTNotABurst() {
        var r = RestRun()
        r.land(1, cmd, 0)
        r.land(2, shift, 0.04)
        r.land(3, t, 0.09)
        r.lift(3, 0.2)
        r.lift(2, 0.3)
        r.lift(1, 0.4)
        XCTAssertEqual(r.timed, ["+55@0.135", "+56@0.135", "+17@0.135", "-17@0.200", "-56@0.300", "-55@0.400"])
    }

    func testDeleteHeldStillImmediate() {
        var r = RestRun()
        r.land(1, delete, 0)
        r.lift(1, 1.0)
        XCTAssertEqual(r.timed, ["+51@0.045", "-51@1.000"])
    }

    func testIsolatedHoldJPostsDownAtThreshold() {
        var r = RestRun(isolated)
        r.land(1, j, 0)
        XCTAssertEqual(r.pipeline.nextDeadline ?? 0, 0.30, accuracy: 1e-9)
        r.lift(1, 1.0)
        XCTAssertEqual(r.timed, ["+38@0.300", "-38@1.000"])
        XCTAssertEqual(r.feedback, [.tentative(j), .committed(j), .released(j)])
    }

    func testIsolatedHoldIsOffByDefault() {
        var r = RestRun()
        r.land(1, j, 0)
        r.lift(1, 1.0)
        XCTAssertEqual(r.timed, [])
    }

    func testHoldJWithOtherRestsRests() {
        var r = RestRun()
        r.restLeftHand()
        r.land(2, j, 0.5)
        r.lift(2, 1.5)
        for id in 101...104 { r.lift(id, 2.0) }
        XCTAssertEqual(r.timed, [])
    }

    func testHoldJAfterAnotherFingerTouchedAndLeftRests() {
        var r = RestRun()
        r.land(1, j, 0)
        r.land(2, f, 0.05)
        r.lift(2, 0.1)
        r.lift(1, 1.0)
        XCTAssertEqual(r.timed, ["+3@0.300", "-3@0.300"],
                       "F waits behind J (I1) until J rests; J was not isolated for its whole life")
    }

    func testIsolatedHoldCancelledByForeignContact() {
        var r = RestRun(isolated)
        r.land(1, j, 0)
        r.advance(0.1)
        r.pipeline.noteForeignContact(at: 0.1)
        r.advance(0.3)
        XCTAssertEqual(r.pipeline.phase(of: 1), .resting)
        r.lift(1, 1.0)
        XCTAssertEqual(r.timed, [])
    }

    func testForeignContactAfterHoldDeadlineDoesNotCancelIt() {
        var r = RestRun(isolated)
        r.land(1, j, 0)
        r.pipeline.noteForeignContact(at: 0.32)  // delivered before the deadline was advanced
        r.advance(0.32)
        XCTAssertEqual(r.pipeline.phase(of: 1), .down)
        r.lift(1, 1.0)
        XCTAssertEqual(r.timed, ["+38@0.300", "-38@1.000"])
    }

    func testForeignContactAlreadyDownIsResignalledAfterLanding() {
        var r = RestRun(isolated)
        r.pipeline.noteForeignContact(at: 0)     // a palm or trackpad finger that stays down
        r.land(1, j, 0.1)
        r.pipeline.noteForeignContact(at: 0.1)   // the engine re-signals it after every land
        r.advance(0.45)
        XCTAssertEqual(r.pipeline.phase(of: 1), .resting)
        r.lift(1, 2.0)
        XCTAssertEqual(r.timed, [])
    }

    func testSlowCmdSIsARest() {
        // Policy F1 over F3a: S held past tapMax is a rest, so neither S nor Cmd posts anything.
        var r = RestRun()
        r.land(1, cmd, 0)
        r.land(2, s, 0.6)
        r.lift(2, 0.9)
        r.lift(1, 1.2)
        XCTAssertEqual(r.timed, [], "a rest-capable key held past tapMax never types, even under Cmd")
    }

    func testThumbsSettlingOnCmdThenSpaceRestBoth() {
        // Space never presses by isolation and its rest settles the unused Cmd: thumbs resting on
        // Cmd and Space must not open Spotlight, and a later Space tap is plain.
        var r = RestRun()
        r.land(1, cmd, 0)
        r.land(2, space, 0.1)
        r.advance(0.45)
        XCTAssertEqual(r.pipeline.phase(of: 2), .resting)
        XCTAssertEqual(r.pipeline.phase(of: 1), .resting)
        r.lift(2, 0.45)
        r.land(3, space, 0.5)
        r.lift(3, 0.6)
        r.lift(1, 0.7)
        XCTAssertEqual(r.timed, ["+49@0.600", "-49@0.600"])
    }

    func testQuickCmdSpaceTypes() {
        var r = RestRun()
        r.land(1, cmd, 0)
        r.land(2, space, 0.1)
        r.lift(2, 0.2)
        r.lift(1, 0.3)
        XCTAssertEqual(r.timed, ["+55@0.200", "+49@0.200", "-49@0.200", "-55@0.300"])
    }

    func testThumbsRestingOnCmdAndSpaceDoNotType() {
        var r = RestRun()
        r.land(1, cmd, 0)
        r.land(2, space, 0.5)
        r.advance(3.0)
        XCTAssertEqual(r.pipeline.phase(of: 2), .resting)
        r.lift(2, 3.0)
        r.lift(1, 3.0)
        XCTAssertEqual(r.timed, [], "a resting thumb on Cmd posts nothing; Space never presses")
    }

    func testPinkyShiftAndThumbSpaceDoNotRepeatSpaces() {
        // Verifier P12.
        var r = RestRun()
        r.land(1, shift, 0)
        r.land(2, space, 0.5)
        r.advance(3.0)
        r.lift(2, 3.0)
        r.lift(1, 3.0)
        XCTAssertEqual(r.timed, [])
    }

    func testSlowCmdSWithIsolatedHoldOnStillRests() {
        // Isolated hold needs the key alone on the deck; a held Cmd is another contact.
        var r = RestRun(isolated)
        r.land(1, cmd, 0)
        r.land(2, s, 0.6)
        r.lift(2, 0.9)
        r.lift(1, 1.2)
        XCTAssertEqual(r.timed, [])
    }

    func testKeyRestsOnceModifierLifted() {
        var r = RestRun()
        r.land(1, cmd, 0)
        r.land(2, s, 0.6)
        r.lift(1, 0.7)
        r.lift(2, 1.2)
        XCTAssertEqual(r.pipeline.phase(of: 2), nil)
        XCTAssertEqual(r.timed, [], "Cmd waits for S to resolve (I4); S rests, so nothing is typed")
    }

    func testQuickTapBehindBurstDoesNotPostSuspectCmd() {
        // E waits behind the resting partners (I1); D's rest decides Cmd before E commits.
        var r = RestRun()
        r.land(1, a, 0)
        r.land(2, s, 0.03)
        r.land(3, d, 0.06)
        r.land(4, cmd, 0.09)
        r.land(5, e, 0.15)
        r.lift(5, 0.20)
        r.land(6, 4, 3.0)
        r.lift(6, 3.08)
        XCTAssertEqual(r.pipeline.phase(of: 4), .resting)
        r.advance(6.0)
        XCTAssertEqual(r.pipeline.phase(of: 4), .resting)
        XCTAssertEqual(r.timed, ["+14@0.360", "-14@0.360", "+4@3.045", "-4@3.080"])
        XCTAssertFalse(r.pipeline.postedCodes.contains(cmd))
    }

    func testQuickTapBehindBurstWithCmdNotLastDoesNotPostCmd() {
        var r = RestRun()
        r.land(1, a, 0)
        r.land(2, cmd, 0.03)
        r.land(3, s, 0.06)
        r.land(4, d, 0.09)
        r.land(5, e, 0.15)
        r.lift(5, 0.20)
        r.advance(1.0)
        XCTAssertEqual(r.pipeline.phase(of: 2), .resting)
        XCTAssertEqual(r.timed, ["+14@0.390", "-14@0.390"])
    }

    func testSlowShiftAIsARest() {
        // Policy F1: A held 0.30 s (tapMax) rests, so a slow Shift+A types nothing.
        var r = RestRun()
        r.land(1, shift, 0)
        r.land(2, a, 0.4)
        r.lift(2, 0.7)
        r.lift(1, 0.9)
        XCTAssertEqual(r.timed, [])
    }

    func testModifierLandingAfterKeyBreaksIsolation() {
        var r = RestRun()
        r.land(1, j, 0)
        r.land(2, cmd, 0.1)
        r.advance(0.5)
        XCTAssertEqual(r.pipeline.phase(of: 1), .resting)
        // Cmd landed 100 ms after J (the only key then settling): J resting is not Cmd settling,
        // so Cmd stays held, unposted, and could still chord (tc-hunt-2 finding G).
        XCTAssertEqual(r.pipeline.phase(of: 2), .pending, "Cmd pressed after J anchored stays live")
        r.lift(1, 0.8)
        r.lift(2, 1.0)
        XCTAssertEqual(r.timed, [])
    }

    func testSuspectCmdLandingLastRestsAfterBounceTap() {
        var r = RestRun()
        r.land(1, a, 0)
        r.land(2, s, 0.03)
        r.land(3, d, 0.06)
        r.land(4, cmd, 0.09)
        r.lift(1, 0.12)                          // first finger bounces: a real tap
        r.land(5, a, 0.20)
        r.advance(0.9)
        XCTAssertEqual(r.pipeline.phase(of: 4), .resting)
        r.land(6, 4, 1.0)
        r.lift(6, 1.08)
        r.land(7, e, 1.2)
        r.lift(7, 1.28)
        XCTAssertEqual(r.timed, ["+0@0.120", "-0@0.120", "+4@1.045", "-4@1.080", "+14@1.245", "-14@1.280"])
        XCTAssertFalse(r.pipeline.postedCodes.contains(cmd))
    }

    func testSuspectCmdRestsWhenEarlierPartnerTapped() {
        var r = RestRun()
        r.land(1, a, 0)
        r.land(2, cmd, 0.05)
        r.land(3, s, 0.06)
        r.land(4, d, 0.09)
        r.lift(1, 0.1)
        r.advance(1.0)
        XCTAssertEqual(r.pipeline.phase(of: 2), .resting)
        XCTAssertNil(r.pipeline.nextDeadline)
        r.flush(1.0)
        r.land(5, e, 1.5)
        r.lift(5, 1.55)
        XCTAssertEqual(r.timed, ["+0@0.100", "-0@0.100", "+14@1.545", "-14@1.550"])
    }

    func testBroadThumbInBurstUsesTapMax() {
        var r = RestRun()
        r.land(1, a, 0)
        r.land(2, s, 0.01)
        r.land(3, 45, 0.02, broad: true)
        r.land(4, d, 0.03)
        r.advance(0.31)
        XCTAssertEqual(r.pipeline.phase(of: 3), .pending, "burst conversion uses tapMax 0.30 s, not 0.35 s")
        r.advance(0.32)
        XCTAssertEqual(r.pipeline.phase(of: 3), .resting)
        r.lift(3, 0.34)
        XCTAssertEqual(r.timed, [])
    }

    func testInvalidCountSettingsFallBackToDefaults() {
        var r = RestRun(TypingSettings(resting: .homeRow, burstMinContacts: 0, burstMinRestCapable: 0,
                                       staleRestingContacts: 0))
        r.land(1, cmd, 0)
        r.land(2, e, 5.1)
        r.lift(2, 5.2)
        r.lift(1, 6.0)
        XCTAssertEqual(r.timed, ["+55@5.145", "+14@5.145", "-14@5.200", "-55@6.000"])
    }

    func testCmdHeld3sThenTabStaysDown() {
        var r = RestRun()
        r.land(1, cmd, 0)
        r.land(2, tab, 3.0)
        r.lift(2, 3.1)
        r.lift(1, 3.5)
        XCTAssertEqual(r.timed, ["+55@3.045", "+48@3.045", "-48@3.100", "-55@3.500"])
    }

    func testRevealSettingIsIgnoredInRestModes() {
        // Lazy modifiers: the legacy revealHeldModifiers flag never posts a held modifier.
        var r = RestRun(TypingSettings(resting: .homeRow, revealHeldModifiers: true))
        r.land(1, cmd, 0)
        r.advance(2.0)
        XCTAssertEqual(r.timed, [])
        r.land(2, tab, 3.0)
        r.lift(2, 3.1)
        r.lift(1, 3.5)
        XCTAssertEqual(r.timed, ["+55@3.045", "+48@3.045", "-48@3.100", "-55@3.500"])
    }

    func testOptionFlushedForPointerStaysDownWhileHandsRest() {
        var r = RestRun()
        r.restLeftHand()
        r.land(1, option, 1.0)
        r.flush(1.2)
        r.pipeline.notePointerUse(at: 1.2)
        r.advance(4.0)
        XCTAssertEqual(r.timed, ["+58@1.200"])
        XCTAssertEqual(r.pipeline.phase(of: 1), .down)
        r.lift(1, 4.5)
        XCTAssertEqual(r.timed, ["+58@1.200", "-58@4.500"])
    }

    func testOptionCommittedForPointerWithPointerUseStaysDown() {
        var r = RestRun()
        r.restLeftHand()
        r.land(1, option, 1.0)
        r.advance(1.3)
        XCTAssertEqual(r.timed, [], "never posted from time alone")
        XCTAssertEqual(r.pipeline.commitHeldModifiers(at: 1.3), [.key(code: option, down: true),
                                                                 .feedback(.committed(option))])
        r.pipeline.notePointerUse(at: 1.5)
        r.advance(4.0)
        XCTAssertEqual(r.pipeline.phase(of: 1), .down)
        r.lift(1, 4.5)
        XCTAssertEqual(r.timed, ["-58@4.500"])
        XCTAssertEqual(r.pipeline.postedCodes, [])
    }

    func testStaleNeedsEnoughRestingContacts() {
        var r = RestRun()
        r.land(101, a, 0)
        r.land(102, s, 0.01)
        r.land(1, cmd, 1.0)
        r.advance(4.0)
        XCTAssertEqual(r.pipeline.phase(of: 1), .pending, "two resting fingers do not make Cmd stale")
        r.land(2, e, 4.0)
        r.lift(2, 4.1)
        r.lift(1, 4.5)
        XCTAssertEqual(r.timed, ["+55@4.045", "+14@4.045", "-14@4.100", "-55@4.500"])
    }

    func testThumbOnCmdBeforeHandsSettleLaterRestsSilently() {
        var r = RestRun()
        r.land(1, cmd, 0)
        r.advance(2.5)
        r.restLeftHand(at: 2.5, firstID: 201)
        r.advance(3.5)
        XCTAssertEqual(r.pipeline.phase(of: 1), .resting, "a thumb held before the burst settles with it")
        r.land(2, e, 4.0)
        r.lift(2, 4.1)
        r.lift(1, 4.5)
        XCTAssertEqual(r.timed, ["+14@4.045", "-14@4.100"])
    }

    func testCapsInBurstRests() {
        var r = RestRun()
        r.land(1, a, 0)
        r.land(2, caps, 0.02)
        r.land(3, s, 0.04)
        r.land(4, d, 0.06)
        r.advance(1.0)
        XCTAssertEqual(r.pipeline.phase(of: 2), .resting)
        for id in 1...4 { r.lift(id, 1.1) }
        XCTAssertEqual(r.timed, [])
    }

    func testSpaceRestThreshold030() {
        var tap = RestRun()
        tap.land(1, space, 0)
        tap.advance(0.27)
        XCTAssertEqual(tap.pipeline.phase(of: 1), .pending)
        tap.lift(1, 0.28)
        XCTAssertEqual(tap.timed, ["+49@0.280", "-49@0.280"])

        var rest = RestRun()
        rest.restLeftHand()
        rest.land(2, space, 1.0)
        rest.advance(1.29)
        XCTAssertEqual(rest.pipeline.phase(of: 2), .pending)
        rest.advance(1.30)
        XCTAssertEqual(rest.pipeline.phase(of: 2), .resting)
        XCTAssertEqual(rest.timed, [])
    }

    func testAllTypingKeysMode() {
        var r = RestRun(TypingSettings(resting: .allTypingKeys))
        r.land(1, f, 0)
        r.land(7, j, 0.01)
        r.land(2, e, 1.0)
        r.lift(2, 1.5)
        XCTAssertEqual(r.timed, [], "E rests in allTypingKeys mode")
        r.land(3, e, 2.0)
        r.lift(3, 2.1)
        r.land(4, delete, 3.0)
        r.lift(4, 3.1)
        r.land(5, 36, 4.0)
        r.lift(5, 4.1)
        r.land(6, caps, 5.0)
        r.lift(6, 5.1)
        XCTAssertEqual(r.timed, ["+14@2.100", "-14@2.100", "+51@3.045", "-51@3.100",
                                 "+36@4.045", "-36@4.100", "+57@5.045", "-57@5.100"])
    }

    // MARK: - Verifier probes (resting thumbs and pinkies never post)

    /// Taps `code` at `t` for 50 ms.
    private func tap(_ r: inout RestRun, _ id: Int, _ code: UInt16, _ t: TimeInterval) {
        r.land(id, code, t)
        r.lift(id, t + 0.05)
    }

    func testP14BouncingPartnerAfterSuspectCmdTypesPlain() {
        for mod in [cmd, shift] {
            var r = RestRun()
            r.land(1, a, 0)
            r.land(2, s, 0.02)
            r.land(3, d, 0.04)
            r.land(4, mod, 0.06)
            r.land(5, f, 0.08)                   // last finger lands after the thumb and bounces
            r.lift(5, 0.13)
            r.land(6, f, 0.16)                   // and re-lands to rest
            r.land(7, h, 1.2)
            r.lift(7, 1.26)
            r.advance(3.0)
            XCTAssertEqual(r.pipeline.phase(of: 4), .resting)
            for id in [1, 2, 3, 4, 6] { r.lift(id, 3.0) }
            XCTAssertEqual(r.timed, ["+3@0.340", "-3@0.340", "+4@1.245", "-4@1.260"], "modifier \(mod)")
        }
    }

    func testP6NonHomeTapInBurstAfterCmdTypesPlain() {
        var r = RestRun()
        r.land(1, a, 0)
        r.land(2, s, 0.03)
        r.land(3, d, 0.06)
        r.land(4, cmd, 0.09)
        r.land(5, e, 0.11)
        r.lift(5, 0.16)
        r.land(6, h, 1.2)
        r.lift(6, 1.26)
        for id in 1...4 { r.lift(id, 2.0) }
        XCTAssertEqual(r.timed, ["+14@0.360", "-14@0.360", "+4@1.245", "-4@1.260"])
    }

    func testP6bCmdFirstThenBurstWithTapTypesPlain() {
        var r = RestRun()
        r.land(1, cmd, 0)
        r.land(2, a, 0.02)
        r.land(3, s, 0.04)
        r.land(4, d, 0.06)
        r.land(5, e, 0.10)
        r.lift(5, 0.15)
        r.land(6, h, 1.2)
        r.lift(6, 1.26)
        for id in 1...4 { r.lift(id, 2.0) }
        XCTAssertEqual(r.timed, ["+14@0.360", "-14@0.360", "+4@1.245", "-4@1.260"])
    }

    func testP3LoneCmdHeld5sPostsNothing() {
        var r = RestRun()
        r.land(1, cmd, 0)
        r.advance(5.0)
        XCTAssertEqual(r.pipeline.postedCodes, [])
        r.lift(1, 5.0)
        XCTAssertEqual(r.timed, [])
        XCTAssertEqual(r.feedback, [.tentative(cmd), .released(cmd)])
    }

    func testP1ThumbOnCmdBeforeHandRestsTypesPlain() {
        var r = RestRun()
        r.land(1, cmd, 0)
        r.restLeftHand(at: 0.2)
        r.advance(0.6)
        XCTAssertEqual(r.pipeline.phase(of: 1), .resting)
        tap(&r, 2, h, 0.8)
        tap(&r, 3, e, 1.0)
        XCTAssertEqual(r.timed, ["+4@0.845", "-4@0.850", "+14@1.045", "-14@1.050"])
    }

    func testP2ThumbOnCmdSettlingAfterBothHandsTypesPlain() {
        var r = RestRun()
        for (i, code) in [UInt16(0), 1, 2, 3, 38, 40, 37, 41].enumerated() { r.land(101 + i, code, 0) }
        r.land(1, cmd, 0.16)
        tap(&r, 2, q, 0.9)
        r.advance(3.0)
        XCTAssertEqual(r.timed, ["+12@0.945", "-12@0.950"])
    }

    func testP3bThumbsOnSpaceAndCmdWhileOtherHandTypes() {
        var r = RestRun()
        r.land(1, space, 0)
        r.land(2, cmd, 0.02)
        for (i, code) in [h, e, l, l, o].enumerated() { tap(&r, 10 + i, code, 0.6 + Double(i) * 0.15) }
        r.advance(3.0)
        r.lift(1, 3.0)
        r.lift(2, 3.0)
        XCTAssertEqual(r.keys, ["+4", "-4", "+14", "-14", "+37", "-37", "+37", "-37", "+31", "-31"])
    }

    func testP4SlowLoneCmdTapStillTaps() {
        for duration in [0.24, 0.26, 0.28, 0.29, 0.295] {
            var alone = RestRun()
            alone.land(1, cmd, 0)
            alone.lift(1, duration)
            XCTAssertEqual(alone.keys, ["+55", "-55"], "alone, \(duration) s")

            var resting = RestRun()
            resting.restLeftHand()
            resting.land(1, cmd, 1.0)
            resting.lift(1, 1.0 + duration)
            XCTAssertEqual(resting.keys, ["+55", "-55"], "hands resting, \(duration) s")
        }
        var long = RestRun()
        long.land(1, cmd, 0)
        long.lift(1, 0.35)
        XCTAssertEqual(long.timed, [], "a longer lone touch is a resting thumb")
    }

    func testP15LoneThumbOnSpaceNeverPresses() {
        var r = RestRun()
        r.land(1, space, 0)
        r.advance(3.0)
        XCTAssertEqual(r.pipeline.phase(of: 1), .resting)
        r.lift(1, 3.0)
        XCTAssertEqual(r.timed, [])
    }

    func testP16ThumbOnSpaceBeforeHandsNeverPresses() {
        var r = RestRun()
        r.land(1, space, 0)
        for (i, code) in [UInt16(0), 1, 2, 3, 38, 40, 37, 41].enumerated() { r.land(101 + i, code, 0.4) }
        r.advance(3.0)
        XCTAssertEqual(r.timed, [])
        XCTAssertEqual(r.pipeline.postedCodes, [])
    }

    func testP8ThumbOnSpaceThenTypingDoesNotLeadWithSpace() {
        var r = RestRun()
        r.land(1, space, 0)
        tap(&r, 2, h, 0.6)
        tap(&r, 3, e, 0.75)
        r.lift(1, 1.5)
        XCTAssertEqual(r.timed, ["+4@0.645", "-4@0.650", "+14@0.795", "-14@0.800"])
    }

    func testThumbOnCmdLongAfterHandsRestGoesStale() {
        var r = RestRun()
        r.restLeftHand()
        r.land(1, cmd, 1.0)
        r.advance(3.0)
        XCTAssertEqual(r.pipeline.phase(of: 1), .resting, "unused for 2 s among resting hands")
        tap(&r, 2, e, 3.5)
        r.lift(1, 4.0)
        XCTAssertEqual(r.timed, ["+14@3.545", "-14@3.550"])
    }

    func testDeliberateCmdEWhileHandsRestChords() {
        var r = RestRun()
        r.restLeftHand()
        r.land(1, cmd, 1.0)
        tap(&r, 2, e, 1.3)
        r.lift(1, 1.5)
        XCTAssertEqual(r.timed, ["+55@1.345", "+14@1.345", "-14@1.350", "-55@1.500"])
    }

    func testDeliberateCmdCFromRestingHandChords() {
        // Touch typist: hands rest, the thumb presses Cmd, the middle finger leaves D for C.
        var r = RestRun()
        r.restLeftHand()
        r.land(1, cmd, 1.0)
        r.lift(103, 1.1)
        r.land(2, 8, 1.15)
        r.lift(2, 1.22)
        r.land(3, d, 1.3)                        // the finger returns to D and rests
        r.lift(1, 1.4)
        r.advance(2.0)
        XCTAssertEqual(r.timed, ["+55@1.195", "+8@1.195", "-8@1.220", "-55@1.600"],
                       "Cmd up waits until D, landed while Cmd was held, rests (I4)")
    }

    func testFastCapitalRolloverInBurstStillShifts() {
        // A held Shift turns suspect in a burst-shaped rollover but every partner taps, so
        // nothing rests and Shift applies (resolution a).
        var r = RestRun()
        r.land(1, shift, 0)
        r.land(2, a, 0.4)
        r.land(3, s, 0.43)
        r.land(4, d, 0.46)
        r.lift(2, 0.5)
        r.lift(3, 0.52)
        r.lift(4, 0.55)
        r.lift(1, 0.7)
        XCTAssertEqual(r.keys, ["+56", "+0", "-0", "+1", "-1", "+2", "-2", "-56"])
    }

    // MARK: - Tap-only codes (left Command remapped to Caps Lock on the Mac)

    private let tapOnlyCmd = TypingSettings(resting: .homeRow, tapOnlyCodes: [55])

    func testTapOnlyCmdTapPostsDownUpAtLift() {
        var r = RestRun(tapOnlyCmd)
        r.land(1, cmd, 0)
        r.lift(1, 0.12)
        XCTAssertEqual(r.timed, ["+55@0.120", "-55@0.120"])
        var resting = RestRun(tapOnlyCmd)
        resting.restLeftHand()
        resting.land(1, cmd, 1.0)
        resting.lift(1, 1.28)
        XCTAssertEqual(resting.timed, ["+55@1.280", "-55@1.280"])
    }

    func testTapOnlyCmdRestingNeverChordsOrPosts() {
        var r = RestRun(tapOnlyCmd)
        r.land(1, cmd, 0)
        r.advance(1.0)
        XCTAssertEqual(r.pipeline.phase(of: 1), .resting)
        tap(&r, 2, h, 1.0)
        r.flush(1.2)
        tap(&r, 3, s, 1.4)
        r.lift(1, 3.0)
        XCTAssertEqual(r.timed, ["+4@1.045", "-4@1.050", "+1@1.450", "-1@1.450"])
    }

    func testTapOnlyCmdDoesNotChordWithQuickKey() {
        var r = RestRun(tapOnlyCmd)
        r.land(1, cmd, 0)
        r.land(2, h, 0.05)
        r.lift(2, 0.1)
        r.lift(1, 0.15)
        XCTAssertEqual(r.timed, ["+55@0.150", "-55@0.150", "+4@0.150", "-4@0.150"],
                       "a quick tap is a Caps Lock press of its own, in landing order")
    }

    func testTapOnlyCmdWithRestingOffIsAPlainKey() {
        var r = RestRun(TypingSettings(resting: .off, tapOnlyCodes: [55]))
        r.land(1, cmd, 0)
        r.land(2, h, 0.2)
        r.lift(2, 0.3)
        XCTAssertTrue(r.pipeline.hasHeldOrdinaryKey, "a tap-only code is an ordinary key")
        r.lift(1, 0.8)
        XCTAssertEqual(r.timed, ["+55@0.045", "+4@0.245", "-4@0.300", "-55@0.800"])
    }

    // MARK: - Settling contacts do not swallow a queued chord (verifier R1-R4, S1)

    private let c: UInt16 = 8, k: UInt16 = 40, rightCmd: UInt16 = 54, rightShift: UInt16 = 60

    func testR1FastCapitalAfterSettlingFingerStaysShifted() {
        var r = RestRun()
        r.restLeftHand()
        r.land(1, j, 1.0)                        // right index comes back to rest
        r.land(2, shift, 1.08)
        r.land(3, t, 1.12)
        r.lift(3, 1.20)
        r.lift(2, 1.3)
        r.advance(2.0)
        XCTAssertEqual(r.timed, ["+56@1.300", "+17@1.300", "-17@1.300", "-56@1.300"],
                       "T waits behind J (I1); J resting must not rest the Shift T was typed with")
    }

    func testR1bCmdCAfterSettlingFingerChords() {
        var r = RestRun()
        r.restLeftHand()
        r.land(1, j, 1.0)
        r.land(2, rightCmd, 1.05)
        r.land(3, c, 1.10)
        r.lift(3, 1.17)
        r.lift(2, 1.3)
        XCTAssertEqual(r.timed, ["+54@1.300", "+8@1.300", "-8@1.300", "-54@1.300"])
    }

    func testR3CmdCAfterThumbSettlesOnSpaceChords() {
        var r = RestRun()
        r.restLeftHand()
        r.land(1, space, 1.0)
        r.land(2, cmd, 1.1)
        r.land(3, c, 1.15)
        r.lift(3, 1.21)
        r.lift(2, 1.4)
        r.lift(1, 2.0)
        XCTAssertEqual(r.timed, ["+55@1.300", "+8@1.300", "-8@1.300", "-55@1.400"])

        var control = RestRun()                  // R3c: no settling contact
        control.restLeftHand()
        control.land(2, cmd, 1.1)
        control.land(3, c, 1.15)
        control.lift(3, 1.21)
        control.lift(2, 1.4)
        XCTAssertEqual(control.timed, ["+55@1.195", "+8@1.195", "-8@1.210", "-55@1.400"])
    }

    func testR2CapitalAfterThumbSettlesOnSpaceStaysShifted() {
        var r = RestRun()
        r.restLeftHand()
        r.land(1, space, 1.0)
        r.land(2, rightShift, 1.1)
        r.lift(104, 1.12)                        // the index leaves its resting F
        r.land(3, f, 1.15)
        r.lift(3, 1.32)
        r.lift(2, 1.4)
        r.lift(1, 2.0)
        XCTAssertEqual(r.timed, ["+60@1.320", "+3@1.320", "-3@1.320", "-60@1.400"])
    }

    func testR4CapitalAfterTwoSettlingFingersStaysShifted() {
        var r = RestRun()
        r.restLeftHand()
        r.land(1, k, 1.0)
        r.land(2, l, 1.02)
        r.land(3, rightShift, 1.10)
        r.land(4, j, 1.14)
        r.lift(4, 1.22)
        r.lift(3, 1.35)
        XCTAssertEqual(r.timed, ["+60@1.320", "+38@1.320", "-38@1.320", "-60@1.350"])
    }

    func testS1SlowShiftKThatRestedKeepsShiftForTheRetry() {
        var r = RestRun()
        r.restLeftHand()
        for (i, code) in [j, l, UInt16(41), k].enumerated() { r.land(105 + i, code, 0.04 + Double(i) * 0.01) }
        r.lift(108, 1.9)                         // the middle finger leaves K
        r.land(1, rightShift, 2.0)
        r.land(2, k, 2.05)                       // pressed too slowly among resting hands: rests
        r.lift(2, 2.40)
        XCTAssertEqual(r.pipeline.phase(of: 1), .pending, "Shift still waits for its chord")
        r.land(3, k, 2.5)
        r.lift(3, 2.55)
        r.lift(1, 2.7)
        XCTAssertEqual(r.timed, ["+60@2.550", "+40@2.550", "-40@2.550", "-60@2.700"])
    }

    func testSlowSpaceUnderHeldCmdStillRestsCmd() {
        // Space is excluded from the S1 rule: thumbs settle on Cmd and Space together.
        var r = RestRun()
        r.restLeftHand()
        r.land(1, cmd, 1.0)
        r.land(2, space, 1.01)
        r.advance(1.4)
        XCTAssertEqual(r.pipeline.phase(of: 1), .resting)
        tap(&r, 3, h, 1.5)
        XCTAssertEqual(r.timed, ["+4@1.545", "-4@1.550"])
    }

    // MARK: - Tap-only bounce during hand placement (verifier TB1, TB1b, TB3)

    func testTB1TapOnlyThumbBouncingInBurstPostsNothing() {
        var r = RestRun(tapOnlyCmd)
        r.restLeftHand()
        r.land(1, cmd, 0.05)
        r.lift(1, 0.11)
        r.land(2, cmd, 0.16)                     // re-lands and rests
        r.advance(1.0)
        XCTAssertEqual(r.timed, [])
        r.lift(2, 1.5)
        r.land(3, cmd, 2.0)                      // a later deliberate tap still types
        r.lift(3, 2.1)
        XCTAssertEqual(r.timed, ["+55@2.100", "-55@2.100"])
    }

    func testTB1bTapOnlyThumbHeldBeforeBurstBouncesSilently() {
        var r = RestRun(tapOnlyCmd)
        r.land(1, cmd, 0)
        r.restLeftHand(at: 0.03)
        r.lift(1, 0.12)
        r.land(2, cmd, 0.18)
        r.advance(1.0)
        r.lift(2, 1.0)
        XCTAssertEqual(r.timed, [])
    }

    func testTB3TapOnlyTapOverlappingHandPlacementIsDropped() {
        // Ambiguous on purpose: a tap-only press that overlaps a placement burst is treated as a
        // settling thumb, so a stray input-source switch is never posted.
        var r = RestRun(tapOnlyCmd)
        r.land(1, cmd, 0)
        r.restLeftHand(at: 0.05)
        r.lift(1, 0.15)
        r.advance(1.0)
        XCTAssertEqual(r.timed, [])
    }

    // MARK: - A chorded modifier stays down until its contact lifts (policy F3a, verifier PV4)

    func testPV4ChordedModifierStaysDownUntilItsLift() {
        for mod: UInt16 in [cmd, shift, option, 59, rightCmd] {
            var r = RestRun()
            r.restLeftHand()
            r.land(1, mod, 0.5)
            tap(&r, 2, h, 1.2)                   // chords: the accepted ambiguity
            tap(&r, 3, q, 4.2)                   // still chords: F3a has no stale release
            r.advance(6.0)
            XCTAssertEqual(r.pipeline.phase(of: 1), .down, "modifier \(mod)")
            r.lift(1, 6.0)
            XCTAssertEqual(r.timed, ["+\(mod)@1.245", "+4@1.245", "-4@1.250",
                                     "+12@4.245", "-12@4.250", "-\(mod)@6.000"], "modifier \(mod)")
        }
    }

    func testUsedModifierAmongRestingHandsStaysDown() {
        var r = RestRun()
        r.restLeftHand()
        r.land(1, cmd, 0.5)
        tap(&r, 2, h, 1.0)
        tap(&r, 3, q, 2.5)
        r.land(4, delete, 3.0)
        r.advance(6.0)
        XCTAssertEqual(r.pipeline.phase(of: 1), .down)
        r.lift(4, 6.0)
        r.advance(9.0)
        XCTAssertEqual(r.pipeline.phase(of: 1), .down)
        r.lift(1, 9.5)
        XCTAssertEqual(r.timed, ["+55@1.045", "+4@1.045", "-4@1.050", "+12@2.545", "-12@2.550",
                                 "+51@3.045", "-51@6.000", "-55@9.500"])
    }

    func testUsedModifierWithoutRestingHandsStaysDown() {
        var r = RestRun()
        r.land(1, cmd, 0)
        tap(&r, 2, 48, 0.2)                      // Cmd-Tab, then a long look at the switcher
        r.advance(5.0)
        r.lift(1, 5.0)
        XCTAssertEqual(r.timed, ["+55@0.245", "+48@0.245", "-48@0.250", "-55@5.000"])
    }
}
