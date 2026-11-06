import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import IKeyCore

/// Coordinates in these tests are millimetres from the trackpad's top-left
/// corner on a 128.2 x 80.05 mm trackpad drawn at 665.1 x 414.8 pt.
final class TrackpadRecognizerTests: XCTestCase {
    private static let geometry = TrackpadGeometry(rect: CGRect(x: 0, y: 0, width: 665.1, height: 414.8))

    // MARK: - One finger

    func testStillFingerNeverDrags2s() {
        var pad = Pad()
        pad.down(1, 64, 40, at: 0)
        var t = 0.0
        while t < 2.0 {
            t += 1.0 / 60
            pad.move(1, 64 + 0.3 * sin(t * 30), 40, at: t)
            pad.advance(t)
            XCTAssertTrue(pad.r.heldButtons.isEmpty)
        }
        pad.up(1, at: 2.05)
        XCTAssertEqual(buttons(pad.log), [])
    }

    func testTapClicksState1() {
        var pad = Pad()
        XCTAssertEqual(pad.down(1, 64, 40, at: 0), [.contacts(1)])
        XCTAssertEqual(pad.up(1, at: 0.1), [.contacts(0)] + click(1))
        XCTAssertTrue(pad.r.heldButtons.isEmpty)
    }

    func testDoubleTapState2() {
        var pad = Pad()
        pad.down(1, 64, 40, at: 0)
        XCTAssertEqual(pad.up(1, at: 0.1), [.contacts(0)] + click(1))
        pad.down(2, 64.5, 40, at: 0.25)
        XCTAssertEqual(pad.up(2, at: 0.33), [.contacts(0)] + click(2))
    }

    func testClickCountCapsAt3AndNeedsStillPointer() {
        var pad = Pad(TrackpadSettings(dragStyle: .holdToDrag))
        var states: [Int] = []
        for k in 0..<4 {
            let t = Double(k) * 0.2
            pad.down(1, 64, 40, at: t)
            states += clickStates(pad.up(1, at: t + 0.08))
        }
        XCTAssertEqual(states, [1, 2, 3, 3])

        // Pointer travel of more than 1.5 mm between taps starts a new count.
        pad.down(2, 30, 40, at: 2.0)
        XCTAssertEqual(clickStates(pad.up(2, at: 2.08)), [1])
        pad.down(3, 30, 40, at: 2.15)
        pad.glide([Path(3, from: (30, 40), to: (34, 40))], from: 2.15, to: 2.3)
        pad.up(3, at: 2.31)
        pad.down(4, 34, 40, at: 2.4)
        XCTAssertEqual(clickStates(pad.up(4, at: 2.45)), [1])
    }

    func testTapThenTouchMoveDrags() {
        var pad = Pad()
        pad.down(1, 64, 40, at: 0)
        pad.up(1, at: 0.1)
        XCTAssertEqual(pad.down(2, 64, 40, at: 0.2), [.contacts(1)])
        let out = pad.glide([Path(2, from: (64, 40), to: (74, 40))], from: 0.2, to: 0.5)
        let press = out.firstIndex(of: .button(.left, down: true, clickState: 1))
        let firstMotion = out.firstIndex { if case .motion = $0 { return true } else { return false } }
        XCTAssertNotNil(press)
        XCTAssertNotNil(firstMotion)
        XCTAssertLessThan(press ?? .max, firstMotion ?? -1)
        XCTAssertEqual(motionSum(out).x, 10, accuracy: 1e-6, "motion since touch-down is kept")
        XCTAssertEqual(pad.r.heldButtons, [.left])
        XCTAssertEqual(pad.up(2, at: 0.55), [.contacts(0), .button(.left, down: false, clickState: 1)])
        XCTAssertEqual(buttons(pad.log), click(1) + [.button(.left, down: true, clickState: 1),
                                                     .button(.left, down: false, clickState: 1)])
    }

    func testTapThenTouchHoldDragsAtTapMax() throws {
        var pad = Pad()
        pad.down(1, 64, 40, at: 0)
        pad.up(1, at: 0.1)
        pad.down(2, 64, 40, at: 0.2)
        let deadline = try XCTUnwrap(pad.r.nextDeadline)
        XCTAssertEqual(deadline, 0.5, accuracy: 1e-9)
        XCTAssertEqual(pad.advance(deadline - 0.001), [])
        XCTAssertEqual(pad.advance(deadline), [.button(.left, down: true, clickState: 1)])
        XCTAssertEqual(pad.up(2, at: 0.8), [.contacts(0), .button(.left, down: false, clickState: 1)])
    }

    func testTapDragLockReleasesOnNextTap() {
        var pad = Pad(TrackpadSettings(dragStyle: .tapDragLock))
        pad.down(1, 64, 40, at: 0)
        pad.up(1, at: 0.1)
        pad.down(2, 64, 40, at: 0.2)
        pad.glide([Path(2, from: (64, 40), to: (74, 40))], from: 0.2, to: 0.5)
        XCTAssertEqual(pad.up(2, at: 0.55), [.contacts(0)])
        XCTAssertEqual(pad.r.heldButtons, [.left])
        XCTAssertNil(pad.r.nextDeadline)

        pad.down(3, 74, 40, at: 1.0)
        let dragOn = pad.glide([Path(3, from: (74, 40), to: (80, 40))], from: 1.0, to: 1.3)
        XCTAssertEqual(buttons(dragOn), [])
        XCTAssertEqual(motionSum(dragOn).x, 6, accuracy: 1e-6)
        XCTAssertEqual(pad.up(3, at: 1.35), [.contacts(0)])
        XCTAssertEqual(pad.r.heldButtons, [.left])

        pad.down(4, 80, 40, at: 2.0)
        XCTAssertEqual(pad.up(4, at: 2.1), [.contacts(0), .button(.left, down: false, clickState: 1)])
        XCTAssertTrue(pad.r.heldButtons.isEmpty)
    }

    func testDragReleaseDelayAllowsRelanding() throws {
        var pad = Pad(TrackpadSettings(dragReleaseDelay: 0.5))
        pad.down(1, 64, 40, at: 0)
        pad.up(1, at: 0.1)
        pad.down(2, 64, 40, at: 0.2)
        pad.glide([Path(2, from: (64, 40), to: (70, 40))], from: 0.2, to: 0.4)
        XCTAssertEqual(pad.up(2, at: 0.45), [.contacts(0)])
        XCTAssertEqual(pad.r.nextDeadline ?? 0, 0.95, accuracy: 1e-9)
        pad.down(3, 70, 40, at: 0.7)
        XCTAssertEqual(buttons(pad.glide([Path(3, from: (70, 40), to: (75, 40))], from: 0.7, to: 0.9)), [])
        XCTAssertEqual(pad.up(3, at: 0.95), [.contacts(0)])
        let release = try XCTUnwrap(pad.r.nextDeadline)
        XCTAssertEqual(release, 1.45, accuracy: 1e-9)
        XCTAssertEqual(pad.advance(release - 0.001), [])
        XCTAssertEqual(pad.advance(release), [.button(.left, down: false, clickState: 1)])
    }

    func testHoldToDragLegacy() {
        var pad = Pad(TrackpadSettings(dragStyle: .holdToDrag))
        pad.down(1, 64, 40, at: 0)
        XCTAssertEqual(pad.r.nextDeadline ?? 0, 0.38, accuracy: 1e-9)
        XCTAssertEqual(pad.advance(0.379), [])
        XCTAssertEqual(pad.advance(0.38), [.button(.left, down: true, clickState: 1)])
        let out = pad.glide([Path(1, from: (64, 40), to: (70, 40))], from: 0.38, to: 0.6)
        XCTAssertEqual(motionSum(out).x, 6, accuracy: 1e-6)
        XCTAssertEqual(pad.up(1, at: 0.65), [.contacts(0), .button(.left, down: false, clickState: 1)])

        var modern = Pad()
        modern.down(1, 64, 40, at: 0)
        XCTAssertNil(modern.r.nextDeadline)
        XCTAssertEqual(modern.advance(0.5), [])
    }

