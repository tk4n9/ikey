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
    /// bounded and always ends.
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
        // Unbounded settings never leave momentum running.
        var broken = ScrollSynthesizer(basePtPerMM: .infinity)
        _ = flick(&broken, release: 300)
        XCTAssertFalse(broken.isMomentumActive)
    }

    /// Lifts one finger-scroll at velocity (vx, vy) mm/s and drains the glide; returns
    /// the total momentum points per axis and whether momentum started.
    private func glide(vx: Double, vy: Double) -> (x: Int, y: Int, started: Bool) {
        var s = ScrollSynthesizer()
        _ = move(&s, .began, dx: 1, dy: 1, at: 0)
        _ = lift(&s, vx: vx, vy: vy, at: 0.05)
        let started = s.isMomentumActive
        let frames = drain(&s, limit: 2000)
        XCTAssertTrue(frames.isEmpty || frames.last?.momentum == 3)
        return (frames.reduce(0) { $0 + Int($1.pointX) }, frames.reduce(0) { $0 + Int($1.pointY) }, started)
    }

    /// A release whose magnitude overflows, or with infinite components, clamps to the
    /// 3000 mm/s cap keeping its direction; a NaN component counts as 0.
    func testOverflowingReleaseClampsKeepingDirection() {
        let c = 3000 / 2.0.squareRoot()
        let diagonal = glide(vx: c, vy: c)
        XCTAssertGreaterThan(diagonal.x, 0)
        XCTAssertEqual(diagonal.x, diagonal.y, accuracy: 1)
        let right = glide(vx: 3000, vy: 0)
        let left = glide(vx: -3000, vy: 0)
        XCTAssertGreaterThan(right.x, 0)
        XCTAssertLessThan(left.x, 0)

        func check(_ vx: Double, _ vy: Double, _ expected: (x: Int, y: Int, started: Bool), line: UInt = #line) {
            let g = glide(vx: vx, vy: vy)
            XCTAssertTrue(g.started, "(\(vx), \(vy))", line: line)
            XCTAssertEqual(g.x, expected.x, accuracy: 1, "(\(vx), \(vy))", line: line)
            XCTAssertEqual(g.y, expected.y, accuracy: 1, "(\(vx), \(vy))", line: line)
        }
        check(1e308, 1e308, diagonal)                                   // hypot overflows
        check(-1e308, -1e308, (-diagonal.x, -diagonal.y, true))
        check(.infinity, .infinity, diagonal)
        check(.infinity, .nan, right)
        check(.infinity, 5, right)                                      // finite part is dropped
        check(-.infinity, 0, left)
        check(1e308, .nan, right)

        XCTAssertFalse(glide(vx: .nan, vy: .nan).started)
        XCTAssertFalse(glide(vx: .nan, vy: 10).started)                 // below 20 mm/s
    }

    /// A lift at a non-finite, unrepresentable or stale time starts no momentum, so
    /// nextDeadline is never NaN, infinite or unreachable.
    func testUnusableReleaseTimeStartsNoMomentum() {
        for t in [Double.nan, Double.infinity, -Double.infinity, 1e300, -1e300, 1e20, 0.6, -0.6] {
            var s = ScrollSynthesizer()
            _ = move(&s, .began, dy: 2, at: 0)
            XCTAssertEqual(lift(&s, vy: 500, at: t), [ScrollFrame(phase: 4)], "lift at \(t)")
            XCTAssertFalse(s.isMomentumActive, "lift at \(t)")
            XCTAssertNil(s.nextDeadline, "lift at \(t)")
        }
        // Within the gap (finger still for 0.5 s at most) the glide still starts.
        var s = ScrollSynthesizer()
        _ = move(&s, .began, dy: 2, at: 0)
        _ = lift(&s, vy: 500, at: 0.5)
        XCTAssertEqual(s.nextDeadline ?? 0, 0.5 + 1.0 / 120, accuracy: 1e-12)

        // Without a finite input time, only the release time itself is checked.
        var unanchored = ScrollSynthesizer()
        _ = move(&unanchored, .began, dy: 2, at: .nan)
        _ = lift(&unanchored, vy: 500, at: 1e300)
        XCTAssertFalse(unanchored.isMomentumActive)
        _ = move(&unanchored, .began, dy: 2, at: .nan)
        _ = lift(&unanchored, vy: 500, at: 7)
        XCTAssertTrue(unanchored.isMomentumActive)
        XCTAssertFalse(drain(&unanchored).isEmpty)
    }

    /// A tick at a non-finite or rewound clock ends the glide instead of leaving it
    /// active forever; a small rewind (an early timer) is ignored.
    func testBadTickClockEndsMomentum() {
        var s = ScrollSynthesizer()
        _ = flick(&s, release: 500)
        let first = s.nextDeadline!
        XCTAssertEqual(s.tick(at: first).map(\.momentum), [1])
        XCTAssertEqual(s.tick(at: first - 0.5), [])
        XCTAssertTrue(s.isMomentumActive)
        XCTAssertEqual(s.tick(at: s.nextDeadline!).map(\.momentum), [2])
        XCTAssertEqual(s.tick(at: .nan), [ScrollFrame(momentum: 3)])
        XCTAssertFalse(s.isMomentumActive)
        XCTAssertNil(s.nextDeadline)

        var rewound = ScrollSynthesizer()
        _ = flick(&rewound, release: 500)
        _ = rewound.tick(at: rewound.nextDeadline!)
        XCTAssertEqual(rewound.tick(at: -100), [ScrollFrame(momentum: 3)])
        XCTAssertFalse(rewound.isMomentumActive)

        // Before the Begin frame, ending emits nothing.
        for t in [Double.infinity, -Double.infinity, -5] {
            var fresh = ScrollSynthesizer()
            _ = flick(&fresh, release: 500)
            XCTAssertEqual(fresh.tick(at: t), [], "tick at \(t)")
            XCTAssertFalse(fresh.isMomentumActive, "tick at \(t)")
        }
        // A far-future tick decays the glide to nothing and ends it.
        var future = ScrollSynthesizer()
        _ = flick(&future, release: 500)
        _ = future.tick(at: future.nextDeadline!)
        XCTAssertEqual(future.tick(at: 1e300), [ScrollFrame(momentum: 3)])
        XCTAssertFalse(future.isMomentumActive)
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
