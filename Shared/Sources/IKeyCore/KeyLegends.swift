import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Legend layout generation: `.legacy` for M1-M3 MacBook Airs, `.modern` for M4/M5.
public enum LegendStyle: String, Codable, Sendable { case legacy, modern }

public enum LegendRole: Sendable { case letter, upper, lower, word, modifierSymbol, fnLabel, icon }

public enum LegendAlign: Sendable { case left, center, right }

public enum ArrowDirection: Sendable { case up, down, left, right }

/// What a legend run draws.
///
/// `.symbol` carries an SF Symbol name for `UIImage(systemName:)`, never a glyph: the modifier keys
/// use "control", "option", "command" (drawn as ⌃ ⌥ ⌘) and fn uses "globe".
///
/// Colour intent for renderers: `.text`, `.symbol`, `.triangle` and `.missionControlGlyph` are printed,
/// backlit legends (`DeckPalette.legend`, and they belong in the night glow). The other cases are not
/// printed legends and must not glow: `.ring` is the Touch ID ring (`touchIDRing`), `.dot` is the
/// Caps Lock LED (`capsLEDOff` / `capsLEDOn`), `.hairline` is the dark gap between the up and down
/// arrow keys (e.g. `keycapRim`), and `.bump` is the raised f/j home bar (a keycap-toned highlight
/// such as `keycapBevel`).
public enum LegendContent: Equatable, Sendable {
    case text(String), symbol(String), triangle(ArrowDirection), dot, ring, bump, hairline, missionControlGlyph
}

/// One legend element in cap-local millimetres: x from the cap's left edge, y down from the cap top.
///
/// - `.text` runs: `size` is the em (font size), (`anchorX`, `anchorY`) is the baseline point and
///   `align` says whether `anchorX` is the left end, centre or right end of the line. No box.
/// - All other runs have `boxWidth`/`boxHeight`; `anchorY` is the box top and `anchorX` is the box's
///   left edge, centre or right edge per `align`. `size` is the nominal glyph size: symbol point size,
///   dot/ring diameter, triangle base, bump length, hairline thickness, Mission Control box width.
public struct LegendRun: Equatable, Sendable {
    public let content: LegendContent
    public let role: LegendRole
    public let size: Double
    public let anchorX: Double
    public let anchorY: Double
    public let align: LegendAlign
    public let boxWidth: Double?
    public let boxHeight: Double?

    public init(content: LegendContent, role: LegendRole, size: Double, anchorX: Double, anchorY: Double,
                align: LegendAlign, boxWidth: Double? = nil, boxHeight: Double? = nil) {
        self.content = content; self.role = role; self.size = size
        self.anchorX = anchorX; self.anchorY = anchorY; self.align = align
        self.boxWidth = boxWidth; self.boxHeight = boxHeight
    }

    /// The run's box in cap-local mm, or nil for text runs.
    public var box: CGRect? {
        guard let width = boxWidth, let height = boxHeight else { return nil }
        let minX: Double
        switch align {
        case .left: minX = anchorX
        case .center: minX = anchorX - width / 2
        case .right: minX = anchorX - width
        }
        return CGRect(x: minX, y: anchorY, width: width, height: height)
    }
}

/// US ANSI MacBook Air key legends, measured from Apple's orthographic M4 render (±0.2 mm).
/// Values are regression locks for those measurements, not independent fidelity evidence.
public enum KeyLegends {
    /// Stroke width of the Touch ID `.ring` run.
    public static let ringStrokeWidth = 0.30
    /// Stroke width of the `.missionControlGlyph` window outlines.
    public static let missionControlStrokeWidth = 0.20

    /// The three window outlines of the F3 Mission Control glyph, placed in the run's `box`.
    public static func missionControlFrames(in box: CGRect) -> [CGRect] {
        let sx = box.width / Metrics.mcBounds.width, sy = box.height / Metrics.mcBounds.height
        return Metrics.mcWindows.map { w in
            CGRect(x: box.minX + (w.minX - Metrics.mcBounds.minX) * sx,
                   y: box.minY + (w.minY - Metrics.mcBounds.minY) * sy,
                   width: w.width * sx, height: w.height * sy)
        }
    }

