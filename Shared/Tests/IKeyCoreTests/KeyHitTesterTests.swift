import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import IKeyCore

final class KeyHitTesterTests: XCTestCase {
    private let spec = MacBookAirModel.defaultModel.spec
    /// Screen-centred default placement on the iPad Pro 13.
    private lazy var projection = DeckProjection(display: .pro13, spec: spec, screenSize: CGSize(width: 1376, height: 1032))
    private lazy var deck = ResolvedDeck(spec: spec, projection: projection)
    private lazy var tester = KeyHitTester(deck: deck, captureRadius: KeyHitTester.defaultCaptureRadius(for: deck))

    /// D point for KL coordinates on the 2022/2025 deck.
    private func kl(_ x: Double, _ y: Double) -> MMPoint { MMPoint(x: -136.99 + x, y: 199.87 - y) }

    private func code(_ hit: KeyHitTester.Hit) -> UInt16? {
        if case .key(let code, _) = hit { return code }
        return nil
    }

    private func resolved(_ id: String) throws -> ResolvedKey { try XCTUnwrap(deck.keys.first { $0.id == id }) }

    func testDefaultCaptureRadius() {
        XCTAssertEqual(Double(KeyHitTester.defaultCaptureRadius(for: deck)), 3.0 * projection.ppm, accuracy: 1e-9)
        XCTAssertEqual(deck.mmPerPoint ?? 0, projection.mmPerPoint, accuracy: 1e-12)
        XCTAssertEqual(deck.trackpadPhysicalWidthMM, 128.2)
        XCTAssertEqual(deck.trackpadPhysicalHeightMM, 80.05)
        XCTAssertEqual(deck.keys.count, 78)
        XCTAssertEqual(deck.keys.filter(\.restCapable).count, 9)
        XCTAssertEqual(KeyHitTester.defaultCaptureRadius(for: ResolvedDeck(keys: [], trackpad: .zero, trackpadPhysicalWidthMM: 0,
                                                                          trackpadPhysicalHeightMM: 0, mmPerPoint: nil)), 0)
    }

    func testCapInteriorHitsOwnKey() {
        for key in deck.keys {
            let r = key.rect
            for p in [CGPoint(x: r.midX, y: r.midY), CGPoint(x: r.minX + 1, y: r.minY + 1),
                      CGPoint(x: r.maxX - 1, y: r.maxY - 1)] {
                let hit = tester.hit(p)
                if let code = key.code {
                    XCTAssertEqual(hit, .key(code: code, distance: 0), key.id)
                } else {
                    XCTAssertEqual(hit, .inert(id: key.id))
                }
            }
        }
    }

    func testGapMidpointsHitNeighbour() {
        var horizontal = 0, vertical = 0
        for a in spec.keys {
            for b in spec.keys where b.row == a.row {
                let gap = b.cap.minX - a.cap.maxX
                let yLo = max(a.cap.minY, b.cap.minY), yHi = min(a.cap.maxY, b.cap.maxY)
                guard gap > 0, gap < 2, yHi - yLo > 1 else { continue }
                let hit = tester.hit(projection.point(MMPoint(x: a.cap.maxX + gap / 2, y: (yLo + yHi) / 2)))
                XCTAssertTrue([a.keyCode, b.keyCode].contains(code(hit)) || hit == .inert(id: "touchid"),
                              "\(a.id)|\(b.id) → \(hit)")
                horizontal += 1
            }
            for b in spec.keys where b.row == a.row + 1 {
                let gap = a.cap.minY - b.cap.maxY
                let xLo = max(a.cap.minX, b.cap.minX), xHi = min(a.cap.maxX, b.cap.maxX)
                guard gap > 0, gap < 2, xHi - xLo > 1 else { continue }
                let hit = tester.hit(projection.point(MMPoint(x: (xLo + xHi) / 2, y: b.cap.maxY + gap / 2)))
                XCTAssertTrue([a.keyCode, b.keyCode].contains(code(hit)) || hit == .inert(id: "touchid"),
                              "\(a.id)/\(b.id) → \(hit)")
                vertical += 1
            }
        }
        XCTAssertGreaterThan(horizontal, 65)
        XCTAssertGreaterThan(vertical, 60)
    }

