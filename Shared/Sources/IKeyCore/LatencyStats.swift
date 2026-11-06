import Foundation

/// Rolling window of the most recent latency samples (for example ping/pong round trips).
public struct LatencyStats: Sendable {
    private let capacity: Int
    private var samples: [Double] = []
    private var next = 0

    /// Keeps the newest `capacity` samples (at least 1).
    public init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
        samples.reserveCapacity(self.capacity)
    }

    /// Adds a sample in seconds; negative or non-finite samples are ignored.
    public mutating func add(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        if samples.count < capacity {
            samples.append(seconds)
        } else {
            samples[next] = seconds
        }
        next = (next + 1) % capacity
    }

    public var count: Int { samples.count }

    /// Nearest-rank percentile; `p` is a percentage (50 = median), clamped to 0...100.
    /// Returns nil when empty or when `p` is NaN.
    public func percentile(_ p: Double) -> Double? {
        guard !samples.isEmpty, !p.isNaN else { return nil }
        let sorted = samples.sorted()
        let percent = min(max(p, 0), 100)
        // p * n first keeps whole-number ranks exact (95 * 20 / 100 == 19).
        let rank = Int((percent * Double(sorted.count) / 100).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
