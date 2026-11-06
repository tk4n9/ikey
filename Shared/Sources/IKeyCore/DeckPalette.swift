import Foundation

/// An sRGB colour with straight (non-premultiplied) alpha; every channel is 0...1.
public struct RGBA: Codable, Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// `hex` is 0xRRGGBB.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255,
                  g: Double((hex >> 8) & 0xFF) / 255,
                  b: Double(hex & 0xFF) / 255,
                  a: alpha)
    }

    /// WCAG relative luminance (Rec. 709 weights on linear-light channels); alpha is ignored.
    public var relativeLuminance: Double {
        0.2126 * Self.linear(r) + 0.7152 * Self.linear(g) + 0.0722 * Self.linear(b)
    }

    /// Multiplies the colour in linear light by `first`, clamps to 0...1, then multiplies by `second`.
    /// Two factors keep the spec's order: tone (clamped), then night.
    fileprivate func lit(_ first: Double, then second: Double = 1) -> RGBA {
        if first == 1 && second == 1 { return self }
        func channel(_ c: Double) -> Double {
            Self.encoded(min(max(Self.linear(c) * first, 0), 1) * second)
        }
        return RGBA(r: channel(r), g: channel(g), b: channel(b), a: a)
    }

    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ l: Double) -> Double {
        if l >= 1 { return 1 } // exact white; the curve below rounds to 1 - ulp
        let c = l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055
        return max(c, 0)
    }
}

/// MacBook Air finishes (Gold is the M1 colour).
public enum DeckFinish: String, Codable, CaseIterable, Sendable {
    case midnight, starlight, silver, spaceGray, skyBlue, gold

    public var displayName: String {
        switch self {
        case .midnight: return "Midnight"
        case .starlight: return "Starlight"
        case .silver: return "Silver"
        case .spaceGray: return "Space Gray"
        case .skyBlue: return "Sky Blue"
        case .gold: return "Gold"
        }
    }
}

/// Colours for drawing the deck. The base values are render-lit approximations measured from
/// Apple product renders (low confidence); the tone slider exists to match the real aluminium.
public struct DeckPalette: Equatable, Sendable {
    public var deck: RGBA
    public var wellFloor: RGBA
    public var wellEdge: RGBA
    public var trackpad: RGBA
    public var trackpadEdge: RGBA
    public var keycapFaceTop: RGBA
    public var keycapFaceBottom: RGBA
    public var keycapRim: RGBA
    public var keycapBevel: RGBA
    public var legend: RGBA
    public var legendBacklit: RGBA
    /// Glow colour for backlit legends; its alpha is 0.35 x night (transparent by day).
    public var legendGlow: RGBA
    public var capsLEDOff: RGBA
    public var capsLEDOn: RGBA
    /// The dark ring around the Touch ID key; toned and darkened with the keycaps.
    public var touchIDRing: RGBA

    /// - Parameters:
    ///   - tone: exposure in EV, clamped to -0.5...0.5. Aluminium (deck, well, trackpad) scales by
    ///     2^tone in linear light, keycaps by 2^(tone/2).
    ///   - night: 0...1 (clamped). Aluminium darkens by (1 - 0.75 night), keycaps by (1 - 0.4 night),
    ///     legends move toward the backlit white and the glow fades in.
    ///   NaN counts as 0; infinities clamp to the nearest bound.
    ///   `wellEdge` / `trackpadEdge` are 0.80 / 0.82 of the final `wellFloor` / `trackpad` luminance
    ///   at every tone and night, including when the toned base clips to white.
    public static func palette(_ finish: DeckFinish, tone: Double = 0, night: Double = 0) -> DeckPalette {
        let tone = clamped(tone, -0.5, 0.5)
        let night = clamped(night, 0, 1)
        let metalTone = pow(2, tone), metalNight = 1 - 0.75 * night
        let capTone = pow(2, tone / 2), capNight = 1 - 0.4 * night

        let metal = metalHex(finish)
        let floor = RGBA(hex: metal.wellFloor), pad = RGBA(hex: metal.trackpad)
        let face: (top: UInt32, bottom: UInt32) = finish == .skyBlue ? (0x2E3035, 0x27292D) : (0x2D2E32, 0x26272A)

        let legend = RGBA(hex: 0xE6E6EA), backlit = RGBA(hex: 0xFFFFFF)
        return DeckPalette(
            deck: RGBA(hex: metal.deck).lit(metalTone, then: metalNight),
            wellFloor: floor.lit(metalTone, then: metalNight),
            // Edges are 0.80 / 0.82 of the toned, clipped base, so the outline survives when the base clips.
            wellEdge: floor.lit(metalTone, then: 0.80 * metalNight),
            trackpad: pad.lit(metalTone, then: metalNight),
            trackpadEdge: pad.lit(metalTone, then: 0.82 * metalNight),
            keycapFaceTop: RGBA(hex: face.top).lit(capTone, then: capNight),
            keycapFaceBottom: RGBA(hex: face.bottom).lit(capTone, then: capNight),
            keycapRim: RGBA(hex: 0x060708).lit(capTone, then: capNight),
            keycapBevel: RGBA(hex: 0x3A3B40).lit(capTone, then: capNight),
            legend: mix(legend, backlit, night),
            legendBacklit: backlit,
            legendGlow: RGBA(hex: 0xFFFFFF, alpha: 0.35 * night),
            capsLEDOff: RGBA(hex: 0x6E6F73),
            capsLEDOn: RGBA(hex: 0x5DE16A),
            touchIDRing: RGBA(hex: 0x4A4C52).lit(capTone, then: capNight))
    }

    private static func metalHex(_ finish: DeckFinish) -> (deck: UInt32, wellFloor: UInt32, trackpad: UInt32) {
        switch finish {
        case .midnight: return (0x505865, 0x3F4754, 0x555D6A)
        case .silver: return (0xE1E2E3, 0xC1C2C4, 0xDADADC)
        case .starlight: return (0xECE6DC, 0xCAC3B9, 0xEEE7DD)
        case .skyBlue: return (0xD3DEE4, 0xABB8BF, 0xD0DBE1)
        case .spaceGray: return (0xB0B1B4, 0x848588, 0xA9AAAD)
        case .gold: return (0xE3CDB8, 0xC9B4A0, 0xE1CBB6) // M1 estimate
        }
    }

    private static func clamped(_ value: Double, _ low: Double, _ high: Double) -> Double {
        value.isNaN ? 0 : min(max(value, low), high)
    }

    /// sRGB lerp written so t = 0 and t = 1 return the end points exactly.
    private static func mix(_ from: RGBA, _ to: RGBA, _ t: Double) -> RGBA {
        func m(_ x: Double, _ y: Double) -> Double { (1 - t) * x + t * y }
        return RGBA(r: m(from.r, to.r), g: m(from.g, to.g), b: m(from.b, to.b), a: m(from.a, to.a))
    }
}