    func testCaptureRadiusBoundary() throws {
        let space = try XCTUnwrap(spec.key(id: "space")).cap
        XCTAssertEqual(code(tester.hit(projection.point(MMPoint(x: space.midX, y: space.minY - 2.9)))), 49)
        XCTAssertEqual(tester.hit(projection.point(MMPoint(x: space.midX, y: space.minY - 3.1))), .outside)
        let delete = try XCTUnwrap(spec.key(id: "delete")).cap
        XCTAssertEqual(code(tester.hit(projection.point(MMPoint(x: delete.maxX + 2.9, y: delete.midY)))), 51)
        XCTAssertEqual(tester.hit(projection.point(MMPoint(x: delete.maxX + 3.1, y: delete.midY))), .outside)
        // Diagonal distance off a corner.
        let off = 2.9 / 2.0.squareRoot()
        let fn = try XCTUnwrap(spec.key(id: "fn")).cap
        let hit = tester.hit(projection.point(MMPoint(x: fn.minX - off, y: fn.minY - off)))
        guard case .key(63, let d) = hit else { return XCTFail("\(hit)") }
        XCTAssertEqual(Double(d), 2.9 * projection.ppm, accuracy: 1e-6)
    }

    func testVoidAboveLeftArrowOutside() {
        XCTAssertEqual(tester.hit(projection.point(kl(227.24, 96.7))), .outside)
        XCTAssertEqual(tester.hit(projection.point(kl(265.24, 96.7))), .outside)
        // The void's lower edge is within reach of the arrow below it.
        XCTAssertEqual(code(tester.hit(projection.point(kl(227.24, 99.0)))), 123)
    }

    func testTouchIDInert() throws {
        let touchID = try resolved("touchid")
        XCTAssertNil(touchID.code)
        XCTAssertEqual(tester.hit(CGPoint(x: touchID.rect.midX, y: touchID.rect.midY)), .inert(id: "touchid"))
        let above = projection.point(MMPoint(x: try XCTUnwrap(spec.key(id: "touchid")).cap.midX, y: 199.87 + 1))
        XCTAssertEqual(tester.hit(above), .inert(id: "touchid"))
        // Nothing in or around Touch ID ever yields Delete or F12.
        let r = touchID.rect
        for fx in stride(from: 0.3, through: 1.0, by: 0.1) {
            for fy in stride(from: -0.1, through: 0.9, by: 0.1) {
                let hit = tester.hit(CGPoint(x: r.minX + r.width * CGFloat(fx), y: r.minY + r.height * CGFloat(fy)))
                XCTAssertNotEqual(code(hit), 51)
                XCTAssertNotEqual(code(hit), 111)
            }
        }
    }

    func testTrackpadWinsNearSpace() throws {
        let topInside = projection.point(MMPoint(x: 0, y: spec.trackpad.maxY - 0.2))
        XCTAssertEqual(tester.hit(topInside), .trackpad)
        // Even when the space bar is within a (large) capture radius.
        let greedy = KeyHitTester(deck: deck, captureRadius: CGFloat(10 * projection.ppm))
        XCTAssertEqual(greedy.hit(topInside), .trackpad)
        let justAbove = projection.point(MMPoint(x: 0, y: spec.trackpad.maxY + 0.2))
        XCTAssertEqual(code(greedy.hit(justAbove)), 49)
        XCTAssertEqual(tester.hit(justAbove), .outside)
        XCTAssertEqual(tester.hit(CGPoint(x: deck.trackpad.midX, y: deck.trackpad.midY)), .trackpad)
    }

    /// The key field is wider than both 13-inch screens; the screen-centred default clips the outer caps
    /// symmetrically and they stay hittable right up to each screen edge.
    func testNegativeOriginEdgeKeysHit() throws {
        for (display, size) in [(IPadDisplaySpec.pro13, CGSize(width: 1376, height: 1032)),
                                (.air13, CGSize(width: 1366, height: 1024))] {
            let p = DeckProjection(display: display, spec: spec, screenSize: size)
            let deck = ResolvedDeck(spec: spec, projection: p)
            let tester = KeyHitTester(deck: deck, captureRadius: KeyHitTester.defaultCaptureRadius(for: deck))
            func rect(_ id: String) throws -> CGRect { try XCTUnwrap(deck.keys.first { $0.id == id }, id).rect }
            for (id, code) in [("esc", UInt16(53)), ("tab", 48), ("capslock", 57), ("shift_l", 56), ("fn", 63)] {
                let r = try rect(id)
                XCTAssertLessThan(r.minX, 0, id)
                for x in [0.0, 1.0, 2.0] {
                    XCTAssertEqual(tester.hit(CGPoint(x: x, y: Double(r.midY))), .key(code: code, distance: 0), "\(display.id) \(id)")
                }
            }
            // Right edge too.
            for id in ["delete", "backslash", "return", "shift_r", "right", "touchid"] {
                let key = try XCTUnwrap(deck.keys.first { $0.id == id })
                XCTAssertGreaterThan(key.rect.maxX, size.width, id)
                let hit = tester.hit(CGPoint(x: size.width - 1, y: key.rect.midY))
                if let c = key.code {
                    XCTAssertEqual(hit, .key(code: c, distance: 0), "\(display.id) \(id)")
                } else {
                    XCTAssertEqual(hit, .inert(id: id), display.id)
                }
            }
            // Symmetric clip: the same width is cut off each side.
            XCTAssertEqual(Double(-(try rect("esc")).minX), Double((try rect("delete")).maxX - size.width), accuracy: 1e-9)
            // The whole function row and trackpad are on screen.
            XCTAssertGreaterThan(try rect("f5").minY, 0)
            XCTAssertLessThan(deck.trackpad.maxY, size.height)
        }
    }

