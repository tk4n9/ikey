import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Physical display geometry of a 13-inch iPad in landscape (mm).
public struct IPadDisplaySpec: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bodyWidth, bodyDepth, activeWidth, activeHeight, bezelX, bezelY, displayCornerRadius: Double
    public let nativePixelsLong, nativePixelsShort: Int
    /// `utsname.machine` identifiers (medium confidence).
    public let machineIDs: [String]

    public static let pro13 = IPadDisplaySpec(
        id: "pro13", name: "iPad Pro 13-inch (M4, M5)",
        bodyWidth: 281.58, bodyDepth: 215.53, activeWidth: 265.19, activeHeight: 199.14,
        bezelX: 8.195, bezelY: 8.195, displayCornerRadius: 6.3,
        nativePixelsLong: 2752, nativePixelsShort: 2064,
        machineIDs: ["iPad16,5", "iPad16,6", "iPad17,3", "iPad17,4"])

    public static let air13 = IPadDisplaySpec(
        id: "air13", name: "iPad Air 13-inch (M2, M3)",
        bodyWidth: 280.66, bodyDepth: 215.00, activeWidth: 263.27, activeHeight: 197.61,
        bezelX: 8.695, bezelY: 8.695, displayCornerRadius: 4.0,
        nativePixelsLong: 2732, nativePixelsShort: 2048,
        machineIDs: ["iPad14,10", "iPad14,11", "iPad15,5", "iPad15,6"])

    public static let all: [IPadDisplaySpec] = [pro13, air13]

    public static func preset(id: String) -> IPadDisplaySpec? {
        all.first { $0.id == id }
    }

    public static func preset(forMachine machineID: String) -> IPadDisplaySpec? {
        all.first { $0.machineIDs.contains(machineID) }
    }

    /// Matches native pixels in either orientation (±2 px). 2732 x 2048 also matches older
    /// 12.9-inch iPad Pros, whose active width is nearly the same.
    public static func detect(nativeLandscapePixels: CGSize) -> IPadDisplaySpec? {
        let w = Double(nativeLandscapePixels.width), h = Double(nativeLandscapePixels.height)
        guard w.isFinite, h.isFinite else { return nil }
        let long = max(w, h), short = min(w, h)
        return all.first {
            abs(long - Double($0.nativePixelsLong)) <= 2 && abs(short - Double($0.nativePixelsShort)) <= 2
        }
    }
}

/// User adjustment of the drawn deck relative to the reference placement
/// (iPad centred left-right, front edge flush with the deck front).
public struct DeckPlacement: Codable, Equatable, Sendable {
    /// Position of the iPad's screen centre relative to the reference, in deck mm (+x right, +y toward the hinge).
    public var offsetXmm: Double = 0
    public var offsetYmm: Double = 0
    public var scale: Double = 1

    public init(offsetXmm: Double = 0, offsetYmm: Double = 0, scale: Double = 1) {
        self.offsetXmm = offsetXmm; self.offsetYmm = offsetYmm; self.scale = scale
    }

    /// Missing keys decode to defaults so stored placements survive format additions.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offsetXmm = try c.decodeIfPresent(Double.self, forKey: .offsetXmm) ?? 0
        offsetYmm = try c.decodeIfPresent(Double.self, forKey: .offsetYmm) ?? 0
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
    }

    /// offsetX ±5 mm; offsetY ±8 mm (±12 mm for the M1 estimate); scale 0.99...1.01. Non-finite values reset.
    public func clamped(for model: MacBookAirModel) -> DeckPlacement {
        let yLimit = model == .air13_2020 ? 12.0 : 8.0
        func clamp(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
            v.isFinite ? min(max(v, lo), hi) : fallback
        }
        return DeckPlacement(offsetXmm: clamp(offsetXmm, -5, 5, 0),
                             offsetYmm: clamp(offsetYmm, -yLimit, yLimit, 0),
                             scale: clamp(scale, 0.99, 1.01, 1))
    }

    public static let stepMM = 0.1, repeatStepMM = 0.5, scaleStep = 0.0005
}

