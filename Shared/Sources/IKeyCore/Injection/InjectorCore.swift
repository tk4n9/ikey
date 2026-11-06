import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One thing the Mac EventInjector posts or does. Flags use CGEventFlags bits.
public enum SynthEvent: Equatable, Sendable {
    case key(code: UInt16, down: Bool, flags: ModifierFlags, autorepeat: Bool)
    case flagsChanged(code: UInt16, flags: ModifierFlags)
    /// NX_KEYTYPE_* system-defined key (brightness, volume, media).
    case aux(nxKeyType: Int, down: Bool, autorepeat: Bool, flags: ModifierFlags)
    case openApplication(path: String)
    /// Set the system Caps Lock state (verified by the poster).
    case setCapsLock(Bool)
    case mouseMove(to: CGPoint, deltaX: Int64, deltaY: Int64, drag: PointerButton?, flags: ModifierFlags)
    case mouseButton(PointerButton, down: Bool, at: CGPoint, clickState: Int64, flags: ModifierFlags)
    case scroll(ScrollFrame, flags: ModifierFlags)
    /// IOPMAssertionDeclareUserActivity: iKey input counts as the user being present.
    case declareUserActivity
    /// Switch to the previously selected keyboard input source, as a Caps Lock tap does with
    /// 'Use Caps Lock to switch to and from ABC/last used' and as a Globe tap set to 'Change
    /// Input Source' does. On a real Mac this works whether or not the 'Select the previous
    /// input source' shortcut (symbolic hot key 60) is enabled, and modifiers the user holds do
    /// not matter. The poster selects the source itself (TISSelectInputSource between the
    /// current and the previously selected keyboard source) and posts `fallback` only when it
    /// cannot; `fallback` is that shortcut's chord, empty when it is disabled or unassigned.
    case selectPreviousInputSource(fallback: [SynthEvent])
}

/// Everything the Mac side knows that shapes v2 injection.
public struct InjectorSettings: Equatable, Sendable {
    public var prefs: MacInputPreferences = .init()
    /// The user's top-row choices; a missing or unusable choice falls back to `TopRowDefaults`.
    public var topRowChoices: [TopRowFunction: TopRowStrategy] = [:]
    public var hotKeys: SymbolicHotKeys = .init(plist: nil)
    public var capsMode: CapsMode = .system
    public var fnTapAction: FnTapAction = .none
    /// Live IORegistry curves; nil uses the built-in tables.
    public var pointerCurves: [HIDAccelCurve]? = nil
    public var scrollCurves: [HIDAccelCurve]? = nil
    /// Live tracking index; nil uses `prefs.trackingIndex`.
    public var trackingIndexOverride: Double? = nil
    /// The trackpad's scrolling speed as its live scroll acceleration index (IOHID
    /// HIDTrackpadScrollAcceleration, set by Accessibility > Pointer Control > Trackpad Options >
    /// Scrolling speed); nil or invalid uses `ScrollSynthesizer.defaultScrollIndex`. Posted scroll
    /// events bypass the Mac's own scroll acceleration, so iKey applies it at this index.
    public var scrollIndexOverride: Double? = nil
    public var gainScale: Double = 1
    public var speedAxisScale: Double = 1
    public var scrollBasePtPerMM: Double = 5.0
    public var scrollSpeedFactor: Double = 1
    /// Release everything after this long without a frame while input is held. nil in
    /// production, where the ReceiverArbiter owns the dead-man.
    public var deadManTimeout: Double? = nil
    /// The Mac's own key remapping (hidutil, Modifier Keys, Karabiner), Mac virtual key code
    /// to key code. Posted events bypass it, so it is applied to every incoming key first.
    public var keyRemap: [UInt16: UInt16] = [:]
    /// How long after a key contact lands the iPad posts its down: DeckInputEngine's key
    /// confirmation delay with palm protection on (the default). Caps Lock holds judged by sender
    /// times add it back, so a quick tap that the hardware key would take turns Caps Lock on.
    /// 0 when the iPad confirms keys at once (palm protection off). Used until the iPad states
    /// its own value in a heartbeat (`Heartbeat.keyConfirmDelay`), which then wins.
    public var padKeyConfirmationDelay: Double = 0.045

