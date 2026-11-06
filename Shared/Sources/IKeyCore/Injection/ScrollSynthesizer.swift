import Foundation

/// One continuous scroll-wheel event in CGEvent field terms. Axis 1 is vertical
/// (pointY/fixedY/lineY), axis 2 horizontal. `phase` is the CGScrollPhase
/// (1 began, 2 changed, 4 ended, 8 cancelled, 128 may-begin) and `momentum` the
/// CGMomentumScrollPhase (1 begin, 2 continue, 3 end); at most one is nonzero.
public struct ScrollFrame: Equatable, Sendable {
    public var pointX, pointY: Int32
    public var fixedX, fixedY: Double
    public var lineX, lineY: Int32
    public var phase: Int64
    public var momentum: Int64

    public init(pointX: Int32 = 0, pointY: Int32 = 0, fixedX: Double = 0, fixedY: Double = 0,
                lineX: Int32 = 0, lineY: Int32 = 0, phase: Int64 = 0, momentum: Int64 = 0) {
        self.pointX = pointX
        self.pointY = pointY
        self.fixedX = fixedX
        self.fixedY = fixedY
        self.lineX = lineX
        self.lineY = lineY
        self.phase = phase
        self.momentum = momentum
    }
}

public enum ScrollInputPhase: Sendable { case mayBegin, began, changed, ended, cancelled }

/// Turns two-finger scroll motion (mm, UIKit axes) into phased, accelerated
/// scroll frames and generates momentum on the Mac side after a flick.
public struct ScrollSynthesizer: Sendable {
    private enum Phase {
        static let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4, cancelled: Int64 = 8, mayBegin: Int64 = 128
    }
    private enum Momentum {
        static let begin: Int64 = 1, continuing: Int64 = 2, end: Int64 = 3
    }
    private enum Gesture { case idle, mayBegan, scrolling }
    private struct Glide {
        var vx, vy: Double      // wheel points per second
        let alpha: Double       // decay per 8 ms
        var lastTick: TimeInterval
        var begun = false
    }

    /// Release speed (mm/s) below which a lift does not start momentum.
    private static let momentumMinRelease = 20.0
    /// Release speeds above this (mm/s) are clamped, keeping the direction: a fast
    /// real flick is about 1-2 m/s, so anything beyond is an estimator spike.
    private static let momentumMaxRelease = 3000.0
    /// Momentum ends once it slows below this (points/s).
    private static let momentumStopSpeed = 1.0
    private static let tickInterval = 1.0 / 120
    /// A lift more than this far (s) from the gesture's last scroll input, or at a
    /// time that cannot carry 1/120 s ticks, starts no momentum: the timestamp is
    /// stale or on another clock, and a glide from it could never be ticked.
    private static let momentumMaxReleaseGap = 0.5
    /// A tick this far (s) before the last one means the clock is inconsistent: the
    /// glide ends instead of waiting for time to catch up.
    private static let momentumMaxClockRewind = 1.0

    public var natural: Bool
    public var basePtPerMM: Double
    public var speedFactor: Double

    private let accel: ParametricAccel
    private let maxBoost: Double
    private var gesture = Gesture.idle
    private var glide: Glide?
    private var remainderX = 0.0, remainderY = 0.0
    private var lastScrollInput: TimeInterval?

    public init(natural: Bool = true, basePtPerMM: Double = 5.0, speedFactor: Double = 1.0, scrollIndex: Double = 0.6875,
                maxBoost: Double = 8, curves: [HIDAccelCurve] = HIDCurveTables.scroll) {
        self.natural = natural
        self.basePtPerMM = basePtPerMM
        self.speedFactor = speedFactor
        accel = ParametricAccel(curves: curves, index: scrollIndex)
        self.maxBoost = maxBoost.isFinite ? max(1, maxBoost) : 8
    }

    public var isMomentumActive: Bool { glide != nil }

    public var nextDeadline: TimeInterval? { glide.map { $0.lastTick + Self.tickInterval } }

