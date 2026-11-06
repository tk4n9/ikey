import Foundation

// Protocol v2: newline-delimited flat JSON objects {"v":2,"m":<kind>,...}. The iPad sends
// physical intent (keys, mm motion, scroll phases, click state, gestures) with sender
// timestamps "t" in microseconds; the Mac answers with its settings and state.

public enum WireScrollPhase: String, Codable, Sendable { case mayBegin, began, changed, ended, cancelled }

/// Pointer travel in trackpad millimetres over `dt` seconds; `speed` in mm/s.
public struct PointerMotion: Codable, Equatable, Sendable {
    public var dx, dy, dt, speed: Double

    public init(dx: Double, dy: Double, dt: Double, speed: Double) {
        self.dx = dx; self.dy = dy; self.dt = dt; self.speed = speed
    }
}

/// Two-finger scroll in millimetres; release velocities (mm/s) accompany `.ended`.
public struct ScrollMotion: Codable, Equatable, Sendable {
    public var phase: WireScrollPhase
    public var dx, dy, dt, speed: Double
    public var releaseVX: Double?
    public var releaseVY: Double?

    public init(phase: WireScrollPhase, dx: Double, dy: Double, dt: Double, speed: Double,
                releaseVX: Double? = nil, releaseVY: Double? = nil) {
        self.phase = phase; self.dx = dx; self.dy = dy; self.dt = dt; self.speed = speed
        self.releaseVX = releaseVX; self.releaseVY = releaseVY
    }
}

public enum WireGestureKind: String, Codable, Sendable { case swipe, tap }

public struct WireGesture: Codable, Equatable, Sendable {
    public var kind: WireGestureKind
    public var fingers: Int
    /// Swipe direction name (for example "left"); nil for taps.
    public var direction: String?

    public init(kind: WireGestureKind, fingers: Int, direction: String? = nil) {
        self.kind = kind; self.fingers = fingers; self.direction = direction
    }
}

public enum PadInput: Equatable, Sendable {
    case key(code: UInt16, down: Bool)
    case button(button: PointerButton, down: Bool, clickState: Int)
    case motion(PointerMotion)
    case scroll(ScrollMotion)
    case contacts(Int)
    case gesture(WireGesture)
    case releaseAll

    /// Merges runs of consecutive `.motion`, and of consecutive `.scroll(.changed)`, into one
    /// (dx, dy and dt summed, last speed and release velocity kept). Never merges across any
    /// other input, and stops merging where the sum would leave the wire limits.
    public static func coalesced(_ inputs: [PadInput]) -> [PadInput] {
        var result: [PadInput] = []
        result.reserveCapacity(inputs.count)
        for input in inputs {
            if let last = result.last, let merged = last.merged(with: input) {
                result[result.count - 1] = merged
            } else {
                result.append(input)
            }
        }
        return result
    }

    private func merged(with next: PadInput) -> PadInput? {
        switch (self, next) {
        case let (.motion(a), .motion(b)):
            let m = PointerMotion(dx: a.dx + b.dx, dy: a.dy + b.dy, dt: a.dt + b.dt, speed: b.speed)
            return WireLimits.mergeable(dx: m.dx, dy: m.dy, dt: m.dt) ? .motion(m) : nil
        case let (.scroll(a), .scroll(b)) where a.phase == .changed && b.phase == .changed:
            let s = ScrollMotion(phase: .changed, dx: a.dx + b.dx, dy: a.dy + b.dy, dt: a.dt + b.dt,
                                 speed: b.speed, releaseVX: b.releaseVX, releaseVY: b.releaseVY)
            return WireLimits.mergeable(dx: s.dx, dy: s.dy, dt: s.dt) ? .scroll(s) : nil
        default:
            return nil
        }
    }
}

public enum GoodbyeReason: String, Codable, Sendable {
    case background, user, replaced, unpaired, macSleeping, receiverStopping, protocolMismatch
}

/// First frame from the iPad on a v2 link.
public struct Hello: Codable, Equatable, Sendable {
    public var proto: Int
    public var client: UUID
    public var app: String
    public var device: String
    public var features: [String]

    public init(proto: Int, client: UUID, app: String, device: String, features: [String]) {
        self.proto = proto; self.client = client; self.app = app; self.device = device
        self.features = features
    }
}

