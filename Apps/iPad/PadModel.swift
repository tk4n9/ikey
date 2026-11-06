import Foundation
import Combine
import SwiftUI
import UIKit
import ImageIO
import Network
import os
import IKeyCore

struct MacPeer: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    /// Protocol from the Bonjour TXT record (1 = a Mac that needs updating).
    let proto: Int
    /// The Mac's TXT `id`, when advertised.
    let macID: UUID?
}

/// A needsRepair or macTooOld problem. It is kept through the automatic retries those states make
/// (`.connecting`/`.awaitingWelcome` every 10 s), a pasted-key Connect that pre-empts one of them, and
/// trips through the background, so the pairing card, the panel's pairing section, the ring and the
/// hint stay put while the user types a key.
struct PairingEpisode: Equatable {
    enum Kind: Equatable { case needsRepair, macTooOld }
    var kind: Kind
    /// `PadModel.status` when the problem was last seen (the card title and the top-band hint).
    var status: String
}

extension SecureParameters {
    /// Offer the ECDHE-PSK suite; the integration pass flips it after the macOS loopback test.
    static let offerForwardSecrecyEnabled = false
}

/// The iPad's session with its paired Mac. Networking callbacks and UI state are confined to the
/// main queue. `ConnectionSupervisor` decides when to connect; this class executes its commands.
final class PadModel: ObservableObject {
    // MARK: Published state

    @Published var preferences: PadPreferences {
        didSet { preferencesChanged(from: oldValue) }
    }
    /// The supervisor's state. A `.connected` value is not re-published when only `lastHeard`
    /// moves, so views do not redraw for every message from the Mac.
    @Published private(set) var linkState: LinkState
    @Published private(set) var problemSince: Double?
    @Published private(set) var macName: String? {
        didSet { if macName != oldValue { refreshPairingEpisode() } }
    }
    @Published private(set) var welcome: Welcome?
    @Published private(set) var macPrefs: MacInputPreferences?
    @Published private(set) var capsLockOn = false
    @Published private(set) var detectedMacModel: MacBookAirModel?
    @Published private(set) var isPaired = false
    /// Ping round trip in seconds over the current session (nil until the first pong).
    @Published private(set) var rttP50: Double?
    @Published private(set) var rttP95: Double?
    /// Modifier key codes the live Mac's key remap makes tap-only (`MacState.tapOnly`); kept per Mac
    /// across launches so the deck is right before the first state message. Read via `effectiveTyping`.
    @Published private var macTapOnlyCodes: Set<UInt16> = []
    @Published var isPanelPresented = false {
        didSet { if isPanelPresented != oldValue { inputModeMayHaveChanged() } }
    }
    @Published var isFitPresented = false {
        didSet { if isFitPresented != oldValue { inputModeMayHaveChanged() } }
    }
    /// Fit & Size live preview; never persisted.
    @Published var previewPlacement: DeckPlacement?
    @Published private(set) var projection: ProjectionResolution?
    /// The Mac's last goodbye; kept across suspension, cleared by the next welcome.
    @Published private(set) var lastGoodbye: GoodbyeReason? {
        didSet { if lastGoodbye != oldValue { refreshPairingEpisode() } }
    }
    /// The needsRepair / macTooOld problem the pairing UI answers (see `PairingEpisode`); nil otherwise.
    @Published private(set) var pairingEpisode: PairingEpisode?
    /// "Keep waiting" during a needsRepair episode: the pairing card stays hidden while iKey keeps
    /// retrying the stored key. Reversible (`stopWaitingForRepair()`, or pairing from the panel); ends
    /// with the episode.
    @Published private(set) var isWaitingOutRepair = false
    /// "Pause input": the link stays up, but the deck stays at `.panelOnly` until `resumeInput()` (the
    /// panel's Resume input, or the settings gesture on the deck). Deck touches never resume it. Not
    /// persisted: a relaunch starts live.
    @Published private(set) var isInputPaused = false {
        didSet { if isInputPaused != oldValue { inputModeMayHaveChanged() } }
    }

    // Discovery, pairing, calibration and photo mode.
    @Published private(set) var peers: [MacPeer] = []
    @Published var selectedPeerID = ""
    /// Editing the key is a user action that answers a failed pairing's message.
    @Published var pairingText = "" {
        didSet { if pairingText != oldValue { clearPairingFailure() } }
    }
    /// Any other text written here (by the model or a view) supersedes a failed pairing's message,
    /// so a later reconnect never brings the stale failure back over it.
    @Published var message: String? {
        didSet { if let failure = pairingFailure, message != failure { pairingFailure = nil } }
    }
    @Published private(set) var isRefreshing = false
    @Published private(set) var discoveryStatus = "Search for your Mac after starting its receiver."
    @Published private(set) var photo: UIImage?
    @Published private(set) var layout = DeckLayout.macBookANSI
    @Published private(set) var resetGeneration = 0

    @Published private var scenePhase: ScenePhase = .active
    /// Screen brightness below the Auto glow threshold.
    @Published private var lowLight = false

    // MARK: Derived state

    var deckInputMode: DeckInputMode {
        if scenePhase == .background { return .off }
        guard case .connected = linkState, !isPanelPresented, !isFitPresented, !isInputPaused,
              scenePhase == .active else {
            return .panelOnly
        }
        // Windowed or rotated scenes pause input. An unknown iPad keeps a usable scaled deck
        // (amendment E: the fitting mode exists for unknown devices, with a banner).
        if let projection, projection.fit == .windowed, preferences.appearance.mode != .photo {
            return .panelOnly
        }
        return .live
    }

    var effectiveTrackpad: TrackpadSettings { preferences.effectiveTrackpad(mac: macPrefs) }

    /// The user's typing settings plus the live Mac's tap-only keys (amendment H).
    var effectiveTyping: TypingSettings {
        var typing = preferences.typing
        typing.tapOnlyCodes.formUnion(macTapOnlyCodes)
        return typing
    }

    var effectiveModel: MacBookAirModel {
        let appearance = preferences.appearance
        return appearance.modelIsManual ? appearance.model : (detectedMacModel ?? appearance.model)
    }

    var effectiveFinish: DeckFinish {
        let model = effectiveModel
        if let finish = preferences.appearance.finish, model.finishes.contains(finish) { return finish }
        return model.defaultFinish
    }

