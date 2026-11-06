import AppKit
import IKeyCore
import SwiftUI

@main
struct IKeyMacApp: App {
    @StateObject private var receiver = ReceiverModel()
    @StateObject private var deckCheck = DeckCheck()

    var body: some Scene {
        MenuBarExtra("iKey", systemImage: receiver.isConnected ? "keyboard.fill" : "keyboard") {
            ReceiverPanel(receiver: receiver, deckCheck: deckCheck)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu panel

private struct ReceiverPanel: View {
    @ObservedObject var receiver: ReceiverModel
    let deckCheck: DeckCheck
    @State private var showPairingKey = false
    @State private var confirmNewKey = false

    var body: some View {
        // A ViewBuilder block takes at most 10 views before macOS 14, hence the sub-sections.
        VStack(alignment: .leading, spacing: 12) {
            statusSection

            HStack {
                Toggle("Pause iKey", isOn: $receiver.isPaused).toggleStyle(.switch)
                Spacer()
                if receiver.isConnected {
                    Button("Disconnect iPad") { receiver.disconnect() }
                }
            }

            Divider()
            pairingSection

            Divider()
            DisclosureGroup("Settings") {
                SettingsSection(receiver: receiver).padding(.top, 6)
            }
            DisclosureGroup("Key remapping") {
                RemapSection(receiver: receiver).padding(.top, 6)
            }

            Divider()
            toolsAndFooter
        }
        .padding(18)
        .frame(width: 400)
        .onAppear {
            receiver.refreshPermission()
            receiver.refreshLoginItem()
        }
    }

    @ViewBuilder private var statusSection: some View {
        header
        Text(receiver.status).font(.callout).fixedSize(horizontal: false, vertical: true)
        if receiver.keychainProblem != nil {
            Button("Retry") { receiver.retryKeychain() }
        }
        if !receiver.hasInputPermission { permissionSection }
    }

    @ViewBuilder private var toolsAndFooter: some View {
        HStack {
            Button("Check Top-Row Keys…") {
                ToolWindows.shared.show(id: "toprow", title: "Check Top-Row Keys",
                                        size: NSSize(width: 600, height: 660), onClose: nil) {
                    TopRowCheckView(receiver: receiver)
                }
            }
            Button("Deck check…") {
                ToolWindows.shared.show(id: "deckcheck", title: "Deck Check",
                                        size: NSSize(width: 460, height: 520),
                                        onClose: { deckCheck.stop() }) {
                    DeckCheckView(check: deckCheck)
                }
            }
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

    private var header: some View {
        HStack {
            Image(systemName: "ipad.and.iphone").font(.title2)
            VStack(alignment: .leading) {
                Text("iKey").font(.title2.bold())
                Text(receiver.serviceName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(stateWord).font(.caption).foregroundStyle(.secondary)
            Circle().fill(stateColor).frame(width: 9, height: 9)
        }
    }

    private var stateWord: String {
        if receiver.isConnected { return "Connected" }
        if receiver.isListening { return "Ready" }
        return receiver.isPaused ? "Paused" : "Off"
    }

    private var stateColor: Color {
        if receiver.isConnected { return .green }
        return receiver.isListening ? .orange : .gray
    }

    @ViewBuilder private var permissionSection: some View {
        Text("Allow iKey to control keyboard and mouse input on this Mac.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("Allow Input Control") { receiver.requestInputPermission() }
            Button("Check Again") { receiver.refreshPermission() }
        }
        Button("Show This App in Finder") { receiver.showAppInFinder() }
        Text("If access is already enabled, quit and reopen iKey. If needed, re-add this copy of the app in System Settings.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var pairingSection: some View {
        Text("Pairing").font(.headline)
        if !receiver.isPaired || receiver.isPairingAnother {
            Text("Use the same Wi-Fi network. Select this Mac in iKey on your iPad, then paste this pairing key. The key stays the same until you choose New Key. Copied keys are cleared from the clipboard after pairing.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy Pairing Key") { receiver.copyPairingKey() }
                    .disabled(receiver.pairingKey.isEmpty)
                Button(showPairingKey ? "Hide" : "Show") { showPairingKey.toggle() }
                    .disabled(receiver.pairingKey.isEmpty)
                newKeyButton
                if receiver.isPaired && receiver.isPairingAnother {
                    Button("Done") {
                        showPairingKey = false
                        receiver.finishPairingAnother()
                    }
                }
            }
            if showPairingKey && !receiver.pairingKey.isEmpty {
                Text(receiver.pairingKey)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Your iPad is paired and connects automatically.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Pair another iPad…") {
                    showPairingKey = false
                    receiver.pairAnotherIPad()
                }
                newKeyButton
            }
        }
        if confirmNewKey {
            Text("A new key unpairs every iPad that uses this Mac. Each one needs the new key.")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Replace Key") {
                    confirmNewKey = false
                    showPairingKey = false
                    receiver.rotatePairingKey()
                }
                Button("Cancel") { confirmNewKey = false }
            }
        }
    }

    /// Replacing the key unpairs; ask first once an iPad has paired.
    private var newKeyButton: some View {
        Button("New Key") {
            if receiver.isPaired {
                confirmNewKey = true
            } else {
                showPairingKey = false
                receiver.rotatePairingKey()
            }
        }
    }
}

// MARK: - Settings

private struct SettingsSection: View {
    @ObservedObject var receiver: ReceiverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            loginRows
            connectionAndPointerRows
            keyRows
        }
    }

    @ViewBuilder private var loginRows: some View {
        Toggle("Open at login", isOn: $receiver.launchAtLogin)
        if receiver.loginItemNeedsApproval {
            HStack {
                Text("Approve iKey in System Settings → General → Login Items.").font(.caption)
                Button("Open") { receiver.openLoginItemsSettings() }
            }
        }
        if receiver.runsFromBuildFolder {
            caption("This copy runs from Xcode's build folder, which changes with each build. Copy iKey to Applications and open that copy before turning on Open at login.")
        }
    }

    @ViewBuilder private var connectionAndPointerRows: some View {
        Picker("Wi-Fi connection", selection: $receiver.peerToPeer) {
            Text("Automatic").tag(PeerToPeerSetting.automatic)
            Text("Always allow direct").tag(PeerToPeerSetting.always)
            Text("Never direct").tag(PeerToPeerSetting.never)
        }
        caption("Direct Wi-Fi works without a shared network. Automatic prefers your Wi-Fi network once a connection over it has worked.")
        Text("Tracking speed: follows your Mac (\(Self.decimal(receiver.trackingIndexShown, digits: 4)))")
        slider("Fine-tune", value: $receiver.gainScale, in: 0.75...1.25)
        slider("Scroll speed", value: $receiver.scrollSpeedFactor, in: 0.5...2.0)
    }

    @ViewBuilder private var keyRows: some View {
        Picker("Caps Lock", selection: $receiver.capsModePreference) {
            Text("Automatic").tag(Optional<CapsMode>.none)
            Text("Turns caps lock on").tag(Optional<CapsMode>.some(.system))
            Text("Switches input source").tag(Optional<CapsMode>.some(.switchesInputSource))
            Text("Virtual").tag(Optional<CapsMode>.some(.virtual))
        }
        caption("In effect: \(capsEffect)")
        if receiver.capsMode == .switchesInputSource && receiver.capsHardwareUnavailable {
            Text("Long-press Caps Lock toggle unavailable; input switching still works")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        Picker("Globe key", selection: $receiver.fnTapPreference) {
            Text("Automatic").tag(Optional<FnTapAction>.none)
            Text("Change input source").tag(Optional<FnTapAction>.some(.changeInputSource))
            Text("Emoji & Symbols").tag(Optional<FnTapAction>.some(.emojiAndSymbols))
            Text("Do nothing").tag(Optional<FnTapAction>.some(FnTapAction.none))
        }
    }

    private var capsEffect: String {
        switch receiver.capsMode {
        case .system:
            return "turns caps lock on"
        case .switchesInputSource:
            return "a tap switches input source, a long press turns caps lock on"
        case .virtual:
            // Chosen .system (or Automatic) but the system lock could not be set.
            return receiver.capsModePreference == .virtual ? "virtual" : "virtual (permission needed)"
        }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack {
            Slider(value: value, in: range) { Text(title) }
            Text("×" + Self.decimal(value.wrappedValue, digits: 2))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}

// MARK: - Key remapping

private struct RemapSection: View {
    @ObservedObject var receiver: ReceiverModel
    @State private var newSource: UInt16 = 55
    @State private var newTarget: UInt16 = MacKeyCode.capsLock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Apply my Mac's key remapping", isOn: $receiver.applyKeyRemap)
            caption("iKey's keys bypass macOS key remapping, so iKey repeats this Mac's remapping itself.")

            Text("Detected").font(.subheadline.bold())
            if !receiver.hasReadKeyRemap {
                caption(receiver.isListening ? "Reading this Mac's key remapping…"
                                             : "Read while iKey is on.")
            } else if receiver.detectedKeyRemap.map.isEmpty {
                caption("No key remapping found (hidutil, Modifier Keys, Karabiner-Elements).")
            } else {
                caption("From " + KeyNames.sources(receiver.detectedKeyRemap.sources))
                pairLines(receiver.detectedKeyRemap.map)
            }

            Text("In effect").font(.subheadline.bold())
            if !receiver.applyKeyRemap {
                caption("Off: every key is sent as printed on the iPad.")
            } else if receiver.keyRemap.map.isEmpty {
                caption("No remapping.")
            } else {
                pairLines(receiver.keyRemap.map)
                ForEach(receiver.keyRemap.tapOnlyPadCodes.sorted(), id: \.self) { code in
                    Text("\(KeyNames.name(code)) acts as \(tapOnlyTarget(code)) (tap only)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Extra pairs").font(.subheadline.bold())
            ForEach(receiver.manualKeyRemap.keys.sorted(), id: \.self) { source in
                HStack {
                    Text(KeyNames.pair(source, receiver.manualKeyRemap[source] ?? source)).font(.caption)
                    Spacer()
                    Button("Remove") { receiver.removeManualRemap(source) }.controlSize(.small)
                }
            }
            HStack {
                Picker("", selection: $newSource) {
                    ForEach(KeyNames.editable, id: \.self) { Text(KeyNames.name($0)).tag($0) }
                }
                .labelsHidden()
                Text("→")
                Picker("", selection: $newTarget) {
                    ForEach(KeyNames.editable + [KeyRemap.noAction], id: \.self) { Text(KeyNames.name($0)).tag($0) }
                }
                .labelsHidden()
                Button("Add") { receiver.setManualRemap(newSource, to: newTarget) }
            }
            caption("Extra pairs override the detected ones and apply while remapping is on. A key mapped to itself cancels a detected remap.")
        }
    }

    private func tapOnlyTarget(_ code: UInt16) -> String {
        let target = receiver.keyRemap.apply(code)
        if target == MacKeyCode.capsLock && receiver.capsMode == .switchesInputSource {
            return "Caps Lock / input switch"
        }
        return KeyNames.name(target)
    }

    private func pairLines(_ map: [UInt16: UInt16]) -> some View {
        ForEach(map.keys.sorted(), id: \.self) { source in
            Text(KeyNames.pair(source, map[source] ?? source)).font(.caption)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Plain-word names for Mac virtual keycodes ('Left ⌘ → Caps Lock').
private enum KeyNames {
    private static let special: [UInt16: String] = [
        55: "Left ⌘", 54: "Right ⌘", 58: "Left ⌥", 61: "Right ⌥", 59: "Left ⌃", 62: "Right ⌃",
        56: "Left ⇧", 60: "Right ⇧", 57: "Caps Lock", 63: "fn / Globe", 53: "Esc", 48: "Tab",
        36: "Return", 51: "Delete", 117: "Forward Delete", 49: "Space",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        KeyRemap.noAction: "No Action",
    ]
    /// Letters A-Z, digits 1-0, then punctuation, in the editor's order.
    private static let characterKeys: [(code: UInt16, name: String)] = [
        (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"),
        (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"),
        (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
        (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
        (29, "0"), (27, "-"), (24, "="), (33, "["), (30, "]"), (42, "\\"), (41, ";"), (39, "'"), (43, ","),
        (47, "."), (44, "/"), (50, "`"),
    ]
    private static let characters = Dictionary(uniqueKeysWithValues: characterKeys.map { ($0.code, $0.name) })
    private static let functionKeys: [UInt16] = MacKeyCode.fKeys + [105, 107, 113, 106, 64, 79, 80, 90]

    /// Keys offered in the manual editor: modifiers and special keys, F-keys, then characters.
    static let editable: [UInt16] = [55, 54, 58, 61, 59, 62, 56, 60, 57, 63, 53, 48, 36, 51, 117, 49,
                                     123, 124, 125, 126, 115, 119, 116, 121]
        + functionKeys + characterKeys.map { $0.code }

    static func name(_ code: UInt16) -> String {
        if let name = special[code] ?? characters[code] { return name }
        if let index = functionKeys.firstIndex(of: code) { return "F\(index + 1)" }
        return "Key \(code)"
    }

    static func pair(_ source: UInt16, _ target: UInt16) -> String {
        source == target ? "\(name(source)) → itself (cancels a detected remap)"
                         : "\(name(source)) → \(name(target))"
    }

    static func sources(_ sources: [KeyRemapSource]) -> String {
        sources.map { source -> String in
            switch source {
            case .hidutil: return "hidutil"
            case .modifierKeys: return "Modifier Keys (System Settings)"
            case .karabiner: return "Karabiner-Elements"
            case .manual: return "iKey"
            }
        }
        .joined(separator: ", ")
    }
}

// MARK: - Tool windows

/// The 'Check Top-Row Keys' and 'Deck check' windows. AppKit-hosted rather than SwiftUI `Window`
/// scenes: on macOS 13/14 SwiftUI opens a menu-bar app's first `Window` scene at launch (opting
/// out needs macOS 15), which the always-on receiver must not do. An agent app is also
/// activated explicitly so the window comes to the front.
@MainActor
private final class ToolWindows: NSObject, NSWindowDelegate {
    static let shared = ToolWindows()

    private var windows: [String: NSWindow] = [:]
    private var closeHandlers: [String: () -> Void] = [:]

    func show<Content: View>(id: String, title: String, size: NSSize, onClose: (() -> Void)?,
                             content: () -> Content) {
        let window: NSWindow
        if let existing = windows[id] {
            window = existing
        } else {
            window = makeWindow(id: id, title: title, size: size, rootView: content())
        }
        closeHandlers[id] = onClose
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow<Content: View>(id: String, title: String, size: NSSize, rootView: Content) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(size)
        window.center()
        windows[id] = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let id = (notification.object as? NSWindow)?.identifier?.rawValue else { return }
        closeHandlers[id]?()
    }
}