    public init() {}
}

/// All v2 Mac input state and the HID-filter behaviour posted events skip: keyboard model,
/// top-row strategies, hot-key chords, accelerated pointer, phased scroll with momentum,
/// gestures, heartbeat reconciliation and user activity. Times are Mac-clock seconds.
public struct InjectorCore: Sendable {
    private static let userActivityInterval = 1.0
    /// Symbolic hot key id of 'Select the previous input source'.
    private static let previousInputSourceHotKey = 60
    /// The Mission Control key's code (kVK 160, what the F3 key posts by default; it toggles).
    private static let missionControlKeyCode: UInt16 = 160

    /// Chord modifiers in posting order: mask bit, the left-side key that posts it, its flags.
    private static let chordModifiers: [(mask: ModifierFlags, code: UInt16, flags: ModifierFlags)] = [
        (.control, 59, [.control, .leftControl]),
        (.option, 58, [.option, .leftOption]),
        (.shift, 56, [.shift, .leftShift]),
        (.command, 55, [.command, .leftCommand]),
        (.secondaryFn, MacKeyCode.fn, .secondaryFn),
    ]

    private var settings: InjectorSettings
    private var keyboard: MacKeyboardModel
    private var pointer: PointerAccelerator
    private var cursor = VirtualCursor()
    private var scroll: ScrollSynthesizer
    private var scrollCurvesInUse: [HIDAccelCurve]
    private var scrollIndexInUse: Double
    /// New scroll curves or a new scroll index wait until no scroll or momentum is in flight.
    private var scrollRebuildPending = false
    /// A scroll gesture (may-begin or scrolling) is open on the Mac, as shown by the phase of
    /// the last posted scroll frame.
    private var scrollOpen = false
    private var gestures: GestureActionMap
    private var swipeFingers: Int
    private var appExposeEnabled: Bool
    /// The Mac key code each held physical iPad key produced at its down (remap applied), so
    /// the up releases the same code even if the remap changed meanwhile.
    private var mappedDown: [UInt16: UInt16] = [:]
    /// The strategy each held top-row function used at its down; repeats and the up reuse it.
    private var topRowHeld: [TopRowFunction: TopRowStrategy] = [:]
    /// Held buttons and the click state of their down.
    private var buttons: [PointerButton: Int64] = [:]
    private var lastFrame: TimeInterval = -.infinity
    private var lastUserActivity: TimeInterval = -.infinity
    /// The iPad's key confirmation delay from its latest heartbeat; nil until one states it.
    private var padKeyLead: Double?
    /// Set by `synth` when a key posted a Mission Control toggle (the F3 key); the input or tick
    /// that caused it hands it to the gesture map.
    private var missionControlKeyPosted = false

    public init(settings: InjectorSettings = .init()) {
        self.settings = settings
        keyboard = MacKeyboardModel(config: Self.keyboardConfig(settings, base: MacKeyboardConfig(), padKeyLead: nil))
        pointer = Self.makePointer(settings)
        scrollCurvesInUse = Self.scrollCurves(settings)
        scrollIndexInUse = Self.scrollIndex(settings)
        scroll = Self.makeScroll(settings)
        swipeFingers = Self.swipeFingers(settings)
        appExposeEnabled = settings.prefs.appExposeGesture
        gestures = GestureActionMap(swipeFingers: swipeFingers, appExposeEnabled: appExposeEnabled)
    }

