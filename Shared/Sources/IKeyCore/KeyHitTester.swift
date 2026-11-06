import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct ResolvedKey: Equatable, Sendable {
    public var id: String
    /// nil for Touch ID (inert).
    public var code: UInt16?
    /// View points; may extend past the screen edges.
    public var rect: CGRect
    public var restCapable: Bool

    public init(id: String, code: UInt16?, rect: CGRect, restCapable: Bool) {
        self.id = id; self.code = code; self.rect = rect; self.restCapable = restCapable
    }
}

/// Deck geometry in view points, shared by drawing and hit testing.
public struct ResolvedDeck: Equatable, Sendable {
    public var keys: [ResolvedKey]
    public var trackpad: CGRect
    public var trackpadPhysicalWidthMM: Double
    public var trackpadPhysicalHeightMM: Double
    /// nil in photo mode, where points have no known physical size.
    public var mmPerPoint: Double?

    public init(keys: [ResolvedKey], trackpad: CGRect, trackpadPhysicalWidthMM: Double,
                trackpadPhysicalHeightMM: Double, mmPerPoint: Double?) {
        self.keys = keys; self.trackpad = trackpad
        self.trackpadPhysicalWidthMM = trackpadPhysicalWidthMM
        self.trackpadPhysicalHeightMM = trackpadPhysicalHeightMM
        self.mmPerPoint = mmPerPoint
    }

    /// Projected cap rects, not clipped to the screen, so edge keys stay hittable up to the screen edge.
    /// At true scale the key field (273.98 mm) is wider than a 13-inch screen (265.19 mm Pro, 263.27 mm
    /// Air): the screen-centred default clips about 4.4 mm (Pro) or 5.4 mm (Air) off the outer caps on
    /// each side, and those caps keep their full 1:1 rects here.
    public init(spec: DeckSpec, projection: DeckProjection) {
        self.init(keys: spec.keys.map {
                      ResolvedKey(id: $0.id, code: $0.keyCode, rect: projection.rect($0.cap), restCapable: $0.restCapable)
                  },
                  trackpad: projection.rect(spec.trackpad),
                  trackpadPhysicalWidthMM: spec.trackpad.width,
                  trackpadPhysicalHeightMM: spec.trackpad.height,
                  mmPerPoint: projection.mmPerPoint)
    }

    /// Photo mode: the calibrated layout mapped into the photo's frame.
    public init(layout: DeckLayout, photoFrame: CGRect) {
        let restCodes: Set<UInt16> = [0, 1, 2, 3, 38, 40, 37, 41, 49]
        let reference = MacBookAirModel.defaultModel.spec.trackpad
        self.init(keys: layout.keys.map {
                      ResolvedKey(id: $0.id, code: $0.keyCode, rect: layout.frame(for: $0).rect(in: photoFrame),
                                  restCapable: restCodes.contains($0.keyCode))
                  },
                  trackpad: layout.trackpad.rect(in: photoFrame),
                  trackpadPhysicalWidthMM: reference.width,
                  trackpadPhysicalHeightMM: reference.height,
                  mmPerPoint: nil)
    }
}

/// Nearest-key hit testing: a touch in a gap or just outside the outer keys still presses the
/// nearest key within the capture radius, as a finger partly on a MacBook key does.
public struct KeyHitTester: Sendable {
    public enum Hit: Equatable, Sendable {
        case key(code: UInt16, distance: CGFloat)
        case inert(id: String)
        case trackpad
        case outside
    }

    private let keys: [ResolvedKey]
    private let trackpad: CGRect
    private let captureRadius: CGFloat

    public init(deck: ResolvedDeck, captureRadius: CGFloat) {
        keys = deck.keys
        trackpad = deck.trackpad
        self.captureRadius = captureRadius
    }

    /// 3 mm at true scale; in photo mode 16% of the median letter-key width.
    public static func defaultCaptureRadius(for deck: ResolvedDeck) -> CGFloat {
        if let mmPerPoint = deck.mmPerPoint, mmPerPoint.isFinite, mmPerPoint > 0 {
            return CGFloat(3.0 / mmPerPoint)
        }
        let letters = deck.keys.filter { $0.code.map(letterCodes.contains) ?? false }
        let widths = (letters.isEmpty ? deck.keys : letters).map(\.rect.width).sorted()
        guard !widths.isEmpty else { return 0 }
        let mid = widths.count / 2
        let median = widths.count % 2 == 1 ? widths[mid] : (widths[mid - 1] + widths[mid]) / 2
        return 0.16 * median
    }

    private static let letterCodes: Set<UInt16> = Set(UInt16(0)...UInt16(17))
        .union(31...35).union([37, 38, 40, 45, 46])

    public func hit(_ p: CGPoint) -> Hit {
        if trackpad.contains(p) { return .trackpad }
        var best: (index: Int, distance: CGFloat)?
        for (i, key) in keys.enumerated() {
            let r = key.rect
            let dx = max(r.minX - p.x, 0, p.x - r.maxX)
            let dy = max(r.minY - p.y, 0, p.y - r.maxY)
            let d = (dx * dx + dy * dy).squareRoot()
            if d < best?.distance ?? .infinity { best = (i, d) } // ties keep the lower index
        }
        guard let best, best.distance <= captureRadius else { return .outside }
        let key = keys[best.index]
        if let code = key.code { return .key(code: code, distance: best.distance) }
        return .inert(id: key.id)
    }
}
