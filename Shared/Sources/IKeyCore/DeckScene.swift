import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// How a pressed key is drawn: not at all, as a sunk cap, or as a sunk cap with a light wash.
public enum PressLook: String, Codable, CaseIterable, Sendable { case off, subtle, clear }

/// The Touch ID status ring shown by the deck surface (hidden while `.live`).
public enum StatusRingStyle: String, Equatable, Sendable { case live, connecting, waiting, needsAction, paused }

/// `.live` sends input; `.panelOnly` only lets the Touch ID hold open the panel; `.off` ignores touches.
public enum DeckInputMode: String, Equatable, Sendable { case live, panelOnly, off }

public enum Paint: Equatable, Sendable {
    case solid(RGBA)
    /// Linear gradient from the rect's top edge to its bottom edge.
    case vertical(top: RGBA, bottom: RGBA)
}

/// A stroke centred on the shape's outline; `width` is in millimetres.
public struct StrokeSpec: Equatable, Sendable {
    public var color: RGBA
    public var width: Double

    public init(color: RGBA, width: Double) {
        self.color = color; self.width = width
    }
}

public enum TextAlign: Sendable { case left, center, right }

/// One drawing step of the deck display list.
///
/// Units: every `CGRect` and `CGPoint` is in view points (snapped to device pixels); every `Double`
/// length (radius, depth, offsetY, blur, stroke width, text size) is in millimetres, which the
/// renderer converts with the projection's points per mm. Colours carry their own alpha.
public enum DrawOp: Equatable, Sendable {
    case fill(CGRect, RGBA)
    case roundedRect(CGRect, radius: Double, fill: Paint, stroke: StrokeSpec?)
    /// A shadow cast inward from the top edge of the rounded rect, `depth` deep.
    case innerShadow(CGRect, radius: Double, depth: Double, color: RGBA)
    /// The shadow of the rounded rect only (the shape itself is not filled).
    case dropShadow(CGRect, radius: Double, offsetY: Double, blur: Double, color: RGBA)
    /// `size` is the em in mm; `baseline` is the baseline point and `align` says whether its x is the
    /// line's left end, centre or right end.
    case text(String, size: Double, baseline: CGPoint, align: TextAlign, color: RGBA)
    /// An SF Symbol name, aspect-fitted and centred in `box`.
    case symbol(String, box: CGRect, color: RGBA)
    case strokeRects([CGRect], width: Double, color: RGBA)
    /// A filled triangle filling the rect, pointing in the given direction.
    case triangle(CGRect, ArrowDirection, RGBA)
    case ellipse(CGRect, fill: RGBA?, stroke: StrokeSpec?)
    /// Seeded grain: each pixel lightens or darkens by up to `amplitude` (0...1).
    case noise(CGRect, amplitude: Double, seed: UInt64)
}

/// The true-scale deck as pure display lists, built once per geometry or look change.
///
/// - `base`: chassis, keyboard well, keycaps (with the Touch ID ring, f/j bumps and the up/down
///   hairline, which are cap features and darken with the night palette) and trackpad. Its colours
///   are baked from `palette`, so a renderer cannot recolour it: the night base is a second `build`
///   with `palette: nightPalette`; the renderer rasterises both bases and cross-fades them.
/// - `legends`: the printed legends (text, SF Symbols, arrow triangles, the Mission Control glyph) in
///   `palette.legend`.
/// - `glow`: exactly the `legends` ops, one for one, in `nightPalette.legendBacklit`.
/// - `pressedAtlas`: every key with a key code drawn pressed at its own frame (empty for `.off`), in
///   view coordinates like the other lists. See `pressedAtlas` for how to crop a key's tile.
/// The Caps Lock LED is not drawn; `capsLEDRect` positions it for a separate layer.
public struct DeckScene: Equatable, Sendable {
    public var base: [DrawOp]
    public var legends: [DrawOp]
    public var glow: [DrawOp]
    /// Every key with a key code, drawn pressed in place. Each key's ops lie inside that key's
    /// `keyFrames` rect, and nothing is drawn outside the caps (no drop shadow).
    ///
    /// Crop a key's pressed tile to exactly its `keyFrames` rect, with no margin. Neighbouring caps can
    /// touch: the up and down arrows share an edge (0 mm gap). A margin on that edge would show the
    /// neighbour's pressed cap inside this key's tile.
    public var pressedAtlas: [DrawOp]
    /// Snapped cap rects by macOS key code (Touch ID has none).
    public var keyFrames: [UInt16: CGRect]
    /// Snapped cap rects by key id, Touch ID included.
    public var keyIDFrames: [String: CGRect]
    public var capsLEDRect: CGRect
    public var touchIDRect: CGRect
    public var trackpadRect: CGRect