/// The Mac's answer to a hello: identity, hardware and current settings.
public struct Welcome: Codable, Equatable, Sendable {
    public var proto: Int
    public var mac: UUID
    public var name: String
    /// hw.model, for example "Mac14,2".
    public var model: String
    public var keyboard: KeyboardKind
    /// Built-in display [width, height] in millimetres, when known.
    public var displayMM: [Double]?
    public var prefs: MacInputPreferences
    public var caps: Bool
    public var features: [String]

    public init(proto: Int, mac: UUID, name: String, model: String, keyboard: KeyboardKind,
                displayMM: [Double]?, prefs: MacInputPreferences, caps: Bool, features: [String]) {
        self.proto = proto; self.mac = mac; self.name = name; self.model = model
        self.keyboard = keyboard; self.displayMM = displayMM; self.prefs = prefs; self.caps = caps
        self.features = features
    }
}

/// A change of Mac state; nil fields are unchanged.
public struct MacState: Codable, Equatable, Sendable {
    public var caps: Bool?
    public var prefs: MacInputPreferences?
    public var displayAsleep: Bool?

    public init(caps: Bool? = nil, prefs: MacInputPreferences? = nil, displayAsleep: Bool? = nil) {
        self.caps = caps; self.prefs = prefs; self.displayAsleep = displayAsleep
    }
}

/// What the iPad currently holds, so the Mac can release anything it missed.
public struct Heartbeat: Codable, Equatable, Sendable {
    public var seq: UInt32
    public var held: [UInt16]
    public var buttons: [PointerButton]
    /// True while any contact is on the deck.
    public var active: Bool

    public init(seq: UInt32, held: [UInt16], buttons: [PointerButton], active: Bool) {
        self.seq = seq; self.held = held; self.buttons = buttons; self.active = active
    }
}

/// Messages from the iPad. `t` is the sender's timestamp in microseconds.
public enum PadMessage: Equatable, Sendable {
    case hello(Hello)
    case input(PadInput, t: Int64)
    case heartbeat(Heartbeat, t: Int64)
    case ping(id: UInt32, t: Int64)
    case goodbye(GoodbyeReason)
    /// A protocol v1 frame ({"version":1,"event":...}); encodes back to v1.
    case legacy(InputEvent)
    /// A v2 frame of a kind this build does not know; receive-only.
    case unknown(String)
}

/// Messages from the Mac.
public enum MacMessage: Equatable, Sendable {
    case welcome(Welcome)
    case state(MacState)
    /// `echoT` is the ping's `t`; `macT` is the Mac's clock in microseconds.
    case pong(id: UInt32, echoT: Int64, macT: Int64)
    case goodbye(GoodbyeReason)
    /// A v2 frame of a kind this build does not know; receive-only.
    case unknown(String)
}

/// Capability names exchanged in hello/welcome.
public enum WireFeature {
    public static let macRepeat = "macRepeat", mmMotion = "mmMotion", scrollPhases = "scrollPhases",
                      gestures = "gestures", capsSync = "capsSync", clickState = "clickState"
    public static let all: [String] = [macRepeat, mmMotion, scrollPhases, gestures, capsSync, clickState]
}

/// Bonjour TXT keys the Mac advertises.
public enum TXTRecordKeys {
    public static let proto = "proto", macID = "id"
}

public enum WireV2 {
    public static let version = 2

    /// One newline-terminated frame. Throws ProtocolError.invalidEvent for out-of-range values
    /// or `.unknown`; `.legacy` encodes as a v1 frame.
    public static func encode(_ m: PadMessage) throws -> Data {
        if case .legacy(let event) = m { return try WireCodec.encode(event) }
        return try frame(PadFrame(message: m))
    }

    /// One newline-terminated frame. Throws ProtocolError.invalidEvent for out-of-range values
    /// or `.unknown`.
    public static func encode(_ m: MacMessage) throws -> Data {
        try frame(MacFrame(message: m))
    }

