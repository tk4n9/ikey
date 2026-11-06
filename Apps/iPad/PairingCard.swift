import SwiftUI
import IKeyCore

/// Pairing UI on the left palm rest (unpaired, needsRepair, macTooOld). Frozen signature;
/// W4-SHELL implements the body.
struct PairingCard: View {
    @ObservedObject var model: PadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.status)
                .font(.headline)
            Picker("Mac", selection: $model.selectedPeerID) {
                ForEach(model.peers) { peer in
                    Text(peer.name).tag(peer.id)
                }
            }
            SecureField("Pairing key", text: $model.pairingText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Connect", action: model.connect)
                .disabled(!model.canConnect)
            if let message = model.message {
                Text(message)
                    .font(.footnote)
            }
        }
        .padding()
    }
}