    /// - Parameters: dxMM/dyMM are finger deltas in UIKit axes (y down); `speed` is the
    ///   finger speed in mm/s (derived from the deltas and `dt` when not finite);
    ///   releaseVX/VY are the lift velocity in mm/s, used on `.ended`.
    public mutating func input(_ phase: ScrollInputPhase, dxMM: Double, dyMM: Double, dt: Double, speed: Double,
                               releaseVX: Double?, releaseVY: Double?, at now: TimeInterval) -> [ScrollFrame] {
        switch phase {
        case .mayBegin:
            var frames = stopMomentum(at: now)
            if gesture == .scrolling { frames.append(ScrollFrame(phase: Phase.ended)) }
            beginGesture()
            gesture = .mayBegan
            frames.append(ScrollFrame(phase: Phase.mayBegin))
            return frames

        case .began, .changed:
            var frames: [ScrollFrame] = []
            if gesture != .scrolling {
                frames += stopMomentum(at: now)
                if gesture == .idle { beginGesture() }
            }
            if now.isFinite { lastScrollInput = now }
            let dx = Self.finite(dxMM), dy = Self.finite(dyMM)
            guard dx != 0 || dy != 0 else { return frames }
            let v = speed.isFinite && speed >= 0 ? speed : (dt > 0 ? (dx * dx + dy * dy).squareRoot() / dt : 0)
            let gain = basePtPerMM * speedFactor * boost(mmPerSecond: v) * sign
            let code = gesture == .scrolling ? Phase.changed : Phase.began
            gesture = .scrolling
            frames.append(emit(x: dx * gain, y: dy * gain, phase: code, momentum: 0))
            return frames

        case .ended:
            switch gesture {
            case .idle:
                return []
            case .mayBegan:
                gesture = .idle
                return [ScrollFrame(phase: Phase.cancelled)]
            case .scrolling:
                gesture = .idle
                startMomentum(releaseVX: releaseVX, releaseVY: releaseVY, at: now)
                return [ScrollFrame(phase: Phase.ended)]
            }

        case .cancelled:
            guard gesture != .idle else { return [] }
            gesture = .idle
            return [ScrollFrame(phase: Phase.cancelled)]
        }
    }

    /// Ends momentum (for example when a finger touches the pad), emitting the End frame.
    public mutating func stopMomentum(at now: TimeInterval) -> [ScrollFrame] {
        guard glide != nil else { return [] }
        glide = nil
        return [ScrollFrame(momentum: Momentum.end)]
    }

    /// Advances momentum to `now`; call at `nextDeadline`.
    public mutating func tick(at now: TimeInterval) -> [ScrollFrame] {
        guard var g = glide else { return [] }
        // A non-finite or rewound clock can never advance the glide: end it.
        guard now.isFinite, now >= g.lastTick - Self.momentumMaxClockRewind else {
            glide = nil
            return g.begun ? [ScrollFrame(momentum: Momentum.end)] : []
        }
        guard now > g.lastTick else { return [] }
        let dt = now - g.lastTick
        let decay = pow(g.alpha, dt / 0.008)
        g.vx *= decay
        g.vy *= decay
        g.lastTick = now
        let v = (g.vx * g.vx + g.vy * g.vy).squareRoot()
        guard v.isFinite, v >= Self.momentumStopSpeed else {
            glide = nil
            return g.begun ? [ScrollFrame(momentum: Momentum.end)] : []
        }
        let scale = basePtPerMM * speedFactor
        let b = scale > 0 ? boost(mmPerSecond: v / scale) : 1
        let code = g.begun ? Momentum.continuing : Momentum.begin
        g.begun = true
        glide = g
        return [emit(x: b * g.vx * dt, y: b * g.vy * dt, phase: 0, momentum: code)]
    }

    /// Closes everything for a session reset: an open scroll ends (4), momentum ends (3).
    public mutating func cancel(at now: TimeInterval) -> [ScrollFrame] {
        var frames: [ScrollFrame] = []
        switch gesture {
        case .scrolling: frames.append(ScrollFrame(phase: Phase.ended))
        case .mayBegan: frames.append(ScrollFrame(phase: Phase.cancelled))
        case .idle: break
        }
        gesture = .idle
        frames += stopMomentum(at: now)
        return frames
    }

    // MARK: - Private

    /// Natural scrolling: content follows the finger, so the wheel delta equals the
    /// finger delta in UIKit axes (finger down → positive axis 1).
    private var sign: Double { natural ? 1 : -1 }