    func testSameTapSlopAtTwoScales() {
        let geometries = [
            Self.geometry,
            TrackpadGeometry(rect: CGRect(x: 100, y: 50, width: 1330.2, height: 829.6))
        ]
        for g in geometries {
            var pad = Pad(geometry: g)
            pad.down(1, 64, 40, at: 0)
            pad.move(1, 65.4, 40, at: 0.05)
            XCTAssertEqual(clickStates(pad.up(1, at: 0.1)), [1], "\(g.rect)")
            pad.down(2, 64, 20, at: 1.0)
            pad.move(2, 65.6, 20, at: 1.05)
            XCTAssertEqual(clickStates(pad.up(2, at: 1.1)), [], "\(g.rect)")
        }
    }

    // MARK: - Thumbs and palms

    func testFingerThenThumbLandsStaysNoClick() {
        var pad = Pad()
        pad.down(1, 50, 40, at: 0)
        XCTAssertEqual(pad.down(2, 50, 70, at: 0.1), [])
        pad.glide([Path(1, from: (50, 40), to: (90, 40)), Path(2, from: (50, 70), to: (50.4, 70))],
                  from: 0.1, to: 2.1)
        XCTAssertEqual(pad.up(2, at: 2.15), [])
        pad.up(1, at: 2.2)
        XCTAssertEqual(buttons(pad.log), [])
        XCTAssertEqual(scrollPhases(pad.log), [])
        XCTAssertEqual(contactCounts(pad.log), [1, 0])
        XCTAssertEqual(motionSum(pad.log).x, 40, accuracy: 1e-6)
    }

    func testThumbTapClicks() {
        var lone = Pad()
        XCTAssertEqual(lone.down(1, 64, 72, at: 0, size: .broad), [])
        XCTAssertEqual(lone.up(1, at: 0.15), click(1))

        var pointing = Pad()
        pointing.down(1, 50, 40, at: 0)
        pointing.glide([Path(1, from: (50, 40), to: (60, 40))], from: 0, to: 0.5)
        XCTAssertEqual(pointing.down(2, 55, 72, at: 0.6), [])
        XCTAssertEqual(pointing.up(2, at: 0.75), click(1))

        var slow = Pad()
        slow.down(1, 64, 72, at: 0, size: .broad)
        XCTAssertEqual(slow.up(1, at: 0.27), [], "a thumb resting 0.27 s is not a tap")

        var off = Pad(TrackpadSettings(thumbClick: false))
        off.down(1, 64, 72, at: 0, size: .broad)
        XCTAssertEqual(off.up(1, at: 0.15), [])
    }

    func testThumbTapHoldDragsWithIndexReland() throws {
        var pad = Pad()
        pad.down(1, 50, 40, at: 0)
        pad.down(2, 55, 72, at: 0.5)
        XCTAssertEqual(pad.up(2, at: 0.6), click(1))
        XCTAssertEqual(pad.down(2, 55.5, 72, at: 0.75), [])
        let deadline = try XCTUnwrap(pad.r.nextDeadline)
        XCTAssertEqual(deadline, 1.05, accuracy: 1e-9)
        XCTAssertEqual(pad.advance(deadline - 0.001), [])
        XCTAssertEqual(pad.advance(deadline), [.button(.left, down: true, clickState: 1)])

        let first = pad.glide([Path(1, from: (50, 40), to: (60, 40))], from: 1.05, to: 1.3)
        XCTAssertEqual(motionSum(first).x, 10, accuracy: 1e-6)
        XCTAssertEqual(pad.up(1, at: 1.35), [.contacts(0)])
        XCTAssertEqual(pad.r.heldButtons, [.left])
        XCTAssertEqual(pad.down(3, 50, 40, at: 1.5), [.contacts(1)])
        let second = pad.glide([Path(3, from: (50, 40), to: (60, 40))], from: 1.5, to: 1.6)
        XCTAssertEqual(buttons(second), [])
        XCTAssertEqual(motionSum(second).x, 10, accuracy: 1e-6)
        XCTAssertEqual(pad.up(3, at: 1.65), [.contacts(0)])
        XCTAssertEqual(pad.up(2, at: 2.0), [.button(.left, down: false, clickState: 1)])
        XCTAssertEqual(buttons(pad.log), click(1) + [.button(.left, down: true, clickState: 1),
                                                     .button(.left, down: false, clickState: 1)])
    }

    func testThumbHoldStartsWhenIndexMovesAndSoleThumbDrivesAfter2mm() {
        var pad = Pad()
        pad.down(1, 50, 40, at: 0)
        pad.down(2, 55, 72, at: 0.5)
        pad.up(2, at: 0.6)
        pad.down(2, 55, 72, at: 0.7)
        let out = pad.move(1, 51, 40, at: 0.75)
        XCTAssertEqual(out.first, .button(.left, down: true, clickState: 1))
        XCTAssertEqual(motionSum(out).x, 1, accuracy: 1e-6)
        pad.up(1, at: 0.8)
        XCTAssertEqual(pad.move(2, 56.5, 72, at: 0.9), [], "within 2 mm the thumb only rests")
        let driving = pad.move(2, 58, 72, at: 1.0)
        XCTAssertEqual(motionSum(driving).x, 1.5, accuracy: 1e-6)
        XCTAssertEqual(pad.up(2, at: 1.1), [.button(.left, down: false, clickState: 1)])
    }

    func testPalmHeelCornerIgnoredWhilePointing() {
        for corner in [5.0, 123.0] {
            var pad = Pad()
            pad.down(1, 64, 30, at: 0)
            XCTAssertEqual(pad.down(2, corner, 75, at: 0.05, size: .broad), [])
            pad.glide([Path(1, from: (64, 30), to: (84, 30)), Path(2, from: (corner, 75), to: (corner + 1, 74))],
                      from: 0.05, to: 0.5)
            XCTAssertEqual(pad.up(2, at: 0.52), [])
            pad.up(1, at: 0.6)
            XCTAssertEqual(buttons(pad.log), [])
            XCTAssertEqual(scrollPhases(pad.log), [])
            XCTAssertEqual(contactCounts(pad.log), [1, 0])
            XCTAssertEqual(motionSum(pad.log).x, 20, accuracy: 1e-6)
        }
    }

    func testBroadCentralContactRestsNotFinger() {
        var pad = Pad()
        XCTAssertEqual(pad.down(1, 64, 72, at: 0, size: .broad), [])
        XCTAssertEqual(pad.advance(1.0), [])
        XCTAssertEqual(pad.move(1, 64.5, 72, at: 1.0), [])
        XCTAssertEqual(pad.down(2, 64, 40, at: 1.2), [.contacts(1)])
        let out = pad.glide([Path(2, from: (64, 40), to: (74, 40))], from: 1.2, to: 1.5)
        XCTAssertEqual(motionSum(out).x, 10, accuracy: 1e-6)
        pad.up(2, at: 1.6)
        XCTAssertEqual(pad.up(1, at: 2.0), [])
        XCTAssertEqual(buttons(pad.log), [])
        XCTAssertEqual(scrollPhases(pad.log), [])
        XCTAssertEqual(contactCounts(pad.log), [1, 0])
    }

    func testRestingThumbPlusIndexIsPointerNotScroll() {
        var pad = Pad()
        XCTAssertEqual(pad.down(1, 64, 72, at: 0), [.contacts(1)])
        pad.move(1, 64.3, 72, at: 0.1)
        XCTAssertEqual(pad.down(2, 60, 40, at: 0.3), [], "the click-zone contact becomes a resting thumb")
        let out = pad.glide([Path(2, from: (60, 40), to: (80, 40))], from: 0.3, to: 0.7)
        XCTAssertEqual(motionSum(out).x, 20, accuracy: 1e-6)
        XCTAssertEqual(pad.up(2, at: 0.75), [.contacts(0)])
        XCTAssertEqual(pad.up(1, at: 1.0), [])
        XCTAssertEqual(scrollPhases(pad.log), [])
        XCTAssertEqual(buttons(pad.log), [])
    }

    // MARK: - Two fingers

    func testIndexMiddleNearBottomScroll() {
        var pad = Pad()
        pad.down(1, 55, 70, at: 0)
        XCTAssertEqual(pad.down(2, 75, 70, at: 0.02), [.contacts(2), mayBegin])
        pad.glide([Path(1, from: (55, 70), to: (55, 60)), Path(2, from: (75, 70), to: (75, 60))], from: 0.02, to: 0.3)
        pad.up(1, at: 0.31)
        pad.up(2, at: 0.32)
        let phases = scrollPhases(pad.log)
        XCTAssertEqual(phases.first, .mayBegin)
        XCTAssertEqual(phases.dropFirst().first, .began)
        XCTAssertEqual(phases.last, .ended)
        XCTAssertEqual(motionSum(pad.log).x, 0)
    }

