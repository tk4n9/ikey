import Foundation

// Millimetre model of the MacBook Air lower deck.
//
// Frame D (mm): origin at the midpoint of the deck front edge, +x right, +y toward the hinge.
// Keyboard-local frame KL (mm): origin at the top-left of the esc cap, +y toward the user.
//
// Provenance: the key grid (19.00 mm column pitch, 18.50 mm row pitch) is measured from Apple's
// orthographic MacBook Air M4 render scaled to the 304.1 mm specified width (high confidence).
// The placement of the key field, keyboard well and trackpad on the deck is ±0.5 mm (medium);
// corner radii are low confidence; the M1 (2020) placement is an estimate. Values asserted by the
// XCTests are regression locks on these constants, not evidence of fidelity.
//
// The deck is a rigid 1:1 body: every cap, gap, the keyboard-to-trackpad distance and the trackpad
// are drawn at these millimetres at the iPad's real points per mm. Placement on screen only
// translates it (see `DeckProjection`); on a supported 13-inch iPad it is never scaled to fit.

public struct MMPoint: Codable, Equatable, Sendable {
    public var x, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct MMRect: Codable, Equatable, Sendable {
    public var minX, minY, width, height: Double
    public init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX; self.minY = minY; self.width = width; self.height = height
    }
    public var maxX: Double { minX + width }
    public var maxY: Double { minY + height }
    public var midX: Double { minX + width / 2 }
    public var midY: Double { minY + height / 2 }

    /// Like CGRect.insetBy; an inset larger than half a side collapses that side to zero at its centre.
    public func insetBy(dx: Double, dy: Double) -> MMRect {
        let w = max(width - 2 * dx, 0), h = max(height - 2 * dy, 0)
        return MMRect(minX: midX - w / 2, minY: midY - h / 2, width: w, height: h)
    }

    /// Closed on all edges.
    public func contains(_ p: MMPoint) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }
}

public enum MacBookAirModel: String, Codable, CaseIterable, Sendable {
    case air13_2022 // M2, M3
    case air13_2025 // M4, M5
    case air13_2020 // M1, estimate

    public var displayName: String {
        switch self {
        case .air13_2022: return "MacBook Air 13.6\" (M2, M3)"
        case .air13_2025: return "MacBook Air 13.6\" (M4, M5)"
        case .air13_2020: return "MacBook Air 13.3\" (M1, estimate)"
        }
    }

    public var isEstimate: Bool { self == .air13_2020 }

    /// The preset used wherever a default is chosen (no Mac connected yet, unknown `hw.model`,
    /// previews): the MacBook Air M4/M5. Its deck geometry equals the 2022 (M2/M3) preset.
    public static let defaultModel: MacBookAirModel = .air13_2025

    public var spec: DeckSpec {
        switch self {
        case .air13_2022: return DeckSpecCatalog.air13_2022
        case .air13_2025: return DeckSpecCatalog.air13_2025
        case .air13_2020: return DeckSpecCatalog.air13_2020
        }
    }
}

public struct KeySpec: Equatable, Sendable, Identifiable {
    public let id: String
    /// macOS virtual keycode; nil for Touch ID, which is inert.
    public let keyCode: UInt16?
    /// Cap rectangle in frame D.
    public let cap: MMRect
    /// 0 = function row ... 5 = bottom row (arrows included).
    public let row: Int
    /// A finger may rest on this key; it commits on lift.
    public let restCapable: Bool

    public init(id: String, keyCode: UInt16?, cap: MMRect, row: Int, restCapable: Bool) {
        self.id = id; self.keyCode = keyCode; self.cap = cap; self.row = row; self.restCapable = restCapable
    }
}