    /// Ops whose bounds lie entirely outside `viewBounds` are dropped (a text op's bounds is its cap);
    /// rect edges snap to multiples of 1 / `displayScale`.
    public static func build(spec: DeckSpec, projection: DeckProjection, palette: DeckPalette,
                             nightPalette: DeckPalette, legendStyle: LegendStyle, viewBounds: CGRect,
                             displayScale: Double, pressLook: PressLook) -> DeckScene {
        let b = Builder(projection: projection, viewBounds: viewBounds, displayScale: displayScale)
        let halfHeightFRow = spec.model == .air13_2020
        let keys = spec.keys.map { key -> (spec: KeySpec, frame: CGRect, runs: [LegendRun]) in
            (key, projection.rect(key.cap),
             KeyLegends.runs(keyID: key.id, capWidth: key.cap.width, capHeight: key.cap.height,
                             style: legendStyle, halfHeightFRow: halfHeightFRow))
        }

        var base = OpList(builder: b)
        b.chassis(spec, palette, into: &base)
        b.well(spec, palette, into: &base)
        for key in keys {
            b.dropShadow(key.frame, radius: spec.keycapCornerRadius, into: &base)
        }
        for key in keys {
            b.cap(key.frame, radius: spec.keycapCornerRadius, palette, into: &base)
            b.capFeatures(key.runs, cap: key.frame, dyMM: 0, palette, into: &base)
        }
        b.trackpad(spec, palette, into: &base)

        var legends = OpList(builder: b), glow = OpList(builder: b)
        for key in keys {
            b.printedLegends(key.runs, cap: key.frame, dyMM: 0, color: palette.legend, into: &legends)
            b.printedLegends(key.runs, cap: key.frame, dyMM: 0, color: nightPalette.legendBacklit, into: &glow)
        }

        var atlas = OpList(builder: b)
        if pressLook != .off {
            for key in keys where key.spec.keyCode != nil {
                b.pressedCap(key.frame, radius: spec.keycapCornerRadius, runs: key.runs, palette,
                             wash: pressLook == .clear, into: &atlas)
            }
        }

        var keyFrames: [UInt16: CGRect] = [:], keyIDFrames: [String: CGRect] = [:]
        for key in keys {
            let frame = b.snap(key.frame)
            keyIDFrames[key.spec.id] = frame
            if let code = key.spec.keyCode { keyFrames[code] = frame }
        }
        let capsLED = keys.first { $0.spec.id == "capslock" }.flatMap { key in
            key.runs.first { $0.content == .dot }?.box.map { b.snap(b.capLocal($0, cap: key.frame, dyMM: 0)) }
        }

        return DeckScene(base: base.ops, legends: legends.ops, glow: glow.ops, pressedAtlas: atlas.ops,
                         keyFrames: keyFrames, keyIDFrames: keyIDFrames,
                         capsLEDRect: capsLED ?? .zero,
                         touchIDRect: keyIDFrames["touchid"] ?? .zero,
                         trackpadRect: b.snap(projection.rect(spec.trackpad)))
    }
}

// MARK: - Building

