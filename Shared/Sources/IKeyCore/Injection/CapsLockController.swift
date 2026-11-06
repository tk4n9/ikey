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
    /// How long the finger was already down when the sender stamped a key's down: the iPad posts
    /// a confirmed key (Caps Lock among them) only after its confirmation delay, so its
    /// down-to-up gap is the finger's hold minus this. Added back when an up judges the hold by
    /// sender times, so the thresholds count from the touch, like the hardware key's from the press.
    var senderLead: TimeInterval
    public private(set) var virtualOn = false

    private struct Press: Sendable {
        var downAt: TimeInterval
        var senderDown: TimeInterval?
        /// When the press resolves by holding; nil once resolved.
        var deadline: TimeInterval?
        /// The sender posts this key's lone tap as a down and an up together at the lift.
        var tapAtLift: Bool
    }
    private var press: Press?

    /// Symbolic hot key id of 'Select the previous input source'.
    private static let previousInputSourceHotKey = 60

    public init(delay: TimeInterval = 0.075, mode: CapsMode = .system, switchHold: TimeInterval = 0.5,
                senderLead: TimeInterval = 0) {
        self.delay = delay
        self.mode = mode
        self.switchHold = switchHold
        self.senderLead = senderLead
    }

    public var nextDeadline: TimeInterval? { press?.deadline }

    /// `tapAtLift`: the key is one whose lone tap the sender posts as a down and an up together
    /// at its lift (a deck modifier remapped to Caps Lock, e.g. the user's left Command), so a
    /// zero sender gap says nothing about how long the finger was down. In `.system` such a tap
    /// counts as a full press, like the remapped hardware key's ordinary tap; in
    /// `.switchesInputSource` it stays a tap.
    public mutating func down(senderTime: TimeInterval?, at now: TimeInterval, isOn: Bool,
                              tapAtLift: Bool = false) -> [KeyboardAction] {
        guard press == nil else { return [] }
        var p = Press(downAt: now, senderDown: senderTime, deadline: nil, tapAtLift: tapAtLift)
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

    /// A press still pending at its up resolves by the sender's own down-to-up duration plus
    /// `senderLead` when both sender times are known (a short press stretched by network delay
    /// stays short, and the iPad's confirmation delay does not shorten it); without them it
    /// resolves by the Mac clock. A deadline already fired by `advance` has resolved the press.
    /// The Mac-clock deadline keeps the full threshold from the down's arrival, so network jitter
    /// cannot turn a short press into a hold; a hold judged at the up just resolves at the lift.
    public mutating func up(senderTime: TimeInterval?, at now: TimeInterval, isOn: Bool) -> [KeyboardAction] {
        guard let p = press else { return [] }
        press = nil
        guard let deadline = p.deadline else { return [] }
        let held: Bool
        if let s0 = p.senderDown, let s1 = senderTime {
            if p.tapAtLift, s1 == s0, mode == .system {
                held = true
            } else {
                held = s1 - s0 + effectiveSenderLead >= (mode == .system ? effectiveDelay : effectiveSwitchHold)
            }
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
    /// Within 0...0.25 s; a non-finite or negative lead counts as none.
    private var effectiveSenderLead: TimeInterval { senderLead.isFinite ? min(max(senderLead, 0), 0.25) : 0 }

    public mutating func reset() {
        press = nil
        virtualOn = false
    }
}