    /// Off 0, on 1; auto follows the screen brightness (below 0.3 → 1).
    var keyboardGlowLevel: Double {
        switch preferences.appearance.glow {
        case .off: return 0
        case .on: return 1
        case .auto: return lowLight ? 1 : 0
        }
    }

    var isConnected: Bool {
        if case .connected = linkState { return true }
        return false
    }

    var isConnecting: Bool {
        switch linkState {
        case .connecting, .awaitingWelcome: return true
        default: return false
        }
    }

    var status: String {
        let name = macName ?? "your Mac"
        switch linkState {
        case .unpaired: return "Not paired"
        case .suspended: return "Paused"
        case .backoff, .connecting, .awaitingWelcome: return "Connecting to \(name)…"
        case .connected: return "Connected to \(name)"
        case .replaced:
            return lastGoodbye == .replaced ? "In use by another iPad — touch to switch" : "Disconnected"
        case .macTooOld:
            return lastGoodbye == .protocolMismatch ? "Update iKey" : "Update iKey on your Mac"
        case .needsRepair: return "Can't reach \(name) — the pairing key may have changed"
        }
    }

    /// A pasted key with a chosen Mac pairs; no key reconnects the paired Mac. A pasted key may
    /// pre-empt an automatic attempt (a needsRepair / macTooOld retry, a reconnect), never the user's
    /// own pairing attempt.
    var canConnect: Bool {
        if isConnected { return false }
        if trimmedPairingText.isEmpty { return isPaired && !isConnecting }
        guard peers.contains(where: { $0.id == selectedPeerID }) else { return false }
        return !isConnecting || attempt?.pairing == nil
    }

    var connectionHint: String? {
        if isConnected || isConnecting || isPaired { return nil }
        if peers.isEmpty { return "Connect becomes available when your Mac appears in the list and you enter its pairing key." }
        if !peers.contains(where: { $0.id == selectedPeerID }) { return "Choose a Mac from the list above." }
        if trimmedPairingText.isEmpty { return "Paste the pairing key from the selected Mac to enable Connect." }
        return nil
    }

    var touchProtection: TouchProtectionSettings { preferences.protection }

    var showTouchIndicators: Bool { preferences.showTouchIndicators }

    // MARK: Private state

    private enum Key {
        static let pairing = "iKey.pairing.v2"
        static let clientID = "iKey.clientID"
        static let macTapOnly = "iKey.macTapOnly.v1"
        static let v1TouchProtection = "iKey.touchProtection.v1"
        static let v1ShowIndicators = "iKey.showTouchIndicators.v1"
    }

    private struct PairingRecord: Codable, Equatable {
        var macID: UUID
        var macName: String
        var lastServiceName: String
        var knownGoodHosts: [String]
    }

    private static let log = Logger(subsystem: "com.ikey.pad", category: "session")
    private static let maxKnownGoodHosts = 8
    private static let glowBrightness = 0.3
    /// A close this soon after hello, without a welcome, is how a v1 receiver refuses v2.
    private static let closedAfterHelloWindow = 1.0
    private static let goodbyeGrace = 1.0

    private var supervisor: ConnectionSupervisor
    private var record: PairingRecord?
    private var pairedSecret: PairingSecret?
    private var pendingPairing: PendingPairing?
    /// Why the last pasted-key pairing failed. It stays in `message` when the supervisor then
    /// reconnects the previously paired Mac; the next user action, a successful pairing or any newer
    /// `message` clears it.
    private var pairingFailure: String?
    private var attempt: LinkAttempt?
    /// Streams closing with a goodbye stay alive until it is handed to the network.
    private var closingStreams: [ObjectIdentifier: PadLinkStream] = [:]
    private let clientID: UUID

    private var browser: NWBrowser?
    private var browsingWanted = false
    private var discoveryTimeout: DispatchWorkItem?
    private var pairedEndpoint: NWEndpoint?
    /// TXT proto of the paired Mac's current advert; nil while it is not advertised.
    private var pairedAdvertProto: Int?
    private let pathMonitor = NWPathMonitor()
    private var pathSatisfied: Bool?

    private var tickTimer: Timer?
    private var linkTimer: Timer?
    private var heartbeatSeq: UInt32 = 0
    private var lastHeartbeatAt = -Double.infinity
    private var pingID: UInt32 = 0
    private var lastPingAt = -Double.infinity
    private var latency = LatencyStats()
    private var heldKeys: Set<UInt16> = []
    private var heldButtons: Set<PointerButton> = []
    private var heldActive = false
    /// The Mac whose tap-only codes are in `macTapOnlyCodes`.
    private var tapOnlyMacID: UUID?