extension DeckScene {
    private enum Look {
        static let chassisNoise = 0.015, chassisSeed: UInt64 = 0x694B
        static let wellShadowDepth = 1.2, wellShadow = RGBA(r: 0, g: 0, b: 0, a: 0.18), wellEdgeWidth = 0.2
        static let capShadowOffset = 0.20, capShadowBlur = 0.40, capShadow = RGBA(r: 0, g: 0, b: 0, a: 0.40)
        static let faceInset = 0.40, bevelHeight = 0.35, bevelAlpha = 0.60
        static let trackpadEdgeWidth = 0.30, trackpadHighlightHeight = 0.20
        static let trackpadHighlight = RGBA(r: 1, g: 1, b: 1, a: 0.08)
        static let trackpadNoise = 0.005, trackpadSeed: UInt64 = 0x7470
        static let pressedFaceLuminance = 0.86, pressedFaceInset = 0.15, pressedLegendShift = 0.1
        static let pressedShadowDepth = 0.6, pressedShadow = RGBA(r: 0, g: 0, b: 0, a: 0.30)
        static let pressedWash = RGBA(r: 1, g: 1, b: 1, a: 0.10)
        static let transparent = RGBA(r: 0, g: 0, b: 0, a: 0)
    }

    /// Ops plus culling against the view.
    private struct OpList {
        let builder: Builder
        var ops: [DrawOp] = []

        mutating func add(_ op: DrawOp, bounds: CGRect) {
            if builder.isVisible(bounds) { ops.append(op) }
        }
    }

    private struct Builder {
        let projection: DeckProjection
        let ppm: Double
        let viewBounds: CGRect
        let displayScale: Double

        init(projection: DeckProjection, viewBounds: CGRect, displayScale: Double) {
            self.projection = projection
            self.ppm = projection.ppm
            self.viewBounds = viewBounds
            self.displayScale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
        }

        func snap(_ value: Double) -> Double { (value * displayScale).rounded() / displayScale }

        func snap(_ r: CGRect) -> CGRect {
            let minX = snap(Double(r.minX)), minY = snap(Double(r.minY))
            return CGRect(x: minX, y: minY, width: snap(Double(r.maxX)) - minX, height: snap(Double(r.maxY)) - minY)
        }

        /// Strict overlap (edge contact is outside), written out because `CGRect` set operations
        /// differ between Foundation implementations.
        func isVisible(_ r: CGRect) -> Bool {
            r.minX < viewBounds.maxX && r.maxX > viewBounds.minX && r.minY < viewBounds.maxY && r.maxY > viewBounds.minY
        }