/// Isotropic mapping between deck mm (frame D) and view points (y down).
public struct DeckProjection: Equatable, Sendable {
    public let isTrueScale: Bool
    private let pointsPerMM: Double
    /// Deck mm shown at `anchorPoint`.
    private let anchorMM: MMPoint
    private let anchorX: Double
    private let anchorY: Double

    /// True-scale projection: ppm = landscape width / active width x scale. The screen centre shows
    /// D (offsetX, offsetY + bezelY + activeHeight / 2).
    /// The placement is not range-clamped here (callers normally pass `placement.clamped(for:)`), but a
    /// non-finite offset is treated as 0 and a non-finite or non-positive scale as 1, so a bad stored
    /// or preview placement still draws at true scale instead of producing NaN points.
    public init(display: IPadDisplaySpec, screenSize: CGSize, viewOriginInScreen: CGPoint = .zero,
                placement: DeckPlacement = .init()) {
        let w = Double(max(screenSize.width, screenSize.height))
        let h = Double(min(screenSize.width, screenSize.height))
        let offsetX = placement.offsetXmm.isFinite ? placement.offsetXmm : 0
        let offsetY = placement.offsetYmm.isFinite ? placement.offsetYmm : 0
        let scale = placement.scale.isFinite && placement.scale > 0 ? placement.scale : 1
        self.init(isTrueScale: true,
                  ppm: w / display.activeWidth * scale,
                  anchorMM: MMPoint(x: offsetX, y: offsetY + display.bezelY + display.activeHeight / 2),
                  screenSize: (w, h), viewOrigin: viewOriginInScreen)
    }

    /// Scaled fallback for windowed, rotated or unknown screens: the keyboard well and trackpad
    /// fill the view, centred. Deliberately uses the view's actual width and height (not the
    /// landscape max/min sides used by the true-scale init, which would draw a portrait view's deck
    /// wider than the view) and the spec's own `well.width` (279.6 mm on 2022/2025, 279.58 on M1):
    /// ppm = min(width / well.width, height / (well.maxY - trackpad.minY)); D x 0 maps to the
    /// horizontal centre and D y (well.maxY + trackpad.minY) / 2 to the vertical centre, both
    /// shifted by `viewOriginInScreen` like the true-scale path.
    public static func fitting(spec: DeckSpec, screenSize: CGSize, viewOriginInScreen: CGPoint = .zero) -> DeckProjection {
        let w = Double(screenSize.width), h = Double(screenSize.height)
        let depth = spec.well.maxY - spec.trackpad.minY
        return DeckProjection(isTrueScale: false,
                              ppm: min(w / spec.well.width, h / depth),
                              anchorMM: MMPoint(x: 0, y: (spec.well.maxY + spec.trackpad.minY) / 2),
                              screenSize: (w, h), viewOrigin: viewOriginInScreen)
    }

    private init(isTrueScale: Bool, ppm: Double, anchorMM: MMPoint, screenSize: (w: Double, h: Double), viewOrigin: CGPoint) {
        self.isTrueScale = isTrueScale
        // A zero-sized view (before layout) or a zero scale maps 1 pt per mm so nothing becomes NaN.
        self.pointsPerMM = ppm.isFinite && ppm > 0 ? ppm : 1
        self.anchorMM = anchorMM
        self.anchorX = (screenSize.w.isFinite ? screenSize.w : 0) / 2 - Double(viewOrigin.x)
        self.anchorY = (screenSize.h.isFinite ? screenSize.h : 0) / 2 - Double(viewOrigin.y)
    }

    /// Points per mm, isotropic.
    public var ppm: Double { pointsPerMM }
    public var mmPerPoint: Double { 1 / pointsPerMM }

