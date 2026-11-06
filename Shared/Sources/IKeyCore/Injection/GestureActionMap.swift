import Foundation

public enum GestureDirection: String, Sendable { case up, down, left, right }

public enum GestureInput: Equatable, Sendable {
    case swipe(fingers: Int, direction: GestureDirection)
    case tap(fingers: Int)
}

/// What the Mac should do for a gesture: a symbolic hot key id (resolved through
/// `SymbolicHotKeys`) or an explicit shortcut.
public enum GestureAction: Equatable, Sendable {
    case hotKey(Int)
    case shortcut(keyCode: UInt16, modifierMask: UInt64)
}

/// Maps multi-finger swipes and taps to the public shortcuts macOS binds to the
/// same trackpad gestures (Spaces, Mission Control, App Exposé, Look Up).
public struct GestureActionMap: Sendable {
    private enum HotKeyID {
        static let missionControl = 32, applicationWindows = 33, lookUp = 70
        static let spaceLeft = 79, spaceRight = 81
    }

    /// While Mission Control is taken to be open (this soon after a swipe up, with no
    /// other input since), a swipe up keeps it open and a swipe down closes it.
    private static let missionControlCloseWindow: TimeInterval = 15
    private static let lookUpFingers = 3

    private let swipeFingers: Int
    private let appExposeEnabled: Bool
    private let lookUpTap: Bool
    /// When Mission Control was last opened, while no other action or input followed.
    private var missionControlOpenedAt: TimeInterval?

    public init(swipeFingers: Int = 3, appExposeEnabled: Bool = true, lookUpTap: Bool = true) {
        self.swipeFingers = swipeFingers
        self.appExposeEnabled = appExposeEnabled
        self.lookUpTap = lookUpTap
    }

    public mutating func handle(_ g: GestureInput, at now: TimeInterval) -> [GestureAction] {
        let isUp = g == .swipe(fingers: swipeFingers, direction: .up)
        let actions = actions(for: g, at: now)
        if isUp {
            // Opened now, or already open and kept open (the window restarts).
            missionControlOpenedAt = now
        } else if !actions.isEmpty {
            missionControlOpenedAt = nil
        }
        return actions
    }

    private func actions(for g: GestureInput, at now: TimeInterval) -> [GestureAction] {
        switch g {
        case let .swipe(fingers, direction):
            guard fingers == swipeFingers else { return [] }
            switch direction {
            // Content follows the fingers: swiping left reveals the Space to the right.
            case .left: return [.hotKey(HotKeyID.spaceRight)]
            case .right: return [.hotKey(HotKeyID.spaceLeft)]
            case .up:
                // Ctrl+Up toggles; a real pad keeps Mission Control open on a second swipe up.
                return isMissionControlOpen(at: now) ? [] : [.hotKey(HotKeyID.missionControl)]
            case .down:
                // Ctrl+Up toggles, so a swipe down soon after opening closes Mission Control.
                if isMissionControlOpen(at: now) { return [.hotKey(HotKeyID.missionControl)] }
                return appExposeEnabled ? [.hotKey(HotKeyID.applicationWindows)] : []
            }
        case let .tap(fingers):
            guard fingers == Self.lookUpFingers, lookUpTap else { return [] }
            return [.hotKey(HotKeyID.lookUp)]
        }
    }

    private func isMissionControlOpen(at now: TimeInterval) -> Bool {
        guard let t = missionControlOpenedAt else { return false }
        return now >= t && now - t < Self.missionControlCloseWindow
    }

    /// Any other pad input (keys, clicks, pointer motion) means Mission Control may
    /// have been dismissed some other way, so the next swipe down is App Exposé again.
    public mutating func noteOtherInput(at now: TimeInterval) {
        if let t = missionControlOpenedAt, now >= t { missionControlOpenedAt = nil }
    }
}
