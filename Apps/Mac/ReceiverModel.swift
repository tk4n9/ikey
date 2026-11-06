import AppKit
import Combine
import CoreGraphics
import Foundation
import IKeyCore
import Network
import os
import Security
import ServiceManagement

/// The always-on receiver: persistent pairing key, Bonjour listener with a TXT identity, v2 sessions
/// (welcome, state, pong) under the ReceiverArbiter, Mac preference and key-remap mirroring, power
/// activity and pasteboard hardening. Network callbacks and state changes run on the main queue.
final class ReceiverModel: ObservableObject {
    /// Offer the ECDHE-PSK suite (forward secrecy). Off until the integration pass confirms the
    /// macOS loopback test on both ends.
    static let offerForwardSecrecyEnabled = false

    // MARK: Published state

    /// The receiver is on: not paused, key available, input permission granted, Mac awake.
    @Published private(set) var isListening = false
    @Published private(set) var isConnected = false
    @Published private(set) var hasInputPermission = false
    @Published private(set) var status = ""
    /// Bonjour instance name: the computer name (≤ 48 UTF-8 bytes) + " — iKey".
    @Published private(set) var serviceName: String
    @Published private var secret: PairingSecret? = nil

    /// Session-only pause (a relaunch always starts the receiver).
    @Published var isPaused = false {
        didSet { if isPaused != oldValue { updateReceiver() } }
    }
    @Published var peerToPeer: PeerToPeerSetting {
        didSet {
            guard peerToPeer != oldValue else { return }
            defaults.set(peerToPeer.rawValue, forKey: Keys.peerToPeer)
            if listener != nil { restartListenerNow() }
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { if !syncingLoginItem && launchAtLogin != oldValue { applyLoginItem() } }
    }
    /// Open at login is registered but waits for the user's approval in System Settings.
    @Published private(set) var loginItemNeedsApproval: Bool
    /// Pointer fine-tune on top of the Mac's tracking speed (0.75...1.25).
    @Published var gainScale: Double {
        didSet { defaults.set(gainScale, forKey: Keys.gainScale); applyTuning() }
    }
    /// Scroll speed factor (0.5...2.0).
    @Published var scrollSpeedFactor: Double {
        didSet { defaults.set(scrollSpeedFactor, forKey: Keys.scrollSpeedFactor); applyTuning() }
    }
    /// nil follows the Mac's settings.
    @Published var capsModePreference: CapsMode? {
        didSet {
            defaults.set(capsModePreference?.rawValue, forKey: Keys.capsMode)
            injector.setCapsModePreference(capsModePreference)
            refreshCapsMode()
            refreshCapsHardware()
        }
    }
    /// nil follows the Mac's settings.
    @Published var fnTapPreference: FnTapAction? {
        didSet {
            defaults.set(fnTapPreference?.rawValue, forKey: Keys.fnTap)
            injector.setFnTapPreference(fnTapPreference)
        }
    }
    @Published private(set) var connectedDeviceName: String? = nil
    @Published private(set) var capsMode: CapsMode
    /// In 'Switches input source' mode: the injector could not set the system Caps Lock, so a long
    /// press cannot toggle it (taps still switch the input source; amendments J and K).
    @Published private(set) var capsHardwareUnavailable = false
    /// A switch to a Korean/Chinese/Japanese input method had to use TISSelectInputSource because
    /// the 'Select the previous input source' shortcut is off; the menu asks to turn it on.
    @Published private(set) var inputSourceShortcutNeeded = false
    @Published private(set) var keychainProblem: String? = nil
    @Published private(set) var trackingIndexShown: Double
    /// "Use F1, F2, etc. keys as standard function keys" on this Mac (fnState).
    @Published private(set) var fnKeysStandard: Bool
    /// An iPad has connected with the current key.
    @Published private(set) var isPaired: Bool {
        didSet { defaults.set(isPaired, forKey: Keys.paired) }
    }
    /// pairAnotherIPad() was chosen and no new iPad has connected since: the UI shows Copy/Show.
    @Published private(set) var isPairingAnother = false

    /// The key remap v2 input mirrors: the Mac's detected layers plus the manual pairs, or empty
    /// while `applyKeyRemap` is off (the injector's effective remap).
    @Published private(set) var keyRemap = KeyRemap()
    /// The Mac's own remapping layers as detected, without manual pairs, also while
    /// `applyKeyRemap` is off.
    @Published private(set) var detectedKeyRemap = KeyRemap()
    /// The injector has finished its first remap read (`detectedKeyRemap` reflects the Mac).
    @Published private(set) var hasReadKeyRemap = false
    /// Mirror the Mac's key remapping (hidutil, Modifier Keys, Karabiner) and the manual pairs.
    @Published var applyKeyRemap: Bool {
        didSet {
            guard applyKeyRemap != oldValue else { return }
            defaults.set(applyKeyRemap, forKey: Keys.applyKeyRemap)
            applyKeyRemapOverride()
        }
    }
    /// Extra source → target keycode pairs (target `KeyRemap.noAction` disables the key; a key
    /// mapped to itself cancels a detected remap). Edited with set/removeManualRemap.
    @Published private(set) var manualKeyRemap: [UInt16: UInt16]

    /// The top-row strategies confirmed in 'Check Top-Row Keys' (persisted; a function without a
    /// choice uses its default chain).
    @Published var topRowChoices: TopRowChoices {
        didSet {
            guard topRowChoices != oldValue else { return }
            if let data = try? JSONEncoder().encode(topRowChoices) {
                defaults.set(data, forKey: TopRowChoices.storageKey)
            }
            injector.setTopRowChoices(topRowChoices.strategies())
        }
    }

    var pairingKey: String { secret?.hex ?? "" }

    let injector = EventInjector()

    // MARK: Private state

    private enum Keys {
        static let peerToPeer = "iKey.peerToPeer"
        static let gainScale = "iKey.gainScale"
        static let scrollSpeedFactor = "iKey.scrollSpeedFactor"
        static let capsMode = "iKey.capsModePreference"
        static let fnTap = "iKey.fnTapPreference"
        static let paired = "iKey.paired"
        static let applyKeyRemap = "iKey.keyRemap.apply"
        static let manualKeyRemap = "iKey.keyRemap.manual"
    }

    /// A transient status line, shown after the connected line while an iPad is connected.
    private enum Notice: Equatable {
        case dropped
        case pairAnother
        case pairingHint(host: String)
        case keyRotationFailed(OSStatus)

        var text: String {
            switch self {
            case .dropped: return "iPad disconnected. Waiting for it to reconnect."
            case .pairAnother: return "Copy the pairing key and paste it in iKey on the other iPad."
            case .pairingHint(let host):
                return "An iPad at \(host) could not connect. Paste this Mac's pairing key in iKey on that iPad."
            case .keyRotationFailed(let code):
                return "Could not save a new pairing key (error \(code)). The current key stays in effect."
            }
        }

        /// Hints that also clear by themselves after `noticeLifetime` (amendment J).
        var expires: Bool {
            switch self {
            case .pairingHint, .keyRotationFailed: return true
            case .dropped, .pairAnother: return false
            }
        }
    }

    private static let noticeLifetime: TimeInterval = 30
    private static let permissionText =
        "Allow iKey in System Settings → Privacy & Security → Accessibility, then choose Check Again."
    private static let log = Logger(subsystem: "com.ikey.mac", category: "receiver")

    /// One accepted connection, pending or active.
    private final class Session {
        let stream: MacLinkStream
        var tlsReady = false
        var sawFrame = false
        var hello: Hello?
        /// Set on promotion.
        var version: Int?
        /// The caps state last sent to this v2 session.
        var sentCaps: Bool?
        /// This side sent a goodbye; the stream closes once it is handed to the network.
        var goodbyeSent = false

        init(stream: MacLinkStream) { self.stream = stream }
    }

    private let defaults = UserDefaults.standard
    private let power = PowerActivity()
    private var readings: MacReadings
    private var arbiter = ReceiverArbiter()
    private var sessions: [UUID: Session] = [:]
    /// True while this side ends sessions on purpose (pause, sleep, new key, disconnect).
    private var endingDeliberately = false
    /// Cleared when it is acted on or a session goes live; hints also expire.
    private var notice: Notice? {
        didSet { scheduleNoticeExpiry() }
    }
    private var noticeExpiryWork: DispatchWorkItem?
    /// The iPad that was connected when pairAnotherIPad() was chosen: its reconnecting does not
    /// end pairing-another (only a different iPad does).
    private var pairingAnotherExcludedClient: UUID?

    private var listener: NWListener?
    private var listenerID: UUID?
    private var listenerReady = false
    private var listenerTrouble = false
    private var forceAnyPort = false
    private var backoff = ListenerBackoff()
    private var restartWork: DispatchWorkItem?
    private var wakeWork: DispatchWorkItem?
    private var isAsleep = false
    private let pathMonitor = NWPathMonitor()

    private let arbiterTimer = DispatchSource.makeTimerSource(queue: .main)
    private var armedDeadline: Double?
    private var slowTimer: Timer?
    private var capsTimer: Timer?

    private var copiedChangeCount: Int?
    private var clearPasteboardWork: DispatchWorkItem?
    private var syncingLoginItem = false

    /// Sorted deck codes the iPad must type as taps only (from the effective remap). nil until
    /// the injector's first remap read finished, so MacState leaves the iPad's persisted set
    /// unchanged instead of clearing it (amendments H and K).
    private var tapOnlyCodes: [UInt16]?
    /// The effective remap map the last tap-only codes were computed from.
    private var mirroredRemapMap: [UInt16: UInt16]?

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let readings = MacPreferencesReader.read()
        self.readings = readings
        serviceName = ReceiverModel.serviceName(for: readings.computerName)
        trackingIndexShown = readings.liveCurves.trackingIndex ?? readings.prefs.trackingIndex
        let defaults = UserDefaults.standard
        peerToPeer = defaults.string(forKey: Keys.peerToPeer).flatMap(PeerToPeerSetting.init(rawValue:)) ?? .automatic
        let loginStatus = SMAppService.mainApp.status
        launchAtLogin = Self.loginItemEnabled(loginStatus)
        loginItemNeedsApproval = loginStatus == .requiresApproval
        fnKeysStandard = readings.prefs.fnKeysStandard
        gainScale = defaults.object(forKey: Keys.gainScale) as? Double ?? 1
        scrollSpeedFactor = defaults.object(forKey: Keys.scrollSpeedFactor) as? Double ?? 1
        capsModePreference = defaults.string(forKey: Keys.capsMode).flatMap(CapsMode.init(rawValue:))
        fnTapPreference = defaults.string(forKey: Keys.fnTap).flatMap(FnTapAction.init(rawValue:))
        isPaired = defaults.bool(forKey: Keys.paired)
        capsMode = .system
        applyKeyRemap = defaults.object(forKey: Keys.applyKeyRemap) as? Bool ?? true
        manualKeyRemap = Self.decodeManualRemap(defaults.dictionary(forKey: Keys.manualKeyRemap))
        topRowChoices = defaults.data(forKey: TopRowChoices.storageKey)
            .flatMap { try? JSONDecoder().decode(TopRowChoices.self, from: $0) } ?? TopRowChoices()

        injector.onHeldInputChanged = { [weak self] held in self?.drive(.heldInputChanged(held)) }
        // Fires after the first remap read (also when it finds nothing) and on every change of
        // the detected or effective remap, also for override changes before that read. The remap
        // is read only from pollPreferences while listening (amendment J).
        injector.onKeyRemapChanged = { [weak self] _ in self?.keyRemapChanged() }
        // The Mac's readings without a remap read (idle spawns no hidutil): the Caps Lock mode,
        // the fn-tap action and top-row Try's hot keys follow this Mac before listening starts.
        injector.setReadings(readings)
        applyKeyRemapOverride()
        injector.setTopRowChoices(topRowChoices.strategies())
        injector.setCapsModePreference(capsModePreference)
        injector.setFnTapPreference(fnTapPreference)
        applyTuning()
        refreshCapsMode()

        arbiterTimer.setEventHandler { [weak self] in
            guard let self else { return }
            self.armedDeadline = nil
            self.drive(.tick)
        }
        arbiterTimer.schedule(deadline: .distantFuture)
        arbiterTimer.resume()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied, self.wantsListener, self.listener == nil else { return }
            self.restartListenerNow()
        }
        pathMonitor.start(queue: .main)

