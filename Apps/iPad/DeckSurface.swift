import SwiftUI
import UIKit
import IKeyCore

struct DeckSurface: UIViewRepresentable {
    let image: UIImage?
    let layout: DeckLayout
    let inputEnabled: Bool
    let resetGeneration: Int
    let showRegions: Bool
    let selectedKeyID: String?
    let protection: TouchProtectionSettings
    let showTouchIndicators: Bool
    let onEvent: (InputEvent) -> Void

    // Drawn true-scale deck. Appended with defaults so existing call sites compile unchanged.
    /// nil = legacy photo/practice path.
    var drawn: DrawnDeckConfig? = nil
    /// Fit & Size live preview; overrides `drawn.placement` while non-nil.
    var previewPlacement: DeckPlacement? = nil
    /// Effective mode = inputEnabled ? inputMode : .off.
    var inputMode: DeckInputMode = .live
    var typing: TypingSettings = .init()
    var trackpad: TrackpadSettings = .init()
    var panelTriggerRaw: String = "touchIDHold"
    var capsLockOn: Bool = false
    var statusRing: StatusRingStyle = .live
    var dimmed: Bool = false
    /// 0...1.
    var keyboardGlow: Double = 0
    var onInputs: (([PadInput], TimeInterval) -> Void)? = nil
    var onRequestPanel: (() -> Void)? = nil
    /// Held key codes, held buttons, any active contact.
    var onHeldSnapshot: ((Set<UInt16>, Set<PointerButton>, Bool) -> Void)? = nil
    var onTouchWhileDisabled: (() -> Void)? = nil
    var onProjectionResolved: ((ProjectionResolution) -> Void)? = nil

    func makeUIView(context: Context) -> DeckTouchView { DeckTouchView() }

    func updateUIView(_ view: DeckTouchView, context: Context) {
        view.update(from: self)
    }

    static func dismantleUIView(_ uiView: DeckTouchView, coordinator: ()) {
        uiView.resetTouches(notify: true)
    }
}

/// The drawn MacBook deck: model, look and the committed placement.
struct DrawnDeckConfig: Equatable {
    var model: MacBookAirModel
    var finish: DeckFinish
    var tone: Double
    var placement: DeckPlacement
    var iPadOverrideID: String?
    var pressLook: PressLook
}

/// The deck surface. Drawn mode (`drawn != nil`, regions hidden) shows the true-scale MacBook deck as
/// pre-rendered layers: touches only toggle layers, nothing is repainted. Photo and calibration modes
/// paint the photo (or practice layout) in `PhotoCanvas`. Both feed `DeckInputEngine` with the touches'
/// own timestamps and every coalesced sample, and wake it with one deadline timer.
final class DeckTouchView: UIView {
    // MARK: Configuration (from `DeckSurface`)

    private var photo: UIImage?
    private var layout = DeckLayout.macBookANSI
    private var inputEnabled = false
    private var generation = -1
    private var showRegions = false
    private var selectedKeyID: String?
    private var protection = TouchProtectionSettings()
    private var showTouchIndicators = false
    private var drawn: DrawnDeckConfig?
    private var previewPlacement: DeckPlacement?
    private var inputMode: DeckInputMode = .live
    private var typing = TypingSettings()
    private var trackpad = TrackpadSettings()
    private var panelTriggerRaw = "touchIDHold"
    private var capsLockOn = false
    private var statusRing: StatusRingStyle = .live
    private var dimmed = false
    private var keyboardGlow = 0.0
    private var onEvent: (InputEvent) -> Void = { _ in }
    private var onInputs: (([PadInput], TimeInterval) -> Void)?
    private var onRequestPanel: (() -> Void)?
    private var onHeldSnapshot: ((Set<UInt16>, Set<PointerButton>, Bool) -> Void)?
    private var onTouchWhileDisabled: (() -> Void)?
    private var onProjectionResolved: ((ProjectionResolution) -> Void)?

    // MARK: Geometry

    private var environment: ScreenEnvironment?
    /// Resolution for `previewPlacement ?? drawn.placement`; nil in photo mode or before a window.
    private var resolution: ProjectionResolution?
    private var reportedResolution: ProjectionResolution?

    // MARK: Input

    private var engine: DeckInputEngine?
    private var engineKey: EngineKey?
    /// A typing/trackpad settings change is waiting for the engine to go idle (see `updateEngine`).
    private var engineRebuildDeferred = false
    private var appliedMode: DeckInputMode = .off
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 0
    private var keyVisual = KeyVisualState()
    private var lastHeldSnapshot: HeldSnapshot?
    private var deadlineTimer: DispatchSourceTimer?
    private var armedDeadline: TimeInterval?
    private var holdLink: CADisplayLink?
    private var holdProgress: Double?
    /// Outputs of the engine calls since the last delivery, and the timestamp of the latest call.
    /// One UIKit callback (or timer fire) delivers them once, so coalesced samples become one motion.
    private var pendingOutputs: [PadInput] = []
    private var pendingTime: TimeInterval?

    // MARK: Rendering

    private let photoCanvas = PhotoCanvas()
    /// Holds every deck layer; carries the Fit & Size preview transform.
    private let deckLayer = CALayer()
    private let dayBaseLayer = CALayer()
    private let nightBaseLayer = CALayer()
    private let legendLayer = CALayer()
    private let glowLayer = CALayer()
    private let keysLayer = CALayer()
    private let capsLEDLayer = CAShapeLayer()
    private let statusRingLayer = CAShapeLayer()
    private let dimLayer = CALayer()
    private let indicatorLayer = CALayer()
    private var keyLayers: [UInt16: CALayer] = [:]
    private var indicatorShapes: [CAShapeLayer] = []
    /// Keys currently drawn pressed (drawn and photo mode).
    private var shownPressed: Set<UInt16> = []
    /// The images on screen.
    private var shown: RenderedDeck?
    /// The newest wanted render: the one in flight, or the one queued behind it.
    private var requestedRender: RenderKey?
    /// True while a render runs; a newer request waits for it and only the latest one is rendered.
    private var renderInFlight = false
    /// Sequence number of the last render launched (monotonic).
    private var renderSequence = 0
    /// Sequence of what is on screen; a landing render at or below it is older and dropped.
    private var shownSequence = 0
    private var previewCommit: DispatchWorkItem?
    private var ringState: RingState = .hidden
    /// A deferred `becomeFirstResponder` is queued (see `claimFirstResponderSoon`).
    private var firstResponderClaimQueued = false

