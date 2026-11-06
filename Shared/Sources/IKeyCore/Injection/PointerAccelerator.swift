import Foundation

/// One row of an IOHIDFamily parametric acceleration table (`HIDAccelCurves`).
public struct HIDAccelCurve: Equatable, Sendable {
    public var index, gl, gp, gc, gq, t1, t2: Double

    public init(index: Double, gl: Double, gp: Double, gc: Double, gq: Double, t1: Double, t2: Double) {
        self.index = index
        self.gl = gl
        self.gp = gp
        self.gc = gc
        self.gq = gq
        self.t1 = t1
        self.t2 = t2
    }
}

/// Built-in curve tables plus the parser for live IORegistry curves.
///
/// Provenance: the VoodooI2C Magic Trackpad 2 personality (decoded from 16.16),
/// matched within ~6% to an independent macOS 27 M4 Air fit; medium confidence.
/// Tests lock these values, not their fidelity. Live curves replace them when readable.
public enum HIDCurveTables {
    public static let pointer: [HIDAccelCurve] = [
        (0.0, 1.00, 0.00, 0.00, 7.4, 21), (0.125, 0.99, 0.50, 0.08, 7.3, 20),
        (0.5, 0.98, 0.66, 0.10, 7.2, 19), (0.6875, 0.96, 0.83, 0.12, 7.1, 18),
        (0.875, 0.94, 1.00, 0.15, 7.0, 17), (1.0, 0.92, 1.15, 0.18, 7.0, 16),
        (1.5, 0.89, 1.30, 0.21, 7.0, 15), (2.0, 0.86, 1.45, 0.24, 7.0, 14),
        (2.5, 0.83, 1.66, 0.28, 7.0, 13), (3.0, 1.00, 1.88, 0.36, 7.0, 12),
    ].map { HIDAccelCurve(index: $0.0, gl: $0.1, gp: $0.2, gc: $0.3, gq: 0, t1: $0.4, t2: $0.5) }

    public static let scroll: [HIDAccelCurve] = [
        (0.0, 1.00, 0.0, 6.0), (0.125, 0.95, 0.6, 6.2), (0.5, 0.90, 0.9, 6.4),
        (0.6875, 0.85, 1.2, 6.6), (0.875, 0.80, 1.4, 6.8), (1.0, 0.75, 1.6, 7.0),
        (1.5, 0.70, 1.8, 7.2), (2.0, 0.65, 2.0, 7.4), (2.5, 0.60, 2.2, 7.6),
        (3.0, 0.55, 2.4, 7.8),
    ].map { HIDAccelCurve(index: $0.0, gl: $0.1, gp: $0.2, gc: 0, gq: 0, t1: $0.3, t2: 12) }

    /// Parses an IORegistry `HIDAccelCurves` array. Integer values are 16.16 fixed
    /// point; floating-point values are used as is. Missing gain keys read as 0; a
    /// missing index or tangent key, a non-numeric value or an empty array yields nil.
    public static func parse(_ plist: [[String: Any]]) -> [HIDAccelCurve]? {
        var curves: [HIDAccelCurve] = []
        for entry in plist {
            func required(_ key: String) -> Double? { entry[key].flatMap(number) }
            func gain(_ key: String) -> Double? {
                guard let raw = entry[key] else { return 0 }
                return number(raw)
            }
            guard let index = required("HIDAccelIndex"),
                  let t1 = required("HIDAccelTangentSpeedLinear"),
                  let t2 = required("HIDAccelTangentSpeedParabolicRoot"),
                  let gl = gain("HIDAccelGainLinear"),
                  let gp = gain("HIDAccelGainParabolic"),
                  let gc = gain("HIDAccelGainCubic"),
                  let gq = gain("HIDAccelGainQuartic") else { return nil }
            curves.append(HIDAccelCurve(index: index, gl: gl, gp: gp, gc: gc, gq: gq, t1: t1, t2: t2))
        }
        guard !curves.isEmpty else { return nil }
        return curves.sorted { $0.index < $1.index }
    }

    public static func fixedToDouble(_ v: Int64) -> Double { Double(v) / 65536 }

    /// Reads a plist number; integers (any width) are 16.16 fixed, floating-point values
    /// are used as is. Types are matched exactly because Foundation bridges integral
    /// numbers to NSNumber/Double and back. Booleans are not numbers here.
    private static func number(_ value: Any) -> Double? {
        let result: Double?
        switch value {
        case let n as NSNumber where type(of: value) is NSNumber.Type:
            // CFBoolean singletons (true/false) are rejected rather than read as 1/65536.
            guard n !== NSNumber(value: true), n !== NSNumber(value: false) else { return nil }
            let kind = String(cString: n.objCType)
            result = (kind == "d" || kind == "f") ? n.doubleValue : fixedToDouble(n.int64Value)
        case let v as Double where type(of: value) == Double.self: result = v
        case is Bool where type(of: value) == Bool.self: result = nil
        case let v as any BinaryInteger: result = Int64(exactly: v).map(fixedToDouble)
        case let v as any BinaryFloatingPoint: result = Double(v)
        default: result = nil
        }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
}

/// IOHIDAccelerationAlgorithm parametric curve for one tracking index.
public struct ParametricAccel: Sendable {
    /// The effective row: parameters interpolated between the bracketing table rows.
    let curve: HIDAccelCurve
    private let m0, b0, m1, b1: Double

