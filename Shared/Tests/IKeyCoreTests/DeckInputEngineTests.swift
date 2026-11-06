import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import IKeyCore

// Ports of the 16 legacy TouchInputEngine behaviours (that engine and its tests stay untouched)
// run with typing .off, plus trackpad .holdToDrag where the original used hold-to-drag.
// Changed expectations against the legacy tests:
// - Pointer output is `.motion` in trackpad millimetres (dt, speed); scroll is phased; the
//   recognizer reports `.contacts(n)` whenever the finger count changes.
// - Trackpad confirmation uses radius 28: a radius-10 fingertip is now accepted instantly.
// - Held modifiers are committed (`commitHeldModifiers`) right before pointer buttons
//   (Cmd/Shift-click), drag motion, a scroll's start and gestures, not only before keys; never
//   for plain pointer motion.
// - No iPad-side repeat: the Mac repeats held keys.
// - Deadlines run at their own time inside every call, so a key confirms at 0.045 s even when
//   the next call is later. The growing-palm and cancel tests therefore act at 0.04 / 0.03 s
//   (before confirmation), and a Shift lifted before its pending letter waits for that letter
//   (I4) instead of committing it early.
// - A Space contact that lands as a fingertip may grow into a thumb while pending only in the
//   rest modes (Space commits at lift there); under typing .off it is rejected past fingerRadius.
// - A pending (radius 28) trackpad fingertip that lifts before its 45 ms confirmation within
//   1.5 mm is handed over at lift, so a quick tap still clicks as it did in the legacy engine.
//   Every pad lift first hands over the other pending fingertips still down, so a quick
//   two-finger tap stays one secondary click. A pending fingertip that slid further is handed
//   over too when other fingers take part, so the recognizer keeps the true finger count.
// - A pending trackpad contact begins in the recognizer where it landed and catches up to its
//   current point when handed over; the catch-up counts for taps and drags but never moves the
//   pointer or a scroll (no retroactive motion).
final class DeckInputEngineTests: XCTestCase {
    private let deck = ResolvedDeck(spec: MacBookAirModel.air13_2022.spec,
                                    projection: DeckProjection(display: .pro13, screenSize: CGSize(width: 1376, height: 1032)))
    private let off = TypingSettings(resting: .off)

    private func engine(typing: TypingSettings = TypingSettings(resting: .off),
                        protection: TouchProtectionSettings = .init(), trackpad: TrackpadSettings = .init(),
                        panel: PanelTrigger = .touchIDHold) -> DeckInputEngine {
        DeckInputEngine(deck: deck, protection: protection, typing: typing, trackpad: trackpad, panelTrigger: panel)
    }

    private func keyRect(_ code: UInt16) -> CGRect { deck.keys.first { $0.code == code }!.rect }
    private var touchIDRect: CGRect { deck.keys.first { $0.id == "touchid" }!.rect }
    private var keyFieldBottom: CGFloat { deck.keys.map(\.rect.maxY).max()! }
    private var ppm: Double { 1 / deck.mmPerPoint! }

    private func key(_ code: UInt16, id: Int = 1, radius: Double = 10, tolerance: Double = 0) -> TouchSample {
        let r = keyRect(code)
        return TouchSample(id: id, point: CGPoint(x: r.midX, y: r.midY), radius: radius, radiusTolerance: tolerance)
    }

    private func at(_ id: Int, _ x: CGFloat, _ y: CGFloat, radius: Double = 10) -> TouchSample {
        TouchSample(id: id, point: CGPoint(x: x, y: y), radius: radius)
    }

    private func pad(id: Int = 1, dx: CGFloat = 0, dy: CGFloat = 0, radius: Double = 10) -> TouchSample {
        at(id, deck.trackpad.midX + dx, deck.trackpad.midY + dy, radius: radius)
    }

    /// A trackpad point in millimetres from its top-left corner.
    private func padMM(id: Int, x: Double, y: Double, radius: Double) -> TouchSample {
        at(id, deck.trackpad.minX + CGFloat(x * ppm), deck.trackpad.minY + CGFloat(y * ppm), radius: radius)
    }

    private func touchID(id: Int, radius: Double = 10, dx: CGFloat = 0) -> TouchSample {
        at(id, touchIDRect.midX + dx, touchIDRect.midY, radius: radius)
    }

    private func keyEvents(_ out: [PadInput]) -> [PadInput] {
        out.filter { if case .key = $0 { return true } else { return false } }
    }

    private func buttonEvents(_ out: [PadInput]) -> [PadInput] {
        out.filter { if case .button = $0 { return true } else { return false } }
    }

    private func motion(_ out: [PadInput]) -> PointerMotion? {
        for case .motion(let m) in out { return m }
        return nil
    }

    // MARK: - Ported legacy behaviours

    func testBroadThumbCanTapSpace() {
        var e = engine()
        let thumb = key(49, radius: 55)
        XCTAssertEqual(e.begin([thumb], at: 0), [])
        XCTAssertEqual(e.advance(to: 0.05), [])
        XCTAssertEqual(e.end([thumb], at: 0.12), [.key(code: 49, down: true), .key(code: 49, down: false)])
    }

    func testRestingBroadPalmOnSpaceDoesNotType() {
        var e = engine()
        let palm = key(49, radius: 55)
        XCTAssertEqual(e.begin([palm], at: 0), [])
        XCTAssertEqual(e.advance(to: 0.6), [])
        XCTAssertEqual(e.advance(to: 5), [])
        XCTAssertEqual(e.end([palm], at: 5.1), [])
    }

    func testBroadSpaceSlideDoesNotBecomeTap() {
        var e = engine()
        let thumb = key(49, radius: 55)
        _ = e.begin([thumb], at: 0)
        var sliding = thumb
        sliding.point.x += 30
        XCTAssertEqual(e.move([sliding], at: 0.1), [])
        XCTAssertEqual(e.end([sliding], at: 0.2), [])
    }

    func testOversizedPalmOnSpaceIsRejected() {
        var e = engine()
        let palm = key(49, radius: 100)
        XCTAssertEqual(e.begin([palm], at: 0), [])
        XCTAssertEqual(e.end([palm], at: 0.1), [])
    }

    func testGrowingPalmRejectedBeforeKeyConfirmation() {
        var e = engine()
        _ = e.begin([key(0)], at: 0)
        XCTAssertEqual(e.move([key(0, radius: 50)], at: 0.04), [])
        XCTAssertEqual(e.advance(to: 0.1), [])
        XCTAssertEqual(e.end([key(0, radius: 50)], at: 0.2), [])
    }

    func testGrowingPalmOnSpaceInOffModeDoesNotType() {
        var e = engine()
        _ = e.begin([key(49, radius: 15)], at: 0)
        XCTAssertEqual(e.move([key(49, radius: 60)], at: 0.02), [])
        XCTAssertEqual(e.advance(to: 0.2), [])
        XCTAssertEqual(e.end([key(49, radius: 60)], at: 0.5), [])

        // A thumb that settles and stays still never holds Space down (the Mac would repeat it).
        var still = engine()
        _ = still.begin([key(49, radius: 20)], at: 0)
        XCTAssertEqual(still.move([key(49, radius: 60)], at: 0.02), [])
        XCTAssertEqual(still.advance(to: 2), [])
        XCTAssertTrue(still.heldKeyCodes.isEmpty)
        XCTAssertEqual(still.move([key(49, radius: 62)], at: 2.1), [])
        XCTAssertEqual(still.end([key(49, radius: 62)], at: 2.2), [])

        // Rest modes keep the legacy tolerance: Space only commits at lift there.
        var rest = engine(typing: TypingSettings())
        _ = rest.begin([key(49, radius: 20)], at: 0)
        XCTAssertEqual(rest.move([key(49, radius: 60)], at: 0.02), [])
        XCTAssertEqual(rest.advance(to: 2), [])
        XCTAssertEqual(rest.end([key(49, radius: 60)], at: 2.1), [])
    }

    func testPalmRejectionSticksWhenContactShrinks() {
        var e = engine()
        _ = e.begin([key(0, radius: 50)], at: 0)
        XCTAssertEqual(e.move([key(0)], at: 0.1), [])
        XCTAssertEqual(e.end([key(0)], at: 0.2), [])
    }

    func testPalmGrowthReleasesAlreadyPressedKey() {
        var e = engine()
        _ = e.begin([key(0)], at: 0)
        XCTAssertEqual(e.advance(to: 0.05), [.key(code: 0, down: true)])
        XCTAssertEqual(e.move([key(0, radius: 60)], at: 0.1), [.key(code: 0, down: false)])
        XCTAssertEqual(e.advance(to: 1), [])
        XCTAssertEqual(e.end([key(0, radius: 60)], at: 1.1), [])
    }

    func testQuickChordOrdersModifierBeforeLetterAndReleasesItLast() {
        var e = engine()
        let letter = key(0, id: 1), shift = key(56, id: 2)
        _ = e.begin([letter, shift], at: 0)
        XCTAssertEqual(e.end([letter, shift], at: 0.02), [
            .key(code: 56, down: true), .key(code: 0, down: true),
            .key(code: 0, down: false), .key(code: 56, down: false)
        ])
    }

    func testStaggeredQuickLetterCommitsPendingShiftFirst() {
        var e = engine()
        _ = e.begin([key(56, id: 2)], at: 0)
        _ = e.begin([key(0)], at: 0.01)
        XCTAssertEqual(e.end([key(0)], at: 0.025), [
            .key(code: 56, down: true), .key(code: 0, down: true), .key(code: 0, down: false)
        ])
        XCTAssertEqual(e.end([key(56, id: 2)], at: 0.03), [.key(code: 56, down: false)])
    }

    func testShiftLiftingBeforePendingLetterStillTypesItsChord() {
        var e = engine()
        _ = e.begin([key(56, id: 2)], at: 0)
        _ = e.begin([key(0)], at: 0.01)
        XCTAssertEqual(e.end([key(56, id: 2)], at: 0.02), [], "Shift's up waits for the letter (I4)")
        XCTAssertEqual(e.advance(to: 0.06), [
            .key(code: 56, down: true), .key(code: 0, down: true), .key(code: 56, down: false)
        ])
        XCTAssertEqual(e.end([key(0)], at: 0.1), [.key(code: 0, down: false)])
    }

    func testSecondFingerOnSameKeyDoesNotReleaseFirstFinger() {
        var e = engine()
        _ = e.begin([key(0)], at: 0)
        XCTAssertEqual(e.advance(to: 0.05), [.key(code: 0, down: true)])
        _ = e.begin([key(0, id: 2)], at: 0.1)
        XCTAssertEqual(e.advance(to: 0.15), [])
        XCTAssertEqual(e.end([key(0)], at: 0.2), [])
        XCTAssertEqual(e.end([key(0, id: 2)], at: 0.21), [.key(code: 0, down: false)])
    }