        observe(NotificationCenter.default, NSApplication.willTerminateNotification) { model in
            // The permanent key must not outlive iKey on the pasteboard.
            model.clearCopiedKey()
            model.shutDown(.receiverStopping)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { model in
            model.wakeWork?.cancel()
            model.isAsleep = true
            model.updateReceiver(stopReason: .macSleeping)
        }
        observe(workspace, NSWorkspace.didWakeNotification) { model in model.scheduleWake() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { model in model.scheduleWake() }

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.slowPoll() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        slowTimer = timer

        loadKey()
        hasInputPermission = CGPreflightPostEventAccess()
        updateReceiver()
    }

    deinit {
        slowTimer?.invalidate()
        capsTimer?.invalidate()
        arbiterTimer.cancel()
        pathMonitor.cancel()
        restartWork?.cancel()
        wakeWork?.cancel()
        clearPasteboardWork?.cancel()
        noticeExpiryWork?.cancel()
        for (center, observer) in observers { center.removeObserver(observer) }
        listener?.cancel()
    }

    // MARK: Kept API

    func refreshPermission() {
        let granted = CGPreflightPostEventAccess()
        guard granted != hasInputPermission else { return }
        hasInputPermission = granted
        updateReceiver()
    }

    func requestInputPermission() {
        _ = CGRequestPostEventAccess()
        refreshPermission()
    }

    func showAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// Copies the key as a concealed, transient pasteboard item, cleared after the next pairing or
    /// after 60 s (only if nothing else was copied since).
    func copyPairingKey() {
        guard let secret else { return }
        // Copying the key is what a pairing hint asks for.
        if case .pairingHint? = notice {
            notice = nil
            refreshStatus()
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(secret.hex, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
        copiedChangeCount = pasteboard.changeCount
        clearPasteboardWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.clearCopiedKey() }
        clearPasteboardWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    /// Replaces the key (also while listening): paired iPads get an authenticated goodbye(.unpaired)
    /// and the listener restarts with the new key. On a Keychain failure the old key stays.
    func rotatePairingKey() {
        switch MacKeychain.rotatePSK() {
        case .loaded(let newSecret), .created(let newSecret):
            clearCopiedKey()
            endSessions(.unpaired)
            secret = newSecret
            keychainProblem = nil
            isPaired = false
            isPairingAnother = false
            pairingAnotherExcludedClient = nil
            notice = nil
            if listener != nil || restartWork != nil { restartListenerNow() }
            updateReceiver()
        case .unavailable(let code):
            notice = .keyRotationFailed(code)
            refreshStatus()
        }
    }

    /// Resume shim.
    func start() {
        refreshPermission()
        isPaused = false
    }

    /// Pause shim (used before quitting).
    func stop() {
        isPaused = true
    }

    /// Ends the current session; the iPad waits until its deck is touched.
    func disconnect() {
        endSessions(.user)
        refreshStatus()
    }

    // MARK: Added API

    /// Repeats the Keychain load after the user allowed access.
    func retryKeychain() {
        loadKey()
        updateReceiver()
    }

    /// Reveals the pairing key controls while already paired.
    func pairAnotherIPad() {
        isPairingAnother = true
        pairingAnotherExcludedClient = arbiter.activeID.flatMap { sessions[$0]?.hello?.client }
        notice = .pairAnother
        refreshStatus()
    }

    /// Ends pair-another without a new iPad (the panel's Done): hides the key controls, drops the
    /// instructions and clears a copied key from the clipboard.
    func finishPairingAnother() {
        guard isPairingAnother else { return }
        isPairingAnother = false
        pairingAnotherExcludedClient = nil
        if notice == .pairAnother { notice = nil }
        clearCopiedKey()
        refreshStatus()
    }

    /// Posts one top-row function with `s` as a down then an up ('Check Top-Row Keys').
    func tryTopRow(_ f: TopRowFunction, _ s: TopRowStrategy) {
        guard hasInputPermission else { return }
        injector.postTopRowTest(f, strategy: s)
    }

    /// Adds or replaces a manual remap pair (source → target keycode).
    func setManualRemap(_ source: UInt16, to target: UInt16) {
        guard manualKeyRemap[source] != target else { return }
        manualKeyRemap[source] = target
        manualRemapChanged()
    }

    func removeManualRemap(_ source: UInt16) {
        guard manualKeyRemap.removeValue(forKey: source) != nil else { return }
        manualRemapChanged()
    }

    /// Re-reads the Open at login state (the user may have approved or removed it in System Settings).
    func refreshLoginItem() {
        syncLoginItem(SMAppService.mainApp.status)
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// A build run from Xcode's DerivedData: Open at login would register a copy that moves or
    /// disappears with the next clean build.
    var runsFromBuildFolder: Bool { Bundle.main.bundlePath.contains("/DerivedData/") }

    // MARK: Receiver lifecycle

    private var wantsListener: Bool {
        !isPaused && secret != nil && hasInputPermission && !isAsleep
    }

    private func loadKey() {
        switch MacKeychain.loadOrCreatePSK() {
        case .loaded(let loaded):
            secret = loaded
            keychainProblem = nil
        case .created(let created):
            secret = created
            keychainProblem = nil
            isPaired = false
        case .unavailable(let code):
            // Never invent a key here: every paired iPad would be locked out.
            secret = nil
            keychainProblem = code == errSecDecode
                ? "iKey's saved pairing key cannot be read (error \(code)). Retry, or choose New Key to reset pairing."
                : "Allow iKey to use its keychain item (error \(code)), then Retry"
        }
    }

    /// Starts or stops the receiver to match `wantsListener`.
    private func updateReceiver(stopReason: GoodbyeReason = .receiverStopping) {
        if wantsListener {
            if listener == nil && restartWork == nil { startListener() }
            if !isListening {
                isListening = true
                pollPreferences()
            }
        } else if isListening || listener != nil || restartWork != nil || !sessions.isEmpty {
            isListening = false
            shutDown(stopReason)
        }
        refreshStatus()
    }

    private func shutDown(_ reason: GoodbyeReason) {
        endSessions(reason)
        for session in Array(sessions.values) where !session.goodbyeSent { session.stream.cancel() }
        restartWork?.cancel()
        restartWork = nil
        tearDownListener()
        listenerTrouble = false
    }

    /// Releases input, says goodbye to the active session and cancels pending handshakes.
    private func endSessions(_ reason: GoodbyeReason) {
        endingDeliberately = true
        drive(.stop(reason))
        endingDeliberately = false
    }

    private func scheduleWake() {
        wakeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wakeWork = nil
            if self.isAsleep {
                self.isAsleep = false
                self.updateReceiver()
            } else if self.wantsListener && !self.listenerReady {
                self.restartListenerNow()
            }
        }
        wakeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Listener

    private func startListener() {
        guard listener == nil, let secret else { return }
        let parameters = SecureParameters.make(secret: secret, peerToPeer: peerToPeer != .never,
                                               offerForwardSecrecy: Self.offerForwardSecrecyEnabled)
        parameters.allowLocalEndpointReuse = true
        let savedPort = forceAnyPort ? nil : MacKeychain.savedPort.flatMap { NWEndpoint.Port(rawValue: $0) }
        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters, on: savedPort ?? .any)
        } catch {
            listenerFailed(error as? NWError)
            return
        }
        let id = UUID()
        listenerID = id
        listener = newListener
        newListener.service = NWListener.Service(
            name: serviceName, type: IKeyService.bonjourType, domain: nil,
            txtRecord: NWTXTRecord([TXTRecordKeys.proto: String(WireV2.version),
                                    TXTRecordKeys.macID: MacKeychain.macID.uuidString]))
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self, self.listenerID == id else { return }
            switch state {
            case .ready:
                self.listenerReady = true
                self.listenerTrouble = false
                self.forceAnyPort = false
                self.backoff.reset()
                if let port = self.listener?.port?.rawValue { MacKeychain.savedPort = port }
                self.refreshStatus()
            case .waiting(let error), .failed(let error):
                self.listenerFailed(error)
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        newListener.start(queue: .main)
    }

    /// Restarts after a backoff delay; a busy saved port falls back to any port at once.
    private func listenerFailed(_ error: NWError?) {
        tearDownListener()
        guard wantsListener else { return }
        if case .posix(.EADDRINUSE)? = error, !forceAnyPort {
            forceAnyPort = true
            startListener()
            return
        }
        listenerTrouble = true
        refreshStatus()
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWork = nil
            if self.wantsListener { self.startListener() }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff.nextDelay(), execute: work)
    }

    private func restartListenerNow() {
        restartWork?.cancel()
        restartWork = nil
        tearDownListener()
        if wantsListener { startListener() }
    }

    /// Cancels the listener only; accepted connections stay up.
    private func tearDownListener() {
        listenerID = nil
        listenerReady = false
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    // MARK: Sessions

    private func accept(_ connection: NWConnection) {
        guard wantsListener else {
            connection.cancel()
            return
        }
        let id = UUID()
        let stream = MacLinkStream(connection: connection)
        let session = Session(stream: stream)
        sessions[id] = session
        stream.onReady = { [weak self, weak session] in
            session?.tlsReady = true
            self?.drive(.tlsReady(id: id))
        }
        stream.onMessage = { [weak self] message in self?.received(message, on: id) }
        stream.onClose = { [weak self] reason in self?.streamClosed(id, reason: reason) }
        drive(.accepted(id: id, remoteHost: ReceiverArbiter.hostKey(fromEndpointDescription: "\(connection.endpoint)")))
        stream.start()
    }

    private func received(_ message: PadMessage, on id: UUID) {
        guard let session = sessions[id] else { return }
        guard arbiter.activeID == id else {
            firstFrame(message, of: session, id: id)
            return
        }
        switch message {
        case .input, .heartbeat, .legacy:
            if hasInputPermission { injector.handle(message) }
            drive(.frame(id: id))
        case .ping(let pingID, let t):
            session.stream.send([.pong(id: pingID, echoT: t, macT: Self.micros(Self.clock()))])
            drive(.frame(id: id))
        case .hello, .unknown:
            drive(.frame(id: id))
        case .goodbye:
            break // The stream closes itself after delivering it.
        }
    }

    /// The first frame decides the protocol: a v2 hello or a v1 frame; anything else is refused.
    private func firstFrame(_ message: PadMessage, of session: Session, id: UUID) {
        guard !session.sawFrame else { return }
        session.sawFrame = true
        switch message {
        case .hello(let hello):
            guard hello.proto >= WireV2.version else {
                session.stream.send([.goodbye(.protocolMismatch)])
                return
            }
            session.hello = hello
            drive(.helloVerified(id: id))
        case .legacy:
            drive(.legacyFrame(id: id))
            if arbiter.activeID == id && hasInputPermission { injector.handle(message) }
        case .goodbye:
            return
        case .input, .heartbeat, .ping, .unknown:
            session.stream.send([.goodbye(.protocolMismatch)])
            return
        }
        // Not promoted (its handshake slot expired or was taken): drop it.
        if arbiter.activeID != id { session.stream.cancel() }
    }

    private func streamClosed(_ id: UUID, reason: LinkCloseReason) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        if case .failed = reason, !session.tlsReady {
            drive(.handshakeFailed(id: id))
        } else {
            drive(.closed(id: id))
        }
        if session.version != nil { power.sessionEnded(id) }
    }

    private func drive(_ input: ArbiterInput) {
        for command in arbiter.handle(input, now: Self.clock()) { execute(command) }
        syncConnection()
        armArbiterTimer()
    }

    private func execute(_ command: ArbiterCommand) {
        switch command {
        case .cancel(let id), .close(let id):
            guard let session = sessions[id] else { break }
            if session.goodbyeSent {
                // Cancelling now could drop the goodbye; give it a moment to be written.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak session] in session?.stream.cancel() }
            } else {
                session.stream.cancel()
            }
        case .promote(let id, let version):
            promoted(id, version: version)
        case .sendGoodbye(let id, let reason):
            // A v1 iPad cannot decode a v2 goodbye; it is closed next anyway.
            if let session = sessions[id], (session.version ?? 0) >= 2 {
                session.goodbyeSent = true
                session.stream.send([.goodbye(reason)])
            }
        case .releaseAllInput:
            injector.releaseAll()
        case .showPairingHint(let host):
            notice = .pairingHint(host: host)
            refreshStatus()
        }
    }

    private func promoted(_ id: UUID, version: Int) {
        guard let session = sessions[id] else { return }
        session.version = version
        isPaired = true
        connectedDeviceName = session.hello.map { $0.device.isEmpty ? "iPad" : $0.device } ?? "iPad"
        power.sessionStarted(id)
        // The already-paired iPad reconnecting while another is being paired keeps the key
        // controls, the pair-another instructions and the copied key; any other iPad ends
        // pairing-another. Either way a live session clears drop notices and hints.
        let samePadReconnected = isPairingAnother && pairingAnotherExcludedClient != nil
            && session.hello?.client == pairingAnotherExcludedClient
        if !samePadReconnected {
            isPairingAnother = false
            pairingAnotherExcludedClient = nil
            notice = nil
            clearCopiedKey()
        } else {
            notice = .pairAnother
        }
        refreshStatus()
        guard version >= 2 else { return }
        let caps = injector.capsLockOn
        session.sentCaps = caps
        session.stream.send([.welcome(welcome(caps: caps)), stateMessage()])
    }

    private func welcome(caps: Bool) -> Welcome {
        let display = readings.builtInDisplayMM.flatMap { size in
            size.count == 2 && size.allSatisfy({ $0 > 0 && $0 <= 5000 }) ? size : nil
        }
        return Welcome(proto: WireV2.version, mac: MacKeychain.macID,
                       name: Self.truncated(readings.computerName, maxUTF8Bytes: 64),
                       model: Self.truncated(readings.hardwareModel, maxUTF8Bytes: 64),
                       keyboard: readings.keyboard, displayMM: display, prefs: readings.prefs.clamped(),
                       caps: caps, features: WireFeature.all)
    }

    /// Every MacState carries the tap-only codes (amendment H).
    private func stateMessage(caps: Bool? = nil, prefs: MacInputPreferences? = nil) -> MacMessage {
        .state(MacState(caps: caps, prefs: prefs, tapOnly: tapOnlyCodes))
    }

    private var activeV2Session: Session? {
        guard let id = arbiter.activeID, let session = sessions[id], (session.version ?? 0) >= 2 else { return nil }
        return session
    }

    /// Mirrors the arbiter's active session into the published state and the caps poll.
    private func syncConnection() {
        let connected = arbiter.activeID != nil
        if connected != isConnected {
            isConnected = connected
            if !connected {
                connectedDeviceName = nil
                if !endingDeliberately { notice = .dropped }
            }
            refreshStatus()
        }
        let wantsCapsPoll = activeV2Session != nil
        if wantsCapsPoll && capsTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.pollCaps() }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            capsTimer = timer
        } else if !wantsCapsPoll, let timer = capsTimer {
            timer.invalidate()
            capsTimer = nil
        }
    }