    public init(curves: [HIDAccelCurve], index: Double) {
        let c = Self.interpolate(curves.sorted { $0.index < $1.index }, at: index)
        curve = c
        m0 = c.gl + 2 * c.t1 * c.gp * c.gp + 3 * c.t1 * c.t1 * pow(c.gc, 3) + 4 * pow(c.t1, 3) * pow(c.gq, 4)
        b0 = Self.f1(c, c.t1) - m0 * c.t1
        let y1 = m0 * c.t2 + b0
        m1 = 2 * y1 * m0
        b1 = y1 * y1 - m1 * c.t2
    }

    /// Output speed for input speed `x` (device units per report).
    public func f(_ x: Double) -> Double {
        guard x.isFinite, x > 0 else { return 0 }
        if curve.t1 == 0 || x <= curve.t1 { return Self.f1(curve, x) }
        if curve.t2 == 0 || x <= curve.t2 { return m0 * x + b0 }
        return (max(0, m1 * x + b1)).squareRoot()
    }

    private static func f1(_ c: HIDAccelCurve, _ x: Double) -> Double {
        c.gl * x + pow(c.gp * x, 2) + pow(c.gc * x, 3) + pow(c.gq * x, 4)
    }

    /// Highest row with index <= requested, linearly interpolated toward the next row.
    /// An empty table gives the identity curve.
    private static func interpolate(_ rows: [HIDAccelCurve], at index: Double) -> HIDAccelCurve {
        guard let first = rows.first else {
            return HIDAccelCurve(index: index, gl: 1, gp: 0, gc: 0, gq: 0, t1: 0, t2: 0)
        }
        guard index.isFinite, let lowPos = rows.lastIndex(where: { $0.index <= index }) else { return first }
        let low = rows[lowPos]
        guard lowPos + 1 < rows.count, index > low.index else { return low }
        let high = rows[lowPos + 1]
        let r = (index - low.index) / (high.index - low.index)
        func lerp(_ k: KeyPath<HIDAccelCurve, Double>) -> Double { low[keyPath: k] + r * (high[keyPath: k] - low[keyPath: k]) }
        return HIDAccelCurve(index: index, gl: lerp(\.gl), gp: lerp(\.gp), gc: lerp(\.gc), gq: lerp(\.gq),
                             t1: lerp(\.t1), t2: lerp(\.t2))
    }
}

/// Converts finger motion in millimetres to Mac points the way the Mac's own
/// trackpad filter would, for a tracking-speed index.
public struct PointerAccelerator: Sendable {
    /// Device resolution the curves are defined in (counts per inch / mm per inch).
    private static let deviceCountsPerInch = 67.0
    private static let pointsPerInch = 96.0
    private static let mmPerInch = 25.4
    private static let crawlSpeed = 0.5

    private let accel: ParametricAccel
    private let reportRate: Double
    private let speedAxisScale: Double
    private let gainScale: Double

    public init(curves: [HIDAccelCurve] = HIDCurveTables.pointer, index: Double, reportRate: Double = 120,
                speedAxisScale: Double = 1, gainScale: Double = 1) {
        accel = ParametricAccel(curves: curves, index: index)
        self.reportRate = reportRate.isFinite && reportRate > 0 ? reportRate : 120
        self.speedAxisScale = speedAxisScale.isFinite && speedAxisScale > 0 ? speedAxisScale : 1
        self.gainScale = gainScale.isFinite && gainScale >= 0 ? gainScale : 1
    }

    /// Gain in Mac points per finger millimetre at the given finger speed.
    public func pointsPerMM(speed mmPerSecond: Double) -> Double {
        let s = mmPerSecond.isFinite ? abs(mmPerSecond) : 0
        guard s >= Self.crawlSpeed else {
            // Limit of the expression below as s -> 0 (f ~ GL·x near zero). This keeps
            // speedAxisScale, unlike the plan's literal 96·GL/25.4·gainScale, so the gain
            // stays continuous at 0.5 mm/s when speedAxisScale != 1 (identical at 1).
            return Self.pointsPerInch * accel.curve.gl * speedAxisScale / Self.mmPerInch * gainScale
        }
        let x = speedAxisScale * Self.deviceCountsPerInch * (s / Self.mmPerInch) / reportRate
        return reportRate * (Self.pointsPerInch / Self.deviceCountsPerInch) * accel.f(x) / s * gainScale
    }

    public func apply(dxMM: Double, dyMM: Double, speed: Double) -> (dx: Double, dy: Double) {
        let gain = pointsPerMM(speed: speed)
        return (dxMM.isFinite ? dxMM * gain : 0, dyMM.isFinite ? dyMM * gain : 0)
    }
}