    /// Applies new settings without dropping held keys, buttons or an open scroll.
    public mutating func update(settings new: InjectorSettings) {
        settings = new
        let config = Self.keyboardConfig(new, base: keyboard.config, padKeyLead: padKeyLead)
        if config != keyboard.config { keyboard.config = config }
        pointer = Self.makePointer(new)
        scroll.natural = new.prefs.naturalScrolling
        scroll.basePtPerMM = Self.scrollBase(new)
        scroll.speedFactor = Self.scrollFactor(new)
        if Self.scrollCurves(new) != scrollCurvesInUse || Self.scrollIndex(new) != scrollIndexInUse {
            scrollRebuildPending = true
            rebuildScrollIfIdle()
        }
        if Self.swipeFingers(new) != swipeFingers || new.prefs.appExposeGesture != appExposeEnabled {
            swipeFingers = Self.swipeFingers(new)
            appExposeEnabled = new.prefs.appExposeGesture
            gestures = GestureActionMap(swipeFingers: swipeFingers, appExposeEnabled: appExposeEnabled)
        }
    }

    /// v2 input and heartbeats; hello, ping, goodbye, legacy and unknown frames yield nothing
    /// (a ping still renews the repeat lease).
    public mutating func handle(_ message: PadMessage, at now: TimeInterval, env: PointerEnvironment) -> [SynthEvent] {
        let events: [SynthEvent]
        switch message {
        case let .input(input, t):
            frameReceived(at: now)
            events = handle(input, senderTime: Double(t) / 1e6, at: now, env: env)
        case let .heartbeat(heartbeat, t):
            frameReceived(at: now)
            events = reconcile(heartbeat, senderTime: Double(t) / 1e6, at: now, env: env)
        case .ping:
            frameReceived(at: now)
            events = []
        case .hello, .goodbye, .legacy, .unknown:
            events = []
        }
        rebuildScrollIfIdle()
        return events
    }

    /// Fires due key repeats and Caps Lock deadlines, momentum frames and (when configured)
    /// the dead-man release. Call at `nextDeadline`.
    public mutating func tick(at now: TimeInterval, env: PointerEnvironment) -> [SynthEvent] {
        var events = synth(keyboard.advance(to: now, capsLockOn: env.capsLockOn), env: env)
        noteMissionControlKey(at: now)
        if let due = scroll.nextDeadline, now >= due {
            events += scrollEvents(scroll.tick(at: now), env: env)
        }
        if let due = deadManDeadline, now >= due {
            events += releaseAll(at: now, env: env)
        }
        rebuildScrollIfIdle()
        return events
    }

    /// Posts `strategy` for `f` as a down then an up, without the fn layer (the Mac's
    /// 'Check Top-Row Keys' self-test).
    public mutating func testTopRow(_ f: TopRowFunction, strategy: TopRowStrategy, env: PointerEnvironment) -> [SynthEvent] {
        let flags = currentFlags(env)
        return perform(strategy, down: true, autorepeat: false, flags: flags)
            + perform(strategy, down: false, autorepeat: false, flags: flags)
    }

    public var nextDeadline: TimeInterval? {
        [keyboard.nextDeadline, scroll.nextDeadline, deadManDeadline].compactMap { $0 }.min()
    }

    /// Releases keys (non-modifiers, top row, then modifiers), buttons, and closes an open
    /// scroll (4) or running momentum (3).
    public mutating func releaseAll(at now: TimeInterval, env: PointerEnvironment) -> [SynthEvent] {
        var events = synth(keyboard.releaseAll(capsLockOn: env.capsLockOn), env: env)
        mappedDown = [:]
        topRowHeld = [:]
        if !buttons.isEmpty {
            let at = cursor.position(env: env)
            let flags = currentFlags(env)
            for button in [PointerButton.left, .right] {
                guard let clickState = buttons[button] else { continue }
                events.append(.mouseButton(button, down: false, at: at, clickState: clickState, flags: flags))
            }
            buttons = [:]
        }
        events += scrollEvents(scroll.cancel(at: now), env: env)
        gestures.noteOtherInput(at: now)
        rebuildScrollIfIdle()
        return events
    }

    /// Keys (including a pending Caps Lock press), buttons or an open scroll.
    public var hasHeldInput: Bool {
        !keyboard.heldPhysicalCodes.isEmpty || !buttons.isEmpty || scrollOpen
    }

    // MARK: - Input

