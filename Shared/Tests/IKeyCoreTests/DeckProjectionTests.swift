import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import IKeyCore

// Worked values are regression locks on the constants and the projection formula. The default
// placement is screen-centred; the front-flush physical-overlay placement is kept as an explicit
// reference (`reference: .frontFlush`) with its original worked values.
final class DeckProjectionTests: XCTestCase {
    private let spec = MacBookAirModel.defaultModel.spec
    private let proScreen = CGSize(width: 1376, height: 1032)
    private let airScreen = CGSize(width: 1366, height: 1024)

    private func assertPoint(_ p: CGPoint, _ x: Double, _ y: Double, accuracy: Double = 0.05,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Double(p.x), x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Double(p.y), y, accuracy: accuracy, file: file, line: line)
    }

    private func key(_ id: String) throws -> KeySpec { try XCTUnwrap(spec.key(id: id)) }

    // MARK: - Screen-centred default

    func testScreenCentredProWorkedValues() throws {
        let p = DeckProjection(display: .pro13, spec: spec, screenSize: proScreen)
        XCTAssertTrue(p.isTrueScale)
        XCTAssertEqual(p.ppm, 5.18873, accuracy: 0.00001)
        // Function row top 199.87 to trackpad bottom 5.08 (194.79 mm) centred in 198.89 mm of screen.
        XCTAssertEqual(p.screenCentreMM.x, 0, accuracy: 1e-9)
        XCTAssertEqual(p.screenCentreMM.y, 102.475, accuracy: 1e-9)
        let esc = p.rect(try key("esc").cap)
        assertPoint(esc.origin, -22.80, 10.64)
        assertPoint(p.point(MMPoint(x: spec.keyField.maxX, y: spec.keyField.minY)), 1398.80, 578.55)
        let pad = p.rect(spec.trackpad)
        assertPoint(pad.origin, 355.40, 606.00)
        assertPoint(CGPoint(x: pad.maxX, y: pad.maxY), 1020.60, 1021.36)
        // Equal margins above the function row and below the trackpad (2.05 mm each).
        XCTAssertEqual(Double(esc.minY), Double(1032 - pad.maxY), accuracy: 1e-9)
        XCTAssertEqual(Double(esc.minY) / p.ppm, 2.051, accuracy: 0.001)
        // Symmetric horizontal clip of 4.395 mm per side.
        let left = p.point(MMPoint(x: spec.keyField.minX, y: 100)).x
        let right = p.point(MMPoint(x: spec.keyField.maxX, y: 100)).x
        XCTAssertEqual(Double(-left), Double(right - 1376), accuracy: 1e-9)
        XCTAssertEqual(Double(-left) / p.ppm, 4.395, accuracy: 0.001)
        // The defaulted-spec initialiser and portrait-reported bounds give the same projection.
        XCTAssertEqual(DeckProjection(display: .pro13, screenSize: proScreen), p)
        XCTAssertEqual(DeckProjection(display: .pro13, spec: spec, screenSize: CGSize(width: 1032, height: 1376)), p)
        XCTAssertEqual(DeckProjection(display: .pro13, spec: MacBookAirModel.air13_2022.spec, screenSize: proScreen), p)
    }

    func testScreenCentredAirWorkedValues() throws {
        let p = DeckProjection(display: .air13, spec: spec, screenSize: airScreen)
        XCTAssertEqual(p.ppm, 5.18859, accuracy: 0.00001)
        XCTAssertEqual(p.screenCentreMM.y, 102.475, accuracy: 1e-9)
        let esc = p.rect(try key("esc").cap)
        assertPoint(esc.origin, -27.78, 6.66)
        assertPoint(p.point(MMPoint(x: spec.keyField.maxX, y: spec.keyField.minY)), 1393.78, 574.55)
        let pad = p.rect(spec.trackpad)
        assertPoint(pad.origin, 350.41, 602.00)
        assertPoint(CGPoint(x: pad.maxX, y: pad.maxY), 1015.59, 1017.34)
        XCTAssertEqual(Double(esc.minY), Double(1024 - pad.maxY), accuracy: 1e-9)
        XCTAssertEqual(Double(esc.minY) / p.ppm, 1.283, accuracy: 0.001)
        let left = p.point(MMPoint(x: spec.keyField.minX, y: 100)).x
        XCTAssertEqual(Double(-left) / p.ppm, 5.355, accuracy: 0.001)
        XCTAssertEqual(DeckProjection(display: .air13, screenSize: airScreen), p)
    }

    func testScreenCentredShowsWholeFunctionRowAndTrackpad() {
        for model in MacBookAirModel.allCases {
            let s = model.spec
            for (display, size) in [(IPadDisplaySpec.pro13, proScreen), (.air13, airScreen)] {
                let p = DeckProjection(display: display, spec: s, screenSize: size)
                let fnTop = p.point(MMPoint(x: 0, y: s.functionRowTopY)).y
                let padBottom = p.point(MMPoint(x: 0, y: s.trackpad.minY)).y
                XCTAssertGreaterThan(Double(fnTop), 0, "\(model) \(display.id)")
                XCTAssertLessThan(Double(padBottom), Double(size.height), "\(model) \(display.id)")
                XCTAssertEqual(Double(fnTop), Double(size.height - padBottom), accuracy: 1e-9, "\(model) \(display.id)")
                XCTAssertEqual(Double(p.point(MMPoint(x: s.keyField.midX, y: 0)).x), Double(size.width) / 2, accuracy: 1e-9)
            }
        }
        // M1: function row top 193.04, trackpad bottom 6.00.
        let m1 = DeckProjection(display: .pro13, spec: MacBookAirModel.air13_2020.spec, screenSize: proScreen)
        XCTAssertEqual(m1.screenCentreMM.y, 99.52, accuracy: 1e-9)
    }

    func testScreenCentredClipsTrackpadWhenSpanDoesNotFit() {
        // A short screen (900 pt at the Air's ppm is 173.45 mm < 194.79 mm): function row on the top edge.
        let p = DeckProjection(display: .air13, spec: spec, screenSize: CGSize(width: 1366, height: 900))
        XCTAssertEqual(Double(p.point(MMPoint(x: 0, y: spec.functionRowTopY)).y), 0, accuracy: 1e-9)
        XCTAssertEqual(p.screenCentreMM.y, 113.1412, accuracy: 0.0001)
        XCTAssertEqual(Double(p.point(MMPoint(x: 0, y: spec.trackpad.minY)).y), 1010.69, accuracy: 0.05)
        XCTAssertEqual(p.ppm, 1366 / IPadDisplaySpec.air13.activeWidth, accuracy: 1e-12) // still 1:1
        // With a view origin the function row sits on the screen's top edge, not the view's.
        let inset = DeckProjection(display: .air13, spec: spec, screenSize: CGSize(width: 1366, height: 900),
                                   viewOriginInScreen: CGPoint(x: 0, y: 30))
        XCTAssertEqual(Double(inset.point(MMPoint(x: 0, y: spec.functionRowTopY)).y), -30, accuracy: 1e-9)
    }

    func testNudgesAreOffsetsFromCentredDefault() {
        let base = DeckProjection(display: .pro13, spec: spec, screenSize: proScreen)
        let nudged = DeckProjection(display: .pro13, spec: spec, screenSize: proScreen,
                                    placement: DeckPlacement(offsetXmm: -2.5, offsetYmm: 4))
        XCTAssertEqual(nudged.screenCentreMM.x, base.screenCentreMM.x - 2.5, accuracy: 1e-9)
        XCTAssertEqual(nudged.screenCentreMM.y, base.screenCentreMM.y + 4, accuracy: 1e-9)
        XCTAssertEqual(nudged.ppm, base.ppm)
        let flushBase = DeckProjection(display: .pro13, spec: spec, screenSize: proScreen, reference: .frontFlush)
        let flushNudged = DeckProjection(display: .pro13, spec: spec, screenSize: proScreen,
                                         placement: DeckPlacement(offsetXmm: -2.5, offsetYmm: 4), reference: .frontFlush)
        XCTAssertEqual(flushNudged.screenCentreMM.y - flushBase.screenCentreMM.y, 4, accuracy: 1e-9)
        XCTAssertEqual(DeckPlacement.Reference.allCases, [.screenCentred, .frontFlush])
        XCTAssertEqual(MacBookAirModel.defaultModel, .air13_2025)
    }

    // MARK: - 1:1 lock-in (true physical size at the device's real ppm)

    /// Every expectation is mm (hard-coded MacBook Air M4/M5 dimensions) x the device's real points per
    /// mm (landscape points / active width), tolerance 0.01 pt; drawn through the resolver's full-screen
    /// path at default and nudged placements.
    func testOneToOneDimensionsProAndAir() throws {
        let cases: [(IPadDisplaySpec, ScreenEnvironment, Double)] = [
            (.pro13, ScreenEnvironment(machineID: "iPad16,5", nativePixels: CGSize(width: 2752, height: 2064),
                                       nativeScale: 2, windowPoints: proScreen), 1376 / 265.19),
            (.air13, ScreenEnvironment(machineID: "iPad15,5", nativePixels: CGSize(width: 2732, height: 2048),
                                       nativeScale: 2, windowPoints: airScreen), 1366 / 263.27)
        ]
        let tol = 0.01
        for (display, env, ppm) in cases {
            for placement in [DeckPlacement(), DeckPlacement(offsetXmm: 5, offsetYmm: -8), DeckPlacement(offsetXmm: -3.3, offsetYmm: 7.1)] {
                let r = DeckGeometryResolver.resolve(spec: spec, env: env, overrideID: nil, placement: placement)
                let label = "\(display.id) \(placement)"
                XCTAssertEqual(r.fit, .fullScreen, label)
                XCTAssertTrue(r.isTrueScale, label)
                XCTAssertEqual(r.projection.ppm, ppm, accuracy: 1e-9, label)
                let deck = ResolvedDeck(spec: spec, projection: r.projection)
                func rect(_ id: String) throws -> CGRect { try XCTUnwrap(deck.keys.first { $0.id == id }, id).rect }
                func eq(_ points: CGFloat, _ mm: Double, _ what: String, line: UInt = #line) {
                    XCTAssertEqual(Double(points), mm * ppm, accuracy: tol, "\(label) \(what)", line: line)
                }
                // Column pitch 19.00 mm and cap gap 1.52 mm along every 1u run of the letter rows.
                for row in [["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "lbracket", "rbracket", "backslash"],
                            ["a", "s", "d", "f", "g", "h", "j", "k", "l", "semicolon", "quote"],
                            ["z", "x", "c", "v", "b", "n", "m", "comma", "period", "slash"],
                            ["d1", "d2", "d3", "d4", "d5", "d6", "d7", "d8", "d9", "d0", "minus", "equal"],
                            ["f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12", "touchid"]] {
                    for (a, b) in zip(row, row.dropFirst()) {
                        let ra = try rect(a), rb = try rect(b)
                        eq(rb.minX - ra.minX, 19.00, "pitch \(a)-\(b)")
                        eq(rb.minX - ra.maxX, 1.52, "gap \(a)-\(b)")
                    }
                }
                // Row pitch 18.50 mm and row gap 1.55 mm, function row to bottom row.
                let column = ["f1", "d1", "q", "a", "z", "option_l"]
                for (a, b) in zip(column, column.dropFirst()) {
                    let ra = try rect(a), rb = try rect(b)
                    eq(rb.minY - ra.minY, 18.50, "row pitch \(a)/\(b)")
                    eq(rb.minY - ra.maxY, 1.55, "row gap \(a)/\(b)")
                }
                // Cap sizes.
                for id in ["a", "j", "f5", "touchid", "fn"] {
                    eq(try rect(id).width, 17.48, "\(id) width"); eq(try rect(id).height, 16.95, "\(id) height")
                }
                eq(try rect("esc").width, 26.98, "esc width")
                eq(try rect("tab").width, 26.98, "tab width")
                eq(try rect("capslock").width, 31.73, "caps width")
                eq(try rect("shift_l").width, 41.23, "shift width")
                eq(try rect("command_l").width, 22.23, "command width")
                eq(try rect("space").width, 93.48, "space width")
                for id in ["left", "down", "right"] { eq(try rect(id).height, 8.55, "\(id) height") }
                eq(try rect("up").height, 8.40, "up height")
                for id in ["left", "up", "down", "right"] { eq(try rect(id).width, 17.48, "\(id) width") }
                eq(try rect("down").minY - (try rect("up")).maxY, 0, "up/down touch")
                // Trackpad 128.20 x 80.05 mm, 5.29 mm below the space bar, centred under it.
                eq(deck.trackpad.width, 128.20, "trackpad width")
                eq(deck.trackpad.height, 80.05, "trackpad height")
                eq(deck.trackpad.minY - (try rect("space")).maxY, 5.29, "keyboard to trackpad")
                eq(deck.trackpad.midX - (try rect("command_l")).minX, 79.99, "trackpad centre vs left command")
                eq(deck.trackpad.minX - (try rect("a")).minX, 39.64, "A to trackpad left edge")
                // Key field width 273.98 mm.
                eq(try rect("delete").maxX - (try rect("esc")).minX, 273.98, "key field width")
            }
        }
    }

    // MARK: - Front-flush reference (physical overlay; the former default)

    func testFrontFlushReferenceProWorkedValues() throws {
        let p = DeckProjection(display: .pro13, spec: spec, screenSize: proScreen, reference: .frontFlush)
        XCTAssertTrue(p.isTrueScale)
        XCTAssertEqual(p.ppm, 5.18873, accuracy: 0.00001)
        XCTAssertEqual(p.screenCentreMM.x, 0, accuracy: 1e-9)
        XCTAssertEqual(p.screenCentreMM.y, 8.195 + 199.14 / 2, accuracy: 1e-9)
        let esc = p.rect(try key("esc").cap)
        assertPoint(esc.origin, -22.80, 38.09)
        assertPoint(p.point(MMPoint(x: spec.keyField.maxX, y: spec.keyField.minY)), 1398.80, 606.00)
        let pad = p.rect(spec.trackpad)
        assertPoint(pad.origin, 355.40, 633.45)
        assertPoint(CGPoint(x: pad.maxX, y: pad.maxY), 1020.60, 1048.81)
        // Portrait-reported bounds give the same landscape projection.
        XCTAssertEqual(DeckProjection(display: .pro13, spec: spec, screenSize: CGSize(width: 1032, height: 1376),
                                      reference: .frontFlush), p)
        // Front flush clips 3.24 mm off the trackpad bottom; the screen-centred default does not.
        XCTAssertGreaterThan(Double(pad.maxY), 1032)
        // Same ppm and x as the default; only the vertical translation differs (5.29 mm).
        let centred = DeckProjection(display: .pro13, spec: spec, screenSize: proScreen)
        XCTAssertEqual(centred.ppm, p.ppm)
        XCTAssertEqual(centred.screenCentreMM.x, p.screenCentreMM.x, accuracy: 1e-12)
        XCTAssertEqual(p.screenCentreMM.y - centred.screenCentreMM.y, 5.29, accuracy: 1e-9)
    }

    func testFrontFlushReferenceAirWorkedValues() throws {
        let p = DeckProjection(display: .air13, spec: spec, screenSize: airScreen, reference: .frontFlush)
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
            DeckProjection(display: .pro13, spec: MacBookAirModel.air13_2020.spec, screenSize: proScreen,
                           placement: DeckPlacement(offsetYmm: -4), reference: .frontFlush),
            DeckProjection(display: .air13, spec: spec, screenSize: CGSize(width: 1366, height: 900)),
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
        // Before layout (zero size): no NaN in either reference.
        for reference in DeckPlacement.Reference.allCases {
            let empty = DeckProjection(display: .pro13, spec: spec, screenSize: .zero, reference: reference)
            XCTAssertEqual(empty.ppm, 1)
            XCTAssertTrue(empty.point(p).x.isFinite && empty.point(p).y.isFinite, "\(reference)")
            XCTAssertTrue(empty.screenCentreMM.y.isFinite)
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
        XCTAssertEqual(r.projection, DeckProjection(display: .pro13, spec: spec, screenSize: proScreen))
        XCTAssertEqual(r.projection.screenCentreMM.y, 102.475, accuracy: 1e-9)
        // The reference overload: front flush on request; the 4-argument form is screen-centred.
        let flush = DeckGeometryResolver.resolve(spec: spec, env: pro, overrideID: nil, placement: .init(),
                                                 reference: .frontFlush)
        XCTAssertEqual(flush.projection,
                       DeckProjection(display: .pro13, spec: spec, screenSize: proScreen, reference: .frontFlush))
        XCTAssertEqual(DeckGeometryResolver.resolve(spec: spec, env: pro, overrideID: nil, placement: .init(),
                                                    reference: .screenCentred), r)
        // The resolver centres the deck it is given (the M1 deck differs).
        let m1Spec = MacBookAirModel.air13_2020.spec
        let m1 = DeckGeometryResolver.resolve(spec: m1Spec, env: pro, overrideID: nil, placement: .init())
        XCTAssertEqual(m1.projection, DeckProjection(display: .pro13, spec: m1Spec, screenSize: proScreen))
        XCTAssertEqual(m1.projection.screenCentreMM.y, 99.52, accuracy: 1e-9)

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
        XCTAssertEqual(s.projection, DeckProjection(display: .pro13, spec: spec, screenSize: proScreen,
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
        XCTAssertEqual(DeckGeometryResolver.resolve(spec: spec, env: env, overrideID: nil, placement: .init(),
                                                    reference: .frontFlush), r)
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
