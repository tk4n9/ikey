import Foundation

/// Why a v2 link stream closed.
public enum LinkCloseReason: Equatable, Sendable {
    /// cancel() was called, a goodbye this side sent was handed to the network (or could not be
    /// sent because the link was not ready), or the connection was cancelled.
    case cancelled
    /// The connection failed; the associated value describes the NWError.
    case failed(String)
    /// The network path became unavailable.
    case waiting
    /// A frame could not be encoded or decoded.
    case protocolError
    /// The peer closed the connection or a receive failed.
    case peerClosed
    /// More than 64 KiB was waiting to be sent.
    case overflow
    /// The peer sent a goodbye. Never reported for a goodbye this side sent (that is `.cancelled`).
    case goodbye(GoodbyeReason)
}

#if canImport(Network) && canImport(Security)
import Network
import Security

public enum SecureParameters {
    /// Today's parameters: peer-to-peer allowed, no forward-secrecy offer.
    public static func make(secret: PairingSecret) -> NWParameters {
        make(secret: secret, peerToPeer: true)
    }

    /// TLS 1.2 PSK over TCP with interactive-voice service class. With `offerForwardSecrecy`
    /// the ECDHE-PSK suite is offered first; the plain PSK suite stays as the fallback.
    public static func make(secret: PairingSecret, peerToPeer: Bool, offerForwardSecrecy: Bool = false) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let key = secret.bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("ikey-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, identity as __DispatchData)
        if offerForwardSecrecy {
            // TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 (RFC 7905). The raw IANA value is used
            // because the SDK may not name it in tls_ciphersuite_t.
            sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0xCCAC)!)
        }
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
        parameters.includePeerToPeer = peerToPeer
        parameters.serviceClass = .interactiveVoice
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
/// Protocol v2 link on the iPad side: sends PadMessages, receives MacMessages.
public final class PadLinkStream {
    private let core: LinkCore<MacMessage, PadMessage>

    public var onReady: (() -> Void)? { get { core.onReady } set { core.onReady = newValue } }
    public var onMessage: ((MacMessage) -> Void)? { get { core.onMessage } set { core.onMessage = newValue } }
    public var onClose: ((LinkCloseReason) -> Void)? { get { core.onClose } set { core.onClose = newValue } }

    public init(connection: NWConnection) {
        var decoder = MacFrameDecoder()
        core = LinkCore(connection: connection,
                        encode: { (message: PadMessage) in try WireV2.encode(message) },
                        decode: { (data: Data) in try decoder.append(data) })
    }

    public func start() { core.start() }
    /// Sends the batch as one write, in order. A goodbye ends the batch and closes the link with
    /// `.cancelled` once it has been handed to the network; a batch holding a goodbye sent
    /// before the link is ready closes it with `.cancelled` at once, so onClose always follows.
    /// Any message that fails validation drops the batch and closes with `.protocolError`.
    public func send(_ messages: [PadMessage]) { core.send(messages) }
    public func cancel() { core.cancel() }
}

/// Protocol v2 link on the Mac side: sends MacMessages, receives PadMessages (v1 frames arrive
/// as `.legacy`).
public final class MacLinkStream {
    private let core: LinkCore<PadMessage, MacMessage>

    public var onReady: (() -> Void)? { get { core.onReady } set { core.onReady = newValue } }
    public var onMessage: ((PadMessage) -> Void)? { get { core.onMessage } set { core.onMessage = newValue } }
    public var onClose: ((LinkCloseReason) -> Void)? { get { core.onClose } set { core.onClose = newValue } }

    public init(connection: NWConnection) {
        var decoder = PadFrameDecoder()
        core = LinkCore(connection: connection,
                        encode: { (message: MacMessage) in try WireV2.encode(message) },
                        decode: { (data: Data) in try decoder.append(data) })
    }

