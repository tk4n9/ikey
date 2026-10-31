import Foundation

public struct PairingSecret: Equatable, Sendable {
    public let bytes: Data
    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    public init(hex: String) throws {
        let text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(text.utf8)
        guard chars.count == 64 else { throw PairingError.invalidSecret }
        func nibble(_ value: UInt8) -> UInt8? {
            switch value {
            case 48...57: return value - 48
            case 65...70: return value - 65 + 10
            case 97...102: return value - 97 + 10
            default: return nil
            }
        }
        var bytes = Data()
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let high = nibble(chars[i]), let low = nibble(chars[i + 1]) else {
                throw PairingError.invalidSecret
            }
            bytes.append(high * 16 + low)
        }
        self.bytes = bytes
    }

    private init(bytes: Data) { self.bytes = bytes }
    public static func generate() -> PairingSecret {
        var generator = SystemRandomNumberGenerator()
        return PairingSecret(bytes: Data((0..<32).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }))
    }
}

public enum PairingError: Error { case invalidSecret }
public enum IKeyService { public static let bonjourType = "_ikey._tcp" }
