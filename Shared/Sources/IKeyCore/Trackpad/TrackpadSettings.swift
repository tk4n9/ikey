import Foundation

public enum DragStyle: String, Codable, CaseIterable, Sendable {
    case tapDrag, tapDragLock, threeFinger, holdToDrag
}

/// Trackpad behaviour on the iPad. Times are seconds, distances millimetres.
public struct TrackpadSettings: Codable, Equatable, Sendable {
    public var dragStyle: DragStyle = .tapDrag
    public var thumbClick = true
    public var restingThumb = true
    public var dragReleaseDelay: Double = 0
    public var threeFingerGestures = true
    public var lookUpTap = true
    public var doubleClickInterval: Double = 0.5
    public var tapQuiet: Double = 0.6
    public var typingBandWindow: Double = 1.5
    public var topBandMM: Double = 10
    public var sideBandMM: Double = 6
    public var palmHeelCornerMM: Double = 25

    public init() {}

    public init(dragStyle: DragStyle = .tapDrag, thumbClick: Bool = true, restingThumb: Bool = true,
                dragReleaseDelay: Double = 0, threeFingerGestures: Bool = true, lookUpTap: Bool = true,
                doubleClickInterval: Double = 0.5, tapQuiet: Double = 0.6, typingBandWindow: Double = 1.5,
                topBandMM: Double = 10, sideBandMM: Double = 6, palmHeelCornerMM: Double = 25) {
        self.dragStyle = dragStyle
        self.thumbClick = thumbClick
        self.restingThumb = restingThumb
        self.dragReleaseDelay = dragReleaseDelay
        self.threeFingerGestures = threeFingerGestures
        self.lookUpTap = lookUpTap
        self.doubleClickInterval = doubleClickInterval
        self.tapQuiet = tapQuiet
        self.typingBandWindow = typingBandWindow
        self.topBandMM = topBandMM
        self.sideBandMM = sideBandMM
        self.palmHeelCornerMM = palmHeelCornerMM
    }

    /// Missing or unreadable fields keep their defaults, so settings saved by an
    /// older or newer build still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let d = TrackpadSettings()
        dragStyle = value(.dragStyle, d.dragStyle)
        thumbClick = value(.thumbClick, d.thumbClick)
        restingThumb = value(.restingThumb, d.restingThumb)
        dragReleaseDelay = value(.dragReleaseDelay, d.dragReleaseDelay)
        threeFingerGestures = value(.threeFingerGestures, d.threeFingerGestures)
        lookUpTap = value(.lookUpTap, d.lookUpTap)
        doubleClickInterval = value(.doubleClickInterval, d.doubleClickInterval)
        tapQuiet = value(.tapQuiet, d.tapQuiet)
        typingBandWindow = value(.typingBandWindow, d.typingBandWindow)
        topBandMM = value(.topBandMM, d.topBandMM)
        sideBandMM = value(.sideBandMM, d.sideBandMM)
        palmHeelCornerMM = value(.palmHeelCornerMM, d.palmHeelCornerMM)
    }
}