    private enum Look {
        static let previewCommitDelay: TimeInterval = 0.25
        static let pressFade: CFTimeInterval = 0.05
        static let capsGlowRadiusMM = 1.2, capsGlowOpacity: Float = 0.6
        static let legendGlowRadiusMM = 0.4
        static let ringDiameterMM = 9.3, ringLineWidthMM = 0.5
        static let ringRotation: CFTimeInterval = 1.2, ringBlinkPeriod: CFTimeInterval = 4
        static let amber = UIColor(red: 0xF5 / 255.0, green: 0xA6 / 255.0, blue: 0x23 / 255.0, alpha: 0.7)
        static let red = UIColor.systemRed
        static let paused = UIColor(white: 1, alpha: 0.4)
        static let holdFill = UIColor(white: 1, alpha: 0.85)
        static let dimOpacity: Float = 0.4
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = true
        backgroundColor = .black
        clipsToBounds = true

        photoCanvas.owner = self
        addSubview(photoCanvas)

        deckLayer.anchorPoint = .zero
        deckLayer.isHidden = true
        let deckSublayers: [CALayer] = [dayBaseLayer, nightBaseLayer, legendLayer, glowLayer, keysLayer,
                                        capsLEDLayer, statusRingLayer]
        for sublayer in deckSublayers { deckLayer.addSublayer(sublayer) }
        nightBaseLayer.opacity = 0
        glowLayer.opacity = 0
        glowLayer.shadowOpacity = 1
        glowLayer.shadowOffset = .zero
        capsLEDLayer.isHidden = true
        capsLEDLayer.shadowOffset = .zero
        statusRingLayer.isHidden = true
        statusRingLayer.fillColor = nil
        statusRingLayer.lineCap = .round
        dimLayer.backgroundColor = UIColor.black.cgColor
        dimLayer.opacity = 0
        layer.addSublayer(deckLayer)
        layer.addSublayer(dimLayer)
        layer.addSublayer(indicatorLayer)

        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
        accessibilityLabel = "MacBook keyboard and trackpad"
        accessibilityHint = "Hold the Touch ID key, or use the Open iKey settings action, for settings."
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Open iKey settings", target: self, selector: #selector(openSettingsAction)),
        ]
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    // MARK: - Configuration

    func update(from surface: DeckSurface) {
        let photoInputsChanged = surface.image !== photo || surface.layout != layout ||
            surface.showRegions != showRegions || surface.selectedKeyID != selectedKeyID
        let wasDrawn = isDrawnMode
        photo = surface.image
        layout = surface.layout
        inputEnabled = surface.inputEnabled
        generation = surface.resetGeneration
        showRegions = surface.showRegions
        selectedKeyID = surface.selectedKeyID
        protection = surface.protection
        showTouchIndicators = surface.showTouchIndicators
        drawn = surface.drawn
        previewPlacement = surface.previewPlacement
        inputMode = surface.inputMode
        typing = surface.typing
        trackpad = surface.trackpad
        panelTriggerRaw = surface.panelTriggerRaw
        capsLockOn = surface.capsLockOn
        statusRing = surface.statusRing
        dimmed = surface.dimmed
        keyboardGlow = surface.keyboardGlow
        onEvent = surface.onEvent
        onInputs = surface.onInputs
        onRequestPanel = surface.onRequestPanel
        onHeldSnapshot = surface.onHeldSnapshot
        onTouchWhileDisabled = surface.onTouchWhileDisabled
        onProjectionResolved = surface.onProjectionResolved

        refreshGeometry()
        applyAppearance()
        if !isDrawnMode && (photoInputsChanged || wasDrawn) { photoCanvas.setNeedsDisplay() }
        refreshAfterInput()
    }

    fileprivate var isDrawnMode: Bool { drawn != nil && !showRegions }

    #if DEBUG
    /// Integration-pass counters: every `PhotoCanvas.draw(_:)`, and those made while the deck is in
    /// drawn mode (which must stay 0; drawn mode never repaints). Read them in the debugger.
    static var debugPhotoDrawCount = 0
    static var debugDrawnModeDrawCount = 0
    #endif
    private var effectiveMode: DeckInputMode { inputEnabled ? inputMode : .off }