    func testPhotoModeDeckEquivalence() throws {
        let layout = DeckLayout.macBookANSI
        let frame = CGRect(x: 30, y: 50, width: 1300, height: 900)
        let photo = ResolvedDeck(layout: layout, photoFrame: frame)
        XCTAssertNil(photo.mmPerPoint)
        XCTAssertEqual(photo.trackpadPhysicalWidthMM, 128.2)
        XCTAssertEqual(photo.trackpadPhysicalHeightMM, 80.05)
        XCTAssertEqual(photo.trackpad, layout.trackpad.rect(in: frame))
        XCTAssertEqual(Set(photo.keys.filter(\.restCapable).compactMap(\.code)), [0, 1, 2, 3, 38, 40, 37, 41, 49])
        let radius = KeyHitTester.defaultCaptureRadius(for: photo)
        let aWidth = try XCTUnwrap(photo.keys.first { $0.code == 0 }).rect.width
        XCTAssertEqual(Double(radius), 0.16 * Double(aWidth), accuracy: 1e-9)
        let photoTester = KeyHitTester(deck: photo, captureRadius: radius)
        for key in layout.keys {
            let f = layout.frame(for: key)
            let nx = f.x + f.width / 2, ny = f.y + f.height / 2
            XCTAssertEqual(layout.key(atX: nx, y: ny)?.keyCode, key.keyCode)
            let p = CGPoint(x: frame.minX + CGFloat(nx) * frame.width, y: frame.minY + CGFloat(ny) * frame.height)
            XCTAssertEqual(code(photoTester.hit(p)), key.keyCode, key.label)
        }
        let pad = photo.trackpad
        XCTAssertEqual(photoTester.hit(CGPoint(x: pad.midX, y: pad.midY)), .trackpad)
    }

    // MARK: - ScaleCheck

    func testRulerTicks() {
        let ticks = ScaleCheck.rulerTicks(lengthMM: 150)
        XCTAssertEqual(ticks.count, 151)
        let cm = ticks.filter { $0.kind == .cm }
        XCTAssertEqual(cm.count, 16)
        XCTAssertEqual(cm.compactMap(\.label), (0...15).map { String($0) })
        XCTAssertEqual(ticks.filter { $0.kind == .half }.map(\.posMM), stride(from: 5.0, through: 145, by: 10).map { $0 })
        XCTAssertTrue(ticks.filter { $0.kind != .cm }.allSatisfy { $0.label == nil })
        XCTAssertEqual(ticks.map(\.posMM), (0...150).map(Double.init))
        XCTAssertEqual(ScaleCheck.rulerTicks(lengthMM: 0).count, 1)
        XCTAssertTrue(ScaleCheck.rulerTicks(lengthMM: -1).isEmpty)
    }

    func testCardRectSize() {
        let card = ScaleCheck.cardRect(centeredOn: spec)
        XCTAssertEqual(card.midX, spec.trackpad.midX, accuracy: 1e-9)
        XCTAssertEqual(card.midY, spec.trackpad.midY, accuracy: 1e-9)
        let r = projection.rect(card)
        XCTAssertEqual(Double(r.width), 444.2, accuracy: 0.05)
        XCTAssertEqual(Double(r.height), 280.1, accuracy: 0.05)
        let pad = deck.trackpad
        XCTAssertTrue(r.minX > pad.minX && r.maxX < pad.maxX && r.minY > pad.minY && r.maxY < pad.maxY)
    }