    func testCancelPendingKeyDoesNotCommitIt() {
        var e = engine()
        _ = e.begin([key(0)], at: 0)
        XCTAssertEqual(e.end([key(0)], at: 0.03, cancelled: true), [])
        XCTAssertEqual(e.advance(to: 1), [])

        var resting = engine(typing: TypingSettings())
        _ = resting.begin([key(0)], at: 0)
        XCTAssertEqual(resting.end([key(0)], at: 0.2, cancelled: true), [])
        XCTAssertEqual(resting.advance(to: 1), [])
    }

    func testTouchStartingOnPalmRestCannotSlideIntoKey() {
        var e = engine()
        let resting = at(1, deck.trackpad.minX - 100, keyFieldBottom + 100)
        XCTAssertEqual(e.begin([resting], at: 0), [])
        XCTAssertEqual(e.move([key(0)], at: 0.1), [])
        XCTAssertEqual(e.advance(to: 0.5), [])
        XCTAssertEqual(e.end([key(0)], at: 0.6), [])
    }

    func testTrackpadConfirmsWithoutRetroactivePointerJump() {
        var e = engine()
        XCTAssertEqual(e.begin([pad(radius: 28)], at: 0), [])
        XCTAssertEqual(e.move([pad(dx: 12, radius: 28)], at: 0.02), [])
        XCTAssertEqual(e.advance(to: 0.05), [.contacts(1)])
        let out = e.move([pad(dx: 20, radius: 28)], at: 0.06)
        XCTAssertEqual(out.count, 1)
        let m = motion(out)
        XCTAssertEqual(m?.dx ?? 0, 8 / ppm, accuracy: 1e-6, "only motion after confirmation (8 pt), in mm")
        XCTAssertEqual(m?.dy ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(m?.dt ?? 0, 0.015, accuracy: 1e-9)
        XCTAssertEqual(e.end([pad(dx: 20, radius: 28)], at: 0.07), [.contacts(0)])
    }

    func testTypingCancelsDragAndSuppressesRestingTrackpadUntilLift() {
        var e = engine(trackpad: TrackpadSettings(dragStyle: .holdToDrag))
        XCTAssertEqual(e.begin([pad(id: 2)], at: 0), [.contacts(1)])
        XCTAssertEqual(e.advance(to: 0.4), [.button(button: .left, down: true, clickState: 1)])
        XCTAssertEqual(e.begin([key(0)], at: 0.5), [])
        XCTAssertEqual(e.advance(to: 0.55), [
            .key(code: 0, down: true), .button(button: .left, down: false, clickState: 1)
        ])
        XCTAssertEqual(e.end([key(0)], at: 0.6), [.key(code: 0, down: false)])
        XCTAssertEqual(e.move([pad(id: 2, dx: 20)], at: 1.1), [])
        XCTAssertEqual(e.end([pad(id: 2)], at: 1.2), [.contacts(0)])
        XCTAssertEqual(e.begin([pad(id: 3)], at: 1.3), [.contacts(1)])
        XCTAssertEqual(e.end([pad(id: 3)], at: 1.4), [
            .contacts(0), .button(button: .left, down: true, clickState: 1),
            .button(button: .left, down: false, clickState: 1)
        ])
    }

    func testResetClearsHeldInput() {
        var e = engine()
        _ = e.begin([key(0), key(56, id: 2)], at: 0)
        XCTAssertEqual(e.advance(to: 0.05), [.key(code: 56, down: true), .key(code: 0, down: true)])
        XCTAssertEqual(e.heldKeyCodes, [0, 56])
        XCTAssertEqual(e.reset(), [.releaseAll])
        XCTAssertTrue(e.heldKeyCodes.isEmpty)
        XCTAssertFalse(e.hasActiveContacts)
        XCTAssertNil(e.nextDeadline)
        XCTAssertEqual(e.advance(to: 1), [])
        XCTAssertEqual(e.end([key(0), key(56, id: 2)], at: 1.1), [])
    }

    // MARK: - Hit testing (F02)

    func testGapTouchHitsNearestKey() {
        let a = keyRect(0), s = keyRect(1)
        let mid = (a.maxX + s.minX) / 2
        for (x, code) in [(mid - 0.5, UInt16(0)), (mid + 0.5, UInt16(1))] {
            var e = engine()
            _ = e.begin([at(1, x, a.midY)], at: 0)
            XCTAssertEqual(e.end([at(1, x, a.midY)], at: 0.02), [.key(code: code, down: true), .key(code: code, down: false)])
        }
        // Between the R and F rows, nearer F.
        let r = keyRect(15), f = keyRect(3)
        let x = (max(r.minX, f.minX) + min(r.maxX, f.maxX)) / 2
        let y = (r.maxY + f.minY) / 2 + 0.5
        var e = engine()
        _ = e.begin([at(1, x, y)], at: 0)
        XCTAssertEqual(e.end([at(1, x, y)], at: 0.02), [.key(code: 3, down: true), .key(code: 3, down: false)])
        // 2.9 mm below fn still presses it (a lone modifier tap); 3.1 mm does not.
        let fn = keyRect(63)
        for (mm, expected) in [(2.9, [PadInput.key(code: 63, down: true), .key(code: 63, down: false)]), (3.1, [])] {
            var e = engine()
            let p = at(1, fn.midX, fn.maxY + CGFloat(mm * ppm))
            _ = e.begin([p], at: 0)
            XCTAssertEqual(e.end([p], at: 0.02), expected, "\(mm) mm")
        }
    }

    func testEdgeKeyAtScreenXZero() {
        // The key field is wider than the screen: the clipped left column stays hittable at x = 0...2.
        XCTAssertLessThan(keyRect(53).minX, 0)
        for code: UInt16 in [53, 48, 57, 56, 63] {
            for x: CGFloat in [0, 1, 2] {
                var e = engine()
                let p = at(1, x, keyRect(code).midY)
                _ = e.begin([p], at: 0)
                let out = e.end([p], at: 0.02)
                XCTAssertEqual(out.first, .key(code: code, down: true), "code \(code) at x \(x)")
                XCTAssertEqual(out.last, .key(code: code, down: false), "code \(code) at x \(x)")
            }
        }
        // Right edge: Delete.
        var e = engine()
        let p = at(1, 1375.5, keyRect(51).midY)
        _ = e.begin([p], at: 0)
        XCTAssertEqual(e.end([p], at: 0.02), [.key(code: 51, down: true), .key(code: 51, down: false)])
    }

    // MARK: - Touch ID and the panel (F12)

    func testTouchIDNeverTypes() {
        let r = touchIDRect
        let points = [CGPoint(x: r.midX, y: r.midY), CGPoint(x: r.minX + 1, y: r.minY + 1),
                      CGPoint(x: r.maxX - 1, y: r.maxY - 1)]
        for panel in PanelTrigger.allCases {
            for p in points {
                var e = engine(panel: panel)
                let tap = at(1, p.x, p.y)
                XCTAssertEqual(e.begin([tap], at: 0), [])
                XCTAssertEqual(e.end([tap], at: 0.1), [])
                // A long hold that slides 10 mm never types either.
                XCTAssertEqual(e.begin([at(2, p.x, p.y)], at: 1), [])
                XCTAssertEqual(e.move([at(2, p.x - CGFloat(10 * ppm), p.y)], at: 1.2), [])
                XCTAssertEqual(e.advance(to: 3), [])
                XCTAssertEqual(e.end([at(2, p.x - CGFloat(10 * ppm), p.y)], at: 3), [])
                XCTAssertFalse(e.drainSignals().contains(.openPanel))
            }
        }
    }

    func testTouchIDHoldOpensPanelAndReleasesAll() {
        var e = engine()
        _ = e.begin([key(56, id: 1)], at: 0)
        XCTAssertEqual(e.advance(to: 0.05), [.key(code: 56, down: true)])
        XCTAssertEqual(e.begin([touchID(id: 2)], at: 0.1), [])
        XCTAssertEqual(e.panelHoldProgress(at: 0.4) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(e.nextDeadline ?? 0, 0.7, accuracy: 1e-9)
        XCTAssertEqual(e.move([touchID(id: 2, dx: CGFloat(3 * ppm))], at: 0.3), [], "3 mm travel is allowed")
        XCTAssertEqual(e.advance(to: 0.699), [])
        XCTAssertFalse(e.drainSignals().contains(.openPanel))
        XCTAssertEqual(e.advance(to: 0.7), [.releaseAll])
        XCTAssertEqual(e.drainSignals(), [.openPanel, .feedback(.released(56))])
        XCTAssertTrue(e.heldKeyCodes.isEmpty)
        XCTAssertFalse(e.hasActiveContacts)
        XCTAssertNil(e.panelHoldProgress(at: 0.8))
        XCTAssertEqual(e.end([key(56, id: 1), touchID(id: 2)], at: 1), [])
        XCTAssertEqual(e.advance(to: 3), [])
        XCTAssertTrue(e.drainSignals().isEmpty, "fires once")
    }

    func testPalmOnTouchIDDoesNotOpenPanel() {
        var palm = engine()
        _ = palm.begin([touchID(id: 1, radius: 50)], at: 0)
        XCTAssertNil(palm.panelHoldProgress(at: 0.3))
        XCTAssertEqual(palm.advance(to: 2), [])
        XCTAssertFalse(palm.drainSignals().contains(.openPanel))

        var sliding = engine()
        _ = sliding.begin([touchID(id: 1)], at: 0)
        _ = sliding.move([touchID(id: 1, dx: CGFloat(5 * ppm))], at: 0.3)
        XCTAssertEqual(sliding.advance(to: 2), [])
        XCTAssertFalse(sliding.drainSignals().contains(.openPanel))

        var growing = engine()
        _ = growing.begin([touchID(id: 1)], at: 0)
        _ = growing.move([touchID(id: 1, radius: 50)], at: 0.3)
        XCTAssertEqual(growing.advance(to: 2), [])
        XCTAssertFalse(growing.drainSignals().contains(.openPanel))

        var two = engine()
        _ = two.begin([touchID(id: 1)], at: 0)
        _ = two.begin([touchID(id: 2, dx: 15)], at: 0.1)
        XCTAssertEqual(two.advance(to: 2), [])
        XCTAssertFalse(two.drainSignals().contains(.openPanel))
    }

    func testPalmRestTwoFingerHold() {
        let p1 = at(1, deck.trackpad.minX - 80, keyFieldBottom + 120)
        let p2 = at(2, deck.trackpad.minX - 140, keyFieldBottom + 140)
        var e = engine(panel: .palmRestTwoFingerHold)
        XCTAssertEqual(e.begin([p1], at: 0), [])
        XCTAssertNil(e.nextDeadline)
        XCTAssertEqual(e.begin([p2], at: 0.2), [])
        XCTAssertEqual(e.panelHoldProgress(at: 0.6) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(e.advance(to: 0.999), [])
        XCTAssertEqual(e.advance(to: 1.0), [.releaseAll])
        XCTAssertEqual(e.drainSignals(), [.openPanel])

        var one = engine(panel: .palmRestTwoFingerHold)
        _ = one.begin([p1], at: 0)
        XCTAssertEqual(one.advance(to: 3), [])
        XCTAssertFalse(one.drainSignals().contains(.openPanel))

        var touchIDOnly = engine(panel: .palmRestTwoFingerHold)
        _ = touchIDOnly.begin([touchID(id: 1)], at: 0)
        XCTAssertEqual(touchIDOnly.advance(to: 3), [])
        XCTAssertFalse(touchIDOnly.drainSignals().contains(.openPanel))

        var defaultTrigger = engine()
        _ = defaultTrigger.begin([p1, p2], at: 0)
        XCTAssertEqual(defaultTrigger.advance(to: 3), [])
        XCTAssertFalse(defaultTrigger.drainSignals().contains(.openPanel))
    }

    func testSuppressedModeRejectsKeysButPanelHoldWorks() {
        var e = engine()
        _ = e.begin([key(0)], at: 0)
        XCTAssertEqual(e.advance(to: 0.05), [.key(code: 0, down: true)])
        _ = e.drainSignals()
        XCTAssertEqual(e.setInputSuppressed(true), [.releaseAll])
        XCTAssertEqual(e.drainSignals(), [.feedback(.released(0))], "the drawn key is released too")
        XCTAssertTrue(e.isInputSuppressed)
        XCTAssertEqual(e.setInputSuppressed(true), [], "already suppressed")
        XCTAssertTrue(e.heldKeyCodes.isEmpty)
        XCTAssertEqual(e.end([key(0)], at: 0.1), [])

        XCTAssertEqual(e.begin([key(14, id: 2)], at: 0.2), [])
        XCTAssertEqual(e.end([key(14, id: 2)], at: 0.3), [])
        XCTAssertEqual(e.begin([pad(id: 3)], at: 0.4), [])
        XCTAssertEqual(e.indicators.map(\.disposition), [.rejected])
        XCTAssertEqual(e.end([pad(id: 3)], at: 0.45), [])

        XCTAssertEqual(e.begin([touchID(id: 4)], at: 1.0), [])
        XCTAssertEqual(e.advance(to: 1.6), [.releaseAll])
        XCTAssertEqual(e.drainSignals(), [.openPanel])
        XCTAssertTrue(e.isInputSuppressed)

        XCTAssertEqual(e.setInputSuppressed(false), [])
        XCTAssertFalse(e.isInputSuppressed)
        _ = e.begin([key(14, id: 5)], at: 2.0)
        XCTAssertEqual(e.end([key(14, id: 5)], at: 2.1), [.key(code: 14, down: true), .key(code: 14, down: false)])
    }

    func testSuppressingKeepsPanelHoldInProgress() {
        var e = engine()
        _ = e.begin([touchID(id: 1)], at: 0)
        XCTAssertEqual(e.advance(to: 0.3), [])
        XCTAssertEqual(e.setInputSuppressed(true), [.releaseAll])
        XCTAssertEqual(e.panelHoldProgress(at: 0.3) ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(e.advance(to: 1.0), [.releaseAll])
        XCTAssertEqual(e.drainSignals(), [.openPanel])
        XCTAssertEqual(e.end([touchID(id: 1)], at: 1.1), [])
        XCTAssertFalse(e.hasActiveContacts)
    }

    func testResetEndsTentativeKeyFeedback() {
        // A pending letter forgotten by suppression is drawn up again.
        var e = engine(typing: TypingSettings())
        _ = e.begin([key(38)], at: 0)
        XCTAssertEqual(e.advance(to: 0.1), [])
        XCTAssertEqual(e.setInputSuppressed(true), [.releaseAll])
        let signals = e.drainSignals()
        XCTAssertEqual(signals, [.feedback(.tentative(38)), .feedback(.rejected(38))])
        var visual = KeyVisualState()
        visual.apply(signals.compactMap { if case .feedback(let f) = $0 { return f } else { return nil } }, at: 0.1)
        XCTAssertTrue(visual.tentative.isEmpty)

        // A resting Command forgotten when the Touch ID hold opens the panel.
        var panel = engine(typing: TypingSettings())
        _ = panel.begin([key(55)], at: 0)
        _ = panel.begin([touchID(id: 2)], at: 0.1)
        XCTAssertEqual(panel.advance(to: 0.8), [.releaseAll])
        XCTAssertEqual(panel.drainSignals(), [.feedback(.tentative(55)), .openPanel, .feedback(.rejected(55))])
        XCTAssertEqual(panel.end([key(55), touchID(id: 2)], at: 1), [])
        XCTAssertEqual(panel.drainSignals(), [])
    }

    func testSuppressingReleasesHeldTrackpadButton() {
        var e = engine(trackpad: TrackpadSettings(dragStyle: .holdToDrag))
        _ = e.begin([pad()], at: 0)
        XCTAssertEqual(e.advance(to: 0.4), [.button(button: .left, down: true, clickState: 1)])
        XCTAssertEqual(e.heldButtons, [.left])
        XCTAssertEqual(e.setInputSuppressed(true), [.releaseAll])
        XCTAssertTrue(e.heldButtons.isEmpty)
        XCTAssertEqual(e.move([pad(dx: 30)], at: 0.5), [])
        XCTAssertEqual(e.end([pad(dx: 30)], at: 0.6), [])
    }

    // MARK: - Resting fingers next to other contacts (F04)

    func testRestingHomeRowWithTrackpadTapStillClicks() {
        var e = engine(typing: TypingSettings())
        let home: [UInt16] = [0, 1, 2, 3, 38, 40, 37, 41]
        for (i, code) in home.enumerated() {
            XCTAssertEqual(e.begin([key(code, id: i + 1)], at: Double(i) * 0.01), [])
        }
        XCTAssertEqual(e.advance(to: 1.0), [])
        XCTAssertEqual(e.indicators.map(\.disposition), Array(repeating: .resting, count: 8))
        XCTAssertEqual(e.begin([pad(id: 20)], at: 1.0), [.contacts(1)])
        XCTAssertEqual(e.end([pad(id: 20)], at: 1.08), [
            .contacts(0), .button(button: .left, down: true, clickState: 1),
            .button(button: .left, down: false, clickState: 1)
        ])
        XCTAssertEqual(e.end(home.indices.map { key(home[$0], id: $0 + 1) }, at: 2), [])
    }

    func testTrackpadContactCancelsIsolatedHold() {
        // Policy F: isolatedHold is opt-in. By default a lone J held past tapMax is a rest.
        var restDefault = engine(typing: TypingSettings())
        _ = restDefault.begin([key(38)], at: 0)
        XCTAssertEqual(restDefault.advance(to: 1.0), [], "default: a held J rests")
        XCTAssertEqual(restDefault.end([key(38)], at: 1.0), [])

        // Control with the opt-in: an isolated J presses at tapMax (0.30 s), not before.
        let hold = TypingSettings(isolatedHold: true)
        var alone = engine(typing: hold)
        _ = alone.begin([key(38)], at: 0)
        XCTAssertEqual(alone.advance(to: 0.29), [])
        XCTAssertEqual(alone.advance(to: 0.31), [.key(code: 38, down: true)], "control: an isolated J holds")
        XCTAssertEqual(alone.end([key(38)], at: 0.5), [.key(code: 38, down: false)])

        // A trackpad finger landing before the threshold breaks the isolation.
        var e = engine(typing: hold)
        _ = e.begin([key(38)], at: 0)
        XCTAssertEqual(e.begin([pad(id: 2)], at: 0.1), [.contacts(1)])
        XCTAssertEqual(e.advance(to: 1.0), [])
        XCTAssertEqual(e.end([key(38)], at: 1.0), [])

        // The trackpad finger was already down when J landed.
        var later = engine(typing: hold)
        _ = later.begin([pad(id: 2)], at: 0)
        _ = later.begin([key(38)], at: 0.5)
        XCTAssertEqual(later.advance(to: 1.5), [])
        XCTAssertEqual(later.end([key(38)], at: 1.5), [])

        // A palm (rejected key contact) or a Touch ID finger already down counts the same way.
        var palm = engine(typing: hold)
        _ = palm.begin([key(5, id: 2, radius: 60)], at: 0)
        _ = palm.begin([key(38)], at: 0.05)
        XCTAssertEqual(palm.advance(to: 1.5), [])
        XCTAssertEqual(palm.end([key(38)], at: 1.5), [])
        var touch = engine(typing: hold)
        _ = touch.begin([touchID(id: 2, radius: 50)], at: 0)
        _ = touch.begin([key(38)], at: 0.05)
        XCTAssertEqual(touch.advance(to: 1.5), [])
        XCTAssertEqual(touch.end([key(38)], at: 1.5), [])
    }

    func testPalmDownThenHeldJDoesNotType() {
        var e = engine(typing: TypingSettings())
        XCTAssertEqual(e.begin([key(5, id: 1, radius: 60)], at: 0), [], "palm on G is rejected")
        _ = e.begin([key(38, id: 2)], at: 0.05)
        XCTAssertEqual(e.advance(to: 1.05), [])
        XCTAssertEqual(e.end([key(38, id: 2)], at: 1.05), [])
        XCTAssertEqual(e.end([key(5, id: 1, radius: 60)], at: 1.1), [])

        var outside = engine(typing: TypingSettings())
        _ = outside.begin([at(1, deck.trackpad.maxX + 100, keyFieldBottom + 100, radius: 40)], at: 0)
        _ = outside.begin([key(38, id: 2)], at: 0.05)
        XCTAssertEqual(outside.advance(to: 1.05), [])
    }

    // MARK: - Modifiers and the pointer (I6)

    func testShiftDragFlushesModifierBeforeButton() {
        var e = engine(typing: TypingSettings())
        XCTAssertEqual(e.begin([key(56, id: 1)], at: 0), [])
        XCTAssertEqual(e.begin([pad(id: 2)], at: 0.1), [.contacts(1)])
        XCTAssertEqual(e.end([pad(id: 2)], at: 0.15), [
            .contacts(0), .key(code: 56, down: true),
            .button(button: .left, down: true, clickState: 1), .button(button: .left, down: false, clickState: 1)
        ])
        XCTAssertEqual(e.begin([pad(id: 3)], at: 0.25), [.contacts(1)])
        let drag = e.move([pad(id: 3, dx: 20)], at: 0.3)
        XCTAssertEqual(drag.first, .button(button: .left, down: true, clickState: 1))
        XCTAssertNotNil(motion(drag))
        XCTAssertTrue(keyEvents(drag).isEmpty)
        XCTAssertEqual(e.end([key(56, id: 1)], at: 0.5), [.key(code: 56, down: false)])
        XCTAssertEqual(e.end([pad(id: 3, dx: 20)], at: 0.6), [.contacts(0), .button(button: .left, down: false, clickState: 1)])
    }

    func testCommandFlushedBeforeHoldToDragButton() {
        var e = engine(typing: TypingSettings(), trackpad: TrackpadSettings(dragStyle: .holdToDrag))
        _ = e.begin([key(55, id: 1)], at: 0)
        _ = e.begin([pad(id: 2)], at: 0.1)
        XCTAssertEqual(e.advance(to: 0.5), [.key(code: 55, down: true), .button(button: .left, down: true, clickState: 1)])
        let m = e.move([pad(id: 2, dx: 20)], at: 0.6)
        XCTAssertEqual(m.count, 1)
        XCTAssertNotNil(motion(m))
        XCTAssertEqual(e.end([pad(id: 2, dx: 20)], at: 0.7), [.contacts(0), .button(button: .left, down: false, clickState: 1)])
        XCTAssertEqual(e.end([key(55, id: 1)], at: 0.8), [.key(code: 55, down: false)])
    }

    /// Policy F3 pointer modifiers: plain pointer motion never commits a held modifier; a click
    /// right after does (Cmd-click), and the modifier stays down until its contact lifts.
    func testPlainPointerMotionNeverCommitsHeldModifierButClickDoes() {
        var e = engine(typing: TypingSettings())
        var out = e.begin([key(55, id: 1)], at: 0)
        out += e.begin([pad(id: 2)], at: 0.5)
        for k in 1...10 { out += e.move([pad(id: 2, dx: CGFloat(4 * k))], at: 0.5 + Double(k) * 0.02) }
        out += e.end([pad(id: 2, dx: 40)], at: 0.8)
        XCTAssertNotNil(motion(out))
        XCTAssertTrue(keyEvents(out).isEmpty, "pointing with Cmd held posts no Cmd: \(out)")
        XCTAssertEqual(e.begin([pad(id: 3)], at: 1.5), [.contacts(1)])
        XCTAssertEqual(e.end([pad(id: 3)], at: 1.55), [
            .contacts(0), .key(code: 55, down: true),
            .button(button: .left, down: true, clickState: 1), .button(button: .left, down: false, clickState: 1)
        ])
        XCTAssertEqual(e.end([key(55, id: 1)], at: 2), [.key(code: 55, down: false)])
    }

    /// A thumb resting on Cmd while the other hand points and the thumb's own hand settles
    /// (pipeline rule P1) never chords: pointing must not mark it used, so the later click is plain.
    func testRestingThumbOnCmdWhilePointingLeavesClicksPlain() {
        for mod: UInt16 in [55, 58] {
            var e = engine(typing: TypingSettings())
            var out = e.begin([key(mod, id: 1)], at: 0)
            out += e.begin([pad(id: 9)], at: 0.05)
            out += e.move([pad(id: 9, dx: 6)], at: 0.1)
            out += e.move([pad(id: 9, dx: 12)], at: 0.15)
            for (i, code) in ([0, 1, 2, 3] as [UInt16]).enumerated() {
                out += e.begin([key(code, id: 2 + i)], at: 0.2 + Double(i) * 0.01)
            }
            for k in 1...10 { out += e.move([pad(id: 9, dx: CGFloat(12 + 3 * k))], at: 0.3 + Double(k) * 0.02) }
            out += e.end([pad(id: 9, dx: 42)], at: 0.55)
            out += e.advance(to: 1.2)
            out += e.begin([pad(id: 10)], at: 1.2)
            out += e.end([pad(id: 10)], at: 1.25)
            out += e.end((1...5).map { $0 == 1 ? key(mod, id: 1) : key([0, 1, 2, 3][$0 - 2], id: $0) }, at: 2)
            out += e.advance(to: 3)
            XCTAssertTrue(keyEvents(out).isEmpty, "modifier \(mod): \(out)")
            XCTAssertEqual(buttonEvents(out), [.button(button: .left, down: true, clickState: 1),
                                               .button(button: .left, down: false, clickState: 1)])
        }
    }

    /// Option held, then a two-finger scroll: Option is committed right before the scroll's
    /// `.began` (not at `.mayBegin`, which a resting pair of fingers also sends).
    func testOptionCommittedRightBeforeScrollBegins() {
        var e = engine(typing: TypingSettings())
        _ = e.begin([key(58, id: 1)], at: 0)
        var out = e.begin([padMM(id: 2, x: 55, y: 40, radius: 10), padMM(id: 3, x: 75, y: 40, radius: 10)], at: 0.5)
        XCTAssertTrue(keyEvents(out).isEmpty, "\(out)")
        for k in 1...6 {
            let dy = Double(k) * 2
            out += e.move([padMM(id: 2, x: 55, y: 40 + dy, radius: 10), padMM(id: 3, x: 75, y: 40 + dy, radius: 10)],
                          at: 0.5 + Double(k) * 0.016)
        }
        guard let began = out.firstIndex(where: { if case .scroll(let m) = $0 { return m.phase == .began } else { return false } }) else {
            return XCTFail("no scroll began: \(out)")
        }
        XCTAssertEqual(keyEvents(out), [.key(code: 58, down: true)])
        XCTAssertEqual(out[began - 1], .key(code: 58, down: true), "\(out)")
        out = e.end([padMM(id: 2, x: 55, y: 52, radius: 10), padMM(id: 3, x: 75, y: 52, radius: 10)], at: 0.7)
        XCTAssertTrue(keyEvents(out).isEmpty)
        XCTAssertEqual(e.end([key(58, id: 1)], at: 1), [.key(code: 58, down: false)])
    }

    /// Control held, then a three-finger swipe: Control goes out right before the gesture.
    /// A three-finger tap (Look Up) takes held modifiers the same way.
    func testModifierCommittedRightBeforeGestures() {
        var e = engine(typing: TypingSettings())
        _ = e.begin([key(59, id: 1)], at: 0)
        let xs = [45.0, 65.0, 85.0]
        var out = e.begin(xs.indices.map { padMM(id: 2 + $0, x: xs[$0], y: 40, radius: 10) }, at: 0.5)
        for k in 1...8 {
            out += e.move(xs.indices.map { padMM(id: 2 + $0, x: xs[$0] + Double(k) * 4, y: 40, radius: 10) },
                          at: 0.5 + Double(k) * 0.012)
        }
        out += e.end(xs.indices.map { padMM(id: 2 + $0, x: xs[$0] + 32, y: 40, radius: 10) }, at: 0.62)
        guard let swipe = out.firstIndex(where: { if case .gesture = $0 { return true } else { return false } }) else {
            return XCTFail("no swipe: \(out)")
        }
        XCTAssertEqual(out[swipe], .gesture(WireGesture(kind: .swipe, fingers: 3, direction: "right")))
        XCTAssertEqual(out[swipe - 1], .key(code: 59, down: true), "\(out)")
        XCTAssertEqual(keyEvents(out), [.key(code: 59, down: true)])
        XCTAssertEqual(e.end([key(59, id: 1)], at: 1), [.key(code: 59, down: false)])

        var tap = engine(typing: TypingSettings())
        _ = tap.begin([key(55, id: 1)], at: 0)
        out = tap.begin(xs.indices.map { padMM(id: 2 + $0, x: xs[$0], y: 40, radius: 10) }, at: 0.5)
        out += tap.end(xs.indices.map { padMM(id: 2 + $0, x: xs[$0], y: 40, radius: 10) }, at: 0.58)
        guard let lookUp = out.firstIndex(of: .gesture(WireGesture(kind: .tap, fingers: 3))) else {
            return XCTFail("no three-finger tap: \(out)")
        }
        XCTAssertEqual(out[lookUp - 1], .key(code: 55, down: true), "\(out)")
        XCTAssertEqual(keyEvents(out), [.key(code: 55, down: true)])
        XCTAssertTrue(buttonEvents(out).isEmpty)
        XCTAssertEqual(tap.end([key(55, id: 1)], at: 1), [.key(code: 55, down: false)])
    }

    /// A modifier pressed during a tap-drag (Option-drag to copy) is committed before the next
    /// drag motion; plain pointing afterwards with the button up commits nothing new.
    func testModifierPressedDuringDragCommitsBeforeNextDragMotion() {
        var e = engine(typing: TypingSettings())
        XCTAssertEqual(e.begin([pad(id: 1)], at: 0), [.contacts(1)])
        _ = e.end([pad(id: 1)], at: 0.05)
        _ = e.begin([pad(id: 2)], at: 0.15)
        var out = e.move([pad(id: 2, dx: 20)], at: 0.2)
        XCTAssertTrue(keyEvents(out).isEmpty)
        XCTAssertEqual(e.heldButtons, [.left], "tap-drag engaged: \(out)")
        XCTAssertEqual(e.begin([key(58, id: 3)], at: 0.4), [])
        out = e.move([pad(id: 2, dx: 30)], at: 0.45)
        XCTAssertEqual(out.first, .key(code: 58, down: true), "\(out)")
        XCTAssertNotNil(motion(out))
        out = e.end([pad(id: 2, dx: 30)], at: 0.6)
        XCTAssertEqual(buttonEvents(out), [.button(button: .left, down: false, clickState: 1)])
        XCTAssertTrue(keyEvents(out).isEmpty, "Option stays down until its contact lifts")
        XCTAssertEqual(e.end([key(58, id: 3)], at: 0.8), [.key(code: 58, down: false)])

        // Without the drag, the same Option landing while pointing posts nothing.
        var plain = engine(typing: TypingSettings())
        _ = plain.begin([pad(id: 2)], at: 1)
        _ = plain.begin([key(58, id: 3)], at: 1.1)
        out = plain.move([pad(id: 2, dx: 30)], at: 1.2)
        XCTAssertNotNil(motion(out))
        XCTAssertTrue(keyEvents(out).isEmpty)
        out = plain.end([key(58, id: 3)], at: 1.6) + plain.end([pad(id: 2, dx: 30)], at: 1.7)
        XCTAssertTrue(keyEvents(out).isEmpty, "a rest posts nothing: \(out)")
    }

    /// The remapped left Command (tap-only, the user's input-source switch) is never a pointer
    /// modifier: a click with it held is plain, and the long hold posts nothing.
    func testTapOnlyLeftCommandIsNeverCommittedForThePointer() {
        var e = engine(typing: TypingSettings(tapOnlyCodes: [55]))
        var out = e.begin([key(55, id: 1)], at: 0)
        out += e.begin([pad(id: 2)], at: 0.5)
        out += e.end([pad(id: 2)], at: 0.55)
        out += e.end([key(55, id: 1)], at: 1)
        out += e.advance(to: 2)
        XCTAssertTrue(keyEvents(out).isEmpty, "\(out)")
        XCTAssertEqual(buttonEvents(out).count, 2)
    }

    // MARK: - Typing scenarios end to end (amendment F through the engine)

    private typealias KeyTouch = (code: UInt16, down: TimeInterval, up: TimeInterval)

    private static func stamp(_ code: UInt16, _ down: Bool, _ t: TimeInterval) -> String {
        "\(down ? "+" : "-")\(code)@\(String(format: "%.3f", t))"
    }

    /// Plays key touches (key centres, radius 10) through the engine the way the surface does:
    /// `advance(to:)` only at `nextDeadline` (the one-shot timer), touches at their own times.
    /// Returns "+code@t" / "-code@t" and checks that a bare `KeyCommitPipeline` driven by its own
    /// `nextDeadline` gives exactly the same timeline, so the engine honours every pipeline
    /// deadline (confirmations, tap waits, bounce followers, late-modifier waits, stale rests).
    private func playKeys(_ touches: [KeyTouch], _ typing: TypingSettings = TypingSettings(),
                          tail: TimeInterval = 1.5, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        var steps: [(t: TimeInterval, seq: Int, index: Int, down: Bool)] = []
        for (i, touch) in touches.enumerated() {
            steps.append((touch.down, 2 * i, i, true))
            steps.append((touch.up, 2 * i + 1, i, false))
        }
        steps.sort { $0.t == $1.t ? $0.seq < $1.seq : $0.t < $1.t }
        let end = (steps.last?.t ?? 0) + tail

        var e = engine(typing: typing)
        var timed: [String] = []
        var held = Set<UInt16>()
        func record(_ t: TimeInterval, _ out: [PadInput]) {
            for case .key(let code, let down) in out {
                if down {
                    XCTAssertTrue(held.insert(code).inserted, "double down \(code)", file: file, line: line)
                } else {
                    XCTAssertNotNil(held.remove(code), "up without down \(code)", file: file, line: line)
                }
                timed.append(Self.stamp(code, down, t))
            }
        }
        func drain(before t: TimeInterval) {
            var guardCount = 0
            while let d = e.nextDeadline, d < t, guardCount < 10_000 {
                record(d, e.advance(to: d))
                guardCount += 1
            }
        }
        for s in steps {
            drain(before: s.t)
            let sample = key(touches[s.index].code, id: s.index + 1)
            record(s.t, s.down ? e.begin([sample], at: s.t) : e.end([sample], at: s.t))
        }
        drain(before: end)
        record(end, e.advance(to: end))
        XCTAssertTrue(held.isEmpty, "still held \(held)", file: file, line: line)
        XCTAssertTrue(e.heldKeyCodes.isEmpty, file: file, line: line)
        XCTAssertFalse(e.hasActiveContacts, file: file, line: line)

        var p = KeyCommitPipeline(settings: typing, confirmationDelay: 0.045)
        var reference: [String] = []
        func note(_ t: TimeInterval, _ out: [PipelineOutput]) {
            for case .key(let code, let down) in out { reference.append(Self.stamp(code, down, t)) }
        }
        func drainPipeline(before t: TimeInterval) {
            var guardCount = 0
            while let d = p.nextDeadline, d < t, guardCount < 10_000 {
                note(d, p.advance(to: d))
                guardCount += 1
            }
        }
        for s in steps {
            drainPipeline(before: s.t)
            note(s.t, s.down ? p.land(id: s.index, code: touches[s.index].code, at: s.t) : p.lift(id: s.index, at: s.t))
        }
        drainPipeline(before: end)
        note(end, p.advance(to: end))
        XCTAssertEqual(timed, reference, "engine and pipeline timelines differ", file: file, line: line)
        return timed
    }

    private static let bothHands: [UInt16] = [3, 38, 2, 40, 1, 37, 0, 41]

    private func resting(_ codes: [UInt16], from start: TimeInterval, spacing: TimeInterval = 0.01,
                         until end: TimeInterval) -> [KeyTouch] {
        codes.enumerated().map { ($0.element, start + Double($0.offset) * spacing, end + Double($0.offset) * 0.01) }
    }

    func testRestingHandsAreSilentEndToEnd() {
        let fingers = Self.bothHands + [49, 49]
        for n in [4, 8, 9, 10] {
            for spacing in [0.01, 0.03, 0.4] {
                let touches: [KeyTouch] = (0..<n).map { i in
                    (fingers[i], Double(i) * spacing, Double(i) * spacing + 5.0 + Double(n - i) * 0.01)
                }
                XCTAssertEqual(playKeys(touches), [], "\(n) fingers, spacing \(spacing)")
            }
        }
        // The user's configuration: left Command is a tap-only key; a thumb resting on it is silent.
        let thumb: [KeyTouch] = resting(Self.bothHands, from: 0, until: 3) + [(55, 0.5, 3.2)]
        XCTAssertEqual(playKeys(thumb, TypingSettings(tapOnlyCodes: [55])), [])
    }

    func testTapOnlyLeftCommandTapEndToEnd() {
        let user = TypingSettings(tapOnlyCodes: [55])
        XCTAssertEqual(playKeys([(55, 0, 0.12)], user), ["+55@0.120", "-55@0.120"], "down+up at the lift")
        let amongHands: [KeyTouch] = resting(Self.bothHands, from: 0, until: 3) + [(49, 0.05, 3.0), (55, 1.0, 1.2)]
        XCTAssertEqual(playKeys(amongHands, user), ["+55@1.200", "-55@1.200"])
        for held in [0.31, 1.0, 3.0] {
            XCTAssertEqual(playKeys([(55, 0, held)], user), [], "a rest of \(held) s")
        }
        // A tap-only tap never chords: typing beside a resting left Command stays plain. (H, which
        // landed during the thumb's tap window, waits in landing order until the thumb's contact
        // outlives tapMax at 0.30 s and is a rest.)
        XCTAssertEqual(playKeys([(55, 0, 2.0), (4, 0.1, 0.16), (14, 0.5, 0.56)], user),
                       ["+4@0.300", "-4@0.300", "+14@0.545", "-14@0.560"])
    }

    func testCmdTabEndToEnd() {
        XCTAssertEqual(playKeys([(55, 0, 3.5), (48, 3.0, 3.08)]),
                       ["+55@3.045", "+48@3.045", "-48@3.080", "-55@3.500"], "Cmd held 3 s, then Tab")
        var repeated: [KeyTouch] = resting([38, 40, 37, 41], from: 0, until: 3) + [(49, 0.05, 3.0), (55, 1.0, 2.5)]
        for start in [1.2, 1.5, 1.8] { repeated.append((48, start, start + 0.08)) }
        let timed = playKeys(repeated)
        XCTAssertEqual(timed.filter { $0.hasPrefix("+55") }, ["+55@1.245"], "one Cmd down, before the first Tab")
        XCTAssertEqual(timed.filter { $0.hasPrefix("+48") }.count, 3)
        XCTAssertEqual(timed.last, "-55@2.500")
    }

    func testFastCapitalsEndToEnd() {
        XCTAssertEqual(playKeys([(56, 0, 0.16), (38, 0.03, 0.18), (0, 0.06, 0.20), (2, 0.09, 0.22)]),
                       ["+56@0.180", "+38@0.180", "-38@0.180", "+0@0.200", "-0@0.200",
                        "+2@0.220", "-2@0.220", "-56@0.220"])
        // Shift landing 25 ms after the letter (a waits for Shift: the late-modifier deadline).
        let late = playKeys([(0, 0, 0.10), (56, 0.025, 0.15)])
        XCTAssertEqual(late.filter { $0.hasPrefix("+") }.map { $0.prefix(3) }, ["+56", "+0@"], "\(late)")
        // Shift lifting just before the letter lifts.
        let lifted = playKeys([(56, 0, 0.08), (0, 0.03, 0.11)])
        XCTAssertEqual(lifted.filter { $0.hasPrefix("+") }.map { $0.prefix(3) }, ["+56", "+0@"], "\(lifted)")
    }

    func testThumbBounceDeadlinesEndToEnd() {
        // Very short tap-only and Space taps wait on the bounce follower and settle checks; the
        // engine's timer must land on each of those pipeline deadlines (checked by playKeys).
        let user = TypingSettings(tapOnlyCodes: [55])
        _ = playKeys([(55, 0, 0.03), (49, 0.05, 0.12)], user)
        _ = playKeys([(55, 0, 0.03), (49, 0.05, 1.0)], user)
        _ = playKeys([(55, 0, 0.03), (55, 0.06, 0.15)], user)
        let space: [KeyTouch] = [(49, 0, 0.04), (49, 0.07, 0.6)]
        _ = playKeys(space + resting(Self.bothHands, from: 0.02, until: 2))
        let tapBeforeBurst: [KeyTouch] = [(55, 0.01, 0.05), (4, 0.3, 0.36)]
        _ = playKeys(resting([3, 2, 1], from: 0, until: 1.5) + tapBeforeBurst, user)
    }

    // MARK: - Trackpad acceptance (F09, F16, F21)

    func testInstantAcceptRadius10MovesImmediately() {
        var e = engine()
        XCTAssertEqual(e.begin([pad()], at: 0), [.contacts(1)])
        let out = e.move([pad(dx: 10)], at: 0.008)
        XCTAssertEqual(out.count, 1)
        let m = motion(out)
        XCTAssertEqual(m?.dx ?? 0, 10 / ppm, accuracy: 1e-6)
        XCTAssertEqual(m?.dt ?? 0, 0.008, accuracy: 1e-9)
    }

    func testCoalescedSamplesSumToOneMotion() {
        var e = engine()
        var out = e.begin([pad()], at: 0)
        for k in 1...12 { out += e.move([pad(dx: CGFloat(2 * k))], at: Double(k) / 240) }
        let merged = PadInput.coalesced(out)
        XCTAssertEqual(merged.count, 2, "\(merged)")
        XCTAssertEqual(merged.first, .contacts(1))
        let m = motion(merged)
        XCTAssertEqual(m?.dt ?? 0, 0.05, accuracy: 1e-9)
        XCTAssertEqual(m?.dx ?? 0, 24 / ppm, accuracy: 1e-6)
    }

    func testRadius28WaitsNoRetroactive() {
        var e = engine()
        XCTAssertEqual(e.begin([pad(radius: 28)], at: 0), [])
        XCTAssertEqual(e.nextDeadline ?? 0, 0.045, accuracy: 1e-9)
        XCTAssertEqual(e.indicators.map(\.disposition), [.pending])
        XCTAssertEqual(e.move([pad(dx: 12, radius: 28)], at: 0.02), [])
        XCTAssertEqual(e.advance(to: 0.0449), [])
        XCTAssertEqual(e.advance(to: 0.045), [.contacts(1)])
        XCTAssertEqual(e.indicators.map(\.disposition), [.accepted])
        XCTAssertEqual(motion(e.move([pad(dx: 20, radius: 28)], at: 0.06))?.dx ?? 0, 8 / ppm, accuracy: 1e-6)

        // Strict sensitivity confirms radius 20 late too (instant only up to 18 pt).
        var strict = engine(protection: TouchProtectionSettings(sensitivity: .strict))
        XCTAssertEqual(strict.begin([pad(radius: 20)], at: 0), [])
        XCTAssertEqual(strict.advance(to: 0.045), [.contacts(1)])

        // Protection off: everything is instant and no size rule applies.
        var unprotected = engine(protection: TouchProtectionSettings(enabled: false))
        XCTAssertEqual(unprotected.begin([pad(radius: 100)], at: 0), [.contacts(1)])
        XCTAssertNotNil(motion(unprotected.move([pad(dx: 20, radius: 100)], at: 0.01)))
        XCTAssertEqual(unprotected.begin([key(0, id: 2, radius: 100)], at: 0.5), [.key(code: 0, down: true)])
    }

    func testShortPendingFingertipTapStillClicks() {
        var e = engine()
        XCTAssertEqual(e.begin([pad(radius: 28)], at: 0), [])
        XCTAssertEqual(e.end([pad(radius: 28)], at: 0.04), [
            .contacts(1), .contacts(0), .button(button: .left, down: true, clickState: 1),
            .button(button: .left, down: false, clickState: 1)
        ])
        XCTAssertFalse(e.hasActiveContacts)
        // A pending contact that slid before lifting is no tap, and its motion is never replayed.
        var slid = engine()
        _ = slid.begin([pad(radius: 28)], at: 0)
        _ = slid.move([pad(dx: 20, radius: 28)], at: 0.02)
        XCTAssertEqual(slid.end([pad(dx: 20, radius: 28)], at: 0.04), [])
        // A cancelled one is dropped too.
        var cancelled = engine()
        _ = cancelled.begin([pad(radius: 28)], at: 0)
        XCTAssertEqual(cancelled.end([pad(radius: 28)], at: 0.04, cancelled: true), [])
    }

    func testOversizedTrackpadContactsRejected() {
        // Broad above the bottom 20 mm, or bigger than a thumb anywhere.
        for sample in [padMM(id: 1, x: 64, y: 30, radius: 50), padMM(id: 1, x: 64, y: 72, radius: 90)] {
            var e = engine()
            XCTAssertEqual(e.begin([sample], at: 0), [])
            XCTAssertEqual(e.advance(to: 0.1), [])
            XCTAssertEqual(e.end([sample], at: 0.15), [])
        }
        // A fingertip that grows into a palm while pointing stops driving the pointer.
        var e = engine()
        _ = e.begin([pad()], at: 0)
        XCTAssertNotNil(motion(e.move([pad(dx: 10)], at: 0.02)))
        XCTAssertEqual(e.move([pad(dx: 20, radius: 60)], at: 0.04), [.contacts(0)])
        XCTAssertEqual(e.move([pad(dx: 40, radius: 10)], at: 0.06), [])
        XCTAssertEqual(e.indicators.map(\.disposition), [.rejected])
        XCTAssertEqual(e.end([pad(dx: 40)], at: 0.1), [])
    }

    func testTwoBroadPadContactsRejected() {
        let b1 = padMM(id: 1, x: 50, y: 72, radius: 50), b2 = padMM(id: 2, x: 80, y: 72, radius: 50)
        // Control: one broad thumb tap clicks.
        var single = engine()
        _ = single.begin([b1], at: 0)
        XCTAssertEqual(single.advance(to: 0.05), [])
        XCTAssertEqual(single.end([b1], at: 0.2), [
            .button(button: .left, down: true, clickState: 1), .button(button: .left, down: false, clickState: 1)
        ])

        var pending = engine()
        _ = pending.begin([b1], at: 0)
        _ = pending.begin([b2], at: 0.01)
        XCTAssertEqual(pending.indicators.map(\.disposition), [.rejected, .rejected])
        XCTAssertNil(pending.nextDeadline)
        XCTAssertEqual(pending.advance(to: 0.1), [])
        XCTAssertEqual(pending.end([b1, b2], at: 0.15), [])

        var forwarded = engine()
        _ = forwarded.begin([b1], at: 0)
        XCTAssertEqual(forwarded.advance(to: 0.05), [])
        XCTAssertEqual(forwarded.begin([b2], at: 0.1), [])
        XCTAssertEqual(forwarded.advance(to: 0.15), [])
        XCTAssertEqual(forwarded.end([b1, b2], at: 0.2), [], "no thumb click once both are rejected")
    }

    func testThreeBroadPadContactsRejected() {
        let b1 = padMM(id: 1, x: 40, y: 72, radius: 50), b2 = padMM(id: 2, x: 70, y: 72, radius: 50)
        let b3 = padMM(id: 3, x: 100, y: 72, radius: 50)
        var e = engine()
        var outputs: [PadInput] = []
        outputs += e.begin([b1], at: 0)
        outputs += e.begin([b2], at: 0.01)
        outputs += e.begin([b3], at: 0.02)
        outputs += e.advance(to: 0.1)
        XCTAssertEqual(e.indicators.map(\.disposition), [.rejected, .rejected, .rejected])
        outputs += e.end([b3], at: 0.2)
        outputs += e.end([b1, b2], at: 0.3)
        XCTAssertEqual(outputs, [])

        // The first broad contact lifting leaves the second one counting.
        var lifted = engine()
        _ = lifted.begin([b1], at: 0)
        _ = lifted.begin([b2], at: 0.01)
        XCTAssertEqual(lifted.end([b1], at: 0.1), [])
        XCTAssertEqual(lifted.begin([b3], at: 0.5), [])
        XCTAssertEqual(lifted.advance(to: 0.6), [])
        XCTAssertEqual(lifted.end([b3], at: 0.7), [])

        // Both palm heels resting in the corners, then a central thumb tap: a resting hand.
        var heels = engine()
        _ = heels.begin([padMM(id: 1, x: 5, y: 75, radius: 50)], at: 0)
        _ = heels.begin([padMM(id: 2, x: 122, y: 75, radius: 50)], at: 0.01)
        let thumb = padMM(id: 3, x: 64, y: 74, radius: 40)
        XCTAssertEqual(heels.begin([thumb], at: 0.5), [])
        XCTAssertEqual(heels.advance(to: 0.6), [])
        XCTAssertEqual(heels.end([thumb], at: 0.7), [])
    }

    func testBroadContactThatGrewOrLandedSuppressedStillCounts() {
        let newcomer = padMM(id: 2, x: 80, y: 74, radius: 50)
        // A heel that lands as an instant fingertip and then grows is broad from then on.
        var grown = engine()
        var outputs = grown.begin([padMM(id: 1, x: 40, y: 72, radius: 20)], at: 0)
        outputs += grown.move([padMM(id: 1, x: 40, y: 72, radius: 55)], at: 0.03)
        outputs += grown.begin([newcomer], at: 0.2)
        XCTAssertEqual(grown.indicators.map(\.disposition), [.rejected, .rejected])
        outputs += grown.advance(to: 0.3)
        outputs += grown.end([newcomer], at: 0.35)
        XCTAssertTrue(buttonEvents(outputs).isEmpty, "\(outputs)")

        // A broad contact that landed while input was suppressed still counts afterwards.
        var suppressed = engine()
        _ = suppressed.setInputSuppressed(true)
        outputs = suppressed.begin([padMM(id: 1, x: 40, y: 72, radius: 50)], at: 0)
        outputs += suppressed.setInputSuppressed(false)
        outputs += suppressed.begin([newcomer], at: 0.5)
        outputs += suppressed.advance(to: 0.6)
        outputs += suppressed.end([newcomer], at: 0.65)
        XCTAssertEqual(outputs, [])

        // A fingertip growing broad next to an accepted thumb rejects both.
        var both = engine()
        _ = both.begin([newcomer], at: 0)
        _ = both.advance(to: 0.05)
        _ = both.begin([padMM(id: 1, x: 40, y: 72, radius: 30)], at: 0.1)
        XCTAssertEqual(both.indicators.map(\.disposition), [.pending, .accepted])
        _ = both.move([padMM(id: 1, x: 40, y: 72, radius: 55)], at: 0.12)
        XCTAssertEqual(both.indicators.map(\.disposition), [.rejected, .rejected])
        XCTAssertTrue(buttonEvents(both.end([newcomer], at: 0.2)).isEmpty)
    }

    func testQuickTwoFingerTapWithPendingFingersRightClicks() {
        let right: [PadInput] = [.button(button: .right, down: true, clickState: 1),
                                 .button(button: .right, down: false, clickState: 1)]
        // Every mix of instant (10) and pending (28) fingers, landing together or 5 ms apart,
        // lifting together or 10 ms apart in either order, before or after confirmation.
        for (ra, rb) in [(28.0, 28.0), (10.0, 28.0), (28.0, 10.0)] {
            for bDown in [0.0, 0.005] {
                for liftAt in [0.02, 0.035, 0.06, 0.1] {
                    for pattern in 0..<5 {
                        let a = padMM(id: 1, x: 55, y: 40, radius: ra), b = padMM(id: 2, x: 75, y: 40, radius: rb)
                        var e = engine()
                        var outputs = e.begin(bDown == 0 ? [a, b] : [a], at: 0)
                        if bDown > 0 { outputs += e.begin([b], at: bDown) }
                        switch pattern {
                        case 0: outputs += e.end([a, b], at: liftAt)
                        case 1: outputs += e.end([b, a], at: liftAt)
                        case 2: outputs += e.end([a], at: liftAt); outputs += e.end([b], at: liftAt + 0.01)
                        case 3: outputs += e.end([b], at: liftAt); outputs += e.end([a], at: liftAt + 0.01)
                        default: outputs += e.end([a], at: liftAt); outputs += e.end([b], at: liftAt + 0.05)
                        }
                        outputs += e.advance(to: 1)
                        XCTAssertEqual(buttonEvents(outputs), right,
                                       "radii \(ra)/\(rb) b at \(bDown) lift \(liftAt) pattern \(pattern): \(outputs)")
                        XCTAssertFalse(e.hasActiveContacts)
                    }
                }
            }
        }

        // Strict sensitivity: radius 22 fingertips are pending (instant only up to 18 pt).
        var strict = engine(protection: TouchProtectionSettings(sensitivity: .strict))
        let a = padMM(id: 1, x: 55, y: 40, radius: 22), b = padMM(id: 2, x: 75, y: 40, radius: 22)
        var outputs = strict.begin([a], at: 0)
        outputs += strict.begin([b], at: 0.005)
        outputs += strict.end([a], at: 0.03)
        outputs += strict.end([b], at: 0.04)
        XCTAssertEqual(buttonEvents(outputs), right, "\(outputs)")

        // A pending fingertip that slid 10 mm and lifted first: still a two-finger touch, so the
        // other finger's lift is no click (it used to be dropped, leaving a left click).
        var slid = engine()
        _ = slid.begin([a, padMM(id: 2, x: 75, y: 40, radius: 28)], at: 0)
        _ = slid.move([padMM(id: 2, x: 85, y: 40, radius: 28)], at: 0.02)
        outputs = slid.end([padMM(id: 2, x: 85, y: 40, radius: 28)], at: 0.03)
        outputs += slid.end([a], at: 0.035)
        outputs += slid.advance(to: 1)
        XCTAssertTrue(buttonEvents(outputs).isEmpty, "\(outputs)")
        XCTAssertFalse(slid.hasActiveContacts)
    }

    /// W2FIX-ENGINE refix: a quick two-finger touch whose pending fingertip slid past the slop
    /// before lifting never clicks the primary button (it used to reach the recognizer as one
    /// still finger: a left click), in every lift order, with the other finger instant or pending.
    func testTwoFingerTouchWithSlidPendingFingerNeverLeftClicks() {
        for ra in [10.0, 28.0] {
            for slide in [1.6, 2.5, 6.0] {
                for pattern in 0..<3 {
                    let a = padMM(id: 1, x: 55, y: 40, radius: ra)
                    let b0 = padMM(id: 2, x: 75, y: 40, radius: 28), b1 = padMM(id: 2, x: 75 + slide, y: 40, radius: 28)
                    var e = engine()
                    var outputs = e.begin([a, b0], at: 0)
                    outputs += e.move([b1], at: 0.015)
                    switch pattern {
                    case 0: outputs += e.end([a, b1], at: 0.035)
                    case 1: outputs += e.end([b1], at: 0.03); outputs += e.end([a], at: 0.035)
                    default: outputs += e.end([b1], at: 0.03); outputs += e.end([a], at: 0.12)
                    }
                    outputs += e.advance(to: 1)
                    let label = "radius \(ra) slide \(slide) pattern \(pattern): \(outputs)"
                    XCTAssertTrue(buttonEvents(outputs).isEmpty, label)
                    XCTAssertFalse(e.hasActiveContacts, label)
                }
            }
        }
        // A wobble within the two-finger slop is still one secondary click.
        var wobble = engine()
        var outputs = wobble.begin([padMM(id: 1, x: 55, y: 40, radius: 10), padMM(id: 2, x: 75, y: 40, radius: 28)], at: 0)
        outputs += wobble.move([padMM(id: 2, x: 76.2, y: 40, radius: 28)], at: 0.015)
        outputs += wobble.end([padMM(id: 1, x: 55, y: 40, radius: 10), padMM(id: 2, x: 76.2, y: 40, radius: 28)], at: 0.035)
        XCTAssertEqual(buttonEvents(outputs), [.button(button: .right, down: true, clickState: 1),
                                               .button(button: .right, down: false, clickState: 1)], "\(outputs)")
        // A lone pending fingertip that slid is still dropped: no click, no motion.
        var lone = engine()
        _ = lone.begin([padMM(id: 1, x: 55, y: 40, radius: 28)], at: 0)
        _ = lone.move([padMM(id: 1, x: 57, y: 40, radius: 28)], at: 0.015)
        XCTAssertEqual(lone.end([padMM(id: 1, x: 57, y: 40, radius: 28)], at: 0.035), [])
    }

    /// W2FIX-ENGINE refix: a quick three-finger tap whose pending fingertip wobbled 1.5-2.0 mm
    /// (within the recognizer's three-finger slop) is still one Look Up tap, not a secondary
    /// click; past the slop it is neither.
    func testThreeFingerTapWithWobblingPendingFingerIsStillLookUp() {
        let lookUp = PadInput.gesture(WireGesture(kind: .tap, fingers: 3))
        func gestures(_ out: [PadInput]) -> [PadInput] {
            out.filter { if case .gesture = $0 { return true } else { return false } }
        }
        for wobble in [1.7, 1.9, 2.5] {
            for radii in [[10.0, 10.0, 28.0], [28.0, 10.0, 28.0], [28.0, 28.0, 28.0]] {
                for together in [true, false] {
                    let xs = [45.0, 65.0, 85.0]
                    let down = (0..<3).map { padMM(id: $0 + 1, x: xs[$0], y: 40, radius: radii[$0]) }
                    var lifted = down
                    lifted[2] = padMM(id: 3, x: 85 + wobble, y: 40, radius: radii[2])
                    var e = engine()
                    var outputs = e.begin(down, at: 0)
                    outputs += e.move([lifted[2]], at: 0.015)
                    if together {
                        outputs += e.end(lifted, at: 0.035)
                    } else {
                        outputs += e.end([lifted[2]], at: 0.03)
                        outputs += e.end([lifted[0], lifted[1]], at: 0.035)
                    }
                    outputs += e.advance(to: 1)
                    let label = "wobble \(wobble) radii \(radii) together \(together): \(outputs)"
                    XCTAssertTrue(buttonEvents(outputs).isEmpty, label)
                    XCTAssertEqual(gestures(outputs), wobble < 2.0 ? [lookUp] : [], label)
                    XCTAssertFalse(e.hasActiveContacts, label)
                }
            }
        }
    }

    /// W2FIX-ENGINE refix: travel a pending fingertip made before its 45 ms confirmation counts
    /// for the recognizer's decisions (a slid two-finger touch is no secondary click; a slid
    /// finger is no hold-to-drag), but is never replayed as pointer or scroll motion.
    func testPreConfirmationTravelCountsForTapsButIsNotReplayed() {
        let a = padMM(id: 1, x: 55, y: 40, radius: 10)
        let b0 = padMM(id: 2, x: 75, y: 40, radius: 28), b1 = padMM(id: 2, x: 77.5, y: 40, radius: 28)
        var e = engine()
        var outputs = e.begin([a, b0], at: 0)
        outputs += e.move([b1], at: 0.02)
        let confirm = e.advance(to: 0.045)
        outputs += confirm
        outputs += e.end([a, b1], at: 0.08)
        outputs += e.advance(to: 1)
        XCTAssertTrue(buttonEvents(outputs).isEmpty, "\(outputs)")
        XCTAssertNil(motion(outputs))
        for case .scroll(let s) in outputs {
            XCTAssertEqual(s.dx, 0, "\(outputs)")
            XCTAssertEqual(s.dy, 0, "\(outputs)")
        }
        // Control: the same touch with B instant is no click either.
        var instant = engine()
        outputs = instant.begin([a, padMM(id: 2, x: 75, y: 40, radius: 10)], at: 0)
        outputs += instant.move([padMM(id: 2, x: 77.5, y: 40, radius: 10)], at: 0.02)
        outputs += instant.end([a, padMM(id: 2, x: 77.5, y: 40, radius: 10)], at: 0.08)
        XCTAssertTrue(buttonEvents(outputs).isEmpty, "\(outputs)")

        // Hold-to-drag: a lone pending finger that slid 3 mm before confirmation and then holds
        // still is pointing, not a press-and-hold; one that stayed still does press.
        for (slide, presses) in [(3.0, false), (0.0, true)] {
            var drag = engine(trackpad: TrackpadSettings(dragStyle: .holdToDrag))
            outputs = drag.begin([padMM(id: 1, x: 60, y: 40, radius: 28)], at: 0)
            outputs += drag.move([padMM(id: 1, x: 60 + slide, y: 40, radius: 28)], at: 0.03)
            outputs += drag.advance(to: 1)
            XCTAssertNil(motion(outputs), "no retroactive pointer jump")
            XCTAssertEqual(!buttonEvents(outputs).isEmpty, presses, "slide \(slide): \(outputs)")
            outputs += drag.end([padMM(id: 1, x: 60 + slide, y: 40, radius: 28)], at: 1.1)
            XCTAssertTrue(drag.heldButtons.isEmpty)
        }
    }

    /// W2FIX-ENGINE refix: a broad trackpad contact already down when input is suppressed, or
    /// when the panel hold opens the panel, keeps counting for the two-broad-contacts rule until
    /// it lifts, so a thumb tap next to it afterwards is no click.
    func testBroadContactDownAcrossSuppressionOrPanelStillCounts() {
        let heel = padMM(id: 1, x: 40, y: 72, radius: 50)
        let thumb = padMM(id: 2, x: 80, y: 74, radius: 50)
        func thumbTap(_ e: inout DeckInputEngine, at t: TimeInterval) -> [PadInput] {
            var out = e.begin([thumb], at: t)
            out += e.advance(to: t + 0.06)
            out += e.end([thumb], at: t + 0.15)
            return out
        }
        // Control: the thumb alone clicks after a suppress toggle.
        var control = engine()
        _ = control.setInputSuppressed(true)
        _ = control.setInputSuppressed(false)
        XCTAssertFalse(buttonEvents(thumbTap(&control, at: 1.0)).isEmpty)

        var suppressed = engine()
        _ = suppressed.begin([heel], at: 0)
        XCTAssertEqual(suppressed.setInputSuppressed(true), [.releaseAll])
        XCTAssertEqual(suppressed.indicators.map(\.disposition), [.rejected])
        XCTAssertEqual(suppressed.setInputSuppressed(false), [])
        XCTAssertEqual(thumbTap(&suppressed, at: 1.0), [])
        XCTAssertEqual(suppressed.end([heel], at: 1.2), [])
        XCTAssertFalse(suppressed.hasActiveContacts)
        XCTAssertFalse(buttonEvents(thumbTap(&suppressed, at: 2.0)).isEmpty, "the heel lifted: a thumb tap clicks again")

        // A trackpad fingertip down across suppression that grows broad later still counts.
        var grows = engine()
        _ = grows.begin([padMM(id: 1, x: 40, y: 72, radius: 10)], at: 0)
        _ = grows.setInputSuppressed(true)
        _ = grows.setInputSuppressed(false)
        XCTAssertEqual(grows.move([heel], at: 0.5), [])
        XCTAssertEqual(thumbTap(&grows, at: 1.0), [])

        // The Touch ID hold opening the panel keeps it too.
        var panel = engine()
        _ = panel.begin([heel], at: 0)
        _ = panel.begin([touchID(id: 3)], at: 0.1)
        XCTAssertEqual(panel.advance(to: 0.7), [.releaseAll])
        XCTAssertEqual(panel.drainSignals(), [.openPanel])
        XCTAssertEqual(panel.end([touchID(id: 3)], at: 0.8), [])
        XCTAssertEqual(thumbTap(&panel, at: 1.0), [])
        XCTAssertEqual(panel.end([heel], at: 1.2), [])
        XCTAssertFalse(panel.hasActiveContacts)

        // reset() is for a caller that forgets its touches: it keeps nothing.
        var reset = engine()
        _ = reset.begin([heel], at: 0)
        XCTAssertEqual(reset.reset(), [.releaseAll])
        XCTAssertFalse(reset.hasActiveContacts)
    }

    /// Fix2 probe (a): with strict sensitivity, fingertips of radius 19-26 pt are pending (instant
    /// only up to 18). Every quick two-finger tap with one or both of them pending, landing
    /// together or staggered, lifting together or staggered in either order, before or after
    /// confirmation, is exactly one secondary click and never a left click.
    func testQuickTwoFingerTapStrictPendingGridIsOneSecondaryClick() {
        let right: [PadInput] = [.button(button: .right, down: true, clickState: 1),
                                 .button(button: .right, down: false, clickState: 1)]
        let strict = TouchProtectionSettings(sensitivity: .strict)
        for (ra, rb) in [(22.0, 22.0), (10.0, 22.0), (22.0, 10.0), (19.0, 26.0), (26.0, 26.0)] {
            for bDown in [0.0, 0.005, 0.03] {
                for liftAfter in [0.015, 0.03, 0.05, 0.1] {
                    for pattern in 0..<5 {
                        let a = padMM(id: 1, x: 55, y: 40, radius: ra), b = padMM(id: 2, x: 75, y: 40, radius: rb)
                        let liftAt = bDown + liftAfter
                        var e = engine(protection: strict)
                        var outputs = e.begin(bDown == 0 ? [a, b] : [a], at: 0)
                        if bDown > 0 { outputs += e.advance(to: bDown) + e.begin([b], at: bDown) }
                        switch pattern {
                        case 0: outputs += e.end([a, b], at: liftAt)
                        case 1: outputs += e.end([b, a], at: liftAt)
                        case 2: outputs += e.end([a], at: liftAt); outputs += e.end([b], at: liftAt + 0.01)
                        case 3: outputs += e.end([b], at: liftAt); outputs += e.end([a], at: liftAt + 0.01)
                        default: outputs += e.end([a], at: liftAt); outputs += e.end([b], at: liftAt + 0.04)
                        }
                        outputs += e.advance(to: 1)
                        XCTAssertEqual(buttonEvents(outputs), right,
                                       "radii \(ra)/\(rb) b at \(bDown) lift \(liftAt) pattern \(pattern): \(outputs)")
                        XCTAssertFalse(e.hasActiveContacts)
                    }
                }
            }
        }
    }

    /// Fix2 probe (a), three fingers: a quick three-finger tap with any of its fingertips still
    /// pending is exactly one Look Up tap, never a click (strict and balanced sensitivity).
    func testQuickThreeFingerTapWithPendingFingersIsOneLookUp() {
        let lookUp = PadInput.gesture(WireGesture(kind: .tap, fingers: 3))
        let xs = [45.0, 65.0, 85.0]
        for (protection, pending) in [(TouchProtectionSettings(sensitivity: .strict), 22.0),
                                      (TouchProtectionSettings(), 28.0)] {
            for mask in 0..<8 {
                let radii = (0..<3).map { mask & (1 << $0) != 0 ? pending : 10.0 }
                for stagger in [0.0, 0.006] {
                    for liftAfter in [0.02, 0.05, 0.12] {
                        for pattern in 0..<3 {
                            let fingers = (0..<3).map { padMM(id: $0 + 1, x: xs[$0], y: 40, radius: radii[$0]) }
                            var e = engine(protection: protection)
                            var outputs: [PadInput] = []
                            for (i, f) in fingers.enumerated() { outputs += e.begin([f], at: Double(i) * stagger) }
                            let liftAt = 2 * stagger + liftAfter
                            switch pattern {
                            case 0: outputs += e.end(fingers, at: liftAt)
                            case 1: for (i, f) in fingers.enumerated() { outputs += e.end([f], at: liftAt + Double(i) * 0.008) }
                            default: for (i, f) in fingers.reversed().enumerated() { outputs += e.end([f], at: liftAt + Double(i) * 0.008) }
                            }
                            outputs += e.advance(to: 1)
                            let label = "\(protection.sensitivity) radii \(radii) stagger \(stagger) lift \(liftAt) pattern \(pattern): \(outputs)"
                            XCTAssertEqual(outputs.filter { if case .gesture = $0 { return true } else { return false } }, [lookUp], label)
                            XCTAssertTrue(buttonEvents(outputs).isEmpty, label)
                            XCTAssertFalse(e.hasActiveContacts)
                        }
                    }
                }
            }
        }
    }

    /// Fix2 probe (b): broad contacts that were rejected for another reason still count for the
    /// two-broad-contacts rule: one that grew broad while still pending, one that landed during
    /// the typing pause, and one too large even for a thumb.
    func testBroadContactsRejectedForOtherReasonsStillCount() {
        let thumb = padMM(id: 2, x: 80, y: 74, radius: 50)
        func thumbTapClicks(_ e: inout DeckInputEngine, at t: TimeInterval) -> Bool {
            var out = e.begin([thumb], at: t)
            out += e.advance(to: t + 0.06)
            out += e.end([thumb], at: t + 0.15)
            return !buttonEvents(out).isEmpty
        }
        // Control: a thumb tap alone clicks.
        var control = engine()
        XCTAssertTrue(thumbTapClicks(&control, at: 1))

        // A fingertip (pending, radius 30) growing broad before its confirmation.
        var grown = engine()
        _ = grown.begin([padMM(id: 1, x: 40, y: 72, radius: 30)], at: 0)
        _ = grown.move([padMM(id: 1, x: 40, y: 72, radius: 55)], at: 0.02)
        XCTAssertEqual(grown.indicators.map(\.disposition), [.rejected])
        XCTAssertFalse(thumbTapClicks(&grown, at: 1))

        // A broad heel landing during the typing pause (rejected for typing), then the thumb.
        var typing = engine(typing: TypingSettings())
        _ = typing.begin([key(14, id: 5)], at: 0)
        _ = typing.end([key(14, id: 5)], at: 0.08)
        _ = typing.begin([padMM(id: 1, x: 40, y: 72, radius: 50)], at: 0.1)
        XCTAssertFalse(thumbTapClicks(&typing, at: 1.5))

        // A contact too large even for a thumb, in the bottom zone.
        var huge = engine()
        _ = huge.begin([padMM(id: 1, x: 40, y: 72, radius: 90)], at: 0)
        XCTAssertFalse(thumbTapClicks(&huge, at: 1))

        // A fingertip outside the bottom zone never counts, broad or not.
        var high = engine()
        _ = high.begin([padMM(id: 1, x: 40, y: 30, radius: 10)], at: 0)
        _ = high.end([padMM(id: 1, x: 40, y: 30, radius: 10)], at: 0.5)
        XCTAssertTrue(thumbTapClicks(&high, at: 1.5))
    }

    func testCornerBroadPadContactIgnored() {
        var e = engine()
        var outputs: [PadInput] = []
        outputs += e.begin([pad(id: 1)], at: 0)
        let heel = padMM(id: 2, x: 5, y: 75, radius: 50)
        outputs += e.begin([heel], at: 0.05)
        outputs += e.advance(to: 0.1)
        XCTAssertEqual(e.indicators.map(\.disposition), [.accepted, .accepted])
        for step in 1...5 {
            outputs += e.move([pad(id: 1, dx: CGFloat(step * 10))], at: 0.1 + Double(step) * 0.02)
            outputs += e.move([padMM(id: 2, x: 5 + Double(step) * 0.2, y: 75, radius: 50)], at: 0.11 + Double(step) * 0.02)
        }
        outputs += e.end([heel], at: 0.4)
        outputs += e.end([pad(id: 1, dx: 50)], at: 0.5)
        let motions = outputs.filter { if case .motion = $0 { return true } else { return false } }
        XCTAssertEqual(motions.count, 5)
        XCTAssertEqual(outputs.count - motions.count, 2, "only .contacts(1) and .contacts(0) besides motion: \(outputs)")
        XCTAssertTrue(buttonEvents(outputs).isEmpty)
    }

    func testTypingSuppressesPadTap() {
        var e = engine(typing: TypingSettings())
        _ = e.begin([key(14)], at: 0)
        XCTAssertEqual(e.end([key(14)], at: 0.08), [.key(code: 14, down: true), .key(code: 14, down: false)])
        // Within 0.35 s of typing the contact is a palm: nothing at all.
        XCTAssertEqual(e.begin([pad(id: 2)], at: 0.2), [])
        XCTAssertEqual(e.move([pad(id: 2, dx: 20)], at: 0.22), [])
        XCTAssertEqual(e.end([pad(id: 2, dx: 20)], at: 0.25), [])
        // 0.4 s after the key the pointer moves but a tap does not click.
        XCTAssertEqual(e.begin([pad(id: 3)], at: 0.45), [.contacts(1)])
        XCTAssertEqual(e.end([pad(id: 3)], at: 0.5), [.contacts(0)])
        // 0.7 s after the key a tap clicks.
        XCTAssertEqual(e.begin([pad(id: 4)], at: 0.7), [.contacts(1)])
        XCTAssertEqual(e.end([pad(id: 4)], at: 0.75), [
            .contacts(0), .button(button: .left, down: true, clickState: 1),
            .button(button: .left, down: false, clickState: 1)
        ])
        // A held key also pauses the trackpad.
        _ = e.begin([key(51, id: 5)], at: 2)
        XCTAssertEqual(e.advance(to: 2.5), [.key(code: 51, down: true)])
        XCTAssertEqual(e.begin([pad(id: 6)], at: 3), [])
    }

    func testTypingRejectsPendingPadContact() {
        var e = engine()
        XCTAssertEqual(e.begin([pad(id: 1, radius: 28)], at: 0), [])
        _ = e.begin([key(14, id: 2)], at: 0)
        // The key commits at 0.045 first (lower serial), so the pending pad contact is a palm.
        XCTAssertEqual(e.advance(to: 0.1), [.key(code: 14, down: true)])
        XCTAssertEqual(e.indicators.first?.disposition, .rejected)
        XCTAssertEqual(e.move([pad(id: 1, dx: 20, radius: 28)], at: 1), [])
    }

    // MARK: - Signals, indicators, deadlines

    func testFeedbackSignals() {
        var e = engine()
        _ = e.begin([key(14)], at: 0)
        _ = e.end([key(14)], at: 0.1)
        XCTAssertEqual(e.drainSignals(), [.feedback(.tentative(14)), .feedback(.committed(14)), .feedback(.released(14))])
        XCTAssertEqual(e.drainSignals(), [])
        for i in 0..<30 {
            _ = e.begin([key(14, id: 10 + i)], at: 1 + Double(i))
            _ = e.end([key(14, id: 10 + i)], at: 1.1 + Double(i))
        }
        let signals = e.drainSignals()
        XCTAssertEqual(signals.count, 64, "capped; the oldest are dropped")
        XCTAssertEqual(signals.last, .feedback(.released(14)))
        XCTAssertEqual(signals.first, .feedback(.released(14)), "90 signals: the first 26 are dropped")
    }

    func testIndicatorsResting() {
        var e = engine(typing: TypingSettings())
        _ = e.begin([key(3, id: 1)], at: 0)
        _ = e.begin([key(38, id: 2)], at: 0.01)
        _ = e.begin([key(5, id: 3, radius: 60)], at: 0.02)
        _ = e.begin([pad(id: 4, radius: 28)], at: 0.02)
        _ = e.begin([TouchSample(id: 5, point: CGPoint(x: CGFloat.nan, y: 0), radius: 10)], at: 0.02)
        XCTAssertEqual(e.indicators.map(\.disposition), [.pending, .pending, .rejected, .pending])
        _ = e.advance(to: 0.07)
        XCTAssertEqual(e.indicators.map(\.disposition), [.pending, .pending, .rejected, .accepted])
        // Policy F: a home-row contact becomes a rest only once it outlives tapMax (0.30 s).
        _ = e.advance(to: 0.299)
        XCTAssertEqual(e.indicators.map(\.disposition), [.pending, .pending, .rejected, .accepted])
        _ = e.advance(to: 0.305)
        XCTAssertEqual(e.indicators.map(\.disposition), [.resting, .pending, .rejected, .accepted], "F landed at 0")
        _ = e.advance(to: 0.32)
        XCTAssertEqual(e.indicators.map(\.disposition), [.resting, .resting, .rejected, .accepted])
        XCTAssertEqual(e.indicators.first?.point, key(3).point)
        XCTAssertTrue(e.hasActiveContacts)
        XCTAssertTrue(e.drainSignals().contains(.feedback(.restStarted(3))))
    }

    func testNextDeadlineSchedulesTheTransition() {
        var e = engine()
        _ = e.begin([key(14)], at: 0)
        XCTAssertEqual(e.nextDeadline ?? 0, 0.045, accuracy: 1e-9)
        XCTAssertEqual(e.advance(to: 0.0449), [])
        XCTAssertEqual(e.advance(to: 0.045), [.key(code: 14, down: true)])
        XCTAssertNil(e.nextDeadline)
        // Earlier times are clamped to the engine's clock.
        XCTAssertEqual(e.end([key(14)], at: 0.01), [.key(code: 14, down: false)])
    }
}