    public func start() { core.start() }
    /// Sends the batch as one write, in order. A goodbye ends the batch and closes the link with
    /// `.cancelled` once it has been handed to the network; a batch holding a goodbye sent
    /// before the link is ready closes it with `.cancelled` at once, so onClose always follows.
    /// Any message that fails validation drops the batch and closes with `.protocolError`.
    public func send(_ messages: [MacMessage]) { core.send(messages) }
    public func cancel() { core.cancel() }
}

private protocol LinkMessage {
    var goodbyeReason: GoodbyeReason? { get }
}

extension PadMessage: LinkMessage {
    fileprivate var goodbyeReason: GoodbyeReason? {
        if case .goodbye(let reason) = self { return reason }
        return nil
    }
}

extension MacMessage: LinkMessage {
    fileprivate var goodbyeReason: GoodbyeReason? {
        if case .goodbye(let reason) = self { return reason }
        return nil
    }
}

/// Main-queue confined framing over one NWConnection, with EventStream's close semantics.
/// Callbacks are released after the single onClose.
private final class LinkCore<Incoming: LinkMessage, Outgoing: LinkMessage> {
    var onReady: (() -> Void)?
    var onMessage: ((Incoming) -> Void)?
    var onClose: ((LinkCloseReason) -> Void)?
    private let connection: NWConnection
    private let encode: (Outgoing) throws -> Data
    private let decode: (Data) throws -> [Incoming]
    private var started = false
    private var ready = false
    private var closed = false
    private var goodbyeSent = false
    private var pendingBytes = 0
    private static var maxPendingBytes: Int { 65_536 }

    init(connection: NWConnection, encode: @escaping (Outgoing) throws -> Data,
         decode: @escaping (Data) throws -> [Incoming]) {
        self.connection = connection
        self.encode = encode
        self.decode = decode
    }

    func start() {
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
            case .failed(let error):
                self.finish(.failed("\(error)"))
            case .waiting:
                self.finish(.waiting)
            case .cancelled:
                self.finish(.cancelled)
            default: break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ messages: [Outgoing]) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !closed, !goodbyeSent else { return }
        guard ready else {
            // Nothing can be written yet; a goodbye still ends the link so the caller hears onClose.
            if messages.contains(where: { $0.goodbyeReason != nil }) { finish(.cancelled) }
            return
        }
        var data = Data()
        var goodbye: GoodbyeReason?
        do {
            for message in messages {
                data.append(try encode(message))
                if let reason = message.goodbyeReason {
                    goodbye = reason
                    break
                }
            }
        } catch {
            finish(.protocolError)
            return
        }
        guard !data.isEmpty else { return }
        guard pendingBytes + data.count <= Self.maxPendingBytes else {
            finish(.overflow)
            return
        }
        let count = data.count
        pendingBytes += count
        goodbyeSent = goodbye != nil
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            self.pendingBytes -= count
            if let error {
                self.finish(.failed("\(error)"))
            } else if goodbye != nil {
                // Our own goodbye: .goodbye(r) is reserved for the peer's.
                self.finish(.cancelled)
            }
        })
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        finish(.cancelled)
    }

    private func receive() {
        guard ready, !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                let messages: [Incoming]
                do {
                    messages = try self.decode(data)
                } catch {
                    self.finish(.protocolError)
                    return
                }
                for message in messages {
                    guard !self.closed else { return }
                    self.onMessage?(message)
                    if let reason = message.goodbyeReason {
                        self.finish(.goodbye(reason))
                        return
                    }
                }
                // Messages ahead of a malformed frame were delivered above; the decoder reports
                // that frame's error on its next call.
                guard !self.closed else { return }
                do {
                    _ = try self.decode(Data())
                } catch {
                    self.finish(.protocolError)
                    return
                }
            }
            if complete || error != nil {
                self.finish(.peerClosed)
            } else {
                self.receive()
            }
        }
    }

    private func finish(_ reason: LinkCloseReason) {
        guard !closed else { return }
        closed = true
        ready = false
        connection.stateUpdateHandler = nil
        connection.cancel()
        let callback = onClose
        onReady = nil; onMessage = nil; onClose = nil
        callback?(reason)
    }
}
#endif
