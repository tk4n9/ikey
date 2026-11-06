import Foundation
import XCTest
@testable import IKeyCore

final class ScrollSynthesizerTests: XCTestCase {
    private func move(_ s: inout ScrollSynthesizer, _ phase: ScrollInputPhase = .changed, dx: Double = 0, dy: Double,
                      speed: Double = 100, at t: TimeInterval) -> [ScrollFrame] {
        s.input(phase, dxMM: dx, dyMM: dy, dt: 1.0 / 120, speed: speed, releaseVX: nil, releaseVY: nil, at: t)
    }

    private func lift(_ s: inout ScrollSynthesizer, vx: Double = 0, vy: Double, at t: TimeInterval) -> [ScrollFrame] {
        s.input(.ended, dxMM: 0, dyMM: 0, dt: 1.0 / 120, speed: 0, releaseVX: vx, releaseVY: vy, at: t)
    }

    /// Ticks at each deadline until momentum ends; returns every momentum frame.
    private func drain(_ s: inout ScrollSynthesizer, limit: Int = 10_000) -> [ScrollFrame] {
        var frames: [ScrollFrame] = []
        var n = 0
        while let deadline = s.nextDeadline, n < limit {
            frames += s.tick(at: deadline)
            n += 1
        }
        XCTAssertFalse(s.isMomentumActive)
        return frames
    }

    /// A finger flick: may-begin, began, four changes, lift at `release` mm/s.
    private func flick(_ s: inout ScrollSynthesizer, release: Double) -> [ScrollFrame] {
        var frames = s.input(.mayBegin, dxMM: 0, dyMM: 0, dt: 0, speed: 0, releaseVX: nil, releaseVY: nil, at: 0)
        frames += move(&s, .began, dy: 2, at: 0.01)
        for i in 1...4 { frames += move(&s, dy: 2, at: 0.01 + Double(i) / 120) }
        frames += lift(&s, vy: release, at: 0.06)
        return frames
    }

    private func isZero(_ f: ScrollFrame) -> Bool {
        f.pointX == 0 && f.pointY == 0 && f.fixedX == 0 && f.fixedY == 0 && f.lineX == 0 && f.lineY == 0
    }

    func testPhaseSequenceWithMomentum() {
        var s = ScrollSynthesizer()
        let gesture = flick(&s, release: 300)
        XCTAssertEqual(gesture.map(\.phase), [128, 1, 2, 2, 2, 2, 4])
        XCTAssertTrue(gesture.allSatisfy { $0.momentum == 0 })
        XCTAssertTrue(isZero(gesture[0]) && isZero(gesture[6]))
        XCTAssertTrue(gesture[1...5].allSatisfy { $0.pointY > 0 })
        XCTAssertTrue(s.isMomentumActive)
        XCTAssertEqual(s.nextDeadline ?? 0, 0.06 + 1.0 / 120, accuracy: 1e-12)

        let glide = drain(&s)
        XCTAssertGreaterThan(glide.count, 10)
        XCTAssertEqual(glide.first?.momentum, 1)
        XCTAssertGreaterThan(glide.first?.pointY ?? 0, 0)
        XCTAssertTrue(glide.dropFirst().dropLast().allSatisfy { $0.momentum == 2 })
        XCTAssertEqual(glide.last?.momentum, 3)
        XCTAssertTrue(isZero(glide.last!))
        XCTAssertTrue(glide.allSatisfy { $0.phase == 0 })
        XCTAssertNil(s.nextDeadline)
        XCTAssertEqual(s.tick(at: 100), [])
    }

    func testMomentumDecaysAndTicksAtDisplayRate() {
        var s = ScrollSynthesizer()
        _ = flick(&s, release: 300)
        var last = 0.06
        var previous = Int32.max - 1
        for _ in 0..<20 {
            let deadline = s.nextDeadline!
            XCTAssertEqual(deadline - last, 1.0 / 120, accuracy: 1e-9)
            let frame = s.tick(at: deadline)[0]
            XCTAssertLessThanOrEqual(frame.pointY, previous + 1)  // ±1 from sub-pixel carry
            previous = frame.pointY
            last = deadline
        }
        // A tick before any time has passed emits nothing.
        XCTAssertEqual(s.tick(at: last), [])
    }