    /// One-shot timer at the arbiter's next deadline; moved only when a deadline comes earlier
    /// (a tick before anything is due is harmless and re-arms).
    private func armArbiterTimer() {
        guard let deadline = arbiter.nextDeadline else { return }
        if let armed = armedDeadline, armed <= deadline { return }
        armedDeadline = deadline
        arbiterTimer.schedule(deadline: .now() + max(0, deadline - Self.clock()), leeway: .milliseconds(5))
    }

    // MARK: Polling

    /// Every 2 s. While listening it is the only trigger of the injector's remap read
    /// (hidutil, Modifier Keys, Karabiner); idle, nothing is read (amendment J).
    private func slowPoll() {
        refreshPermission()
        refreshCapsMode()
        refreshCapsHardware()
        if isListening { pollPreferences() }
    }

    private func pollPreferences() {
        let fresh = MacPreferencesReader.read()
        // Every poll, also when the readings are unchanged: this re-reads the key remap
        // (hidutil, Modifier Keys, Karabiner are not part of MacReadings; amendment C). Equal
        // settings make the injector's rebuild a no-op; the remap read runs off-main.
        injector.apply(readings: fresh)
        refreshCapsMode()
        refreshCapsHardware()
        guard fresh != readings else { return }
        let prefsChanged = fresh.prefs != readings.prefs
        let nameChanged = fresh.computerName != readings.computerName
        readings = fresh
        let shownIndex = fresh.liveCurves.trackingIndex ?? fresh.prefs.trackingIndex
        if shownIndex != trackingIndexShown { trackingIndexShown = shownIndex }
        if fresh.prefs.fnKeysStandard != fnKeysStandard { fnKeysStandard = fresh.prefs.fnKeysStandard }
        if prefsChanged { activeV2Session?.stream.send([stateMessage(prefs: fresh.prefs.clamped())]) }
        if nameChanged {
            serviceName = Self.serviceName(for: fresh.computerName)
            if listener != nil { restartListenerNow() }
        }
    }