    private mutating func handle(_ input: PadInput, senderTime: TimeInterval, at now: TimeInterval,
                                 env: PointerEnvironment) -> [SynthEvent] {
        switch input {
        case let .key(code, down):
            let events = (down ? userActivity(at: now) : []) + key(code, down: down, senderTime: senderTime, at: now, env: env)
            // A key press may dismiss Mission Control (Escape); the Mission Control key toggles it.
            if !noteMissionControlKey(at: now), down { gestures.noteOtherInput(at: now) }
            return events

        case let .button(button, down, clickState):
            gestures.noteOtherInput(at: now)
            var events = down ? userActivity(at: now) : []
            events += scrollEvents(scroll.stopMomentum(at: now), env: env)
            let state = Int64(min(max(clickState, 1), 3))
            if down {
                guard buttons[button] == nil else { return events }
                buttons[button] = state
            } else {
                guard buttons.removeValue(forKey: button) != nil else { return events }
            }
            events.append(.mouseButton(button, down: down, at: cursor.position(env: env), clickState: state,
                                       flags: currentFlags(env)))
            return events

        case let .motion(m):
            // Moving the pointer cannot close Mission Control, so it leaves the gesture map alone.
            let d = pointer.apply(dxMM: m.dx, dyMM: m.dy, speed: m.speed)
            let move = cursor.move(by: d.dx, dy: d.dy, env: env)
            let drag: PointerButton? = buttons[.left] != nil ? .left : (buttons[.right] != nil ? .right : nil)
            return userActivity(at: now)
                + [.mouseMove(to: move.to, deltaX: move.deltaX, deltaY: move.deltaY, drag: drag, flags: currentFlags(env))]

        case let .scroll(s):
            let phase: ScrollInputPhase
            switch s.phase {
            case .mayBegin: phase = .mayBegin
            case .began: phase = .began
            case .changed: phase = .changed
            case .ended: phase = .ended
            case .cancelled: phase = .cancelled
            }
            let frames = scroll.input(phase, dxMM: s.dx, dyMM: s.dy, dt: s.dt, speed: s.speed,
                                      releaseVX: s.releaseVX, releaseVY: s.releaseVY, at: now)
            return (phase == .began || phase == .changed ? userActivity(at: now) : []) + scrollEvents(frames, env: env)

        case let .contacts(n):
            return n > 0 ? scrollEvents(scroll.stopMomentum(at: now), env: env) : []

        case let .gesture(g):
            guard let gesture = Self.gestureInput(g) else { return [] }
            let actions = gestures.handle(gesture, at: now)
            var events = actions.isEmpty ? [] : userActivity(at: now)
            for action in actions {
                switch action {
                case .hotKey(let id): events += hotKeyChord(id, base: currentFlags(env))
                case let .shortcut(code, mask): events += chord(code, mask: mask, base: currentFlags(env))
                }
            }
            return events

        case .releaseAll:
            return releaseAll(at: now, env: env)
        }
    }

    /// Applies the remap, then the keyboard model. Several physical keys mapped to one code
    /// press it once and release it with the last of them.
    private mutating func key(_ physical: UInt16, down: Bool, senderTime: TimeInterval, at now: TimeInterval,
                              env: PointerEnvironment) -> [SynthEvent] {
        let code: UInt16
        if down {
            guard mappedDown[physical] == nil else { return [] }
            code = settings.keyRemap[physical] ?? physical
            let alreadyDown = mappedDown.values.contains(code)
            mappedDown[physical] = code
            guard !alreadyDown else { return [] }
        } else {
            guard let mapped = mappedDown.removeValue(forKey: physical),
                  !mappedDown.values.contains(mapped) else { return [] }
            code = mapped
        }
        // A deck modifier (lazy, or tap-only once remapped) sends a lone tap's down and up
        // together at the lift, so a Caps Lock it is remapped to cannot be timed from the gap.
        let tapAtLift = down && code == MacKeyCode.capsLock && physical != code
            && KeyCommitPipeline.modifierCodes.contains(physical)
        return synth(keyboard.key(code, down: down, senderTime: senderTime, at: now, capsLockOn: env.capsLockOn,
                                  capsTapAtLift: tapAtLift), env: env)
    }