/// All rects are in frame D (mm).
public struct DeckSpec: Equatable, Sendable {
    public let model: MacBookAirModel
    public let chassis: MMRect
    public let chassisCornerRadius: Double
    public let well: MMRect
    public let wellCornerRadius: Double
    public let keyField: MMRect
    public let trackpad: MMRect
    public let trackpadCornerRadius: Double
    public let keycapCornerRadius: Double
    public let keys: [KeySpec]
    /// Empty areas inside the key field (above the half-height left and right arrows).
    public let voids: [MMRect]
    /// Source and confidence text shown in Fit & Size.
    public let provenance: String

    public init(model: MacBookAirModel, chassis: MMRect, chassisCornerRadius: Double,
                well: MMRect, wellCornerRadius: Double, keyField: MMRect,
                trackpad: MMRect, trackpadCornerRadius: Double, keycapCornerRadius: Double,
                keys: [KeySpec], voids: [MMRect], provenance: String) {
        self.model = model; self.chassis = chassis; self.chassisCornerRadius = chassisCornerRadius
        self.well = well; self.wellCornerRadius = wellCornerRadius; self.keyField = keyField
        self.trackpad = trackpad; self.trackpadCornerRadius = trackpadCornerRadius
        self.keycapCornerRadius = keycapCornerRadius; self.keys = keys; self.voids = voids
        self.provenance = provenance
    }

    /// D y of the top edge of the function row (199.87 mm on 2022/2025, 193.04 mm on M1). The default
    /// screen-centred placement centres the span from here down to `trackpad.minY` on screen.
    public var functionRowTopY: Double {
        keys.filter { $0.row == 0 }.map(\.cap.maxY).max() ?? keyField.maxY
    }

    public func key(id: String) -> KeySpec? { keys.first { $0.id == id } }
    public func key(code: UInt16) -> KeySpec? { keys.first { $0.keyCode == code } }
}

/// Maps the Mac's `hw.model` to a deck preset (medium confidence).
public enum MacModelCatalog {
    private static let thirteenInch: [String: MacBookAirModel] = [
        "MacBookAir10,1": .air13_2020,
        "Mac14,2": .air13_2022, "Mac15,12": .air13_2022,
        "Mac16,12": .air13_2025
    ]
    private static let fifteenInch: Set<String> = ["Mac14,15", "Mac15,13", "Mac16,13"]

    public static func model(forHardwareModel id: String) -> MacBookAirModel? {
        thirteenInch[normalized(id)]
    }

    /// A 15-inch Air has a wider deck than any 13-inch iPad; callers show a notice instead of a preset.
    public static func isFifteenInch(hardwareModel id: String) -> Bool {
        fifteenInch.contains(normalized(id))
    }

    private static func normalized(_ id: String) -> String {
        id.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }
}

// MARK: - Preset construction

private struct KeyDef {
    let id: String
    let code: UInt16?
    let units: Double
    init(_ id: String, _ code: UInt16?, _ units: Double = 1) { self.id = id; self.code = code; self.units = units }
}

private enum DeckSpecCatalog {
    static let air13_2022 = modern(.air13_2022)
    static let air13_2025 = modern(.air13_2025)
    static let air13_2020 = m1()

    static let columnPitch = 19.00
    static let rowPitch = 18.50
    static let capGap = 1.52
    static let capHeight = 16.95
    /// D.x of the KL origin (left edge of esc, caps lock, shift ...).
    static let fieldMinX = -136.99
    static let fieldWidth = 273.98
    static let fieldBottomY = 90.42
    static let chassisHalfWidth = 152.05
    static let restCapableIDs: Set<String> = ["a", "s", "d", "f", "j", "k", "l", "semicolon", "space"]

    static let functionRow: [KeyDef] = [KeyDef("esc", 53, 1.5)]
        + zip(1...12, [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111] as [UInt16]).map { KeyDef("f\($0)", $1) }
        + [KeyDef("touchid", nil)]