    private var displayScale: CGFloat {
        let scale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
        return scale > 0 ? scale : 2
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        photoCanvas.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        deckLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        deckLayer.position = bounds.origin
        dimLayer.frame = bounds
        indicatorLayer.frame = bounds
        CATransaction.commit()
        refreshGeometry()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            refreshGeometry()
            claimFirstResponderSoon()
        }
    }

    // MARK: - First responder (iPadOS three-finger editing gestures)

    /// Since iPadOS 13, UIKit turns three-finger gestures into editing commands app-wide (swipe left Undo,
    /// swipe right Redo, double-tap Undo, tap the shortcut bar, pinches Copy/Cut/Paste) and cancels the
    /// touches it claims, unless the responder chain from the first responder opts out. The deck forwards
    /// those very shapes to the Mac (Spaces swipes, Look Up tap, three-finger drag), so it opts out and
    /// holds first responder while its input is live. Only the input deck takes first responder, never a
    /// preview such as the calibration canvas.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    override var canBecomeFirstResponder: Bool { inputEnabled }

    /// Takes first responder now. Only while input is live: that requires a live link with no panel,
    /// Fit & Size or pairing card up, so no text field is being edited and none loses its keyboard.
    private func claimFirstResponderIfLive() {
        guard appliedMode == .live, window != nil, !isFirstResponder else { return }
        _ = becomeFirstResponder()
    }

    /// Takes first responder after the current SwiftUI update or layout pass (`applyMode` runs inside
    /// `updateUIView`), so the responder change never happens mid-update.
    private func claimFirstResponderSoon() {
        guard appliedMode == .live, !isFirstResponder, !firstResponderClaimQueued else { return }
        firstResponderClaimQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.firstResponderClaimQueued = false
            self.claimFirstResponderIfLive()
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            resetTouches(notify: true)
            previewCommit?.cancel()
            previewCommit = nil
        }
        super.willMove(toWindow: newWindow)
    }

    /// Resolves the projection, then brings the render, the engine and the input mode up to date.
    private func refreshGeometry() {
        resolveProjection()
        updateRender()
        applyMode()
        updateEngine()
    }

    private func resolveProjection() {
        guard let drawn, let window, let screen = window.windowScene?.screen,
              bounds.width > 0, bounds.height > 0 else {
            if drawn == nil { environment = nil; resolution = nil; reportedResolution = nil }
            return
        }
        let env = ScreenEnvironment(machineID: DeviceIdentity.machineID,
                                    nativePixels: screen.nativeBounds.size,
                                    nativeScale: Double(screen.nativeScale),
                                    windowPoints: window.bounds.size,
                                    viewOriginInWindow: convert(bounds.origin, to: window))
        let resolved = DeckGeometryResolver.resolve(spec: drawn.model.spec, env: env, overrideID: drawn.iPadOverrideID,
                                                    placement: previewPlacement ?? drawn.placement)
        environment = env
        resolution = resolved
        guard resolved != reportedResolution else { return }
        reportedResolution = resolved
        // Delivered after the current SwiftUI update or layout pass, which must not publish state.
        let callback = onProjectionResolved
        DispatchQueue.main.async { callback?(resolved) }
    }

    // MARK: - Engine and input modes

    private func currentEngineKey() -> EngineKey? {
        let deck: ResolvedDeck
        let trigger: PanelTrigger
        if isDrawnMode {
            guard let drawn, let resolution else { return nil }
            deck = ResolvedDeck(spec: drawn.model.spec, projection: resolution.projection)
            trigger = PanelTrigger(rawValue: panelTriggerRaw) ?? .touchIDHold
        } else {
            deck = ResolvedDeck(layout: layout, photoFrame: photoRect)
            // The photo has no Touch ID key.
            trigger = .palmRestTwoFingerHold
        }
        return EngineKey(generation: generation, deck: deck, protection: protection, typing: typing,
                         trackpad: trackpad, panelTrigger: trigger)
    }

    /// Rebuilds the engine whenever anything it depends on changes (the deck geometry covers the model,
    /// placement, preview, iPad override and projection), releasing everything the old one held.
    /// A change of typing or trackpad settings alone (the Mac's trackpad preferences or tap-only keys
    /// arrive in a MacState at any moment) waits until the engine is idle: like a MacBook, a setting
    /// takes effect from the next gesture instead of dropping a held click, drag or drag lock and the
    /// fingers on the glass.
    private func updateEngine() {
        guard let key = currentEngineKey(), key != engineKey else {
            engineRebuildDeferred = false
            return
        }
        if let current = engineKey, key.differsOnlyInSettings(from: current), engineIsBusy {
            engineRebuildDeferred = true
            return
        }
        engineRebuildDeferred = false
        resetTouches(notify: appliedMode != .off)
        var fresh = DeckInputEngine(deck: key.deck, protection: key.protection, typing: key.typing,
                                    trackpad: key.trackpad, panelTrigger: key.panelTrigger)
        if appliedMode == .panelOnly { _ = fresh.setInputSuppressed(true) }
        _ = fresh.drainSignals()
        engine = fresh
        engineKey = key
    }

    /// Contacts on the glass, keys or buttons held on the Mac (including a drag lock with no finger
    /// down), or a decision still pending (a tap awaiting its double-tap window, a key awaiting
    /// confirmation): rebuilding now would drop or release something mid-gesture.
    private var engineIsBusy: Bool {
        guard let engine else { return false }
        return !touchIDs.isEmpty || engine.hasActiveContacts || !engine.heldButtons.isEmpty
            || !engine.heldKeyCodes.isEmpty || engine.nextDeadline != nil
    }

    /// Applies a settings-only rebuild that `updateEngine` deferred, once the engine is idle.
    private func applyDeferredEngineUpdate() {
        guard engineRebuildDeferred, !engineIsBusy else { return }
        // Cleared first: the rebuild's own reset runs `refreshAfterInput` again.
        engineRebuildDeferred = false
        updateEngine()
    }

    /// `.live` runs the engine normally; `.panelOnly` suppresses it (the panel hold still works);
    /// `.off` forgets every touch and ignores new ones.
    private func applyMode() {
        let mode = effectiveMode
        guard mode != appliedMode else { return }
        let previous = appliedMode
        appliedMode = mode
        if mode == .off {
            resetTouches(notify: previous != .off)
        } else {
            let now = ProcessInfo.processInfo.systemUptime
            runEngine(at: now) { $0.setInputSuppressed(mode == .panelOnly) }
            flushOutputs()
            // Back to live (link up, panel/Fit & Size closed, app active): hold first responder again
            // before the next three-finger gesture, whatever took it meanwhile.
            if mode == .live { claimFirstResponderSoon() }
        }
    }

    /// Releases everything (via `onInputs`, or `onEvent` when nil) if `notify`, and forgets all touches.
    func resetTouches(notify: Bool) {
        flushOutputs()
        if var current = engine {
            let releases = current.reset()
            _ = current.drainSignals()
            engine = current
            if notify { deliver(releases, at: ProcessInfo.processInfo.systemUptime) }
        }
        touchIDs.removeAll()
        nextTouchID = 0
        cancelDeadlineTimer()
        keyVisual.reset()
        refreshAfterInput()
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let direct = touches.filter { $0.type == .direct }
        guard !direct.isEmpty, !showRegions else { return }
        if appliedMode != .live { onTouchWhileDisabled?() }
        guard appliedMode != .off, engine != nil else { return }
        // A touch event handler, not a SwiftUI update: reclaim synchronously, before UIKit's editing
        // recognizer can recognise a three-finger shape that starts with this touch.
        claimFirstResponderIfLive()
        for touch in direct.sorted(by: { $0.timestamp < $1.timestamp }) {
            nextTouchID += 1
            touchIDs[ObjectIdentifier(touch)] = nextTouchID
        }
        for group in timedSamples(direct, event: nil) {
            runEngine(at: group.time) { $0.begin(group.samples, at: group.time) }
        }
        refreshAfterInput()
    }

    /// Every coalesced sample reaches the engine, one `move` per timestamp; predicted touches are not used.
    /// The outputs of all of them are delivered once, coalesced, at the last sample's timestamp.
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !touchIDs.isEmpty else { return }
        for group in timedSamples(touches, event: event) {
            runEngine(at: group.time) { $0.move(group.samples, at: group.time) }
        }
        refreshAfterInput()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        guard !touchIDs.isEmpty else { return }
        for group in timedSamples(touches, event: nil) {
            runEngine(at: group.time) { $0.end(group.samples, at: group.time, cancelled: cancelled) }
        }
        for touch in touches { touchIDs.removeValue(forKey: ObjectIdentifier(touch)) }
        refreshAfterInput()
    }

    /// Samples of the known touches grouped by timestamp, oldest first. With an event, each touch
    /// contributes its coalesced samples.
    private func timedSamples(_ touches: Set<UITouch>, event: UIEvent?) -> [(time: TimeInterval, samples: [TouchSample])] {
        var byTime: [TimeInterval: [TouchSample]] = [:]
        for touch in touches {
            guard let id = touchIDs[ObjectIdentifier(touch)] else { continue }
            let coalesced = event?.coalescedTouches(for: touch) ?? []
            for sampleTouch in coalesced.isEmpty ? [touch] : coalesced {
                byTime[sampleTouch.timestamp, default: []].append(sample(sampleTouch, id: id))
            }
        }
        return byTime.keys.sorted().map { time in
            (time: time, samples: byTime[time, default: []].sorted { $0.id < $1.id })
        }
    }

    private func sample(_ touch: UITouch, id: Int) -> TouchSample {
        TouchSample(id: id, point: touch.location(in: self), radius: Double(touch.majorRadius),
                    radiusTolerance: Double(touch.majorRadiusTolerance))
    }

    // MARK: - Engine output

    /// One engine call: queues its inputs for `flushOutputs`, then handles its signals. A panel request
    /// delivers the inputs queued so far first, so inputs and the panel keep their order.
    private func runEngine(at time: TimeInterval, _ call: (inout DeckInputEngine) -> [PadInput]) {
        guard engine != nil else { return }
        pendingOutputs.append(contentsOf: call(&engine!))
        pendingTime = time
        var feedback: [KeyFeedback] = []
        var openPanel = false
        for signal in engine?.drainSignals() ?? [] {
            switch signal {
            case .openPanel: openPanel = true
            case .feedback(let item): feedback.append(item)
            }
        }
        keyVisual.apply(feedback, at: time)
        if openPanel {
            flushOutputs()
            onRequestPanel?()
        }
    }

    /// Delivers the queued engine outputs as one coalesced batch at the latest call's timestamp.
    private func flushOutputs() {
        guard let time = pendingTime else { return }
        let outputs = pendingOutputs
        pendingOutputs = []
        pendingTime = nil
        deliver(outputs, at: time)
    }

    private func deliver(_ outputs: [PadInput], at time: TimeInterval) {
        let inputs = PadInput.coalesced(outputs)
        guard !inputs.isEmpty else { return }
        if let onInputs {
            onInputs(inputs, time)
            return
        }
        // Legacy path (calibration preview): keys, buttons and release only.
        for input in inputs {
            switch input {
            case let .key(code, down): onEvent(.key(code: code, down: down))
            case let .button(button, down, _): onEvent(.button(button: button, down: down))
            case .releaseAll: onEvent(.releaseAll)
            case .motion, .scroll, .contacts, .gesture: break
            }
        }
    }

    /// Delivers the batch, then brings the visible state and the deadline timer up to date.
    private func refreshAfterInput() {
        flushOutputs()
        updatePressed()
        updateIndicators()
        updateHoldDisplay()
        reportHeldSnapshot()
        armDeadlineTimer()
        applyDeferredEngineUpdate()
    }

    private func reportHeldSnapshot() {
        let snapshot = HeldSnapshot(keys: engine?.heldKeyCodes ?? [], buttons: engine?.heldButtons ?? [],
                                    active: engine?.hasActiveContacts ?? false)
        guard snapshot != lastHeldSnapshot else { return }
        lastHeldSnapshot = snapshot
        onHeldSnapshot?(snapshot.keys, snapshot.buttons, snapshot.active)
    }

    // MARK: - Deadline timer

    /// One-shot timer at the engine's next deadline or the next pressed-key expiry, whichever is first.
    private func armDeadlineTimer() {
        guard let deadline = [engine?.nextDeadline, keyVisual.nextExpiry].compactMap({ $0 }).min() else {
            cancelDeadlineTimer()
            return
        }
        guard deadline != armedDeadline else { return }
        armedDeadline = deadline
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        if let deadlineTimer {
            deadlineTimer.schedule(deadline: .now() + delay, leeway: .milliseconds(1))
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { _ = self?.deadlineFired() }
        }
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(1))
        timer.resume()
        deadlineTimer = timer
    }

    private func cancelDeadlineTimer() {
        deadlineTimer?.cancel()
        deadlineTimer = nil
        armedDeadline = nil
    }

    private func deadlineFired() {
        // Never earlier than the deadline it was armed for, so the due transition always happens.
        let now = max(ProcessInfo.processInfo.systemUptime, armedDeadline ?? 0)
        armedDeadline = nil
        runEngine(at: now) { $0.advance(to: now) }
        keyVisual.apply([], at: now)
        refreshAfterInput()
    }

    // MARK: - Rendering

    private func currentRenderKey() -> RenderKey? {
        guard isDrawnMode, let drawn, let resolution, let environment,
              bounds.width > 0, bounds.height > 0 else { return nil }
        return RenderKey(look: LookKey(model: drawn.model, finish: drawn.finish, tone: drawn.tone,
                                       pressLook: drawn.pressLook, overrideID: drawn.iPadOverrideID,
                                       size: bounds.size, displayScale: displayScale),
                         environment: environment, projection: resolution.projection)
    }

    /// Renders on a change of look, size or screen at once; a placement-only change (Fit & Size
    /// preview or nudges) moves the current images with a layer transform and re-renders 250 ms after
    /// the last change.
    private func updateRender() {
        guard let key = currentRenderKey() else {
            if !isDrawnMode { clearRender() }
            return
        }
        updateDeckTransform()
        if key == requestedRender {
            previewCommit?.cancel()
            previewCommit = nil
        } else if let requested = requestedRender, requested.look == key.look, requested.environment == key.environment {
            schedulePreviewCommit()
        } else {
            startRender(key)
        }
    }

    private func schedulePreviewCommit() {
        previewCommit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { _ = self?.commitPreview() }
        }
        previewCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Look.previewCommitDelay, execute: work)
    }

    private func commitPreview() {
        previewCommit = nil
        if let key = currentRenderKey(), key != requestedRender { startRender(key) }
    }

    /// At most one render runs and at most one waits: a request made while a render runs only replaces
    /// `requestedRender`, and the newest request starts when the running one lands. A continuous change
    /// (tone slider, live resize) therefore never queues a backlog of superseded renders, and each render
    /// that lands is shown, so the deck follows the drag about once per render time.
    private func startRender(_ key: RenderKey) {
        previewCommit?.cancel()
        previewCommit = nil
        requestedRender = key
        launchRenderIfIdle()
    }

    private func launchRenderIfIdle() {
        guard !renderInFlight, let key = requestedRender, key != shown?.key else { return }
        renderInFlight = true
        renderSequence += 1
        let sequence = renderSequence
        SceneRenderer.renderAsync(key) { [weak self] deck in
            MainActor.assumeIsolated { _ = self?.renderLanded(deck, sequence: sequence) }
        }
    }

    private func renderLanded(_ deck: RenderedDeck, sequence: Int) {
        renderInFlight = false
        applyRendered(deck, sequence: sequence)
        launchRenderIfIdle()
    }

    private func clearRender() {
        previewCommit?.cancel()
        previewCommit = nil
        // The cleared deck counts as the newest display: a render still in flight lands as older.
        shownSequence = renderSequence
        guard shown != nil || requestedRender != nil else { return }
        shown = nil
        requestedRender = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for imageLayer in [dayBaseLayer, nightBaseLayer, legendLayer, glowLayer] { imageLayer.contents = nil }
        for keyLayer in keyLayers.values { keyLayer.removeFromSuperlayer() }
        keyLayers.removeAll()
        deckLayer.setAffineTransform(.identity)
        CATransaction.commit()
        configureCapsLED()
        configureRing()
    }

    /// Shows a landed render unless it is older than the one on screen. A render superseded by a newer
    /// request is still shown (an intermediate frame of a drag); the newer one follows it. After a
    /// clear, a render launched before it is still shown when it is exactly the one wanted again
    /// (a quick drawn → photo → drawn toggle), instead of being rendered a second time.
    private func applyRendered(_ deck: RenderedDeck, sequence: Int) {
        let wantedAfterClear = shown == nil && deck.key == requestedRender
        guard sequence > shownSequence || wantedAfterClear else { return }
        shownSequence = max(shownSequence, sequence)
        shown = deck
        let size = deck.key.look.size, scale = deck.key.look.displayScale
        let ppm = CGFloat(deck.key.projection.ppm)
        let full = CGRect(origin: .zero, size: size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let images: [(CALayer, CGImage?)] = [(dayBaseLayer, deck.dayBase), (nightBaseLayer, deck.nightBase),
                                             (legendLayer, deck.legends), (glowLayer, deck.glow)]
        for (imageLayer, image) in images {
            imageLayer.frame = full
            imageLayer.contents = image
            imageLayer.contentsScale = scale
        }
        glowLayer.shadowColor = cgColor(deck.nightPalette.legendGlow)
        glowLayer.shadowRadius = CGFloat(Look.legendGlowRadiusMM) * ppm
        glowLayer.shouldRasterize = true
        glowLayer.rasterizationScale = scale
        keysLayer.frame = full
        capsLEDLayer.frame = full
        capsLEDLayer.contentsScale = scale
        capsLEDLayer.path = UIBezierPath(ovalIn: deck.scene.capsLEDRect).cgPath

        let touchID = deck.scene.touchIDRect
        let diameter = CGFloat(Look.ringDiameterMM) * ppm, lineWidth = CGFloat(Look.ringLineWidthMM) * ppm
        let side = diameter + lineWidth
        statusRingLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        statusRingLayer.position = CGPoint(x: touchID.midX, y: touchID.midY)
        statusRingLayer.contentsScale = scale
        statusRingLayer.lineWidth = lineWidth
        // One clockwise circle from 12 o'clock; arcs and the hold fill are strokeEnd fractions of it.
        statusRingLayer.path = UIBezierPath(arcCenter: CGPoint(x: side / 2, y: side / 2), radius: diameter / 2,
                                            startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath

        rebuildKeyLayers(deck)
        updateDeckTransform()
        CATransaction.commit()

        configureCapsLED()
        configureRing(force: true)
    }

    /// One layer per key, cropped from the shared pressed atlas to exactly the key's frame (no margin:
    /// the up and down arrows touch), clipped to the image for the off-screen edge keys.
    private func rebuildKeyLayers(_ deck: RenderedDeck) {
        for keyLayer in keyLayers.values { keyLayer.removeFromSuperlayer() }
        keyLayers.removeAll()
        guard let atlas = deck.atlas else { return }
        let size = deck.key.look.size
        for (code, frame) in deck.scene.keyFrames {
            let minX = max(frame.minX, 0), minY = max(frame.minY, 0)
            let maxX = min(frame.maxX, size.width), maxY = min(frame.maxY, size.height)
            guard maxX > minX, maxY > minY else { continue }
            let visible = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            let keyLayer = CALayer()
            keyLayer.frame = visible
            keyLayer.contents = atlas
            keyLayer.contentsScale = deck.key.look.displayScale
            keyLayer.contentsRect = CGRect(x: minX / size.width, y: minY / size.height,
                                           width: visible.width / size.width, height: visible.height / size.height)
            keyLayer.opacity = shownPressed.contains(code) ? 1 : 0
            keysLayer.addSublayer(keyLayer)
            keyLayers[code] = keyLayer
        }
    }

    /// Maps the rendered projection onto the current one (identity unless a preview is in flight).
    private func updateDeckTransform() {
        var transform = CGAffineTransform.identity
        if let rendered = shown?.key.projection, let current = resolution?.projection, rendered != current {
            let scale = CGFloat(current.ppm / rendered.ppm)
            let origin = current.point(rendered.mm(.zero))
            transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: origin.x, ty: origin.y)
        }
        guard deckLayer.affineTransform() != transform else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        deckLayer.setAffineTransform(transform)
        CATransaction.commit()
    }

    // MARK: - Appearance

    private func applyAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photoCanvas.isHidden = isDrawnMode
        deckLayer.isHidden = !isDrawnMode
        CATransaction.commit()
        // Glow and dimming cross-fade with the layers' implicit animations.
        let glow = Float(keyboardGlow.isFinite ? min(max(keyboardGlow, 0), 1) : 0)
        if nightBaseLayer.opacity != glow {
            nightBaseLayer.opacity = glow
            glowLayer.opacity = glow
        }
        let dim = dimmed ? Look.dimOpacity : 0
        if dimLayer.opacity != dim { dimLayer.opacity = dim }
        configureCapsLED()
        configureRing()
    }

    private func configureCapsLED() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let shown, shown.scene.capsLEDRect.width > 0 else {
            capsLEDLayer.isHidden = true
            return
        }
        capsLEDLayer.isHidden = false
        let palette = shown.dayPalette
        capsLEDLayer.fillColor = cgColor(capsLockOn ? palette.capsLEDOn : palette.capsLEDOff)
        if capsLockOn {
            capsLEDLayer.shadowColor = cgColor(palette.capsLEDOn)
            capsLEDLayer.shadowRadius = CGFloat(Look.capsGlowRadiusMM * shown.key.projection.ppm)
            capsLEDLayer.shadowOpacity = Look.capsGlowOpacity
            capsLEDLayer.shadowPath = capsLEDLayer.path
        } else {
            capsLEDLayer.shadowOpacity = 0
        }
    }

    private enum RingState: Equatable {
        case hidden, hold
        case style(StatusRingStyle, reduceMotion: Bool)
    }

    /// The Touch ID status ring; a panel hold in progress replaces it with a clockwise fill.
    private func configureRing(force: Bool = false) {
        let state: RingState
        if shown == nil || !isDrawnMode {
            state = .hidden
        } else if holdProgress != nil {
            state = .hold
        } else {
            state = .style(statusRing, reduceMotion: UIAccessibility.isReduceMotionEnabled)
        }
        guard state != ringState || state == .hold || force else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if state == .hold, let holdProgress {
            statusRingLayer.strokeEnd = CGFloat(holdProgress)
        }
        guard state != ringState || force else { return }
        ringState = state
        statusRingLayer.removeAllAnimations()
        statusRingLayer.setAffineTransform(.identity)
        statusRingLayer.opacity = 1
        statusRingLayer.strokeStart = 0
        switch state {
        case .hidden, .style(.live, _):
            statusRingLayer.isHidden = true
        case .hold:
            statusRingLayer.isHidden = false
            statusRingLayer.strokeColor = Look.holdFill.cgColor
            statusRingLayer.strokeEnd = CGFloat(holdProgress ?? 0)
        case .style(.connecting, let reduceMotion):
            statusRingLayer.isHidden = false
            statusRingLayer.strokeColor = Look.amber.cgColor
            statusRingLayer.strokeEnd = reduceMotion ? 0.5 : 0.25
            if !reduceMotion {
                let spin = CABasicAnimation(keyPath: "transform.rotation")
                spin.fromValue = 0
                spin.toValue = 2 * Double.pi
                spin.duration = Look.ringRotation
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                statusRingLayer.add(spin, forKey: "spin")
            }
        case .style(.waiting, _):
            statusRingLayer.isHidden = false
            statusRingLayer.strokeColor = Look.amber.cgColor
            statusRingLayer.strokeEnd = 1
        case .style(.needsAction, _):
            statusRingLayer.isHidden = false
            statusRingLayer.strokeColor = Look.red.cgColor
            statusRingLayer.strokeEnd = 1
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1, 0.15, 1, 0.15, 1, 1]
            blink.keyTimes = [0, 0.03, 0.06, 0.09, 0.12, 1]
            blink.duration = Look.ringBlinkPeriod
            blink.repeatCount = .infinity
            blink.isRemovedOnCompletion = false
            statusRingLayer.add(blink, forKey: "blink")
        case .style(.paused, _):
            statusRingLayer.isHidden = false
            statusRingLayer.strokeColor = Look.paused.cgColor
            statusRingLayer.strokeEnd = 1
        }
    }

    // MARK: - Press feedback, indicators, panel hold

    /// Shows committed keys at once; released keys fade out over 50 ms. Tentative keys are not drawn.
    private func updatePressed() {
        let visible = keyVisual.visiblePressed(at: ProcessInfo.processInfo.systemUptime)
        guard visible != shownPressed else { return }
        let added = visible.subtracting(shownPressed), removed = shownPressed.subtracting(visible)
        shownPressed = visible
        guard isDrawnMode else {
            photoCanvas.setNeedsDisplay()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for code in added {
            keyLayers[code]?.removeAnimation(forKey: "opacity")
            keyLayers[code]?.opacity = 1
        }
        CATransaction.commit()
        guard !removed.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Look.pressFade)
        for code in removed { keyLayers[code]?.opacity = 0 }
        CATransaction.commit()
    }

    private func updateIndicators() {
        let show = showTouchIndicators && !showRegions && appliedMode != .off
        let items = show ? engine?.indicators ?? [] : []
        guard !items.isEmpty || indicatorShapes.contains(where: { !$0.isHidden }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while indicatorShapes.count < items.count {
            let shape = CAShapeLayer()
            shape.contentsScale = displayScale
            shape.lineWidth = 2
            indicatorLayer.addSublayer(shape)
            indicatorShapes.append(shape)
        }
        for (index, shape) in indicatorShapes.enumerated() {
            if index < items.count {
                configureIndicator(shape, items[index])
            } else {
                shape.isHidden = true
            }
        }
        CATransaction.commit()
    }

    /// Pending yellow dashed, accepted green, resting blue dotted, rejected red crossed.
    private func configureIndicator(_ shape: CAShapeLayer, _ item: DeckContactIndicator) {
        let r = CGFloat(min(120, max(6, item.radius)))
        let rect = CGRect(x: item.point.x - r, y: item.point.y - r, width: r * 2, height: r * 2)
        let path = UIBezierPath(ovalIn: rect)
        let color: UIColor
        var dash: [NSNumber]?
        switch item.disposition {
        case .pending:
            color = .systemYellow
            dash = [6, 4]
        case .accepted:
            color = .systemGreen
        case .resting:
            color = .systemBlue
            dash = [1, 5]
        case .rejected:
            color = .systemRed
            let d = r * 0.5
            path.move(to: CGPoint(x: rect.midX - d, y: rect.midY - d))
            path.addLine(to: CGPoint(x: rect.midX + d, y: rect.midY + d))
            path.move(to: CGPoint(x: rect.midX + d, y: rect.midY - d))
            path.addLine(to: CGPoint(x: rect.midX - d, y: rect.midY + d))
        }
        shape.isHidden = false
        shape.path = path.cgPath
        shape.strokeColor = color.cgColor
        shape.fillColor = color.withAlphaComponent(0.16).cgColor
        shape.lineDashPattern = dash
        shape.lineCap = item.disposition == .resting ? .round : .butt
    }

    /// While the panel hold runs, a display link fills the Touch ID ring with its progress.
    private func updateHoldDisplay() {
        let progress = isDrawnMode && appliedMode != .off
            ? engine?.panelHoldProgress(at: ProcessInfo.processInfo.systemUptime) : nil
        holdProgress = progress
        if progress != nil, holdLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(holdFrame))
            link.add(to: .main, forMode: .common)
            holdLink = link
        } else if progress == nil, let link = holdLink {
            link.invalidate()
            holdLink = nil
        }
        configureRing()
    }

    @objc private func holdFrame() { updateHoldDisplay() }

    @objc private func reduceMotionChanged() { configureRing(force: true) }

    @objc private func openSettingsAction() -> Bool {
        guard let onRequestPanel else { return false }
        onRequestPanel()
        return true
    }

    private func cgColor(_ c: RGBA) -> CGColor {
        UIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a)).cgColor
    }

    // MARK: - Photo and calibration drawing

    private var photoRect: CGRect {
        PhotoGeometry.aspectFit(imageSize: photo?.size ?? CGSize(width: 1440, height: 900), in: bounds)
    }

    /// Drawn by `PhotoCanvas`, which is hidden in drawn mode.
    fileprivate func drawPhotoDeck(in bounds: CGRect) {
        UIColor.black.setFill()
        UIRectFill(bounds)
        let deck = photoRect
        if let photo {
            photo.draw(in: deck)
        } else {
            UIColor(white: 0.64, alpha: 1).setFill()
            UIBezierPath(roundedRect: deck, cornerRadius: deck.width * 0.018).fill()
            for key in layout.keys {
                let frame = layout.frame(for: key).rect(in: deck)
                UIColor(white: 0.09, alpha: 1).setFill()
                UIBezierPath(roundedRect: frame, cornerRadius: max(2, frame.height * 0.12)).fill()
                drawLabel(key.label, in: frame, color: .white, size: max(8, min(18, frame.height * 0.31)))
            }
            let pad = layout.trackpad.rect(in: deck)
            UIColor(white: 0.4, alpha: 1).setStroke()
            let path = UIBezierPath(roundedRect: pad, cornerRadius: 7)
            path.lineWidth = 1.5
            path.stroke()
            drawLabel("Practice layout · import your MacBook photo in Settings", in: CGRect(x: deck.minX, y: deck.minY + 4, width: deck.width, height: 22), color: .black, size: 11)
        }

        if showRegions {
            stroke(layout.keyboard.rect(in: deck), color: .systemTeal, width: 2)
            let pad = layout.trackpad.rect(in: deck)
            UIColor.systemBlue.withAlphaComponent(0.18).setFill()
            UIRectFill(pad)
            stroke(pad, color: .systemBlue, width: 2)
            for key in layout.keys {
                let frame = layout.frame(for: key).rect(in: deck)
                let selected = key.id == selectedKeyID
                stroke(frame, color: selected ? .systemOrange : .systemTeal, width: selected ? 3 : 0.75)
                if selected {
                    UIColor.systemOrange.withAlphaComponent(0.25).setFill()
                    UIRectFill(frame)
                }
                if photo != nil { drawLabel(key.label, in: frame, color: .systemYellow, size: max(7, min(13, frame.height * 0.3))) }
            }
        } else {
            for key in layout.keys where shownPressed.contains(key.keyCode) {
                UIColor.white.withAlphaComponent(0.18).setFill()
                UIBezierPath(roundedRect: layout.frame(for: key).rect(in: deck), cornerRadius: 4).fill()
            }
        }
    }

    private func drawLabel(_ text: String, in rect: CGRect, color: UIColor, size: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let font = UIFont.systemFont(ofSize: size, weight: .medium)
        let textRect = CGRect(x: rect.minX + 2, y: rect.midY - font.lineHeight / 2,
                              width: max(0, rect.width - 4), height: font.lineHeight)
        (text as NSString).draw(in: textRect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    private func stroke(_ rect: CGRect, color: UIColor, width: CGFloat) {
        color.setStroke()
        let path = UIBezierPath(rect: rect)
        path.lineWidth = width
        path.stroke()
    }
}

/// Paints the photo/practice deck and the calibration regions; never shown in drawn mode.
private final class PhotoCanvas: UIView {
    weak var owner: DeckTouchView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func draw(_ rect: CGRect) {
        #if DEBUG
        DeckTouchView.debugPhotoDrawCount += 1
        if owner?.isDrawnMode == true {
            DeckTouchView.debugDrawnModeDrawCount += 1
            NSLog("iKey: PhotoCanvas.draw(_:) ran in drawn mode (%ld times)", DeckTouchView.debugDrawnModeDrawCount)
        }
        #endif
        owner?.drawPhotoDeck(in: bounds)
    }
}

/// Everything the input engine is built from.
private struct EngineKey: Equatable {
    var generation: Int
    var deck: ResolvedDeck
    var protection: TouchProtectionSettings
    var typing: TypingSettings
    var trackpad: TrackpadSettings
    var panelTrigger: PanelTrigger

    /// Only the typing or trackpad settings differ: nothing the deck's touches or geometry depend on.
    func differsOnlyInSettings(from other: EngineKey) -> Bool {
        generation == other.generation && deck == other.deck && protection == other.protection
            && panelTrigger == other.panelTrigger
    }
}

private struct HeldSnapshot: Equatable {
    var keys: Set<UInt16>
    var buttons: Set<PointerButton>
    var active: Bool
}

/// What the deck images depend on apart from the placement.
private struct LookKey: Equatable {
    var model: MacBookAirModel
    var finish: DeckFinish
    var tone: Double
    var pressLook: PressLook
    var overrideID: String?
    var size: CGSize
    var displayScale: CGFloat
}

private struct RenderKey: Equatable {
    var look: LookKey
    var environment: ScreenEnvironment
    var projection: DeckProjection
}

private struct RenderedDeck {
    let key: RenderKey
    let scene: DeckScene
    let dayPalette: DeckPalette
    let nightPalette: DeckPalette
    let dayBase: CGImage?
    let nightBase: CGImage?
    let legends: CGImage?
    let glow: CGImage?
    let atlas: CGImage?
}

/// Builds and rasterises the deck off the main thread.
private enum SceneRenderer {
    private static let queue = DispatchQueue(label: "ikey.deck-surface.render", qos: .userInitiated)

    /// Calls `completion` on the main queue. `DeckTouchView` keeps at most one call in flight.
    static func renderAsync(_ key: RenderKey, completion: @escaping (RenderedDeck) -> Void) {
        queue.async {
            let deck = render(key)
            DispatchQueue.main.async { completion(deck) }
        }
    }

    private static func render(_ key: RenderKey) -> RenderedDeck {
        let look = key.look
        let spec = look.model.spec
        let day = DeckPalette.palette(look.finish, tone: look.tone)
        let night = DeckPalette.palette(look.finish, tone: look.tone, night: 1)
        let viewBounds = CGRect(origin: .zero, size: look.size)
        let scale = Double(look.displayScale)
        let scene = DeckScene.build(spec: spec, projection: key.projection, palette: day, nightPalette: night,
                                    legendStyle: look.model.legendStyle, viewBounds: viewBounds,
                                    displayScale: scale, pressLook: look.pressLook)
        // The night base is the same base list in the night palette.
        let nightBase = DeckScene.build(spec: spec, projection: key.projection, palette: night, nightPalette: night,
                                        legendStyle: look.model.legendStyle, viewBounds: viewBounds,
                                        displayScale: scale, pressLook: .off).base
        func image(_ ops: [DrawOp], opaque: Bool) -> CGImage? {
            guard opaque || !ops.isEmpty else { return nil }
            return DeckArtist.render(ops, size: look.size, scale: look.displayScale, opaque: opaque,
                                     ppm: key.projection.ppm)
        }
        return RenderedDeck(key: key, scene: scene, dayPalette: day, nightPalette: night,
                            dayBase: image(scene.base, opaque: true),
                            nightBase: image(nightBase, opaque: true),
                            legends: image(scene.legends, opaque: false),
                            glow: image(scene.glow, opaque: false),
                            atlas: image(scene.pressedAtlas, opaque: false))
    }
}

enum DeviceIdentity {
    /// The `utsname.machine` identifier (e.g. "iPad16,5"); the simulated device's in the simulator.
    static let machineID: String = {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #endif
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "" }
        let machine = systemInfo.machine
        let capacity = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }()
}