    func testSpanChecks() {
        for model in MacBookAirModel.allCases {
            let spans = ScaleCheck.spanChecks(spec: model.spec)
            XCTAssertEqual(spans.map(\.fromKeyID), ["a", "grave"])
            XCTAssertEqual(spans.map(\.toKeyID), ["quote", "equal"])
            XCTAssertEqual(spans.map(\.expectedMM), [190.00, 228.00])
            XCTAssertEqual(spans.first?.label, "A to ' left edges")
        }
    }

    func testReferenceDistances2022() {
        for model in [MacBookAirModel.air13_2022, .air13_2025] {
            let refs = ScaleCheck.referenceDistances(spec: model.spec)
            XCTAssertEqual(refs.map(\.id), ["front_trackpad", "front_space", "left_a", "left_trackpad"])
            XCTAssertEqual(refs.map(\.expectedMM), [5.08, 90.42, 48.31, 87.95])
            XCTAssertEqual(refs.map(\.axis), [.y, .y, .x, .x])
            XCTAssertEqual(refs[1].label, "Front edge to space bar bottom edge")
        }
        let m1 = ScaleCheck.referenceDistances(spec: MacBookAirModel.air13_2020.spec)
        XCTAssertEqual(m1.map(\.expectedMM), [6.00, 90.42, 48.31, 92.05])
    }

    func testSuggestPlacementShiftsAndResidual() {
        let s = ScaleCheck.suggestPlacement(spec: spec, measured: ["front_space": 91.0, "left_a": 48.81], current: .init())
        XCTAssertEqual(s.offsetYmm, -0.58, accuracy: 1e-9)
        XCTAssertEqual(s.offsetXmm, -0.50, accuracy: 1e-9)
        XCTAssertEqual(s.maxResidualMM, 0, accuracy: 1e-9)

        // Mean per axis, residual against that mean; unknown ids and NaN ignored; relative to current.
        let mixed = ScaleCheck.suggestPlacement(
            spec: spec,
            measured: ["front_trackpad": 5.5, "front_space": 91.0, "left_trackpad": 87.95, "bogus": 3, "left_a": .nan],
            current: DeckPlacement(offsetXmm: 1, offsetYmm: 2, scale: 1.002))
        XCTAssertEqual(mixed.offsetYmm, 2 - 0.5, accuracy: 1e-9)
        XCTAssertEqual(mixed.offsetXmm, 1, accuracy: 1e-9)
        XCTAssertEqual(mixed.maxResidualMM, 0.08, accuracy: 1e-9)

        let none = ScaleCheck.suggestPlacement(spec: spec, measured: [:], current: DeckPlacement(offsetXmm: 0.4))
        XCTAssertEqual(none, ScaleCheck.PlacementSuggestion(offsetXmm: 0.4, offsetYmm: 0, maxResidualMM: 0))

        let far = ScaleCheck.suggestPlacement(spec: spec, measured: ["front_space": 110, "left_a": 30], current: .init())
        XCTAssertEqual(far.offsetYmm, -8)
        XCTAssertEqual(far.offsetXmm, 5)
        // The clamp-limited part of the shift stays in the residual (wanted x +18.31 -> 5, y -19.58 -> -8).
        XCTAssertEqual(far.maxResidualMM, 13.31, accuracy: 1e-9)

        // Clamped by 1 mm: wanted y -9 from current -7, clamp gives -8, so 1 mm remains.
        let clampedByOne = ScaleCheck.suggestPlacement(
            spec: spec, measured: ["front_space": 92.42, "front_trackpad": 7.08], current: DeckPlacement(offsetYmm: -7))
        XCTAssertEqual(clampedByOne.offsetYmm, -8)
        XCTAssertEqual(clampedByOne.maxResidualMM, 1, accuracy: 1e-9)

        // Not idempotent by contract: the caller passes the pre-Apply placement as `current`.
        let again = ScaleCheck.suggestPlacement(spec: spec, measured: ["front_space": 91.0],
                                                current: DeckPlacement(offsetYmm: s.offsetYmm))
        XCTAssertEqual(again.offsetYmm, -1.16, accuracy: 1e-9)
        let farM1 = ScaleCheck.suggestPlacement(spec: MacBookAirModel.air13_2020.spec, measured: ["front_space": 110],
                                                current: .init())
        XCTAssertEqual(farM1.offsetYmm, -12)
    }
}
