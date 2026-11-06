import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// What the injector reads from the Mac before handling an input: the system cursor, the
/// active display bounds (global, y down) and the Caps Lock state.
public struct PointerEnvironment: Equatable, Sendable {
    public var cursor: CGPoint
    public var displays: [CGRect]
    public var capsLockOn: Bool

    public init(cursor: CGPoint, displays: [CGRect], capsLockOn: Bool) {
        self.cursor = cursor
        self.displays = displays
        self.capsLockOn = capsLockOn
    }
}

/// Sub-point pointer position kept on the Mac side, so slow accelerated motion is not lost
/// to integer rounding, and integer deltas whose running sum equals the requested motion.
public struct VirtualCursor: Sendable {
    /// Another pointing device moved the cursor when it is this far (pt) from every placement
    /// that can still be iKey's own.
    private static let resyncDistance = 1.0
    /// How many placements may be in flight: the Mac may report the cursor before the window
    /// server has applied the latest posts (several frames handled in one receive callback, or
    /// the location read right after posting), and such a lagging report must not pull the
    /// virtual cursor back.
    private static let recentLimit = 8
    /// The placements that can still be reported as iKey's own, newest last; empty before the
    /// first one. The first is the last one the Mac reported (or the resync point), the rest
    /// are still in flight. Anything older has been applied and passed, so the Mac reporting
    /// it again means another device moved the cursor back there (typically onto a clamped
    /// screen edge or corner iKey used earlier).
    private var recent: [CGPoint] = []
    private var remainderX = 0.0, remainderY = 0.0

    public init() {}

    /// Moves by (dx, dy) points. The position is clamped to the displays and the virtual
    /// position follows the clamp, so reversing away from an edge moves at once. Deltas are
    /// the requested (unclamped) motion rounded with the remainder carried to the next move.
    public mutating func move(by dx: Double, dy: Double, env: PointerEnvironment) -> (to: CGPoint, deltaX: Int64, deltaY: Int64) {
        let start = position(env: env)
        let mx = dx.isFinite ? dx : 0, my = dy.isFinite ? dy : 0
        let to = Self.clamp(CGPoint(x: start.x + CGFloat(mx), y: start.y + CGFloat(my)), displays: env.displays)
        recent.append(to)
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
        return (to, Self.carry(&remainderX, mx), Self.carry(&remainderY, my))
    }

    /// Where the next event goes: the virtual position (the newest placement) while the Mac's
    /// cursor is within 1 pt of the newest placement or of one still in flight, otherwise the
    /// Mac's cursor, because something else moved it (or nothing was posted yet). A matched
    /// report shows the window server has applied every placement before it, so those stop
    /// counting as iKey's own. The oldest match wins, so an ambiguous lagging report never
    /// discards a placement that may still be reported.
    mutating func position(env: PointerEnvironment) -> CGPoint {
        if let i = recent.firstIndex(where: { p in
            hypot(Double(env.cursor.x - p.x), Double(env.cursor.y - p.y)) <= Self.resyncDistance
        }) {
            recent.removeFirst(i)
            return recent[recent.count - 1]
        }
        let synced = Self.clamp(env.cursor, displays: env.displays)
        recent = [synced]
        return synced
    }

    /// The nearest point inside a display; the far edges are maxX/maxY - 0.01 because the
    /// rect's max edge belongs to the next display. Without displays `p` is returned as is.
    public static func clamp(_ p: CGPoint, displays: [CGRect]) -> CGPoint {
        let x = Double(p.x).isFinite ? p.x : 0, y = Double(p.y).isFinite ? p.y : 0
        var best: (point: CGPoint, distance: Double)?
        for rect in displays {
            let r = rect.standardized
            guard !r.isNull, r.width > 0, r.height > 0 else { continue }
            let cx = min(max(x, r.minX), r.maxX - 0.01), cy = min(max(y, r.minY), r.maxY - 0.01)
            let d = hypot(Double(cx - x), Double(cy - y))
            if d == 0 { return CGPoint(x: cx, y: cy) }
            if d < (best?.distance ?? .infinity) { best = (CGPoint(x: cx, y: cy), d) }
        }
        return best?.point ?? CGPoint(x: x, y: y)
    }

    /// Rounds the accumulated delta to whole points and keeps the rest.
    private static func carry(_ remainder: inout Double, _ delta: Double) -> Int64 {
        remainder += delta
        let whole = min(max(remainder.rounded(), -1e9), 1e9)
        remainder -= whole
        if !remainder.isFinite || abs(remainder) >= 1 { remainder = 0 }
        return Int64(whole)
    }
}
