import Foundation

public enum PointerButton: String, Codable, Sendable { case left, right }

/// Physical macOS virtual keycodes preserve shortcuts and the Mac's input source.
public enum InputEvent: Codable, Equatable, Sendable {
    case key(code: UInt16, down: Bool)
    case pointer(dx: Double, dy: Double)
    case button(button: PointerButton, down: Bool)
    case scroll(dx: Double, dy: Double)
    case releaseAll
    case heartbeat

    public static let supportedKeyCodes: Set<UInt16> = Set(UInt16(0)...UInt16(50)).union([
        51, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
        65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92,
        96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 114,
        115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126
    ])

    public func validate() throws {
        switch self {
        case .key(let code, _):
            guard Self.supportedKeyCodes.contains(code) else { throw ProtocolError.invalidEvent }
        case .pointer(let dx, let dy), .scroll(let dx, let dy):
            guard dx.isFinite, dy.isFinite, abs(dx) <= 4096, abs(dy) <= 4096 else {
                throw ProtocolError.invalidEvent
            }
        case .button, .releaseAll, .heartbeat: break
        }
    }
}

public enum ProtocolError: Error, Equatable {
    case unsupportedVersion, invalidEvent, frameTooLarge, invalidFrame
}

public enum WireCodec {
    public static let maxFrameBytes = 8192
    private struct Envelope: Codable { var version: Int; var event: InputEvent }

    public static func encode(_ event: InputEvent) throws -> Data {
        try event.validate()
        var data = try JSONEncoder().encode(Envelope(version: 1, event: event))
        guard data.count <= maxFrameBytes else { throw ProtocolError.frameTooLarge }
        data.append(0x0a)
        return data
    }

    public static func decode(_ frame: Data) throws -> InputEvent {
        guard !frame.isEmpty, frame.count <= maxFrameBytes else {
            throw frame.isEmpty ? ProtocolError.invalidFrame : ProtocolError.frameTooLarge
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: frame)
        guard envelope.version == 1 else { throw ProtocolError.unsupportedVersion }
        try envelope.event.validate()
        return envelope.event
    }
}

/// TCP may split a frame anywhere or deliver several frames together.
public struct LineDecoder {
    private var pending = Data()
    public init() {}

    public mutating func append(_ data: Data) throws -> [InputEvent] {
        var events: [InputEvent] = []
        for byte in data {
            if byte == 0x0a {
                let event = try WireCodec.decode(pending)
                pending.removeAll(keepingCapacity: true)
                events.append(event)
            } else {
                guard pending.count < WireCodec.maxFrameBytes else {
                    pending.removeAll(keepingCapacity: false)
                    throw ProtocolError.frameTooLarge
                }
                pending.append(byte)
            }
        }
        return events
    }
}
