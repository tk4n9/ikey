import SwiftUI
import PhotosUI
import IKeyCore

@main
struct IKeyPadApp: App {
    @StateObject private var model = PadModel()

    var body: some Scene {
        WindowGroup { PadRootView(model: model) }
    }
}

struct PadRootView: View {
    @ObservedObject var model: PadModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .topTrailing) {
            DeckSurface(
                image: model.photo,
                layout: model.layout,
                inputEnabled: model.inputEnabled,
                resetGeneration: model.resetGeneration,
                showRegions: false,
                selectedKeyID: nil,
                protection: model.touchProtection,
                showTouchIndicators: model.showTouchIndicators,
                onEvent: model.send
            )
            .ignoresSafeArea()

            if !model.isConnected {
                VStack {
                    Text(model.status)
                        .font(.callout.weight(.medium))
                        .padding(12)
                        .background(.regularMaterial, in: Capsule())
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .allowsHitTesting(false)
            }

            Button {
                model.presentSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Open iKey settings and pause input")
            .padding(8)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $model.isSettingsPresented, onDismiss: model.settingsDismissed) {
            PadSettingsView(model: model)
        }
        .task { model.startDiscovery() }
        .onChange(of: scenePhase) { _, phase in
            model.sceneActiveChanged(phase == .active)
        }
        .onDisappear { model.disconnect() }
    }
}

struct PadSettingsView: View {
    @ObservedObject var model: PadModel
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac connection") {
                    Text(model.status)
                    if !model.isConnected {
                        Text(model.discoveryStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if !model.peers.isEmpty {
                            Picker("Mac", selection: $model.selectedPeerID) {
                                Text("Choose a Mac").tag("")
                                ForEach(model.peers) { peer in
                                    Text(peer.name).tag(peer.id)
                                }
                            }
                        }
                        SecureField("Paste the pairing key from your Mac", text: $model.pairingText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.password)
                            .accessibilityHint("64 hexadecimal characters. The key is kept only for this session.")
                        Button(model.isConnecting ? "Connecting…" : "Connect") {
                            model.connect()
                        }
                        .disabled(!model.canConnect)
                        if let hint = model.connectionHint {
                            Text(hint)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.isConnected || model.isConnecting {
                        Button("Disconnect", role: .destructive) { model.disconnect() }
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
                }

                Section("Your MacBook photo") {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label(importing ? "Importing photo…" : "Choose a photo", systemImage: "photo")
                    }
                    .disabled(importing)
                    Text("Use a straight-down photo of your MacBook's keyboard, palm rests, and trackpad. Crop to the bottom half before importing. iKey preserves the photo's proportions; any unmatched screen area stays black.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if model.photo == nil {
                        Text("The current drawing is an approximate practice layout, not a photo of your MacBook.")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Remove imported photo", role: .destructive) { model.removePhoto() }
                    }
                    NavigationLink("Align keys and trackpad with the photo") {
                        CalibrationView(model: model)
                    }
                }

                Section("Touch controls") {
                    Text("Tap keys, or hold modifiers while tapping another key. Slide one finger on the trackpad to move the pointer. Tap for a click; tap with two fingers for a right click. Slide two fingers to scroll. Hold one finger still briefly, then move it to drag; lift to release.")
                    if model.touchProtection.enabled {
                        Text("Broader thumb taps on Space are recognized when you lift your thumb. Use a fingertip if you want to hold Space to repeat it. Pressing harder is not needed.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Palm rejection") {
                    Toggle("Palm rejection", isOn: $model.touchProtection.enabled)
                    if model.touchProtection.enabled {
                        Picker("Sensitivity", selection: $model.touchProtection.sensitivity) {
                            ForEach(TouchSensitivity.allCases) { sensitivity in
                                Text(sensitivity.title).tag(sensitivity)
                            }
                        }
                        Text("Strict rejects more touches. Relaxed accepts larger finger contacts. Start with Balanced and adjust if intended taps are missed.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Toggle("Pause trackpad while typing", isOn: $model.touchProtection.pauseTrackpadWhileTyping)
                        Text("Helps keep resting palms from moving the pointer as you type. Modifier keys alone still allow gestures such as Shift-drag.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Show touch indicators", isOn: $model.showTouchIndicators)
                    Text("Yellow means a touch is being checked, green means accepted, and red means ignored. Turn this off to see only your MacBook photo.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("This filtering helps with accidental touches, but a resting finger can still look like an intentional tap. It cannot exactly reproduce a physical keyboard or trackpad.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let message = model.message {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("iKey")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use touch surface") { model.isSettingsPresented = false }
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                importing = true
                Task {
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
        .interactiveDismissDisabled(importing)
    }
}
