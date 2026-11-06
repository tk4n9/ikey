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
        r.advance(0.75)
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
        var r = RestRun()
        r.land(1, j, 0)
        XCTAssertEqual(r.pipeline.nextDeadline ?? 0, 0.25, accuracy: 1e-9)
        r.lift(1, 1.0)
        XCTAssertEqual(r.timed, ["+38@0.250", "-38@1.000"])
        XCTAssertEqual(r.feedback, [.tentative(j), .committed(j), .released(j)])
    }

    func testIsolatedHoldCanBeTurnedOff() {
        var r = RestRun(TypingSettings(resting: .homeRow, isolatedHold: false))
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
        XCTAssertEqual(r.timed, ["+3@0.250", "-3@0.250"],
                       "F waits behind J (I1) until J rests; J was not isolated for its whole life")
    }

    func testIsolatedHoldCancelledByForeignContact() {
        var r = RestRun()
        r.land(1, j, 0)
        r.advance(0.1)
        r.pipeline.noteForeignContact(at: 0.1)
        r.advance(0.3)
        XCTAssertEqual(r.pipeline.phase(of: 1), .resting)
        r.lift(1, 1.0)
        XCTAssertEqual(r.timed, [])
    }

    func testForeignContactAfterHoldDeadlineDoesNotCancelIt() {
        var r = RestRun()
        r.land(1, j, 0)
        r.pipeline.noteForeignContact(at: 0.3)   // delivered before the deadline was advanced
        r.advance(0.3)
        XCTAssertEqual(r.pipeline.phase(of: 1), .down)
        r.lift(1, 1.0)
        XCTAssertEqual(r.timed, ["+38@0.250", "-38@1.000"])
    }

    func testForeignContactAlreadyDownIsResignalledAfterLanding() {
        var r = RestRun()
        r.pipeline.noteForeignContact(at: 0)     // a palm or trackpad finger that stays down
        r.land(1, j, 0.1)
        r.pipeline.noteForeignContact(at: 0.1)   // the engine re-signals it after every land
        r.advance(0.35)
        XCTAssertEqual(r.pipeline.phase(of: 1), .resting)
        r.lift(1, 2.0)
        XCTAssertEqual(r.timed, [])
    }

    func testSlowCmdSPostsChordAtThreshold() {
        var r = RestRun()
        r.land(1, cmd, 0)
        r.land(2, s, 0.6)
        r.lift(2, 0.9)
        r.lift(1, 1.2)
        XCTAssertEqual(r.timed, ["+55@0.300", "+1@0.850", "-1@0.900", "-55@1.200"])
    }

    func testSlowCmdSpaceRestsButQuickCmdSpaceTypes() {
        // Space never chords through isolation: thumbs resting on Cmd and Space must not open
        // Spotlight. A Space tap shorter than its threshold still gives Cmd+Space.
        var r = RestRun()
        r.land(1, cmd, 0)
        r.land(2, space, 0.1)
        r.advance(0.45)
        XCTAssertEqual(r.pipeline.phase(of: 2), .resting)
        r.lift(2, 0.45)
        r.land(3, space, 0.5)
        r.lift(3, 0.6)
        r.lift(1, 0.7)
        XCTAssertEqual(r.timed, ["+55@0.300", "+49@0.600", "-49@0.600", "-55@0.700"])
    }

    func testThumbsRestingOnCmdAndSpaceDoNotType() {
        var r = RestRun()
        r.land(1, cmd, 0)
        r.land(2, space, 0.5)
        r.advance(3.0)
        XCTAssertEqual(r.pipeline.phase(of: 2), .resting)
        r.lift(2, 3.0)
        r.lift(1, 3.0)
        XCTAssertEqual(r.timed, ["+55@0.300", "-55@3.000"], "lone held Cmd is revealed; Space never presses")
    }

    func testPinkyShiftAndThumbSpaceDoNotRepeatSpaces() {
        var r = RestRun()
        r.land(1, shift, 0)
        r.land(2, space, 0.5)
        r.advance(3.0)
        r.lift(2, 3.0)
        r.lift(1, 3.0)
        XCTAssertEqual(r.timed, ["+56@0.300", "-56@3.000"])
    }

    func testSlowCmdSWithIsolatedHoldOffStillChords() {
        var r = RestRun(TypingSettings(resting: .homeRow, isolatedHold: false))
        r.land(1, cmd, 0)
        r.land(2, s, 0.6)
        r.lift(2, 0.9)
        r.lift(1, 1.2)
        XCTAssertEqual(r.timed, ["+55@0.300", "+1@0.850", "-1@0.900", "-55@1.200"])
    }

    func testIsolatedHoldOffKeyRestsOnceModifierLifted() {
        var r = RestRun(TypingSettings(resting: .homeRow, isolatedHold: false))
        r.land(1, cmd, 0)
        r.land(2, s, 0.6)
        r.lift(1, 0.7)
        r.lift(2, 1.2)
        XCTAssertEqual(r.pipeline.phase(of: 2), nil)
        XCTAssertEqual(r.timed, ["+55@0.300", "-55@0.850"], "Cmd up waits for S to resolve (I4)")
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
        XCTAssertEqual(r.timed, ["+14@0.310", "-14@0.310", "+4@3.045", "-4@3.080"])
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
        XCTAssertEqual(r.timed, ["+14@0.340", "-14@0.340"])
    }

    func testSlowShiftACapitalizes() {
        var r = RestRun()
        r.land(1, shift, 0)
        r.land(2, a, 0.4)
        r.lift(2, 0.7)
        r.lift(1, 0.9)
        XCTAssertEqual(r.timed, ["+56@0.300", "+0@0.650", "-0@0.700", "-56@0.900"])
    }

    func testModifierLandingAfterKeyBreaksIsolation() {
        var r = RestRun()
        r.land(1, j, 0)
        r.land(2, cmd, 0.1)
        r.advance(0.5)
        XCTAssertEqual(r.pipeline.phase(of: 1), .resting)
        r.lift(1, 0.8)
        r.lift(2, 1.0)
        XCTAssertEqual(r.timed, ["+55@0.400", "-55@1.000"])
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

    func testBroadThumbInBurstUsesRestThreshold() {
        var r = RestRun()
        r.land(1, a, 0)
        r.land(2, s, 0.01)
        r.land(3, 45, 0.02, broad: true)
        r.land(4, d, 0.03)
        r.advance(0.27)
        XCTAssertEqual(r.pipeline.phase(of: 3), .resting)
        r.lift(3, 0.30)
        XCTAssertEqual(r.timed, [])
    }

    func testInvalidCountSettingsFallBackToDefaults() {
        var r = RestRun(TypingSettings(resting: .homeRow, burstMinContacts: 0, burstMinRestCapable: 0,
                                       staleRestingContacts: 0))
        r.land(1, cmd, 0)
        r.land(2, e, 5.1)
        r.lift(2, 5.2)
        r.lift(1, 6.0)
        XCTAssertEqual(r.timed, ["+55@0.300", "+14@5.145", "-14@5.200", "-55@6.000"])
    }

    func testCmdHeld3sThenTabStaysDown() {
        var r = RestRun()
        r.land(1, cmd, 0)
        r.land(2, tab, 3.0)
        r.lift(2, 3.1)
        r.lift(1, 3.5)
        XCTAssertEqual(r.timed, ["+55@0.300", "+48@3.045", "-48@3.100", "-55@3.500"])
    }

    func testOptionHeldWithPointerUseStaysDown() {
        var r = RestRun()
        r.restLeftHand()
        r.land(1, option, 0.2)
        r.advance(1.0)
        XCTAssertEqual(r.timed, ["+58@0.500"])
        r.pipeline.notePointerUse(at: 1.0)
        r.advance(3.0)
        XCTAssertEqual(r.timed, ["+58@0.500"])
        XCTAssertEqual(r.pipeline.phase(of: 1), .down)
        r.lift(1, 3.5)
        XCTAssertEqual(r.timed, ["+58@0.500", "-58@3.500"])
    }

    func testStaleCmdReleasedWhileHandsRest() {
        var r = RestRun()
        r.restLeftHand()
        r.land(1, cmd, 1.0)
        r.advance(2.9)
        XCTAssertEqual(r.timed, ["+55@1.300"])
        r.advance(3.0)
        XCTAssertEqual(r.timed, ["+55@1.300", "-55@3.000"])
        XCTAssertEqual(r.pipeline.phase(of: 1), .resting)
        r.land(2, e, 3.5)
        r.lift(2, 3.55)
        r.lift(1, 4.0)
        XCTAssertEqual(r.timed, ["+55@1.300", "-55@3.000", "+14@3.545", "-14@3.550"])
    }

    func testStaleNeedsEnoughRestingContacts() {
        var r = RestRun()
        r.land(101, a, 0)
        r.land(102, s, 0.01)
        r.land(1, cmd, 1.0)
        r.advance(4.0)
        XCTAssertEqual(r.timed, ["+55@1.300"])
        r.lift(1, 4.5)
        XCTAssertEqual(r.timed, ["+55@1.300", "-55@4.500"])
    }

    func testStaleAppliesWhenHandsSettleLater() {
        var r = RestRun()
        r.land(1, cmd, 0)
        r.advance(2.5)
        XCTAssertEqual(r.timed, ["+55@0.300"])
        r.restLeftHand(at: 2.5, firstID: 201)
        r.advance(3.5)
        XCTAssertEqual(r.timed, ["+55@0.300", "-55@2.780"],
                       "Released once three fingers rest and the fourth, still undecided, has resolved")
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
}