    private func pollCaps() {
        refreshCapsMode()
        guard let session = activeV2Session else { return }
        let caps = injector.capsLockOn
        guard caps != session.sentCaps else { return }
        session.sentCaps = caps
        session.stream.send([stateMessage(caps: caps)])
    }

    private func refreshCapsMode() {
        let mode = injector.effectiveCapsMode
        if mode != capsMode { capsMode = mode }
    }

    /// The injector only falls back to virtual in `.system` mode; in `.switchesInputSource` a
    /// failed hardware set just loses the long-press toggle, which the menu says (amendment K).
    private func refreshCapsHardware() {
        let unavailable = capsMode == .switchesInputSource && injector.capsHardwareSetFailed
        if unavailable != capsHardwareUnavailable { capsHardwareUnavailable = unavailable }
        let shortcutNeeded = injector.inputSourceShortcutNeeded
        if shortcutNeeded != inputSourceShortcutNeeded { inputSourceShortcutNeeded = shortcutNeeded }
    }

    private func applyTuning() {
        injector.setTuning(gainScale: min(max(gainScale, 0.75), 1.25),
                           scrollSpeedFactor: min(max(scrollSpeedFactor, 0.5), 2.0))
    }

    // MARK: Key remap

    /// Publishes the injector's remaps on every call (the menu shows override changes at once),
    /// but computes the tap-only codes and resends MacState(tapOnly:) to a v2 iPad only once the
    /// first remap read finished (amendments H and K): before it, MacState carries nil so the
    /// iPad keeps its persisted set. The first read always reports, so the first set is never
    /// missed; from then on an empty set is sent explicitly, clearing a stale one on the iPad.
    private func keyRemapChanged() {
        let remap = injector.keyRemap
        if remap != keyRemap { keyRemap = remap }
        let detected = injector.detectedKeyRemap
        if detected != detectedKeyRemap { detectedKeyRemap = detected }
        let read = injector.hasReadKeyRemap
        if read != hasReadKeyRemap { hasReadKeyRemap = read }
        guard read, remap.map != mirroredRemapMap else { return }
        mirroredRemapMap = remap.map
        tapOnlyCodes = remap.tapOnlyPadCodes.sorted()
        activeV2Session?.stream.send([stateMessage()])
    }

