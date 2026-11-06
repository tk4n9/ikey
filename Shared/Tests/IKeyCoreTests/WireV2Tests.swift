import Foundation
import XCTest
@testable import IKeyCore

final class WireV2Tests: XCTestCase {
    private let client = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private let macID = UUID(uuidString: "0E2C8A47-3A51-4F6B-9D8E-7C1B2A3D4E5F")!

    private var padMessages: [PadMessage] {
        [
            .hello(Hello(proto: 2, client: client, app: "1.2 (34)", device: "iPad Pro 13", features: WireFeature.all)),
            .input(.key(code: 55, down: true), t: 1_000),
            .input(.key(code: 102, down: false), t: 1_001),
            .input(.button(button: .left, down: true, clickState: 2), t: 1_002),
            .input(.button(button: .right, down: false, clickState: 1), t: 1_003),
            .input(.motion(PointerMotion(dx: -1.25, dy: 0.5, dt: 0.008, speed: 160.3)), t: 1_004),
            .input(.scroll(ScrollMotion(phase: .mayBegin, dx: 0, dy: 0, dt: 0, speed: 0)), t: 1_005),
            .input(.scroll(ScrollMotion(phase: .changed, dx: 0.1, dy: -4.5, dt: 0.0083, speed: 540)), t: 1_006),
            .input(.scroll(ScrollMotion(phase: .ended, dx: 0, dy: 0, dt: 0, speed: 0,
                                        releaseVX: -12.5, releaseVY: 830)), t: 1_007),
            .input(.contacts(2), t: 1_008),
            .input(.gesture(WireGesture(kind: .swipe, fingers: 3, direction: "left")), t: 1_009),
            .input(.gesture(WireGesture(kind: .tap, fingers: 3)), t: 1_010),
            .input(.releaseAll, t: Int64.max),
            .heartbeat(Heartbeat(seq: UInt32.max, held: [56, 0], buttons: [.left], active: true), t: -5),
            .ping(id: 7, t: 1_699_999_999_123_456),
            .goodbye(.background),
            .legacy(.pointer(dx: 3, dy: -2))
        ]
    }

    private var macMessages: [MacMessage] {
        var prefs = MacInputPreferences()
        prefs.keyRepeatDelay = nil
        prefs.trackingIndex = 2.5
        return [
            .welcome(Welcome(proto: 2, mac: macID, name: "Taekyung’s MacBook Air", model: "Mac14,2",
                             keyboard: .jis, displayMM: [302.4, 196.6], prefs: prefs, caps: true,
                             features: WireFeature.all)),
            .welcome(Welcome(proto: 2, mac: macID, name: "Mac", model: "Mac15,12", keyboard: .ansi,
                             displayMM: nil, prefs: MacInputPreferences(), caps: false, features: [])),
            .state(MacState()),
            .state(MacState(caps: true)),
            .state(MacState(prefs: prefs, displayAsleep: false)),
            .state(MacState(caps: false, tapOnly: [55])),
            .state(MacState(tapOnly: [])),
            .pong(id: UInt32.max, echoT: 1_699_999_999_123_456, macT: -1),
            .goodbye(.protocolMismatch)
        ]
    }

    private func pad(_ json: String) throws -> PadMessage { try WireV2.decodeFromPad(Data(json.utf8)) }
    private func mac(_ json: String) throws -> MacMessage { try WireV2.decodeFromMac(Data(json.utf8)) }