    static let mainRows: [[KeyDef]] = [
        [KeyDef("grave", 50), KeyDef("d1", 18), KeyDef("d2", 19), KeyDef("d3", 20), KeyDef("d4", 21),
         KeyDef("d5", 23), KeyDef("d6", 22), KeyDef("d7", 26), KeyDef("d8", 28), KeyDef("d9", 25),
         KeyDef("d0", 29), KeyDef("minus", 27), KeyDef("equal", 24), KeyDef("delete", 51, 1.5)],
        [KeyDef("tab", 48, 1.5), KeyDef("q", 12), KeyDef("w", 13), KeyDef("e", 14), KeyDef("r", 15),
         KeyDef("t", 17), KeyDef("y", 16), KeyDef("u", 32), KeyDef("i", 34), KeyDef("o", 31),
         KeyDef("p", 35), KeyDef("lbracket", 33), KeyDef("rbracket", 30), KeyDef("backslash", 42)],
        [KeyDef("capslock", 57, 1.75), KeyDef("a", 0), KeyDef("s", 1), KeyDef("d", 2), KeyDef("f", 3),
         KeyDef("g", 5), KeyDef("h", 4), KeyDef("j", 38), KeyDef("k", 40), KeyDef("l", 37),
         KeyDef("semicolon", 41), KeyDef("quote", 39), KeyDef("return", 36, 1.75)],
        [KeyDef("shift_l", 56, 2.25), KeyDef("z", 6), KeyDef("x", 7), KeyDef("c", 8), KeyDef("v", 9),
         KeyDef("b", 11), KeyDef("n", 45), KeyDef("m", 46), KeyDef("comma", 43), KeyDef("period", 47),
         KeyDef("slash", 44), KeyDef("shift_r", 60, 2.25)],
        [KeyDef("fn", 63), KeyDef("control_l", 59), KeyDef("option_l", 58), KeyDef("command_l", 55, 1.25),
         KeyDef("space", 49, 5), KeyDef("command_r", 54, 1.25), KeyDef("option_r", 61)]
    ]

    /// Inverted-T arrows in KL: (id, code, x, y, height); width 17.48.
    static let arrows: [(id: String, code: UInt16, x: Double, y: Double, h: Double)] = [
        ("left", 123, 218.5, 100.90, 8.55), ("up", 126, 237.5, 92.50, 8.40),
        ("down", 125, 237.5, 100.90, 8.55), ("right", 124, 256.5, 100.90, 8.55)
    ]
    static let arrowWidth = 17.48
    /// Gaps above the half-height left and right arrows, in KL: (x, width).
    static let voidColumns: [(x: Double, w: Double)] = [(217.74, 19.0), (255.74, 19.0)]
    static let voidTopKL = 91.725
    static let voidBottomKL = 99.40

    /// KL rect → D rect for a key field whose top edge sits at D.y = `topY`.
    static func dRect(xKL: Double, yKL: Double, w: Double, h: Double, topY: Double) -> MMRect {
        MMRect(minX: fieldMinX + xKL, minY: topY - yKL - h, width: w, height: h)
    }

    static func key(_ def: KeyDef, cap: MMRect, row: Int) -> KeySpec {
        KeySpec(id: def.id, keyCode: def.code, cap: cap, row: row, restCapable: restCapableIDs.contains(def.id))
    }

    /// Full-height rows at `rowPitch`; row `firstRow` starts at KL y `firstRowTop`.
    static func unitRows(_ rows: [[KeyDef]], firstRow: Int, firstRowTop: Double, topY: Double) -> [KeySpec] {
        var keys: [KeySpec] = []
        for (offset, defs) in rows.enumerated() {
            let yKL = firstRowTop + Double(offset) * rowPitch
            var units = 0.0
            for def in defs {
                let cap = dRect(xKL: units * columnPitch, yKL: yKL, w: def.units * columnPitch - capGap, h: capHeight, topY: topY)
                keys.append(key(def, cap: cap, row: firstRow + offset))
                units += def.units
            }
        }
        return keys
    }

