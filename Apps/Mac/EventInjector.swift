import AppKit
import Carbon
import CoreGraphics
import Foundation
import IKeyCore
import IOKit
import IOKit.pwr_mgt
import os

/// Posts only events received from the authenticated iPad. Never monitors local typing.
///
/// Protocol v1 frames run through `LegacyEventInjector` unchanged. Protocol v2 messages go
/// through the Linux-tested `InjectorCore`; this class only reads the Mac's environment, turns
/// the core's `SynthEvent`s into CGEvents (and the few system calls the core asks for) and
/// drives the core's deadlines with a one-shot timer. Main-queue confined.
final class EventInjector {
    /// Called when `hasHeldInput` changes.
    var onHeldInputChanged: ((Bool) -> Void)?

    /// True while any key, mouse button or scroll gesture is held on the Mac (v1 or v2).
    var hasHeldInput: Bool { core.hasHeldInput || legacy.hasHeldInput }

    /// The Caps Lock state iKey types with: the virtual lock after a fallback to virtual mode,
    /// otherwise the system state (falling back to the HID event flags).
    var capsLockOn: Bool {
        effectiveCapsMode == .virtual ? virtualCapsOn : Self.systemCapsLockOn
    }

    /// The Caps Lock behaviour in effect (`.virtual` after a failed hardware set in `.system`
    /// mode; `.switchesInputSource` is kept, see `setCapsLock`).
    var effectiveCapsMode: CapsMode { settings.capsMode }

    /// Additive (amendments C/H/J): the effective key remapping that v2 input mirrors: the Mac's
    /// detected remap (hidutil, the Modifier Keys preferences, Karabiner-Elements) merged with the
    /// manual pairs, or empty while applying is off (`setKeyRemapOverride`).
    private(set) var keyRemap = KeyRemap()
    /// Additive: the detected remap without manual pairs, also while applying is off (for display).
    private(set) var detectedKeyRemap = KeyRemap()
    /// Additive (amendment J): true once the first remap read has finished, even if it found nothing.
    private(set) var hasReadKeyRemap = false
    /// Additive: called on the main queue whenever `keyRemap` or `detectedKeyRemap` changes
    /// (also for `setKeyRemapOverride` changes before the first read, e.g. while not listening),
    /// and once when the first remap read finishes even if nothing changed. A consumer that must
    /// not act on a partial remap (the first MacState.tapOnly, amendment H) checks
    /// `hasReadKeyRemap` in the callback.
    var onKeyRemapChanged: ((KeyRemap) -> Void)?
    /// Additive (amendment K): true after the system Caps Lock could not be set and verified in
    /// `.switchesInputSource` mode, so a long press cannot toggle Caps Lock while taps still
    /// switch the input source. Cleared by a later successful set and by a new Caps Lock
    /// preference.
    private(set) var capsHardwareSetFailed = false
    /// Additive (final-review fix): true after an input-source switch to a source that cannot
    /// type ASCII (Korean 2-Set, Pinyin, Kana) had to use TISSelectInputSource because the
    /// 'Select the previous input source' shortcut is off or unassigned. macOS may then show
    /// the new source in the menu bar while the focused app keeps the old one, so the menu
    /// asks for the shortcut. Cleared when the shortcut is enabled again.
    private(set) var inputSourceShortcutNeeded = false

    /// Symbolic hot key 60, 'Select the previous input source' (^Space by default).
    private static let previousInputSourceHotKey = 60
    /// Every posted event carries this in kCGEventSourceUserData ("iKey").
    private static let userData: Int64 = 0x694B6579
    private static let log = Logger(subsystem: "com.ikey.mac", category: "injector")

    private let legacy = LegacyEventInjector()
    private var core = InjectorCore()
    private var settings = InjectorSettings()
    private let source = CGEventSource(stateID: .privateState)
    private let inputSources = InputSourceHistory()
    private var timer: DispatchSourceTimer?
    private var reportedHeldInput = false

    private var readings: MacReadings?
    private var gainScale = 1.0
    private var scrollSpeedFactor = 1.0
    private var topRowChoices: [TopRowFunction: TopRowStrategy] = [:]
    /// nil: follow the Mac's settings.
    private var capsModePreference: CapsMode?
    /// nil: follow the Mac's settings.
    private var fnTapPreference: FnTapAction?
    /// Set when the system Caps Lock could not be set and verified in `.system` mode; forces
    /// `.virtual` (while the chosen mode is `.system`) until the user picks another Caps Lock
    /// preference.
    private var capsHardwareFailed = false
    /// The core's virtual lock, mirrored from the Caps Lock flagsChanged events it emits.
    private var virtualCapsOn = false

