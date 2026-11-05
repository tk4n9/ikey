import Foundation
import Combine
import UIKit
import ImageIO
import Network
import IKeyCore

struct MacPeer: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

/// Networking callbacks and UI state are confined to the main queue.
final class PadModel: ObservableObject {
    @Published var peers: [MacPeer] = []
    @Published var selectedPeerID = ""
    @Published var pairingText = ""
    @Published var status = "Not connected"
    @Published var message: String?
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var discoveryStatus = "Search for your Mac after starting its receiver."
    @Published var isSettingsPresented = true
    @Published private(set) var photo: UIImage?
    @Published private(set) var layout = DeckLayout.macBookANSI
    @Published private(set) var resetGeneration = 0
    @Published var touchProtection = TouchProtectionSettings() {
        didSet {
            guard touchProtection != oldValue else { return }
            if let data = try? JSONEncoder().encode(touchProtection) {
                UserDefaults.standard.set(data, forKey: PreferenceKey.touchProtection)
            }
            resetTouchInput()
        }
    }
    @Published var showTouchIndicators = false {
        didSet {
            guard showTouchIndicators != oldValue else { return }
            UserDefaults.standard.set(showTouchIndicators, forKey: PreferenceKey.showTouchIndicators)
            resetTouchInput()
        }
    }
    @Published private var sceneIsActive = true

    private enum PreferenceKey {
        static let touchProtection = "iKey.touchProtection.v1"
        static let showTouchIndicators = "iKey.showTouchIndicators.v1"
    }

    private var browser: NWBrowser?
    private var stream: EventStream?
    private var heartbeat: Timer?
    private var connectTimeout: DispatchWorkItem?
    private var discoveryTimeout: DispatchWorkItem?
    private var attemptID: UUID?
    private let store = PadStore()

    var inputEnabled: Bool { isConnected && !isSettingsPresented && sceneIsActive }

    var canConnect: Bool {
        !isConnecting && peers.contains(where: { $0.id == selectedPeerID }) &&
        !pairingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var connectionHint: String? {
        if isConnected || isConnecting { return nil }
        if peers.isEmpty { return "Connect becomes available when your Mac appears in the list and you enter its pairing key." }
        if !peers.contains(where: { $0.id == selectedPeerID }) { return "Choose a Mac from the list above." }
        if pairingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Paste the pairing key from the selected Mac to enable Connect." }
        return nil
    }

    init() {
        do { layout = try store.loadLayout() ?? .macBookANSI }
        catch { message = "Saved calibration could not be loaded. The default layout is active." }
        photo = store.loadPhoto()
        let preferences = UserDefaults.standard
        if let data = preferences.data(forKey: PreferenceKey.touchProtection),
           let saved = try? JSONDecoder().decode(TouchProtectionSettings.self, from: data) {
            touchProtection = saved
        }
        showTouchIndicators = preferences.object(forKey: PreferenceKey.showTouchIndicators) as? Bool ?? false
    }

    func startDiscovery() {
        stopDiscovery()
        peers = []
        isRefreshing = true
        discoveryStatus = "Searching for Macs…"
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let next = NWBrowser(for: .bonjour(type: IKeyService.bonjourType, domain: nil), using: parameters)
        browser = next
        next.browseResultsChangedHandler = { [weak self, weak next] results, _ in
            guard let self, let next, self.browser === next else { return }
            self.peers = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return MacPeer(id: String(describing: result.endpoint), name: name, endpoint: result.endpoint)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if !self.peers.contains(where: { $0.id == self.selectedPeerID }) {
                self.selectedPeerID = self.peers.first?.id ?? ""
            }
            if !self.peers.isEmpty {
                self.discoveryTimeout?.cancel()
                self.discoveryTimeout = nil
                self.isRefreshing = false
                self.discoveryStatus = self.peers.count == 1 ? "Found 1 Mac." : "Found \(self.peers.count) Macs."
            } else if case .ready = next.state {
                self.waitForDiscoveryResults(from: next)
            }
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
                    self.isRefreshing = false
                    self.discoveryStatus = self.peers.count == 1 ? "Found 1 Mac." : "Found \(self.peers.count) Macs."
                }
            default: break
            }
        }
        next.start(queue: .main)
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