    /// Decodes one frame; a trailing newline is tolerated and does not count toward the 8192-byte
    /// limit. Unknown kinds → `.unknown` (kind cut to 64 UTF-8 bytes); v1 frames →
    /// `.legacy`; malformed or out-of-range known kinds → invalidEvent; other versions →
    /// unsupportedVersion; non-JSON → invalidFrame.
    public static func decodeFromPad(_ frame: Data) throws -> PadMessage {
        try decode(PadFrame.self, frame).message
    }

    /// Decodes one frame from the Mac; see `decodeFromPad`. The Mac never sends v1 frames.
    public static func decodeFromMac(_ frame: Data) throws -> MacMessage {
        try decode(MacFrame.self, frame).message
    }

    /// The protocol a peer advertises in its Bonjour TXT record; absent or invalid → 1.
    public static func peerProtocol(txt: [String: String]) -> Int {
        guard let text = txt[TXTRecordKeys.proto]?.trimmingCharacters(in: .whitespaces),
              let value = Int(text), value >= 1 else { return 1 }
        return value
    }

    private static func frame<T: Encodable>(_ value: T) throws -> Data {
        var data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch let error as ProtocolError {
            throw error
        } catch {
            throw ProtocolError.invalidEvent
        }
        guard data.count <= WireCodec.maxFrameBytes else { throw ProtocolError.frameTooLarge }
        data.append(0x0a)
        return data
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ frame: Data) throws -> T {
        // The limit applies to the frame body, as in the stream decoders: drop one "\n" or "\r\n".
        var body = frame[...]
        if body.last == 0x0a {
            body = body.dropLast()
            if body.last == 0x0d { body = body.dropLast() }
        }
        guard !body.isEmpty else { throw ProtocolError.invalidFrame }
        guard body.count <= WireCodec.maxFrameBytes else { throw ProtocolError.frameTooLarge }
        do {
            return try JSONDecoder().decode(type, from: Data(body))
        } catch let error as ProtocolError {
            throw error
        } catch {
            throw ProtocolError.invalidFrame
        }
    }
}

/// Splits a byte stream into v2 frames from the iPad. TCP may split a frame anywhere or deliver
/// several together.
///
/// When a chunk holds a malformed frame, `append` still returns the messages decoded before it
/// (a key-up just ahead of a bad frame is not lost) and throws that error on the next call;
/// `append(Data())` surfaces it at once. Bytes after the bad frame are discarded. With nothing
/// decoded first, the error is thrown immediately.
public struct PadFrameDecoder {
    private var lines = FrameLines()
    public init() {}

    public mutating func append(_ data: Data) throws -> [PadMessage] {
        try lines.append(data, decode: WireV2.decodeFromPad)
    }
}

/// Splits a byte stream into v2 frames from the Mac; errors behave as in `PadFrameDecoder`.
public struct MacFrameDecoder {
    private var lines = FrameLines()
    public init() {}

    public mutating func append(_ data: Data) throws -> [MacMessage] {
        try lines.append(data, decode: WireV2.decodeFromMac)
    }
}

// MARK: - Framing

/// Newline framing shared by both decoders; a frame never exceeds WireCodec.maxFrameBytes.
private struct FrameLines {
    private var pending = Data()
    private var deferredError: ProtocolError?

    mutating func append<M>(_ data: Data, decode: (Data) throws -> M) throws -> [M] {
        if let error = deferredError {
            deferredError = nil
            throw error
        }
        var messages: [M] = []
        var rest = data[...]
        do {
            while let newline = rest.firstIndex(of: 0x0a) {
                try buffer(rest[rest.startIndex..<newline])
                let frame = pending
                pending = Data()
                messages.append(try decode(frame))
                rest = rest[rest.index(after: newline)...]
            }
            try buffer(rest)
        } catch {
            pending = Data()
            guard messages.isEmpty else {
                deferredError = (error as? ProtocolError) ?? .invalidFrame
                return messages
            }
            throw error
        }
        return messages
    }

    private mutating func buffer(_ bytes: Data) throws {
        guard pending.count + bytes.count <= WireCodec.maxFrameBytes else { throw ProtocolError.frameTooLarge }
        pending.append(bytes)
    }
}

// MARK: - Validation

private enum WireLimits {
    static let maxMM = 300.0
    static let maxDT = 0.5
    static let maxSpeed = 5000.0
    static let maxStringBytes = 64
    static let maxListCount = 32
    static let maxDisplayMM = 5000.0

