import Foundation

/// The top-row strategies the user confirmed in the Mac's 'Check Top-Row Keys' window, stored as
/// JSON in UserDefaults under `storageKey`. A function without a choice uses its default chain
/// (`TopRowDefaults.chain(for:)`, most faithful strategy first).
public struct TopRowChoices: Codable, Equatable, Sendable {
    /// `TopRowFunction.rawValue` → `TopRowStrategy.id`.
    public var choices: [String: String] = [:]

    public static let storageKey = "iKey.topRow.v1"

    public init() {}

    /// The stored choices that name a known function and a strategy of that function's default
    /// chain (matched by `id`). Anything else (an unknown function, a malformed id, a strategy no
    /// longer in the chain) is ignored, so the function falls back to its chain.
    public func strategies() -> [TopRowFunction: TopRowStrategy] {
        var result: [TopRowFunction: TopRowStrategy] = [:]
        for (name, id) in choices {
            guard let function = TopRowFunction(rawValue: name),
                  let strategy = TopRowDefaults.chain(for: function).first(where: { $0.id == id }) else { continue }
            result[function] = strategy
        }
        return result
    }

    /// Records `s` as the confirmed strategy for `f`, replacing any earlier choice.
    public mutating func set(_ f: TopRowFunction, _ s: TopRowStrategy) {
        choices[f.rawValue] = s.id
    }
}