    func testTouchDuringMomentumEndsFirst() {
        var s = ScrollSynthesizer()
        _ = flick(&s, release: 400)
        _ = s.tick(at: s.nextDeadline!)
        let touch = s.input(.mayBegin, dxMM: 0, dyMM: 0, dt: 0, speed: 0, releaseVX: nil, releaseVY: nil, at: 0.2)
        XCTAssertEqual(touch, [ScrollFrame(momentum: 3), ScrollFrame(phase: 128)])
        XCTAssertFalse(s.isMomentumActive)
        XCTAssertNil(s.nextDeadline)

        // A scroll that begins without may-begin also ends the glide first.
        _ = s.input(.cancelled, dxMM: 0, dyMM: 0, dt: 0, speed: 0, releaseVX: nil, releaseVY: nil, at: 0.21)
        _ = flick(&s, release: 400)
        let frames = move(&s, .began, dy: 1, at: 0.3)
        XCTAssertEqual(frames.map(\.momentum), [3, 0])
        XCTAssertEqual(frames.map(\.phase), [0, 1])

        // stopMomentum is a no-op when nothing glides.
        XCTAssertEqual(s.stopMomentum(at: 0.4), [])
    }

    func testStopMomentumEmitsEnd() {
        var s = ScrollSynthesizer()
        _ = flick(&s, release: 400)
        XCTAssertEqual(s.stopMomentum(at: 0.07), [ScrollFrame(momentum: 3)])
        XCTAssertFalse(s.isMomentumActive)
    }

    func testLiftWithoutMotionCancelled8() {
        var s = ScrollSynthesizer()
        XCTAssertEqual(s.input(.mayBegin, dxMM: 0, dyMM: 0, dt: 0, speed: 0, releaseVX: nil, releaseVY: nil, at: 0),
                       [ScrollFrame(phase: 128)])
        XCTAssertEqual(lift(&s, vy: 500, at: 0.1), [ScrollFrame(phase: 8)])
        XCTAssertFalse(s.isMomentumActive)

        // A cancelled scroll is 8 as well, and never glides.
        _ = move(&s, .began, dy: 3, at: 0.2)
        XCTAssertEqual(s.input(.cancelled, dxMM: 0, dyMM: 0, dt: 0, speed: 0, releaseVX: 500, releaseVY: 500, at: 0.3),
                       [ScrollFrame(phase: 8)])
        XCTAssertFalse(s.isMomentumActive)
        // Nothing open: nothing to end.
        XCTAssertEqual(lift(&s, vy: 500, at: 0.4), [])
    }

    func testZeroDeltaDoesNotBegin() {
        var s = ScrollSynthesizer()
        _ = s.input(.mayBegin, dxMM: 0, dyMM: 0, dt: 0, speed: 0, releaseVX: nil, releaseVY: nil, at: 0)
        XCTAssertEqual(move(&s, .began, dy: 0, at: 0.01), [])
        XCTAssertEqual(move(&s, dy: 1, at: 0.02).map(\.phase), [1])
        XCTAssertEqual(move(&s, dy: 1, at: 0.03).map(\.phase), [2])
    }

    func testNaturalSign() {
        var natural = ScrollSynthesizer(natural: true)
        let n = move(&natural, .began, dx: 10, dy: 10, at: 0)[0]
        XCTAssertGreaterThan(n.pointY, 0)
        XCTAssertGreaterThan(n.pointX, 0)
        XCTAssertGreaterThan(n.lineY, 0)

        var classic = ScrollSynthesizer(natural: false)
        let c = move(&classic, .began, dx: 10, dy: 10, at: 0)[0]
        XCTAssertLessThan(c.pointY, 0)
        XCTAssertLessThan(c.pointX, 0)
        XCTAssertEqual(c.pointY, -n.pointY)

        // Momentum follows the same convention.
        _ = lift(&classic, vy: 300, at: 0.05)
        XCTAssertLessThan(classic.tick(at: classic.nextDeadline!)[0].pointY, 0)
    }

