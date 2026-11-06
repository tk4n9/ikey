import Foundation

/// Data for Fit & Size: rulers, the ID-1 card and key spans (the true-scale check, part of setup), plus
/// reference distances measured on the real MacBook (the position check, optional/advanced).
///
/// The overlay of the iPad on the MacBook is a conceptual yardstick: the default placement is
/// screen-centred (`DeckPlacement.Reference.screenCentred`), not front-flush. The scale checks hold at
/// any placement because placement only translates the 1:1 deck.
public enum ScaleCheck {
    public struct Tick: Equatable, Sendable {
        public enum Kind: Sendable { case mm, half, cm }
        public let posMM: Double
        public let kind: Kind
        /// Centimetre number on .cm ticks.
        public let label: String?
    }

    public struct SpanCheck: Equatable, Sendable {
        public let fromKeyID: String
        public let toKeyID: String
        /// Distance between the two keys' left edges.
        public let expectedMM: Double
        public let label: String
    }

    public enum Axis: Sendable { case x, y }

    public struct ReferenceDistance: Equatable, Sendable {
        public let id: String
        public let label: String
        public let expectedMM: Double
        public let axis: Axis
    }

    public struct PlacementSuggestion: Equatable, Sendable {
        public let offsetXmm: Double
        public let offsetYmm: Double
        /// Largest disagreement left after the shift, including any part of the shift that the
        /// placement clamp could not apply; large values mean the preset does not match this MacBook.
        public let maxResidualMM: Double
    }

    /// One tick per mm over 0...lengthMM.
    public static func rulerTicks(lengthMM: Int) -> [Tick] {
        guard lengthMM >= 0 else { return [] }
        return (0...lengthMM).map { i in
            if i % 10 == 0 { return Tick(posMM: Double(i), kind: .cm, label: String(i / 10)) }
            return Tick(posMM: Double(i), kind: i % 5 == 0 ? .half : .mm, label: nil)
        }
    }

    public static let idCardWidthMM = 85.60, idCardHeightMM = 53.98, idCardCornerMM = 3.18

    /// ISO/IEC 7810 ID-1 card centred on the trackpad.
    public static func cardRect(centeredOn spec: DeckSpec) -> MMRect {
        MMRect(minX: spec.trackpad.midX - idCardWidthMM / 2, minY: spec.trackpad.midY - idCardHeightMM / 2,
               width: idCardWidthMM, height: idCardHeightMM)
    }

    public static func spanChecks(spec: DeckSpec) -> [SpanCheck] {
        [("a", "quote", "A to ' left edges"), ("grave", "equal", "` to = left edges")].compactMap { from, to, label in
            guard let a = spec.key(id: from), let b = spec.key(id: to) else { return nil }
            return SpanCheck(fromKeyID: from, toKeyID: to, expectedMM: rounded(b.cap.minX - a.cap.minX), label: label)
        }
    }

    /// Distances the user measures on the uncovered MacBook, from the deck front edge or its left side.
    public static func referenceDistances(spec: DeckSpec) -> [ReferenceDistance] {
        let front = spec.chassis.minY, left = spec.chassis.minX
        var result = [
            ReferenceDistance(id: "front_trackpad", label: "Front edge to trackpad front edge",
                              expectedMM: rounded(spec.trackpad.minY - front), axis: .y)
        ]
        if let space = spec.key(id: "space") {
            result.append(ReferenceDistance(id: "front_space", label: "Front edge to space bar bottom edge",
                                            expectedMM: rounded(space.cap.minY - front), axis: .y))
        }
        if let a = spec.key(id: "a") {
            result.append(ReferenceDistance(id: "left_a", label: "Left side to A key left edge",
                                            expectedMM: rounded(a.cap.minX - left), axis: .x))
        }
        result.append(ReferenceDistance(id: "left_trackpad", label: "Left side to trackpad left edge",
                                        expectedMM: rounded(spec.trackpad.minX - left), axis: .x))
        return result
    }

    /// Shifts the placement by the mean disagreement per axis between measured and expected
    /// distances (relative to `current`). Unknown ids and non-finite values are ignored.
    ///
    /// The shift is relative, so it applies to either reference, but it restores physical registration
    /// only for an iPad lying front-flush on the MacBook with the deck drawn at `.frontFlush`. At the
    /// default `.screenCentred` reference it is an advanced option; `maxResidualMM` stays meaningful
    /// either way as a sign that the preset does not match this MacBook.
    ///
    /// The measured distances do not depend on the current placement, so the shift is not
    /// idempotent: pass the placement from before any earlier suggestion was applied, or applying
    /// the result twice moves the deck twice. The result is clamped by `DeckPlacement.clamped(for:)`
    /// and the clamped-away part of the shift is added to `maxResidualMM`.
    public static func suggestPlacement(spec: DeckSpec, measured: [String: Double],
                                        current: DeckPlacement) -> PlacementSuggestion {
        var deviations: [Axis: [Double]] = [.x: [], .y: []]
        for ref in referenceDistances(spec: spec) {
            guard let value = measured[ref.id], value.isFinite else { continue }
            deviations[ref.axis, default: []].append(value - ref.expectedMM)
        }
        func mean(_ axis: Axis) -> Double {
            let values = deviations[axis] ?? []
            return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
        let devX = mean(.x), devY = mean(.y)
        let spread = deviations.flatMap { axis, values in
            values.map { abs($0 - (axis == .x ? devX : devY)) }
        }.max() ?? 0
        let wanted = DeckPlacement(offsetXmm: current.offsetXmm - devX, offsetYmm: current.offsetYmm - devY,
                                   scale: current.scale)
        let placement = wanted.clamped(for: spec.model)
        // Shift the clamp could not apply; a non-finite `current` offset resets to 0 and is not a loss.
        func clampLoss(_ wanted: Double, _ got: Double) -> Double { wanted.isFinite ? abs(wanted - got) : 0 }
        let residual = max(spread,
                           clampLoss(wanted.offsetXmm, placement.offsetXmm),
                           clampLoss(wanted.offsetYmm, placement.offsetYmm))
        return PlacementSuggestion(offsetXmm: placement.offsetXmm, offsetYmm: placement.offsetYmm,
                                   maxResidualMM: residual)
    }

    /// Nominal values are stated to 0.01 mm; rounding removes floating-point noise from the D-frame sums.
    private static func rounded(_ mm: Double) -> Double { (mm * 100).rounded() / 100 }
}
