import AppKit
import Combine
import CoreGraphics
import Foundation
import IKeyCore
import Network

/// Network callbacks and state transitions are serialized on the main queue.
final class ReceiverModel: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isConnected = false
    @Published private(set) var hasInputPermission = false
    @Published private(set) var status = "Start the receiver to connect your iPad."
    @Published private var secret = PairingSecret.generate()

    let serviceName: String = {
        // Bonjour instance names are limited by UTF-8 bytes, not character count.
        var name = ""
        for character in Host.current().localizedName ?? "Mac" {
            guard (name + String(character)).utf8.count <= 48 else { break }
            name.append(character)
        }
        return (name.isEmpty ? "Mac" : name) + " — iKey"
    }()
    var pairingKey: String { secret.hex }

    private let injector = EventInjector()
    private var listener: NWListener?
    private var listenerID: UUID?
    private var stream: EventStream?
    private var streamID: UUID?
    private var handshakeStarted: TimeInterval = 0
    private var lastReceived: TimeInterval = 0
    private var watchdog: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        refreshPermission()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.stop() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.stop(reason: "Receiver stopped because this Mac went to sleep.") })
    }

    deinit {
        watchdog?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func refreshPermission() {
        let previouslyGranted = hasInputPermission
        hasInputPermission = CGPreflightPostEventAccess()
        if !hasInputPermission && isListening {
            stop(reason: "Input control permission was removed. Allow input control and start again.")
        } else if hasInputPermission && !previouslyGranted && !isListening {
            status = "Input control allowed. Choose Start Receiver to make this Mac discoverable."
        }
    }

    func showAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func requestInputPermission() {
        _ = CGRequestPostEventAccess()
        refreshPermission()
        if !hasInputPermission {
            status = "Allow iKey in System Settings → Privacy & Security → Accessibility, then choose Check Again."
        }
    }

    func copyPairingKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(secret.hex, forType: .string)
    }

    func rotatePairingKey() {
        guard !isListening else { return }
        secret = PairingSecret.generate()
        status = "New pairing key ready. Copy it to your iPad before connecting."
    }

    func start() {
        guard listener == nil else { return }
        refreshPermission()
        guard hasInputPermission else {
            status = "Allow input control before starting the receiver."
            return
        }
        do {
            let newListener = try NWListener(using: SecureParameters.make(secret: secret))
            let id = UUID()
            listenerID = id
            listener = newListener
            isListening = true
            status = "Starting local receiver…"
            newListener.service = NWListener.Service(name: serviceName, type: IKeyService.bonjourType)
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self, self.listenerID == id else { return }
                switch state {
                case .ready:
                    if !self.isConnected { self.status = "Ready. Connect from iKey on your iPad." }
                case .waiting:
                    self.status = "Waiting for local-network access. Check Wi-Fi and the Local Network permission in System Settings."
                case .failed:
                    self.stop(reason: "Could not start the receiver. Check Wi-Fi and local-network permission, then try again.")
                case .cancelled:
                    self.stop()
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            newListener.start(queue: .main)
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkConnection() }
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        } catch {
            stop(reason: "Could not create the local receiver. Try starting it again.")
        }
    }

    func stop(reason: String = "Receiver stopped.") {
        watchdog?.invalidate()
        watchdog = nil
        listenerID = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        isListening = false
        closeStream()
        status = reason
    }

    func disconnect() {
        closeStream()
        status = isListening ? "iPad disconnected. Ready for a new connection." : "Receiver stopped."
    }

    private func accept(_ connection: NWConnection) {
        // Only one pending handshake or authenticated connection is allowed at a time.
        guard isListening, stream == nil else {
            connection.cancel()
            return
        }
        refreshPermission()
        guard hasInputPermission, isListening else {
            connection.cancel()
            return
        }
        let incoming = EventStream(connection: connection)
        let id = UUID()
        stream = incoming
        streamID = id
        handshakeStarted = ProcessInfo.processInfo.systemUptime
        status = "Checking the iPad's pairing key…"
        incoming.onReady = { [weak self] in
            guard let self, self.streamID == id else { return }
            self.refreshPermission()
            guard self.hasInputPermission, self.streamID == id else { return }
            self.isConnected = true
            self.lastReceived = ProcessInfo.processInfo.systemUptime
            self.status = "iPad connected. Keyboard and trackpad are ready."
        }
        incoming.onEvent = { [weak self] event in
            guard let self, self.streamID == id, self.isConnected else { return }
            // The watchdog refreshes permission every 0.5 seconds; avoid a
            // privacy-database query for every high-frequency pointer event.
            guard self.hasInputPermission, self.streamID == id else { return }
            self.lastReceived = ProcessInfo.processInfo.systemUptime
            self.injector.handle(event)
        }
        incoming.onClose = { [weak self] _ in
            guard let self, self.streamID == id else { return }
            self.closeStream()
            self.status = "iPad disconnected. Check the pairing key and reconnect."
        }
        incoming.start()
    }

    private func checkConnection() {
        refreshPermission()
        guard stream != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !isConnected && now - handshakeStarted > 8 {
            closeStream()
            status = "Pairing timed out. Check the key on your iPad and reconnect."
        } else if isConnected && now - lastReceived > 3 {
            closeStream()
            status = "Connection interrupted. Held keys and mouse buttons were released. Reconnect from your iPad."
        }
    }

    private func closeStream() {
        streamID = nil
        stream?.onReady = nil
        stream?.onEvent = nil
        stream?.onClose = nil
        stream?.cancel()
        stream = nil
        isConnected = false
        injector.releaseAll()
    }
}
