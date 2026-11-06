import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import IKeyCore

final class DeckSceneTests: XCTestCase {
    private let proScreen = CGSize(width: 1376, height: 1032)
    private let airScreen = CGSize(width: 1366, height: 1024)

    private func scene(model: MacBookAirModel = .defaultModel, display: IPadDisplaySpec = .pro13,
                       screen: CGSize? = nil, viewBounds: CGRect? = nil, displayScale: Double = 2,
                       finish: DeckFinish? = nil, pressLook: PressLook = .subtle) -> (DeckScene, DeckProjection) {
        let size = screen ?? (display == .pro13 ? proScreen : airScreen)
        let spec = model.spec
        let projection = DeckProjection(display: display, spec: spec, screenSize: size)
        let finish = finish ?? model.defaultFinish
        let scene = DeckScene.build(spec: spec, projection: projection,
                                    palette: DeckPalette.palette(finish),
                                    nightPalette: DeckPalette.palette(finish, night: 1),
                                    legendStyle: model.legendStyle,
                                    viewBounds: viewBounds ?? CGRect(origin: .zero, size: size),
                                    displayScale: displayScale, pressLook: pressLook)
        return (scene, projection)
    }

    private func snapped(_ r: CGRect, scale: Double) -> CGRect {
        func s(_ v: CGFloat) -> Double { (Double(v) * scale).rounded() / scale }
        return CGRect(x: s(r.minX), y: s(r.minY), width: s(r.maxX) - s(r.minX), height: s(r.maxY) - s(r.minY))
    }

