#if canImport(Network) && canImport(Security)
import Foundation
import Network
import Security

public enum SecureParameters {
    public static func make(secret: PairingSecret) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let key = secret.bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("ikey-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(options,
            tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!)
        // Apple's Network framework supports PSK only with TLS 1.2.
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

/// Main-queue confined transport, shared by the two native apps.
public final class EventStream {
    public var onReady: (() -> Void)?
    public var onEvent: ((InputEvent) -> Void)?
    public var onClose: ((String) -> Void)?
    private let connection: NWConnection
    private var decoder = LineDecoder()
    private var started = false
    private var ready = false
    private var closed = false
    private var pendingBytes = 0
    private static let maxPendingBytes = 65_536

    public init(connection: NWConnection) { self.connection = connection }

    public func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started, !closed else { return }
        started = true
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.ready = true
                self.onReady?()
                self.receive()
            case .failed:
                self.finish("Connection failed. Check the pairing key and local network access.")
            case .cancelled:
                self.finish("Disconnected.")
            case .waiting:
                self.finish("Connection unavailable. Check local network access and reconnect.")
            default: break
            }
        }
        connection.start(queue: .main)
    }

    public func send(_ event: InputEvent) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard ready, !closed else { return }
        do {
            let data = try WireCodec.encode(event)
            guard pendingBytes + data.count <= Self.maxPendingBytes else {
                finish("Connection could not keep up. Reconnect to resume input.")
                return
            }
            pendingBytes += data.count
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                self.pendingBytes -= data.count
                if error != nil { self.finish("Input could not be delivered. Reconnect to resume.") }
            })
        } catch {
            finish("Invalid input event.")
        }
    }

    public func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        finish("Disconnected.")
    }

    private func receive() {
        guard ready, !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                do {
                    for event in try self.decoder.append(data) {
                        guard !self.closed else { return }
                        self.onEvent?(event)
                    }
                } catch {
                    self.finish("Invalid or unsupported input message.")
                    return
                }
            }
            if complete || error != nil {
                self.finish("Disconnected.")
            } else {
                self.receive()
            }
        }
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        ready = false
        connection.stateUpdateHandler = nil
        connection.cancel()
        let callback = onClose
        onReady = nil; onEvent = nil; onClose = nil
        callback?(reason)
    }
}
#endif