    /// Legend runs for `keyID` (W1-GEO key ids). `halfHeightFRow` selects the M1's short function row.
    /// Unknown ids and `space` return [].
    public static func runs(keyID: String, capWidth: Double, capHeight: Double, style: LegendStyle,
                            halfHeightFRow: Bool = false) -> [LegendRun] {
        let cap = Cap(width: capWidth, height: capHeight)
        if Metrics.letterIDs.contains(keyID) {
            var result = [cap.text(keyID.uppercased(), .letter, em: 5.30, baseline: Metrics.letterBaseline, .center)]
            if keyID == "f" || keyID == "j" {
                result.append(cap.box(.bump, .icon, size: 2.2, x: cap.midX, top: Metrics.letterBaseline + 0.45,
                                      width: 2.2, height: 0.3, .center))
            }
            return result
        }
        if let pair = Metrics.pairs[keyID] {
            return [cap.text(pair.upper, .upper, em: 3.70, baseline: 6.40, .center),
                    cap.text(pair.lower, .lower, em: 5.30, baseline: 13.70, .center)]
        }
        if let fnNumber = Metrics.functionKeys[keyID] {
            return functionKey(fnNumber, cap: cap, style: style, halfHeight: halfHeightFRow)
        }
        if let modifier = Metrics.modifiers[keyID] {
            // Modern puts symbol and word on the key's outer side; legacy mirrors them toward Space.
            let outer: LegendAlign = modifier.isRight ? .right : .left
            let side: LegendAlign = style == .modern ? outer : (outer == .left ? .right : .left)
            return [cap.box(.symbol(modifier.symbol), .modifierSymbol, size: 4.6, x: cap.inset(side), top: 3.56,
                            width: 4.6, height: 4.6, side),
                    cap.word(modifier.word, side)]
        }
        if let direction = Metrics.arrows[keyID] {
            return arrow(direction, cap: cap)
        }
        switch keyID {
        case "esc":
            if halfHeightFRow { return [cap.text("esc", .word, em: 2.0, baseline: 8.6, .left)] }
            return [cap.word("esc", .left)]
        case "tab": return [cap.word("tab", .left)]
        case "capslock":
            return [cap.box(.dot, .icon, size: 1.26, x: 3.98, top: 4.08 - 0.63, width: 1.26, height: 1.26, .center),
                    cap.word("caps lock", .left)]
        case "shift_l": return [cap.word("shift", .left)]
        case "delete": return [cap.word("delete", .right)]
        case "return": return [cap.word("return", .right)]
        case "shift_r": return [cap.word("shift", .right)]
        case "fn":
            let globe = cap.box(.symbol("globe"), .modifierSymbol, size: 3.9, x: cap.inset(.left), top: 13.71 - 3.9,
                                width: 3.9, height: 3.9, .left)
            let fnBaseline = style == .modern ? 13.65 : 6.0
            return [cap.text("fn", .word, em: 3.20, baseline: fnBaseline, .right), globe]
        case "touchid":
            return [cap.box(.ring, .icon, size: 9.3, x: cap.midX, top: capHeight / 2 - 4.65,
                            width: 9.3, height: 9.3, .center)]
        default:
            return []
        }
    }

    private static func functionKey(_ n: Int, cap: Cap, style: LegendStyle, halfHeight: Bool) -> [LegendRun] {
        let iconSize = halfHeight ? 2.6 : 3.2
        let iconTop = halfHeight ? 1.6 : 4.55
        let icon: LegendRun
        if n == 3 {
            // Glyph bounds scale with the icon box and keep their offset from the box top and cap centre.
            let s = iconSize / 3.2
            let b = Metrics.mcBounds
            let width = Double(b.width) * s
            icon = cap.box(.missionControlGlyph, .icon, size: width,
                           x: cap.midX + (Double(b.midX) - Metrics.mcReferenceCentreX) * s,
                           top: iconTop + (Double(b.minY) - 4.55) * s, width: width, height: Double(b.height) * s,
                           .center)
        } else {
            let name = n == 10 && style == .modern ? "speaker.slash" : Metrics.functionSymbols[n, default: ""]
            icon = cap.box(.symbol(name), .icon, size: iconSize, x: cap.midX, top: iconTop,
                           width: iconSize, height: iconSize, .center)
        }
        let label = halfHeight
            ? cap.text("F\(n)", .fnLabel, em: 2.0, baseline: 8.6, .center)
            : cap.text("F\(n)", .fnLabel, em: 2.40, baseline: 13.61, .center)
        return [icon, label]
    }