    /// Releases what the Mac holds but the heartbeat does not; never presses, never changes
    /// the Caps Lock state, and drops anything a release would trigger (an fn tap action, an
    /// input-source switch). A key mapped to Caps Lock whose up was lost (the user's remapped
    /// left Command) is let go too: its pending press is cancelled without resolving, so a hold
    /// deadline cannot toggle the lock later and the next tap is not swallowed.
    private mutating func reconcile(_ heartbeat: Heartbeat, senderTime: TimeInterval, at now: TimeInterval,
                                    env: PointerEnvironment) -> [SynthEvent] {
        if let lead = heartbeat.keyConfirmDelay, lead.isFinite, lead >= 0, lead != padKeyLead {
            padKeyLead = lead
            let config = Self.keyboardConfig(settings, base: keyboard.config, padKeyLead: lead)
            if config != keyboard.config { keyboard.config = config }
        }
        let padHeld = Set(heartbeat.held)
        mappedDown = mappedDown.filter { padHeld.contains($0.key) }
        let stillHeld = Set(mappedDown.values)
        let stale = HeldStateReconciler.reconcile(macHeldKeys: keyboard.heldPhysicalCodes, macButtons: Set(buttons.keys),
                                                  padHeld: stillHeld, padButtons: Set(heartbeat.buttons))
        var releaseKeys = stale.releaseKeys
        if keyboard.heldPhysicalCodes.contains(MacKeyCode.capsLock), !stillHeld.contains(MacKeyCode.capsLock) {
            releaseKeys.append(MacKeyCode.capsLock)
        }
        var events: [SynthEvent] = []
        for code in releaseKeys {
            let actions = keyboard.key(code, down: false, senderTime: senderTime, at: now, capsLockOn: env.capsLockOn)
            events += synth(actions.filter(Self.isRelease), env: env)
        }
        if !stale.releaseButtons.isEmpty {
            let at = cursor.position(env: env)
            for button in stale.releaseButtons {
                guard let clickState = buttons.removeValue(forKey: button) else { continue }
                events.append(.mouseButton(button, down: false, at: at, clickState: clickState, flags: currentFlags(env)))
            }
        }
        return events
    }

    private static func isRelease(_ action: KeyboardAction) -> Bool {
        switch action {
        case .key(_, let down, _, _), .topRow(_, let down, _, _): return !down
        case .flagsChanged: return true
        case .setCapsLock, .symbolicHotKey, .shortcut: return false
        }
    }

    // MARK: - Keyboard actions

    private mutating func synth(_ actions: [KeyboardAction], env: PointerEnvironment) -> [SynthEvent] {
        var events: [SynthEvent] = []
        for action in actions {
            switch action {
            case let .key(code, down, flags, autorepeat):
                events.append(.key(code: code, down: down, flags: flags, autorepeat: autorepeat))
            case let .flagsChanged(code, flags):
                events.append(.flagsChanged(code: code, flags: flags))
            case let .topRow(f, down, autorepeat, flags):
                let strategy: TopRowStrategy
                if !down {
                    strategy = topRowHeld.removeValue(forKey: f) ?? resolve(f)
                } else if autorepeat, let held = topRowHeld[f] {
                    strategy = held
                } else {
                    strategy = resolve(f)
                    topRowHeld[f] = strategy
                }
                if down, !autorepeat, Self.togglesMissionControl(strategy, flags: flags) { missionControlKeyPosted = true }
                events += perform(strategy, down: down, autorepeat: autorepeat, flags: flags)
            case let .setCapsLock(on):
                events.append(.setCapsLock(on))
            case let .symbolicHotKey(id) where id == Self.previousInputSourceHotKey:
                events.append(.selectPreviousInputSource(fallback: inputSourceFallback(id, held: currentFlags(env))))
            case let .symbolicHotKey(id):
                events += hotKeyChord(id, base: currentFlags(env))
            case let .shortcut(code, mask):
                events += chord(code, mask: mask, base: currentFlags(env))
            }
        }
        return events
    }

