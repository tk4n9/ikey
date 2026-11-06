import Foundation
import XCTest
@testable import IKeyCore

final class PointerAcceleratorTests: XCTestCase {
    private let speeds: [Double] = [10, 50, 100, 150, 300, 600]

    private func assertGains(index: Double, _ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
        let accel = PointerAccelerator(index: index)
        for (s, want) in zip(speeds, expected) {
            XCTAssertEqual(accel.pointsPerMM(speed: s), want, accuracy: want * 0.01, "speed \(s)", file: file, line: line)
        }
    }

    func testGainTableIndex06875() {
        assertGains(index: 0.6875, [4.20, 6.50, 9.38, 12.28, 21.08, 31.28])
    }

    func testGainTableIndex1() {
        assertGains(index: 1.0, [4.58, 9.00, 14.57, 20.20, 37.40, 56.98])
    }

    func testMonotonicOutputSpeed() {
        let indices = HIDCurveTables.pointer.map(\.index) + [0.3, 0.8, 2.75]
        for index in indices {
            let accel = PointerAccelerator(index: index)
            var previous = 0.0
            for step in 0...4000 {
                let s = 0.5 + Double(step) * 0.5
                let out = accel.pointsPerMM(speed: s) * s
                XCTAssertGreaterThan(out, previous, "index \(index) speed \(s)")
                previous = out
            }
        }
    }

    func testContinuityAtT1T2() {
        for curves in [HIDCurveTables.pointer, HIDCurveTables.scroll] {
            for row in curves {
                let accel = ParametricAccel(curves: curves, index: row.index)
                for t in [row.t1, row.t2] {
                    let below = accel.f(t - 1e-7), at = accel.f(t), above = accel.f(t + 1e-7)
                    XCTAssertEqual(below, at, accuracy: 1e-5, "index \(row.index) t \(t)")
                    XCTAssertEqual(above, at, accuracy: 1e-5, "index \(row.index) t \(t)")
                }
            }
        }
    }