    static func mergeable(dx: Double, dy: Double, dt: Double) -> Bool {
        abs(dx) <= maxMM && abs(dy) <= maxMM && dt <= maxDT
    }

    static func check(_ condition: Bool) throws {
        guard condition else { throw ProtocolError.invalidEvent }
    }

    static func checkMM(_ dx: Double, _ dy: Double) throws {
        try check(abs(dx) <= maxMM && abs(dy) <= maxMM) // false for NaN and ±inf
    }

    /// Motion and live scroll phases (began, changed) need 0 < dt ≤ 0.5.
    static func checkDT(_ dt: Double) throws {
        try check(dt > 0 && dt <= maxDT)
    }

    /// Boundary scroll phases (mayBegin, ended, cancelled) carry no motion, so dt only has to be
    /// finite and ≥ 0: a lift after a long pause must not fail.
    static func checkBoundaryDT(_ dt: Double) throws {
        try check(dt.isFinite && dt >= 0)
    }

    static func checkSpeed(_ speed: Double) throws {
        try check((0...maxSpeed).contains(speed))
    }

    static func checkString(_ value: String) throws {
        try check(value.utf8.count <= maxStringBytes)
    }

    static func checkStrings(_ values: [String]) throws {
        try check(values.count <= maxListCount)
        try values.forEach(checkString)
    }

    static func checkKey(_ code: UInt16) throws {
        try check(InputEvent.supportedKeyCodes.contains(code))
    }
}

private extension PadInput {
    func validate() throws {
        switch self {
        case .key(let code, _):
            try WireLimits.checkKey(code)
        case .button(_, _, let clickState):
            try WireLimits.check((1...3).contains(clickState))
        case .motion(let m):
            try WireLimits.checkMM(m.dx, m.dy)
            try WireLimits.checkDT(m.dt)
            try WireLimits.checkSpeed(m.speed)
        case .scroll(let s):
            try WireLimits.checkMM(s.dx, s.dy)
            if s.phase == .began || s.phase == .changed {
                try WireLimits.checkDT(s.dt)
            } else {
                try WireLimits.checkBoundaryDT(s.dt)
            }
            try WireLimits.checkSpeed(s.speed)
            for v in [s.releaseVX, s.releaseVY].compactMap({ $0 }) {
                try WireLimits.check(abs(v) <= WireLimits.maxSpeed)
            }
        case .contacts(let n):
            try WireLimits.check((0...10).contains(n))
        case .gesture(let g):
            try WireLimits.check((3...5).contains(g.fingers))
            if let direction = g.direction { try WireLimits.checkString(direction) }
        case .releaseAll:
            break
        }
    }
}

private extension PadMessage {
    func validate() throws {
        switch self {
        case .hello(let h):
            try WireLimits.check(h.proto >= 1)
            try WireLimits.checkString(h.app)
            try WireLimits.checkString(h.device)
            try WireLimits.checkStrings(h.features)
        case .input(let input, _):
            try input.validate()
        case .heartbeat(let hb, _):
            try WireLimits.check(hb.held.count <= WireLimits.maxListCount
                && hb.buttons.count <= WireLimits.maxListCount)
            try hb.held.forEach(WireLimits.checkKey)
        case .legacy(let event):
            try event.validate()
        case .unknown(let kind):
            try WireLimits.checkString(kind)
        case .ping, .goodbye:
            break
        }
    }
}

private extension MacMessage {
    func validate() throws {
        switch self {
        case .welcome(let w):
            try WireLimits.check(w.proto >= 1)
            try WireLimits.checkString(w.name)
            try WireLimits.checkString(w.model)
            try WireLimits.checkStrings(w.features)
            if let display = w.displayMM {
                try WireLimits.check(display.count == 2
                    && display.allSatisfy { $0 > 0 && $0 <= WireLimits.maxDisplayMM })
            }
            try w.prefs.validate()
        case .state(let s):
            try s.prefs?.validate()
        case .unknown(let kind):
            try WireLimits.checkString(kind)
        case .pong, .goodbye:
            break
        }
    }
}

// MARK: - Flat JSON coding