    private func assertRect(_ r: CGRect, _ expected: CGRect, accuracy: Double = 1e-9,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Double(r.minX), Double(expected.minX), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Double(r.minY), Double(expected.minY), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Double(r.width), Double(expected.width), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Double(r.height), Double(expected.height), accuracy: accuracy, file: file, line: line)
    }

    private func isOnPixelGrid(_ v: CGFloat, scale: Double) -> Bool {
        let px = Double(v) * scale
        return abs(px - px.rounded()) < 1e-6
    }

    /// The rect an op draws in (text ops have none).
    private func rect(of op: DrawOp) -> CGRect? {
        switch op {
        case .fill(let r, _), .roundedRect(let r, _, _, _), .innerShadow(let r, _, _, _), .dropShadow(let r, _, _, _, _),
             .symbol(_, let r, _), .triangle(let r, _, _), .ellipse(let r, _, _), .noise(let r, _, _):
            return r
        case .strokeRects(let rects, _, _):
            return rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
        case .text:
            return nil
        }
    }

    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && a.maxX > b.minX && a.minY < b.maxY && a.maxY > b.minY
    }

    // MARK: - Tests

    func testDeterministic() {
        for model in MacBookAirModel.allCases {
            for look in PressLook.allCases {
                let first = scene(model: model, pressLook: look).0
                let second = scene(model: model, pressLook: look).0
                XCTAssertEqual(first, second)
            }
        }
        XCTAssertNotEqual(scene(finish: .midnight).0, scene(finish: .silver).0)
    }

    func testCulling() throws {
        let (full, projection) = scene()
        // Left third of the screen, above the trackpad.
        let view = CGRect(x: 0, y: 0, width: 400, height: 500)
        let (part, _) = scene(viewBounds: view)
        XCTAssertLessThan(part.base.count, full.base.count)
        XCTAssertLessThan(part.legends.count, full.legends.count)
        XCTAssertLessThan(part.pressedAtlas.count, full.pressedAtlas.count)
        for op in part.base + part.legends + part.glow + part.pressedAtlas {
            if let r = rect(of: op) {
                XCTAssertTrue(overlaps(r, view), "\(op) is outside \(view)")
            }
        }
        // Text is kept or culled with its cap: L (right of 400 pt) is gone, A stays.
        let texts = part.legends.compactMap { op -> String? in
            if case .text(let s, _, _, _, _) = op { return s } else { return nil }
        }
        XCTAssertTrue(texts.contains("A"))
        XCTAssertFalse(texts.contains("L"))
        let pad = snapped(projection.rect(MacBookAirModel.defaultModel.spec.trackpad), scale: 2)
        XCTAssertFalse(part.base.contains { rect(of: $0) == pad })
        XCTAssertTrue(full.base.contains { rect(of: $0) == pad })
        // Frames are data, not ops: they are never culled.
        XCTAssertEqual(part.keyFrames, full.keyFrames)
        XCTAssertEqual(part.trackpadRect, full.trackpadRect)

        // A view that misses the deck entirely keeps nothing.
        let (none, _) = scene(viewBounds: CGRect(x: 5000, y: 5000, width: 10, height: 10))
        XCTAssertTrue(none.base.isEmpty && none.legends.isEmpty && none.glow.isEmpty && none.pressedAtlas.isEmpty)

        // The clipped edge keys stay drawn on the full screen.
        let escFrame = try XCTUnwrap(full.keyFrames[53])
        XCTAssertLessThan(Double(escFrame.minX), 0)
        XCTAssertTrue(full.base.contains { rect(of: $0) == escFrame })
    }

    func testKeyFrameAEqualsProjectedCapSnapped() throws {
        for scale in [1.0, 2.0, 3.0] {
            for display in IPadDisplaySpec.all {
                let (s, projection) = scene(display: display, displayScale: scale)
                let spec = MacBookAirModel.defaultModel.spec
                let a = try XCTUnwrap(spec.key(id: "a"))
                let frame = try XCTUnwrap(s.keyFrames[0])
                assertRect(frame, snapped(projection.rect(a.cap), scale: scale))
                XCTAssertEqual(s.keyIDFrames["a"], frame)
                for edge in [frame.minX, frame.minY, frame.maxX, frame.maxY] {
                    XCTAssertTrue(isOnPixelGrid(edge, scale: scale))
                }
                // True scale survives snapping: the A cap is 17.48 mm wide within one pixel.
                XCTAssertEqual(Double(frame.width), 17.48 * projection.ppm, accuracy: 1 / scale + 1e-9)
            }
        }
        let (s, projection) = scene()
        let spec = MacBookAirModel.defaultModel.spec
        XCTAssertEqual(s.keyFrames.count, spec.keys.count - 1) // Touch ID has no key code
        XCTAssertEqual(s.keyIDFrames.count, spec.keys.count)
        assertRect(s.touchIDRect, snapped(projection.rect(try XCTUnwrap(spec.key(id: "touchid")).cap), scale: 2))
        assertRect(s.trackpadRect, snapped(projection.rect(spec.trackpad), scale: 2))
        // Every op rect lands on the pixel grid.
        for op in s.base + s.legends + s.pressedAtlas {
            guard let r = rect(of: op) else { continue }
            for edge in [r.minX, r.minY, r.maxX, r.maxY] {
                XCTAssertTrue(isOnPixelGrid(edge, scale: 2), "\(op)")
            }
        }
    }

    func testOpBudget() {
        for model in MacBookAirModel.allCases {
            for look in PressLook.allCases {
                let s = scene(model: model, pressLook: look).0
                XCTAssertLessThanOrEqual(s.base.count + s.legends.count, 1500)
                XCTAssertGreaterThan(s.legends.count, 100)
            }
        }
    }

    func testCapsLEDRect() throws {
        for model in MacBookAirModel.allCases {
            let (s, projection) = scene(model: model)
            let caps = projection.rect(try XCTUnwrap(model.spec.key(id: "capslock")).cap)
            let ppm = projection.ppm
            let expected = CGRect(x: Double(caps.minX) + (3.98 - 0.63) * ppm, y: Double(caps.minY) + (4.08 - 0.63) * ppm,
                                  width: 1.26 * ppm, height: 1.26 * ppm)
            assertRect(s.capsLEDRect, snapped(expected, scale: 2))
            XCTAssertEqual(Double(s.capsLEDRect.midX), Double(caps.minX) + 3.98 * ppm, accuracy: 0.5)
            XCTAssertEqual(Double(s.capsLEDRect.midY), Double(caps.minY) + 4.08 * ppm, accuracy: 0.5)
            // The LED is left to its own layer: nothing in the lists draws at its rect.
            XCTAssertFalse((s.base + s.legends + s.glow + s.pressedAtlas).contains { rect(of: $0) == s.capsLEDRect })
        }
    }

    func testFinishesPerModel() {
        XCTAssertEqual(MacBookAirModel.air13_2022.finishes, [.midnight, .starlight, .spaceGray, .silver])
        XCTAssertEqual(MacBookAirModel.air13_2025.finishes, [.skyBlue, .silver, .starlight, .midnight])
        XCTAssertEqual(MacBookAirModel.air13_2020.finishes, [.gold, .silver, .spaceGray])
        XCTAssertEqual(MacBookAirModel.air13_2022.defaultFinish, .midnight)
        XCTAssertEqual(MacBookAirModel.air13_2025.defaultFinish, .skyBlue)
        XCTAssertEqual(MacBookAirModel.air13_2020.defaultFinish, .gold)
    }

    func testLegendStylePerModel() {
        XCTAssertEqual(MacBookAirModel.air13_2025.legendStyle, .modern)
        XCTAssertEqual(MacBookAirModel.air13_2022.legendStyle, .legacy)
        XCTAssertEqual(MacBookAirModel.air13_2020.legendStyle, .legacy)
        // Modern F10 is mute; the half-height M1 row uses its own label size.
        func symbols(_ s: DeckScene) -> [String] {
            s.legends.compactMap { if case .symbol(let n, _, _) = $0 { return n } else { return nil } }
        }
        XCTAssertTrue(symbols(scene(model: .air13_2025).0).contains("speaker.slash"))
        XCTAssertFalse(symbols(scene(model: .air13_2022).0).contains("speaker.slash"))
        let m1Labels = scene(model: .air13_2020).0.legends.compactMap { op -> Double? in
            if case .text("F1", let size, _, _, _) = op { return size } else { return nil }
        }
        XCTAssertEqual(m1Labels, [2.0])
    }

    func testPaletteUsedForChassisFill() {
        for finish in DeckFinish.allCases {
            let (s, projection) = scene(finish: finish)
            let chassis = snapped(projection.rect(MacBookAirModel.defaultModel.spec.chassis), scale: 2)
            XCTAssertEqual(s.base.first, .fill(chassis, DeckPalette.palette(finish).deck))
            XCTAssertEqual(s.base.dropFirst().first, .noise(chassis, amplitude: 0.015, seed: 0x694B))
        }
    }

    func testGlowListMatchesLegendCount() {
        let palette = DeckPalette.palette(.midnight), night = DeckPalette.palette(.midnight, night: 1)
        for model in MacBookAirModel.allCases {
            for view in [CGRect(origin: .zero, size: proScreen), CGRect(x: 0, y: 0, width: 300, height: 300)] {
                let s = scene(model: model, viewBounds: view, finish: .midnight).0
                XCTAssertEqual(s.glow.count, s.legends.count)
                // One for one: the same op with the backlit colour instead of the printed one.
                for (legend, glow) in zip(s.legends, s.glow) {
                    XCTAssertEqual(recoloured(legend, palette.legend, night.legendBacklit), glow)
                }
            }
        }
        // Ring, bump, hairline and the LED dot never glow.
        let s = scene().0
        for op in s.glow {
            switch op {
            case .text, .symbol, .triangle, .strokeRects: continue
            default: XCTFail("unexpected glow op \(op)")
            }
        }
    }

    // MARK: - Further structure

    func testBaseOrderAndLayers() throws {
        let (s, projection) = scene()
        let spec = MacBookAirModel.defaultModel.spec
        let palette = DeckPalette.palette(MacBookAirModel.defaultModel.defaultFinish)
        let well = snapped(projection.rect(spec.well), scale: 2)
        XCTAssertEqual(Array(s.base[2...4]), [
            .roundedRect(well, radius: 4.0, fill: .solid(palette.wellFloor), stroke: nil),
            .innerShadow(well, radius: 4.0, depth: 1.2, color: RGBA(r: 0, g: 0, b: 0, a: 0.18)),
            .roundedRect(well, radius: 4.0, fill: .solid(RGBA(r: 0, g: 0, b: 0, a: 0)),
                         stroke: StrokeSpec(color: palette.wellEdge, width: 0.2)),
        ])
        // The trackpad comes after the well and every key, and ends the base.
        let pad = snapped(projection.rect(spec.trackpad), scale: 2)
        let padIndex = try XCTUnwrap(s.base.firstIndex {
            if case .roundedRect(pad, 5.0, .solid(palette.trackpad), StrokeSpec(color: palette.trackpadEdge, width: 0.30)) = $0 {
                return true
            }
            return false
        })
        XCTAssertEqual(s.base.last, .noise(pad, amplitude: 0.005, seed: 0x7470))
        let a = try XCTUnwrap(s.keyFrames[0])
        let capIndex = try XCTUnwrap(s.base.firstIndex(of: .roundedRect(a, radius: 2.0, fill: .solid(palette.keycapRim), stroke: nil)))
        XCTAssertLessThan(capIndex, padIndex)
        XCTAssertTrue(s.base.contains(.dropShadow(a, radius: 2.0, offsetY: 0.20, blur: 0.40, color: RGBA(r: 0, g: 0, b: 0, a: 0.40))))
        // Face: inset 0.40 mm with the vertical keycap gradient.
        let face = s.base[capIndex + 1]
        guard case .roundedRect(let faceRect, let faceRadius, .vertical(palette.keycapFaceTop, palette.keycapFaceBottom), nil) = face else {
            return XCTFail("face \(face)")
        }
        XCTAssertEqual(faceRadius, 1.6, accuracy: 1e-9)
        XCTAssertEqual(Double(faceRect.minX - a.minX), 0.40 * projection.ppm, accuracy: 0.5)
        // Bevel band at the face top, 0.35 mm, keycapBevel at 60 %.
        guard case .roundedRect(let band, _, .solid(let bevel), nil) = s.base[capIndex + 2] else {
            return XCTFail("bevel")
        }
        XCTAssertEqual(band.minY, faceRect.minY)
        XCTAssertEqual(Double(band.height), 0.35 * projection.ppm, accuracy: 0.5)
        XCTAssertEqual(bevel.a, palette.keycapBevel.a * 0.6, accuracy: 1e-12)
        // Cap features are in the base: the Touch ID ring and the f/j bumps.
        XCTAssertTrue(s.base.contains { if case .ellipse(_, nil, StrokeSpec(color: palette.touchIDRing, width: 0.30)) = $0 { return true }; return false })
        let bumps = s.base.filter { if case .roundedRect(_, _, .solid(palette.keycapBevel), nil) = $0 { return true }; return false }
        XCTAssertEqual(bumps.count, 2)
    }

    func testLegendsAreMappedToPoints() throws {
        let (s, projection) = scene()
        let a = projection.rect(try XCTUnwrap(MacBookAirModel.defaultModel.spec.key(id: "a")).cap)
        let ppm = projection.ppm
        let palette = DeckPalette.palette(MacBookAirModel.defaultModel.defaultFinish)
        let baseline = CGPoint(x: Double(a.minX) + 8.74 * ppm, y: Double(a.minY) + 10.40 * ppm)
        XCTAssertTrue(s.legends.contains(.text("A", size: 5.30, baseline: baseline, align: .center, color: palette.legend)))
        // Modifier symbols are SF Symbols, not glyph text; F3 is the Mission Control glyph.
        let symbols = s.legends.compactMap { op -> String? in if case .symbol(let n, _, _) = op { return n }; return nil }
        for name in ["command", "option", "control", "globe"] { XCTAssertTrue(symbols.contains(name), name) }
        XCTAssertEqual(s.legends.filter { if case .strokeRects(let r, 0.20, _) = $0 { return r.count == 3 }; return false }.count, 1)
        XCTAssertEqual(s.legends.filter { if case .triangle = $0 { return true }; return false }.count, 4)
    }

    func testPressedAtlas() throws {
        XCTAssertTrue(scene(pressLook: .off).0.pressedAtlas.isEmpty)
        let (subtle, projection) = scene(pressLook: .subtle)
        let (clear, _) = scene(pressLook: .clear)
        let palette = DeckPalette.palette(MacBookAirModel.defaultModel.defaultFinish)
        let wash = { (op: DrawOp) -> Bool in
            if case .roundedRect(_, _, .solid(RGBA(r: 1, g: 1, b: 1, a: 0.10)), nil) = op { return true }
            return false
        }
        let keyCount = subtle.keyFrames.count
        XCTAssertEqual(subtle.pressedAtlas.filter(wash).count, 0)
        XCTAssertEqual(clear.pressedAtlas.filter(wash).count, keyCount)
        // No bevel band and no drop shadow; one 0.6 mm 30 % inner shadow per pressed key.
        XCTAssertFalse(subtle.pressedAtlas.contains { if case .dropShadow = $0 { return true }; return false })
        XCTAssertFalse(subtle.pressedAtlas.contains { if case .roundedRect(_, _, .solid(let c), nil) = $0 { return c.r == palette.keycapBevel.r && c.a < palette.keycapBevel.a }; return false })
        let shadows = subtle.pressedAtlas.filter {
            if case .innerShadow(_, _, 0.6, RGBA(r: 0, g: 0, b: 0, a: 0.30)) = $0 { return true }; return false
        }
        XCTAssertEqual(shadows.count, keyCount)
        // Face inset 0.15 mm at 0.86 luminance.
        let a = try XCTUnwrap(subtle.keyFrames[0])
        let rim = try XCTUnwrap(subtle.pressedAtlas.firstIndex(of: .roundedRect(a, radius: 2.0, fill: .solid(palette.keycapRim), stroke: nil)))
        guard case .roundedRect(let face, let faceRadius, .vertical(let top, let bottom), nil) = subtle.pressedAtlas[rim + 1] else {
            return XCTFail("pressed face")
        }
        XCTAssertEqual(faceRadius, 1.85, accuracy: 1e-9)
        XCTAssertEqual(Double(face.minX - a.minX), 0.15 * projection.ppm, accuracy: 0.5)
        XCTAssertEqual(top.relativeLuminance, 0.86 * palette.keycapFaceTop.relativeLuminance, accuracy: 1e-9)
        XCTAssertEqual(bottom.relativeLuminance, 0.86 * palette.keycapFaceBottom.relativeLuminance, accuracy: 1e-9)
        // Legends 0.1 mm lower than in the legend list.
        let aBaselines = (subtle.legends + subtle.pressedAtlas).compactMap { op -> Double? in
            if case .text("A", _, let p, _, _) = op { return Double(p.y) }; return nil
        }
        XCTAssertEqual(aBaselines.count, 2)
        XCTAssertEqual(aBaselines[1] - aBaselines[0], 0.1 * projection.ppm, accuracy: 1e-9)
        // Touch ID is inert and never drawn pressed.
        XCTAssertFalse(subtle.pressedAtlas.contains { rect(of: $0) == subtle.touchIDRect })
    }

    func testPressedAtlasStaysInsideEachKeyFrame() throws {
        // A key's pressed tile is cropped to exactly its keyFrames rect, so no atlas op may reach into
        // another key's rect. The up and down arrows share an edge (0 mm gap): the case that matters.
        func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
            let e = 1e-9
            return Double(inner.minX) >= Double(outer.minX) - e && Double(inner.maxX) <= Double(outer.maxX) + e
                && Double(inner.minY) >= Double(outer.minY) - e && Double(inner.maxY) <= Double(outer.maxY) + e
        }
        for model in MacBookAirModel.allCases {
            for display in IPadDisplaySpec.all {
                for scale in [1.0, 2.0, 3.0] {
                    for look in [PressLook.subtle, .clear] {
                        let s = scene(model: model, display: display, displayScale: scale, pressLook: look).0
                        let frames = Array(s.keyFrames.values)
                        let up = try XCTUnwrap(s.keyFrames[126]), down = try XCTUnwrap(s.keyFrames[125])
                        XCTAssertEqual(down.minY, up.maxY, "up/down share an edge")
                        for (i, a) in frames.enumerated() {
                            for b in frames[(i + 1)...] { XCTAssertFalse(overlaps(a, b), "\(a) overlaps \(b)") }
                        }
                        XCTAssertFalse(s.pressedAtlas.isEmpty)
                        for op in s.pressedAtlas {
                            if let r = rect(of: op) {
                                XCTAssertTrue(frames.contains { contains($0, r) }, "\(model) \(op) leaves its cap")
                            } else if case .text(_, _, let p, _, _) = op {
                                let dot = CGRect(origin: p, size: .zero)
                                XCTAssertTrue(frames.contains { contains($0, dot) }, "\(model) \(op) leaves its cap")
                            }
                        }
                        // No op of another key reaches into the up or down crop.
                        for crop in [up, down] {
                            for op in s.pressedAtlas {
                                guard let r = rect(of: op), overlaps(r, crop) else { continue }
                                XCTAssertTrue(contains(crop, r), "\(op) crosses into \(crop)")
                            }
                        }
                        // The up key's hairline stays drawn, cut to its own cap; the base keeps it whole.
                        let rim = DeckPalette.palette(model.defaultFinish).keycapRim
                        XCTAssertTrue(s.pressedAtlas.contains { op in
                            if case .fill(let r, rim) = op { return r.maxY == up.maxY && r.minY > up.minY }
                            return false
                        }, "\(model) pressed up hairline")
                        XCTAssertTrue(s.base.contains { op in
                            if case .fill(let r, rim) = op { return r.minY < up.maxY && r.maxY > down.minY }
                            return false
                        }, "\(model) base hairline")
                    }
                }
            }
        }
    }

    func testOneToOneScale() throws {
        // Rigid 1:1: neighbouring caps sit one 19.00 mm pitch and a 1.52 mm gap apart, in points, on
        // both 13-inch iPads (within a device pixel from snapping).
        for display in IPadDisplaySpec.all {
            let (s, projection) = scene(display: display)
            let a = try XCTUnwrap(s.keyIDFrames["a"]), sKey = try XCTUnwrap(s.keyIDFrames["s"])
            XCTAssertEqual(Double(sKey.minX - a.minX), 19.00 * projection.ppm, accuracy: 0.5)
            XCTAssertEqual(Double(sKey.minX - a.maxX), 1.52 * projection.ppm, accuracy: 0.5)
            let q = try XCTUnwrap(s.keyIDFrames["q"])
            XCTAssertEqual(Double(a.minY - q.minY), 18.50 * projection.ppm, accuracy: 0.5)
        }
    }

    func testDegenerateInputsStayFinite() {
        let spec = MacBookAirModel.defaultModel.spec
        let projection = DeckProjection(display: .pro13, spec: spec, screenSize: .zero)
        let s = DeckScene.build(spec: spec, projection: projection, palette: .palette(.silver),
                                nightPalette: .palette(.silver, night: 1), legendStyle: .modern,
                                viewBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                displayScale: .nan, pressLook: .clear)
        for r in s.keyFrames.values + [s.capsLEDRect, s.touchIDRect, s.trackpadRect] {
            XCTAssertTrue(r.minX.isFinite && r.minY.isFinite && r.width.isFinite && r.height.isFinite)
        }
    }

    private func recoloured(_ op: DrawOp, _ from: RGBA, _ to: RGBA) -> DrawOp {
        switch op {
        case .text(let s, let size, let p, let align, from): return .text(s, size: size, baseline: p, align: align, color: to)
        case .symbol(let n, let box, from): return .symbol(n, box: box, color: to)
        case .triangle(let r, let d, from): return .triangle(r, d, to)
        case .strokeRects(let r, let w, from): return .strokeRects(r, width: w, color: to)
        default: return op
        }
    }
}