    private var userActivityAssertion = IOPMAssertionID(0)
    private var remapReadInFlight = false
    /// The last successfully read pairs of each remap layer; a layer whose read fails keeps
    /// these, so one failed or slow read never drops the user's remap. An override change
    /// re-merges these without re-reading.
    private var remapLayers = KeyRemapReader.Layers()
    /// The layers whose last read failed (logged only when this changes).
    private var lastRemapFailures: [String] = []
    /// `setKeyRemapOverride`: false applies no remap at all.
    private var applyDetectedRemap = true
    private var manualRemap: [UInt16: UInt16]?

    deinit {
        timer?.cancel()
        if userActivityAssertion != 0 { IOPMAssertionRelease(userActivityAssertion) }
    }

    // MARK: - Frozen API

    /// Protocol v1 input.
    func handle(_ event: InputEvent) {
        legacy.handle(event)
        reportHeldInput()
    }

    func handle(_ message: PadMessage) {
        if case .legacy(let event) = message {
            handle(event)
            return
        }
        post(core.handle(message, at: Self.now, env: environment()))
        didCallCore()
    }

    func releaseAll() {
        post(core.releaseAll(at: Self.now, env: environment()))
        legacy.releaseAll()
        didCallCore()
    }

    /// Also the only remap-read trigger (amendment J): ReceiverModel calls this at start and on
    /// each preferences poll while listening.
    func apply(readings: MacReadings) {
        setReadings(readings)
        refreshKeyRemap()
    }

    /// Additive (amendment K): hands over the Mac's readings without starting a remap read, so
    /// the Caps Lock mode, the fn-tap action and the hot keys (top-row Try) follow the Mac
    /// before listening starts while idle still spawns no hidutil.
    func setReadings(_ readings: MacReadings) {
        self.readings = readings
        rebuildSettings()
    }

    func setTuning(gainScale: Double, scrollSpeedFactor: Double) {
        self.gainScale = gainScale
        self.scrollSpeedFactor = scrollSpeedFactor
        rebuildSettings()
    }

    func setTopRowChoices(_ choices: [TopRowFunction: TopRowStrategy]) {
        topRowChoices = choices
        rebuildSettings()
    }

    /// nil = automatic from the readings. A new preference retries the hardware lock after a
    /// fallback to virtual mode.
    func setCapsModePreference(_ mode: CapsMode?) {
        if mode != capsModePreference {
            capsHardwareFailed = false
            capsHardwareSetFailed = false
        }
        capsModePreference = mode
        rebuildSettings()
    }

    /// nil = automatic from the readings.
    func setFnTapPreference(_ action: FnTapAction?) {
        fnTapPreference = action
        rebuildSettings()
    }

    /// Posts one top-row function with the given strategy as a down then an up (the menu's
    /// self-test), on top of the modifiers the iPad currently holds.
    func postTopRowTest(_ f: TopRowFunction, strategy: TopRowStrategy) {
        post(core.testTopRow(f, strategy: strategy, env: environment()))
        didCallCore()
    }

    // MARK: - Settings

    private func rebuildSettings() {
        var s = InjectorSettings()
        if let r = readings {
            s.prefs = r.prefs
            s.hotKeys = r.hotKeys
            s.pointerCurves = r.liveCurves.pointer
            s.scrollCurves = r.liveCurves.scroll
            s.trackingIndexOverride = r.liveCurves.trackingIndex
            s.scrollBasePtPerMM = r.builtInPtPerMM ?? 5.0
        }
        s.gainScale = gainScale
        s.scrollSpeedFactor = scrollSpeedFactor
        s.topRowChoices = topRowChoices
        let multipleSources = (readings?.enabledInputSourceCount ?? 0) > 1
        let automaticCaps: CapsMode = readings?.capsSwitchesInputSource == true && multipleSources
            ? .switchesInputSource : .system
        let chosenCaps = capsModePreference ?? automaticCaps
        // Only the plain system lock falls back to virtual; input-source switching (the user's
        // remapped left Command) must keep working when the hardware lock cannot be set.
        s.capsMode = capsHardwareFailed && chosenCaps == .system ? .virtual : chosenCaps
        let automaticFnTap: FnTapAction = multipleSources ? .changeInputSource : FnTapAction.none
        s.fnTapAction = fnTapPreference ?? readings?.fnTapAction ?? automaticFnTap
        s.keyRemap = keyRemap.map
        if inputSourceShortcutNeeded, s.hotKeys.hotKey(Self.previousInputSourceHotKey)?.enabled == true {
            inputSourceShortcutNeeded = false
        }
        guard s != settings else { return }
        // A mode change resets the core's Caps Lock controller, including its virtual lock, and
        // ends a long-press failure episode (the next hold tries the hardware lock again).
        if s.capsMode != settings.capsMode {
            virtualCapsOn = false
            capsHardwareSetFailed = false
        }
        settings = s
        core.update(settings: s)
        didCallCore()
    }

