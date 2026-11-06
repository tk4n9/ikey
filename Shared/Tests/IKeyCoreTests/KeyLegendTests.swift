import XCTest
@testable import IKeyCore

final class KeyLegendTests: XCTestCase {
    // 2022/2025 cap sizes: width = units x 19.00 - 1.52, height 16.95.
    private let unitW = 17.48, capH = 16.95

    private func runs(_ id: String, w: Double = 17.48, h: Double = 16.95, _ style: LegendStyle = .legacy,
                      half: Bool = false) -> [LegendRun] {
        KeyLegends.runs(keyID: id, capWidth: w, capHeight: h, style: style, halfHeightFRow: half)
    }

    private func assertRun(_ run: LegendRun?, _ content: LegendContent, _ role: LegendRole, size: Double,
                           x: Double, y: Double, _ align: LegendAlign, box: (Double, Double)? = nil,
                           file: StaticString = #filePath, line: UInt = #line) {
        guard let run else { return XCTFail("missing run", file: file, line: line) }
        XCTAssertEqual(run.content, content, file: file, line: line)
        XCTAssertEqual(run.role, role, file: file, line: line)
        XCTAssertEqual(run.align, align, file: file, line: line)
        XCTAssertEqual(run.size, size, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(run.anchorX, x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(run.anchorY, y, accuracy: 1e-9, file: file, line: line)
        if let box {
            XCTAssertEqual(run.boxWidth ?? -1, box.0, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(run.boxHeight ?? -1, box.1, accuracy: 1e-9, file: file, line: line)
        } else {
            XCTAssertNil(run.boxWidth, file: file, line: line)
            XCTAssertNil(run.boxHeight, file: file, line: line)
        }
    }

    func testLetterA() {
        let a = runs("a")
        XCTAssertEqual(a.count, 1)
        assertRun(a.first, .text("A"), .letter, size: 5.30, x: 8.74, y: 10.40, .center)
        XCTAssertEqual(runs("q", .modern), [LegendRun(content: .text("Q"), role: .letter, size: 5.30,
                                                     anchorX: unitW / 2, anchorY: 10.40, align: .center)])
    }

    func testDigitTwoPair() {
        let two = runs("d2")
        XCTAssertEqual(two.count, 2)
        assertRun(two[0], .text("@"), .upper, size: 3.70, x: 8.74, y: 6.40, .center)
        assertRun(two[1], .text("2"), .lower, size: 5.30, x: 8.74, y: 13.70, .center)
        let expected: [String: (String, String)] = [
            "grave": ("~", "`"), "d1": ("!", "1"), "d9": ("(", "9"), "d0": (")", "0"), "minus": ("_", "-"),
            "equal": ("+", "="), "lbracket": ("{", "["), "rbracket": ("}", "]"), "backslash": ("|", "\\"),
            "semicolon": (":", ";"), "quote": ("\"", "'"), "comma": ("<", ","), "period": (">", "."),
            "slash": ("?", "/"),
        ]
        for (id, pair) in expected {
            XCTAssertEqual(runs(id).map(\.content), [.text(pair.0), .text(pair.1)], id)
        }
    }

    func testWordKeys() {
        let left: [String: String] = ["esc": "esc", "tab": "tab", "shift_l": "shift"]
        let right: [String: String] = ["delete": "delete", "return": "return", "shift_r": "shift"]
        let widths: [String: Double] = ["esc": 26.98, "tab": 26.98, "shift_l": 41.23, "delete": 26.98,
                                        "return": 31.73, "shift_r": 41.23]
        for (id, word) in left {
            let r = runs(id, w: widths[id]!)
            XCTAssertEqual(r.count, 1, id)
            assertRun(r.first, .text(word), .word, size: 3.20, x: 3.35, y: 13.65, .left)
        }
        for (id, word) in right {
            let w = widths[id]!
            let r = runs(id, w: w)
            XCTAssertEqual(r.count, 1, id)
            assertRun(r.first, .text(word), .word, size: 3.20, x: w - 3.35, y: 13.65, .right)
        }
    }

    func testLeftOptionLegacyVsModern() {
        let legacy = runs("option_l", .legacy), modern = runs("option_l", .modern)
        XCTAssertEqual(legacy.count, 2); XCTAssertEqual(modern.count, 2)
        assertRun(legacy[0], .symbol("option"), .modifierSymbol, size: 4.6, x: 17.48 - 3.35, y: 3.56, .right,
                  box: (4.6, 4.6))
        assertRun(legacy[1], .text("option"), .word, size: 3.20, x: 17.48 - 3.35, y: 13.65, .right)
        assertRun(modern[0], .symbol("option"), .modifierSymbol, size: 4.6, x: 3.35, y: 3.56, .left, box: (4.6, 4.6))
        assertRun(modern[1], .text("option"), .word, size: 3.20, x: 3.35, y: 13.65, .left)
        XCTAssertEqual(legacy[0].box?.maxX ?? 0, 17.48 - 3.35, accuracy: 1e-9)
        XCTAssertEqual(modern[0].box?.minX ?? 0, 3.35, accuracy: 1e-9)
    }

    func testRightModifiersMirror() {
        let w = 1.25 * 19 - 1.52
        for (id, word) in [("command_r", "command"), ("option_r", "option")] {
            let rw = id == "command_r" ? w : unitW
            let modern = runs(id, w: rw, .modern), legacy = runs(id, w: rw, .legacy)
            assertRun(modern[0], .symbol(word), .modifierSymbol, size: 4.6, x: rw - 3.35, y: 3.56, .right,
                      box: (4.6, 4.6))
            assertRun(modern[1], .text(word), .word, size: 3.20, x: rw - 3.35, y: 13.65, .right)
            assertRun(legacy[0], .symbol(word), .modifierSymbol, size: 4.6, x: 3.35, y: 3.56, .left, box: (4.6, 4.6))
            assertRun(legacy[1], .text(word), .word, size: 3.20, x: 3.35, y: 13.65, .left)
        }
        XCTAssertEqual(runs("control_l", .legacy).map(\.content), [.symbol("control"), .text("control")])
        XCTAssertEqual(runs("command_l", w: w, .modern).map(\.align), [.left, .left])
        XCTAssertEqual(runs("command_l", w: w, .legacy).map(\.align), [.right, .right])
    }

    func testFnLegacyVsModern() {
        let legacy = runs("fn", .legacy), modern = runs("fn", .modern)
        XCTAssertEqual(legacy.count, 2); XCTAssertEqual(modern.count, 2)
        assertRun(legacy[0], .text("fn"), .word, size: 3.20, x: 17.48 - 3.35, y: 6.0, .right)
        assertRun(modern[0], .text("fn"), .word, size: 3.20, x: 17.48 - 3.35, y: 13.65, .right)
        for globe in [legacy[1], modern[1]] {
            assertRun(globe, .symbol("globe"), .modifierSymbol, size: 3.9, x: 3.35, y: 13.71 - 3.9, .left,
                      box: (3.9, 3.9))
            XCTAssertEqual(globe.box?.maxY ?? 0, 13.71, accuracy: 1e-9)
        }
    }

    func testFunctionRow() {
        let symbols = ["sun.min", "sun.max", nil, "magnifyingglass", "mic", "moon",
                       "backward", "playpause", "forward", "speaker", "speaker.wave.1", "speaker.wave.3"]
        for (i, symbol) in symbols.enumerated() {
            let r = runs("f\(i + 1)")
            XCTAssertEqual(r.count, 2)
            if let symbol {
                assertRun(r[0], .symbol(symbol), .icon, size: 3.2, x: 8.74, y: 4.55, .center, box: (3.2, 3.2))
            } else {
                XCTAssertEqual(r[0].content, .missionControlGlyph)
            }
            assertRun(r[1], .text("F\(i + 1)"), .fnLabel, size: 2.40, x: 8.74, y: 13.61, .center)
        }
    }

    func testF10Mute() {
        XCTAssertEqual(runs("f10", .legacy).first?.content, .symbol("speaker"))
        XCTAssertEqual(runs("f10", .modern).first?.content, .symbol("speaker.slash"))
        XCTAssertEqual(runs("f11", .legacy), runs("f11", .modern))
    }

    func testMissionControlGlyph() {
        let glyph = runs("f3")[0]
        let box = glyph.box!
        XCTAssertEqual(Double(box.minX), 6.49, accuracy: 1e-9)
        XCTAssertEqual(Double(box.maxX), 11.10, accuracy: 1e-9)
        XCTAssertEqual(Double(box.minY), 4.61, accuracy: 1e-9)
        XCTAssertEqual(Double(box.maxY), 7.64, accuracy: 1e-9)
        let frames = KeyLegends.missionControlFrames(in: box)
        let expected: [(Double, Double, Double, Double)] = [
            (6.49, 8.79, 4.61, 6.07), (9.32, 11.10, 4.92, 7.43), (6.91, 8.90, 6.39, 7.64)]
        XCTAssertEqual(frames.count, 3)
        for (f, e) in zip(frames, expected) {
            XCTAssertEqual(Double(f.minX), e.0, accuracy: 1e-9); XCTAssertEqual(Double(f.maxX), e.1, accuracy: 1e-9)
            XCTAssertEqual(Double(f.minY), e.2, accuracy: 1e-9); XCTAssertEqual(Double(f.maxY), e.3, accuracy: 1e-9)
        }
        XCTAssertEqual(KeyLegends.missionControlStrokeWidth, 0.2)
        // M1 half-height row: scaled by 2.6/3.2 around the cap centre, top 1.6 + 0.06 x scale.
        let small = runs("f3", w: 18.6, h: 10.2, half: true)[0].box!
        let s = 2.6 / 3.2
        XCTAssertEqual(Double(small.width), 4.61 * s, accuracy: 1e-9)
        XCTAssertEqual(Double(small.minY), 1.6 + 0.06 * s, accuracy: 1e-9)
        XCTAssertEqual(Double(small.midX), 9.3 + 0.055 * s, accuracy: 1e-9)
    }

    func testHalfHeightFunctionRow() {
        let f1 = runs("f1", w: 18.6, h: 10.2, half: true)
        assertRun(f1[0], .symbol("sun.min"), .icon, size: 2.6, x: 9.3, y: 1.6, .center, box: (2.6, 2.6))
        assertRun(f1[1], .text("F1"), .fnLabel, size: 2.0, x: 9.3, y: 8.6, .center)
        assertRun(runs("esc", w: 18.6, h: 10.2, half: true).first, .text("esc"), .word, size: 2.0, x: 3.35, y: 8.6,
                  .left)
        // The flag only affects the function row.
        XCTAssertEqual(runs("a", half: true), runs("a"))
        XCTAssertEqual(runs("tab", w: 26.98, half: true), runs("tab", w: 26.98))
    }

    func testArrows() {
        let up = runs("up", h: 8.40)
        XCTAssertEqual(up.count, 2)
        assertRun(up[0], .triangle(.up), .icon, size: 1.55, x: 8.74, y: (8.40 - 1.35) / 2, .center, box: (1.55, 1.35))
        assertRun(up[1], .hairline, .icon, size: 0.35, x: 0, y: 8.40 - 0.175, .left, box: (17.48, 0.35))
        let down = runs("down", h: 8.55)
        XCTAssertEqual(down.count, 1)
        assertRun(down[0], .triangle(.down), .icon, size: 1.55, x: 8.74, y: (8.55 - 1.35) / 2, .center,
                  box: (1.55, 1.35))
        for (id, dir) in [("left", ArrowDirection.left), ("right", .right)] {
            let r = runs(id, h: 8.55)
            XCTAssertEqual(r.count, 1)
            assertRun(r[0], .triangle(dir), .icon, size: 1.55, x: 8.74, y: (8.55 - 1.55) / 2, .center,
                      box: (1.35, 1.55))
        }
    }

    func testBumpsOnlyFandJ() {
        for letter in "abcdefghijklmnopqrstuvwxyz".map(String.init) {
            let bumps = runs(letter).filter { $0.content == .bump }
            if letter == "f" || letter == "j" {
                XCTAssertEqual(bumps.count, 1, letter)
                assertRun(bumps.first, .bump, .icon, size: 2.2, x: 8.74, y: 10.40 + 0.45, .center, box: (2.2, 0.3))
            } else {
                XCTAssertTrue(bumps.isEmpty, letter)
            }
        }
    }

    func testCapsDot() {
        let caps = runs("capslock", w: 1.75 * 19 - 1.52)
        XCTAssertEqual(caps.count, 2)
        assertRun(caps[0], .dot, .icon, size: 1.26, x: 3.98, y: 4.08 - 0.63, .center, box: (1.26, 1.26))
        XCTAssertEqual(Double(caps[0].box!.midY), 4.08, accuracy: 1e-9)
        assertRun(caps[1], .text("caps lock"), .word, size: 3.20, x: 3.35, y: 13.65, .left)
    }

    func testTouchIDRingNoText() {
        let ring = runs("touchid")
        XCTAssertEqual(ring.count, 1)
        assertRun(ring[0], .ring, .icon, size: 9.3, x: 8.74, y: (16.95 - 9.3) / 2, .center, box: (9.3, 9.3))
        XCTAssertEqual(Double(ring[0].box!.midY), 16.95 / 2, accuracy: 1e-9)
        XCTAssertEqual(KeyLegends.ringStrokeWidth, 0.30)
        for style in [LegendStyle.legacy, .modern] {
            XCTAssertFalse(runs("touchid", style).contains { if case .text = $0.content { return true }; return false })
        }
    }

    func testSpaceEmpty() {
        XCTAssertEqual(runs("space", w: 5 * 19 - 1.52, .legacy), [])
        XCTAssertEqual(runs("space", w: 5 * 19 - 1.52, .modern), [])
    }

    func testUnknownKeyEmpty() {
        for id in ["", "A", "f13", "shift", "command", "num1", "kp_enter"] {
            XCTAssertEqual(runs(id), [], id)
        }
    }

    /// The 78 W1-GEO key ids with their 2022 cap sizes, hard-coded here so this test does not depend on DeckSpec.
    private static let allKeys: [(id: String, units: Double, height: Double)] = {
        let full = 16.95
        var keys: [(String, Double, Double)] = [("esc", 1.5, full)]
        keys += (1...12).map { ("f\($0)", 1, full) }
        keys += [("touchid", 1, full)]
        keys += ["grave", "d1", "d2", "d3", "d4", "d5", "d6", "d7", "d8", "d9", "d0", "minus", "equal"].map { ($0, 1, full) }
        keys += [("delete", 1.5, full), ("tab", 1.5, full)]
        keys += ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "lbracket", "rbracket", "backslash"].map { ($0, 1, full) }
        keys += [("capslock", 1.75, full)]
        keys += ["a", "s", "d", "f", "g", "h", "j", "k", "l", "semicolon", "quote"].map { ($0, 1, full) }
        keys += [("return", 1.75, full), ("shift_l", 2.25, full)]
        keys += ["z", "x", "c", "v", "b", "n", "m", "comma", "period", "slash"].map { ($0, 1, full) }
        keys += [("shift_r", 2.25, full), ("fn", 1, full), ("control_l", 1, full), ("option_l", 1, full),
                 ("command_l", 1.25, full), ("space", 5, full), ("command_r", 1.25, full), ("option_r", 1, full),
                 ("left", 1, 8.55), ("up", 1, 8.40), ("down", 1, 8.55), ("right", 1, 8.55)]
        return keys
    }()

    func testAllKeyIDsCovered() {
        XCTAssertEqual(Self.allKeys.count, 78)
        XCTAssertEqual(Set(Self.allKeys.map(\.id)).count, 78)
        let fRow = Set(["esc", "touchid"] + (1...12).map { "f\($0)" })
        for style in [LegendStyle.legacy, .modern] {
            for half in [false, true] {
                for key in Self.allKeys {
                    let m1FRow = half && fRow.contains(key.id)
                    let width = m1FRow ? (key.id == "touchid" ? 10.1 : 18.6) : key.units * 19 - 1.52
                    let height = m1FRow ? 10.2 : key.height
                    let r = runs(key.id, w: width, h: height, style, half: half)
                    if key.id == "space" { XCTAssertTrue(r.isEmpty); continue }
                    XCTAssertFalse(r.isEmpty, "\(key.id) \(style) half:\(half)")
                    for run in r {
                        let context = "\(key.id) \(run.content) \(style) half:\(half)"
                        XCTAssertEqual(run.boxWidth == nil, run.boxHeight == nil, context)
                        if case .text = run.content {
                            XCTAssertNil(run.boxWidth, context)
                            XCTAssertTrue((0...width).contains(run.anchorX), context)
                            XCTAssertTrue(run.anchorY > run.size * 0.5 && run.anchorY <= height, context)
                        } else if let box = run.box {
                            // Only the arrow hairline straddles the cap edge (by half its thickness).
                            let slack = run.content == .hairline ? 0.175 + 1e-9 : 1e-9
                            XCTAssertGreaterThanOrEqual(Double(box.minX), -1e-9, context)
                            XCTAssertLessThanOrEqual(Double(box.maxX), width + 1e-9, context)
                            XCTAssertGreaterThanOrEqual(Double(box.minY), -1e-9, context)
                            XCTAssertLessThanOrEqual(Double(box.maxY), height + slack, context)
                        } else {
                            XCTFail("non-text run without a box: \(context)")
                        }
                    }
                }
            }
        }
    }
}