    /// Hands the toggle and the manual pairs to the injector; its change callback (and the
    /// direct call here, for an unchanged map) updates the published remap and the iPad.
    private func applyKeyRemapOverride() {
        injector.setKeyRemapOverride(apply: applyKeyRemap, manual: manualKeyRemap.isEmpty ? nil : manualKeyRemap)
        keyRemapChanged()
    }

    private func manualRemapChanged() {
        defaults.set(Dictionary(uniqueKeysWithValues: manualKeyRemap.map { (String($0.key), Int($0.value)) }),
                     forKey: Keys.manualKeyRemap)
        applyKeyRemapOverride()
    }

    /// Stored as ["<source>": target]; malformed entries are skipped.
    private static func decodeManualRemap(_ stored: [String: Any]?) -> [UInt16: UInt16] {
        var pairs: [UInt16: UInt16] = [:]
        for (key, value) in stored ?? [:] {
            guard let source = UInt16(key), let target = (value as? NSNumber).flatMap({ UInt16(exactly: $0.intValue) })
            else { continue }
            pairs[source] = target
        }
        return pairs
    }

    // MARK: Pasteboard, login item, status

    /// Clears the copied key if the pasteboard still holds it.
    private func clearCopiedKey() {
        clearPasteboardWork?.cancel()
        clearPasteboardWork = nil
        guard let count = copiedChangeCount else { return }
        copiedChangeCount = nil
        if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
    }

