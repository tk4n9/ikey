import Foundation
import XCTest
@testable import IKeyCore

// Values here are regression locks on the deck constants, not evidence of physical fidelity.
// The fixture is the default preset (M4/M5, `air13_2025`); the 2022 preset shares its geometry.
final class DeckSpecTests: XCTestCase {
    private let spec = MacBookAirModel.defaultModel.spec
    /// KL x of a D x for the 2022/2025 decks.
    private func klX(_ x: Double) -> Double { x + 136.99 }

    func testKeyCountsAndCodes() {
        for model in [MacBookAirModel.air13_2022, .air13_2025, .air13_2020] {
            let keys = model.spec.keys
            XCTAssertEqual(keys.count, 78, "\(model)")
            let codes = keys.compactMap(\.keyCode)
            XCTAssertEqual(codes.count, 77)
            XCTAssertEqual(Set(codes).count, 77)
            XCTAssertTrue(Set(codes).isSubset(of: InputEvent.supportedKeyCodes))
            XCTAssertEqual(Set(keys.map(\.id)).count, 78)
            XCTAssertNil(model.spec.key(id: "touchid")?.keyCode)
            XCTAssertNotNil(model.spec.key(id: "touchid"))
            XCTAssertEqual(Set(keys.filter(\.restCapable).map(\.id)),
                           ["a", "s", "d", "f", "j", "k", "l", "semicolon", "space"])
        }
        XCTAssertEqual(spec.key(code: 0)?.id, "a")
        XCTAssertEqual(spec.key(code: 126)?.id, "up")
        XCTAssertNil(spec.key(code: 10))
        XCTAssertEqual(MacBookAirModel.air13_2022.spec.keys, spec.keys)
        XCTAssertEqual(spec.model, .air13_2025)
    }

    func testRowRightEdgesAndSpans() throws {
        for row in 0...5 {
            let right = try XCTUnwrap(spec.keys.filter { $0.row == row }.map(\.cap.maxX).max())
            XCTAssertEqual(klX(right), 273.98, accuracy: 0.001, "row \(row)")
        }
        let a = try XCTUnwrap(spec.key(id: "a")), quote = try XCTUnwrap(spec.key(id: "quote"))
        let grave = try XCTUnwrap(spec.key(id: "grave")), equal = try XCTUnwrap(spec.key(id: "equal"))
        XCTAssertEqual(quote.cap.minX - a.cap.minX, 190.00, accuracy: 0.001)
        XCTAssertEqual(equal.cap.minX - grave.cap.minX, 228.00, accuracy: 0.001)
        XCTAssertEqual(klX(try XCTUnwrap(spec.key(id: "a")).cap.minX), 33.25, accuracy: 0.001)
        XCTAssertEqual(klX(try XCTUnwrap(spec.key(id: "space")).cap.minX), 80.75, accuracy: 0.001)
        XCTAssertEqual(klX(try XCTUnwrap(spec.key(id: "command_r")).cap.minX), 175.75, accuracy: 0.001)
        let esc = try XCTUnwrap(spec.key(id: "esc"))
        XCTAssertEqual(esc.cap.width, 26.98, accuracy: 0.001)
        XCTAssertEqual(esc.cap.maxY, 199.87, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(spec.key(id: "space")).cap.width, 93.48, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(spec.key(id: "space")).cap.minY, 90.42, accuracy: 0.001)
    }