    func testCurveSegments() {
        // Linear-only row: f1 = x up to T1, the tangent line to T2, then the root segment.
        let row = HIDAccelCurve(index: 0, gl: 1, gp: 0, gc: 0, gq: 0, t1: 2, t2: 4)
        let accel = ParametricAccel(curves: [row], index: 0)
        XCTAssertEqual(accel.f(1), 1, accuracy: 1e-12)
        XCTAssertEqual(accel.f(3), 3, accuracy: 1e-12)
        // m0 = 1, b0 = 0, y1 = 4, m1 = 8, b1 = -16 → sqrt(8·9 - 16)
        XCTAssertEqual(accel.f(9), (56.0).squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(accel.f(0), 0)
        XCTAssertEqual(accel.f(-3), 0)
        XCTAssertEqual(accel.f(.nan), 0)
        // T1 == 0 keeps the polynomial everywhere.
        let poly = ParametricAccel(curves: [HIDAccelCurve(index: 0, gl: 1, gp: 1, gc: 0, gq: 0, t1: 0, t2: 5)], index: 0)
        XCTAssertEqual(poly.f(10), 10 + 100, accuracy: 1e-9)
    }

    func testInterpolationBetweenRows() {
        let table = HIDCurveTables.pointer
        let low = table[2], high = table[3]  // 0.5 and 0.6875
        let mid = (low.index + high.index) / 2
        let curve = ParametricAccel(curves: table, index: mid).curve
        XCTAssertEqual(curve.gl, (low.gl + high.gl) / 2, accuracy: 1e-12)
        XCTAssertEqual(curve.gp, (low.gp + high.gp) / 2, accuracy: 1e-12)
        XCTAssertEqual(curve.gc, (low.gc + high.gc) / 2, accuracy: 1e-12)
        XCTAssertEqual(curve.t1, (low.t1 + high.t1) / 2, accuracy: 1e-12)
        XCTAssertEqual(curve.t2, (low.t2 + high.t2) / 2, accuracy: 1e-12)
        for s in speeds {
            let a = PointerAccelerator(index: low.index).pointsPerMM(speed: s)
            let b = PointerAccelerator(index: high.index).pointsPerMM(speed: s)
            let m = PointerAccelerator(index: mid).pointsPerMM(speed: s)
            XCTAssertGreaterThan(m, min(a, b), "speed \(s)")
            XCTAssertLessThan(m, max(a, b), "speed \(s)")
        }
        // Exact rows, out-of-range indices and unsorted input.
        XCTAssertEqual(ParametricAccel(curves: table, index: 0.6875).curve, high)
        XCTAssertEqual(ParametricAccel(curves: table, index: -1).curve, table[0])
        XCTAssertEqual(ParametricAccel(curves: table, index: 9).curve, table[table.count - 1])
        XCTAssertEqual(ParametricAccel(curves: table.reversed(), index: 0.6875).curve, high)
        XCTAssertEqual(ParametricAccel(curves: [], index: 1).f(3), 3)
    }

    func testCrawlLimit() {
        let accel = PointerAccelerator(index: 0.6875)
        let crawl = 96 * 0.96 / 25.4
        XCTAssertEqual(accel.pointsPerMM(speed: 0), crawl, accuracy: 1e-12)
        XCTAssertEqual(accel.pointsPerMM(speed: 0.49), crawl, accuracy: 1e-12)
        XCTAssertEqual(accel.pointsPerMM(speed: -0.2), crawl, accuracy: 1e-12)
        XCTAssertEqual(accel.pointsPerMM(speed: .nan), crawl, accuracy: 1e-12)
        // The formula meets the crawl limit at the switch-over.
        XCTAssertEqual(accel.pointsPerMM(speed: 0.5), crawl, accuracy: crawl * 0.01)
        let scaled = PointerAccelerator(index: 0.6875, gainScale: 1.5)
        XCTAssertEqual(scaled.pointsPerMM(speed: 0.1), crawl * 1.5, accuracy: 1e-12)
        XCTAssertEqual(scaled.pointsPerMM(speed: 100), accel.pointsPerMM(speed: 100) * 1.5, accuracy: 1e-9)
    }

    func testApplyScalesBothAxes() {
        let accel = PointerAccelerator(index: 0.6875)
        let gain = accel.pointsPerMM(speed: 150)
        let out = accel.apply(dxMM: 2, dyMM: -0.5, speed: 150)
        XCTAssertEqual(out.dx, 2 * gain, accuracy: 1e-12)
        XCTAssertEqual(out.dy, -0.5 * gain, accuracy: 1e-12)
        XCTAssertEqual(out.dx, 24.56, accuracy: 0.25)
        let bad = accel.apply(dxMM: .infinity, dyMM: 1, speed: 10)
        XCTAssertEqual(bad.dx, 0)
    }

    private func fixed(_ v: Double) -> Int { Int((v * 65536).rounded()) }

    private func fixedRow(_ row: HIDAccelCurve) -> [String: Any] {
        ["HIDAccelIndex": fixed(row.index), "HIDAccelGainLinear": fixed(row.gl),
         "HIDAccelGainParabolic": fixed(row.gp), "HIDAccelGainCubic": fixed(row.gc),
         "HIDAccelGainQuartic": fixed(row.gq), "HIDAccelTangentSpeedLinear": fixed(row.t1),
         "HIDAccelTangentSpeedParabolicRoot": fixed(row.t2)]
    }

    private func assertRow(_ got: HIDAccelCurve?, _ want: HIDAccelCurve, file: StaticString = #filePath, line: UInt = #line) {
        guard let got else { return XCTFail("missing row", file: file, line: line) }
        for k in [\HIDAccelCurve.index, \.gl, \.gp, \.gc, \.gq, \.t1, \.t2] {
            XCTAssertEqual(got[keyPath: k], want[keyPath: k], accuracy: 1e-4, file: file, line: line)
        }
    }

    func testParseFixedPointPlist() {
        let row = HIDCurveTables.pointer[3]
        XCTAssertEqual(row.index, 0.6875)
        assertRow(HIDCurveTables.parse([fixedRow(row)])?.first, row)

        // IORegistry values arrive as integer NSNumbers.
        let boxed = fixedRow(row).mapValues { NSNumber(value: Int64($0 as! Int)) as Any }
        assertRow(HIDCurveTables.parse([boxed])?.first, row)

        // Floating-point values are used as is, also when boxed; rows come back sorted.
        var doubles = fixedRow(HIDCurveTables.pointer[5]).mapValues { Double($0 as! Int) / 65536 as Any }
        doubles["HIDAccelGainLinear"] = NSNumber(value: 0.92)
        let parsed = HIDCurveTables.parse([doubles, fixedRow(row)])
        XCTAssertEqual(parsed?.count, 2)
        assertRow(parsed?.first, row)
        assertRow(parsed?.last, HIDCurveTables.pointer[5])

        // Missing gains read as zero.
        let sparse: [String: Any] = ["HIDAccelIndex": 0, "HIDAccelTangentSpeedLinear": fixed(7),
                                     "HIDAccelTangentSpeedParabolicRoot": fixed(12)]
        assertRow(HIDCurveTables.parse([sparse])?.first,
                  HIDAccelCurve(index: 0, gl: 0, gp: 0, gc: 0, gq: 0, t1: 7, t2: 12))

        XCTAssertEqual(HIDCurveTables.fixedToDouble(65536), 1)
        XCTAssertEqual(HIDCurveTables.fixedToDouble(45056), 0.6875)
        XCTAssertEqual(HIDCurveTables.fixedToDouble(-32768), -0.5)
    }

    func testParsedCurvesDriveAccelerator() throws {
        let curves = try XCTUnwrap(HIDCurveTables.parse(HIDCurveTables.pointer.map(fixedRow)))
        XCTAssertEqual(curves.count, HIDCurveTables.pointer.count)
        let live = PointerAccelerator(curves: curves, index: 0.6875)
        XCTAssertEqual(live.pointsPerMM(speed: 150), 12.28, accuracy: 0.12)
    }

    func testParseRejectsMissingIndex() {
        let good = fixedRow(HIDCurveTables.pointer[3])
        for key in ["HIDAccelIndex", "HIDAccelTangentSpeedLinear", "HIDAccelTangentSpeedParabolicRoot"] {
            var bad = good
            bad.removeValue(forKey: key)
            XCTAssertNil(HIDCurveTables.parse([good, bad]), key)
        }
        var wrongType = good
        wrongType["HIDAccelGainLinear"] = "fast"
        XCTAssertNil(HIDCurveTables.parse([wrongType]))
        var notFinite = good
        notFinite["HIDAccelIndex"] = Double.nan
        XCTAssertNil(HIDCurveTables.parse([notFinite]))
        XCTAssertNil(HIDCurveTables.parse([]))
    }

    /// The crawl gain keeps speedAxisScale (the continuous limit of the main formula),
    /// so the gain does not jump at 0.5 mm/s when the speed axis is scaled.
    func testCrawlLimitWithSpeedAxisScale() {
        let accel = PointerAccelerator(index: 0.6875, speedAxisScale: 2)
        let crawl = 96 * 0.96 * 2 / 25.4
        XCTAssertEqual(accel.pointsPerMM(speed: 0.49), crawl, accuracy: 1e-12)
        XCTAssertEqual(accel.pointsPerMM(speed: 0.5), crawl, accuracy: crawl * 0.02)
        let scaled = PointerAccelerator(index: 0.6875, speedAxisScale: 2, gainScale: 0.5)
        XCTAssertEqual(scaled.pointsPerMM(speed: 0.1), crawl * 0.5, accuracy: 1e-12)
    }

    func testParseAcceptsAnyNumericType() {
        let row = HIDCurveTables.pointer[3]
        var mixed = fixedRow(row)
        mixed["HIDAccelIndex"] = UInt64(45056)
        mixed["HIDAccelTangentSpeedLinear"] = Int32(fixed(row.t1))
        mixed["HIDAccelTangentSpeedParabolicRoot"] = UInt(fixed(row.t2))
        mixed["HIDAccelGainLinear"] = CGFloat(row.gl)
        mixed["HIDAccelGainParabolic"] = Float(row.gp)
        mixed["HIDAccelGainCubic"] = NSNumber(value: Int32(fixed(row.gc)))
        mixed["HIDAccelGainQuartic"] = Int16(0)
        assertRow(HIDCurveTables.parse([mixed])?.first, row)

        // Booleans are not numbers, and an integer beyond Int64 is rejected.
        var boolean = fixedRow(row)
        boolean["HIDAccelGainCubic"] = NSNumber(value: true)
        XCTAssertNil(HIDCurveTables.parse([boolean]))
        boolean["HIDAccelGainCubic"] = false
        XCTAssertNil(HIDCurveTables.parse([boolean]))
        var huge = fixedRow(row)
        huge["HIDAccelIndex"] = UInt64.max
        XCTAssertNil(HIDCurveTables.parse([huge]))
    }
}