    func testScrollPhaseSequence() {
        var pad = Pad()
        pad.down(1, 55, 30, at: 0)
        pad.down(2, 75, 30, at: 0.02)
        pad.glide([Path(1, from: (55, 30), to: (55, 40)), Path(2, from: (75, 30), to: (75, 40))], from: 0.02, to: 0.3)
        let lift = pad.up(1, at: 0.305)
        pad.up(2, at: 0.31)

        let tail = Array(pad.log.drop { $0 != .contacts(2) })
        XCTAssertEqual(Array(tail.prefix(2)), [.contacts(2), mayBegin])
        let phases = scrollPhases(tail)
        XCTAssertEqual(phases.first, .mayBegin)
        XCTAssertEqual(phases[1], .began)
        XCTAssertEqual(phases.last, .ended)
        XCTAssertGreaterThan(phases.count, 4)
        XCTAssertTrue(phases.dropFirst(2).dropLast().allSatisfy { $0 == .changed })
        XCTAssertEqual(scrollSum(pad.log).y, 10, accuracy: 1e-6)
        XCTAssertEqual(scrollSum(pad.log).x, 0, accuracy: 1e-9)
        XCTAssertEqual(lift.first, .contacts(1), "the count precedes the end so momentum survives it")
        guard case .scroll(.ended, _, _, _, _, let vx?, let vy?) = lift.last else { return XCTFail("\(lift)") }
        XCTAssertEqual(vx, 0, accuracy: 1e-6)
        XCTAssertEqual(vy, 10 / 0.28, accuracy: 2)
        for output in pad.log {
            guard case .scroll(.changed, _, _, let dt, let speed, _, _) = output else { continue }
            XCTAssertGreaterThan(dt, 0)
            XCTAssertGreaterThan(speed, 0)
        }
    }

    func testNoMomentumVelocityAfterPause80ms() {
        var pad = Pad()
        pad.down(1, 55, 30, at: 0)
        pad.down(2, 75, 30, at: 0.02)
        pad.glide([Path(1, from: (55, 30), to: (55, 50)), Path(2, from: (75, 30), to: (75, 50))], from: 0.02, to: 0.3)
        let lift = pad.up(1, at: 0.38)
        XCTAssertEqual(lift.last, .scroll(phase: .ended, dxMM: 0, dyMM: 0, dt: 0, speed: 0, releaseVX: 0, releaseVY: 0))
    }

    func testTwoFingerTapRightClick() {
        var pad = Pad()
        pad.down(1, 55, 40, at: 0)
        pad.down(2, 75, 40, at: 0.02)
        XCTAssertEqual(pad.up(1, at: 0.12), [
            .contacts(1),
            .scroll(phase: .cancelled, dxMM: 0, dyMM: 0, dt: 0, speed: 0, releaseVX: nil, releaseVY: nil),
            .button(.right, down: true, clickState: 1),
            .button(.right, down: false, clickState: 1)
        ])
        XCTAssertEqual(pad.up(2, at: 0.13), [.contacts(0)])

        var slow = Pad()
        slow.down(1, 55, 40, at: 0)
        slow.down(2, 75, 40, at: 0.02)
        XCTAssertEqual(buttons(slow.up(1, at: 0.4)), [])
    }

    func testRemainingFingerInertAfterScroll() {
        var pad = Pad()
        pad.down(1, 55, 30, at: 0)
        pad.down(2, 75, 30, at: 0.02)
        pad.glide([Path(1, from: (55, 30), to: (55, 40)), Path(2, from: (75, 30), to: (75, 40))], from: 0.02, to: 0.2)
        pad.up(1, at: 0.21)
        let out = pad.glide([Path(2, from: (75, 40), to: (90, 40))], from: 0.21, to: 0.5)
        XCTAssertEqual(out, [])
        XCTAssertEqual(pad.up(2, at: 0.55), [.contacts(0)])
    }

    // MARK: - Three fingers

    func testThreeFingerSwipeLeftOnce() {
        var pad = Pad()
        threeDown(&pad)
        pad.glide(threePaths(dx: -25, dy: 0), from: 0.02, to: 0.3)
        liftThree(&pad, at: 0.31)
        XCTAssertEqual(gestures(pad.log), [.swipe(fingers: 3, direction: .left)])
        XCTAssertEqual(motionSum(pad.log).x, 0)
        XCTAssertFalse(scrollPhases(pad.log).contains(.began))
        XCTAssertEqual(buttons(pad.log), [])
    }

    func testThreeFingerSwipeDirections() {
        let cases: [(Double, Double, SwipeDirection)] = [(25, 0, .right), (0, -25, .up), (0, 25, .down)]
        for (dx, dy, direction) in cases {
            var pad = Pad()
            threeDown(&pad)
            pad.glide(threePaths(dx: dx, dy: dy), from: 0.02, to: 0.3)
            liftThree(&pad, at: 0.31)
            XCTAssertEqual(gestures(pad.log), [.swipe(fingers: 3, direction: direction)])
        }
    }

    func testThreeFingerFlickSwipesAtLift() {
        var pad = Pad()
        threeDown(&pad)
        pad.glide(threePaths(dx: 10, dy: 0), from: 0.02, to: 0.07)
        XCTAssertEqual(gestures(pad.log), [])
        liftThree(&pad, at: 0.075)
        XCTAssertEqual(gestures(pad.log), [.swipe(fingers: 3, direction: .right)])

        var slow = Pad()
        threeDown(&slow)
        slow.glide(threePaths(dx: 10, dy: 0), from: 0.02, to: 0.5)
        liftThree(&slow, at: 0.6)
        XCTAssertEqual(gestures(slow.log), [])
    }

    func testDiagonalNoSwipe() {
        var pad = Pad()
        threeDown(&pad)
        pad.glide(threePaths(dx: 20, dy: 18), from: 0.02, to: 0.3)
        liftThree(&pad, at: 0.31)
        XCTAssertEqual(gestures(pad.log), [])
    }

    func testThreeFingerTap() {
        var pad = Pad()
        threeDown(&pad)
        liftThree(&pad, at: 0.12)
        XCTAssertEqual(gestures(pad.log), [.tap(fingers: 3)])
        XCTAssertEqual(buttons(pad.log), [])

        var off = Pad(TrackpadSettings(lookUpTap: false))
        threeDown(&off)
        liftThree(&off, at: 0.12)
        XCTAssertEqual(gestures(off.log), [])
    }

    func testThreeFingerDragStyle() throws {
        var pad = Pad(TrackpadSettings(dragStyle: .threeFinger))
        threeDown(&pad)
        let out = pad.glide(threePaths(dx: 25, dy: 0), from: 0.02, to: 0.3)
        XCTAssertEqual(buttons(out), [.button(.left, down: true, clickState: 1)])
        XCTAssertEqual(motionSum(out).x, 25, accuracy: 1e-6)
        liftThree(&pad, at: 0.35)
        XCTAssertEqual(gestures(pad.log), [], "three-finger swipes need four fingers in this style")
        XCTAssertEqual(pad.r.heldButtons, [.left])
        let deadline = try XCTUnwrap(pad.r.nextDeadline)
        XCTAssertEqual(deadline, 0.37 + 0.25, accuracy: 1e-9)
        XCTAssertEqual(pad.advance(deadline - 0.001), [])
        XCTAssertEqual(pad.advance(deadline), [.button(.left, down: false, clickState: 1)])

        var four = Pad(TrackpadSettings(dragStyle: .threeFinger))
        threeDown(&four)
        four.down(4, 92, 40, at: 0.03)
        four.glide(threePaths(dx: -25, dy: 0) + [Path(4, from: (92, 40), to: (67, 40))], from: 0.03, to: 0.3)
        XCTAssertEqual(gestures(four.log), [.swipe(fingers: 4, direction: .left)])
        XCTAssertEqual(buttons(four.log), [])
    }

    // MARK: - Edges and typing