private enum WireKey: String, CodingKey {
    case v, m, t
    case version, event // v1 envelope
    case proto, client, app, device, features
    case code, down, button, cs
    case dx, dy, dt, sp, ph, vx, vy, n
    case kind, fingers, dir
    case seq, held, buttons, active
    case id, reason
    case mac, name, model, keyboard, displayMM, prefs, caps, asleep
    case echo, macT
}

private enum PadKind: String {
    case hello, key, button, motion, scroll, contacts, gesture, releaseAll, hb, ping, bye
}

private enum MacKind: String {
    case welcome, state, pong, bye
}

/// Reads the frame header. Returns nil for a v1 envelope; throws for other versions.
private func readKind(_ c: KeyedDecodingContainer<WireKey>) throws -> String? {
    if !c.contains(.v), c.contains(.version) { return nil }
    let version: Int
    let kind: String
    do {
        version = try c.decode(Int.self, forKey: .v)
    } catch {
        throw ProtocolError.invalidFrame
    }
    guard version == WireV2.version else { throw ProtocolError.unsupportedVersion }
    do {
        kind = try c.decode(String.self, forKey: .m)
    } catch {
        throw ProtocolError.invalidFrame
    }
    return kind
}

private func wireContainer(_ decoder: Decoder) throws -> KeyedDecodingContainer<WireKey> {
    do {
        return try decoder.container(keyedBy: WireKey.self)
    } catch {
        throw ProtocolError.invalidFrame
    }
}

/// An unknown kind from a newer peer is ignored, not fatal: keep at most 64 UTF-8 bytes of its
/// name (whole scalars only) so `.unknown` always passes validation.
private func truncatedKind(_ kind: String) -> String {
    guard kind.utf8.count > 64 else { return kind }
    var result = String.UnicodeScalarView()
    var bytes = 0
    for scalar in kind.unicodeScalars {
        let size = String(scalar).utf8.count
        guard bytes + size <= 64 else { break }
        bytes += size
        result.append(scalar)
    }
    return String(result)
}

/// A goodbye with a reason this build does not know (from a newer peer) is still a goodbye.
/// It maps to `.receiverStopping`, which only triggers an ordinary reconnect: it never deletes
/// a pairing or waits for the user.
private func decodeGoodbyeReason(_ c: KeyedDecodingContainer<WireKey>) throws -> GoodbyeReason {
    GoodbyeReason(rawValue: try c.decode(String.self, forKey: .reason)) ?? .receiverStopping
}

/// Runs a body decoder, turning missing or mistyped fields into invalidEvent.
private func decodingBody<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as ProtocolError {
        throw error
    } catch {
        throw ProtocolError.invalidEvent
    }
}

private struct PadFrame: Codable {
    let message: PadMessage

    init(message: PadMessage) { self.message = message }

    init(from decoder: Decoder) throws {
        let c = try wireContainer(decoder)
        guard let kind = try readKind(c) else {
            let version: Int
            do { version = try c.decode(Int.self, forKey: .version) } catch { throw ProtocolError.invalidFrame }
            guard version == 1 else { throw ProtocolError.unsupportedVersion }
            message = .legacy(try decodingBody { try c.decode(InputEvent.self, forKey: .event) })
            try message.validate()
            return
        }
        message = try decodingBody { try Self.body(kind: kind, c) }
        try message.validate()
    }

