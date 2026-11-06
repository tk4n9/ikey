import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import IKeyCore

// Worked values are regression locks on the constants and the projection formula.
final class DeckProjectionTests: XCTestCase {
    private let spec = MacBookAirModel.air13_2022.spec
    private let proScreen = CGSize(width: 1376, height: 1032)
    private let airScreen = CGSize(width: 1366, height: 1024)

    private func assertPoint(_ p: CGPoint, _ x: Double, _ y: Double, accuracy: Double = 0.05,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Double(p.x), x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Double(p.y), y, accuracy: accuracy, file: file, line: line)
    }

    private func key(_ id: String) throws -> KeySpec { try XCTUnwrap(spec.key(id: id)) }

    func testProWorkedValues() throws {
        let p = DeckProjection(display: .pro13, screenSize: proScreen)
        XCTAssertTrue(p.isTrueScale)
        XCTAssertEqual(p.ppm, 5.18873, accuracy: 0.00001)
        let esc = p.rect(try key("esc").cap)
        assertPoint(esc.origin, -22.80, 38.09)
        assertPoint(p.point(MMPoint(x: spec.keyField.maxX, y: spec.keyField.minY)), 1398.80, 606.00)
        let pad = p.rect(spec.trackpad)
        assertPoint(pad.origin, 355.40, 633.45)
        assertPoint(CGPoint(x: pad.maxX, y: pad.maxY), 1020.60, 1048.81)
        // Portrait-reported bounds give the same landscape projection.
        XCTAssertEqual(DeckProjection(display: .pro13, screenSize: CGSize(width: 1032, height: 1376)), p)
    }

    func testAirWorkedValues() throws {
        let p = DeckProjection(display: .air13, screenSize: airScreen)
        XCTAssertEqual(p.ppm, 5.18859, accuracy: 0.00001)
        assertPoint(p.rect(try key("esc").cap).origin, -27.78, 32.73)
        let pad = p.rect(spec.trackpad)
        assertPoint(pad.origin, 350.41, 628.07)
        assertPoint(CGPoint(x: pad.maxX, y: pad.maxY), 1015.59, 1043.42)
    }

    func testIsotropic() {
        for display in IPadDisplaySpec.all {
            let p = DeckProjection(display: display, screenSize: proScreen,
                                   placement: DeckPlacement(offsetXmm: 1.3, offsetYmm: -2, scale: 1.007))
            let r = p.rect(MMRect(minX: 3, minY: 40, width: 10, height: 10))
            XCTAssertEqual(r.width, r.height)
            XCTAssertEqual(Double(r.width), 10 * p.ppm, accuracy: 1e-9)
            XCTAssertEqual(p.mmPerPoint * p.ppm, 1, accuracy: 1e-12)
            XCTAssertEqual(Double(p.length(mm: 10)), Double(r.width), accuracy: 1e-9)
        }
    }

    func testRoundTrip() {
        let projections = [
            DeckProjection(display: .pro13, screenSize: proScreen),
            DeckProjection(display: .air13, screenSize: airScreen, viewOriginInScreen: CGPoint(x: 12, y: -7),
                           placement: DeckPlacement(offsetXmm: -3.2, offsetYmm: 5.5, scale: 0.995)),
            DeckProjection.fitting(spec: spec, screenSize: CGSize(width: 1000, height: 800),
                                   viewOriginInScreen: CGPoint(x: 40, y: 30))
        ]
        for p in projections {
            for mm in [MMPoint(x: 0, y: 0), MMPoint(x: -136.99, y: 199.87), MMPoint(x: 152.05, y: 215), MMPoint(x: 17.3, y: 88.8)] {
                let back = p.mm(p.point(mm))
                XCTAssertEqual(back.x, mm.x, accuracy: 1e-9)
                XCTAssertEqual(back.y, mm.y, accuracy: 1e-9)
            }
            let pt = CGPoint(x: 333.25, y: 777.5)
            let again = p.point(p.mm(pt))
            XCTAssertEqual(Double(again.x), Double(pt.x), accuracy: 1e-9)
            XCTAssertEqual(Double(again.y), Double(pt.y), accuracy: 1e-9)
        }
    }

    func testMoreSpaceBoundsSameMM() {
        let standard = DeckProjection(display: .pro13, screenSize: proScreen)
        let moreSpace = DeckProjection(display: .pro13, screenSize: CGSize(width: 1590, height: 1192))
        let a0 = standard.mm(.zero), a1 = standard.mm(CGPoint(x: 1376, y: 1032))
        let b0 = moreSpace.mm(.zero), b1 = moreSpace.mm(CGPoint(x: 1590, y: 1192))
        XCTAssertEqual(a1.x - a0.x, b1.x - b0.x, accuracy: 1e-9)
        XCTAssertEqual(a1.x - a0.x, IPadDisplaySpec.pro13.activeWidth, accuracy: 1e-9)
        XCTAssertEqual(a0.x, b0.x, accuracy: 1e-9)
        // Height differs only by the aspect rounding of the More Space mode (1192 vs 1191.9 pt).
        XCTAssertEqual(a0.y, b0.y, accuracy: 0.05)
        XCTAssertEqual(a0.y - a1.y, b0.y - b1.y, accuracy: 0.1)
    }

    func testNudgeAndScale() throws {
        let base = DeckProjection(display: .pro13, screenSize: proScreen)
        let nudged = DeckProjection(display: .pro13, screenSize: proScreen, placement: DeckPlacement(offsetXmm: 1))
        let a = try key("a").cap, quote = try key("quote").cap
        let at = MMPoint(x: a.minX, y: a.midY)
        XCTAssertEqual(Double(nudged.point(at).x - base.point(at).x), -5.189, accuracy: 0.001)
        XCTAssertEqual(Double(nudged.point(at).y), Double(base.point(at).y), accuracy: 1e-9)
        let up = DeckProjection(display: .pro13, screenSize: proScreen, placement: DeckPlacement(offsetYmm: 1))
        XCTAssertEqual(Double(up.point(at).y - base.point(at).y), 5.189, accuracy: 0.001)

        let scaled = DeckProjection(display: .pro13, screenSize: proScreen, placement: DeckPlacement(scale: 1.005))
        let to = MMPoint(x: quote.minX, y: quote.midY)
        let spanOnGlassMM = Double(scaled.point(to).x - scaled.point(at).x) / base.ppm
        XCTAssertEqual(spanOnGlassMM - 190.0, 0.95, accuracy: 0.001)
    }

    func testDirectInitSanitisesPlacement() {
        let base = DeckProjection(display: .pro13, screenSize: proScreen)
        let p = MMPoint(x: 0, y: 100)
        let nan = DeckProjection(display: .pro13, screenSize: proScreen,
                                 placement: DeckPlacement(offsetXmm: .nan, offsetYmm: .infinity, scale: .nan))
        XCTAssertEqual(nan.ppm, base.ppm, accuracy: 1e-12)
        XCTAssertEqual(nan.point(p), base.point(p))
        for bad in [0.0, -1.0, .infinity] {
            let d = DeckProjection(display: .pro13, screenSize: proScreen, placement: DeckPlacement(scale: bad))
            XCTAssertEqual(d.ppm, 5.18873, accuracy: 0.00001, "scale \(bad)")
        }
        // Finite out-of-range values are not clamped here (the resolver clamps).
        let wide = DeckProjection(display: .pro13, screenSize: proScreen, placement: DeckPlacement(offsetXmm: 20))
        XCTAssertEqual(Double(wide.point(p).x - base.point(p).x), -20 * base.ppm, accuracy: 1e-9)
    }

    func testDetectAndMachine() {
        XCTAssertEqual(IPadDisplaySpec.detect(nativeLandscapePixels: CGSize(width: 2752, height: 2064)), .pro13)
        XCTAssertEqual(IPadDisplaySpec.detect(nativeLandscapePixels: CGSize(width: 2064, height: 2752)), .pro13)
        XCTAssertEqual(IPadDisplaySpec.detect(nativeLandscapePixels: CGSize(width: 2732, height: 2048)), .air13)
        XCTAssertEqual(IPadDisplaySpec.detect(nativeLandscapePixels: CGSize(width: 2048, height: 2732)), .air13)
        XCTAssertNil(IPadDisplaySpec.detect(nativeLandscapePixels: CGSize(width: 2360, height: 1640)))
        XCTAssertNil(IPadDisplaySpec.detect(nativeLandscapePixels: .zero))
        XCTAssertEqual(IPadDisplaySpec.preset(forMachine: "iPad16,5"), .pro13)
        XCTAssertEqual(IPadDisplaySpec.preset(forMachine: "iPad17,4"), .pro13)
        XCTAssertEqual(IPadDisplaySpec.preset(forMachine: "iPad15,5"), .air13)
        XCTAssertEqual(IPadDisplaySpec.preset(forMachine: "iPad14,10"), .air13)
        XCTAssertNil(IPadDisplaySpec.preset(forMachine: "iPad13,8"))
        XCTAssertEqual(IPadDisplaySpec.preset(id: "pro13"), .pro13)
        XCTAssertEqual(IPadDisplaySpec.preset(id: "air13"), .air13)
        XCTAssertNil(IPadDisplaySpec.preset(id: "mini"))
        XCTAssertEqual(IPadDisplaySpec.all.map(\.id), ["pro13", "air13"])
        for d in IPadDisplaySpec.all {
            XCTAssertEqual(d.bodyWidth, d.activeWidth + 2 * d.bezelX, accuracy: 1e-9)
            XCTAssertEqual(d.bodyDepth, d.activeHeight + 2 * d.bezelY, accuracy: 1e-9)
        }
    }

    func testPlacementClamp() {
        let wild = DeckPlacement(offsetXmm: 9, offsetYmm: -20, scale: 1.2)
        XCTAssertEqual(wild.clamped(for: .air13_2022), DeckPlacement(offsetXmm: 5, offsetYmm: -8, scale: 1.01))
        XCTAssertEqual(wild.clamped(for: .air13_2025), DeckPlacement(offsetXmm: 5, offsetYmm: -8, scale: 1.01))
        XCTAssertEqual(wild.clamped(for: .air13_2020), DeckPlacement(offsetXmm: 5, offsetYmm: -12, scale: 1.01))
        XCTAssertEqual(DeckPlacement(offsetXmm: -9, offsetYmm: 20, scale: 0.5).clamped(for: .air13_2020),
                       DeckPlacement(offsetXmm: -5, offsetYmm: 12, scale: 0.99))
        let inRange = DeckPlacement(offsetXmm: 1.2, offsetYmm: -3.4, scale: 1.003)
        XCTAssertEqual(inRange.clamped(for: .air13_2022), inRange)
        XCTAssertEqual(DeckPlacement(offsetXmm: .nan, offsetYmm: .infinity, scale: .nan).clamped(for: .air13_2022),
                       DeckPlacement())
        XCTAssertEqual(DeckPlacement.stepMM, 0.1)
        XCTAssertEqual(DeckPlacement.repeatStepMM, 0.5)
        XCTAssertEqual(DeckPlacement.scaleStep, 0.0005)
    }

    func testPlacementCodable() throws {
        let p = DeckPlacement(offsetXmm: 0.3, offsetYmm: -1.1, scale: 1.0005)
        XCTAssertEqual(try JSONDecoder().decode(DeckPlacement.self, from: JSONEncoder().encode(p)), p)
        let partial = try JSONDecoder().decode(DeckPlacement.self, from: Data(#"{"offsetYmm":2}"#.utf8))
        XCTAssertEqual(partial, DeckPlacement(offsetYmm: 2))
    }

    func testResolverFullScreen() {
        let pro = ScreenEnvironment(machineID: "iPad16,5", nativePixels: CGSize(width: 2064, height: 2752),
                                    nativeScale: 2, windowPoints: proScreen)
        let r = DeckGeometryResolver.resolve(spec: spec, env: pro, overrideID: nil, placement: .init())
        XCTAssertEqual(r.fit, .fullScreen)
        XCTAssertEqual(r.display, .pro13)
        XCTAssertTrue(r.isTrueScale)
        XCTAssertEqual(r.projection, DeckProjection(display: .pro13, screenSize: proScreen))

        let moreSpace = ScreenEnvironment(machineID: "iPad16,5", nativePixels: CGSize(width: 2064, height: 2752),
                                          nativeScale: 1.7308, windowPoints: CGSize(width: 1590, height: 1192))
        let m = DeckGeometryResolver.resolve(spec: spec, env: moreSpace, overrideID: nil, placement: .init())
        XCTAssertEqual(m.fit, .fullScreen)
        XCTAssertTrue(m.isTrueScale)
        XCTAssertEqual(m.projection.ppm, 1590 / IPadDisplaySpec.pro13.activeWidth, accuracy: 1e-9)

        // Placement is clamped and the view origin is honoured.
        let shifted = ScreenEnvironment(machineID: "iPad16,5", nativePixels: CGSize(width: 2752, height: 2064),
                                        nativeScale: 2, windowPoints: proScreen, viewOriginInWindow: CGPoint(x: 0, y: 20))
        let s = DeckGeometryResolver.resolve(spec: spec, env: shifted, overrideID: nil,
                                             placement: DeckPlacement(offsetXmm: 30))
        XCTAssertEqual(s.projection, DeckProjection(display: .pro13, screenSize: proScreen,
                                                    viewOriginInScreen: CGPoint(x: 0, y: 20),
                                                    placement: DeckPlacement(offsetXmm: 5)))
    }

    func testResolverOverrideAndPixelFallback() {
        let unknownID = ScreenEnvironment(machineID: "iPad99,1", nativePixels: CGSize(width: 2048, height: 2732),
                                          nativeScale: 2, windowPoints: CGSize(width: 1366, height: 1024))
        let detected = DeckGeometryResolver.resolve(spec: spec, env: unknownID, overrideID: nil, placement: .init())
        XCTAssertEqual(detected.display, .air13)
        XCTAssertEqual(detected.fit, .fullScreen)
        // An override wins over the machine identifier; the pixel check then uses the override's panel.
        let proEnv = ScreenEnvironment(machineID: "iPad16,5", nativePixels: CGSize(width: 2064, height: 2752),
                                       nativeScale: 2, windowPoints: proScreen)
        let overridden = DeckGeometryResolver.resolve(spec: spec, env: proEnv, overrideID: "air13", placement: .init())
        XCTAssertEqual(overridden.display, .air13)
        XCTAssertEqual(overridden.fit, .windowed)
        let badOverride = DeckGeometryResolver.resolve(spec: spec, env: proEnv, overrideID: "nope", placement: .init())
        XCTAssertEqual(badOverride.display, .pro13)
    }

    func testResolverWindowed() {
        let env = ScreenEnvironment(machineID: "iPad16,5", nativePixels: CGSize(width: 2064, height: 2752),
                                    nativeScale: 2, windowPoints: CGSize(width: 1000, height: 800))
        let r = DeckGeometryResolver.resolve(spec: spec, env: env, overrideID: nil, placement: .init())
        XCTAssertEqual(r.fit, .windowed)
        XCTAssertEqual(r.display, .pro13)
        XCTAssertFalse(r.isTrueScale)
        XCTAssertFalse(r.projection.isTrueScale)
        XCTAssertEqual(r.projection, DeckProjection.fitting(spec: spec, screenSize: CGSize(width: 1000, height: 800)))
    }

    func testResolverPortraitIsWindowed() {
        let env = ScreenEnvironment(machineID: "iPad16,5", nativePixels: CGSize(width: 2064, height: 2752),
                                    nativeScale: 2, windowPoints: CGSize(width: 1032, height: 1376))
        let r = DeckGeometryResolver.resolve(spec: spec, env: env, overrideID: nil, placement: .init())
        XCTAssertEqual(r.fit, .windowed)
        XCTAssertFalse(r.isTrueScale)
    }

    func testResolverUnknownDevice() {
        let env = ScreenEnvironment(machineID: "iPad13,18", nativePixels: CGSize(width: 1640, height: 2360),
                                    nativeScale: 2, windowPoints: CGSize(width: 1180, height: 820))
        let r = DeckGeometryResolver.resolve(spec: spec, env: env, overrideID: nil, placement: .init())
        XCTAssertEqual(r.fit, .unknownDevice)
        XCTAssertNil(r.display)
        XCTAssertFalse(r.isTrueScale)
        XCTAssertEqual(r.projection, DeckProjection.fitting(spec: spec, screenSize: CGSize(width: 1180, height: 820)))
        // A manual override makes an unknown device true scale when its pixels match.
        let overridden = DeckGeometryResolver.resolve(
            spec: spec,
            env: ScreenEnvironment(machineID: "iPad99,9", nativePixels: .zero, nativeScale: 2, windowPoints: proScreen),
            overrideID: "pro13", placement: .init())
        XCTAssertEqual(overridden.fit, .fullScreen)
    }

    func testFittingFallback() {
        let size = CGSize(width: 1000, height: 800)
        let p = DeckProjection.fitting(spec: spec, screenSize: size, viewOriginInScreen: CGPoint(x: 10, y: 20))
        XCTAssertFalse(p.isTrueScale)
        let depth = spec.well.maxY - spec.trackpad.minY
        XCTAssertEqual(p.ppm, min(1000 / 279.6, 800 / depth), accuracy: 1e-9)
        assertPoint(p.point(MMPoint(x: 0, y: (spec.well.maxY + spec.trackpad.minY) / 2)), 490, 380, accuracy: 1e-9)
        // The well and trackpad fit inside the view.
        let well = p.rect(spec.well).offsetBy(dx: 10, dy: 20), pad = p.rect(spec.trackpad).offsetBy(dx: 10, dy: 20)
        for r in [well, pad] {
            XCTAssertTrue(r.minX >= -1e-6 && r.maxX <= 1000 + 1e-6 && r.minY >= -1e-6 && r.maxY <= 800 + 1e-6, "\(r)")
        }
        // Width-limited case.
        let wide = DeckProjection.fitting(spec: spec, screenSize: CGSize(width: 600, height: 900))
        XCTAssertEqual(wide.ppm, 600 / spec.well.width, accuracy: 1e-9)
        // Before layout: no NaN.
        let empty = DeckProjection.fitting(spec: spec, screenSize: .zero)
        XCTAssertTrue(empty.ppm.isFinite && empty.ppm > 0)
        XCTAssertTrue(empty.mm(CGPoint(x: 5, y: 5)).x.isFinite)
    }
}