    /// Bottom row (row 5) arrows and the voids above the half-height arrows, shifted by `dyKL`.
    static func arrowCluster(dyKL: Double, topY: Double) -> (keys: [KeySpec], voids: [MMRect]) {
        let keys = arrows.map { a in
            key(KeyDef(a.id, a.code), cap: dRect(xKL: a.x, yKL: a.y + dyKL, w: arrowWidth, h: a.h, topY: topY), row: 5)
        }
        let voids = voidColumns.map {
            dRect(xKL: $0.x, yKL: voidTopKL + dyKL, w: $0.w, h: voidBottomKL - voidTopKL, topY: topY)
        }
        return (keys, voids)
    }

    static func modern(_ model: MacBookAirModel) -> DeckSpec {
        let topY = 199.87
        let cluster = arrowCluster(dyKL: 0, topY: topY)
        let keys = unitRows([functionRow] + mainRows, firstRow: 0, firstRowTop: 0, topY: topY) + cluster.keys
        return DeckSpec(
            model: model,
            chassis: MMRect(minX: -chassisHalfWidth, minY: 0, width: 2 * chassisHalfWidth, height: 215.0),
            chassisCornerRadius: 10.7,
            well: MMRect(minX: -139.80, minY: 87.75, width: 279.60, height: 115.0),
            wellCornerRadius: 4.0,
            keyField: MMRect(minX: fieldMinX, minY: fieldBottomY, width: fieldWidth, height: topY - fieldBottomY),
            trackpad: MMRect(minX: -64.10, minY: 5.08, width: 128.2, height: 80.05),
            trackpadCornerRadius: 5.0,
            keycapCornerRadius: 2.0,
            keys: keys,
            voids: cluster.voids,
            provenance: "Key grid (19.00 mm column and 18.50 mm row pitch) measured from Apple's orthographic "
                + "MacBook Air M4 render scaled to the 304.1 mm specified width (high confidence). Placement of "
                + "the key field, keyboard well and trackpad on the deck ±0.5 mm (medium). Corner radii approximate (low)."
        )
    }

    /// 2020 (M1) deck: half-height function row, otherwise the modern grid. Placement is an estimate.
    static func m1() -> DeckSpec {
        let topY = 193.04
        let shift = -6.83
        let fRowHeight = 10.2, fRowWidth = 18.6, fRowPitch = 20.28
        var keys: [KeySpec] = []
        for (i, def) in functionRow.enumerated() {
            let isTouchID = def.code == nil
            let x = isTouchID ? 263.88 : fRowPitch * Double(i)
            let cap = dRect(xKL: x, yKL: 0, w: isTouchID ? 10.1 : fRowWidth, h: fRowHeight, topY: topY)
            keys.append(key(def, cap: cap, row: 0))
        }
        let cluster = arrowCluster(dyKL: shift, topY: topY)
        keys += unitRows(mainRows, firstRow: 1, firstRowTop: rowPitch + shift, topY: topY) + cluster.keys
        let keyField = MMRect(minX: fieldMinX, minY: fieldBottomY, width: fieldWidth, height: topY - fieldBottomY)
        return DeckSpec(
            model: .air13_2020,
            chassis: MMRect(minX: -chassisHalfWidth, minY: 0, width: 2 * chassisHalfWidth, height: 212.4),
            chassisCornerRadius: 10.7,
            well: keyField.insetBy(dx: -2.8, dy: -2.8),
            wellCornerRadius: 4.0,
            keyField: keyField,
            trackpad: MMRect(minX: -60.0, minY: 6.0, width: 120.0, height: 82.0),
            trackpadCornerRadius: 5.0,
            keycapCornerRadius: 2.0,
            keys: keys,
            voids: cluster.voids,
            provenance: "Estimate: the 2020 (M1) deck is derived from the measured 2022 grid with its half-height "
                + "function row; placement of the key field, keyboard well and trackpad is estimated (low confidence). "
                + "Run the position check before relying on it."
        )
    }
}
