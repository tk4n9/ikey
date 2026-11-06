import Foundation

/// How the Caps Lock key behaves on the Mac.
public enum CapsMode: String, Codable, Sendable {
    /// Real system lock state with the hardware activation delay.
    case system
    /// iKey-only lock reflected in event flags (fallback when the system state cannot be set).
    case virtual
    /// A tap selects the previous input source; a hold toggles Caps Lock.
    case switchesInputSource
}

/// Caps Lock press semantics that IOHIDKeyboardFilter applies to real keys but posted events bypass.
public struct CapsLockController: Sendable {
    /// Changing the mode drops any press in flight and the virtual lock.
    public var mode: CapsMode {
        didSet { if mode != oldValue { reset() } }
    }
    /// Minimum hold that turns the system lock on (.system).
    var delay: TimeInterval
    /// Hold that turns a tap into a Caps Lock toggle (.switchesInputSource).
    var switchHold: TimeInterval
    public private(set) var virtualOn = false

    private struct Press: Sendable {
        var downAt: TimeInterval
        var senderDown: TimeInterval?
        /// When the press resolves by holding; nil once resolved.
        var deadline: TimeInterval?
    }
    private var press: Press?

    /// Symbolic hot key id of 'Select the previous input source'.
    private static let previousInputSourceHotKey = 60

    public init(delay: TimeInterval = 0.075, mode: CapsMode = .system, switchHold: TimeInterval = 0.5) {
        self.delay = delay
        self.mode = mode
        self.switchHold = switchHold
    }

    public var nextDeadline: TimeInterval? { press?.deadline }

    public mutating func down(senderTime: TimeInterval?, at now: TimeInterval, isOn: Bool) -> [KeyboardAction] {
        guard press == nil else { return [] }
        var p = Press(downAt: now, senderDown: senderTime, deadline: nil)
        defer { press = p }
        switch mode {
        case .system:
            if isOn { return [.setCapsLock(false)] }
            if effectiveDelay <= 0 { return [.setCapsLock(true)] }
            p.deadline = now + effectiveDelay
            return []
        case .virtual:
            virtualOn.toggle()
            return [.flagsChanged(code: MacKeyCode.capsLock, flags: virtualOn ? [.nonCoalesced, .alphaShift] : .nonCoalesced)]
        case .switchesInputSource:
            p.deadline = now + effectiveSwitchHold
            return []
        }
    }

    /// A press still pending at its up resolves by the sender's own down-to-up duration when both
    /// sender times are known (a short press stretched by network delay stays short); without them
    /// it resolves by the Mac clock. A deadline already fired by `advance` has resolved the press.
    public mutating func up(senderTime: TimeInterval?, at now: TimeInterval, isOn: Bool) -> [KeyboardAction] {
        guard let p = press else { return [] }
        press = nil
        guard let deadline = p.deadline else { return [] }
        let held: Bool
        if let s0 = p.senderDown, let s1 = senderTime {
            held = s1 - s0 >= (mode == .system ? effectiveDelay : effectiveSwitchHold)
        } else {
            held = now >= deadline
        }
        switch mode {
        case .system:
            return held ? [.setCapsLock(true)] : []
        case .switchesInputSource:
            return held ? [.setCapsLock(!isOn)] : [.symbolicHotKey(Self.previousInputSourceHotKey)]
        case .virtual:
            return []
        }
    }

    public mutating func advance(to now: TimeInterval, isOn: Bool) -> [KeyboardAction] {
        guard let deadline = press?.deadline, now >= deadline else { return [] }
        press?.deadline = nil
        switch mode {
        case .system: return [.setCapsLock(true)]
        case .switchesInputSource: return [.setCapsLock(!isOn)]
        case .virtual: return []
        }
    }

    /// Non-finite thresholds (a corrupt preference) fall back to the defaults so deadlines stay finite.
    private var effectiveDelay: TimeInterval { delay.isFinite ? delay : 0.075 }
    private var effectiveSwitchHold: TimeInterval { switchHold.isFinite ? switchHold : 0.5 }

    public mutating func reset() {
        press = nil
        virtualOn = false
    }
}