    /// The user's choice, then the default chain; a hot key that is disabled or unassigned
    /// on the Mac is skipped.
    private func resolve(_ f: TopRowFunction) -> TopRowStrategy {
        let choice = settings.topRowChoices[f].map { [$0] } ?? []
        return (choice + TopRowDefaults.chain(for: f)).first { strategy in
            if case .hotKey(let id) = strategy { return settings.hotKeys.hotKey(id)?.enabled == true }
            return true
        } ?? .none
    }

    private func perform(_ strategy: TopRowStrategy, down: Bool, autorepeat: Bool, flags: ModifierFlags) -> [SynthEvent] {
        switch strategy {
        case .aux(let k):
            return [.aux(nxKeyType: k, down: down, autorepeat: autorepeat, flags: flags)]
        case let .keyCode(code, secondaryFn):
            var keyFlags = flags.union(MacKeyCode.implicitFlags(for: code))
            if secondaryFn { keyFlags.insert(.secondaryFn) }
            return [.key(code: code, down: down, flags: keyFlags, autorepeat: autorepeat)]
        case .hotKey(let id):
            return down ? hotKeyChord(id, base: flags) : []
        case .openApplication(let path):
            return down && !autorepeat ? [.openApplication(path: path)] : []
        case .none:
            return []
        }
    }

    /// The Mac's current shortcut for a symbolic hot key; nothing when unassigned or disabled
    /// (a disabled shortcut would only reach the front app as a stray key).
    private func hotKeyChord(_ id: Int, base: ModifierFlags) -> [SynthEvent] {
        guard let hotKey = settings.hotKeys.hotKey(id), hotKey.enabled else { return [] }
        return chord(hotKey.keyCode, mask: hotKey.modifierMask, base: base)
    }

    /// The 'previous input source' shortcut's chord with exactly its own modifiers, for the
    /// poster to use only when it cannot select the source itself. The switch ignores held
    /// modifiers, but the shortcut would not: a held Command would turn ^Space into ^⌘Space
    /// (Emoji & Symbols). So the held modifier keys are lifted first (reverse chord order),
    /// the chord is posted on the remaining flags (Caps Lock, non-coalesced), and the held keys
    /// are pressed again in chord order, ending at `held`. Empty when the shortcut is off.
    private func inputSourceFallback(_ id: Int, held: ModifierFlags) -> [SynthEvent] {
        let heldKeys = Self.heldModifierKeys(held)
        let bare = Self.flags(held, keeping: [])
        let chordEvents = hotKeyChord(id, base: bare)
        guard !chordEvents.isEmpty, !heldKeys.isEmpty else { return chordEvents }
        var events: [SynthEvent] = []
        for n in stride(from: heldKeys.count - 1, through: 0, by: -1) {
            events.append(.flagsChanged(code: heldKeys[n], flags: Self.flags(held, keeping: heldKeys[..<n])))
        }
        events += chordEvents
        for n in heldKeys.indices {
            events.append(.flagsChanged(code: heldKeys[n], flags: Self.flags(held, keeping: heldKeys[...n])))
        }
        return events
    }

    /// Modifier key codes whose device bits are set in `flags`, in chord order (control,
    /// option, shift, command, left before right, then fn).
    private static func heldModifierKeys(_ flags: ModifierFlags) -> [UInt16] {
        let order: [(bit: ModifierFlags, code: UInt16)] = [
            (.leftControl, 59), (.rightControl, 62), (.leftOption, 58), (.rightOption, 61),
            (.leftShift, 56), (.rightShift, 60), (.leftCommand, 55), (.rightCommand, 54),
            (.secondaryFn, MacKeyCode.fn),
        ]
        return order.filter { flags.contains($0.bit) }.map(\.code)
    }

