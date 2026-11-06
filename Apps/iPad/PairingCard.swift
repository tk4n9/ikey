import SwiftUI
import IKeyCore

/// Pairing on the left palm rest for unpaired, needsRepair and macTooOld: the only UI that appears by
/// itself. The shell (`PadRootView`) decides when it shows and where it sits. The problem it answers is
/// `PadModel.pairingEpisode` (unpaired wording when there is none).
struct PairingCard: View {
    @ObservedObject var model: PadModel
    /// Opens iKey settings; shown when the card covers the deck's own settings gesture (the
    /// two-finger hold on the left palm rest). nil hides the button.
    var onSettings: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if let onSettings {
                            Button(action: onSettings) {
                                Image(systemName: "gearshape")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("iKey settings")
                        }
                    }
                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                macPicker
                SecureField("Pairing key", text: $model.pairingText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    // No content type (never .password): the key stays device-only and must never be
                    // offered to Passwords / iCloud Keychain AutoFill or saving (amendment A2).
                    .submitLabel(.go)
                    .onSubmit { if model.canConnect { model.connect() } }
                    .accessibilityHint("The 64-character key shown by iKey on your Mac.")
                HStack(spacing: 12) {
                    // An automatic retry in flight shows as "Connecting…" until a key is pasted, which
                    // may pre-empt it (`PadModel.canConnect`).
                    let busy = model.isConnecting && !model.canConnect
                    Button(action: model.connect) {
                        HStack(spacing: 8) {
                            if busy { ProgressView().controlSize(.small) }
                            Text(busy ? "Connecting…" : "Connect")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canConnect)
                    if problem?.kind == .needsRepair {
                        // Reversible: the panel's pairing section can show the card again.
                        Button("Keep waiting") { model.keepWaitingForRepair() }
                            .buttonStyle(.bordered)
                    }
                }
                if let message = model.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let hint = model.connectionHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onChange(of: model.peers.map(\.id), initial: true) { _, ids in
            // One Mac nearby: choose it, so pasting the key is the only step.
            if ids.count == 1, !ids.contains(model.selectedPeerID) { model.selectedPeerID = ids[0] }
        }
    }

    @ViewBuilder private var macPicker: some View {
        if model.peers.isEmpty {
            HStack(spacing: 8) {
                if model.isRefreshing { ProgressView().controlSize(.small) }
                Text(model.discoveryStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Refresh") { model.startDiscovery() }
                    .disabled(model.isRefreshing || model.isConnecting)
            }
        } else {
            Picker("Mac", selection: $model.selectedPeerID) {
                Text("Choose a Mac").tag("")
                ForEach(model.peers) { peer in
                    Text(peer.name).tag(peer.id)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var problem: PairingEpisode? { model.pairingEpisode }

    private var title: String {
        problem?.status ?? "Pair with your Mac"
    }

    private var explanation: String {
        switch problem?.kind {
        case .needsRepair?:
            return "If you reset pairing on the Mac, paste its new key. Otherwise iKey keeps trying on its own."
        case .macTooOld?:
            return "Update iKey on the Mac, or paste another Mac's key to pair with it."
        case nil:
            return "Open iKey on your Mac, copy its pairing key, and paste it here."
        }
    }
}
