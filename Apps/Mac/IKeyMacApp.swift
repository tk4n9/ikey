import AppKit
import SwiftUI

@main
struct IKeyMacApp: App {
    @StateObject private var receiver = ReceiverModel()

    var body: some Scene {
        MenuBarExtra("iKey", systemImage: receiver.isConnected ? "keyboard.fill" : "keyboard") {
            ReceiverPanel(receiver: receiver)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct ReceiverPanel: View {
    @ObservedObject var receiver: ReceiverModel
    @State private var showPairingKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "ipad.and.iphone")
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text("iKey").font(.title2.bold())
                    Text(receiver.serviceName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(receiver.isConnected ? Color.green : (receiver.isListening ? Color.orange : Color.gray))
                    .frame(width: 9, height: 9)
            }

            Text(receiver.status).font(.callout).fixedSize(horizontal: false, vertical: true)

            if !receiver.hasInputPermission {
                Text("Allow iKey to control keyboard and mouse input on this Mac, then start the receiver.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Allow Input Control") { receiver.requestInputPermission() }
                    Button("Check Again") { receiver.refreshPermission() }
                }
            }

            HStack {
                Button(receiver.isListening ? "Stop Receiver" : "Start Receiver") {
                    if receiver.isListening { receiver.stop() } else { receiver.start() }
                }
                .buttonStyle(.borderedProminent)
                if receiver.isConnected {
                    Button("Disconnect iPad") { receiver.disconnect() }
                }
            }

            Divider()
            Text("Pair your iPad").font(.headline)
            Text("Use the same Wi-Fi network. Select this Mac in iKey on your iPad, then paste this pairing key. The key changes when you quit iKey or choose New Key.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy Pairing Key") { receiver.copyPairingKey() }
                Button(showPairingKey ? "Hide" : "Show") { showPairingKey.toggle() }
                Button("New Key") { receiver.rotatePairingKey() }
                    .disabled(receiver.isListening)
            }
            if showPairingKey {
                Text(receiver.pairingKey)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Text("Input stays on your local connection.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") {
                    receiver.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(18)
        .frame(width: 390)
        .onAppear { receiver.refreshPermission() }
    }
}
