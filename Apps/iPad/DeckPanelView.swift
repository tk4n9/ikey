import SwiftUI
import PhotosUI
import IKeyCore

/// The settings panel opened by holding Touch ID (input stays paused while it is open). Every
/// setting is in this list or one level below it, so each is at most two taps away.
struct DeckPanelView: View {
    @ObservedObject var model: PadModel
    var onFitAndSize: () -> Void

    @State private var confirmForget = false
    @State private var typingAdvanced = false

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                if showsPairingSection { pairingSection }
                macBookSection
                typingSection
                trackpadSection
                advancedSection
                diagnosticsSection
                if let message = model.message {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("iKey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.isPanelPresented = false }
                }
            }
            .confirmationDialog("Forget \(model.macName ?? "this Mac")?", isPresented: $confirmForget,
                                titleVisibility: .visible) {
                Button("Forget this Mac", role: .destructive) { model.forgetPairing() }
            } message: {
                Text("To connect again you will need the pairing key shown by iKey on the Mac.")
            }
        }
    }

    // MARK: Header

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.macName ?? "No Mac paired").font(.headline)
                Text(headerDetail).font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if model.isInputPaused {
                Button("Resume input") {
                    model.resumeInput()
                    model.isPanelPresented = false
                }
            } else if model.isConnected || model.isConnecting {
                // Keeps the link; the deck ignores touches until Resume input or the settings gesture.
                Button("Pause input") {
                    model.pauseInput()
                    model.isPanelPresented = false
                }
            }
            if model.isConnected || model.isConnecting {
                Button("Disconnect", role: .destructive) { model.disconnect() }
            } else if model.isPaired {
                Button("Connect") { model.connect() }
            }
        } footer: {
            if model.isInputPaused || model.isConnected || model.isConnecting {
                Text(headerFooter)
            }
        }
    }

    private var headerFooter: String {
        let resume = usesTouchIDTrigger ? "hold Touch ID" : "hold two fingers on the left palm rest"
        let pause = model.isInputPaused
            ? "Input is paused until you tap Resume input or \(resume) on the deck; touching the deck does not resume it."
            : "Input is paused while this panel is open. Pause input keeps it paused after you close the panel, until you \(resume)."
        guard model.isConnected || model.isConnecting else { return pause }
        return pause + " After Disconnect, touching the deck connects again."
    }

    /// The deck's settings gesture: holding Touch ID on the drawn deck, else the two-finger hold on the
    /// left palm rest (as `PadRootView` words it).
    private var usesTouchIDTrigger: Bool {
        model.preferences.appearance.mode == .drawn
            && (PanelTrigger(rawValue: model.preferences.panelTriggerRaw) ?? .touchIDHold) == .touchIDHold
    }

    private var headerDetail: String {
        var parts = [linkStateText]
        if model.isConnected, let p50 = model.rttP50 { parts.append("\(Self.milliseconds(p50)) ms") }
        return parts.joined(separator: " · ")
    }

    private var linkStateText: String {
        switch model.linkState {
        case .unpaired: return "Not paired"
        case .suspended: return "Paused"
        case .backoff, .connecting, .awaitingWelcome: return "Connecting…"
        case .connected: return "Connected"
        case .replaced: return model.lastGoodbye == .replaced ? "In use by another iPad" : "Disconnected"
        case .macTooOld:
            return model.lastGoodbye == .protocolMismatch ? "Update iKey" : "Update iKey on your Mac"
        case .needsRepair: return "Can't connect — the pairing key may have changed"
        }
    }

    // MARK: Pairing (unpaired, needsRepair, macTooOld; the pairing card on the deck offers the same)

    /// Unpaired, or a needsRepair / macTooOld episode (also after "Keep waiting" hid the card), so a
    /// new key can always be pasted here.
    private var showsPairingSection: Bool { !model.isPaired || model.pairingEpisode != nil }

    private var pairingSectionTitle: String {
        switch model.pairingEpisode?.kind {
        case .needsRepair?: return "Pair again"
        case .macTooOld?: return "Pair with another Mac"
        case nil: return "Pair with your Mac"
        }
    }

    private var pairingSection: some View {
        Section {
            if model.isWaitingOutRepair {
                Text("iKey keeps trying the stored key. If you reset pairing on the Mac, paste its new key here.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Show the pairing card again") {
                    model.stopWaitingForRepair()
                    model.isPanelPresented = false
                }
            }
            Text(model.discoveryStatus).font(.footnote).foregroundStyle(.secondary)
            if !model.peers.isEmpty {
                Picker("Mac", selection: $model.selectedPeerID) {
                    Text("Choose a Mac").tag("")
                    ForEach(model.peers) { peer in Text(peer.name).tag(peer.id) }
                }
            }
            // No content type (never .password): the key stays device-only and must never be offered to
            // Passwords / iCloud Keychain AutoFill or saving (amendment A2).
            SecureField("Paste the pairing key from your Mac", text: $model.pairingText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { if model.canConnect { model.connect() } }
                .accessibilityHint("64 hexadecimal characters, shown by iKey on the Mac.")
            // An automatic retry shows as "Connecting…" until a key is pasted, which may pre-empt it.
            Button(model.isConnecting && !model.canConnect ? "Connecting…" : "Connect") { model.connect() }
                .disabled(!model.canConnect)
            if let hint = model.connectionHint {
                Text(hint).font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                model.startDiscovery()
            } label: {
                HStack {
                    if model.isRefreshing { ProgressView().controlSize(.small) }
                    Text(model.isRefreshing ? "Searching for Macs…" : "Refresh nearby Macs")
                }
            }
            .disabled(model.isRefreshing || model.isConnecting)
        } header: {
            Text(pairingSectionTitle)
        }
    }

    // MARK: Your MacBook

    private var macBookSection: some View {
        Section {
            Picker("Model", selection: modelChoice) {
                Text(autoModelLabel).tag(MacBookAirModel?.none)
                ForEach(MacBookAirModel.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(MacBookAirModel?.some(preset))
                }
            }
            if let hwModel = model.welcome?.model, MacModelCatalog.isFifteenInch(hardwareModel: hwModel) {
                Text("This Mac is a 15-inch MacBook Air. iKey draws the 13-inch deck, which is all that fits on the iPad.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            LabeledContent("Finish") {
                HStack(spacing: 14) {
                    ForEach(model.effectiveModel.finishes, id: \.self) { finish in
                        finishSwatch(finish)
                    }
                }
            }
            LabeledContent("Keyboard glow") {
                Picker("Keyboard glow", selection: $model.preferences.appearance.glow) {
                    Text("Off").tag(KeyboardGlowSetting.off)
                    Text("Auto").tag(KeyboardGlowSetting.auto)
                    Text("On").tag(KeyboardGlowSetting.on)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
            }
            Button("Fit & size…", action: onFitAndSize)
        } header: {
            Text("Your MacBook")
        } footer: {
            Text("Auto glow lights the key legends when the screen is dim.")
        }
    }

    /// nil is Auto (the model the Mac reports).
    private var modelChoice: Binding<MacBookAirModel?> {
        Binding(
            get: { model.preferences.appearance.modelIsManual ? model.preferences.appearance.model : nil },
            set: { model.noteManualModelChoice($0) })
    }

    private var autoModelLabel: String {
        if let detected = model.detectedMacModel { return "Auto (detected: \(detected.displayName))" }
        return "Auto (\(MacBookAirModel.defaultModel.displayName) until a Mac connects)"
    }

    private func finishSwatch(_ finish: DeckFinish) -> some View {
        let selected = finish == model.effectiveFinish
        let deck = DeckPalette.palette(finish).deck
        return Button {
            model.preferences.appearance.finish = finish
        } label: {
            Circle()
                .fill(Color(.sRGB, red: deck.r, green: deck.g, blue: deck.b, opacity: 1))
                .frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                .padding(3)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(selected ? 1 : 0))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(finish.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Typing

    private var typingSection: some View {
        Section {
            Picker("Resting fingers", selection: $model.preferences.typing.resting) {
                Text("Off").tag(RestingFingers.off)
                Text("Home row").tag(RestingFingers.homeRow)
                Text("All typing keys").tag(RestingFingers.allTypingKeys)
            }
            DisclosureGroup("Advanced typing", isExpanded: $typingAdvanced) {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Rest time", value: String(format: "%.2f s", restTime.wrappedValue))
                    Slider(value: restTime, in: 0.15...0.35, step: 0.01) { Text("Rest time") }
                    Text("A touch held longer than this rests instead of typing.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .disabled(model.preferences.typing.resting == .off)
                Toggle("Hold a home-row key alone to repeat it", isOn: $model.preferences.typing.isolatedHold)
                    .disabled(model.preferences.typing.resting == .off)
            }
            LabeledContent("Key press look") {
                Picker("Key press look", selection: $model.preferences.appearance.pressLook) {
                    Text("Off").tag(PressLookSetting.off)
                    Text("Subtle").tag(PressLookSetting.subtle)
                    Text("Clear").tag(PressLookSetting.clear)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
            }
        } header: {
            Text("Typing")
        } footer: {
            Text(restingCaption)
        }
    }

    /// `tapMax`, shown within the range the pipeline uses.
    private var restTime: Binding<Double> {
        Binding(
            get: { min(max(model.preferences.typing.tapMax, 0.15), 0.35) },
            set: { model.preferences.typing.tapMax = $0 })
    }

    private var restingCaption: String {
        let typing = model.preferences.typing
        switch typing.resting {
        case .off:
            return "Every touch on a key types, so resting fingers type too."
        case .homeRow, .allTypingKeys:
            let base = "Only taps type. Rest your hands on the keys."
            if typing.isolatedHold {
                return base + " To repeat a home-row key, hold it with the other fingers lifted."
            }
            return typing.resting == .homeRow
                ? base + " Keys outside the home row repeat when held."
                : base + " Delete, Return and the arrow keys repeat when held."
        }
    }

    // MARK: Trackpad

    private var trackpadSection: some View {
        Section {
            Text(followsMacLine).font(.footnote).foregroundStyle(.secondary)
            Toggle("Follow my Mac's trackpad settings", isOn: $model.preferences.trackpadFollowsMac)
            if !model.preferences.trackpadFollowsMac {
                Picker("Dragging", selection: $model.preferences.trackpad.dragStyle) {
                    ForEach(dragStyles, id: \.self) { style in Text(Self.title(style)).tag(style) }
                }
                Toggle("Three-finger swipes and Look Up", isOn: $model.preferences.trackpad.threeFingerGestures)
            }
            Toggle("Click with a thumb tap", isOn: $model.preferences.trackpad.thumbClick)
            Toggle("Resting thumb", isOn: $model.preferences.trackpad.restingThumb)
        } header: {
            Text("Trackpad")
        } footer: {
            Text("A resting thumb on the trackpad's front edge is ignored while another finger moves the pointer.")
        }
    }

    /// Read-only: what the Mac's own settings give.
    private var followsMacLine: String {
        guard let prefs = model.macPrefs else {
            return "Follows your Mac: tracking speed and scrolling come from the Mac once it connects."
        }
        let drag = prefs.threeFingerDrag ? "on" : "off"
        return "Follows your Mac: tracking speed \(String(format: "%.2f", prefs.trackingIndex)) of 3 · "
            + "natural scrolling \(prefs.naturalScrolling ? "on" : "off") · three-finger drag \(drag)"
    }

    /// Hold-to-drag is retired; it stays listed only while it is the stored choice.
    private var dragStyles: [DragStyle] {
        let current = model.preferences.trackpad.dragStyle
        return DragStyle.allCases.filter { $0 != .holdToDrag || $0 == current }
    }

    private static func title(_ style: DragStyle) -> String {
        switch style {
        case .tapDrag: return "Tap, then drag"
        case .tapDragLock: return "Tap, then drag with drag lock"
        case .threeFinger: return "Three-finger drag"
        case .holdToDrag: return "Hold, then drag (old)"
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Section("Advanced") {
            Toggle("Palm rejection", isOn: $model.preferences.protection.enabled)
            if model.preferences.protection.enabled {
                Picker("Palm sensitivity", selection: $model.preferences.protection.sensitivity) {
                    ForEach(TouchSensitivity.allCases) { sensitivity in
                        Text(sensitivity.title).tag(sensitivity)
                    }
                }
                Toggle("Pause trackpad while typing", isOn: $model.preferences.protection.pauseTrackpadWhileTyping)
            }
            Toggle("Show touch indicators", isOn: $model.preferences.showTouchIndicators)
            NavigationLink("Photo mode") { PhotoModeSettings(model: model) }
            Picker("Wi-Fi connection", selection: $model.preferences.peerToPeer.setting) {
                Text("Automatic").tag(PeerToPeerSetting.automatic)
                Text("Always allow direct").tag(PeerToPeerSetting.always)
                Text("Never direct").tag(PeerToPeerSetting.never)
            }
            Picker("Open settings by", selection: panelTrigger) {
                Text("Holding Touch ID").tag(PanelTrigger.touchIDHold)
                Text("Two fingers on the left palm rest").tag(PanelTrigger.palmRestTwoFingerHold)
            }
            Button("Flip 180°") {
                NotificationCenter.default.post(name: Notification.Name("iKeyFlipOrientation"), object: nil)
            }
            if model.isPaired {
                Button("Forget this Mac", role: .destructive) { confirmForget = true }
            }
        }
    }

    private var panelTrigger: Binding<PanelTrigger> {
        Binding(
            get: { PanelTrigger(rawValue: model.preferences.panelTriggerRaw) ?? .touchIDHold },
            set: { model.preferences.panelTriggerRaw = $0.rawValue })
    }

    private var diagnosticsSection: some View {
        Section {
            LabeledContent("Round trip", value: roundTripText)
            LabeledContent("Direct Wi-Fi (peer-to-peer)", value: model.preferences.peerToPeer.useP2P() ? "Allowed" : "Off")
            if let resolution = model.projection {
                LabeledContent("iPad", value: resolution.display?.name ?? "Unknown model")
                LabeledContent("Drawing", value: resolution.isTrueScale
                    ? String(format: "True scale, %.3f pt per mm", resolution.projection.ppm)
                    : "Scaled to fit")
            }
        } header: {
            Text("Diagnostics")
        }
    }

    private var roundTripText: String {
        guard let p50 = model.rttP50 else { return "—" }
        let p95 = model.rttP95.map { " · p95 \(Self.milliseconds($0)) ms" } ?? ""
        return "p50 \(Self.milliseconds(p50)) ms" + p95
    }

    private static func milliseconds(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        return String(Int((seconds * 1000).rounded()))
    }
}

/// Photo mode: import a photo of the MacBook, align it, or go back to the drawn deck.
private struct PhotoModeSettings: View {
    @ObservedObject var model: PadModel
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importing = false

    var body: some View {
        Form {
            Section {
                Picker("Deck", selection: $model.preferences.appearance.mode) {
                    Text("Drawn MacBook").tag(DeckMode.drawn)
                    Text("Photo").tag(DeckMode.photo)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("The drawn deck is true to scale. A photo is aligned by hand and is only as accurate as that alignment.")
            }
            Section("Your MacBook photo") {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label(importing ? "Importing photo…" : "Choose a photo", systemImage: "photo")
                }
                .disabled(importing)
                Text("Use a straight-down photo of your MacBook's keyboard, palm rests and trackpad, cropped to the bottom half. Your first photo also switches Deck to Photo.")
                    .font(.footnote).foregroundStyle(.secondary)
                if model.photo != nil {
                    Button("Remove imported photo", role: .destructive) { model.removePhoto() }
                }
                NavigationLink("Align keys and trackpad with the photo") { CalibrationView(model: model) }
            }
            if let message = model.message {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Photo mode")
        .interactiveDismissDisabled(importing)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            importing = true
            Task { @MainActor in
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw PadStoreError.unreadablePhoto
                    }
                    try model.importPhoto(data)
                } catch {
                    model.message = error.localizedDescription
                }
                importing = false
                selectedPhoto = nil
            }
        }
    }
}