    // MARK: - Environment and deadlines

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static var systemCapsLockOn: Bool {
        CapsLockHardware.read() ?? CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
    }

    private func environment() -> PointerEnvironment {
        PointerEnvironment(cursor: CGEvent(source: nil)?.location ?? .zero,
                           displays: Self.activeDisplayBounds(),
                           capsLockOn: Self.systemCapsLockOn)
    }

    /// Global display bounds (Quartz coordinates, y down; negative origins allowed).
    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private func didCallCore() {
        scheduleTick()
        reportHeldInput()
    }

    /// Re-arms the one-shot timer at the core's next deadline (repeat, Caps Lock hold,
    /// momentum frame), or parks it when there is none.
    private func scheduleTick() {
        let timer = self.timer ?? makeTimer()
        guard let deadline = core.nextDeadline, deadline.isFinite else {
            timer.schedule(deadline: .distantFuture, repeating: .never, leeway: .milliseconds(1))
            return
        }
        let delay = min(max(deadline - Self.now, 0), 3600)
        timer.schedule(deadline: .now() + delay, repeating: .never, leeway: .milliseconds(1))
    }

    private func makeTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.schedule(deadline: .distantFuture, repeating: .never, leeway: .milliseconds(1))
        timer.resume()
        self.timer = timer
        return timer
    }

    private func tick() {
        post(core.tick(at: Self.now, env: environment()))
        didCallCore()
    }

    private func reportHeldInput() {
        let held = hasHeldInput
        guard held != reportedHeldInput else { return }
        reportedHeldInput = held
        onHeldInputChanged?(held)
    }

    // MARK: - Posting

    private func post(_ events: [SynthEvent]) {
        for synth in events { post(synth) }
    }

    private func post(_ synth: SynthEvent) {
        switch synth {
        case let .key(code, down, flags, autorepeat):
            postKey(code, down: down, flags: flags, autorepeat: autorepeat, flagsChanged: false)

        case let .flagsChanged(code, flags):
            if code == MacKeyCode.capsLock { virtualCapsOn = flags.contains(.alphaShift) }
            postKey(code, down: false, flags: flags, autorepeat: false, flagsChanged: true)

        case let .aux(nxKeyType, down, autorepeat, flags):
            postAux(nxKeyType, down: down, autorepeat: autorepeat, flags: flags)

        case let .openApplication(path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path),
                                               configuration: NSWorkspace.OpenConfiguration(),
                                               completionHandler: nil)

        case let .setCapsLock(on):
            setCapsLock(on)

        case let .mouseMove(to, deltaX, deltaY, drag, flags):
            let type: CGEventType
            switch drag {
            case .left: type = .leftMouseDragged
            case .right: type = .rightMouseDragged
            case nil: type = .mouseMoved
            }
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: to,
                                mouseButton: drag == .right ? .right : .left)
            event?.flags = CGEventFlags(rawValue: flags.rawValue)
            event?.setIntegerValueField(.mouseEventDeltaX, value: deltaX)
            event?.setIntegerValueField(.mouseEventDeltaY, value: deltaY)
            post(event)

        case let .mouseButton(button, down, at, clickState, flags):
            let type: CGEventType
            switch button {
            case .left: type = down ? .leftMouseDown : .leftMouseUp
            case .right: type = down ? .rightMouseDown : .rightMouseUp
            }
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at,
                                mouseButton: button == .right ? .right : .left)
            event?.flags = CGEventFlags(rawValue: flags.rawValue)
            event?.setIntegerValueField(.mouseEventClickState, value: clickState)
            post(event)

        case let .scroll(frame, flags):
            postScroll(frame, flags: flags)

        case .declareUserActivity:
            var id = userActivityAssertion
            let result = IOPMAssertionDeclareUserActivity("iKey input" as CFString, kIOPMUserActiveLocal, &id)
            if result == kIOReturnSuccess { userActivityAssertion = id }

        case let .selectPreviousInputSource(fallback):
            selectPreviousInputSource(fallback: fallback)
        }
    }

    /// The enabled 'Select the previous input source' shortcut goes first, TISSelectInputSource
    /// only when it is off or unassigned (`fallback` empty). Posted like a keystroke, the
    /// shortcut makes macOS switch the frontmost app's input context, CJKV input methods
    /// included. TISSelectInputSource from iKey, a background agent that is never frontmost,
    /// can return noErr and change the menu-bar icon while the focused app keeps typing with
    /// the old source when the target is a CJKV input method such as Korean 2-Set (the macOS
    /// bug macism and im-select work around). Nothing can detect that, so the shortcut must
    /// not wait for a TIS error. `fallback` already lifts and re-presses held modifiers around
    /// the chord, so held keys do not change the shortcut. This deliberately reverses the
    /// 'TIS first' order of amendments C/I (final-review fix, pending lead sign-off).
    private func selectPreviousInputSource(fallback: [SynthEvent]) {
        guard fallback.isEmpty else {
            post(fallback)
            return
        }
        guard let target = inputSources.selectPrevious() else { return }
        guard !target.asciiCapable, !inputSourceShortcutNeeded else { return }
        inputSourceShortcutNeeded = true
        Self.log.error("Switched to \(target.id, privacy: .public) with TISSelectInputSource because the 'Select the previous input source' shortcut is off; the focused app may keep the old source")
    }

    private func postKey(_ code: UInt16, down: Bool, flags: ModifierFlags, autorepeat: Bool, flagsChanged: Bool) {
        // A key the user's remap disables ("No Action") posts nothing.
        guard code != KeyRemap.noAction,
              let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
        else { return }
        if flagsChanged { event.type = .flagsChanged }
        event.flags = CGEventFlags(rawValue: flags.rawValue)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat ? 1 : 0)
        post(event)
    }

    /// NX_SYSDEFINED / NX_SUBTYPE_AUX_CONTROL_BUTTONS: brightness, volume and media keys.
    private func postAux(_ key: Int, down: Bool, autorepeat: Bool, flags: ModifierFlags) {
        let state = down ? 0xA : 0xB
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(state << 8) | UInt(flags.rawValue & 0xFFFF_0000))
        let data1 = (key << 16) | (state << 8) | (autorepeat ? 1 : 0)
        let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: modifierFlags,
                                       timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                       data1: data1, data2: -1)
        post(event?.cgEvent)
    }

    /// A continuous (trackpad-style) pixel scroll with its gesture and momentum phases.
    private func postScroll(_ frame: ScrollFrame, flags: ModifierFlags) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: frame.pointY, wheel2: frame.pointX, wheel3: 0) else { return }
        event.flags = CGEventFlags(rawValue: flags.rawValue)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(frame.pointY))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(frame.pointX))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: frame.fixedY)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: frame.fixedX)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(frame.lineY))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(frame.lineX))
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: frame.phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: frame.momentum)
        post(event)
    }

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.userData)
        event.post(tap: .cghidEventTap)
    }

    /// Sets the system lock and verifies it. When that fails in `.system` mode, Caps Lock falls
    /// back to the virtual mode (the menu shows it). The press that failed is not replayed: the
    /// user presses Caps Lock again (accepted in the plan amendments). In
    /// `.switchesInputSource` mode only this hold-to-toggle is dropped (`capsHardwareSetFailed`):
    /// the mode is kept so that taps still switch the input source (they never need the
    /// hardware lock).
    private func setCapsLock(_ on: Bool) {
        guard !CapsLockHardware.set(on) else {
            capsHardwareSetFailed = false
            return
        }
        if settings.capsMode == .switchesInputSource {
            if !capsHardwareSetFailed {
                Self.log.error("Caps Lock could not be set to \(on, privacy: .public); hold ignored, input-source switching kept")
            }
            capsHardwareSetFailed = true
            return
        }
        guard !capsHardwareFailed else { return }
        capsHardwareFailed = true
        Self.log.error("Caps Lock could not be set to \(on, privacy: .public); using virtual Caps Lock")
        rebuildSettings()
    }

    // MARK: - Key remap

    /// Additive (amendment J): `apply` false posts every key unmapped (effective map [:]);
    /// otherwise the detected layers merged with `manual` via `KeyRemap.merged`. Takes effect
    /// immediately from the last read layers, without re-reading.
    func setKeyRemapOverride(apply: Bool, manual: [UInt16: UInt16]?) {
        applyDetectedRemap = apply
        manualRemap = manual
        updateKeyRemap(reportAnyway: false)
    }

    /// Reads the remap off the main queue (hidutil runs as a child process with a timeout).
    /// At most one read runs at a time; a request during a read is dropped.
    private func refreshKeyRemap() {
        guard !remapReadInFlight else { return }
        remapReadInFlight = true
        let lastGood = remapLayers
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = KeyRemapReader.read(lastGood: lastGood)
            DispatchQueue.main.async { self?.keyRemapRead(result) }
        }
    }

    /// Layers whose read failed keep their last good pairs.
    private func keyRemapRead(_ result: KeyRemapReader.ReadResult) {
        remapReadInFlight = false
        remapLayers = result.layers
        if result.failed != lastRemapFailures {
            lastRemapFailures = result.failed
            let failed = result.failed.joined(separator: ", ")
            if result.failed.isEmpty {
                Self.log.notice("Key remap reads recovered")
            } else {
                Self.log.error("Key remap read failed for [\(failed, privacy: .public)]; keeping their last read pairs")
            }
        }
        let firstRead = !hasReadKeyRemap
        hasReadKeyRemap = true
        updateKeyRemap(reportAnyway: firstRead)
    }

    /// Recomputes the detected and effective remaps from the stored layers and the override,
    /// rebuilds the settings when the effective one changed and reports any change
    /// (`reportAnyway`: the first read itself, which reports even when nothing changed).
    private func updateKeyRemap(reportAnyway: Bool) {
        let detected = remapLayers.merged(manual: nil)
        let effective = applyDetectedRemap ? remapLayers.merged(manual: manualRemap) : KeyRemap()
        var changed = false
        if detected != detectedKeyRemap {
            detectedKeyRemap = detected
            changed = true
            Self.log.notice("Detected key remap \(Self.describe(detected), privacy: .public)")
        }
        if effective != keyRemap {
            keyRemap = effective
            changed = true
            Self.log.notice("Applied key remap \(Self.describe(effective), privacy: .public)")
            rebuildSettings()
        }
        if changed || reportAnyway { onKeyRemapChanged?(keyRemap) }
    }

    private static func describe(_ remap: KeyRemap) -> String {
        let pairs = remap.map.sorted { $0.key < $1.key }.map { "\($0.key)→\($0.value)" }.joined(separator: ", ")
        let sources = remap.sources.map(\.rawValue).joined(separator: ", ")
        return "[\(pairs)] from [\(sources)]"
    }
}

