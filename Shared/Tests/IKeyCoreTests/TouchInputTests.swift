import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import IKeyCore

final class TouchInputTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private func engine(_ settings: TouchProtectionSettings = .init()) -> TouchInputEngine {
        TouchInputEngine(photoFrame: frame, protection: settings)
    }
    private func key(_ code: UInt16, id: Int = 1, radius: Double = 10,
                     tolerance: Double = 0) -> TouchSample {
        let layout = DeckLayout.macBookANSI
        let region = layout.keys.first { $0.keyCode == code }!
        let rect = layout.frame(for: region).rect(in: frame)
        return TouchSample(id: id, point: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                           radiusTolerance: tolerance)
    }
    private func pad(id: Int = 1, dx: CGFloat = 0, dy: CGFloat = 0, radius: Double = 10) -> TouchSample {
        let rect = DeckLayout.macBookANSI.trackpad.rect(in: frame)
        return TouchSample(id: id, point: CGPoint(x: rect.midX + dx, y: rect.midY + dy), radius: radius)
    }

    func testBroadThumbCanTapSpace() {
        var e = engine()
        let thumb = key(49, radius: 55)
        XCTAssertEqual(e.begin([thumb], at: 0), [])
        XCTAssertEqual(e.advance(to: 0.05), [])
        XCTAssertEqual(e.end([thumb], at: 0.12), [.key(code: 49, down: true), .key(code: 49, down: false)])
    }

    func testRestingBroadPalmOnSpaceDoesNotTypeOrRepeat() {
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

    func testSpaceUsesToleranceRatherThanRawRadius() {
        var e = engine()
        let thumb = key(49, radius: 80, tolerance: 10)
        _ = e.begin([thumb], at: 0)
        XCTAssertEqual(e.end([thumb], at: 0.15), [.key(code: 49, down: true), .key(code: 49, down: false)])
    }

    func testOversizedPalmOnSpaceIsRejected() {
        var e = engine()
        let palm = key(49, radius: 100)
        XCTAssertEqual(e.begin([palm], at: 0), [])
        XCTAssertEqual(e.end([palm], at: 0.1), [])
    }

    func testGrowingPalmRejectedBeforeKeyConfirmation() {
        var e = engine()
        let finger = key(0)
        _ = e.begin([finger], at: 0)
        let palm = key(0, radius: 50)
        XCTAssertEqual(e.move([palm], at: 0.045), [])
        XCTAssertEqual(e.advance(to: 0.1), [])
        XCTAssertEqual(e.end([palm], at: 0.2), [])
    }

    func testPalmRejectionSticksWhenContactShrinks() {
        var e = engine()
        _ = e.begin([key(0, radius: 50)], at: 0)
        XCTAssertEqual(e.move([key(0)], at: 0.1), [])
        XCTAssertEqual(e.end([key(0)], at: 0.2), [])
    }

    func testPalmGrowthReleasesAlreadyPressedKeyAndStopsRepeat() {
        var e = engine()
        _ = e.begin([key(0)], at: 0)
        XCTAssertEqual(e.advance(to: 0.05), [.key(code: 0, down: true)])
        XCTAssertEqual(e.move([key(0, radius: 60)], at: 0.1), [.key(code: 0, down: false)])
        XCTAssertEqual(e.advance(to: 1), [])
    }

    func testNormalQuickTapDoesNotDisappearInConfirmationWindow() {
        var e = engine()
        let tap = key(0)
        XCTAssertEqual(e.begin([tap], at: 0), [])
        XCTAssertEqual(e.end([tap], at: 0.02), [.key(code: 0, down: true), .key(code: 0, down: false)])
    }

    func testQuickChordOrdersModifierBeforeLetterAndReleasesItLast() {
        var e = engine()
        let letter = key(0, id: 1)
        let shift = key(56, id: 2)
        _ = e.begin([letter, shift], at: 0)
        XCTAssertEqual(e.end([letter, shift], at: 0.02), [
            .key(code: 56, down: true), .key(code: 0, down: true),
            .key(code: 0, down: false), .key(code: 56, down: false)
        ])
    }

    func testHeldKeysRepeatButModifierDoesNotRepeat() {
        var e = engine()
        _ = e.begin([key(0), key(56, id: 2)], at: 0)
        XCTAssertEqual(e.advance(to: 0.05), [.key(code: 56, down: true), .key(code: 0, down: true)])
        XCTAssertEqual(e.advance(to: 0.6), [.key(code: 0, down: true)])
        XCTAssertEqual(e.advance(to: 0.67), [.key(code: 0, down: true)])
        XCTAssertEqual(e.end([key(0)], at: 0.7), [.key(code: 0, down: false)])
        XCTAssertEqual(e.advance(to: 1), [])
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

    func testStaggeredBroadSpaceTapCommitsPendingShiftFirst() {
        var e = engine()
        _ = e.begin([key(56, id: 2)], at: 0)
        _ = e.begin([key(49, radius: 55)], at: 0.01)
        XCTAssertEqual(e.end([key(49, radius: 55)], at: 0.025), [
            .key(code: 56, down: true), .key(code: 49, down: true), .key(code: 49, down: false)
        ])
    }

    func testShiftLiftingBeforePendingLetterStillTypesItsChord() {
        var e = engine()
        _ = e.begin([key(56, id: 2)], at: 0)
        _ = e.begin([key(0)], at: 0.01)
        XCTAssertEqual(e.end([key(56, id: 2)], at: 0.02), [
            .key(code: 56, down: true), .key(code: 0, down: true), .key(code: 56, down: false)
        ])
        XCTAssertEqual(e.end([key(0)], at: 0.03), [.key(code: 0, down: false)])
    }

    func testSecondFingerOnSameKeyDoesNotReleaseFirstFinger() {
        var e = engine()
        _ = e.begin([key(0)], at: 0)
        _ = e.advance(to: 0.05)
        _ = e.begin([key(0, id: 2)], at: 0.1)
        XCTAssertEqual(e.advance(to: 0.15), [])
        XCTAssertEqual(e.end([key(0)], at: 0.2), [])
        XCTAssertEqual(e.end([key(0, id: 2)], at: 0.21), [.key(code: 0, down: false)])
    }

    func testCancelPendingKeyDoesNotCommitIt() {
        var e = engine()
        _ = e.begin([key(0)], at: 0)
        XCTAssertEqual(e.end([key(0)], at: 0.1, cancelled: true), [])
    }

    func testTouchStartingOnPalmRestCannotSlideIntoKey() {
        var e = engine()
        let resting = TouchSample(id: 1, point: CGPoint(x: 20, y: 700), radius: 10)
        _ = e.begin([resting], at: 0)
        XCTAssertEqual(e.move([key(0)], at: 0.1), [])
        XCTAssertEqual(e.end([key(0)], at: 0.2), [])
    }

    func testSimpleTrackpadTapClicks() {
        var e = engine()
        _ = e.begin([pad()], at: 0)
        XCTAssertEqual(e.end([pad()], at: 0.02), [.button(button: .left, down: true), .button(button: .left, down: false)])
    }

    func testTwoFingerTapRightClicksOnlyOnce() {
        var e = engine()
        let one = pad(id: 1, dx: -20)
        let two = pad(id: 2, dx: 20)
        _ = e.begin([one, two], at: 0)
        XCTAssertEqual(e.end([one], at: 0.1), [])
        XCTAssertEqual(e.end([two], at: 0.12), [.button(button: .right, down: true), .button(button: .right, down: false)])
    }

    func testTrackpadConfirmsWithoutRetroactivePointerJump() {
        var e = engine()
        _ = e.begin([pad()], at: 0)
        XCTAssertEqual(e.move([pad(dx: 12)], at: 0.02), [])
        XCTAssertEqual(e.advance(to: 0.05), [])
        XCTAssertEqual(e.move([pad(dx: 20)], at: 0.06), [.pointer(dx: 8, dy: 0)])
        XCTAssertEqual(e.end([pad(dx: 20)], at: 0.07), [])
    }

    func testTwoFingerScrollDoesNotProducePointerOrTap() {
        var e = engine()
        _ = e.begin([pad(id: 1, dx: -20), pad(id: 2, dx: 20)], at: 0)
        _ = e.advance(to: 0.05)
        let moved = [pad(id: 1, dx: -20, dy: 12), pad(id: 2, dx: 20, dy: 12)]
        XCTAssertEqual(e.move(moved, at: 0.1), [.scroll(dx: 0, dy: -12)])
        XCTAssertEqual(e.end(moved, at: 0.15), [])
    }

    func testPalmGrowthReleasesTrackpadDrag() {
        var e = engine()
        _ = e.begin([pad()], at: 0)
        XCTAssertEqual(e.advance(to: 0.4), [.button(button: .left, down: true)])
        XCTAssertEqual(e.move([pad(radius: 60)], at: 0.5), [.button(button: .left, down: false)])
        XCTAssertEqual(e.move([pad(dx: 30)], at: 0.6), [])
        XCTAssertEqual(e.end([pad()], at: 0.7), [])
    }

    func testOnePalmInTwoFingerGestureCannotCauseTailClick() {
        var e = engine()
        _ = e.begin([pad(id: 1, dx: -20), pad(id: 2, dx: 20)], at: 0)
        _ = e.advance(to: 0.05)
        XCTAssertEqual(e.move([pad(id: 2, dx: 20, radius: 60)], at: 0.1), [])
        XCTAssertEqual(e.end([pad(id: 2, dx: 20, radius: 60)], at: 0.12), [])
        XCTAssertEqual(e.end([pad(id: 1, dx: -20)], at: 0.13), [])
    }

    func testTypingCancelsDragAndSuppressesRestingTrackpadUntilLift() {
        var e = engine()
        _ = e.begin([pad(id: 2)], at: 0)
        _ = e.advance(to: 0.4)
        _ = e.begin([key(0)], at: 0.5)
        XCTAssertEqual(e.advance(to: 0.55), [.key(code: 0, down: true), .button(button: .left, down: false)])
        _ = e.end([key(0)], at: 0.6)
        XCTAssertEqual(e.move([pad(id: 2, dx: 20)], at: 1.1), [])
        XCTAssertEqual(e.end([pad(id: 2)], at: 1.2), [])
        _ = e.begin([pad(id: 3)], at: 1.3)
        XCTAssertEqual(e.end([pad(id: 3)], at: 1.4), [.button(button: .left, down: true), .button(button: .left, down: false)])
    }

    func testTrackpadBeginningDuringTypingRemainsSuppressed() {
        var e = engine()
        _ = e.begin([key(0)], at: 0)
        _ = e.advance(to: 0.05)
        XCTAssertEqual(e.begin([pad(id: 2)], at: 0.1), [])
        _ = e.end([key(0)], at: 0.15)
        XCTAssertEqual(e.move([pad(id: 2, dx: 40)], at: 1), [])
        XCTAssertEqual(e.end([pad(id: 2)], at: 1.1), [])
    }

    func testSimultaneousQuickKeyWinsOverTrackpadTap() {
        var e = engine()
        _ = e.begin([pad(id: 2), key(0)], at: 0)
        XCTAssertEqual(e.end([pad(id: 2), key(0)], at: 0.02), [.key(code: 0, down: true), .key(code: 0, down: false)])
    }

    func testModifierAloneAllowsTrackpadDrag() {
        var e = engine()
        _ = e.begin([key(55)], at: 0)
        _ = e.advance(to: 0.05)
        _ = e.begin([pad(id: 2)], at: 0.1)
        XCTAssertEqual(e.advance(to: 0.5), [.button(button: .left, down: true)])
        XCTAssertEqual(e.move([pad(id: 2, dx: 20)], at: 0.6), [.pointer(dx: 20, dy: 0)])
        XCTAssertEqual(e.end([pad(id: 2, dx: 20)], at: 0.7), [.button(button: .left, down: false)])
    }

    func testProtectionCanBeDisabledForImmediateLargeContacts() {
        var e = engine(.init(enabled: false))
        XCTAssertEqual(e.begin([key(0, radius: 100)], at: 0), [.key(code: 0, down: true)])
        _ = e.begin([pad(id: 2, radius: 100)], at: 0.1)
        XCTAssertEqual(e.move([pad(id: 2, dx: 20, radius: 100)], at: 0.2), [.pointer(dx: 20, dy: 0)])
    }

    func testResetClearsHeldInputAndRepeatState() {
        var e = engine()
        _ = e.begin([key(0), key(56, id: 2)], at: 0)
        _ = e.advance(to: 0.05)
        XCTAssertEqual(e.reset(), [.releaseAll])
        XCTAssertTrue(e.pressedKeyCodes.isEmpty)
        XCTAssertFalse(e.hasActiveContacts)
        XCTAssertEqual(e.advance(to: 1), [])
    }

    func testSensitivityAndSettingsRoundTrip() throws {
        var strict = engine(.init(sensitivity: .strict))
        var relaxed = engine(.init(sensitivity: .relaxed))
        XCTAssertEqual(strict.begin([key(0, radius: 30)], at: 0), [])
        XCTAssertEqual(strict.end([key(0, radius: 30)], at: 0.1), [])
        _ = relaxed.begin([key(0, radius: 30)], at: 0)
        XCTAssertEqual(relaxed.end([key(0, radius: 30)], at: 0.1), [.key(code: 0, down: true), .key(code: 0, down: false)])
        let settings = TouchProtectionSettings(enabled: true, sensitivity: .strict, pauseTrackpadWhileTyping: false)
        XCTAssertEqual(try JSONDecoder().decode(TouchProtectionSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
}