    private static func body(kind: String, _ c: KeyedDecodingContainer<WireKey>) throws -> PadMessage {
        guard let known = PadKind(rawValue: kind) else { return .unknown(truncatedKind(kind)) }
        func t() throws -> Int64 { try c.decode(Int64.self, forKey: .t) }
        func double(_ key: WireKey) throws -> Double { try c.decode(Double.self, forKey: key) }
        switch known {
        case .hello:
            return .hello(Hello(proto: try c.decode(Int.self, forKey: .proto),
                                client: try c.decode(UUID.self, forKey: .client),
                                app: try c.decode(String.self, forKey: .app),
                                device: try c.decode(String.self, forKey: .device),
                                features: try c.decode([String].self, forKey: .features)))
        case .key:
            return .input(.key(code: try c.decode(UInt16.self, forKey: .code),
                               down: try c.decode(Bool.self, forKey: .down)), t: try t())
        case .button:
            return .input(.button(button: try c.decode(PointerButton.self, forKey: .button),
                                  down: try c.decode(Bool.self, forKey: .down),
                                  clickState: try c.decode(Int.self, forKey: .cs)), t: try t())
        case .motion:
            return .input(.motion(PointerMotion(dx: try double(.dx), dy: try double(.dy),
                                                dt: try double(.dt), speed: try double(.sp))), t: try t())
        case .scroll:
            let scroll = ScrollMotion(phase: try c.decode(WireScrollPhase.self, forKey: .ph),
                                      dx: try double(.dx), dy: try double(.dy), dt: try double(.dt),
                                      speed: try double(.sp),
                                      releaseVX: try c.decodeIfPresent(Double.self, forKey: .vx),
                                      releaseVY: try c.decodeIfPresent(Double.self, forKey: .vy))
            return .input(.scroll(scroll), t: try t())
        case .contacts:
            return .input(.contacts(try c.decode(Int.self, forKey: .n)), t: try t())
        case .gesture:
            let gesture = WireGesture(kind: try c.decode(WireGestureKind.self, forKey: .kind),
                                      fingers: try c.decode(Int.self, forKey: .fingers),
                                      direction: try c.decodeIfPresent(String.self, forKey: .dir))
            return .input(.gesture(gesture), t: try t())
        case .releaseAll:
            return .input(.releaseAll, t: try t())
        case .hb:
            let hb = Heartbeat(seq: try c.decode(UInt32.self, forKey: .seq),
                               held: try c.decode([UInt16].self, forKey: .held),
                               buttons: try c.decode([PointerButton].self, forKey: .buttons),
                               active: try c.decode(Bool.self, forKey: .active))
            return .heartbeat(hb, t: try t())
        case .ping:
            return .ping(id: try c.decode(UInt32.self, forKey: .id), t: try t())
        case .bye:
            return .goodbye(try decodeGoodbyeReason(c))
        }
    }

    func encode(to encoder: Encoder) throws {
        try message.validate()
        var c = encoder.container(keyedBy: WireKey.self)
        try c.encode(WireV2.version, forKey: .v)
        func kind(_ k: PadKind) throws { try c.encode(k.rawValue, forKey: .m) }
        switch message {
        case .hello(let h):
            try kind(.hello)
            try c.encode(h.proto, forKey: .proto)
            try c.encode(h.client, forKey: .client)
            try c.encode(h.app, forKey: .app)
            try c.encode(h.device, forKey: .device)
            try c.encode(h.features, forKey: .features)
        case .input(let input, let t):
            try c.encode(t, forKey: .t)
            switch input {
            case .key(let code, let down):
                try kind(.key)
                try c.encode(code, forKey: .code)
                try c.encode(down, forKey: .down)
            case .button(let button, let down, let clickState):
                try kind(.button)
                try c.encode(button, forKey: .button)
                try c.encode(down, forKey: .down)
                try c.encode(clickState, forKey: .cs)
            case .motion(let m):
                try kind(.motion)
                try c.encode(m.dx, forKey: .dx)
                try c.encode(m.dy, forKey: .dy)
                try c.encode(m.dt, forKey: .dt)
                try c.encode(m.speed, forKey: .sp)
            case .scroll(let s):
                try kind(.scroll)
                try c.encode(s.phase, forKey: .ph)
                try c.encode(s.dx, forKey: .dx)
                try c.encode(s.dy, forKey: .dy)
                try c.encode(s.dt, forKey: .dt)
                try c.encode(s.speed, forKey: .sp)
                try c.encodeIfPresent(s.releaseVX, forKey: .vx)
                try c.encodeIfPresent(s.releaseVY, forKey: .vy)
            case .contacts(let n):
                try kind(.contacts)
                try c.encode(n, forKey: .n)
            case .gesture(let g):
                try kind(.gesture)
                try c.encode(g.kind, forKey: .kind)
                try c.encode(g.fingers, forKey: .fingers)
                try c.encodeIfPresent(g.direction, forKey: .dir)
            case .releaseAll:
                try kind(.releaseAll)
            }
        case .heartbeat(let hb, let t):
            try kind(.hb)
            try c.encode(t, forKey: .t)
            try c.encode(hb.seq, forKey: .seq)
            try c.encode(hb.held, forKey: .held)
            try c.encode(hb.buttons, forKey: .buttons)
            try c.encode(hb.active, forKey: .active)
        case .ping(let id, let t):
            try kind(.ping)
            try c.encode(t, forKey: .t)
            try c.encode(id, forKey: .id)
        case .goodbye(let reason):
            try kind(.bye)
            try c.encode(reason, forKey: .reason)
        case .legacy, .unknown:
            // .legacy is framed by WireCodec; unknown kinds are receive-only.
            throw ProtocolError.invalidEvent
        }
    }
}