// MARK: - Input source switching

/// Selects the previously selected keyboard input source, as Caps Lock (with 'Use Caps Lock to
/// switch to and from ABC/last used') and a Globe tap set to 'Change Input Source' do, while the
/// 'Select the previous input source' shortcut is off (otherwise the injector posts it). The
/// history is kept from the system's selection-change notifications, delivered immediately even
/// while iKey (a menu-bar agent that is almost never active) is inactive. Main-queue confined.
private final class InputSourceHistory: NSObject {
    private struct Source {
        let id: String
        let ref: TISInputSource
        /// False for sources such as Korean 2-Set or Japanese Kana that cannot type ASCII.
        let asciiCapable: Bool
    }

    private static let abcID = "com.apple.keylayout.ABC"

    private var current: String?
    private var previous: String?
    /// The most recently seen source that cannot type ASCII, for the "to and from ABC" fallback.
    private var lastNonASCII: String?

    override init() {
        super.init()
        noteCurrent()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(selectionChanged(_:)),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func selectionChanged(_ notification: Notification) {
        if Thread.isMainThread {
            noteCurrent()
        } else {
            DispatchQueue.main.async { [weak self] in self?.noteCurrent() }
        }
    }

    /// What `selectPrevious` selected.
    struct Selection {
        let id: String
        /// False for sources such as Korean 2-Set or Japanese Kana that cannot type ASCII.
        let asciiCapable: Bool
    }

    /// Selects the previous source. Without a usable history: with exactly two selectable
    /// sources, the other one; with more, "to and from ABC" (from a non-ASCII source to ABC or
    /// another ASCII layout, otherwise to the last seen non-ASCII source, else the first one).
    /// nil when there is no target or TIS refuses the selection. Used only while the 'Select
    /// the previous input source' shortcut is off (see `EventInjector.selectPreviousInputSource`).
    func selectPrevious() -> Selection? {
        noteCurrent()
        guard let currentID = current else { return nil }
        let sources = Self.selectableSources()
        var target = sources.first { $0.id == previous && $0.id != currentID }
        if target == nil, let currentSource = sources.first(where: { $0.id == currentID }) {
            if sources.count == 2 {
                target = sources.first { $0.id != currentID }
            } else {
                target = asciiToggleTarget(from: currentSource, in: sources)
            }
        }
        guard let target, TISSelectInputSource(target.ref) == OSStatus(noErr) else { return nil }
        previous = currentID
        current = target.id
        if !target.asciiCapable { lastNonASCII = target.id }
        return Selection(id: target.id, asciiCapable: target.asciiCapable)
    }

    private func asciiToggleTarget(from currentSource: Source, in sources: [Source]) -> Source? {
        let others = sources.filter { $0.id != currentSource.id }
        if currentSource.asciiCapable {
            return others.first { $0.id == lastNonASCII && !$0.asciiCapable } ?? others.first { !$0.asciiCapable }
        }
        return others.first { $0.id == Self.abcID } ?? others.first { $0.asciiCapable }
    }

    private func noteCurrent() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = Self.id(of: source) else { return }
        if !Self.isASCIICapable(source) { lastNonASCII = id }
        guard id != current else { return }
        if current != nil { previous = current }
        current = id
    }

