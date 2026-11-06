import Foundation
import XCTest
@testable import IKeyCore

final class KeyVisualStateTests: XCTestCase {
    func testMinimumVisible() {
        var v = KeyVisualState()
        v.apply([.tentative(3), .committed(3)], at: 0)
        v.apply([.released(3)], at: 0.01)
        XCTAssertEqual(v.visiblePressed(at: 0.05), [3])
        XCTAssertEqual(v.visiblePressed(at: 0.0799), [3])
        XCTAssertEqual(v.visiblePressed(at: 0.08), [])
        XCTAssertTrue(v.tentative.isEmpty)
    }

    func testTapCommittedAndReleasedTogetherFlashes() {
        var v = KeyVisualState(minimumVisible: 0.1)
        v.apply([.tentative(3), .committed(3), .released(3)], at: 1.0)
        XCTAssertEqual(v.visiblePressed(at: 1.05), [3])
        XCTAssertEqual(v.nextExpiry ?? 0, 1.1, accuracy: 1e-9)
    }

    func testHeldKeyVisibleUntilUp() {
        var v = KeyVisualState()
        v.apply([.committed(38)], at: 0)
        XCTAssertEqual(v.visiblePressed(at: 5), [38])
        XCTAssertNil(v.nextExpiry)
        v.apply([.released(38)], at: 1.0)
        XCTAssertEqual(v.visiblePressed(at: 1.0), [])
        XCTAssertNil(v.nextExpiry)
    }

    func testRestRemovesTentative() {
        var v = KeyVisualState()
        v.apply([.tentative(3), .tentative(38)], at: 0)
        XCTAssertEqual(v.tentative, [3, 38])
        XCTAssertEqual(v.visiblePressed(at: 0.1), [])
        v.apply([.restStarted(3)], at: 0.25)
        XCTAssertEqual(v.tentative, [38])
        v.apply([.rejected(38)], at: 0.3)
        XCTAssertTrue(v.tentative.isEmpty)
    }

    func testRestAndRejectHidePressedKeysAtOnce() {
        var v = KeyVisualState()
        v.apply([.committed(55), .committed(0)], at: 0)
        v.apply([.restStarted(55), .rejected(0)], at: 0.01)
        XCTAssertEqual(v.visiblePressed(at: 0.01), [])
        XCTAssertNil(v.nextExpiry)
    }

    func testSecondContactRestingOrRejectedOnPostedKeyKeepsItPressed() {
        var pipeline = KeyCommitPipeline(settings: TypingSettings(resting: .homeRow, isolatedHold: true))
        var v = KeyVisualState()
        func feed(_ out: [PipelineOutput], _ t: TimeInterval) {
            v.apply(out.compactMap { if case .feedback(let f) = $0 { return f } else { return nil } }, at: t)
        }
        feed(pipeline.land(id: 1, code: 3, at: 0), 0)
        feed(pipeline.advance(to: 0.30), 0.30)       // isolated hold (opt-in) presses F
        feed(pipeline.land(id: 2, code: 3, at: 0.5), 0.5)
        feed(pipeline.advance(to: 0.9), 0.9)         // the second contact rests
        XCTAssertEqual(pipeline.phase(of: 2), .resting)
        XCTAssertEqual(pipeline.postedCodes, [3])
        XCTAssertEqual(v.visiblePressed(at: 0.9), [3])
        feed(pipeline.land(id: 3, code: 3, at: 1.0), 1.0)
        feed(pipeline.reject(id: 3, at: 1.01), 1.01)
        XCTAssertEqual(v.visiblePressed(at: 1.01), [3])
        feed(pipeline.lift(id: 1, at: 1.2), 1.2)
        XCTAssertEqual(pipeline.postedCodes, [])
        XCTAssertEqual(v.visiblePressed(at: 1.2), [])
        XCTAssertTrue(v.tentative.isEmpty)
    }

    func testNextExpiry() {
        var v = KeyVisualState()
        v.apply([.committed(1), .committed(2)], at: 0)
        v.apply([.released(2)], at: 0.01)
        v.apply([.committed(3)], at: 0.02)
        v.apply([.released(1), .released(3)], at: 0.03)
        XCTAssertEqual(v.nextExpiry ?? 0, 0.08, accuracy: 1e-9)
        v.apply([], at: 0.08)
        XCTAssertEqual(v.nextExpiry ?? 0, 0.10, accuracy: 1e-9)
        XCTAssertEqual(v.visiblePressed(at: 0.08), [3])
        v.apply([.committed(3)], at: 0.09)
        XCTAssertNil(v.nextExpiry, "Pressed again before hiding")
        v.reset()
        XCTAssertEqual(v.visiblePressed(at: 0.09), [])
        XCTAssertEqual(v, KeyVisualState())
    }
}
