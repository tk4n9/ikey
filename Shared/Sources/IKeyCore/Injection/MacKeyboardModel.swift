import Foundation

/// What a lone Globe/fn tap does.
public enum FnTapAction: String, Codable, CaseIterable, Sendable {
    case none, changeInputSource, emojiAndSymbols
}

/// One thing the injector must post or do for a keyboard input.
public enum KeyboardAction: Equatable, Sendable {
    case key(code: UInt16, down: Bool, flags: ModifierFlags, autorepeat: Bool)
    case flagsChanged(code: UInt16, flags: ModifierFlags)
    case topRow(TopRowFunction, down: Bool, autorepeat: Bool, flags: ModifierFlags)
    case setCapsLock(Bool)
    case symbolicHotKey(Int)                                // posted as a chord by InjectorCore
    case shortcut(keyCode: UInt16, modifierMask: UInt64)
}

public struct MacKeyboardConfig: Equatable, Sendable {
    /// macOS 'Use F1, F2, etc. keys as standard function keys' (fnState).
    public var fnKeysStandard = false
    /// Seconds before the first repeat; nil or > 2 s turns repeat off.
    public var repeatDelay: Double? = 0.5
    public var repeatInterval: Double = 0.083
    /// Repeats fire only while a frame from the iPad arrived within this many seconds.
    public var lease: Double = 0.25
    public var capsMode: CapsMode = .system
    public var capsDelay: Double = 0.075
    public var capsSwitchHold: Double = 0.5
    public var fnTapAction: FnTapAction = .none
    /// Longest fn press that still counts as a tap.
    public var fnTapMax: Double = 0.5

    public init() {}

    public init(fnKeysStandard: Bool = false, repeatDelay: Double? = 0.5, repeatInterval: Double = 0.083,
                lease: Double = 0.25, capsMode: CapsMode = .system, capsDelay: Double = 0.075,
                capsSwitchHold: Double = 0.5, fnTapAction: FnTapAction = .none, fnTapMax: Double = 0.5) {
        self.fnKeysStandard = fnKeysStandard
        self.repeatDelay = repeatDelay
        self.repeatInterval = repeatInterval
        self.lease = lease
        self.capsMode = capsMode
        self.capsDelay = capsDelay
        self.capsSwitchHold = capsSwitchHold
        self.fnTapAction = fnTapAction
        self.fnTapMax = fnTapMax
    }
}

/// The Mac-side keyboard semantics posted CGEvents skip: implicit and sided flags, the fn
/// layer, the top-row layer, key repeat with a liveness lease, Caps Lock and the fn tap.
/// Times are Mac-clock seconds; `senderTime` is the iPad's own timestamp for the same event.
public struct MacKeyboardModel: Sendable {
    public var config: MacKeyboardConfig {
        didSet {
            syncCaps()
            rescheduleRepeatInterval()
        }
    }

    /// What a held physical key produced at its down; its up and repeats reuse it.
    private enum Output: Equatable, Sendable {
        case key(UInt16)
        case topRow(TopRowFunction)
        case modifier
        case capsLock
    }

    private struct RepeatSlot: Sendable {
        var physical: UInt16
        var output: Output
        /// Repeat n fires at anchor + n * interval.
        var anchor: TimeInterval
        var count: Int
        /// The clamped interval this schedule was built with.
        var interval: TimeInterval
        /// When the last repeat fired (or the frame that resumed a paused slot); nil before the
        /// first repeat. An interval change counts the next repeat from here.
        var lastFire: TimeInterval?
        var paused: Bool
    }

    private struct FnTap: Sendable {
        var downAt: TimeInterval
        var senderDown: TimeInterval?
    }

    private static let fnLayer: [UInt16: UInt16] = [
        123: 115, // Left → Home
        124: 119, // Right → End
        126: 116, // Up → Page Up
        125: 121, // Down → Page Down
        51: 117,  // Delete → Forward Delete
        36: 76    // Return → keypad Enter
    ]

    private var caps: CapsLockController
    private var held: [UInt16: Output] = [:]
    private var repeatSlot: RepeatSlot?
    private var lastFrame: TimeInterval = -.infinity
    private var fnTap: FnTap?

    public init(config: MacKeyboardConfig = .init()) {
        self.config = config
        caps = CapsLockController(delay: config.capsDelay, mode: config.capsMode, switchHold: config.capsSwitchHold)
    }

    public var heldPhysicalCodes: Set<UInt16> { Set(held.keys) }

    public var nextDeadline: TimeInterval? {
        let repeatAt = repeatSlot.flatMap { $0.paused ? nil : nextFire($0) }
        let deadlines = [caps.nextDeadline, repeatAt].compactMap { $0 }.filter(\.isFinite)
        return deadlines.min()
    }

    public func currentFlags(capsLockOn: Bool) -> ModifierFlags {
        var flags: ModifierFlags = .nonCoalesced
        for (code, output) in held where output == .modifier {
            flags.formUnion(MacKeyCode.modifierFlags(for: code) ?? [])
        }
        if caps.mode == .virtual ? caps.virtualOn : capsLockOn { flags.insert(.alphaShift) }
        return flags
    }