    private static func id(of source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// Unknown counts as ASCII-capable (a plain layout).
    private static func isASCIICapable(_ source: TISInputSource) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return true }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }

    /// Enabled keyboard layouts and input modes that can be selected.
    private static func selectableSources() -> [Source] {
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue(),
              let sources = list as? [TISInputSource] else { return [] }
        return sources.compactMap { source in
            id(of: source).map { Source(id: $0, ref: source, asciiCapable: isASCIICapable(source)) }
        }
    }
}

// MARK: - Key remap detection

/// Reads the user's key remapping from every layer posted events bypass. Safe off the main
/// queue. Merge order and conflict policy are `KeyRemap.merged`'s.
private enum KeyRemapReader {
    private static let hidutilTimeout: TimeInterval = 2.0
    private static let modifierMappingPrefix = "com.apple.keyboard.modifiermapping."

    /// Each layer's pairs as last read successfully.
    struct Layers {
        var hidutil: [UInt16: UInt16] = [:]
        var modifierKeys: [UInt16: UInt16] = [:]
        var karabiner: [UInt16: UInt16] = [:]

        func merged(manual: [UInt16: UInt16]?) -> KeyRemap {
            KeyRemap.merged(hidutil: hidutil, modifierKeys: modifierKeys, karabiner: karabiner, manual: manual)
        }
    }