    /// `flags` without any modifier-key bits, plus the bits of the modifier keys `codes`.
    private static func flags<C: Sequence>(_ flags: ModifierFlags, keeping codes: C) -> ModifierFlags
        where C.Element == UInt16 {
        var result = flags
        for code in MacKeyCode.modifiers { result.subtract(MacKeyCode.modifierFlags(for: code) ?? []) }
        for code in codes { result.formUnion(MacKeyCode.modifierFlags(for: code) ?? []) }
        return result
    }

    /// Presses the mask's modifiers (left-side keys) on top of the user's held flags, taps the
    /// key with its implicit flags, and lifts only the modifiers it pressed, in reverse. A
    /// modifier the user already holds is reused; fn is posted only when the key does not
    /// carry SecondaryFn by itself (arrows and F-keys do).
    private func chord(_ code: UInt16, mask: UInt64, base: ModifierFlags) -> [SynthEvent] {
        let implicit = MacKeyCode.implicitFlags(for: code)
        let wanted = ModifierFlags(rawValue: mask)
        var flags = base
        var events: [SynthEvent] = []
        var pressed: [(code: UInt16, flags: ModifierFlags)] = []
        for modifier in Self.chordModifiers where wanted.contains(modifier.mask) {
            guard !base.contains(modifier.mask), !implicit.contains(modifier.mask) else { continue }
            flags.formUnion(modifier.flags)
            pressed.append((modifier.code, modifier.flags))
            events.append(.flagsChanged(code: modifier.code, flags: flags))
        }
        let keyFlags = flags.union(implicit)
        events.append(.key(code: code, down: true, flags: keyFlags, autorepeat: false))
        events.append(.key(code: code, down: false, flags: keyFlags, autorepeat: false))
        for modifier in pressed.reversed() {
            flags.subtract(modifier.flags)
            events.append(.flagsChanged(code: modifier.code, flags: flags))
        }
        return events
    }

    // MARK: - Helpers

    private func currentFlags(_ env: PointerEnvironment) -> ModifierFlags {
        keyboard.currentFlags(capsLockOn: env.capsLockOn)
    }

    /// Wraps frames with the held flags and tracks whether a scroll gesture is open: may-begin,
    /// began and changed open it, ended and cancelled close it, momentum frames leave it.
    private mutating func scrollEvents(_ frames: [ScrollFrame], env: PointerEnvironment) -> [SynthEvent] {
        for frame in frames {
            switch frame.phase {
            case 1, 2, 128: scrollOpen = true
            case 4, 8: scrollOpen = false
            default: break
            }
        }
        let flags = currentFlags(env)
        return frames.map { .scroll($0, flags: flags) }
    }

    private mutating func frameReceived(at now: TimeInterval) {
        keyboard.frameReceived(at: now)
        if now.isFinite { lastFrame = now }
    }

    /// At most one declaration per second (a clock that went backwards restarts the window).
    private mutating func userActivity(at now: TimeInterval) -> [SynthEvent] {
        guard now.isFinite, now < lastUserActivity || now - lastUserActivity >= Self.userActivityInterval else { return [] }
        lastUserActivity = now
        return [.declareUserActivity]
    }

    private var deadManDeadline: TimeInterval? {
        guard let timeout = settings.deadManTimeout, timeout.isFinite, timeout >= 0,
              lastFrame.isFinite, hasHeldInput else { return nil }
        return lastFrame + timeout
    }

    private mutating func rebuildScrollIfIdle() {
        guard scrollRebuildPending, !scrollOpen, !scroll.isMomentumActive else { return }
        scroll = Self.makeScroll(settings)
        scrollCurvesInUse = Self.scrollCurves(settings)
        scrollIndexInUse = Self.scrollIndex(settings)
        scrollRebuildPending = false
    }

    /// Hands a Mission Control key toggle posted since the last call to the gesture map, so a
    /// swipe down then closes Mission Control and a swipe up keeps it open. True when there was one.
    @discardableResult
    private mutating func noteMissionControlKey(at now: TimeInterval) -> Bool {
        guard missionControlKeyPosted else { return false }
        missionControlKeyPosted = false
        gestures.noteMissionControlToggled(at: now)
        return true
    }