    public mutating func key(_ code: UInt16, down: Bool, senderTime: TimeInterval?, at now: TimeInterval,
                             capsLockOn: Bool) -> [KeyboardAction] {
        frameReceived(at: now)
        return down ? keyDown(code, senderTime: senderTime, at: now, capsLockOn: capsLockOn)
                    : keyUp(code, senderTime: senderTime, at: now, capsLockOn: capsLockOn)
    }

    /// Any frame from the iPad renews the repeat lease; a paused repeat resumes one interval later.
    public mutating func frameReceived(at now: TimeInterval) {
        lastFrame = max(lastFrame, now)
        guard var slot = repeatSlot, slot.paused else { return }
        slot.paused = false
        slot.interval = repeatInterval
        slot.anchor = now + slot.interval
        slot.count = 0
        slot.lastFire = now
        repeatSlot = slot
    }

    /// Fires due Caps Lock deadlines and at most one repeat (a late call skips missed repeats).
    public mutating func advance(to now: TimeInterval, capsLockOn: Bool) -> [KeyboardAction] {
        var actions = withCurrentFlags(caps.advance(to: now, isOn: capsLockOn), capsLockOn: capsLockOn)
        guard var slot = repeatSlot, !slot.paused, now >= nextFire(slot) else { return actions }
        guard repeatDelay != nil else {
            repeatSlot = nil
            return actions
        }
        if now - lastFrame <= lease {
            actions.append(action(for: slot.output, down: true, autorepeat: true, capsLockOn: capsLockOn))
            slot = Self.skippingPast(now, slot)
            slot.lastFire = now
        } else {
            slot.paused = true
        }
        repeatSlot = slot
        return actions
    }

    /// Releases everything held: non-modifier keys (by emitted code), top-row actions, then
    /// modifiers, each ascending; a virtual Caps Lock is turned off last.
    public mutating func releaseAll(capsLockOn: Bool) -> [KeyboardAction] {
        var actions: [KeyboardAction] = []
        let keys = held.values.compactMap { output -> UInt16? in
            if case .key(let code) = output { return code }
            return nil
        }
        for code in keys.sorted() {
            actions.append(action(for: .key(code), down: false, autorepeat: false, capsLockOn: capsLockOn))
        }
        let functions = held.values.compactMap { output -> TopRowFunction? in
            if case .topRow(let f) = output { return f }
            return nil
        }
        let order = TopRowFunction.allCases
        for f in functions.sorted(by: { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }) {
            actions.append(action(for: .topRow(f), down: false, autorepeat: false, capsLockOn: capsLockOn))
        }
        held = held.filter { $0.value == .modifier }
        for code in held.keys.sorted() {
            held[code] = nil
            actions.append(.flagsChanged(code: code, flags: currentFlags(capsLockOn: capsLockOn)))
        }
        let virtualWasOn = caps.mode == .virtual && caps.virtualOn
        held = [:]
        repeatSlot = nil
        fnTap = nil
        caps.reset()
        if virtualWasOn {
            actions.append(.flagsChanged(code: MacKeyCode.capsLock, flags: currentFlags(capsLockOn: capsLockOn)))
        }
        return actions
    }

    // MARK: - Private

    private mutating func keyDown(_ code: UInt16, senderTime: TimeInterval?, at now: TimeInterval,
                                  capsLockOn: Bool) -> [KeyboardAction] {
        guard held[code] == nil else { return [] }
        if code != MacKeyCode.fn { fnTap = nil }

        if code == MacKeyCode.capsLock {
            held[code] = .capsLock
            let actions = caps.down(senderTime: senderTime, at: now, isOn: capsLockOn)
            return withCurrentFlags(actions, capsLockOn: capsLockOn)
        }
        if MacKeyCode.modifiers.contains(code) {
            held[code] = .modifier
            if code == MacKeyCode.fn { fnTap = FnTap(downAt: now, senderDown: senderTime) }
            return [.flagsChanged(code: code, flags: currentFlags(capsLockOn: capsLockOn))]
        }

        let fnHeld = held[MacKeyCode.fn] != nil
        let output: Output
        if let f = TopRowFunction.forPhysicalCode(code), config.fnKeysStandard == fnHeld {
            output = .topRow(f)
        } else {
            output = .key(fnHeld ? Self.fnLayer[code] ?? code : code)
        }
        held[code] = output
        if let delay = repeatDelay, Self.repeats(output) {
            repeatSlot = RepeatSlot(physical: code, output: output, anchor: now + delay, count: 0,
                                    interval: repeatInterval, lastFire: nil, paused: false)
        }
        return [action(for: output, down: true, autorepeat: false, capsLockOn: capsLockOn)]
    }