    struct ReadResult {
        /// `lastGood` with every successfully read layer replaced.
        var layers: Layers
        /// Names of the layers whose read failed (they kept their `lastGood` pairs).
        var failed: [String]
    }

    /// Reads every layer. A layer whose read fails (hidutil cannot run or times out, or its
    /// system-wide query exits non-zero; karabiner.json exists but cannot be read or parsed;
    /// the Modifier Keys data cannot be serialised) keeps its `lastGood` pairs instead of
    /// counting as "no remap".
    /// Only a successful read that finds nothing (`(null)`, no file, no mappings) clears a layer.
    static func read(lastGood: Layers) -> ReadResult {
        var layers = lastGood
        var failed: [String] = []
        if let pairs = hidutil() { layers.hidutil = pairs } else { failed.append(KeyRemapSource.hidutil.rawValue) }
        if let pairs = modifierKeys() { layers.modifierKeys = pairs } else { failed.append(KeyRemapSource.modifierKeys.rawValue) }
        if let pairs = karabiner() { layers.karabiner = pairs } else { failed.append(KeyRemapSource.karabiner.rawValue) }
        return ReadResult(layers: layers, failed: failed)
    }

    /// The user's hidutil `UserKeyMapping` for the built-in keyboard; nil when it cannot be read.
    /// hidutil keeps the property in two scopes: `--set` alone writes the event system's
    /// (system-wide) property, while `--matching <service> --set` writes only the matching
    /// services' property, which the system-wide `--get` does not show (it prints `(null)`).
    /// LaunchAgent guides use both forms to remap only the internal keyboard, so both are read:
    /// - `hidutil property --get UserKeyMapping` (system-wide);
    /// - `hidutil property --matching '{"Built-In":true}' --get UserKeyMapping`, one row per
    ///   built-in service (keyboard, trackpad, ...), each `(null)` or a mapping array.
    ///   `parseHidutil` reads every `{...}` mapping block, so the rows merge.
    /// Policy: the union of both, the built-in services' pair winning for a source key both
    /// map (the narrower scope is the one the user aimed at the internal keyboard). When the
    /// scoped read also reports a system-wide mapping, the union is unchanged.
    /// The system-wide read must succeed (nil otherwise). For the scoped read, a timeout or
    /// launch failure fails the layer (it keeps its last good pairs), but a non-zero exit
    /// counts as no scoped mapping, so a hidutil that rejects the query (or finds no
    /// built-in service) cannot pin the layer to stale pairs.
    private static func hidutil() -> [UInt16: UInt16]? {
        // One budget for both runs, so the layer never takes longer than before.
        let deadline = DispatchTime.now() + hidutilTimeout
        guard let system = runHidutil(["property", "--get", "UserKeyMapping"], deadline: deadline),
              system.status == 0 else { return nil }
        guard let builtIn = runHidutil(["property", "--matching", #"{"Built-In":true}"#, "--get", "UserKeyMapping"],
                                       deadline: deadline) else { return nil }
        var pairs = KeyRemap.parseHidutil(system.output)
        if builtIn.status == 0 {
            pairs.merge(KeyRemap.parseHidutil(builtIn.output)) { _, scoped in scoped }
        }
        return pairs
    }

    /// Runs /usr/bin/hidutil; nil when it cannot launch or is still running at `deadline`
    /// (it is then killed).
    private static func runHidutil(_ arguments: [String], deadline: DispatchTime) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        // The output is at most a few kilobytes (one row per built-in service), well within the
        // pipe buffer, so it is read after the exit; a child that hangs (or blocks on a full
        // pipe) is killed at the deadline.
        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            return nil
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    /// System Settings > Keyboard > Modifier Keys for the built-in keyboard (ByHost globals);
    /// [:] when none are set, nil when the stored values cannot be serialised.
    private static func modifierKeys() -> [UInt16: UInt16]? {
        let app: CFString = kCFPreferencesAnyApplication, user: CFString = kCFPreferencesCurrentUser
        let host: CFString = kCFPreferencesCurrentHost
        CFPreferencesSynchronize(app, user, host)
        guard let keys = CFPreferencesCopyKeyList(app, user, host) as? [String] else { return [:] }
        var mappings: [String: Any] = [:]
        for key in keys where key.hasPrefix(modifierMappingPrefix) {
            if let value = CFPreferencesCopyValue(key as CFString, app, user, host) { mappings[key] = value }
        }
        guard !mappings.isEmpty else { return [:] }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: mappings, format: .binary, options: 0)
        else { return nil }
        return KeyRemap.parseModifierMappings(data, keyboard: builtInKeyboardID())
    }

    /// The built-in keyboard's decimal "<vendorID>-<productID>" from the IORegistry (no HID
    /// access permission needed); nil when none is found.
    private static func builtInKeyboardID() -> String? {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOHIDDevice")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard (property(service, "Built-In") as? NSNumber)?.boolValue == true,
                  (property(service, "PrimaryUsagePage") as? NSNumber)?.intValue == 1,
                  (property(service, "PrimaryUsage") as? NSNumber)?.intValue == 6,
                  let vendor = (property(service, "VendorID") as? NSNumber)?.intValue,
                  let product = (property(service, "ProductID") as? NSNumber)?.intValue else { continue }
            return "\(vendor)-\(product)"
        }
        return nil
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Karabiner-Elements simple modifications for the built-in keyboard; [:] without a
    /// karabiner.json, nil when it exists but cannot be read or is not valid JSON (e.g. caught
    /// mid-write).
    private static func karabiner() -> [UInt16: UInt16]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/karabiner/karabiner.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url),
              (try? JSONSerialization.jsonObject(with: data, options: [])) != nil else { return nil }
        return KeyRemap.parseKarabiner(data)
    }
}
