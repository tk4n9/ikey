import XCTest
@testable import IKeyCore

final class DeckPaletteTests: XCTestCase {
    private func assertColor(_ c: RGBA, _ hex: UInt32, alpha: Double = 1, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        let e = RGBA(hex: hex, alpha: alpha)
        for (got, want) in [(c.r, e.r), (c.g, e.g), (c.b, e.b), (c.a, e.a)] {
            XCTAssertEqual(got, want, accuracy: 1e-9, message, file: file, line: line)
        }
    }

    private func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }

    func testRGBAHexAndLuminance() {
        let c = RGBA(hex: 0x336699, alpha: 0.5)
        XCTAssertEqual(c, RGBA(r: 0x33 / 255.0, g: 0x66 / 255.0, b: 0x99 / 255.0, a: 0.5))
        XCTAssertEqual(RGBA(hex: 0xFFFFFF).relativeLuminance, 1, accuracy: 1e-12)
        XCTAssertEqual(RGBA(hex: 0x000000).relativeLuminance, 0)
        XCTAssertEqual(RGBA(hex: 0x808080).relativeLuminance, 0.2158605, accuracy: 1e-6)
    }

    func testRGBACodableRoundTrip() throws {
        let c = RGBA(hex: 0x5DE16A, alpha: 0.35)
        XCTAssertEqual(try JSONDecoder().decode(RGBA.self, from: JSONEncoder().encode(c)), c)
    }

    func testFinishDisplayNamesAndRawValues() {
        XCTAssertEqual(DeckFinish.allCases.count, 6)
        XCTAssertEqual(DeckFinish.spaceGray.displayName, "Space Gray")
        XCTAssertEqual(DeckFinish.skyBlue.displayName, "Sky Blue")
        XCTAssertEqual(DeckFinish(rawValue: "starlight"), .starlight)
        XCTAssertEqual(Set(DeckFinish.allCases.map(\.displayName)).count, 6)
    }

    func testHexPerFinish() {
        let expected: [DeckFinish: (UInt32, UInt32, UInt32)] = [
            .midnight: (0x505865, 0x3F4754, 0x555D6A), .silver: (0xE1E2E3, 0xC1C2C4, 0xDADADC),
            .starlight: (0xECE6DC, 0xCAC3B9, 0xEEE7DD), .skyBlue: (0xD3DEE4, 0xABB8BF, 0xD0DBE1),
            .spaceGray: (0xB0B1B4, 0x848588, 0xA9AAAD), .gold: (0xE3CDB8, 0xC9B4A0, 0xE1CBB6),
        ]
        for finish in DeckFinish.allCases {
            let p = DeckPalette.palette(finish)
            let hex = expected[finish]!
            assertColor(p.deck, hex.0, "\(finish) deck")
            assertColor(p.wellFloor, hex.1, "\(finish) well")
            assertColor(p.trackpad, hex.2, "\(finish) trackpad")
            XCTAssertEqual(p.wellEdge.relativeLuminance, 0.80 * p.wellFloor.relativeLuminance, accuracy: 1e-9)
            XCTAssertEqual(p.trackpadEdge.relativeLuminance, 0.82 * p.trackpad.relativeLuminance, accuracy: 1e-9)
            if finish != .skyBlue {
                assertColor(p.keycapFaceTop, 0x2D2E32); assertColor(p.keycapFaceBottom, 0x26272A)
            }
            assertColor(p.keycapRim, 0x060708); assertColor(p.keycapBevel, 0x3A3B40)
            assertColor(p.legend, 0xE6E6EA); assertColor(p.legendBacklit, 0xFFFFFF)
            assertColor(p.legendGlow, 0xFFFFFF, alpha: 0, "glow is off by day")
            assertColor(p.capsLEDOff, 0x6E6F73); assertColor(p.capsLEDOn, 0x5DE16A)
            assertColor(p.touchIDRing, 0x4A4C52)
        }
        // Untouched colours are exact hex values, so == comparisons work downstream.
        XCTAssertEqual(DeckPalette.palette(.midnight).deck, RGBA(hex: 0x505865))
    }

    func testToneMonotonicAndHalfForKeycaps() {
        for finish in DeckFinish.allCases {
            let tones = stride(from: -0.5, through: 0.5, by: 0.125).map { DeckPalette.palette(finish, tone: $0) }
            for (a, b) in zip(tones, tones.dropFirst()) {
                XCTAssertLessThanOrEqual(a.deck.relativeLuminance, b.deck.relativeLuminance)
                XCTAssertLessThanOrEqual(a.wellFloor.relativeLuminance, b.wellFloor.relativeLuminance)
                XCTAssertLessThanOrEqual(a.trackpad.relativeLuminance, b.trackpad.relativeLuminance)
                XCTAssertLessThan(a.keycapFaceTop.relativeLuminance, b.keycapFaceTop.relativeLuminance)
                XCTAssertEqual(a.legend, b.legend)
                XCTAssertEqual(a.capsLEDOn, b.capsLEDOn)
            }
        }
        // Midnight is dark enough that neither end clips: aluminium x2^tone, keycaps x2^(tone/2).
        let base = DeckPalette.palette(.midnight)
        for tone in [-0.5, -0.25, 0.25, 0.5] {
            let p = DeckPalette.palette(.midnight, tone: tone)
            XCTAssertEqual(p.deck.relativeLuminance, base.deck.relativeLuminance * pow(2, tone), accuracy: 1e-9)
            XCTAssertEqual(p.wellEdge.relativeLuminance, base.wellEdge.relativeLuminance * pow(2, tone), accuracy: 1e-9)
            XCTAssertEqual(p.trackpadEdge.relativeLuminance, base.trackpadEdge.relativeLuminance * pow(2, tone),
                           accuracy: 1e-9)
            XCTAssertEqual(p.keycapFaceTop.relativeLuminance, base.keycapFaceTop.relativeLuminance * pow(2, tone / 2),
                           accuracy: 1e-9)
            XCTAssertEqual(p.keycapRim.relativeLuminance, base.keycapRim.relativeLuminance * pow(2, tone / 2),
                           accuracy: 1e-9)
            XCTAssertEqual(p.touchIDRing.relativeLuminance, base.touchIDRing.relativeLuminance * pow(2, tone / 2),
                           accuracy: 1e-9)
        }
    }

    func testToneClamp() {
        for finish in DeckFinish.allCases {
            XCTAssertEqual(DeckPalette.palette(finish, tone: 3), DeckPalette.palette(finish, tone: 0.5))
            XCTAssertEqual(DeckPalette.palette(finish, tone: -3), DeckPalette.palette(finish, tone: -0.5))
            XCTAssertEqual(DeckPalette.palette(finish, tone: .nan), DeckPalette.palette(finish))
            XCTAssertEqual(DeckPalette.palette(finish, tone: .infinity), DeckPalette.palette(finish, tone: 0.5))
            XCTAssertEqual(DeckPalette.palette(finish, tone: -.infinity), DeckPalette.palette(finish, tone: -0.5))
            XCTAssertEqual(DeckPalette.palette(finish, night: .infinity), DeckPalette.palette(finish, night: 1))
            XCTAssertEqual(DeckPalette.palette(finish, night: -.infinity), DeckPalette.palette(finish))
            let bright = DeckPalette.palette(finish, tone: 0.5)
            for c in [bright.deck, bright.wellFloor, bright.wellEdge, bright.trackpad, bright.trackpadEdge] {
                for v in [c.r, c.g, c.b] { XCTAssertTrue((0...1).contains(v)) }
            }
        }
        // Starlight's trackpad (EEE7DD) exceeds 1 in every channel at +0.5 EV and clips to white,
        // and night then darkens the clipped value.
        XCTAssertEqual(DeckPalette.palette(.starlight, tone: 0.5).trackpad, RGBA(hex: 0xFFFFFF))
        XCTAssertEqual(DeckPalette.palette(.starlight, tone: 0.5, night: 1).trackpad.relativeLuminance, 0.25,
                       accuracy: 1e-9)
    }

    func testEdgeRatioHoldsWhenBaseClips() {
        // Light finishes clip at +0.5 EV; the edge must stay 0.80 / 0.82 of what is actually drawn.
        for finish in DeckFinish.allCases {
            for tone in [-0.5, 0, 0.5] {
                for night in [0, 0.5, 1.0] {
                    let p = DeckPalette.palette(finish, tone: tone, night: night)
                    XCTAssertEqual(p.wellEdge.relativeLuminance, 0.80 * p.wellFloor.relativeLuminance, accuracy: 1e-9,
                                   "\(finish) tone \(tone) night \(night)")
                    XCTAssertEqual(p.trackpadEdge.relativeLuminance, 0.82 * p.trackpad.relativeLuminance, accuracy: 1e-9,
                                   "\(finish) tone \(tone) night \(night)")
                }
            }
        }
    }

    func testSkyBlueKeycapTint() {
        let sky = DeckPalette.palette(.skyBlue)
        assertColor(sky.keycapFaceTop, 0x2E3035)
        assertColor(sky.keycapFaceBottom, 0x27292D)
        let silver = DeckPalette.palette(.silver)
        XCTAssertNotEqual(sky.keycapFaceTop, silver.keycapFaceTop)
        XCTAssertGreaterThan(sky.keycapFaceTop.b - sky.keycapFaceTop.r, silver.keycapFaceTop.b - silver.keycapFaceTop.r)
        XCTAssertGreaterThan(sky.keycapFaceTop.relativeLuminance, sky.keycapFaceBottom.relativeLuminance)
    }

    func testNightDarkensDeckAndBrightensLegends() {
        for finish in DeckFinish.allCases {
            let day = DeckPalette.palette(finish), night = DeckPalette.palette(finish, night: 1)
            XCTAssertLessThanOrEqual(night.deck.relativeLuminance, 0.3 * day.deck.relativeLuminance)
            XCTAssertEqual(night.deck.relativeLuminance, 0.25 * day.deck.relativeLuminance, accuracy: 1e-9)
            XCTAssertEqual(night.wellEdge.relativeLuminance, 0.25 * day.wellEdge.relativeLuminance, accuracy: 1e-9)
            XCTAssertEqual(night.trackpadEdge.relativeLuminance, 0.25 * day.trackpadEdge.relativeLuminance,
                           accuracy: 1e-9)
            XCTAssertEqual(night.keycapFaceTop.relativeLuminance, 0.6 * day.keycapFaceTop.relativeLuminance,
                           accuracy: 1e-9)
            XCTAssertEqual(night.legend, RGBA(hex: 0xFFFFFF))
            XCTAssertEqual(night.legendGlow, RGBA(hex: 0xFFFFFF, alpha: 0.35))
            XCTAssertEqual(night.capsLEDOn, day.capsLEDOn)
        }
        // Night is applied after tone, and partial night interpolates the legend.
        let toned = DeckPalette.palette(.silver, tone: 0.3), tonedNight = DeckPalette.palette(.silver, tone: 0.3, night: 1)
        XCTAssertEqual(tonedNight.deck.relativeLuminance, 0.25 * toned.deck.relativeLuminance, accuracy: 1e-9)
        let half = DeckPalette.palette(.silver, night: 0.5)
        XCTAssertEqual(half.legend.r, (0xE6 / 255.0 + 1) / 2, accuracy: 1e-12)
        XCTAssertEqual(half.legendGlow.a, 0.175, accuracy: 1e-12)
        XCTAssertEqual(DeckPalette.palette(.silver, night: 7), DeckPalette.palette(.silver, night: 1))
    }

    func testNightZeroIsIdentity() {
        for finish in DeckFinish.allCases {
            for tone in [-0.5, -0.2, 0, 0.35, 0.5] {
                let plain = DeckPalette.palette(finish, tone: tone)
                XCTAssertEqual(DeckPalette.palette(finish, tone: tone, night: 0), plain)
                XCTAssertEqual(DeckPalette.palette(finish, tone: tone, night: -1), plain)
                XCTAssertEqual(DeckPalette.palette(finish, tone: tone, night: .nan), plain)
                XCTAssertEqual(plain.legend, RGBA(hex: 0xE6E6EA))
            }
        }
    }
}