    private func stopDiscovery() {
        discoveryTimeout?.cancel()
        discoveryTimeout = nil
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        isRefreshing = false
    }

    func connect() {
        guard let peer = peers.first(where: { $0.id == selectedPeerID }) else {
            message = "Choose a nearby Mac first."
            return
        }
        do {
            let secret = try PairingSecret(hex: pairingText.trimmingCharacters(in: .whitespacesAndNewlines))
            disconnect()
            message = nil
            isConnecting = true
            status = "Connecting to \(peer.name)…"
            let id = UUID()
            attemptID = id
            let connection = NWConnection(to: peer.endpoint, using: SecureParameters.make(secret: secret))
            let next = EventStream(connection: connection)
            stream = next
            next.onReady = { [weak self] in
                guard let self, self.attemptID == id else { return }
                self.connectTimeout?.cancel()
                self.connectTimeout = nil
                self.isConnecting = false
                self.isConnected = true
                self.status = "Connected to \(peer.name)"
                self.pairingText = ""
                self.resetGeneration += 1
                self.stream?.send(.releaseAll)
                self.stream?.send(.heartbeat)
                let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                    self?.stream?.send(.heartbeat)
                }
                self.heartbeat = timer
                RunLoop.main.add(timer, forMode: .common)
                self.updateIdleTimer()
            }
            next.onClose = { [weak self] reason in
                guard let self, self.attemptID == id else { return }
                self.disconnect()
                self.status = "Connection ended"
                self.message = "Reconnect to continue. Check that the Mac receiver is running and the pairing key matches. \(reason)"
                self.isSettingsPresented = true
            }
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.attemptID == id, self.isConnecting else { return }
                self.disconnect()
                self.message = "Connection timed out. Check the pairing key, Wi-Fi, and the Mac receiver."
            }
            connectTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
            next.start()
        } catch {
            message = "Paste the full 64-character pairing key shown by iKey on your Mac."
        }
    }

    func send(_ event: InputEvent) {
        guard inputEnabled else { return }
        stream?.send(event)
    }

    func suspendInput() {
        stream?.send(.releaseAll)
        resetGeneration += 1
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func presentSettings() {
        suspendInput()
        isSettingsPresented = true
    }

    func settingsDismissed() {
        resetGeneration += 1
        updateIdleTimer()
    }

    func sceneActiveChanged(_ active: Bool) {
        sceneIsActive = active
        if active {
            if browser == nil { startDiscovery() }
        } else {
            suspendInput()
            disconnect()
            stopDiscovery()
            isSettingsPresented = true
        }
        updateIdleTimer()
    }

    func disconnect() {
        // Queue a release, then close. The receiver also releases on stream closure.
        stream?.send(.releaseAll)
        attemptID = nil
        connectTimeout?.cancel()
        connectTimeout = nil
        heartbeat?.invalidate()
        heartbeat = nil
        let previous = stream
        stream = nil
        previous?.cancel()
        isConnected = false
        isConnecting = false
        status = "Not connected"
        resetGeneration += 1
        updateIdleTimer()
    }

    func saveLayout(_ draft: DeckLayout) throws {
        let valid = try draft.validated()
        try store.saveLayout(valid)
        layout = valid
        resetGeneration += 1
        message = nil
    }

    func importPhoto(_ data: Data) throws {
        photo = try store.savePhoto(data)
        message = nil
    }

    func removePhoto() {
        do {
            try store.removePhoto()
            photo = nil
        } catch { message = "Could not remove the photo: \(error.localizedDescription)" }
    }

    private func resetTouchInput() {
        stream?.send(.releaseAll)
        resetGeneration += 1
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = inputEnabled
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