    private func assertProtocolError(_ expected: ProtocolError, _ message: String = "",
                                     file: StaticString = #filePath, line: UInt = #line,
                                     _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), message, file: file, line: line) {
            XCTAssertEqual($0 as? ProtocolError, expected, message, file: file, line: line)
        }
    }

    // MARK: Round trips and golden frames

    func testEveryPadKindRoundTrips() throws {
        for message in padMessages {
            let data = try WireV2.encode(message)
            XCTAssertEqual(data.last, 0x0a)
            XCTAssertEqual(data.filter { $0 == 0x0a }.count, 1)
            XCTAssertEqual(try WireV2.decodeFromPad(data.dropLast()), message)
            XCTAssertEqual(try WireV2.decodeFromPad(data), message, "trailing newline tolerated")
        }
        // Golden frames lock the flat key names independent of encoder key order.
        let golden: [(String, PadMessage)] = [
            (#"{"v":2,"m":"hello","proto":2,"client":"6F9619FF-8B86-D011-B42D-00C04FC964FF","app":"1.0","device":"iPad","features":["macRepeat"]}"#,
             .hello(Hello(proto: 2, client: client, app: "1.0", device: "iPad", features: ["macRepeat"]))),
            (#"{"v":2,"m":"key","t":12,"code":0,"down":true}"#, .input(.key(code: 0, down: true), t: 12)),
            (#"{"v":2,"m":"button","t":13,"button":"right","down":false,"cs":3}"#,
             .input(.button(button: .right, down: false, clickState: 3), t: 13)),
            (#"{"v":2,"m":"motion","t":14,"dx":1.5,"dy":-2,"dt":0.01,"sp":250}"#,
             .input(.motion(PointerMotion(dx: 1.5, dy: -2, dt: 0.01, speed: 250)), t: 14)),
            (#"{"v":2,"m":"scroll","t":15,"ph":"began","dx":0,"dy":3,"dt":0.016,"sp":187.5}"#,
             .input(.scroll(ScrollMotion(phase: .began, dx: 0, dy: 3, dt: 0.016, speed: 187.5)), t: 15)),
            (#"{"v":2,"m":"scroll","t":16,"ph":"ended","dx":0,"dy":0,"dt":0,"sp":0,"vx":4,"vy":-900}"#,
             .input(.scroll(ScrollMotion(phase: .ended, dx: 0, dy: 0, dt: 0, speed: 0,
                                         releaseVX: 4, releaseVY: -900)), t: 16)),
            (#"{"v":2,"m":"contacts","t":17,"n":0}"#, .input(.contacts(0), t: 17)),
            (#"{"v":2,"m":"gesture","t":18,"kind":"swipe","fingers":4,"dir":"up"}"#,
             .input(.gesture(WireGesture(kind: .swipe, fingers: 4, direction: "up")), t: 18)),
            (#"{"v":2,"m":"releaseAll","t":19}"#, .input(.releaseAll, t: 19)),
            (#"{"v":2,"m":"hb","t":20,"seq":3,"held":[55,56],"buttons":["left","right"],"active":false}"#,
             .heartbeat(Heartbeat(seq: 3, held: [55, 56], buttons: [.left, .right], active: false), t: 20)),
            (#"{"v":2,"m":"ping","t":21,"id":9}"#, .ping(id: 9, t: 21)),
            (#"{"v":2,"m":"bye","reason":"macSleeping"}"#, .goodbye(.macSleeping))
        ]
        for (json, expected) in golden {
            XCTAssertEqual(try pad(json), expected, json)
        }
    }

    func testEveryMacKindRoundTrips() throws {
        for message in macMessages {
            let data = try WireV2.encode(message)
            XCTAssertEqual(data.last, 0x0a)
            XCTAssertEqual(try WireV2.decodeFromMac(data), message)
        }
        let defaults = MacInputPreferences()
        let golden: [(String, MacMessage)] = [
            (#"{"v":2,"m":"welcome","proto":2,"mac":"0E2C8A47-3A51-4F6B-9D8E-7C1B2A3D4E5F","name":"Air","model":"Mac16,12","keyboard":"iso","displayMM":[302,196],"prefs":{},"caps":false,"features":[]}"#,
             .welcome(Welcome(proto: 2, mac: macID, name: "Air", model: "Mac16,12", keyboard: .iso,
                              displayMM: [302, 196], prefs: defaults, caps: false, features: []))),
            (#"{"v":2,"m":"state","caps":true,"asleep":true}"#, .state(MacState(caps: true, displayAsleep: true))),
            (#"{"v":2,"m":"state","prefs":{"naturalScrolling":false}}"#,
             .state(MacState(prefs: MacInputPreferences(naturalScrolling: false)))),
            (#"{"v":2,"m":"pong","id":4,"echo":100,"macT":250}"#, .pong(id: 4, echoT: 100, macT: 250)),
            (#"{"v":2,"m":"bye","reason":"replaced"}"#, .goodbye(.replaced))
        ]
        for (json, expected) in golden {
            XCTAssertEqual(try mac(json), expected, json)
        }
    }

    func testEverySplitPointPadDecoder() throws {
        let messages = padMessages
        let stream = try messages.reduce(into: Data()) { $0.append(try WireV2.encode($1)) }
        for i in 0...stream.count {
            var decoder = PadFrameDecoder()
            let first = try decoder.append(stream.prefix(i))
            let second = try decoder.append(stream.dropFirst(i))
            XCTAssertEqual(first + second, messages, "split at \(i)")
        }
        // Byte by byte.
        var decoder = PadFrameDecoder()
        var decoded: [PadMessage] = []
        for byte in stream { decoded += try decoder.append(Data([byte])) }
        XCTAssertEqual(decoded, messages)
    }

    func testEverySplitPointMacDecoder() throws {
        let messages = macMessages
        let stream = try messages.reduce(into: Data()) { $0.append(try WireV2.encode($1)) }
        for i in 0...stream.count {
            var decoder = MacFrameDecoder()
            let first = try decoder.append(stream.prefix(i))
            let second = try decoder.append(stream.dropFirst(i))
            XCTAssertEqual(first + second, messages, "split at \(i)")
        }
    }

    func testV1CorpusDecodesAsLegacy() throws {
        let corpus: [InputEvent] = [.key(code: 55, down: true), .key(code: 0, down: false),
            .pointer(dx: -17.5, dy: 12), .button(button: .right, down: true), .button(button: .left, down: false),
            .scroll(dx: 8, dy: -23), .releaseAll, .heartbeat]
        var stream = Data()
        for event in corpus {
            let frame = try WireCodec.encode(event)
            XCTAssertEqual(try WireV2.decodeFromPad(frame), .legacy(event))
            // .legacy encodes as a v1 frame (compared decoded: Linux key order is unstable).
            XCTAssertEqual(try WireCodec.decode(WireV2.encode(PadMessage.legacy(event)).dropLast()), event)
            stream.append(frame)
        }
        // A v1 session's byte stream through the v2 Mac decoder, mixed with v2 frames.
        stream.append(try WireV2.encode(PadMessage.ping(id: 1, t: 2)))
        var decoder = PadFrameDecoder()
        XCTAssertEqual(try decoder.append(stream), corpus.map(PadMessage.legacy) + [.ping(id: 1, t: 2)])
        // v1 rules still apply inside a legacy frame.
        assertProtocolError(.invalidEvent) { _ = try self.pad(#"{"version":1,"event":{"key":{"code":65535,"down":true}}}"#) }
        assertProtocolError(.unsupportedVersion) { _ = try self.pad(#"{"version":999,"event":{"releaseAll":{}}}"#) }
        assertProtocolError(.invalidEvent) { _ = try self.pad(#"{"version":1,"event":{"teleport":{}}}"#) }
        // The Mac never speaks v1.
        assertProtocolError(.unsupportedVersion) { _ = try self.mac(#"{"version":1,"event":{"releaseAll":{}}}"#) }
    }

    func testUnknownKindDecodesUnknown() throws {
        XCTAssertEqual(try pad(#"{"v":2,"m":"haptic","t":1,"strength":0.4}"#), .unknown("haptic"))
        XCTAssertEqual(try mac(#"{"v":2,"m":"clipboard","text":"x"}"#), .unknown("clipboard"))
        // Kinds belong to one direction.
        XCTAssertEqual(try mac(#"{"v":2,"m":"key","t":1,"code":0,"down":true}"#), .unknown("key"))
        XCTAssertEqual(try pad(#"{"v":2,"m":"pong","id":4,"echo":100,"macT":250}"#), .unknown("pong"))
        // Unknown messages are receive-only and their kind is bounded.
        assertProtocolError(.invalidEvent) { _ = try WireV2.encode(PadMessage.unknown("haptic")) }
        assertProtocolError(.invalidEvent) { _ = try WireV2.encode(MacMessage.unknown("clipboard")) }
        // An over-long unknown kind is still ignorable: its name is cut to 64 UTF-8 bytes.
        let longKind = String(repeating: "k", count: 65)
        XCTAssertEqual(try pad(#"{"v":2,"m":"\#(longKind)"}"#), .unknown(String(repeating: "k", count: 64)))
        XCTAssertEqual(try mac(#"{"v":2,"m":"\#(longKind)"}"#), .unknown(String(repeating: "k", count: 64)))
        let wide = "a" + String(repeating: "é", count: 40) // 81 bytes; cut on a scalar boundary
        XCTAssertEqual(try pad(#"{"v":2,"m":"\#(wide)"}"#), .unknown("a" + String(repeating: "é", count: 31)))
    }

    func testUnknownEnumValuesInGoodbyeAndWelcomeAreTolerated() throws {
        // A newer peer's goodbye reason is still a goodbye; it never means "unpaired".
        XCTAssertEqual(try pad(#"{"v":2,"m":"bye","reason":"updating"}"#), .goodbye(.receiverStopping))
        XCTAssertEqual(try mac(#"{"v":2,"m":"bye","reason":"updating"}"#), .goodbye(.receiverStopping))
        // A keyboard layout this build does not know is drawn as ANSI.
        let welcome = try mac(#"{"v":2,"m":"welcome","proto":2,"mac":"0E2C8A47-3A51-4F6B-9D8E-7C1B2A3D4E5F","name":"Air","model":"Mac16,12","keyboard":"abnt","prefs":{},"caps":false,"features":[]}"#)
        guard case .welcome(let w) = welcome else { return XCTFail("\(welcome)") }
        XCTAssertEqual(w.keyboard, .ansi)
        // Mistyped values are still malformed.
        assertProtocolError(.invalidEvent) { _ = try self.pad(#"{"v":2,"m":"bye","reason":3}"#) }
        assertProtocolError(.invalidEvent) { _ = try self.pad(#"{"v":2,"m":"bye"}"#) }
        assertProtocolError(.invalidEvent) {
            _ = try self.mac(#"{"v":2,"m":"welcome","proto":2,"mac":"0E2C8A47-3A51-4F6B-9D8E-7C1B2A3D4E5F","name":"Air","model":"M","keyboard":null,"prefs":{},"caps":false,"features":[]}"#)
        }
    }

    func testMalformedFramesThrow() {
        for json in ["not json", "[1,2]", "42", #"{"m":"key"}"#, #"{"v":"2","m":"key"}"#, #"{"v":2}"#, #"{"v":2,"m":5}"#] {
            assertProtocolError(.invalidFrame, json) { _ = try self.pad(json) }
            assertProtocolError(.invalidFrame, json) { _ = try self.mac(json) }
        }
        assertProtocolError(.invalidFrame) { _ = try WireV2.decodeFromPad(Data()) }
        // Known kinds with missing or mistyped fields.
        for json in [#"{"v":2,"m":"key","code":0,"down":true}"#,                 // no t
                     #"{"v":2,"m":"key","t":1,"code":-1,"down":true}"#,
                     #"{"v":2,"m":"key","t":1.5,"code":0,"down":true}"#,
                     #"{"v":2,"m":"button","t":1,"button":"middle","down":true,"cs":1}"#,
                     #"{"v":2,"m":"scroll","t":1,"ph":"flung","dx":0,"dy":0,"dt":0.01,"sp":0}"#,
                     #"{"v":2,"m":"gesture","t":1,"kind":"pinch","fingers":3}"#,
                     #"{"v":2,"m":"hello","proto":2,"client":"nope","app":"a","device":"d","features":[]}"#,
                     #"{"v":2,"m":"ping","t":1,"id":-3}"#] {
            assertProtocolError(.invalidEvent, json) { _ = try self.pad(json) }
        }
        for json in [#"{"v":2,"m":"pong","id":4,"echo":100}"#,
                     #"{"v":2,"m":"state","prefs":{"trackingIndex":"fast"}}"#,
                     #"{"v":2,"m":"welcome","proto":2}"#] {
            assertProtocolError(.invalidEvent, json) { _ = try self.mac(json) }
        }
    }

    // MARK: Validation

    func testOutOfRangeFieldsThrow() {
        func motion(dx: Double = 1, dy: Double = 1, dt: Double = 0.01, speed: Double = 100) -> PadMessage {
            .input(.motion(PointerMotion(dx: dx, dy: dy, dt: dt, speed: speed)), t: 0)
        }
        func scroll(_ phase: WireScrollPhase = .changed, dx: Double = 1, dt: Double = 0.01,
                    vx: Double? = nil, vy: Double? = nil) -> PadMessage {
            .input(.scroll(ScrollMotion(phase: phase, dx: dx, dy: 0, dt: dt, speed: 10,
                                        releaseVX: vx, releaseVY: vy)), t: 0)
        }
        func hello(app: String = "a", device: String = "d", features: [String] = []) -> PadMessage {
            .hello(Hello(proto: 2, client: client, app: app, device: device, features: features))
        }
        let long = String(repeating: "é", count: 33) // 66 UTF-8 bytes
        let rules: [(String, PadMessage)] = [
            ("dx not finite", motion(dx: .nan)),
            ("dy infinite", motion(dy: -.infinity)),
            ("dx > 300 mm", motion(dx: 300.5)),
            ("dy < -300 mm", motion(dy: -301)),
            ("scroll dx > 300 mm", scroll(dx: 400)),
            ("dt = 0 for motion", motion(dt: 0)),
            ("dt negative", motion(dt: -0.01)),
            ("dt > 0.5", motion(dt: 0.51)),
            ("dt = 0 for changed scroll", scroll(dt: 0)),
            ("dt > 0.5 for began scroll", scroll(.began, dt: 0.6)),
            ("dt NaN", scroll(.ended, dt: .nan)),
            ("dt infinite for ended scroll", scroll(.ended, dt: .infinity)),
            ("dt negative for cancelled scroll", scroll(.cancelled, dt: -0.1)),
            ("speed negative", motion(speed: -1)),
            ("speed > 5000", motion(speed: 5001)),
            ("speed NaN", motion(speed: .nan)),
            ("|vx| > 5000", scroll(.ended, dt: 0, vx: 5001)),
            ("|vy| > 5000", scroll(.ended, dt: 0, vy: -6000)),
            ("vy NaN", scroll(.ended, dt: 0, vy: .nan)),
            ("clickState 0", .input(.button(button: .left, down: true, clickState: 0), t: 0)),
            ("clickState 4", .input(.button(button: .left, down: true, clickState: 4), t: 0)),
            ("contacts -1", .input(.contacts(-1), t: 0)),
            ("contacts 11", .input(.contacts(11), t: 0)),
            ("fingers 2", .input(.gesture(WireGesture(kind: .swipe, fingers: 2, direction: "up")), t: 0)),
            ("fingers 6", .input(.gesture(WireGesture(kind: .tap, fingers: 6)), t: 0)),
            ("direction > 64 bytes", .input(.gesture(WireGesture(kind: .swipe, fingers: 3, direction: long)), t: 0)),
            ("app > 64 bytes", hello(app: long)),
            ("device > 64 bytes", hello(device: long)),
            ("feature > 64 bytes", hello(features: [long])),
            ("features > 32", hello(features: Array(repeating: "f", count: 33))),
            ("proto 0", .hello(Hello(proto: 0, client: client, app: "a", device: "d", features: []))),
            ("held > 32", .heartbeat(Heartbeat(seq: 0, held: Array(repeating: 0, count: 33), buttons: [], active: true), t: 0)),
            ("held unsupported code", .heartbeat(Heartbeat(seq: 0, held: [200], buttons: [], active: true), t: 0)),
            ("buttons > 32", .heartbeat(Heartbeat(seq: 0, held: [], buttons: Array(repeating: .left, count: 33), active: true), t: 0)),
            ("key code unsupported", .input(.key(code: 127, down: true), t: 0)),
            ("key code 65535", .input(.key(code: 65535, down: false), t: 0)),
            ("legacy event invalid", .legacy(.pointer(dx: .infinity, dy: 0)))
        ]
        for (rule, message) in rules {
            assertProtocolError(.invalidEvent, rule) { _ = try WireV2.encode(message) }
        }

        func welcome(name: String = "Mac", model: String = "Mac14,2", displayMM: [Double]? = nil,
                     prefs: MacInputPreferences = .init(), features: [String] = []) -> MacMessage {
            .welcome(Welcome(proto: 2, mac: macID, name: name, model: model, keyboard: .ansi,
                             displayMM: displayMM, prefs: prefs, caps: false, features: features))
        }
        let macRules: [(String, MacMessage)] = [
            ("name > 64 bytes", welcome(name: long)),
            ("model > 64 bytes", welcome(model: long)),
            ("features > 32", welcome(features: Array(repeating: "f", count: 33))),
            ("displayMM one value", welcome(displayMM: [300])),
            ("displayMM zero", welcome(displayMM: [300, 0])),
            ("displayMM NaN", welcome(displayMM: [.nan, 200])),
            ("welcome prefs invalid", welcome(prefs: MacInputPreferences(trackingIndex: 3.5))),
            ("state prefs invalid", .state(MacState(prefs: MacInputPreferences(keyRepeatInterval: 0)))),
            ("state tapOnly key 300", .state(MacState(tapOnly: [55, 300]))),
            ("state tapOnly > 32", .state(MacState(tapOnly: Array(repeating: 55, count: 33))))
        ]
        for (rule, message) in macRules {
            assertProtocolError(.invalidEvent, rule) { _ = try WireV2.encode(message) }
        }

        // Decoding applies the same rules to frames a peer built by hand.
        let decoded: [(String, String)] = [
            ("dx > 300 mm", #"{"v":2,"m":"motion","t":1,"dx":301,"dy":0,"dt":0.01,"sp":1}"#),
            ("dt = 0", #"{"v":2,"m":"motion","t":1,"dx":1,"dy":0,"dt":0,"sp":1}"#),
            ("speed > 5000", #"{"v":2,"m":"scroll","t":1,"ph":"changed","dx":1,"dy":0,"dt":0.01,"sp":9000}"#),
            ("clickState 4", #"{"v":2,"m":"button","t":1,"button":"left","down":true,"cs":4}"#),
            ("contacts 11", #"{"v":2,"m":"contacts","t":1,"n":11}"#),
            ("fingers 2", #"{"v":2,"m":"gesture","t":1,"kind":"tap","fingers":2}"#),
            ("key 127", #"{"v":2,"m":"key","t":1,"code":127,"down":true}"#),
            ("held 300", #"{"v":2,"m":"hb","t":1,"seq":1,"held":[300],"buttons":[],"active":true}"#)
        ]
        for (rule, json) in decoded {
            assertProtocolError(.invalidEvent, rule) { _ = try self.pad(json) }
        }
        assertProtocolError(.invalidEvent, "prefs on decode") {
            _ = try self.mac(#"{"v":2,"m":"state","prefs":{"doubleClickInterval":9}}"#)
        }
    }

    func testBoundaryValuesAccepted() throws {
        let boundary: [PadMessage] = [
            .input(.motion(PointerMotion(dx: 300, dy: -300, dt: 0.5, speed: 5000)), t: 0),
            .input(.motion(PointerMotion(dx: 0, dy: 0, dt: 0.000_001, speed: 0)), t: 0),
            .input(.scroll(ScrollMotion(phase: .cancelled, dx: 0, dy: 0, dt: 0, speed: 0)), t: 0),
            .input(.scroll(ScrollMotion(phase: .ended, dx: 0, dy: 0, dt: 0.5, speed: 0,
                                        releaseVX: -5000, releaseVY: 5000)), t: 0),
            // Boundary phases carry no motion: a lift or touch after a long pause has any dt ≥ 0.
            .input(.scroll(ScrollMotion(phase: .ended, dx: 0, dy: 0, dt: 0.8, speed: 0,
                                        releaseVX: 0, releaseVY: 0)), t: 0),
            .input(.scroll(ScrollMotion(phase: .mayBegin, dx: 0, dy: 0, dt: 30, speed: 0)), t: 0),
            .input(.scroll(ScrollMotion(phase: .cancelled, dx: 0, dy: 0, dt: 2.5, speed: 0)), t: 0),
            .input(.button(button: .left, down: true, clickState: 3), t: 0),
            .input(.contacts(10), t: 0),
            .input(.gesture(WireGesture(kind: .swipe, fingers: 5, direction: String(repeating: "d", count: 64))), t: 0),
            .heartbeat(Heartbeat(seq: 0, held: Array(repeating: 56, count: 32), buttons: [], active: false), t: 0),
            .hello(Hello(proto: 2, client: client, app: String(repeating: "a", count: 64), device: "",
                         features: Array(repeating: String(repeating: "f", count: 64), count: 32)))
        ]
        for message in boundary {
            XCTAssertEqual(try WireV2.decodeFromPad(WireV2.encode(message)), message)
        }
        for code: UInt16 in [93, 94, 95, 102, 104] {
            let message = PadMessage.input(.key(code: code, down: true), t: 0)
            XCTAssertEqual(try WireV2.decodeFromPad(WireV2.encode(message)), message, "JIS \(code)")
        }
    }

    func testVersion3Rejected() {
        assertProtocolError(.unsupportedVersion) { _ = try self.pad(#"{"v":3,"m":"key","t":1,"code":0,"down":true}"#) }
        assertProtocolError(.unsupportedVersion) { _ = try self.mac(#"{"v":3,"m":"welcome"}"#) }
        assertProtocolError(.unsupportedVersion) { _ = try self.pad(#"{"v":1,"m":"key"}"#) }
        var decoder = PadFrameDecoder()
        assertProtocolError(.unsupportedVersion) { _ = try decoder.append(Data(#"{"v":3,"m":"future"}"#.utf8 + [0x0a])) }
    }

    func testBatchOrderPreserved() throws {
        let t: Int64 = 5_000
        let batch: [PadMessage] = [.input(.key(code: 56, down: true), t: t), .input(.key(code: 0, down: true), t: t),
            .input(.key(code: 0, down: false), t: t + 1), .input(.key(code: 56, down: false), t: t + 1),
            .input(.button(button: .left, down: true, clickState: 1), t: t + 2),
            .input(.motion(PointerMotion(dx: 1, dy: 0, dt: 0.01, speed: 100)), t: t + 3),
            .input(.button(button: .left, down: false, clickState: 1), t: t + 4),
            .heartbeat(Heartbeat(seq: 1, held: [], buttons: [], active: false), t: t + 5), .goodbye(.user)]
        let bytes = try batch.reduce(into: Data()) { $0.append(try WireV2.encode($1)) }
        var decoder = PadFrameDecoder()
        XCTAssertEqual(try decoder.append(bytes), batch)
        let replies: [MacMessage] = [.state(MacState(caps: true)), .pong(id: 1, echoT: 2, macT: 3), .state(MacState(caps: false))]
        var macDecoder = MacFrameDecoder()
        XCTAssertEqual(try macDecoder.append(try replies.reduce(into: Data()) { $0.append(try WireV2.encode($1)) }), replies)
    }

    // MARK: Coalescing

    func testCoalescedMergesMotionNotAcrossButton() {
        func m(_ dx: Double, _ dy: Double, _ dt: Double, _ speed: Double) -> PadInput {
            .motion(PointerMotion(dx: dx, dy: dy, dt: dt, speed: speed))
        }
        let down = PadInput.button(button: .left, down: true, clickState: 1)
        let up = PadInput.button(button: .left, down: false, clickState: 1)
        let result = PadInput.coalesced([m(1, 2, 0.01, 100), m(0.5, -1, 0.02, 80), m(0.25, 0, 0.004, 90),
                                         down, m(3, 3, 0.01, 300), m(1, 1, 0.01, 200), up, m(1, 0, 0.01, 50)])
        XCTAssertEqual(result.count, 5)
        guard case .motion(let first) = result[0], case .motion(let second) = result[2] else {
            return XCTFail("unexpected \(result)")
        }
        XCTAssertEqual(first.dx, 1.75, accuracy: 1e-12)
        XCTAssertEqual(first.dy, 1, accuracy: 1e-12)
        XCTAssertEqual(first.dt, 0.034, accuracy: 1e-12)
        XCTAssertEqual(first.speed, 90)
        XCTAssertEqual(result[1], down)
        XCTAssertEqual(second, PointerMotion(dx: 4, dy: 4, dt: 0.02, speed: 200))
        XCTAssertEqual(result[3], up)
        XCTAssertEqual(result[4], m(1, 0, 0.01, 50))
        // Keys, contacts and gestures also separate runs; nothing else is merged.
        let others: [PadInput] = [m(1, 0, 0.01, 1), .key(code: 0, down: true), m(1, 0, 0.01, 1), .contacts(1),
                                  m(1, 0, 0.01, 1), .releaseAll, .releaseAll, .contacts(1), .contacts(1)]
        XCTAssertEqual(PadInput.coalesced(others), others)
        XCTAssertEqual(PadInput.coalesced([]), [])
        // A merge that would leave the wire limits starts a new run instead.
        let long = PadInput.coalesced([m(200, 0, 0.3, 1), m(200, 0, 0.3, 1), m(50, 0, 0.1, 1)])
        XCTAssertEqual(long, [m(200, 0, 0.3, 1), m(250, 0, 0.4, 1)])
    }

    func testCoalescedMergesScrollChangedNotAcrossEnded() {
        func s(_ phase: WireScrollPhase, _ dy: Double, vy: Double? = nil) -> PadInput {
            .scroll(ScrollMotion(phase: phase, dx: 0, dy: dy, dt: 0.01, speed: abs(dy) * 100, releaseVY: vy))
        }
        let input = [s(.mayBegin, 0), s(.began, 1), s(.changed, 2), s(.changed, 3), s(.changed, -1),
                     s(.ended, 0, vy: 400), s(.changed, 5), s(.cancelled, 0), s(.ended, 0), s(.ended, 0)]
        let result = PadInput.coalesced(input)
        XCTAssertEqual(result, [s(.mayBegin, 0), s(.began, 1),
                                .scroll(ScrollMotion(phase: .changed, dx: 0, dy: 4, dt: 0.03, speed: 100)),
                                s(.ended, 0, vy: 400), s(.changed, 5), s(.cancelled, 0), s(.ended, 0), s(.ended, 0)])
        // Motion and scroll never merge with each other.
        let mixed: [PadInput] = [s(.changed, 1), .motion(PointerMotion(dx: 1, dy: 0, dt: 0.01, speed: 1)), s(.changed, 1)]
        XCTAssertEqual(PadInput.coalesced(mixed), mixed)
    }

    // MARK: Preferences

    func testPrefsDecodeIfPresentDefaults() throws {
        let defaults = MacInputPreferences()
        XCTAssertEqual(defaults.keyRepeatDelay, 0.5)
        XCTAssertEqual(defaults.keyRepeatInterval, 0.083)
        XCTAssertTrue(defaults.naturalScrolling)
        XCTAssertEqual(defaults.trackingIndex, 0.6875)
        XCTAssertFalse(defaults.fnKeysStandard)
        XCTAssertEqual(defaults.doubleClickInterval, 0.5)
        XCTAssertFalse(defaults.threeFingerDrag)
        XCTAssertFalse(defaults.dragLock)
        XCTAssertTrue(defaults.tapToClick)
        XCTAssertTrue(defaults.threeFingerSwipes)
        XCTAssertFalse(defaults.appExposeGesture)
        XCTAssertEqual(MacInputPreferences(), MacInputPreferences(keyRepeatDelay: 0.5))
        XCTAssertNoThrow(try defaults.validate())

        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(MacInputPreferences.self, from: Data("{}".utf8)), defaults)
        let partial = try decoder.decode(MacInputPreferences.self,
                                         from: Data(#"{"trackingIndex":1.5,"tapToClick":false,"future":1}"#.utf8))
        XCTAssertEqual(partial, MacInputPreferences(trackingIndex: 1.5, tapToClick: false))
        // A peer that does not know the App Exposé flag leaves it at its default (off).
        let exposeOn = try decoder.decode(MacInputPreferences.self, from: Data(#"{"appExposeGesture":true}"#.utf8))
        XCTAssertEqual(exposeOn, MacInputPreferences(appExposeGesture: true))
        // Explicit null = key repeat off; absent = default.
        let off = try decoder.decode(MacInputPreferences.self, from: Data(#"{"keyRepeatDelay":null}"#.utf8))
        XCTAssertNil(off.keyRepeatDelay)
        XCTAssertThrowsError(try decoder.decode(MacInputPreferences.self, from: Data(#"{"dragLock":"yes"}"#.utf8)))

        // Every field round-trips, including repeat off.
        let custom = MacInputPreferences(keyRepeatDelay: nil, keyRepeatInterval: 0.015, naturalScrolling: false,
                                         trackingIndex: 3, fnKeysStandard: true, doubleClickInterval: 5,
                                         threeFingerDrag: true, dragLock: true, tapToClick: false,
                                         threeFingerSwipes: false, appExposeGesture: true)
        XCTAssertNoThrow(try custom.validate())
        XCTAssertEqual(try decoder.decode(MacInputPreferences.self, from: JSONEncoder().encode(custom)), custom)

        for invalid in [MacInputPreferences(keyRepeatDelay: 0.05), MacInputPreferences(keyRepeatDelay: 2.1),
                        MacInputPreferences(keyRepeatDelay: .nan), MacInputPreferences(keyRepeatInterval: 0.01),
                        MacInputPreferences(keyRepeatInterval: 2.5), MacInputPreferences(trackingIndex: -0.1),
                        MacInputPreferences(trackingIndex: .infinity), MacInputPreferences(doubleClickInterval: 0.05),
                        MacInputPreferences(doubleClickInterval: 5.1)] {
            XCTAssertThrowsError(try invalid.validate(), "\(invalid)") {
                XCTAssertEqual($0 as? ProtocolError, .invalidEvent)
            }
            XCTAssertNoThrow(try invalid.clamped().validate(), "\(invalid)")
        }
    }

    func testPrefsClampedFitsTheWireRanges() throws {
        // Values `defaults write` allows: KeyRepeat 0, InitialKeyRepeat 1, trackpad scaling -1.
        let raw = MacInputPreferences(keyRepeatDelay: 0.015, keyRepeatInterval: 0, trackingIndex: -1,
                                      doubleClickInterval: 9)
        let clamped = raw.clamped()
        XCTAssertEqual(clamped, MacInputPreferences(keyRepeatDelay: 0.1, keyRepeatInterval: 0.015, trackingIndex: 0,
                                                    doubleClickInterval: 5))
        XCTAssertNoThrow(try WireV2.encode(MacMessage.state(MacState(prefs: clamped))))
        XCTAssertNil(MacInputPreferences(keyRepeatDelay: 3).clamped().keyRepeatDelay, "long delay = repeat off")
        XCTAssertNil(MacInputPreferences(keyRepeatDelay: nil).clamped().keyRepeatDelay)
        XCTAssertEqual(MacInputPreferences(keyRepeatDelay: .nan, keyRepeatInterval: .infinity, trackingIndex: .nan,
                                           doubleClickInterval: -.infinity).clamped(), MacInputPreferences())
        let valid = MacInputPreferences(keyRepeatDelay: 0.25, keyRepeatInterval: 0.03, naturalScrolling: false,
                                        trackingIndex: 3, tapToClick: false)
        XCTAssertEqual(valid.clamped(), valid)
    }

    // MARK: MacState.tapOnly (additive field)

    func testStateTapOnlyRoundTripAndEncoding() throws {
        let state = MacState(caps: true, prefs: MacInputPreferences(naturalScrolling: false), displayAsleep: false,
                             tapOnly: [55, 61])
        let data = try WireV2.encode(MacMessage.state(state))
        XCTAssertEqual(try WireV2.decodeFromMac(data), .state(state))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""tapOnly":[55,61]"#))

        // Encoded only when non-nil; [] (clear) is distinct from nil (unchanged).
        let without = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: WireV2.encode(MacMessage.state(MacState(caps: true)))) as? [String: Any])
        XCTAssertNil(without["tapOnly"])
        XCTAssertEqual(Set(without.keys), ["v", "m", "caps"])
        let cleared = try WireV2.encode(MacMessage.state(MacState(tapOnly: [])))
        XCTAssertEqual(try WireV2.decodeFromMac(cleared), .state(MacState(tapOnly: [])))
        XCTAssertNotEqual(MacState(tapOnly: []), MacState())

        // The user's remap, computed on the Mac and sent as a state.
        let remap = KeyRemap.merged(hidutil: [55: 57, 57: 53], modifierKeys: [:], karabiner: [:], manual: nil)
        let sent = MacState(tapOnly: remap.tapOnlyPadCodes.sorted())
        XCTAssertEqual(try WireV2.decodeFromMac(WireV2.encode(MacMessage.state(sent))), .state(MacState(tapOnly: [55])))

        // Through the split-capable decoder too.
        var decoder = MacFrameDecoder()
        XCTAssertEqual(try decoder.append(data + WireV2.encode(MacMessage.state(MacState(caps: false)))),
                       [.state(state), .state(MacState(caps: false))])
    }

    func testStateTapOnlyCompatibility() throws {
        // An older Mac's state (no tapOnly) decodes with tapOnly nil, i.e. unchanged.
        let old = #"{"v":2,"m":"state","caps":true,"prefs":{"naturalScrolling":false},"asleep":false}"#
        XCTAssertEqual(try mac(old), .state(MacState(caps: true, prefs: MacInputPreferences(naturalScrolling: false),
                                                     displayAsleep: false)))
        XCTAssertEqual(try mac(#"{"v":2,"m":"state"}"#), .state(MacState()))
        XCTAssertEqual(try mac(#"{"v":2,"m":"state","tapOnly":null}"#), .state(MacState()))
        XCTAssertEqual(try mac(#"{"v":2,"m":"state","caps":false,"tapOnly":[55]}"#),
                       .state(MacState(caps: false, tapOnly: [55])))
        // Older iPads decode states by key and ignore keys they do not know, the way this build
        // ignores a later additive field.
        XCTAssertEqual(try mac(#"{"v":2,"m":"state","caps":true,"tapOnly":[55],"future":{"x":1}}"#),
                       .state(MacState(caps: true, tapOnly: [55])))
        // A malformed or out-of-range list is rejected like any other invalid field.
        for json in [#"{"v":2,"m":"state","tapOnly":[300]}"#, #"{"v":2,"m":"state","tapOnly":[-1]}"#,
                     #"{"v":2,"m":"state","tapOnly":55}"#, #"{"v":2,"m":"state","tapOnly":["55"]}"#] {
            assertProtocolError(.invalidEvent, json) { _ = try self.mac(json) }
        }
        let maxList = Array(repeating: UInt16(55), count: 32)
        XCTAssertNoThrow(try WireV2.encode(MacMessage.state(MacState(tapOnly: maxList))))
    }

    // MARK: Framing limits and discovery

    func testFrameTooLarge() throws {
        let max = WireCodec.maxFrameBytes
        assertProtocolError(.frameTooLarge) { _ = try WireV2.decodeFromPad(Data(repeating: 0x20, count: max + 1)) }
        assertProtocolError(.frameTooLarge) { _ = try WireV2.decodeFromMac(Data(repeating: 0x20, count: max + 1)) }
        var decoder = PadFrameDecoder()
        assertProtocolError(.frameTooLarge) { _ = try decoder.append(Data(repeating: 0x61, count: max + 1)) }
        var split = MacFrameDecoder()
        XCTAssertEqual(try split.append(Data(repeating: 0x20, count: max)), [])
        assertProtocolError(.frameTooLarge) { _ = try split.append(Data([0x20])) }

        // A valid frame padded to exactly the limit still decodes; one byte more does not.
        let ping = Data(#"{"v":2,"m":"ping","t":1,"id":2}"#.utf8)
        let padded = Data(repeating: 0x20, count: max - ping.count) + ping
        XCTAssertEqual(padded.count, max)
        var exact = PadFrameDecoder()
        XCTAssertEqual(try exact.append(padded + [0x0a]), [.ping(id: 2, t: 1)])
        var over = PadFrameDecoder()
        assertProtocolError(.frameTooLarge) { _ = try over.append(Data([0x20]) + padded + [0x0a]) }
        // The single-frame decoders agree: the trailing newline does not count toward the limit.
        XCTAssertEqual(try WireV2.decodeFromPad(padded + [0x0a]), .ping(id: 2, t: 1))
        XCTAssertEqual(try WireV2.decodeFromPad(padded + [0x0d, 0x0a]), .ping(id: 2, t: 1))
        XCTAssertEqual(try WireV2.decodeFromPad(padded), .ping(id: 2, t: 1))
        assertProtocolError(.frameTooLarge) { _ = try WireV2.decodeFromPad(Data([0x20]) + padded + [0x0a]) }
        let pong = Data(#"{"v":2,"m":"pong","id":4,"echo":100,"macT":250}"#.utf8)
        let paddedPong = Data(repeating: 0x20, count: max - pong.count) + pong
        XCTAssertEqual(try WireV2.decodeFromMac(paddedPong + [0x0a]), .pong(id: 4, echoT: 100, macT: 250))
        assertProtocolError(.invalidFrame) { _ = try WireV2.decodeFromPad(Data([0x0a])) }
    }

    func testDecoderDeliversMessagesBeforeABadFrame() throws {
        let keyUp = try WireV2.encode(PadMessage.input(.key(code: 56, down: false), t: 5))
        let bad = Data(#"{"v":2,"m":"key","t":6,"code":999,"down":true}"#.utf8 + [0x0a])
        let after = try WireV2.encode(PadMessage.input(.releaseAll, t: 7))
        var decoder = PadFrameDecoder()
        // The key-up ahead of the bad frame is delivered; the error follows on the next call and
        // the bytes after the bad frame are dropped.
        XCTAssertEqual(try decoder.append(keyUp + bad + after), [.input(.key(code: 56, down: false), t: 5)])
        assertProtocolError(.invalidEvent) { _ = try decoder.append(Data()) }
        // Reported once; the decoder then starts clean.
        XCTAssertEqual(try decoder.append(after), [.input(.releaseAll, t: 7)])
        // With nothing decoded first, the error is immediate.
        assertProtocolError(.invalidEvent) { _ = try decoder.append(bad + after) }
        XCTAssertEqual(try decoder.append(Data()), [])

        var macDecoder = MacFrameDecoder()
        let state = try WireV2.encode(MacMessage.state(MacState(caps: true)))
        XCTAssertEqual(try macDecoder.append(state + Data("nope\n".utf8)), [.state(MacState(caps: true))])
        assertProtocolError(.invalidFrame) { _ = try macDecoder.append(state) }
    }

    func testPeerProtocolFromTXT() {
        XCTAssertEqual(WireV2.peerProtocol(txt: [TXTRecordKeys.proto: "2"]), 2)
        XCTAssertEqual(WireV2.peerProtocol(txt: ["proto": "3", "id": UUID().uuidString]), 3)
        XCTAssertEqual(WireV2.peerProtocol(txt: [:]), 1)
        XCTAssertEqual(WireV2.peerProtocol(txt: ["id": "x"]), 1)
        XCTAssertEqual(WireV2.peerProtocol(txt: ["proto": "x"]), 1)
        XCTAssertEqual(WireV2.peerProtocol(txt: ["proto": ""]), 1)
        XCTAssertEqual(WireV2.peerProtocol(txt: ["proto": "0"]), 1)
        XCTAssertEqual(WireV2.peerProtocol(txt: ["proto": "-2"]), 1)
        XCTAssertEqual(WireV2.peerProtocol(txt: ["proto": "2.5"]), 1)
        XCTAssertEqual(TXTRecordKeys.macID, "id")
        XCTAssertEqual(WireV2.version, 2)
        XCTAssertEqual(WireFeature.all, ["macRepeat", "mmMotion", "scrollPhases", "gestures", "capsSync", "clickState"])
    }

    /// Regression: the heartbeat carries the iPad's key confirmation delay (0 with palm protection
    /// off) so the Mac stops adding a fixed 45 ms to Caps Lock holds. Additive: absent when nil,
    /// older frames without it still decode, and it must lie in 0...0.25.
    func testHeartbeatKeyConfirmDelay() throws {
        for delay in [0.0, 0.045, 0.25] {
            let message = PadMessage.heartbeat(Heartbeat(seq: 2, held: [57], buttons: [], active: true,
                                                         keyConfirmDelay: delay), t: 30)
            XCTAssertEqual(try WireV2.decodeFromPad(try WireV2.encode(message)), message, "delay \(delay)")
        }
        XCTAssertEqual(try pad(#"{"v":2,"m":"hb","t":1,"seq":1,"held":[],"buttons":[],"active":true,"confirm":0}"#),
                       .heartbeat(Heartbeat(seq: 1, held: [], buttons: [], active: true, keyConfirmDelay: 0), t: 1))
        XCTAssertEqual(try pad(#"{"v":2,"m":"hb","t":1,"seq":1,"held":[],"buttons":[],"active":true}"#),
                       .heartbeat(Heartbeat(seq: 1, held: [], buttons: [], active: true), t: 1))
        let plain = try WireV2.encode(.heartbeat(Heartbeat(seq: 1, held: [], buttons: [], active: false), t: 1))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("confirm"))
        let stated = try WireV2.encode(.heartbeat(Heartbeat(seq: 1, held: [], buttons: [], active: false,
                                                            keyConfirmDelay: 0), t: 1))
        XCTAssertTrue(String(decoding: stated, as: UTF8.self).contains(#""confirm":0"#))
        for bad in [-0.001, 0.2501, .nan, .infinity] {
            assertProtocolError(.invalidEvent, "confirm \(bad)") {
                _ = try WireV2.encode(.heartbeat(Heartbeat(seq: 1, held: [], buttons: [], active: true,
                                                           keyConfirmDelay: bad), t: 1))
            }
        }
        assertProtocolError(.invalidEvent, "confirm 1 on decode") {
            _ = try self.pad(#"{"v":2,"m":"hb","t":1,"seq":1,"held":[],"buttons":[],"active":true,"confirm":1}"#)
        }
        let protection = TouchProtectionSettings()
        XCTAssertTrue(protection.enabled)
        XCTAssertEqual(DeckInputEngine.keyConfirmationDelay(for: protection), 0.045)
        var off = protection
        off.enabled = false
        XCTAssertEqual(DeckInputEngine.keyConfirmationDelay(for: off), 0)
    }
}