    func testLineRounding() {
        XCTAssertEqual(ScrollSynthesizer.line(0), 0)
        XCTAssertEqual(ScrollSynthesizer.line(0.1), 1)
        XCTAssertEqual(ScrollSynthesizer.line(-0.1), -1)
        XCTAssertEqual(ScrollSynthesizer.line(1.0), 1)
        XCTAssertEqual(ScrollSynthesizer.line(-1.0), -1)
        XCTAssertEqual(ScrollSynthesizer.line(1.9), 1)
        XCTAssertEqual(ScrollSynthesizer.line(2.7), 2)
        XCTAssertEqual(ScrollSynthesizer.line(-2.7), -2)

        // In a frame: 3 points → fixed 0.3 → one line; 25 points → 2 lines.
        var s = ScrollSynthesizer(basePtPerMM: 1)
        let small = move(&s, .began, dy: 3, speed: 0, at: 0)[0]
        XCTAssertEqual(small.pointY, 3)
        XCTAssertEqual(small.fixedY, 0.3, accuracy: 1e-12)
        XCTAssertEqual(small.lineY, 1)
        XCTAssertEqual(small.lineX, 0)
        let large = move(&s, dy: -25, speed: 0, at: 0.01)[0]
        XCTAssertEqual(large.pointY, -25)
        XCTAssertEqual(large.lineY, -2)
    }

    func testSubPixelAccumulationSums() {
        var s = ScrollSynthesizer()
        var frames = move(&s, .began, dy: 0.01, speed: 0.3, at: 0)
        for i in 1..<1000 { frames += move(&s, dy: 0.01, speed: 0.3, at: Double(i) / 120) }
        // 1000 × 0.01 mm × 5 pt/mm at crawl speed (boost 1) = 50 points.
        let points = frames.reduce(0) { $0 + Int($1.pointY) }
        XCTAssertEqual(points, 50, accuracy: 1)
        XCTAssertEqual(frames.reduce(0) { $0 + $1.fixedY }, Double(points) / 10, accuracy: 1e-9)
        XCTAssertTrue(frames.allSatisfy { $0.pointY <= 1 && $0.pointX == 0 })
        XCTAssertTrue(frames.allSatisfy { $0.pointY == 0 ? $0.lineY == 0 : $0.lineY == 1 })
    }

    func testFasterFingerScrollsFurtherPerMillimetre() {
        func points(speed: Double) -> Int32 {
            var s = ScrollSynthesizer()
            return move(&s, .began, dy: 10, speed: speed, at: 0)[0].pointY
        }
        XCTAssertEqual(points(speed: 0.2), 50)
        XCTAssertGreaterThan(points(speed: 100), points(speed: 10))
        XCTAssertGreaterThan(points(speed: 300), points(speed: 100))
        // Boost is capped.
        var capped = ScrollSynthesizer(maxBoost: 2)
        XCTAssertEqual(move(&capped, .began, dy: 10, speed: 5000, at: 0)[0].pointY, 100)
        // speedFactor scales linearly.
        var slow = ScrollSynthesizer(speedFactor: 0.5)
        XCTAssertEqual(move(&slow, .began, dy: 10, speed: 0.2, at: 0)[0].pointY, 25)
    }

    func testMomentumDistanceMonotonicInV0() {
        var previous = 0
        for release in [25.0, 60, 120, 300, 800, 2000] {
            var s = ScrollSynthesizer()
            _ = flick(&s, release: release)
            let distance = drain(&s).reduce(0) { $0 + Int($1.pointY) }
            XCTAssertGreaterThan(distance, previous, "release \(release)")
            previous = distance
        }
    }

    func testNoMomentumBelow20mmPerS() {
        var s = ScrollSynthesizer()
        XCTAssertEqual(flick(&s, release: 19.9).last, ScrollFrame(phase: 4))
        XCTAssertFalse(s.isMomentumActive)
        XCTAssertNil(s.nextDeadline)
        XCTAssertEqual(s.tick(at: 1), [])

        // The release speed is the vector magnitude.
        var diagonal = ScrollSynthesizer()
        _ = move(&diagonal, .began, dy: 2, at: 0)
        _ = lift(&diagonal, vx: 14, vy: 14, at: 0.1)
        XCTAssertFalse(diagonal.isMomentumActive)
        _ = move(&diagonal, .began, dy: 2, at: 0.2)
        _ = lift(&diagonal, vx: -15, vy: 15, at: 0.3)
        XCTAssertTrue(diagonal.isMomentumActive)
        var none = ScrollSynthesizer()
        _ = move(&none, .began, dy: 2, at: 0)
        _ = none.input(.ended, dxMM: 0, dyMM: 0, dt: 0, speed: 0, releaseVX: nil, releaseVY: nil, at: 0.1)
        XCTAssertFalse(none.isMomentumActive)
        var atThreshold = ScrollSynthesizer()
        _ = flick(&atThreshold, release: 20)
        XCTAssertTrue(atThreshold.isMomentumActive)
    }