    private func applyLoginItem() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin { try service.register() } else { try service.unregister() }
        } catch {
            Self.log.error("Open at login: \(error.localizedDescription, privacy: .public)")
        }
        let status = service.status
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        syncLoginItem(status)
    }

    private func syncLoginItem(_ status: SMAppService.Status) {
        let enabled = Self.loginItemEnabled(status)
        if enabled != launchAtLogin {
            syncingLoginItem = true
            launchAtLogin = enabled
            syncingLoginItem = false
        }
        let needsApproval = status == .requiresApproval
        if needsApproval != loginItemNeedsApproval { loginItemNeedsApproval = needsApproval }
    }

    private func refreshStatus() {
        let text: String
        if let keychainProblem {
            text = keychainProblem
        } else if !hasInputPermission {
            text = Self.permissionText
        } else if isPaused {
            text = "iKey is paused. Resume it to use your iPad as this Mac's keyboard."
        } else if isConnected {
            // A pairing hint, pair-another instructions or a key-rotation failure must reach the
            // user while an iPad is connected (the usual state for these actions).
            let connected = "Connected to \(connectedDeviceName ?? "iPad"). Keyboard and trackpad are ready."
            text = notice.map { connected + " " + $0.text } ?? connected
        } else if let notice {
            text = notice.text
        } else if listenerTrouble {
            text = "Waiting for the local network. Check Wi-Fi and the Local Network permission in System Settings."
        } else if isPaired {
            text = "Ready. Your iPad connects automatically."
        } else {
            text = "Ready to pair. Copy the pairing key and paste it in iKey on your iPad."
        }
        if status != text { status = text }
    }

    private func scheduleNoticeExpiry() {
        noticeExpiryWork?.cancel()
        noticeExpiryWork = nil
        guard let current = notice, current.expires else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.notice == current else { return }
            self.noticeExpiryWork = nil
            self.notice = nil
            self.refreshStatus()
        }
        noticeExpiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeLifetime, execute: work)
    }

    // MARK: Helpers

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping (ReceiverModel) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            if let self { handler(self) }
        }
        observers.append((center, observer))
    }

    /// Registered, also while awaiting the user's approval in System Settings.
    private static func loginItemEnabled(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    /// The Mac clock shared with the arbiter and the injector.
    private static func clock() -> Double { ProcessInfo.processInfo.systemUptime }

    private static func micros(_ seconds: Double) -> Int64 { Int64((seconds * 1_000_000).rounded()) }

    private static func serviceName(for computerName: String) -> String {
        let name = truncated(computerName, maxUTF8Bytes: 48)
        return (name.isEmpty ? "Mac" : name) + " — iKey"
    }

    /// Whole characters up to `maxUTF8Bytes` (Bonjour and wire limits count UTF-8 bytes).
    private static func truncated(_ text: String, maxUTF8Bytes: Int) -> String {
        var result = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            guard bytes + size <= maxUTF8Bytes else { break }
            bytes += size
            result.append(character)
        }
        return result
    }
}