    func testEdgeExitStopsMotionAt64_1mm() {
        var pad = Pad()
        pad.down(1, 64.1, 40, at: 0)
        let out = pad.glide([Path(1, from: (64.1, 40), to: (140, 40))], from: 0, to: 0.5)
        let sum = motionSum(out).x
        XCTAssertLessThanOrEqual(sum, 64.1 + 0.5)
        XCTAssertGreaterThan(sum, 64.1 - 1.3)
        XCTAssertEqual(out.last, .contacts(0))
        XCTAssertEqual(pad.move(1, 150, 40, at: 0.6), [])
        XCTAssertEqual(pad.up(1, at: 0.7), [])
        XCTAssertEqual(buttons(pad.log), [])
    }

    func testEdgeReentryIsNewContact() {
        var pad = Pad()
        pad.down(1, 120, 40, at: 0)
        pad.move(1, 130, 40, at: 0.05)
        XCTAssertEqual(pad.move(1, 127, 40, at: 0.1), [.contacts(1)])
        XCTAssertEqual(motionSum(pad.move(1, 120, 40, at: 0.15)).x, -7, accuracy: 1e-6)
    }

    func testEdgeExitKeepsThumbHoldDrag() {
        var pad = Pad()
        pad.down(1, 100, 40, at: 0)
        pad.down(2, 55, 72, at: 0.5)
        pad.up(2, at: 0.6)
        pad.down(2, 55, 72, at: 0.7)
        pad.advance(1.01)
        XCTAssertEqual(pad.r.heldButtons, [.left])
        pad.glide([Path(1, from: (100, 40), to: (140, 40))], from: 1.0, to: 1.3)
        XCTAssertEqual(pad.r.heldButtons, [.left])
        XCTAssertEqual(pad.up(2, at: 1.4), [.button(.left, down: false, clickState: 1)])
    }

