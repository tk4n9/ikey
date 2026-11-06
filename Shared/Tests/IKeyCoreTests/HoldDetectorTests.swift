import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import IKeyCore

final class HoldDetectorTests: XCTestCase {
    /// 4 mm at the Pro 13 true scale (5.189 pt/mm).
    private let travel = 4 * 5.189
    private let origin = CGPoint(x: 100, y: 100)

    func testFiresAt06() {
        var h = HoldDetector(maxTravelPt: travel)
        h.began(id: 1, at: origin, time: 1.0)
        XCTAssertEqual(h.nextDeadline ?? 0, 1.6, accuracy: 1e-9)
        XCTAssertFalse(h.advance(to: 1.599))
        h.moved(id: 1, to: CGPoint(x: 103, y: 102), time: 1.3)
        XCTAssertTrue(h.advance(to: 1.6))
        XCTAssertFalse(h.advance(to: 3), "fires once")
        XCTAssertNil(h.nextDeadline)
        h.ended(id: 1, time: 3.1)
        // A new hold can start after the lift.
        h.began(id: 2, at: origin, time: 4)
        XCTAssertTrue(h.advance(to: 4.6))
    }

    func testCancelOn4mm() {
        var h = HoldDetector(maxTravelPt: travel)
        h.began(id: 1, at: origin, time: 0)
        h.moved(id: 1, to: CGPoint(x: origin.x + travel * 0.99, y: origin.y), time: 0.2)
        XCTAssertNotNil(h.nextDeadline)
        h.moved(id: 1, to: CGPoint(x: origin.x + travel * 1.01, y: origin.y), time: 0.3)
        XCTAssertNil(h.nextDeadline)
        XCTAssertFalse(h.advance(to: 2))
        // Coming back does not revive it, and a second contact is ignored until the lift.
        h.moved(id: 1, to: origin, time: 0.4)
        h.began(id: 2, at: origin, time: 0.5)
        XCTAssertFalse(h.advance(to: 2))
        h.ended(id: 1, time: 2.1)
        h.began(id: 3, at: origin, time: 2.2)
        XCTAssertTrue(h.advance(to: 2.81))
    }

    func testNonFiniteMoveCancels() {
        var h = HoldDetector(maxTravelPt: travel)
        h.began(id: 1, at: origin, time: 0)
        h.moved(id: 1, to: CGPoint(x: CGFloat.nan, y: 0), time: 0.1)
        XCTAssertFalse(h.advance(to: 1))
    }

    func testEarlyLift() {
        var h = HoldDetector(maxTravelPt: travel)
        h.began(id: 1, at: origin, time: 0)
        h.ended(id: 1, time: 0.59)
        XCTAssertFalse(h.advance(to: 1))
        XCTAssertNil(h.progress(at: 0.7))
        // Lifting after the deadline but before an advance still fires (the hold completed).
        h.began(id: 2, at: origin, time: 1)
        h.ended(id: 2, time: 1.7)
        XCTAssertTrue(h.advance(to: 1.7))
        XCTAssertNil(h.nextDeadline)
    }

    func testTwoFingerMode() {
        var h = HoldDetector(holdTime: 0.8, maxTravelPt: travel, fingers: 2)
        h.began(id: 1, at: origin, time: 0)
        XCTAssertNil(h.nextDeadline, "waits for the second finger")
        XCTAssertFalse(h.advance(to: 2))
        h.began(id: 2, at: CGPoint(x: 150, y: 100), time: 2.0)
        XCTAssertEqual(h.nextDeadline ?? 0, 2.8, accuracy: 1e-9)
        h.began(id: 3, at: origin, time: 2.1)   // a third finger is not tracked
        h.ended(id: 3, time: 2.2)
        XCTAssertFalse(h.advance(to: 2.79))
        XCTAssertTrue(h.advance(to: 2.8))

        var early = HoldDetector(holdTime: 0.8, maxTravelPt: travel, fingers: 2)
        early.began(id: 1, at: origin, time: 0)
        early.began(id: 2, at: origin, time: 0.1)
        early.ended(id: 2, time: 0.5)
        XCTAssertFalse(early.advance(to: 2))
        early.ended(id: 1, time: 2.1)
        early.began(id: 4, at: origin, time: 3)
        early.began(id: 5, at: origin, time: 3)
        XCTAssertTrue(early.advance(to: 3.8))

        var moved = HoldDetector(holdTime: 0.8, maxTravelPt: travel, fingers: 2)
        moved.began(id: 1, at: origin, time: 0)
        moved.began(id: 2, at: origin, time: 0)
        moved.moved(id: 2, to: CGPoint(x: 100, y: 130), time: 0.4)
        XCTAssertFalse(moved.advance(to: 1))
    }

    func testProgress() {
        var h = HoldDetector(maxTravelPt: travel)
        XCTAssertNil(h.progress(at: 0))
        h.began(id: 1, at: origin, time: 1)
        XCTAssertEqual(h.progress(at: 1) ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(h.progress(at: 1.3) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(h.progress(at: 0.5) ?? -1, 0, accuracy: 1e-9, "clamped below")
        XCTAssertEqual(h.progress(at: 5) ?? -1, 1, accuracy: 1e-9, "clamped above")
        XCTAssertTrue(h.advance(to: 1.6))
        XCTAssertNil(h.progress(at: 1.6))
        h.reset()
        XCTAssertNil(h.progress(at: 2))
        h.began(id: 1, at: origin, time: 2)
        XCTAssertEqual(h.progress(at: 2.15) ?? -1, 0.25, accuracy: 1e-9, "reset forgets every contact")
    }

    func testInvalidParametersFallBack() {
        var h = HoldDetector(holdTime: .nan, maxTravelPt: .nan, fingers: 0)
        h.began(id: 1, at: origin, time: 0)
        XCTAssertEqual(h.nextDeadline ?? 0, 0.6, accuracy: 1e-9)
        h.moved(id: 1, to: CGPoint(x: 100.5, y: 100), time: 0.1)
        XCTAssertFalse(h.advance(to: 1), "NaN travel limit means no travel allowed")
    }
}