    public func point(_ p: MMPoint) -> CGPoint {
        CGPoint(x: anchorX + (p.x - anchorMM.x) * pointsPerMM,
                y: anchorY - (p.y - anchorMM.y) * pointsPerMM)
    }

    /// The top-left of the result is the projection of (minX, maxY), since +y points away from the user.
    public func rect(_ r: MMRect) -> CGRect {
        let origin = point(MMPoint(x: r.minX, y: r.maxY))
        return CGRect(x: origin.x, y: origin.y,
                      width: CGFloat(r.width * pointsPerMM), height: CGFloat(r.height * pointsPerMM))
    }

    public func mm(_ p: CGPoint) -> MMPoint {
        MMPoint(x: anchorMM.x + (Double(p.x) - anchorX) / pointsPerMM,
                y: anchorMM.y - (Double(p.y) - anchorY) / pointsPerMM)
    }

    public func length(mm: Double) -> CGFloat { CGFloat(mm * pointsPerMM) }
}

public enum ScreenFit: String, Equatable, Sendable {
    case fullScreen, windowed, unknownDevice
}

/// Scene geometry as UIKit reports it.
public struct ScreenEnvironment: Equatable, Sendable {
    public var machineID: String
    public var nativePixels: CGSize
    public var nativeScale: Double
    public var windowPoints: CGSize
    public var viewOriginInWindow: CGPoint

    public init(machineID: String, nativePixels: CGSize, nativeScale: Double, windowPoints: CGSize,
                viewOriginInWindow: CGPoint = .zero) {
        self.machineID = machineID; self.nativePixels = nativePixels; self.nativeScale = nativeScale
        self.windowPoints = windowPoints; self.viewOriginInWindow = viewOriginInWindow
    }
}

public struct ProjectionResolution: Equatable, Sendable {
    public let display: IPadDisplaySpec?
    public let fit: ScreenFit
    public let projection: DeckProjection

    public init(display: IPadDisplaySpec?, fit: ScreenFit, projection: DeckProjection) {
        self.display = display; self.fit = fit; self.projection = projection
    }

    public var isTrueScale: Bool { fit == .fullScreen && projection.isTrueScale }
}

/// Decides true scale from scene geometry rather than from the screen alone, so a resizable or
/// rotated scene falls back to a scaled drawing.
public enum DeckGeometryResolver {
    public static func resolve(spec: DeckSpec, env: ScreenEnvironment, overrideID: String?,
                               placement: DeckPlacement) -> ProjectionResolution {
        let display = overrideID.flatMap { IPadDisplaySpec.preset(id: $0) }
            ?? IPadDisplaySpec.preset(forMachine: env.machineID)
            ?? IPadDisplaySpec.detect(nativeLandscapePixels: env.nativePixels)
        let fitting = DeckProjection.fitting(spec: spec, screenSize: env.windowPoints,
                                             viewOriginInScreen: env.viewOriginInWindow)
        guard let display else {
            return ProjectionResolution(display: nil, fit: .unknownDevice, projection: fitting)
        }
        // Display Zoom changes points and nativeScale together, so the pixel product still matches.
        let size = env.windowPoints
        let pxLong = Double(max(size.width, size.height)) * env.nativeScale
        let pxShort = Double(min(size.width, size.height)) * env.nativeScale
        let isFullScreen = abs(pxLong - Double(display.nativePixelsLong)) <= 2
            && abs(pxShort - Double(display.nativePixelsShort)) <= 2
            && size.width > size.height
        guard isFullScreen else {
            return ProjectionResolution(display: display, fit: .windowed, projection: fitting)
        }
        let projection = DeckProjection(display: display, screenSize: size,
                                        viewOriginInScreen: env.viewOriginInWindow,
                                        placement: placement.clamped(for: spec.model))
        return ProjectionResolution(display: display, fit: .fullScreen, projection: projection)
    }
}