    func testNoCapsOverlapAndAllInsideKeyField() {
        for model in MacBookAirModel.allCases {
            let s = model.spec
            for (i, a) in s.keys.enumerated() {
                XCTAssertTrue(a.cap.minX >= s.keyField.minX - 1e-9 && a.cap.maxX <= s.keyField.maxX + 1e-9
                              && a.cap.minY >= s.keyField.minY - 1e-9 && a.cap.maxY <= s.keyField.maxY + 1e-9,
                              "\(model) \(a.id)")
                for b in s.keys[(i + 1)...] {
                    let overlaps = a.cap.minX < b.cap.maxX && b.cap.minX < a.cap.maxX
                        && a.cap.minY < b.cap.maxY && b.cap.minY < a.cap.maxY
                    XCTAssertFalse(overlaps, "\(model) \(a.id) overlaps \(b.id)")
                }
                for void in s.voids {
                    let overlaps = a.cap.minX < void.maxX && void.minX < a.cap.maxX
                        && a.cap.minY < void.maxY && void.minY < a.cap.maxY
                    XCTAssertFalse(overlaps, "\(model) \(a.id) overlaps a void")
                }
            }
            XCTAssertEqual(s.voids.count, 2)
        }
    }

    func testWellAndTrackpadClearances() {
        XCTAssertEqual(spec.keyField.minY - spec.trackpad.maxY, 5.29, accuracy: 0.001)
        for key in spec.keys {
            XCTAssertGreaterThanOrEqual(key.cap.minX - spec.well.minX, 2.5, key.id)
            XCTAssertGreaterThanOrEqual(spec.well.maxX - key.cap.maxX, 2.5, key.id)
            XCTAssertGreaterThanOrEqual(key.cap.minY - spec.well.minY, 2.5, key.id)
            XCTAssertGreaterThanOrEqual(spec.well.maxY - key.cap.maxY, 2.5, key.id)
        }
        XCTAssertEqual(spec.trackpad.midX, 0, accuracy: 1e-9)
        XCTAssertEqual(spec.trackpad.width, 128.2, accuracy: 1e-9)
        XCTAssertEqual(spec.trackpad.height, 80.05, accuracy: 1e-9)
        XCTAssertEqual(spec.well.midX, 0, accuracy: 1e-9)
        XCTAssertEqual(spec.chassis.width, 304.1, accuracy: 1e-9)
        XCTAssertEqual(spec.keyField.height, 109.45, accuracy: 0.001)
    }

    func testDefaultModelAndFunctionRowTop() {
        XCTAssertEqual(MacBookAirModel.defaultModel, .air13_2025)
        XCTAssertEqual(MacBookAirModel.air13_2025.spec.functionRowTopY, 199.87, accuracy: 1e-9)
        XCTAssertEqual(MacBookAirModel.air13_2022.spec.functionRowTopY, 199.87, accuracy: 1e-9)
        XCTAssertEqual(MacBookAirModel.air13_2020.spec.functionRowTopY, 193.04, accuracy: 1e-9)
        // Span centred on screen by the default placement: function row top to trackpad bottom.
        XCTAssertEqual(spec.functionRowTopY - spec.trackpad.minY, 194.79, accuracy: 1e-9)
        XCTAssertEqual(MacBookAirModel.air13_2020.spec.functionRowTopY - MacBookAirModel.air13_2020.spec.trackpad.minY,
                       187.04, accuracy: 1e-9)
        // It fits the shorter (Air) 13-inch screen: 1024 pt / (1366 / 263.27 pt per mm) = 197.36 mm.
        XCTAssertLessThan(spec.functionRowTopY - spec.trackpad.minY, 1024 / (1366 / 263.27))
    }