private struct MacFrame: Codable {
    let message: MacMessage

    init(message: MacMessage) { self.message = message }

    init(from decoder: Decoder) throws {
        let c = try wireContainer(decoder)
        guard let kind = try readKind(c) else { throw ProtocolError.unsupportedVersion }
        message = try decodingBody { try Self.body(kind: kind, c) }
        try message.validate()
    }

    private static func body(kind: String, _ c: KeyedDecodingContainer<WireKey>) throws -> MacMessage {
        guard let known = MacKind(rawValue: kind) else { return .unknown(truncatedKind(kind)) }
        switch known {
        case .welcome:
            return .welcome(Welcome(proto: try c.decode(Int.self, forKey: .proto),
                                    mac: try c.decode(UUID.self, forKey: .mac),
                                    name: try c.decode(String.self, forKey: .name),
                                    model: try c.decode(String.self, forKey: .model),
                                    // A layout this build does not know is drawn as ANSI.
                                    keyboard: KeyboardKind(rawValue: try c.decode(String.self, forKey: .keyboard)) ?? .ansi,
                                    displayMM: try c.decodeIfPresent([Double].self, forKey: .displayMM),
                                    prefs: try c.decode(MacInputPreferences.self, forKey: .prefs),
                                    caps: try c.decode(Bool.self, forKey: .caps),
                                    features: try c.decode([String].self, forKey: .features)))
        case .state:
            return .state(MacState(caps: try c.decodeIfPresent(Bool.self, forKey: .caps),
                                   prefs: try c.decodeIfPresent(MacInputPreferences.self, forKey: .prefs),
                                   displayAsleep: try c.decodeIfPresent(Bool.self, forKey: .asleep)))
        case .pong:
            return .pong(id: try c.decode(UInt32.self, forKey: .id),
                         echoT: try c.decode(Int64.self, forKey: .echo),
                         macT: try c.decode(Int64.self, forKey: .macT))
        case .bye:
            return .goodbye(try decodeGoodbyeReason(c))
        }
    }

    func encode(to encoder: Encoder) throws {
        try message.validate()
        var c = encoder.container(keyedBy: WireKey.self)
        try c.encode(WireV2.version, forKey: .v)
        func kind(_ k: MacKind) throws { try c.encode(k.rawValue, forKey: .m) }
        switch message {
        case .welcome(let w):
            try kind(.welcome)
            try c.encode(w.proto, forKey: .proto)
            try c.encode(w.mac, forKey: .mac)
            try c.encode(w.name, forKey: .name)
            try c.encode(w.model, forKey: .model)
            try c.encode(w.keyboard, forKey: .keyboard)
            try c.encodeIfPresent(w.displayMM, forKey: .displayMM)
            try c.encode(w.prefs, forKey: .prefs)
            try c.encode(w.caps, forKey: .caps)
            try c.encode(w.features, forKey: .features)
        case .state(let s):
            try kind(.state)
            try c.encodeIfPresent(s.caps, forKey: .caps)
            try c.encodeIfPresent(s.prefs, forKey: .prefs)
            try c.encodeIfPresent(s.displayAsleep, forKey: .asleep)
        case .pong(let id, let echoT, let macT):
            try kind(.pong)
            try c.encode(id, forKey: .id)
            try c.encode(echoT, forKey: .echo)
            try c.encode(macT, forKey: .macT)
        case .goodbye(let reason):
            try kind(.bye)
            try c.encode(reason, forKey: .reason)
        case .unknown:
            throw ProtocolError.invalidEvent // receive-only
        }
    }
}