    /// A top-row strategy that toggles Mission Control when pressed without Control, Option or
    /// Command (with them the Mission Control key does other things, such as Show Desktop).
    private static func togglesMissionControl(_ strategy: TopRowStrategy, flags: ModifierFlags) -> Bool {
        guard flags.intersection([.control, .option, .command]).isEmpty else { return false }
        switch strategy {
        case .keyCode(let code, _): return code == missionControlKeyCode
        case .hotKey(let id): return id == GestureActionMap.missionControlHotKey
        case .openApplication(let path): return path.hasSuffix("/Mission Control.app")
        case .aux, .none: return false
        }
    }

    private static func gestureInput(_ g: WireGesture) -> GestureInput? {
        switch g.kind {
        case .swipe:
            guard let direction = g.direction.flatMap(GestureDirection.init(rawValue:)) else { return nil }
            return .swipe(fingers: g.fingers, direction: direction)
        case .tap:
            return .tap(fingers: g.fingers)
        }
    }

    /// `padKeyLead`, the iPad's own key confirmation delay from its heartbeats, wins over
    /// `padKeyConfirmationDelay`.
    private static func keyboardConfig(_ s: InjectorSettings, base: MacKeyboardConfig,
                                       padKeyLead: Double?) -> MacKeyboardConfig {
        let prefs = s.prefs.clamped()
        var config = base
        config.fnKeysStandard = prefs.fnKeysStandard
        config.repeatDelay = prefs.keyRepeatDelay
        config.repeatInterval = prefs.keyRepeatInterval
        config.capsMode = s.capsMode
        config.fnTapAction = s.fnTapAction
        config.capsSenderLead = padKeyLead ?? s.padKeyConfirmationDelay
        return config
    }

    private static func makePointer(_ s: InjectorSettings) -> PointerAccelerator {
        let curves = s.pointerCurves.flatMap { $0.isEmpty ? nil : $0 } ?? HIDCurveTables.pointer
        let index = s.trackingIndexOverride.flatMap { $0.isFinite ? $0 : nil } ?? s.prefs.clamped().trackingIndex
        return PointerAccelerator(curves: curves, index: index, speedAxisScale: s.speedAxisScale, gainScale: s.gainScale)
    }

    private static func scrollCurves(_ s: InjectorSettings) -> [HIDAccelCurve] {
        s.scrollCurves.flatMap { $0.isEmpty ? nil : $0 } ?? HIDCurveTables.scroll
    }

    private static func makeScroll(_ s: InjectorSettings) -> ScrollSynthesizer {
        ScrollSynthesizer(natural: s.prefs.naturalScrolling, basePtPerMM: scrollBase(s), speedFactor: scrollFactor(s),
                          scrollIndex: scrollIndex(s), curves: scrollCurves(s))
    }

    /// The live scroll acceleration index when it is finite and within 0...3 (the range of the
    /// Mac's acceleration tables), else the default.
    private static func scrollIndex(_ s: InjectorSettings) -> Double {
        guard let index = s.scrollIndexOverride, index.isFinite, (0.0...3.0).contains(index) else {
            return ScrollSynthesizer.defaultScrollIndex
        }
        return index
    }

    private static func scrollBase(_ s: InjectorSettings) -> Double {
        s.scrollBasePtPerMM.isFinite && s.scrollBasePtPerMM > 0 ? s.scrollBasePtPerMM : 5.0
    }

    private static func scrollFactor(_ s: InjectorSettings) -> Double {
        s.scrollSpeedFactor.isFinite && s.scrollSpeedFactor >= 0 ? s.scrollSpeedFactor : 1
    }

    /// Three-finger drag moves swipes to four fingers, as on the Mac.
    private static func swipeFingers(_ s: InjectorSettings) -> Int { s.prefs.threeFingerDrag ? 4 : 3 }
}