    private var lastInputMode: DeckInputMode = .panelOnly
    /// Set while `connect()` ends an automatic attempt to pair with a pasted key: the brief `.replaced`
    /// that passes through must not end the pairing episode the user is answering.
    private var keepsPairingEpisode = false
    private var loggedLegacyDrop = false
    private var brightnessObserver: NSObjectProtocol?
    private let store = PadStore()

    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var trimmedPairingText: String { pairingText.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Init

    init() {
        let defaults = UserDefaults.standard
        let savedPreferences = defaults.data(forKey: PadPreferences.storageKey)
            .flatMap { try? JSONDecoder().decode(PadPreferences.self, from: $0) }
        let record = defaults.data(forKey: Key.pairing)
            .flatMap { try? JSONDecoder().decode(PairingRecord.self, from: $0) }
        let secret = record.flatMap { PadKeychain.load(macID: $0.macID) }
        let paired = record != nil && secret != nil
        let supervisor = ConnectionSupervisor(paired: paired)
        // Stored properties without defaults first; the rest go through their setters.
        preferences = savedPreferences ?? .migrated(
            v1TouchProtection: defaults.data(forKey: Key.v1TouchProtection),
            v1ShowIndicators: defaults.object(forKey: Key.v1ShowIndicators) as? Bool)
        linkState = supervisor.state
        self.supervisor = supervisor
        clientID = PadModel.loadClientID()

        self.record = record
        pairedSecret = secret
        isPaired = paired
        macName = record?.macName
        if let macID = record?.macID {
            tapOnlyMacID = macID
            macTapOnlyCodes = Self.storedTapOnly(for: macID)
        }

        do { layout = try store.loadLayout() ?? .macBookANSI }
        catch { message = "Saved calibration could not be loaded. The default layout is active." }
        photo = store.loadPhoto()

        if savedPreferences == nil { savePreferences() }
        startObservers()
        // The supervisor has no clock until its first input; `.active` also starts a paired attempt.
        handle(.active)
    }

    deinit {
        tickTimer?.invalidate()
        linkTimer?.invalidate()
        pathMonitor.cancel()
        browser?.cancel()
        attempt?.stream.cancel()
        if let brightnessObserver { NotificationCenter.default.removeObserver(brightnessObserver) }
    }

    // MARK: Deck callbacks

    /// Deck output stamped with the touch time (seconds on the system-uptime clock). Outside `.live`
    /// only releases go out: the deck's releaseAll and key/button ups often arrive after the mode
    /// has already changed, and the Mac must not keep those keys held until heartbeat reconciliation.
    func send(_ inputs: [PadInput], at touchTime: TimeInterval) {
        guard let stream = liveStream else { return }
        var batch = PadInput.coalesced(inputs)
        if deckInputMode != .live { batch = batch.filter(Self.releasesState) }
        guard !batch.isEmpty else { return }
        let t = Self.micros(touchTime.isFinite ? touchTime : now)
        stream.send(batch.map { PadMessage.input($0, t: t) })
    }

    /// Legacy events (calibration preview and the photo path): keys, clicks and release-all.
    func send(_ event: InputEvent) {
        let input: PadInput
        switch event {
        case .key(let code, let down):
            input = .key(code: code, down: down)
        case .button(let button, let down):
            input = .button(button: button, down: down, clickState: 1)
        case .releaseAll:
            input = .releaseAll
        case .pointer, .scroll:
            if !loggedLegacyDrop {
                loggedLegacyDrop = true
                Self.log.info("Dropping legacy pointer/scroll events: protocol v2 needs mm motion")
            }
            return
        case .heartbeat:
            return
        }
        send([input], at: now)
    }

    func updateHeldSnapshot(keys: Set<UInt16>, buttons: Set<PointerButton>, active: Bool) {
        heldKeys = keys
        heldButtons = buttons
        heldActive = active
    }

    func deckTouchedWhileDisconnected() {
        handle(.deckTouched)
    }

    func projectionResolved(_ r: ProjectionResolution) {
        guard r != projection else { return }
        projection = r
        refreshBrightness()
        inputModeMayHaveChanged()
    }

    // MARK: Scene

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard phase != scenePhase else { return }
        scenePhase = phase
        switch phase {
        case .active:
            refreshBrightness()
            handle(.active)
        case .inactive:
            handle(.inactive)
        case .background:
            handle(.background)
        @unknown default:
            break
        }
    }

    // MARK: User actions

    /// Pairs with the selected Mac using the pasted key, or reconnects the paired Mac when no key
    /// is pasted. The pasted key is cleared only after the Mac's welcome.
    func connect() {
        pairingFailure = nil
        let text = trimmedPairingText
        if text.isEmpty {
            guard isPaired else {
                message = "Paste the pairing key shown by iKey on your Mac."
                return
            }
            message = nil
            handle(.userConnect)
            // macTooOld holds the attempt while the Mac advertises protocol 1: say why nothing happens.
            if case .macTooOld = supervisor.state { message = updateNeededMessage }
            return
        }
        guard let peer = peers.first(where: { $0.id == selectedPeerID }) else {
            message = "Choose a nearby Mac first."
            return
        }
        guard peer.proto >= WireV2.version else {
            message = "Update iKey on your Mac, then connect again."
            return
        }
        guard let secret = try? PairingSecret(hex: text) else {
            message = "Paste the full 64-character pairing key shown by iKey on your Mac."
            return
        }
        message = nil
        // Pairing is a deliberate switch: end any attempt or link in progress (an automatic retry
        // included; the current Mac gets a `.user` goodbye) so the pasted key is used by this action,
        // not by a later retry. The pairing episode being answered survives the brief park.
        keepsPairingEpisode = true
        defer { keepsPairingEpisode = false }
        switch supervisor.state {
        case .connecting, .awaitingWelcome, .connected:
            handle(.userDisconnect)
        case .unpaired, .backoff, .suspended, .replaced, .macTooOld, .needsRepair:
            break
        }
        pendingPairing = PendingPairing(secret: secret, peer: peer)
        handle(.userConnect)
        // One-shot: a pasted key that this action's attempt did not take is dropped, never left for
        // an automatic reconnect (which could silently move the pairing to another Mac).
        guard pendingPairing != nil else { return }
        pendingPairing = nil
        if case .macTooOld = supervisor.state {
            // Not sticky: once that Mac is updated and reconnects, its welcome clears the text.
            message = pairedMacNeedsUpdateMessage
        } else {
            showPairingFailure("Could not start pairing. Try again.")
        }
    }

    func disconnect() {
        pendingPairing = nil
        clearPairingFailure()
        handle(.userDisconnect)
    }

    func forgetPairing() {
        pendingPairing = nil
        clearPairingFailure()
        isInputPaused = false
        handle(.forgot)
        welcome = nil
        macPrefs = nil
        capsLockOn = false
        rttP50 = nil
        rttP95 = nil
    }

    /// nil returns to Auto (the model the Mac reports).
    func noteManualModelChoice(_ model: MacBookAirModel?) {
        var appearance = preferences.appearance
        if let model {
            appearance.model = model
            appearance.modelIsManual = true
        } else {
            appearance.model = detectedMacModel ?? MacBookAirModel.defaultModel
            appearance.modelIsManual = false
        }
        preferences.appearance = appearance
    }

    /// Restarts discovery (Refresh); does nothing while connected, when no browser should run.
    func startDiscovery() {
        clearPairingFailure()
        guard browsingWanted else { return }
        startBrowser()
    }

    /// Keeps the link but stops all deck input until `resumeInput()`; held keys and buttons are
    /// released at once (through `inputModeMayHaveChanged`).
    func pauseInput() {
        isInputPaused = true
    }

    func resumeInput() {
        isInputPaused = false
    }

