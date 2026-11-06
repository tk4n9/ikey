import Foundation

/// Which drawn keys look pressed, from `KeyFeedback`. A committed key stays visible for at
/// least `minimumVisible` so a quick tap still flashes; resting or rejected keys clear at once.
public struct KeyVisualState: Equatable, Sendable {
    private let minimumVisible: TimeInterval
    private var downTimes: [UInt16: TimeInterval] = [:]
    private var hideTimes: [UInt16: TimeInterval] = [:]
    public private(set) var tentative: Set<UInt16> = []

    public init(minimumVisible: TimeInterval = 0.08) {
        self.minimumVisible = minimumVisible.isFinite ? max(0, minimumVisible) : 0.08
    }

    /// Also drops hides that expired by `time`; call with no feedback at `nextExpiry`.
    public mutating func apply(_ feedback: [KeyFeedback], at time: TimeInterval) {
        for item in feedback {
            switch item {
            case .tentative(let code):
                tentative.insert(code)
            case .committed(let code):
                tentative.remove(code)
                hideTimes[code] = nil
                downTimes[code] = time
            case .released(let code):
                tentative.remove(code)
                if let down = downTimes.removeValue(forKey: code) {
                    let hide = max(time, down + minimumVisible)
                    if hide > time { hideTimes[code] = hide }
                }
            case .restStarted(let code), .rejected(let code):
                tentative.remove(code)
                downTimes[code] = nil
                hideTimes[code] = nil
            }
        }
        hideTimes = hideTimes.filter { $0.value > time }
    }

    public func visiblePressed(at time: TimeInterval) -> Set<UInt16> {
        Set(downTimes.keys).union(hideTimes.filter { $0.value > time }.keys)
    }

    /// Earliest time a released key stops looking pressed.
    public var nextExpiry: TimeInterval? { hideTimes.values.min() }

    public mutating func reset() {
        downTimes.removeAll()
        hideTimes.removeAll()
        tentative.removeAll()
    }
}