        /// The overlap of two rects, or nil when they only touch or miss (written out like `isVisible`).
        func intersection(_ a: CGRect, _ b: CGRect) -> CGRect? {
            let minX = max(Double(a.minX), Double(b.minX)), maxX = min(Double(a.maxX), Double(b.maxX))
            let minY = max(Double(a.minY), Double(b.minY)), maxY = min(Double(a.maxY), Double(b.maxY))
            guard minX < maxX, minY < maxY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        func inset(_ r: CGRect, mm: Double) -> CGRect {
            let d = mm * ppm
            let w = max(Double(r.width) - 2 * d, 0), h = max(Double(r.height) - 2 * d, 0)
            return CGRect(x: Double(r.midX) - w / 2, y: Double(r.midY) - h / 2, width: w, height: h)
        }

        /// A cap-local mm rect (x from the cap's left edge, y down from its top) in view points.
        func capLocal(_ r: CGRect, cap: CGRect, dyMM: Double) -> CGRect {
            CGRect(x: Double(cap.minX) + Double(r.minX) * ppm, y: Double(cap.minY) + (Double(r.minY) + dyMM) * ppm,
                   width: Double(r.width) * ppm, height: Double(r.height) * ppm)
        }

        /// A band `heightMM` tall along the rect's top edge, kept clear of the rounded corners.
        func topBand(_ r: CGRect, radiusMM: Double, heightMM: Double) -> CGRect? {
            let width = Double(r.width) - 2 * radiusMM * ppm
            guard width > 0 else { return nil }
            return snap(CGRect(x: Double(r.minX) + radiusMM * ppm, y: Double(r.minY), width: width, height: heightMM * ppm))
        }

        func chassis(_ spec: DeckSpec, _ palette: DeckPalette, into list: inout OpList) {
            let r = snap(projection.rect(spec.chassis))
            list.add(.fill(r, palette.deck), bounds: r)
            list.add(.noise(r, amplitude: Look.chassisNoise, seed: Look.chassisSeed), bounds: r)
        }

        func well(_ spec: DeckSpec, _ palette: DeckPalette, into list: inout OpList) {
            let r = snap(projection.rect(spec.well)), radius = spec.wellCornerRadius
            list.add(.roundedRect(r, radius: radius, fill: .solid(palette.wellFloor), stroke: nil), bounds: r)
            list.add(.innerShadow(r, radius: radius, depth: Look.wellShadowDepth, color: Look.wellShadow), bounds: r)
            list.add(.roundedRect(r, radius: radius, fill: .solid(Look.transparent),
                                  stroke: StrokeSpec(color: palette.wellEdge, width: Look.wellEdgeWidth)), bounds: r)
        }

        func dropShadow(_ cap: CGRect, radius: Double, into list: inout OpList) {
            let r = snap(cap)
            let reach = (Look.capShadowOffset + Look.capShadowBlur) * ppm
            list.add(.dropShadow(r, radius: radius, offsetY: Look.capShadowOffset, blur: Look.capShadowBlur,
                                 color: Look.capShadow),
                     bounds: r.insetBy(dx: -reach, dy: -reach))
        }

        func cap(_ cap: CGRect, radius: Double, _ palette: DeckPalette, into list: inout OpList) {
            let r = snap(cap)
            list.add(.roundedRect(r, radius: radius, fill: .solid(palette.keycapRim), stroke: nil), bounds: r)
            let faceRadius = max(radius - Look.faceInset, 0)
            let face = snap(inset(cap, mm: Look.faceInset))
            list.add(.roundedRect(face, radius: faceRadius,
                                  fill: .vertical(top: palette.keycapFaceTop, bottom: palette.keycapFaceBottom),
                                  stroke: nil), bounds: face)
            if let band = topBand(face, radiusMM: faceRadius, heightMM: Look.bevelHeight) {
                var bevel = palette.keycapBevel
                bevel.a *= Look.bevelAlpha
                list.add(.roundedRect(band, radius: Look.bevelHeight / 2, fill: .solid(bevel), stroke: nil), bounds: band)
            }
        }

        /// Touch ID ring, f/j bump and the up/down hairline; the Caps Lock dot is left to `capsLEDRect`.
        /// With `clip`, the hairline (the only feature that leaves its cap) is cut to that rect.
        func capFeatures(_ runs: [LegendRun], cap: CGRect, dyMM: Double, _ palette: DeckPalette,
                         clip: CGRect? = nil, into list: inout OpList) {
            for run in runs {
                guard let box = run.box else { continue }
                var r = snap(capLocal(box, cap: cap, dyMM: run.content == .hairline ? 0 : dyMM))
                if run.content == .hairline, let clip {
                    guard let cut = intersection(r, clip) else { continue }
                    r = cut
                }
                switch run.content {
                case .ring:
                    list.add(.ellipse(r, fill: nil, stroke: StrokeSpec(color: palette.touchIDRing,
                                                                       width: KeyLegends.ringStrokeWidth)), bounds: r)
                case .bump:
                    list.add(.roundedRect(r, radius: Double(box.height) / 2, fill: .solid(palette.keycapBevel),
                                          stroke: nil), bounds: r)
                case .hairline:
                    list.add(.fill(r, palette.keycapRim), bounds: r)
                case .text, .symbol, .triangle, .missionControlGlyph, .dot:
                    continue
                }
            }
        }

        /// Printed legends in `color`, shifted `dyMM` down. Text is culled with its cap.
        func printedLegends(_ runs: [LegendRun], cap: CGRect, dyMM: Double, color: RGBA, into list: inout OpList) {
            for run in runs {
                switch run.content {
                case .text(let string):
                    let baseline = CGPoint(x: Double(cap.minX) + run.anchorX * ppm,
                                           y: Double(cap.minY) + (run.anchorY + dyMM) * ppm)
                    list.add(.text(string, size: run.size, baseline: baseline, align: TextAlign(run.align),
                                   color: color), bounds: cap)
                case .symbol(let name):
                    guard let box = run.box else { continue }
                    let r = snap(capLocal(box, cap: cap, dyMM: dyMM))
                    list.add(.symbol(name, box: r, color: color), bounds: r)
                case .triangle(let direction):
                    guard let box = run.box else { continue }
                    let r = snap(capLocal(box, cap: cap, dyMM: dyMM))
                    list.add(.triangle(r, direction, color), bounds: r)
                case .missionControlGlyph:
                    guard let box = run.box else { continue }
                    let frames = KeyLegends.missionControlFrames(in: box).map { snap(capLocal($0, cap: cap, dyMM: dyMM)) }
                    let r = snap(capLocal(box, cap: cap, dyMM: dyMM))
                    list.add(.strokeRects(frames, width: KeyLegends.missionControlStrokeWidth, color: color), bounds: r)
                case .dot, .ring, .bump, .hairline:
                    continue
                }
            }
        }

        func trackpad(_ spec: DeckSpec, _ palette: DeckPalette, into list: inout OpList) {
            let r = snap(projection.rect(spec.trackpad)), radius = spec.trackpadCornerRadius
            list.add(.roundedRect(r, radius: radius, fill: .solid(palette.trackpad),
                                  stroke: StrokeSpec(color: palette.trackpadEdge, width: Look.trackpadEdgeWidth)),
                     bounds: r)
            if let band = topBand(r, radiusMM: radius, heightMM: Look.trackpadHighlightHeight) {
                list.add(.roundedRect(band, radius: Look.trackpadHighlightHeight / 2,
                                      fill: .solid(Look.trackpadHighlight), stroke: nil), bounds: band)
            }
            list.add(.noise(r, amplitude: Look.trackpadNoise, seed: Look.trackpadSeed), bounds: r)
        }

        /// A sunk cap: darker face inset 0.15 mm, no bevel, a deeper top shadow, legends 0.1 mm lower.
        func pressedCap(_ cap: CGRect, radius: Double, runs: [LegendRun], _ palette: DeckPalette, wash: Bool,
                        into list: inout OpList) {
            let r = snap(cap)
            list.add(.roundedRect(r, radius: radius, fill: .solid(palette.keycapRim), stroke: nil), bounds: r)
            let faceRadius = max(radius - Look.pressedFaceInset, 0)
            let face = snap(inset(cap, mm: Look.pressedFaceInset))
            let k = Look.pressedFaceLuminance
            list.add(.roundedRect(face, radius: faceRadius,
                                  fill: .vertical(top: palette.keycapFaceTop.luminanceScaled(k),
                                                  bottom: palette.keycapFaceBottom.luminanceScaled(k)),
                                  stroke: nil), bounds: face)
            list.add(.innerShadow(face, radius: faceRadius, depth: Look.pressedShadowDepth, color: Look.pressedShadow),
                     bounds: face)
            // The up key's hairline straddles the edge shared with the down key: keep it on this cap.
            capFeatures(runs, cap: cap, dyMM: Look.pressedLegendShift, palette, clip: r, into: &list)
            printedLegends(runs, cap: cap, dyMM: Look.pressedLegendShift, color: palette.legend, into: &list)
            if wash {
                list.add(.roundedRect(r, radius: radius, fill: .solid(Look.pressedWash), stroke: nil), bounds: r)
            }
        }
    }
}

extension TextAlign {
    fileprivate init(_ align: LegendAlign) {
        switch align {
        case .left: self = .left
        case .center: self = .center
        case .right: self = .right
        }
    }
}

extension RGBA {
    /// Scales the colour in linear light, so its relative luminance scales by `k` (before clipping).
    fileprivate func luminanceScaled(_ k: Double) -> RGBA {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func encoded(_ l: Double) -> Double {
            let l = min(max(l, 0), 1)
            return l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055
        }
        return RGBA(r: encoded(linear(r) * k), g: encoded(linear(g) * k), b: encoded(linear(b) * k), a: a)
    }
}

// MARK: - Model presets

extension MacBookAirModel {
    /// M4/M5 Airs print the modern legends; M1-M3 the legacy ones.
    public var legendStyle: LegendStyle { self == .air13_2025 ? .modern : .legacy }

    /// Finishes sold for this model, Apple's order (the first is the default).
    public var finishes: [DeckFinish] {
        switch self {
        case .air13_2022: return [.midnight, .starlight, .spaceGray, .silver]
        case .air13_2025: return [.skyBlue, .silver, .starlight, .midnight]
        case .air13_2020: return [.gold, .silver, .spaceGray]
        }
    }

    public var defaultFinish: DeckFinish { finishes[0] }
}