    func testTapQuietAfterTyping() {
        var pad = Pad()
        pad.typing(0)
        pad.down(1, 64, 40, at: 0.4)
        XCTAssertEqual(motionSum(pad.move(1, 64.5, 40, at: 0.45)).x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(pad.up(1, at: 0.5), [.contacts(0)])

        pad.typing(1.0)
        pad.down(2, 64, 40, at: 1.7)
        XCTAssertEqual(pad.up(2, at: 1.8), [.contacts(0)] + click(1))

        pad.typing(3.0)
        pad.down(3, 64, 72, at: 3.4, size: .broad)
        XCTAssertEqual(pad.up(3, at: 3.5), [], "thumb taps need the same quiet time")
    }

    func testTopBandIgnoredAfterTyping() {
        var pad = Pad()
        pad.typing(0)
        XCTAssertEqual(pad.down(1, 64, 5, at: 0.5), [])
        XCTAssertEqual(pad.move(1, 70, 5, at: 0.6), [])
        XCTAssertEqual(pad.move(1, 70, 30, at: 0.7), [])
        XCTAssertEqual(pad.up(1, at: 0.8), [])
        XCTAssertEqual(pad.down(2, 64, 5, at: 2.0), [.contacts(1)])

        var strict = Pad(scale: 1.5)
        strict.typing(0)
        XCTAssertEqual(strict.down(1, 64, 12, at: 0.5), [], "strict protection widens the band to 15 mm")
        var balanced = Pad()
        balanced.typing(0)
        XCTAssertEqual(balanced.down(1, 64, 12, at: 0.5), [.contacts(1)])
    }

    func testSideBandBroadIgnored() {
        var pad = Pad()
        pad.typing(0)
        XCTAssertEqual(pad.down(1, 3, 40, at: 0.5, size: .broad), [])
        XCTAssertEqual(pad.move(1, 10, 40, at: 0.6), [])
        XCTAssertEqual(pad.up(1, at: 0.7), [])
        XCTAssertEqual(pad.down(2, 126, 40, at: 0.8, size: .broad), [])
        XCTAssertEqual(pad.down(3, 3, 40, at: 0.9), [.contacts(1)], "fingertips at the side still point")
    }

    func testTypingEndsDragAndScroll() {
        var drag = Pad()
        drag.down(1, 64, 40, at: 0)
        drag.up(1, at: 0.1)
        drag.down(2, 64, 40, at: 0.2)
        drag.glide([Path(2, from: (64, 40), to: (70, 40))], from: 0.2, to: 0.4)
        XCTAssertEqual(drag.typing(0.5), [.button(.left, down: false, clickState: 1)])
        XCTAssertEqual(drag.move(2, 75, 40, at: 0.6), [])
        XCTAssertEqual(drag.up(2, at: 0.7), [.contacts(0)])

        var scroll = Pad()
        scroll.down(1, 55, 30, at: 0)
        scroll.down(2, 75, 30, at: 0.02)
        scroll.glide([Path(1, from: (55, 30), to: (55, 40)), Path(2, from: (75, 30), to: (75, 40))], from: 0.02, to: 0.2)
        XCTAssertEqual(scroll.typing(0.25), [.scroll(phase: .ended, dxMM: 0, dyMM: 0, dt: 0, speed: 0,
                                                      releaseVX: 0, releaseVY: 0)])
        XCTAssertEqual(scroll.move(1, 55, 50, at: 0.3), [])
        XCTAssertEqual(scroll.up(1, at: 0.35), [.contacts(1)])
        XCTAssertEqual(scroll.up(2, at: 0.36), [.contacts(0)])
    }

    func testRejectedContactEndsScroll() {
        var pad = Pad()
        pad.down(1, 55, 30, at: 0)
        pad.down(2, 75, 30, at: 0.02)
        pad.glide([Path(1, from: (55, 30), to: (55, 40)), Path(2, from: (75, 30), to: (75, 40))], from: 0.02, to: 0.2)
        XCTAssertEqual(pad.r.rejected(id: 2, time: 0.21), [
            .contacts(1),
            .scroll(phase: .ended, dxMM: 0, dyMM: 0, dt: 0, speed: 0, releaseVX: 0, releaseVY: 0)
        ])
        XCTAssertEqual(pad.move(2, 75, 50, at: 0.25), [])
        XCTAssertEqual(pad.up(2, at: 0.3), [])
        XCTAssertEqual(pad.up(1, at: 0.31), [.contacts(0)])
    }

    func testResetReleases() {
        var drag = Pad()
        drag.down(1, 64, 40, at: 0)
        drag.up(1, at: 0.1)
        drag.down(2, 64, 40, at: 0.2)
        drag.glide([Path(2, from: (64, 40), to: (70, 40))], from: 0.2, to: 0.4)
        XCTAssertEqual(drag.r.reset(), [.button(.left, down: false, clickState: 1)])
        XCTAssertTrue(drag.r.heldButtons.isEmpty)
        XCTAssertFalse(drag.r.isActive)
        XCTAssertEqual(drag.move(2, 80, 40, at: 0.5), [])
        XCTAssertEqual(drag.up(2, at: 0.6), [])

        var scroll = Pad()
        scroll.down(1, 55, 30, at: 0)
        scroll.down(2, 75, 30, at: 0.02)
        scroll.glide([Path(1, from: (55, 30), to: (55, 40)), Path(2, from: (75, 30), to: (75, 40))], from: 0.02, to: 0.2)
        XCTAssertEqual(scroll.r.reset(), [.scroll(phase: .ended, dxMM: 0, dyMM: 0, dt: 0, speed: 0,
                                                    releaseVX: 0, releaseVY: 0)])
        XCTAssertEqual(scroll.down(3, 64, 40, at: 0.5), [.contacts(1)])
    }

    // MARK: - Inert contacts, click zone and settings

    func testFingerLandingAfterTypingStillPoints() {
        var pad = Pad()
        pad.down(1, 30, 30, at: 0)
        XCTAssertEqual(pad.typing(1.0), [])
        XCTAssertEqual(pad.move(1, 35, 30, at: 1.1), [], "the finger down at typing stays inert")
        XCTAssertEqual(pad.down(2, 90, 40, at: 3.0), [.contacts(2)])
        let out = pad.glide([Path(2, from: (90, 40), to: (105, 40))], from: 3.0, to: 3.2)
        XCTAssertEqual(motionSum(out).x, 15, accuracy: 1e-6)
        XCTAssertEqual(pad.move(1, 40, 30, at: 3.25), [])
        XCTAssertEqual(pad.up(2, at: 3.3), [.contacts(1)])
        XCTAssertEqual(pad.up(1, at: 3.4), [.contacts(0)])

        // A new finger can still tap while the inert one rests.
        pad.down(3, 30, 30, at: 4.0)
        pad.typing(4.1)
        pad.down(4, 90, 40, at: 5.0)
        XCTAssertEqual(pad.up(4, at: 5.1), [.contacts(1)] + click(1))
        XCTAssertEqual(pad.up(3, at: 5.2), [.contacts(0)])
        XCTAssertEqual(scrollPhases(pad.log), [])
    }

    func testScrollResumesWhenFingerRelands() {
        var pad = Pad()
        pad.down(1, 55, 30, at: 0)
        pad.down(2, 75, 30, at: 0.02)
        pad.glide([Path(1, from: (55, 30), to: (55, 40)), Path(2, from: (75, 30), to: (75, 40))], from: 0.02, to: 0.2)
        pad.up(1, at: 0.21)
        XCTAssertEqual(pad.down(3, 55, 40, at: 0.25), [.contacts(2), mayBegin])
        let out = pad.glide([Path(3, from: (55, 40), to: (55, 50)), Path(2, from: (75, 40), to: (75, 50))],
                            from: 0.25, to: 0.45)
        XCTAssertEqual(scrollPhases(out).first, .began)
        XCTAssertEqual(scrollSum(out).y, 10, accuracy: 1e-6)
        XCTAssertEqual(motionSum(out).x, 0)
        XCTAssertEqual(buttons(pad.log), [])
    }

    func testThumbHoldCandidateCancelledByScroll() {
        var pad = Pad()
        pad.down(1, 50, 40, at: 0)
        pad.down(2, 64, 72, at: 0.05)
        XCTAssertEqual(pad.up(2, at: 0.15), click(1))
        XCTAssertEqual(pad.down(2, 64, 72, at: 0.25), [])
        XCTAssertEqual(pad.down(3, 70, 40, at: 0.26), [.contacts(2), mayBegin])
        XCTAssertNil(pad.r.nextDeadline)
        pad.glide([Path(1, from: (50, 40), to: (50, 50)), Path(3, from: (70, 40), to: (70, 50))], from: 0.26, to: 0.8)
        pad.advance(1.0)
        pad.up(1, at: 1.1)
        pad.up(3, at: 1.15)
        pad.advance(1.5)
        XCTAssertEqual(pad.up(2, at: 1.6), [])
        XCTAssertEqual(buttons(pad.log), click(1))
        XCTAssertTrue(scrollPhases(pad.log).contains(.began))
    }

    /// Pointing, thumb tap, a second finger starts a scroll, and only then does
    /// the thumb re-land inside the tap-hold window. When the scroll lifts the
    /// thumb must not press, and later pointing must not drag.
    func testThumbRelandingDuringScrollNeverPresses() {
        var pad = Pad()
        pad.down(1, 50, 40, at: 0)
        pad.down(2, 64, 72, at: 0.05)
        XCTAssertEqual(pad.up(2, at: 0.15), click(1))
        XCTAssertEqual(pad.down(3, 70, 40, at: 0.2), [.contacts(2), mayBegin])
        pad.glide([Path(1, from: (50, 40), to: (50, 45)), Path(3, from: (70, 40), to: (70, 45))], from: 0.2, to: 0.3)
        XCTAssertTrue(scrollPhases(pad.log).contains(.began))
        XCTAssertEqual(pad.down(2, 64, 72, at: 0.32), [], "the thumb rests; no tap-hold candidacy mid-scroll")
        XCTAssertNil(pad.r.nextDeadline)
        pad.glide([Path(1, from: (50, 45), to: (50, 50)), Path(3, from: (70, 45), to: (70, 50))], from: 0.32, to: 0.5)
        pad.up(1, at: 0.55)
        pad.up(3, at: 0.56)
        XCTAssertNil(pad.r.nextDeadline)
        XCTAssertEqual(pad.advance(1.0), [])
        XCTAssertTrue(pad.r.heldButtons.isEmpty)
        pad.down(4, 50, 40, at: 1.2)
        let point = pad.glide([Path(4, from: (50, 40), to: (60, 40))], from: 1.2, to: 1.4)
        XCTAssertEqual(buttons(point), [])
        XCTAssertEqual(motionSum(point).x, 10, accuracy: 1e-6)
        pad.up(4, at: 1.45)
        XCTAssertEqual(pad.up(2, at: 2.0), [])
        XCTAssertEqual(buttons(pad.log), click(1))
    }

    /// Thumb tap, a quick two-finger scroll, then the thumb re-lands while its
    /// tap-hold window is still open: the scroll in between ends that window.
    func testThumbTapThenScrollThenRelandNeverPresses() {
        var pad = Pad()
        pad.down(1, 64, 72, at: 0, size: .broad)
        XCTAssertEqual(pad.up(1, at: 0.08), click(1))
        pad.down(2, 50, 40, at: 0.1)
        XCTAssertEqual(pad.down(3, 70, 40, at: 0.11), [.contacts(2), mayBegin])
        pad.glide([Path(2, from: (50, 40), to: (50, 50)), Path(3, from: (70, 40), to: (70, 50))], from: 0.11, to: 0.25)
        pad.up(2, at: 0.26)
        pad.up(3, at: 0.27)
        XCTAssertTrue(scrollPhases(pad.log).contains(.began))
        XCTAssertEqual(pad.down(1, 64, 72, at: 0.3, size: .broad), [])
        XCTAssertNil(pad.r.nextDeadline)
        XCTAssertEqual(pad.advance(1.0), [])
        pad.down(4, 50, 40, at: 1.1)
        let point = pad.glide([Path(4, from: (50, 40), to: (60, 40))], from: 1.1, to: 1.3)
        XCTAssertEqual(buttons(point), [])
        XCTAssertEqual(motionSum(point).x, 10, accuracy: 1e-6)
        pad.up(4, at: 1.35)
        XCTAssertEqual(pad.up(1, at: 1.5), [])
        XCTAssertEqual(buttons(pad.log), click(1))
    }

    /// A thumb tap made during a scroll opens no tap-hold window, even when the
    /// thumb re-lands after the scroll ended and one finger lingers.
    func testThumbTapDuringScrollOpensNoHoldWindow() {
        var pad = Pad()
        pad.down(1, 50, 40, at: 0)
        XCTAssertEqual(pad.down(3, 70, 40, at: 0.02), [.contacts(2), mayBegin])
        pad.glide([Path(1, from: (50, 40), to: (50, 48)), Path(3, from: (70, 40), to: (70, 48))], from: 0.02, to: 0.15)
        pad.down(2, 64, 72, at: 0.16)
        pad.up(2, at: 0.24)
        pad.up(1, at: 0.3)
        let mark = pad.log.count
        XCTAssertEqual(pad.down(2, 64, 72, at: 0.32), [])
        XCTAssertNil(pad.r.nextDeadline)
        XCTAssertEqual(pad.advance(1.0), [])
        pad.up(3, at: 1.1)
        pad.down(4, 50, 40, at: 1.2)
        pad.glide([Path(4, from: (50, 40), to: (60, 40))], from: 1.2, to: 1.4)
        pad.up(4, at: 1.45)
        pad.up(2, at: 1.5)
        XCTAssertEqual(buttons(Array(pad.log[mark...])), [])
        XCTAssertTrue(pad.r.heldButtons.isEmpty)
    }

    /// A thumb that lands during a scroll and lifts after the scroll fingers have
    /// lifted (mode is idle again) still opens no tap-hold window.
    func testThumbTapOverlappingScrollEndOpensNoHoldWindow() {
        var pad = Pad()
        pad.down(1, 50, 40, at: 0)
        XCTAssertEqual(pad.down(3, 70, 40, at: 0.02), [.contacts(2), mayBegin])
        pad.glide([Path(1, from: (50, 40), to: (50, 48)), Path(3, from: (70, 40), to: (70, 48))], from: 0.02, to: 0.15)
        XCTAssertTrue(scrollPhases(pad.log).contains(.began))
        pad.down(2, 64, 72, at: 0.16, size: .broad)
        pad.up(1, at: 0.2)
        pad.up(3, at: 0.21)
        pad.up(2, at: 0.3)
        let mark = pad.log.count
        XCTAssertEqual(pad.down(2, 64, 72, at: 0.4, size: .broad), [])
        XCTAssertNil(pad.r.nextDeadline)
        XCTAssertEqual(pad.advance(1.0), [])
        XCTAssertTrue(pad.r.heldButtons.isEmpty)
        pad.down(4, 50, 40, at: 1.1)
        let point = pad.glide([Path(4, from: (50, 40), to: (60, 40))], from: 1.1, to: 1.3)
        XCTAssertEqual(buttons(point), [])
        XCTAssertEqual(motionSum(point).x, 10, accuracy: 1e-6)
        pad.up(4, at: 1.35)
        XCTAssertEqual(pad.up(2, at: 1.5), [])
        XCTAssertEqual(buttons(Array(pad.log[mark...])), [])
        XCTAssertTrue(pad.r.heldButtons.isEmpty)
    }

    /// A thumb resting before a quick scroll, lifting after the scroll fingers:
    /// its lift is no tap (no click) and opens no tap-hold window.
    func testThumbRestingThroughScrollNeitherClicksNorOpensHoldWindow() {
        var pad = Pad()
        pad.down(2, 64, 72, at: 0, size: .broad)
        pad.down(1, 50, 40, at: 0.01)
        pad.down(3, 70, 40, at: 0.02)
        pad.glide([Path(1, from: (50, 40), to: (50, 48)), Path(3, from: (70, 40), to: (70, 48))], from: 0.02, to: 0.12)
        XCTAssertTrue(scrollPhases(pad.log).contains(.began))
        pad.up(1, at: 0.15)
        pad.up(3, at: 0.16)
        XCTAssertEqual(buttons(pad.up(2, at: 0.2)), [], "a thumb resting through a scroll is no tap")
        XCTAssertNil(pad.r.nextDeadline)
        XCTAssertEqual(pad.down(2, 64, 72, at: 0.3, size: .broad), [])
        XCTAssertNil(pad.r.nextDeadline)
        XCTAssertEqual(pad.advance(1.0), [])
        XCTAssertTrue(pad.r.heldButtons.isEmpty)
        pad.down(4, 50, 40, at: 1.1)
        let point = pad.glide([Path(4, from: (50, 40), to: (60, 40))], from: 1.1, to: 1.3)
        XCTAssertEqual(buttons(point), [])
        XCTAssertEqual(motionSum(point).x, 10, accuracy: 1e-6)
        pad.up(4, at: 1.35)
        pad.up(2, at: 1.5)
        XCTAssertEqual(buttons(pad.log), [])
    }

    /// A thumb that lands during a three-finger swipe and lifts after the
    /// fingers opens no tap-hold window.
    func testThumbTapOverlappingSwipeEndOpensNoHoldWindow() {
        var pad = Pad()
        pad.down(1, 40, 40, at: 0)
        pad.down(3, 55, 40, at: 0.01)
        pad.down(4, 70, 40, at: 0.02)
        pad.down(2, 64, 72, at: 0.05, size: .broad)
        pad.glide([Path(1, from: (40, 40), to: (65, 40)), Path(3, from: (55, 40), to: (80, 40)),
                   Path(4, from: (70, 40), to: (95, 40))], from: 0.05, to: 0.15)
        XCTAssertEqual(gestures(pad.log), [.swipe(fingers: 3, direction: .right)])
        pad.up(1, at: 0.16)
        pad.up(3, at: 0.17)
        pad.up(4, at: 0.18)
        pad.up(2, at: 0.25)
        let mark = pad.log.count
        XCTAssertEqual(pad.down(2, 64, 72, at: 0.3, size: .broad), [])
        XCTAssertNil(pad.r.nextDeadline)
        XCTAssertEqual(pad.advance(1.0), [])
        XCTAssertTrue(pad.r.heldButtons.isEmpty)
        pad.down(5, 50, 40, at: 1.1)
        let point = pad.glide([Path(5, from: (50, 40), to: (60, 40))], from: 1.1, to: 1.3)
        XCTAssertEqual(buttons(point), [])
        XCTAssertEqual(motionSum(point).x, 10, accuracy: 1e-6)
        pad.up(5, at: 1.35)
        pad.up(2, at: 1.5)
        XCTAssertEqual(buttons(Array(pad.log[mark...])), [])
        XCTAssertTrue(pad.r.heldButtons.isEmpty)
    }

    /// Thumb tap-hold orderings around a three-finger gesture never press.
    func testThumbHoldCandidateNeverSurvivesThreeFingerGesture() {
        // The thumb re-lands while three fingers are down.
        var during = Pad()
        during.down(1, 64, 72, at: 0, size: .broad)
        XCTAssertEqual(during.up(1, at: 0.08), click(1))
        during.down(2, 50, 40, at: 0.1)
        during.down(3, 64, 40, at: 0.11)
        during.down(4, 78, 40, at: 0.12)
        XCTAssertEqual(during.down(1, 64, 72, at: 0.2, size: .broad), [])
        XCTAssertNil(during.r.nextDeadline)
        during.glide([Path(2, from: (50, 40), to: (50, 41)), Path(3, from: (64, 40), to: (64, 41)),
                      Path(4, from: (78, 40), to: (78, 41))], from: 0.2, to: 0.3)
        during.up(2, at: 0.35)
        during.up(3, at: 0.36)
        during.up(4, at: 0.37)
        XCTAssertNil(during.r.nextDeadline)
        XCTAssertEqual(during.advance(1.0), [])
        during.down(5, 50, 40, at: 1.1)
        let point = during.glide([Path(5, from: (50, 40), to: (60, 40))], from: 1.1, to: 1.3)
        XCTAssertEqual(buttons(point), [])
        XCTAssertEqual(motionSum(point).x, 10, accuracy: 1e-6)
        during.up(5, at: 1.35)
        XCTAssertEqual(during.up(1, at: 1.5), [])
        XCTAssertEqual(buttons(during.log), click(1))

        // The candidate already rests when three fingers land.
        var before = Pad()
        before.down(1, 64, 72, at: 0, size: .broad)
        before.up(1, at: 0.08)
        XCTAssertEqual(before.down(1, 64, 72, at: 0.15, size: .broad), [])
        XCTAssertNotNil(before.r.nextDeadline)
        before.down(2, 50, 40, at: 0.2)
        before.down(3, 64, 40, at: 0.21)
        before.down(4, 78, 40, at: 0.22)
        XCTAssertNil(before.r.nextDeadline)
        before.up(2, at: 0.3)
        before.up(3, at: 0.31)
        before.up(4, at: 0.32)
        XCTAssertNil(before.r.nextDeadline)
        XCTAssertEqual(before.advance(1.0), [])
        before.down(5, 50, 40, at: 1.1)
        XCTAssertEqual(buttons(before.glide([Path(5, from: (50, 40), to: (60, 40))], from: 1.1, to: 1.3)), [])
        before.up(5, at: 1.35)
        before.up(1, at: 1.5)
        XCTAssertEqual(buttons(before.log), click(1))
    }

    func testThumbHoldWaitsDespiteThumbTravel() {
        var pad = Pad()
        pad.down(1, 64, 72, at: 0, size: .broad)
        XCTAssertEqual(pad.up(1, at: 0.1), click(1))
        XCTAssertEqual(pad.down(2, 64, 72, at: 0.2, size: .broad), [])
        XCTAssertEqual(pad.move(2, 67, 72, at: 0.25), [], "the candidate's own travel does not press")
        XCTAssertEqual(pad.advance(0.499), [])
        XCTAssertEqual(pad.advance(0.5), [.button(.left, down: true, clickState: 1)])
        XCTAssertEqual(pad.up(2, at: 0.8), [.button(.left, down: false, clickState: 1)])
    }

    func testQuickSecondTouchInDragWindowIsDoubleClick() {
        var pad = Pad()
        pad.down(1, 64, 40, at: 0)
        XCTAssertEqual(pad.up(1, at: 0.1), [.contacts(0)] + click(1))
        pad.down(2, 64, 40, at: 0.38)
        XCTAssertEqual(pad.up(2, at: 0.62), [.contacts(0)] + click(2))
    }

    func testThreeFingerDragNeedsAllFingersMoving() {
        var pad = Pad(TrackpadSettings(dragStyle: .threeFinger))
        threeDown(&pad)
        let one = pad.glide([Path(1, from: (50, 40), to: (55, 40))], from: 0.02, to: 0.2)
        XCTAssertEqual(buttons(one), [], "one finger moving is not three fingers moving together")
        let all = pad.glide([Path(1, from: (55, 40), to: (60, 40)), Path(2, from: (64, 40), to: (69, 40)),
                             Path(3, from: (78, 40), to: (83, 40))], from: 0.2, to: 0.4)
        XCTAssertEqual(buttons(all), [.button(.left, down: true, clickState: 1)])
        XCTAssertEqual(motionSum(all).x, 20.0 / 3, accuracy: 1e-6, "centroid motion since the gesture began")
    }

    func testClickZoneTapThenPointOrScrollWithTapDragOff() {
        for style in [DragStyle.threeFinger, .holdToDrag] {
            var point = Pad(TrackpadSettings(dragStyle: style))
            point.down(1, 64, 70, at: 0)
            point.up(1, at: 0.1)
            XCTAssertEqual(point.down(2, 64, 70, at: 0.2), [.contacts(1)], "\(style)")
            let out = point.glide([Path(2, from: (64, 70), to: (84, 70))], from: 0.2, to: 0.4)
            XCTAssertEqual(motionSum(out).x, 20, accuracy: 1e-6, "\(style)")
            XCTAssertEqual(point.up(2, at: 0.45), [.contacts(0)], "\(style)")
            XCTAssertEqual(buttons(point.log), click(1), "\(style)")

            for order in [[(2, 62.0), (3, 80.0)], [(2, 80.0), (3, 62.0)]] {
                var scroll = Pad(TrackpadSettings(dragStyle: style))
                scroll.down(1, 64, 66, at: 0)
                scroll.up(1, at: 0.1)
                scroll.down(order[0].0, order[0].1, 66, at: 0.2)
                XCTAssertEqual(scroll.down(order[1].0, order[1].1, 66, at: 0.21), [.contacts(2), mayBegin], "\(style)")
                scroll.glide([Path(2, from: (order[0].1, 66), to: (order[0].1, 56)),
                              Path(3, from: (order[1].1, 66), to: (order[1].1, 56))], from: 0.21, to: 0.4)
                XCTAssertTrue(scrollPhases(scroll.log).contains(.began), "\(style) \(order)")
                XCTAssertEqual(buttons(scroll.log), click(1), "\(style) \(order)")
                XCTAssertEqual(motionSum(scroll.log).y, 0, "\(style) \(order)")
            }
        }
    }

    func testBroadThumbTapThenFingertipTouchIsTapDragInTapDragStyle() {
        var pad = Pad()
        pad.down(1, 64, 72, at: 0, size: .broad)
        XCTAssertEqual(pad.up(1, at: 0.1), click(1))
        XCTAssertEqual(pad.down(2, 64, 72, at: 0.2), [.contacts(1)])
        XCTAssertEqual(pad.up(2, at: 0.3), [.contacts(0)] + click(2))
    }

    func testDragLockSurvivesThumbReclassification() {
        var pad = Pad(TrackpadSettings(dragStyle: .tapDragLock))
        pad.down(1, 64, 70, at: 0)
        pad.up(1, at: 0.1)
        pad.down(2, 64, 70, at: 0.2)
        XCTAssertEqual(pad.advance(0.5), [.button(.left, down: true, clickState: 1)])
        XCTAssertEqual(pad.down(3, 64, 50, at: 0.6), [], "the click-zone contact becomes a thumb")
        let out = pad.glide([Path(3, from: (64, 50), to: (74, 50))], from: 0.6, to: 0.8)
        XCTAssertEqual(motionSum(out).x, 10, accuracy: 1e-6)
        XCTAssertEqual(pad.up(3, at: 0.85), [.contacts(0)])
        XCTAssertEqual(pad.up(2, at: 0.9), [])
        XCTAssertEqual(pad.r.heldButtons, [.left])
        pad.down(4, 74, 40, at: 1.5)
        XCTAssertEqual(pad.up(4, at: 1.6), [.contacts(0), .button(.left, down: false, clickState: 1)])
    }

    func testNonFiniteSettingsAreSanitized() {
        for bad in [Double.nan, .infinity, -1] {
            var pad = Pad(TrackpadSettings(dragReleaseDelay: bad, doubleClickInterval: bad, tapQuiet: bad,
                                           typingBandWindow: bad, topBandMM: bad, sideBandMM: bad,
                                           palmHeelCornerMM: bad))
            pad.down(1, 64, 40, at: 0)
            XCTAssertEqual(clickStates(pad.up(1, at: 0.1)), [1], "\(bad)")
            pad.down(2, 64, 40, at: 0.2)
            pad.glide([Path(2, from: (64, 40), to: (70, 40))], from: 0.2, to: 0.4)
            XCTAssertEqual(pad.r.heldButtons, [.left], "\(bad)")
            XCTAssertEqual(pad.up(2, at: 0.45), [.contacts(0), .button(.left, down: false, clickState: 1)], "\(bad)")
            XCTAssertNil(pad.r.nextDeadline, "\(bad)")
            XCTAssertTrue(pad.r.heldButtons.isEmpty, "\(bad)")
        }
    }

    // MARK: - Invariants

    func testNeverButtonDownOnTouchDown() {
        let styles = DragStyle.allCases
        for seed in 0..<2000 {
            var rng = ScriptRandom(seed: UInt64(seed))
            var settings = TrackpadSettings(dragStyle: styles[rng.int(styles.count)])
            settings.thumbClick = rng.bool()
            settings.restingThumb = rng.bool()
            settings.dragReleaseDelay = rng.bool() ? 0 : 0.4
            settings.threeFingerGestures = rng.bool()
            let scale = [0.7, 1.0, 1.5][rng.int(3)]
            var r = TrackpadRecognizer(geometry: Self.geometry, settings: settings, protectionScale: scale)
            let g = Self.geometry
            var positions: [Int: (Double, Double)] = [:]
            var nextID = 1
            var held = Set<PointerButton>()
            var t = 0.0
            var trace: [String] = []
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: x / g.mmPerPointX, y: y / g.mmPerPointY)
            }
            func check(_ out: [TrackpadOutput], began: Bool) -> Bool {
                for o in out {
                    guard case .button(let b, let isDown, let state) = o else { continue }
                    if began && isDown { XCTFail("seed \(seed): button down in began\n\(trace.joined(separator: "\n"))"); return false }
                    if isDown == held.contains(b) || !(1...3).contains(state) {
                        XCTFail("seed \(seed): unbalanced \(o)\n\(trace.joined(separator: "\n"))"); return false
                    }
                    if isDown { held.insert(b) } else { held.remove(b) }
                }
                if held != r.heldButtons {
                    XCTFail("seed \(seed): held \(held) vs \(r.heldButtons)\n\(trace.joined(separator: "\n"))"); return false
                }
                return true
            }
            for _ in 0..<60 {
                t += [0.004, 0.017, 0.05, 0.12, 0.3][rng.int(5)]
                let roll = rng.int(100)
                var out: [TrackpadOutput]
                var isBegan = false
                if roll < 25 && positions.count < 5 || positions.isEmpty && roll < 70 {
                    let id = nextID
                    nextID += 1
                    let p = (rng.double(-2, 130), rng.double(-2, 82))
                    let size: ContactSize = rng.int(4) == 0 ? .broad : .fingertip
                    positions[id] = p
                    trace.append("t=\(t) began \(id) \(p) \(size)")
                    out = r.began(id: id, at: point(p.0, p.1), size: size, time: t)
                    isBegan = true
                } else if roll < 70, let id = positions.keys.sorted().randomElement(using: &rng) {
                    let old = positions[id] ?? (0, 0)
                    let p = (old.0 + rng.double(-4, 4), old.1 + rng.double(-4, 4))
                    positions[id] = p
                    trace.append("t=\(t) moved \(id) \(p)")
                    out = r.moved(id: id, to: point(p.0, p.1), time: t)
                } else if roll < 85, let id = positions.keys.sorted().randomElement(using: &rng) {
                    positions[id] = nil
                    let cancelled = rng.int(5) == 0
                    trace.append("t=\(t) ended \(id) cancelled \(cancelled)")
                    out = r.ended(id: id, time: t, cancelled: cancelled)
                } else if roll < 88, let id = positions.keys.sorted().randomElement(using: &rng) {
                    trace.append("t=\(t) rejected \(id)")
                    out = r.rejected(id: id, time: t)
                } else if roll < 94 {
                    trace.append("t=\(t) typing")
                    out = r.noteTyping(at: t)
                } else if roll < 99 {
                    let target = max(t, r.nextDeadline ?? t)
                    t = target
                    trace.append("t=\(t) advance")
                    out = r.advance(to: target)
                    if let next = r.nextDeadline, next <= target {
                        XCTFail("seed \(seed): deadline \(next) not consumed at \(target)"); break
                    }
                } else {
                    trace.append("t=\(t) reset")
                    out = r.reset()
                }
                guard check(out, began: isBegan) else { break }
            }
        }
    }

    func testGlitchedSampleSpeedIsCapped() {
        var pad = Pad()
        pad.down(1, 10, 40, at: 0)
        pad.move(1, 11, 40, at: 0.004)
        let out = pad.move(1, 100, 40, at: 0.005)
        guard case .motion(let dx, _, let dt, let speed)? = out.first else { return XCTFail("\(out)") }
        XCTAssertEqual(dx, 89, accuracy: 1e-6)
        XCTAssertEqual(dt, 0.001, accuracy: 1e-9)
        XCTAssertEqual(speed, 5000)
    }

    func testSettingsDecodeMissingFieldsAsDefaults() throws {
        let decoded = try JSONDecoder().decode(TrackpadSettings.self,
                                               from: Data(#"{"dragStyle":"tapDragLock","tapQuiet":0.4,"future":1}"#.utf8))
        var expected = TrackpadSettings()
        expected.dragStyle = .tapDragLock
        expected.tapQuiet = 0.4
        XCTAssertEqual(decoded, expected)
        let unknownStyle = try JSONDecoder().decode(TrackpadSettings.self, from: Data(#"{"dragStyle":"force"}"#.utf8))
        XCTAssertEqual(unknownStyle, TrackpadSettings())
        let all = TrackpadSettings(dragStyle: .holdToDrag, thumbClick: false, restingThumb: false, dragReleaseDelay: 0.3,
                                   threeFingerGestures: false, lookUpTap: false, doubleClickInterval: 0.8,
                                   tapQuiet: 1, typingBandWindow: 2, topBandMM: 12, sideBandMM: 8, palmHeelCornerMM: 20)
        XCTAssertEqual(try JSONDecoder().decode(TrackpadSettings.self, from: JSONEncoder().encode(all)), all)
    }

    func testGeometryConvertsPointsToMillimetres() {
        let g = TrackpadGeometry(rect: CGRect(x: 100, y: 200, width: 665.1, height: 414.8))
        XCTAssertEqual(g.mmPerPointX, 128.2 / 665.1, accuracy: 1e-12)
        XCTAssertEqual(g.mmPerPointY, 80.05 / 414.8, accuracy: 1e-12)
        let mm = g.toMM(CGPoint(x: 100 + 665.1, y: 200 + 414.8))
        XCTAssertEqual(mm.x, 128.2, accuracy: 1e-9)
        XCTAssertEqual(mm.y, 80.05, accuracy: 1e-9)
        XCTAssertTrue(g.containsMM(x: -0.4, y: 80.4, expandedBy: 0.5))
        XCTAssertFalse(g.containsMM(x: 128.8, y: 40, expandedBy: 0.5))
        XCTAssertFalse(g.containsMM(x: .nan, y: 40, expandedBy: 0.5))
        XCTAssertEqual(TrackpadGeometry(rect: .zero).mmPerPointX, 0)
    }

    // MARK: - Helpers

    private struct Path {
        var id: Int
        var from: (Double, Double)
        var to: (Double, Double)
        init(_ id: Int, from: (Double, Double), to: (Double, Double)) {
            self.id = id
            self.from = from
            self.to = to
        }
    }

    private struct Pad {
        var r: TrackpadRecognizer
        let g: TrackpadGeometry
        var log: [TrackpadOutput] = []

        init(_ settings: TrackpadSettings = .init(), geometry: TrackpadGeometry = TrackpadRecognizerTests.geometry,
             scale: Double = 1) {
            r = TrackpadRecognizer(geometry: geometry, settings: settings, protectionScale: scale)
            g = geometry
        }

        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: Double(g.rect.minX) + x / g.mmPerPointX, y: Double(g.rect.minY) + y / g.mmPerPointY)
        }

        @discardableResult
        mutating func down(_ id: Int, _ x: Double, _ y: Double, at t: Double,
                           size: ContactSize = .fingertip) -> [TrackpadOutput] {
            record(r.began(id: id, at: point(x, y), size: size, time: t))
        }

        @discardableResult
        mutating func move(_ id: Int, _ x: Double, _ y: Double, at t: Double) -> [TrackpadOutput] {
            record(r.moved(id: id, to: point(x, y), time: t))
        }

        @discardableResult
        mutating func up(_ id: Int, at t: Double, cancelled: Bool = false) -> [TrackpadOutput] {
            record(r.ended(id: id, time: t, cancelled: cancelled))
        }

        @discardableResult
        mutating func advance(_ t: Double) -> [TrackpadOutput] { record(r.advance(to: t)) }

        @discardableResult
        mutating func typing(_ t: Double) -> [TrackpadOutput] { record(r.noteTyping(at: t)) }

        /// Moves every path linearly at 120 Hz; all contacts share each frame's timestamp.
        @discardableResult
        mutating func glide(_ paths: [Path], from t0: Double, to t1: Double) -> [TrackpadOutput] {
            let frames = max(1, Int(((t1 - t0) * 120).rounded()))
            var out: [TrackpadOutput] = []
            for k in 1...frames {
                let f = Double(k) / Double(frames)
                let t = t0 + (t1 - t0) * f
                for p in paths {
                    out += move(p.id, p.from.0 + (p.to.0 - p.from.0) * f, p.from.1 + (p.to.1 - p.from.1) * f, at: t)
                }
            }
            return out
        }

        private mutating func record(_ out: [TrackpadOutput]) -> [TrackpadOutput] {
            log += out
            return out
        }
    }

    private let mayBegin = TrackpadOutput.scroll(phase: .mayBegin, dxMM: 0, dyMM: 0, dt: 0, speed: 0,
                                                 releaseVX: nil, releaseVY: nil)

    private func threeDown(_ pad: inout Pad) {
        pad.down(1, 50, 40, at: 0)
        pad.down(2, 64, 40, at: 0.01)
        pad.down(3, 78, 40, at: 0.02)
    }

    private func threePaths(dx: Double, dy: Double) -> [Path] {
        [50.0, 64, 78].enumerated().map { Path($0.offset + 1, from: ($0.element, 40), to: ($0.element + dx, 40 + dy)) }
    }

    private func liftThree(_ pad: inout Pad, at t: Double) {
        pad.up(1, at: t)
        pad.up(2, at: t + 0.01)
        pad.up(3, at: t + 0.02)
    }

    private func click(_ n: Int, _ button: PointerButton = .left) -> [TrackpadOutput] {
        [.button(button, down: true, clickState: n), .button(button, down: false, clickState: n)]
    }

    private func buttons(_ out: [TrackpadOutput]) -> [TrackpadOutput] {
        out.filter { if case .button = $0 { return true } else { return false } }
    }

    private func clickStates(_ out: [TrackpadOutput]) -> [Int] {
        out.compactMap { if case .button(.left, true, let n) = $0 { return n } else { return nil } }
    }

    private func motionSum(_ out: [TrackpadOutput]) -> (x: Double, y: Double) {
        out.reduce((0.0, 0.0)) { sum, o in
            if case .motion(let dx, let dy, _, _) = o { return (sum.0 + dx, sum.1 + dy) }
            return sum
        }
    }

    private func scrollSum(_ out: [TrackpadOutput]) -> (x: Double, y: Double) {
        out.reduce((0.0, 0.0)) { sum, o in
            if case .scroll(_, let dx, let dy, _, _, _, _) = o { return (sum.0 + dx, sum.1 + dy) }
            return sum
        }
    }

    private func scrollPhases(_ out: [TrackpadOutput]) -> [TrackpadScrollPhase] {
        out.compactMap { if case .scroll(let phase, _, _, _, _, _, _) = $0 { return phase } else { return nil } }
    }

    private func contactCounts(_ out: [TrackpadOutput]) -> [Int] {
        out.compactMap { if case .contacts(let n) = $0 { return n } else { return nil } }
    }

    private func gestures(_ out: [TrackpadOutput]) -> [TrackpadOutput] {
        out.filter {
            switch $0 {
            case .swipe, .tap: return true
            default: return false
            }
        }
    }
}

/// Deterministic generator for the property test.
private struct ScriptRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func bool() -> Bool { next() & 1 == 1 }
    mutating func double(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * Double(next() >> 11) / Double(1 << 53)
    }
}