    private mutating func beginGesture() {
        remainderX = 0
        remainderY = 0
        lastScrollInput = nil
    }

    private mutating func startMomentum(releaseVX: Double?, releaseVY: Double?, at now: TimeInterval) {
        // The first deadline (now + 1/120) must be finite and later than now, or no
        // tick could ever advance or end the glide.
        guard now.isFinite, now + Self.tickInterval > now else { return }
        if let last = lastScrollInput, abs(now - last) > Self.momentumMaxReleaseGap { return }
        let (rx, ry, release) = Self.clampedRelease(releaseVX ?? 0, releaseVY ?? 0)
        let scale = basePtPerMM * speedFactor
        guard release >= Self.momentumMinRelease, scale.isFinite, scale > 0 else { return }
        let vx = rx * scale * sign, vy = ry * scale * sign
        let v0 = (vx * vx + vy * vy).squareRoot()
        guard v0.isFinite else { return }
        let alpha = 0.975 - 0.065 * max(0, (250 - v0) / 250)
        glide = Glide(vx: vx, vy: vy, alpha: alpha, lastTick: now)
    }

    /// The release velocity (mm/s) and its speed, clamped to `momentumMaxRelease`
    /// keeping its direction. A NaN component counts as 0; infinite components set the
    /// direction (the finite one then counts as 0) and clamp to the cap. Components
    /// are normalised first, so a speed that overflows still clamps instead of
    /// collapsing to zero.
    private static func clampedRelease(_ vx: Double, _ vy: Double) -> (x: Double, y: Double, speed: Double) {
        var x = vx.isNaN ? 0 : vx, y = vy.isNaN ? 0 : vy
        let infinite = x.isInfinite || y.isInfinite
        if infinite {
            x = x.isInfinite ? (x > 0 ? 1 : -1) : 0
            y = y.isInfinite ? (y > 0 ? 1 : -1) : 0
        }
        let m = max(abs(x), abs(y))
        guard m > 0 else { return (0, 0, 0) }
        let ux = x / m, uy = y / m
        let n = hypot(ux, uy)  // 1...√2
        let speed = m * n      // +inf when the true speed overflows
        guard infinite || speed > momentumMaxRelease else { return (x, y, speed) }
        let k = momentumMaxRelease / n
        return (ux * k, uy * k, momentumMaxRelease)
    }

    /// Speed-dependent gain from the scroll curve, relative to its linear slope.
    private func boost(mmPerSecond v: Double) -> Double {
        let gl = accel.curve.gl
        guard v >= 0.5, gl > 0 else { return 1 }
        let x = 67 * (v / 25.4) / 120
        let b = accel.f(x) / (gl * x)
        return b.isFinite ? min(b, maxBoost) : 1
    }

    /// Integer points carry their sub-pixel remainder; fixed = points / 10. Only the
    /// sub-pixel part carries over, so a delta beyond the Int32 range is clamped, not
    /// replayed in later frames.
    private mutating func emit(x: Double, y: Double, phase: Int64, momentum: Int64) -> ScrollFrame {
        remainderX += Self.finite(x)
        remainderY += Self.finite(y)
        let px = Self.int32(remainderX.rounded(.towardZero)), py = Self.int32(remainderY.rounded(.towardZero))
        remainderX = Self.subPixel(remainderX - Double(px))
        remainderY = Self.subPixel(remainderY - Double(py))
        let fx = Double(px) / 10, fy = Double(py) / 10
        return ScrollFrame(pointX: px, pointY: py, fixedX: fx, fixedY: fy, lineX: Self.line(fx), lineY: Self.line(fy),
                           phase: phase, momentum: momentum)
    }

    /// Line delta: any nonzero value up to one line rounds away from zero, larger ones truncate.
    static func line(_ fixed: Double) -> Int32 {
        if fixed == 0 { return 0 }
        if abs(fixed) <= 1 { return fixed > 0 ? 1 : -1 }
        return int32(fixed.rounded(.towardZero))
    }

    private static func int32(_ v: Double) -> Int32 { Int32(max(Double(Int32.min), min(Double(Int32.max), v))) }

    private static func finite(_ v: Double) -> Double { v.isFinite ? v : 0 }

    private static func subPixel(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return abs(v) < 1 ? v : v.truncatingRemainder(dividingBy: 1)
    }
}
