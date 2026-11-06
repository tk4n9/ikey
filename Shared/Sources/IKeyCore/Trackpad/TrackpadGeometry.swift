import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Maps view points inside the drawn trackpad to physical millimetres measured
/// from the trackpad's top-left corner (the edge nearest the hinge is y = 0).
public struct TrackpadGeometry: Equatable, Sendable {
    public var rect: CGRect
    public var physicalWidthMM: Double
    public var physicalHeightMM: Double

    /// Defaults are the MacBook Air 13.6" trackpad.
    public init(rect: CGRect, physicalWidthMM: Double = 128.2, physicalHeightMM: Double = 80.05) {
        self.rect = rect
        self.physicalWidthMM = physicalWidthMM
        self.physicalHeightMM = physicalHeightMM
    }

    public var mmPerPointX: Double {
        rect.width > 0 ? physicalWidthMM / Double(rect.width) : 0
    }

    public var mmPerPointY: Double {
        rect.height > 0 ? physicalHeightMM / Double(rect.height) : 0
    }

    public func toMM(_ p: CGPoint) -> (x: Double, y: Double) {
        (Double(p.x - rect.minX) * mmPerPointX, Double(p.y - rect.minY) * mmPerPointY)
    }

    public func containsMM(x: Double, y: Double, expandedBy: Double) -> Bool {
        x.isFinite && y.isFinite &&
            x >= -expandedBy && x <= physicalWidthMM + expandedBy &&
            y >= -expandedBy && y <= physicalHeightMM + expandedBy
    }
}