    func testNeverBothPhasesNonzero() {
        var s = ScrollSynthesizer()
        var frames: [ScrollFrame] = []
        var t = 0.0
        for round in 0..<6 {
            frames += s.input(.mayBegin, dxMM: 0, dyMM: 0, dt: 0, speed: 0, releaseVX: nil, releaseVY: nil, at: t)
            for i in 0..<8 {
                t += 1.0 / 120
                frames += move(&s, i == 0 ? .began : .changed, dx: Double(round) - 2, dy: 1.5, speed: 150, at: t)
            }
            frames += s.input(.ended, dxMM: 0, dyMM: 0, dt: 0, speed: 0, releaseVX: 100, releaseVY: 250, at: t)
            for _ in 0..<(round * 7) {
                guard let d = s.nextDeadline else { break }
                frames += s.tick(at: d)
                t = d
            }
            t += 0.05
        }
        frames += s.cancel(at: t)
        XCTAssertTrue(frames.contains { $0.momentum != 0 })
        for f in frames { XCTAssertTrue(f.phase == 0 || f.momentum == 0, "\(f)") }
    }

    func testCancelEmits4Then3() {
        var scrolling = ScrollSynthesizer()
        _ = move(&scrolling, .began, dy: 2, at: 0)
        XCTAssertEqual(scrolling.cancel(at: 0.1), [ScrollFrame(phase: 4)])
        XCTAssertEqual(scrolling.cancel(at: 0.2), [])

        var gliding = ScrollSynthesizer()
        _ = flick(&gliding, release: 500)
        XCTAssertEqual(gliding.cancel(at: 0.1), [ScrollFrame(momentum: 3)])
        XCTAssertFalse(gliding.isMomentumActive)

        var waiting = ScrollSynthesizer()
        _ = waiting.input(.mayBegin, dxMM: 0, dyMM: 0, dt: 0, speed: 0, releaseVX: nil, releaseVY: nil, at: 0)
        XCTAssertEqual(waiting.cancel(at: 0.1), [ScrollFrame(phase: 8)])
    }

    /// A release-velocity spike is clamped (keeping its direction), so momentum stays
    /// bounded and always ends; an infinite one never starts it.
    func testExtremeReleaseIsClampedAndEnds() {
        var reference = ScrollSynthesizer()
        _ = flick(&reference, release: 3000)
        let cap = drain(&reference).reduce(0) { $0 + Int($1.pointY) }
        XCTAssertGreaterThan(cap, 0)
        for release in [1e5, 1e300, 1e308, -1e308] {
            var s = ScrollSynthesizer()
            _ = flick(&s, release: release)
            XCTAssertTrue(s.isMomentumActive, "release \(release)")
            let glide = drain(&s, limit: 2000)
            let distance = glide.reduce(0) { $0 + Int($1.pointY) }
            // The gesture's sub-pixel remainder may shift the total by one point.
            XCTAssertLessThanOrEqual(abs(abs(distance) - cap), 1, "release \(release)")
            XCTAssertEqual(glide.last?.momentum, 3)
        }
        var infinite = ScrollSynthesizer()
        _ = move(&infinite, .began, dy: 2, at: 0)
        _ = lift(&infinite, vx: .infinity, vy: .nan, at: 0.1)
        XCTAssertFalse(infinite.isMomentumActive)
        // Unbounded settings never leave momentum running.
        var broken = ScrollSynthesizer(basePtPerMM: .infinity)
        _ = flick(&broken, release: 300)
        XCTAssertFalse(broken.isMomentumActive)
    }

    /// Only the sub-pixel part carries over: a delta beyond Int32 is clamped once and
    /// does not replay into later frames after the finger reverses.
    func testHugeDeltaDoesNotReplay() {
        var s = ScrollSynthesizer()
        let first = move(&s, .began, dy: 1e9, at: 0)
        XCTAssertEqual(first.last?.pointY, Int32.max)
        let next = (1...5).flatMap { move(&s, dy: -1, at: Double($0) / 120) }
        XCTAssertTrue(next.allSatisfy { $0.pointY < 0 }, "\(next.map(\.pointY))")
        _ = move(&s, dy: 1e308, at: 0.1)
        _ = move(&s, dy: 1e308, at: 0.11)
        XCTAssertLessThan(move(&s, dy: -1, at: 0.12).last?.pointY ?? 1, 0)
    }
}
