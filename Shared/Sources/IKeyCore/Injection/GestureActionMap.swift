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

    /// Symbolic hot key id of Mission Control (Ctrl+Up by default; it toggles).
    public static let missionControlHotKey = HotKeyID.missionControl

    /// While Mission Control is taken to be open (this soon after it opened, with no key press
    /// or click since), a swipe up keeps it open and a swipe down closes it.
    private static let missionControlCloseWindow: TimeInterval = 15
    private static let lookUpFingers = 3

    private let swipeFingers: Int
    private let appExposeEnabled: Bool
    private let lookUpTap: Bool
    /// When Mission Control was last opened (by a swipe up or the Mission Control key), while
    /// nothing that may have closed it followed.
    private var missionControlOpenedAt: TimeInterval?

    /// `swipeFingers` is the Mac's own swipe finger count (four while its three-finger drag is
    /// on). A swipe with more fingers counts too, so an iPad set to three-finger drag on its own
    /// (not following the Mac), which swipes with four fingers, still reaches the Mac's swipes on
    /// a Mac without three-finger drag. Fewer fingers never count: on a Mac with three-finger
    /// drag, three fingers drag.
    public init(swipeFingers: Int = 3, appExposeEnabled: Bool = true, lookUpTap: Bool = true) {
        self.swipeFingers = swipeFingers
        self.appExposeEnabled = appExposeEnabled
        self.lookUpTap = lookUpTap
    }

    public mutating func handle(_ g: GestureInput, at now: TimeInterval) -> [GestureAction] {
        let actions = actions(for: g, at: now)
        switch g {
        case let .swipe(fingers, direction) where fingers >= swipeFingers:
            switch direction {
            case .up:
                // Opened now, or already open and kept open (the window restarts).
                missionControlOpenedAt = now
            case .down:
                // Closed Mission Control, or opened App Exposé.
                if !actions.isEmpty { missionControlOpenedAt = nil }
            case .left, .right:
                // Switching Spaces inside Mission Control keeps it open.
                break
            }
        case .swipe:
            break
        case .tap:
            if !actions.isEmpty { missionControlOpenedAt = nil }
        }
        return actions
    }

    private func actions(for g: GestureInput, at now: TimeInterval) -> [GestureAction] {
        switch g {
        case let .swipe(fingers, direction):
            guard fingers >= swipeFingers else { return [] }
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

    /// A key press or a click, either of which may dismiss Mission Control (Escape, Return, a
    /// click on a window or the desktop), so the next swipe down is App Exposé again and the next
    /// swipe up opens Mission Control. Pointer motion and scrolling cannot close Mission Control
    /// and must not be reported here: on a MacBook, swipe up, hover over the windows, swipe down
    /// closes it.
    public mutating func noteOtherInput(at now: TimeInterval) {
        if let t = missionControlOpenedAt, now >= t { missionControlOpenedAt = nil }
    }

    /// The Mission Control key (F3) or another posted Mission Control toggle: it opens Mission
    /// Control, or closes it while it is taken to be open.
    public mutating func noteMissionControlToggled(at now: TimeInterval) {
        missionControlOpenedAt = isMissionControlOpen(at: now) ? nil : now
    }
}
