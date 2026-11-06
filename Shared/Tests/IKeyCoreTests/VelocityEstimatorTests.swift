import Foundation
import XCTest
@testable import IKeyCore

final class VelocityEstimatorTests: XCTestCase {
    func test100mmPerSecondAt240HzQuantized() {
        // UIKit reports half-point positions; 0.5 pt is about 0.096 mm on a Pro 13.
        let quantum = 0.5 * 128.2 / 665.1
        var v = VelocityEstimator()
        for k in 0...240 {
            let t = Double(k) / 240
            let x = (100 * t / quantum).rounded() * quantum
            v.add(x: x, y: 0, at: t)
            if k >= 12 { XCTAssertEqual(v.speed(), 100, accuracy: 5, "sample \(k)") }
        }
    }

    func testReleaseVelocityZeroAfterPause() {
        var v = VelocityEstimator()
        for k in 0...24 { v.add(x: Double(k) * 0.5, y: Double(k) * -0.25, at: Double(k) / 120) }
        let last = 24.0 / 120
        let moving = v.releaseVelocity(at: last + 0.01)
        XCTAssertEqual(moving.vx, 60, accuracy: 0.001)
        XCTAssertEqual(moving.vy, -30, accuracy: 0.001)
        let paused = v.releaseVelocity(at: last + 0.08)
        XCTAssertEqual(paused.vx, 0)
        XCTAssertEqual(paused.vy, 0)

        // A finger held still while samples keep arriving also reads zero.
        for k in 25...34 { v.add(x: 12, y: -6, at: Double(k) / 120) }
        let still = v.releaseVelocity(at: 34.0 / 120)
        XCTAssertEqual(still.vx, 0)
        XCTAssertEqual(still.vy, 0)
    }

    func testSingleSampleAndResetReadZero() {
        var v = VelocityEstimator()
        XCTAssertEqual(v.speed(), 0)
        v.add(x: 1, y: 1, at: 0)
        XCTAssertEqual(v.speed(), 0)
        v.add(x: 2, y: 1, at: 0.01)
        XCTAssertEqual(v.speed(), 100, accuracy: 1e-6)
        v.reset()
        XCTAssertEqual(v.speed(), 0)
        XCTAssertEqual(v.releaseVelocity(at: 0.01).vx, 0)
    }

    func testSlowReportRateUsesLastTwoSamples() {
        var v = VelocityEstimator()
        // 30 Hz: the 33 ms gap is wider than the 25 ms minimum window.
        v.add(x: 0, y: 0, at: 0)
        v.add(x: 1, y: 0, at: 1.0 / 30)
        v.add(x: 3, y: 0, at: 2.0 / 30)
        XCTAssertEqual(v.speed(), 60, accuracy: 1e-6)
    }

    func testGapBeyondMaxWindowReadsZero() {
        var v = VelocityEstimator()
        v.add(x: 0, y: 0, at: 0)
        v.add(x: 5, y: 0, at: 0.1)
        XCTAssertEqual(v.speed(), 0)
    }

    func testDuplicateTimestampReplacesSampleAndOldSamplesAreIgnored() {
        var v = VelocityEstimator()
        v.add(x: 0, y: 0, at: 0)
        v.add(x: 1, y: 0, at: 0.01)
        v.add(x: 2, y: 0, at: 0.01)
        XCTAssertEqual(v.speed(), 200, accuracy: 1e-6)
        v.add(x: 50, y: 0, at: 0.005)
        v.add(x: .nan, y: 0, at: 0.02)
        XCTAssertEqual(v.speed(), 200, accuracy: 1e-6)
    }
}