    private static func arrow(_ direction: ArrowDirection, cap: Cap) -> [LegendRun] {
        let vertical = direction == .up || direction == .down
        let width = vertical ? 1.55 : 1.35, height = vertical ? 1.35 : 1.55
        var result = [cap.box(.triangle(direction), .icon, size: 1.55, x: cap.midX, top: (cap.height - height) / 2,
                              width: width, height: height, .center)]
        if direction == .up {
            // Centred on the edge the up key shares with the down key below it.
            result.append(cap.box(.hairline, .icon, size: 0.35, x: 0, top: cap.height - 0.175,
                                  width: cap.width, height: 0.35, .left))
        }
        return result
    }

    private struct Cap {
        let width: Double
        let height: Double
        var midX: Double { width / 2 }

        /// The 3.35 mm side inset, as the anchor x for a left- or right-aligned run.
        func inset(_ align: LegendAlign) -> Double {
            switch align {
            case .left: return 3.35
            case .center: return midX
            case .right: return width - 3.35
            }
        }

        func text(_ string: String, _ role: LegendRole, em: Double, baseline: Double,
                  _ align: LegendAlign) -> LegendRun {
            LegendRun(content: .text(string), role: role, size: em, anchorX: inset(align), anchorY: baseline,
                      align: align)
        }

        func word(_ string: String, _ align: LegendAlign) -> LegendRun {
            text(string, .word, em: 3.20, baseline: 13.65, align)
        }

        func box(_ content: LegendContent, _ role: LegendRole, size: Double, x: Double, top: Double,
                 width: Double, height: Double, _ align: LegendAlign) -> LegendRun {
            LegendRun(content: content, role: role, size: size, anchorX: x, anchorY: top, align: align,
                      boxWidth: width, boxHeight: height)
        }
    }

    private enum Metrics {
        static let letterBaseline = 10.40

        static let letterIDs = Set("abcdefghijklmnopqrstuvwxyz".map(String.init))

        static let pairs: [String: (upper: String, lower: String)] = [
            "grave": ("~", "`"),
            "d1": ("!", "1"), "d2": ("@", "2"), "d3": ("#", "3"), "d4": ("$", "4"), "d5": ("%", "5"),
            "d6": ("^", "6"), "d7": ("&", "7"), "d8": ("*", "8"), "d9": ("(", "9"), "d0": (")", "0"),
            "minus": ("_", "-"), "equal": ("+", "="),
            "lbracket": ("{", "["), "rbracket": ("}", "]"), "backslash": ("|", "\\"),
            "semicolon": (":", ";"), "quote": ("\"", "'"),
            "comma": ("<", ","), "period": (">", "."), "slash": ("?", "/"),
        ]

        static let functionKeys: [String: Int] = Dictionary(uniqueKeysWithValues: (1...12).map { ("f\($0)", $0) })

        /// SF Symbols by function-key number (F3 draws the Mission Control glyph; F10 here is legacy).
        static let functionSymbols: [Int: String] = [
            1: "sun.min", 2: "sun.max", 4: "magnifyingglass", 5: "mic", 6: "moon",
            7: "backward", 8: "playpause", 9: "forward", 10: "speaker", 11: "speaker.wave.1", 12: "speaker.wave.3",
        ]

        /// `symbol` is the SF Symbol name for ⌃ ⌥ ⌘ (see `LegendContent`).
        static let modifiers: [String: (symbol: String, word: String, isRight: Bool)] = [
            "control_l": ("control", "control", false),
            "option_l": ("option", "option", false),
            "command_l": ("command", "command", false),
            "command_r": ("command", "command", true),
            "option_r": ("option", "option", true),
        ]

        static let arrows: [String: ArrowDirection] = [
            "up": .up, "down": .down, "left": .left, "right": .right,
        ]

        /// Mission Control windows as measured on a 17.48 mm F3 cap (centre x 8.74, icon top 4.55).
        static let mcReferenceCentreX = 8.74
        static let mcWindows: [CGRect] = [
            CGRect(x: 6.49, y: 4.61, width: 8.79 - 6.49, height: 6.07 - 4.61),
            CGRect(x: 9.32, y: 4.92, width: 11.10 - 9.32, height: 7.43 - 4.92),
            CGRect(x: 6.91, y: 6.39, width: 8.90 - 6.91, height: 7.64 - 6.39),
        ]
        static let mcBounds: CGRect = mcWindows.dropFirst().reduce(mcWindows[0]) { $0.union($1) }
    }
}
