import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Deterministic "hold still" detector: fires once when `fingers` tracked contacts have all been
/// down for `holdTime` without any of them travelling more than `maxTravelPt` from where it began.
/// An early lift or too much travel cancels; a cancelled or fired hold ignores new contacts until
/// every tracked contact has lifted. Callers pass monotonic times and call `advance(to:)` at
/// `nextDeadline`; a contact that moves or lifts after the deadline has passed still fires.
public struct HoldDetector: Sendable {
    private enum Phase: Equatable, Sendable {
        case idle
        /// Fewer than `fingers` contacts are down.
        case collecting
        /// All fingers down since `since`.
        case armed(since: TimeInterval)
        /// The deadline passed before a move or lift was seen; fires at the next `advance`.
        case due(at: TimeInterval)
        /// Fired or cancelled; waits for the tracked contacts to lift.
        case finished
    }

    private let holdTime: TimeInterval
    private let maxTravelPt: Double
    private let fingers: Int
    private var starts: [Int: CGPoint] = [:]
    private var phase = Phase.idle

    public init(holdTime: TimeInterval = 0.6, maxTravelPt: Double, fingers: Int = 1) {
        self.holdTime = holdTime.isFinite && holdTime > 0 ? holdTime : 0.6
        self.maxTravelPt = maxTravelPt.isNaN ? 0 : max(0, maxTravelPt)
        self.fingers = max(1, fingers)
    }

    public mutating func began(id: Int, at p: CGPoint, time: TimeInterval) {
        switch phase {
        case .idle, .collecting:
            guard starts[id] == nil, starts.count < fingers else { return }
            guard p.x.isFinite, p.y.isFinite else {
                phase = starts.isEmpty ? .idle : .finished
                return
            }
            starts[id] = p
            phase = starts.count == fingers ? .armed(since: time) : .collecting
        case .armed, .due, .finished:
            return
        }
    }

    public mutating func moved(id: Int, to p: CGPoint, time: TimeInterval) {
        guard let start = starts[id] else { return }
        if markDueIfOverdue(at: time) { return }
        let travel = hypot(Double(p.x - start.x), Double(p.y - start.y))
        if !(travel <= maxTravelPt) { cancel() }
    }

    public mutating func ended(id: Int, time: TimeInterval) {
        guard starts[id] != nil else { return }
        if !markDueIfOverdue(at: time) { cancel() }
        starts[id] = nil
        if starts.isEmpty, phase == .finished { phase = .idle }
    }

    /// True exactly once, when the hold completes at or before `time`.
    public mutating func advance(to time: TimeInterval) -> Bool {
        guard nextDeadline.map({ time >= $0 }) == true else { return false }
        phase = starts.isEmpty ? .idle : .finished
        return true
    }

    /// (time - start) / holdTime clamped to 0...1 while every finger is down; nil otherwise.
    public func progress(at time: TimeInterval) -> Double? {
        switch phase {
        case .armed(let since): return min(1, max(0, (time - since) / holdTime))
        case .due: return 1
        case .idle, .collecting, .finished: return nil
        }
    }

    public var nextDeadline: TimeInterval? {
        switch phase {
        case .armed(let since): return since + holdTime
        case .due(let at): return at
        case .idle, .collecting, .finished: return nil
        }
    }

    public mutating func reset() {
        starts.removeAll()
        phase = .idle
    }

    /// Whether `id` takes part in the current hold (the engine rejects contacts it ignores).
    func isTracking(_ id: Int) -> Bool { starts[id] != nil }

    private mutating func markDueIfOverdue(at time: TimeInterval) -> Bool {
        if case .due = phase { return true }
        guard case .armed(let since) = phase, time >= since + holdTime else { return false }
        phase = .due(at: since + holdTime)
        return true
    }

    private mutating func cancel() {
        switch phase {
        case .collecting, .armed: phase = .finished
        case .idle, .due, .finished: break
        }
    }
}
