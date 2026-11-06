import Foundation

/// Finite-difference velocity over a short trailing window of real touch
/// timestamps. The window spans at least `minWindow` and at least the last two
/// samples, but never more than `maxWindow`, so a pause reads as zero.
public struct VelocityEstimator: Sendable {
    private struct Sample: Sendable { var x, y, t: Double }

    private let minWindow: Double
    private let maxWindow: Double
    private var samples: [Sample] = []
    // Absorbs rounding in timestamps such as k / 240.0.
    private static let epsilon = 1e-9

    public init(minWindow: Double = 0.025, maxWindow: Double = 0.060) {
        let low = minWindow.isFinite ? max(0, minWindow) : 0.025
        self.minWindow = low
        self.maxWindow = maxWindow.isFinite ? max(low, maxWindow) : max(low, 0.060)
    }

    public mutating func add(x: Double, y: Double, at t: TimeInterval) {
        guard x.isFinite, y.isFinite, t.isFinite else { return }
        if let last = samples.last {
            if t < last.t { return }
            if t == last.t { samples.removeLast() }
        }
        samples.append(Sample(x: x, y: y, t: t))
        let horizon = t - maxWindow - Self.epsilon
        if let keep = samples.firstIndex(where: { $0.t >= horizon }), keep > 0 {
            samples.removeFirst(keep)
        }
    }

    /// Speed (mm/s when fed millimetres) at the newest sample.
    public func speed() -> Double {
        let v = velocity()
        return hypot(v.vx, v.vy)
    }

    /// Velocity at lift time `t`; zero when the newest sample is older than `maxWindow`.
    public func releaseVelocity(at t: TimeInterval) -> (vx: Double, vy: Double) {
        guard let newest = samples.last, t.isFinite, t - newest.t <= maxWindow + Self.epsilon else {
            return (0, 0)
        }
        return velocity()
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    private func velocity() -> (vx: Double, vy: Double) {
        guard samples.count >= 2, let newest = samples.last else { return (0, 0) }
        let previous = samples[samples.count - 2]
        let window = min(max(minWindow, newest.t - previous.t), maxWindow)
        guard let oldest = samples.first(where: { newest.t - $0.t <= window + Self.epsilon }) else {
            return (0, 0)
        }
        let dt = newest.t - oldest.t
        guard dt > 0 else { return (0, 0) }
        return ((newest.x - oldest.x) / dt, (newest.y - oldest.y) / dt)
    }
}