    /// "Keep waiting" on the pairing card: hide it while iKey keeps retrying the stored key.
    func keepWaitingForRepair() {
        guard pairingEpisode?.kind == .needsRepair else { return }
        isWaitingOutRepair = true
    }

    /// Undoes "Keep waiting": the pairing card shows again.
    func stopWaitingForRepair() {
        isWaitingOutRepair = false
    }

    func saveLayout(_ draft: DeckLayout) throws {
        let valid = try draft.validated()
        try store.saveLayout(valid)
        layout = valid
        resetGeneration += 1
        pairingFailure = nil
        message = nil
    }

    /// The first photo (none was stored) also switches the deck to Photo; a replacement keeps the
    /// mode the user chose.
    func importPhoto(_ data: Data) throws {
        let isFirst = photo == nil
        photo = try store.savePhoto(data)
        pairingFailure = nil
        message = nil
        if isFirst, preferences.appearance.mode != .photo { preferences.appearance.mode = .photo }
    }

    func removePhoto() {
        do {
            try store.removePhoto()
            photo = nil
            clearPairingFailure()
        } catch { message = "Could not remove the photo: \(error.localizedDescription)" }
    }

    // MARK: Supervisor

    private func handle(_ input: LinkInput) {
        let before = supervisor.state
        let commands = supervisor.handle(input, now: now)
        publishLinkState()
        for command in commands { execute(command, input: input, stateBefore: before) }
        updateTimers()
        inputModeMayHaveChanged()
    }

    private func publishLinkState() {
        let state = supervisor.state
        if case .connected(let since, _) = state, case .connected(let shown, _) = linkState, since == shown {
            // Only lastHeard moved.
        } else if state != linkState {
            linkState = state
        }
        if supervisor.problemSince != problemSince { problemSince = supervisor.problemSince }
        refreshPairingEpisode()
    }

    /// Starts an episode in needsRepair / macTooOld (refreshing its wording), keeps it through the
    /// retries, the background and a pasted-key Connect's park, and ends it on `.connected`,
    /// `.unpaired`, `.replaced` or `.backoff`, which the supervisor enters only once its hold is gone
    /// (the stored key worked, the Mac now advertises protocol 2, or the user disconnected or forgot).
    private func refreshPairingEpisode() {
        let next: PairingEpisode?
        switch linkState {
        case .needsRepair:
            next = PairingEpisode(kind: .needsRepair, status: status)
        case .macTooOld:
            next = PairingEpisode(kind: .macTooOld, status: status)
        case .connecting, .awaitingWelcome, .suspended:
            next = pairingEpisode
        case .replaced:
            next = keepsPairingEpisode ? pairingEpisode : nil
        case .connected, .unpaired, .backoff:
            next = nil
        }
        if next != pairingEpisode { pairingEpisode = next }
        if isWaitingOutRepair, next?.kind != .needsRepair { isWaitingOutRepair = false }
    }

    private func execute(_ command: LinkCommand, input: LinkInput, stateBefore: LinkState) {
        switch command {
        case .openAttempt:
            openAttempt()
        case .cancelAttempt:
            if case .tick = input, case .connecting = stateBefore, let attempt {
                // Attempt timeout: the transport did not come up on this path.
                preferences.peerToPeer.attemptFailed(usedP2P: attempt.usedP2P)
            }
            reportEndedPairingAttempt(input: input)
            retireAttempt(goodbye: nil)
        case .sendHello:
            sendHello()
        case .closeLink(let goodbye):
            reportEndedPairingAttempt(input: input)
            retireAttempt(goodbye: goodbye)
        case .releaseHeldInput:
            sendReleaseAll()
            resetGeneration += 1
        case .setBrowsing(let on):
            browsingWanted = on
            if on {
                if browser == nil { startBrowser() }
            } else {
                stopBrowser()
            }
        case .deletePairing:
            deletePairing()
        }
    }

    // MARK: Link

    private var liveStream: PadLinkStream? {
        guard let attempt, attempt.welcomed else { return nil }
        return attempt.stream
    }

    private func openAttempt() {
        retireAttempt(goodbye: nil)
        let pairing = pendingPairing
        pendingPairing = nil
        let chosenSecret: PairingSecret?
        let chosenEndpoint: NWEndpoint?
        if let pairing {
            chosenSecret = pairing.secret
            chosenEndpoint = pairing.peer.endpoint
        } else {
            if pairedSecret == nil, let record { pairedSecret = PadKeychain.load(macID: record.macID) }
            chosenSecret = pairedSecret
            if let pairedEndpoint {
                chosenEndpoint = pairedEndpoint
            } else if let name = record?.lastServiceName, !name.isEmpty {
                // Cold launch: resolve the remembered service instead of waiting for the browser.
                chosenEndpoint = .service(name: name, type: IKeyService.bonjourType, domain: "local.", interface: nil)
            } else {
                chosenEndpoint = nil
            }
        }
        guard let secret = chosenSecret, let endpoint = chosenEndpoint else {
            // No Mac to try yet: report the failure after the supervisor's current step.
            DispatchQueue.main.async { [weak self] in
                guard let self, case .connecting = self.supervisor.state, self.attempt == nil else { return }
                self.handle(.attemptFailed(authFailure: false, knownGoodHost: false))
            }
            return
        }
        let usedP2P = preferences.peerToPeer.useP2P()
        let connection = NWConnection(to: endpoint, using: SecureParameters.make(
            secret: secret, peerToPeer: usedP2P, offerForwardSecrecy: SecureParameters.offerForwardSecrecyEnabled))
        let stream = PadLinkStream(connection: connection)
        let next = LinkAttempt(stream: stream, connection: connection, secret: secret, usedP2P: usedP2P,
                               pairing: pairing)
        attempt = next
        connection.pathUpdateHandler = { [weak next] path in next?.note(path) }
        stream.onReady = { [weak self, weak next] in
            guard let self, let next, self.attempt === next else { return }
            self.handle(.attemptReady)
        }
        stream.onMessage = { [weak self, weak next] message in
            guard let self, let next, self.attempt === next else { return }
            self.received(message, on: next)
        }
        stream.onClose = { [weak self, weak next] reason in
            guard let self, let next, self.attempt === next else { return }
            self.closed(next, reason: reason)
        }
        stream.start()
    }