    func testM1Variant() throws {
        let m1 = MacBookAirModel.air13_2020.spec
        XCTAssertTrue(MacBookAirModel.air13_2020.isEstimate)
        XCTAssertFalse(MacBookAirModel.air13_2022.isEstimate)
        XCTAssertFalse(MacBookAirModel.air13_2025.isEstimate)
        let fRow = m1.keys.filter { $0.row == 0 && $0.keyCode != nil }
        XCTAssertEqual(fRow.count, 13)
        for key in fRow { XCTAssertEqual(key.cap.height, 10.2, accuracy: 1e-9, key.id) }
        let f1 = try XCTUnwrap(m1.key(id: "f1")), f2 = try XCTUnwrap(m1.key(id: "f2"))
        XCTAssertEqual(f2.cap.minX - f1.cap.minX, 20.28, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(m1.key(id: "f12")).cap.minX - f1.cap.minX, 11 * 20.28, accuracy: 1e-9)
        XCTAssertEqual(m1.keyField.height, 102.62, accuracy: 0.001)
        XCTAssertEqual(m1.keyField.minY, 90.42, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(m1.key(id: "touchid")).cap.maxX, m1.keyField.maxX, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(m1.key(id: "space")).cap.minY, 90.42, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(m1.key(id: "grave")).cap.maxY, 193.04 - 11.67, accuracy: 0.001)
        XCTAssertEqual(m1.chassis.height, 212.4, accuracy: 1e-9)
        XCTAssertEqual(m1.trackpad.width, 120, accuracy: 1e-9)
        XCTAssertEqual(m1.trackpad.midX, 0, accuracy: 1e-9)
        XCTAssertEqual(m1.well.minX, m1.keyField.minX - 2.8, accuracy: 1e-9)
        XCTAssertEqual(m1.well.maxY, m1.keyField.maxY + 2.8, accuracy: 1e-9)
    }

    func testModelCatalog() {
        XCTAssertEqual(MacModelCatalog.model(forHardwareModel: "MacBookAir10,1"), .air13_2020)
        XCTAssertEqual(MacModelCatalog.model(forHardwareModel: "Mac14,2"), .air13_2022)
        XCTAssertEqual(MacModelCatalog.model(forHardwareModel: "Mac15,12"), .air13_2022)
        XCTAssertEqual(MacModelCatalog.model(forHardwareModel: "Mac16,12"), .air13_2025)
        XCTAssertEqual(MacModelCatalog.model(forHardwareModel: " Mac14,2\n"), .air13_2022)
        for id in ["Mac14,15", "Mac15,13", "Mac16,13"] {
            XCTAssertNil(MacModelCatalog.model(forHardwareModel: id))
            XCTAssertTrue(MacModelCatalog.isFifteenInch(hardwareModel: id))
        }
        for id in ["", "MacBookPro18,3", "Mac14,7", "iPad16,5"] {
            XCTAssertNil(MacModelCatalog.model(forHardwareModel: id))
            XCTAssertFalse(MacModelCatalog.isFifteenInch(hardwareModel: id))
        }
        XCTAssertFalse(MacModelCatalog.isFifteenInch(hardwareModel: "Mac14,2"))
    }

    func testProvenanceNonEmpty() {
        for model in MacBookAirModel.allCases {
            XCTAssertFalse(model.spec.provenance.isEmpty)
            XCTAssertFalse(model.displayName.isEmpty)
            XCTAssertEqual(model.spec.model, model)
        }
        XCTAssertTrue(MacBookAirModel.air13_2020.spec.provenance.contains("Estimate"))
        XCTAssertEqual(MacBookAirModel(rawValue: "air13_2022"), .air13_2022)
    }

    func testMMRectHelpers() {
        let r = MMRect(minX: 1, minY: 2, width: 10, height: 4)
        XCTAssertEqual(r.maxX, 11); XCTAssertEqual(r.maxY, 6); XCTAssertEqual(r.midX, 6); XCTAssertEqual(r.midY, 4)
        XCTAssertEqual(r.insetBy(dx: 1, dy: 1), MMRect(minX: 2, minY: 3, width: 8, height: 2))
        XCTAssertEqual(r.insetBy(dx: -1, dy: 0), MMRect(minX: 0, minY: 2, width: 12, height: 4))
        XCTAssertEqual(r.insetBy(dx: 0, dy: 3), MMRect(minX: 1, minY: 4, width: 10, height: 0))
        XCTAssertTrue(r.contains(MMPoint(x: 1, y: 2)))
        XCTAssertTrue(r.contains(MMPoint(x: 11, y: 6)))
        XCTAssertFalse(r.contains(MMPoint(x: 11.01, y: 4)))
    }
}