    private mutating func keyUp(_ code: UInt16, senderTime: TimeInterval?, at now: TimeInterval,
                                capsLockOn: Bool) -> [KeyboardAction] {
        guard let output = held.removeValue(forKey: code) else { return [] }
        switch output {
        case .capsLock:
            fnTap = nil
            let actions = caps.up(senderTime: senderTime, at: now, isOn: capsLockOn)
            return withCurrentFlags(actions, capsLockOn: capsLockOn)
        case .modifier:
            var actions: [KeyboardAction] = [.flagsChanged(code: code, flags: currentFlags(capsLockOn: capsLockOn))]
            if code == MacKeyCode.fn, let tap = fnTap {
                let duration: TimeInterval
                if let s0 = tap.senderDown, let s1 = senderTime { duration = s1 - s0 } else { duration = now - tap.downAt }
                if duration <= (config.fnTapMax.isFinite ? config.fnTapMax : 0.5) { actions += fnTapActions }
            }
            fnTap = nil
            return actions
        case .key, .topRow:
            fnTap = nil
            if repeatSlot?.physical == code { repeatSlot = nil }
            return [action(for: output, down: false, autorepeat: false, capsLockOn: capsLockOn)]
        }
    }

    private var fnTapActions: [KeyboardAction] {
        switch config.fnTapAction {
        case .none: return []
        case .changeInputSource: return [.symbolicHotKey(60)]
        case .emojiAndSymbols: return [.shortcut(keyCode: 49, modifierMask: 0x140000)] // Ctrl+Cmd+Space
        }
    }

    /// Ordinary keys (incl. fn-translated and standard F-keys) and brightness/volume repeat;
    /// modifiers and Caps Lock never reach a repeat slot.
    private static func repeats(_ output: Output) -> Bool {
        switch output {
        case .key: return true
        case .topRow(let f): return f.repeats
        case .modifier, .capsLock: return false
        }
    }

    private func action(for output: Output, down: Bool, autorepeat: Bool, capsLockOn: Bool) -> KeyboardAction {
        let flags = currentFlags(capsLockOn: capsLockOn)
        switch output {
        case .key(let code):
            return .key(code: code, down: down, flags: flags.union(MacKeyCode.implicitFlags(for: code)), autorepeat: autorepeat)
        case .topRow(let f):
            return .topRow(f, down: down, autorepeat: autorepeat, flags: flags)
        case .modifier, .capsLock:
            preconditionFailure("modifiers and Caps Lock post flagsChanged")
        }
    }

    /// The caps controller does not know the held modifiers; give its flagsChanged the full flags.
    private func withCurrentFlags(_ actions: [KeyboardAction], capsLockOn: Bool) -> [KeyboardAction] {
        actions.map {
            if case .flagsChanged(let code, _) = $0 { return .flagsChanged(code: code, flags: currentFlags(capsLockOn: capsLockOn)) }
            return $0
        }
    }

    private var repeatDelay: Double? {
        guard let delay = config.repeatDelay, delay <= 2.0, !delay.isNaN else { return nil }
        return max(delay, 0.1)
    }

    /// Clamped to 0.015...2.0; NaN (a corrupt preference) falls back to the default.
    private var repeatInterval: Double {
        let interval = config.repeatInterval.isNaN ? 0.083 : config.repeatInterval
        return min(max(interval, 0.015), 2.0)
    }

    /// NaN falls back to the default; +infinity means repeats never pause.
    private var lease: Double { config.lease.isNaN ? 0.25 : config.lease }

    private func nextFire(_ slot: RepeatSlot) -> TimeInterval {
        slot.anchor + Double(slot.count) * slot.interval
    }

    /// The schedule after a repeat fired at `now`: the next repeat lands strictly after `now`
    /// (missed repeats are skipped, not burst) and stays on the original cadence when possible.
    private static func skippingPast(_ now: TimeInterval, _ slot: RepeatSlot) -> RepeatSlot {
        var s = slot
        let fire = { (s: RepeatSlot) in s.anchor + Double(s.count) * s.interval }
        s.count += 1
        guard fire(s) <= now else { return s }
        // Late call: move the anchor to the last missed slot (no Int conversion of the gap,
        // which could overflow), then step forward past `now` to absorb rounding.
        let missed = ((now - s.anchor) / s.interval).rounded(.down)
        if missed.isFinite, missed > 0 {
            s.anchor += missed * s.interval
            s.count = 0
        }
        for _ in 0..<4 where fire(s) <= now { s.count += 1 }
        if fire(s) <= now {
            s.anchor = now
            s.count = 1
        }
        return s
    }

    /// A changed interval takes effect from the last repeat, keeping a pending first repeat
    /// (down + delay) where it is, so a mid-hold settings change neither stalls nor bursts.
    /// A paused slot is rescheduled by the frame that resumes it.
    private mutating func rescheduleRepeatInterval() {
        guard var slot = repeatSlot, slot.interval != repeatInterval else { return }
        if !slot.paused, let lastFire = slot.lastFire {
            slot.anchor = lastFire + repeatInterval
            slot.count = 0
        }
        slot.interval = repeatInterval
        repeatSlot = slot
    }

    private mutating func syncCaps() {
        caps.mode = config.capsMode
        caps.delay = config.capsDelay
        caps.switchHold = config.capsSwitchHold
    }
}