    private func sendHello() {
        guard let attempt else { return }
        let info = Bundle.main.infoDictionary
        let hello = Hello(proto: WireV2.version, client: clientID,
                          app: Self.wireString(info?["CFBundleShortVersionString"] as? String ?? "0"),
                          device: Self.wireString(Self.helloDeviceName),
                          features: WireFeature.all)
        attempt.helloSentAt = now
        attempt.stream.send([.hello(hello)])
    }

    /// Ends the current attempt or link without reporting its close to the supervisor.
    private func retireAttempt(goodbye: GoodbyeReason?) {
        guard let old = attempt else { return }
        attempt = nil
        let stream = old.stream
        stream.onReady = nil
        stream.onMessage = nil
        old.connection.pathUpdateHandler = nil
        guard let goodbye else {
            stream.onClose = nil
            stream.cancel()
            return
        }
        let key = ObjectIdentifier(stream)
        closingStreams[key] = stream
        stream.onClose = { [weak self] _ in self?.closingStreams[key] = nil }
        stream.send([.goodbye(goodbye)])
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.goodbyeGrace) { [weak self] in
            if let stuck = self?.closingStreams[key] { stuck.cancel() }
        }
    }

    private func closed(_ old: LinkAttempt, reason: LinkCloseReason) {
        attempt = nil
        old.connection.pathUpdateHandler = nil
        let time = now
        if case .goodbye(let r) = reason {
            // A Mac that refuses a pasted key before its welcome leaves a message: the supervisor may
            // now reconnect the previously paired Mac.
            if !old.welcomed, old.pairing != nil { showPairingFailure(Self.pairingRefusedMessage(r)) }
            // That refusal concerns the pasted-key Mac only: it must not park, hold or delete the stored
            // pairing of another Mac (a goodbye(.unpaired) would delete it), so report a plain close.
            handle(.linkClosed(speaksForStoredPairing(old) ? r : nil))
        } else if old.welcomed {
            handle(.linkClosed(nil))
        } else if let hello = old.helloSentAt, time - hello < Self.closedAfterHelloWindow {
            if old.pairing != nil { showPairingFailure("Update iKey on your Mac, then connect again.") }
            handle(.closedAfterHello)
        } else {
            let host = old.remoteHost
            // A pasted key failing proves nothing about the stored key: never count it toward needsRepair.
            // Only a host that completed a handshake before counts (docs/protocol.md): the Bonjour TXT
            // `id` is unauthenticated, so an advert carrying the paired Mac's id proves nothing.
            let knownGood = old.pairing == nil
                && (host.map { record?.knownGoodHosts.contains($0) ?? false } ?? false)
            let authFailure = Self.isAuthFailure(reason, connection: old.connection)
            // A TLS alert or PSK mismatch proves the path reached the Mac: it is not evidence
            // against infrastructure Wi-Fi, so it must not push the policy back to P2P.
            if !authFailure { preferences.peerToPeer.attemptFailed(usedP2P: old.usedP2P) }
            if old.pairing != nil { showPairingFailure(Self.pairingFailedMessage) }
            handle(.attemptFailed(authFailure: authFailure, knownGoodHost: knownGood))
        }
    }

    private func received(_ message: MacMessage, on link: LinkAttempt) {
        handle(.heard)
        switch message {
        case .welcome(let w):
            welcomed(w, on: link)
        case .state(let state):
            if let caps = state.caps, caps != capsLockOn { capsLockOn = caps }
            if let prefs = state.prefs, prefs != macPrefs { macPrefs = prefs }
            if let tapOnly = state.tapOnly, let mac = welcome?.mac { setTapOnly(Set(tapOnly), for: mac) }
        case .pong(_, let echoT, _):
            latency.add(now - Double(echoT) / 1e6)
            let p50 = latency.percentile(50), p95 = latency.percentile(95)
            if p50 != rttP50 { rttP50 = p50 }
            if p95 != rttP95 { rttP95 = p95 }
        case .goodbye(let reason):
            // A pasted-key Mac's refusal is reported by closed(); it says nothing about the paired Mac.
            if speaksForStoredPairing(link) { lastGoodbye = reason }
        case .unknown:
            break
        }
    }

    private func welcomed(_ w: Welcome, on link: LinkAttempt) {
        guard case .awaitingWelcome = supervisor.state else { return }
        link.welcomed = true
        welcome = w
        macName = w.name
        macPrefs = w.prefs
        capsLockOn = w.caps
        lastGoodbye = nil
        // A reconnect of the previously paired Mac keeps a failed pairing's message on screen.
        if link.pairing != nil { pairingFailure = nil }
        message = pairingFailure
        latency = LatencyStats()
        rttP50 = nil
        rttP95 = nil
        heartbeatSeq = 0
        lastHeartbeatAt = -.infinity
        lastPingAt = -.infinity
        if tapOnlyMacID != w.mac {
            tapOnlyMacID = w.mac
            macTapOnlyCodes = Self.storedTapOnly(for: w.mac)
        }
        detectedMacModel = MacModelCatalog.model(forHardwareModel: w.model)
        if let detected = detectedMacModel, !preferences.appearance.modelIsManual,
           preferences.appearance.model != detected {
            preferences.appearance.model = detected
        }
        handle(.welcomeReceived)

        if let path = link.connection.currentPath {
            link.note(path)
            preferences.peerToPeer.sessionEstablished(overInfrastructure: !LinkAttempt.isPeerToPeer(path))
        }
        if let pairing = link.pairing {
            savePairing(w, secret: link.secret, peer: pairing.peer, host: link.remoteHost)
        } else if var current = record {
            if current.macID != w.mac {
                // The stored key opened a different Mac ID: move the pairing to it.
                PadKeychain.delete(macID: current.macID)
                _ = PadKeychain.save(link.secret, macID: w.mac)
                current.macID = w.mac
            }
            current.macName = w.name
            // The remembered service name follows only a Mac that proved the key, never an advert's
            // unauthenticated TXT id alone.
            if case .service(let name, _, _, _) = link.connection.endpoint, !name.isEmpty {
                current.lastServiceName = name
            }
            if let host = link.remoteHost { current.knownGoodHosts = Self.adding(host, to: current.knownGoodHosts) }
            if current != record { saveRecord(current) }
        }
        resetGeneration += 1
    }

    private func savePairing(_ w: Welcome, secret: PairingSecret, peer: MacPeer, host: String?) {
        if let old = record, old.macID != w.mac { PadKeychain.delete(macID: old.macID) }
        if !PadKeychain.save(secret, macID: w.mac) {
            message = "The pairing key could not be saved; you will need to paste it again after a relaunch."
        }
        saveRecord(PairingRecord(macID: w.mac, macName: w.name, lastServiceName: peer.name,
                                 knownGoodHosts: host.map { [$0] } ?? []))
        // Reconnects go to the newly paired Mac, never to a previous Mac's Bonjour endpoint (the
        // browser is stopped while connected, so it cannot correct this before the next attempt).
        pairedEndpoint = peer.endpoint
        pairedAdvertProto = nil
        pairedSecret = secret
        pairingText = ""
        isPaired = true
        handle(.paired)
    }

    private func deletePairing() {
        if let record { PadKeychain.delete(macID: record.macID) }
        record = nil
        UserDefaults.standard.removeObject(forKey: Key.pairing)
        pairedSecret = nil
        pairedEndpoint = nil
        pairedAdvertProto = nil
        isPaired = false
        macName = nil
        if lastGoodbye == .unpaired { message = "Your Mac reset its pairing key. Paste the new key to pair again." }
    }

    private func saveRecord(_ new: PairingRecord) {
        record = new
        if let data = try? JSONEncoder().encode(new) { UserDefaults.standard.set(data, forKey: Key.pairing) }
    }

    private func setTapOnly(_ codes: Set<UInt16>, for mac: UUID) {
        tapOnlyMacID = mac
        if codes != macTapOnlyCodes { macTapOnlyCodes = codes }
        var stored = Self.storedTapOnly()
        let list = codes.sorted().map { Int($0) }
        guard stored[mac.uuidString] != list else { return }
        stored[mac.uuidString] = list
        UserDefaults.standard.set(stored, forKey: Key.macTapOnly)
    }

    // MARK: Timers, heartbeat and ping

    private func updateTimers() {
        if case .connected = supervisor.state {
            stop(&tickTimer)
            if linkTimer == nil { linkTimer = repeating(0.1) { [weak self] in self?.linkTimerFired() } }
        } else {
            stop(&linkTimer)
            if supervisor.nextDeadline == nil {
                stop(&tickTimer)
            } else if tickTimer == nil {
                tickTimer = repeating(0.05) { [weak self] in self?.handle(.tick) }
            }
        }
    }

    private func linkTimerFired() {
        handle(.tick)
        guard let stream = liveStream else { return }
        let time = now
        // Anything held on the Mac (keys, buttons) or a contact on the deck beats every 100 ms: the
        // Mac's 1 s dead-man releases held input after 1 s of silence, and a drag lock keeps the
        // button down with no finger on the deck. 10% slack absorbs timer jitter against the beat.
        let beatActive = heldActive || !heldKeys.isEmpty || !heldButtons.isEmpty
        if time - lastHeartbeatAt >= (beatActive ? 0.1 : 1.0) * 0.9 {
            lastHeartbeatAt = time
            heartbeatSeq &+= 1
            let beat = Heartbeat(seq: heartbeatSeq, held: heldKeys.sorted(),
                                 buttons: heldButtons.sorted { $0.rawValue < $1.rawValue }, active: heldActive)
            stream.send([.heartbeat(beat, t: Self.micros(time))])
        }
        if time - lastPingAt >= 0.9 {
            lastPingAt = time
            pingID &+= 1
            stream.send([.ping(id: pingID, t: Self.micros(time))])
        }
    }

    private func repeating(_ interval: TimeInterval, _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in body() }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func stop(_ timer: inout Timer?) {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Input mode

    private func inputModeMayHaveChanged() {
        let mode = deckInputMode
        guard mode != lastInputMode else { return }
        if lastInputMode == .live { sendReleaseAll() }
        lastInputMode = mode
        UIApplication.shared.isIdleTimerDisabled = mode == .live
    }

    /// Bypasses the live-mode guard: used when input stops.
    private func sendReleaseAll() {
        liveStream?.send([.input(.releaseAll, t: Self.micros(now))])
    }

    // MARK: Preferences

    private func preferencesChanged(from old: PadPreferences) {
        guard preferences != old else { return }
        savePreferences()
        if preferences.isGeometryChange(from: old) || preferences.protection != old.protection
            || preferences.showTouchIndicators != old.showTouchIndicators {
            sendReleaseAll()
            resetGeneration += 1
        }
        if preferences.peerToPeer.useP2P() != old.peerToPeer.useP2P(), browser != nil {
            startBrowser()
        }
        inputModeMayHaveChanged()
    }

    private func savePreferences() {
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: PadPreferences.storageKey)
        }
    }

    // MARK: Discovery

    private func startBrowser() {
        stopBrowser()
        isRefreshing = true
        discoveryStatus = "Searching for Macs…"
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = preferences.peerToPeer.useP2P()
        let next = NWBrowser(for: .bonjourWithTXTRecord(type: IKeyService.bonjourType, domain: nil), using: parameters)
        browser = next
        next.browseResultsChangedHandler = { [weak self, weak next] results, _ in
            guard let self, let next, self.browser === next else { return }
            self.browseResultsChanged(results, browser: next)
        }
        next.stateUpdateHandler = { [weak self, weak next] state in
            guard let self, let next, self.browser === next else { return }
            switch state {
            case .failed(let error), .waiting(let error):
                self.discoveryTimeout?.cancel()
                self.discoveryTimeout = nil
                self.isRefreshing = false
                if case .dns(let code) = error, code == -65570 {
                    self.discoveryStatus = "Local Network access is blocked. Enable iKey in Settings → Privacy & Security → Local Network, then refresh."
                } else {
                    self.discoveryStatus = "Discovery is unavailable. Check Wi-Fi on both devices, then refresh."
                }
            case .ready:
                if self.peers.isEmpty {
                    self.waitForDiscoveryResults(from: next)
                } else {
                    self.showFoundPeers()
                }
            default: break
            }
        }
        next.start(queue: .main)
    }

    private func stopBrowser() {
        discoveryTimeout?.cancel()
        discoveryTimeout = nil
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        pairedAdvertProto = nil
        isRefreshing = false
    }

    private func browseResultsChanged(_ results: Set<NWBrowser.Result>, browser: NWBrowser) {
        peers = results.compactMap { result -> MacPeer? in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            var txt: [String: String] = [:]
            if case .bonjour(let txtRecord) = result.metadata { txt = txtRecord.dictionary }
            return MacPeer(id: String(describing: result.endpoint), name: name, endpoint: result.endpoint,
                           proto: WireV2.peerProtocol(txt: txt),
                           macID: txt[TXTRecordKeys.macID].flatMap(UUID.init(uuidString:)))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var paired: MacPeer?
        if let record {
            // The TXT `id` and `proto` are unauthenticated: when several adverts claim the paired Mac's
            // id, prefer the remembered service name (mDNS keeps names unique on the link), then one that
            // speaks v2, so a stray v1 or missing-proto advert cannot hold the deck in macTooOld while the
            // real Mac is also advertised. The remembered name changes only after a welcome.
            let byID = peers.filter { $0.macID == record.macID }
            paired = byID.first(where: { $0.name == record.lastServiceName })
                ?? byID.first(where: { $0.proto >= WireV2.version })
                ?? byID.first
                ?? peers.first(where: { $0.macID == nil && $0.name == record.lastServiceName })
        }
        if let paired { pairedEndpoint = paired.endpoint }

        if !peers.contains(where: { $0.id == selectedPeerID }) {
            selectedPeerID = paired?.id ?? peers.first(where: { $0.proto >= WireV2.version })?.id ?? peers.first?.id ?? ""
        }
        if !peers.isEmpty {
            showFoundPeers()
        } else if case .ready = browser.state {
            waitForDiscoveryResults(from: browser)
        }

        let proto = paired?.proto
        if proto != pairedAdvertProto {
            pairedAdvertProto = proto
            if let proto { handle(.peerAdvertised(proto: proto)) }
        }
    }

    private func showFoundPeers() {
        discoveryTimeout?.cancel()
        discoveryTimeout = nil
        isRefreshing = false
        discoveryStatus = peers.count == 1 ? "Found 1 Mac." : "Found \(peers.count) Macs."
    }

    private func waitForDiscoveryResults(from browser: NWBrowser) {
        discoveryTimeout?.cancel()
        isRefreshing = true
        discoveryStatus = "Searching for Macs…"
        let timeout = DispatchWorkItem { [weak self, weak browser] in
            guard let self, let browser, self.browser === browser, self.peers.isEmpty else { return }
            self.isRefreshing = false
            self.discoveryStatus = "No Macs found yet. On your Mac, start iKey's receiver and wait for Ready. Keep both devices on the same Wi-Fi network."
            // Keep browsing: a receiver started later should still appear.
        }
        discoveryTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    // MARK: Observers

    private func startObservers() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            guard satisfied != self.pathSatisfied else { return }
            self.pathSatisfied = satisfied
            self.handle(.pathSatisfied(satisfied))
        }
        pathMonitor.start(queue: .main)
        brightnessObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.brightnessDidChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let screen = note.object as? UIScreen else { return }
            self?.setBrightness(Double(screen.brightness))
        }
        // The window scene usually connects only after the model exists.
        DispatchQueue.main.async { [weak self] in self?.refreshBrightness() }
    }

    private func refreshBrightness() {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        if let screen { setBrightness(Double(screen.brightness)) }
    }

    private func setBrightness(_ brightness: Double) {
        let low = brightness < Self.glowBrightness
        if low != lowLight { lowLight = low }
    }

    // MARK: Helpers

    private var updateNeededMessage: String {
        lastGoodbye == .protocolMismatch
            ? "Update iKey on this iPad, then connect again."
            : "Update iKey on \(macName ?? "your Mac"), then connect again."
    }

    private var pairedMacNeedsUpdateMessage: String {
        "\(macName ?? "Your paired Mac") needs an iKey update. Update it, or Forget it to pair a different Mac."
    }

    /// False for a pasted-key attempt (with a key other than the stored one) that has not been
    /// welcomed: what its Mac says or does must not change the stored pairing's state.
    private func speaksForStoredPairing(_ link: LinkAttempt) -> Bool {
        link.welcomed || link.pairing == nil || link.secret == pairedSecret
    }

    /// The supervisor is cancelling or closing the current attempt. A pasted-key attempt that ends
    /// before its welcome, other than by the user's own Disconnect or Forget, leaves a message: the
    /// one-shot key is gone and the supervisor may now reconnect the previously paired Mac.
    private func reportEndedPairingAttempt(input: LinkInput) {
        guard let attempt, attempt.pairing != nil, !attempt.welcomed else { return }
        switch input {
        case .userDisconnect, .forgot:
            return
        case .peerAdvertised:
            // The paired Mac now advertises protocol 1 and holds every attempt (not sticky, as in connect()).
            message = pairedMacNeedsUpdateMessage
        case .background:
            showPairingFailure("Pairing was interrupted. Connect again to finish it.")
        default:
            showPairingFailure(Self.pairingFailedMessage)
        }
    }

    private static func pairingRefusedMessage(_ reason: GoodbyeReason) -> String {
        switch reason {
        case .protocolMismatch: return "Update iKey on this iPad, then connect again."
        case .unpaired: return "That Mac changed its pairing key. Paste the new key, then connect again."
        case .receiverStopping: return "iKey stopped on that Mac before pairing finished. Start it, then connect again."
        case .macSleeping: return "That Mac went to sleep before pairing finished. Wake it, then connect again."
        case .background, .user, .replaced: return pairingFailedMessage
        }
    }

    private func showPairingFailure(_ text: String) {
        pairingFailure = text
        message = text
    }

    /// The user acted after a failed pairing: its message has done its job.
    private func clearPairingFailure() {
        if let pairingFailure, message == pairingFailure { message = nil }
        pairingFailure = nil
    }

    /// Inputs that only release state, safe to send after the deck has left `.live`.
    private static func releasesState(_ input: PadInput) -> Bool {
        switch input {
        case .releaseAll, .key(code: _, down: false), .button(button: _, down: false, clickState: _): return true
        case .key, .button, .motion, .scroll, .contacts, .gesture: return false
        }
    }

    private static let pairingFailedMessage =
        "Could not connect. Check the pairing key, Wi-Fi, and that iKey is running on your Mac."

    /// Never traps: non-finite input is 0 and out-of-range values clamp to Int64.
    private static func micros(_ seconds: Double) -> Int64 {
        let value = seconds * 1e6
        guard value.isFinite else { return 0 }
        if let exact = Int64(exactly: value.rounded(.towardZero)) { return exact }
        return value < 0 ? .min : .max
    }

    /// The name the Mac shows for this iPad. Since iPadOS 16, `UIDevice.name` is the generic model
    /// ("iPad") unless the app holds Apple's managed user-assigned-device-name entitlement, which iKey
    /// does not; send the detected model ("iPad Pro 13-inch") instead. The client UUID stays the identity.
    private static var helloDeviceName: String {
        let name = UIDevice.current.name
        guard name.isEmpty || name == UIDevice.current.model,
              let spec = IPadDisplaySpec.preset(forMachine: DeviceIdentity.machineID) else { return name }
        return spec.name.components(separatedBy: " (").first ?? spec.name
    }

    /// The wire allows at most 64 UTF-8 bytes per string; cut on a character boundary.
    private static func wireString(_ text: String) -> String {
        var out = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            guard bytes + size <= 64 else { break }
            out.append(character)
            bytes += size
        }
        return out
    }

    private static func loadClientID() -> UUID {
        let defaults = UserDefaults.standard
        if let text = defaults.string(forKey: Key.clientID), let id = UUID(uuidString: text) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: Key.clientID)
        return id
    }

    private static func storedTapOnly() -> [String: [Int]] {
        UserDefaults.standard.dictionary(forKey: Key.macTapOnly) as? [String: [Int]] ?? [:]
    }

    private static func storedTapOnly(for mac: UUID) -> Set<UInt16> {
        Set((storedTapOnly()[mac.uuidString] ?? []).compactMap { UInt16(exactly: $0) })
    }

    private static func adding(_ host: String, to hosts: [String]) -> [String] {
        Array(([host] + hosts.filter { $0 != host }).prefix(maxKnownGoodHosts))
    }

    /// A TLS alert or PSK mismatch, as opposed to an unreachable host.
    private static func isAuthFailure(_ reason: LinkCloseReason, connection: NWConnection) -> Bool {
        switch connection.state {
        case .failed(let error), .waiting(let error):
            if case .tls = error { return true }
        default:
            break
        }
        guard case .failed(let text) = reason else { return false }
        // NWError.tls renders as its Secure Transport status (-98xx).
        return text.range(of: #"tls|-98\d\d"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// A pasted key and the Mac it is for; used by the next attempt.
private struct PendingPairing {
    let secret: PairingSecret
    let peer: MacPeer
}

/// One TCP/TLS attempt and, after the welcome, the session on it.
private final class LinkAttempt {
    let stream: PadLinkStream
    let connection: NWConnection
    let secret: PairingSecret
    /// The connection's parameters allowed peer-to-peer (AWDL).
    let usedP2P: Bool
    /// Set when this attempt pairs with a pasted key.
    let pairing: PendingPairing?
    var helloSentAt: Double?
    var welcomed = false
    /// Remote IP without an interface scope, from the latest path.
    var remoteHost: String?

    init(stream: PadLinkStream, connection: NWConnection, secret: PairingSecret, usedP2P: Bool,
         pairing: PendingPairing?) {
        self.stream = stream; self.connection = connection; self.secret = secret; self.usedP2P = usedP2P
        self.pairing = pairing
    }

    func note(_ path: NWPath) {
        if let host = Self.scopedHost(path) {
            remoteHost = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        }
    }

    /// True when the established path runs over AWDL (peer-to-peer) rather than infrastructure Wi-Fi.
    static func isPeerToPeer(_ path: NWPath) -> Bool {
        let awdl = { (name: String) in name.hasPrefix("awdl") || name.hasPrefix("llw") }
        if let host = scopedHost(path), let scope = host.split(separator: "%").dropFirst().first, awdl(String(scope)) {
            return true
        }
        return path.availableInterfaces.first.map { awdl($0.name) } ?? false
    }

    private static func scopedHost(_ path: NWPath) -> String? {
        guard case .hostPort(let host, _)? = path.remoteEndpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return "\(host)"
        }
    }
}

enum PadStoreError: LocalizedError {
    case unreadablePhoto, oversizedPhoto
    var errorDescription: String? {
        switch self {
        case .unreadablePhoto: return "That photo could not be opened. Choose a JPEG, PNG, or HEIC image."
        case .oversizedPhoto: return "Choose a photo smaller than 25 MB."
        }
    }
}

private struct PadStore {
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iKey", isDirectory: true)
    }
    private var photoURL: URL { directory.appendingPathComponent("deck-photo.jpg") }
    private var layoutURL: URL { directory.appendingPathComponent("deck-layout.json") }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func loadLayout() throws -> DeckLayout? {
        guard FileManager.default.fileExists(atPath: layoutURL.path) else { return nil }
        return try JSONDecoder().decode(DeckLayout.self, from: Data(contentsOf: layoutURL)).validated()
    }

    func saveLayout(_ layout: DeckLayout) throws {
        try prepareDirectory()
        try JSONEncoder().encode(layout).write(to: layoutURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func loadPhoto() -> UIImage? { UIImage(contentsOfFile: photoURL.path) }

    func savePhoto(_ data: Data) throws -> UIImage {
        guard data.count <= 25 * 1024 * 1024 else { throw PadStoreError.oversizedPhoto }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary) else { throw PadStoreError.unreadablePhoto }
        let image = UIImage(cgImage: thumbnail)
        guard let normalized = image.jpegData(compressionQuality: 0.95) else { throw PadStoreError.unreadablePhoto }
        try prepareDirectory()
        try normalized.write(to: photoURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return image
    }

    func removePhoto() throws {
        if FileManager.default.fileExists(atPath: photoURL.path) {
            try FileManager.default.removeItem(at: photoURL)
        }
    }
}
