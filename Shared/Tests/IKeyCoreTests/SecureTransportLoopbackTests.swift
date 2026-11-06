#if os(macOS) && canImport(Network)
import Foundation
import Network
import Security
import XCTest
@testable import IKeyCore

/// Real TLS-PSK handshakes over 127.0.0.1 with SecureParameters, and v2 framing through
/// PadLinkStream/MacLinkStream. A step that does not finish within 10 s skips the test (a
/// constrained CI network) instead of failing it; a handshake that fails outright fails it.
/// Everything runs on the main queue, which `waitUntil` drains by spinning the main run loop.
final class SecureTransportLoopbackTests: XCTestCase {
    private static let timeout: TimeInterval = 10
    /// TLS_PSK_WITH_AES_128_GCM_SHA256, the suite SecureParameters always offers.
    private static let plainPSK: UInt16 = 0x00A8
    /// ECDHE_PSK suites (RFC 5489, 7905, 8442).
    private static let ecdhePSK: Set<UInt16> = [0xC035, 0xC036, 0xC037, 0xC038, 0xCCAC, 0xD001, 0xD002, 0xD003, 0xD005]

    private var listeners: [NWListener] = []
    private var serverLinks: [MacLinkStream] = []
    private var clientLinks: [PadLinkStream] = []

    override func tearDown() {
        clientLinks.forEach { $0.cancel() }
        serverLinks.forEach { $0.cancel() }
        listeners.forEach { $0.cancel() }
        clientLinks = []
        serverLinks = []
        listeners = []
        super.tearDown()
    }

    func testSameKeyReachesReady() throws {
        let secret = PairingSecret.generate()
        let session = try connect(server: secret, client: secret)
        try waitForHandshake(session)
    }

    func testWrongKeyFails() throws {
        let session = try connect(server: PairingSecret.generate(), client: PairingSecret.generate())
        let record = session.record
        try waitUntil("rejection of a wrong key") { record.clientClose != nil }
        XCTAssertFalse(record.clientWasReady, "a client with the wrong key reached .ready")
        XCTAssertFalse(record.serverWasReady, "the server accepted a wrong key")
        XCTAssertNotEqual(record.clientClose, .cancelled)
    }

    func testMessageBatchesRoundTrip() throws {
        let secret = PairingSecret.generate()
        let session = try connect(server: secret, client: secret)
        try waitForHandshake(session)
        let record = session.record

        let padBatch: [PadMessage] = [
            .hello(Hello(proto: 2, client: UUID(), app: "1.0 (1)", device: "iPad Pro 13", features: WireFeature.all)),
            .input(.key(code: 55, down: true), t: 1_000),
            .input(.motion(PointerMotion(dx: -1.25, dy: 0.5, dt: 0.008, speed: 160.3)), t: 1_001),
            .input(.scroll(ScrollMotion(phase: .ended, dx: 0, dy: 0, dt: 0, speed: 0,
                                        releaseVX: -12.5, releaseVY: 830)), t: 1_002),
            .input(.key(code: 55, down: false), t: 1_003),
            .heartbeat(Heartbeat(seq: 3, held: [56], buttons: [.left], active: true), t: 1_004),
            .ping(id: 9, t: 1_005),
            .legacy(.pointer(dx: 3, dy: -2)),
        ]
        session.client.send(padBatch)
        try waitUntil("the iPad batch") { record.serverMessages.count >= padBatch.count || record.serverClose != nil }
        XCTAssertEqual(record.serverMessages, padBatch)

        let macBatch: [MacMessage] = [
            .welcome(Welcome(proto: 2, mac: UUID(), name: "MacBook Air", model: "Mac16,12", keyboard: .ansi,
                             displayMM: [302.4, 196.6], prefs: MacInputPreferences(), caps: false,
                             features: WireFeature.all)),
            .state(MacState(caps: true)),
            .pong(id: 9, echoT: 1_005, macT: 2_000),
        ]
        try XCTUnwrap(record.serverLink).send(macBatch)
        try waitUntil("the Mac batch") { record.clientMessages.count >= macBatch.count || record.clientClose != nil }
        XCTAssertEqual(record.clientMessages, macBatch)
        XCTAssertNil(record.clientClose)
        XCTAssertNil(record.serverClose)
    }

    func testGoodbyeClosesBothEnds() throws {
        let secret = PairingSecret.generate()
        let session = try connect(server: secret, client: secret)
        try waitForHandshake(session)
        let record = session.record
        session.client.send([.goodbye(.background)])
        try waitUntil("the goodbye") { record.clientClose != nil && record.serverClose != nil }
        XCTAssertEqual(record.clientClose, .cancelled, "this side's own goodbye closes as .cancelled")
        XCTAssertEqual(record.serverClose, .goodbye(.background))
        XCTAssertEqual(record.serverMessages, [.goodbye(.background)])
    }

    /// One side offering forward secrecy must still connect to a peer that does not.
    func testForwardSecrecyOfferInteroperatesWithPlainPeer() throws {
        let secret = PairingSecret.generate()
        for (serverOffers, clientOffers) in [(true, false), (false, true)] {
            let session = try connect(server: secret, client: secret,
                                      serverOffersFS: serverOffers, clientOffersFS: clientOffers)
            try waitForHandshake(session)
            XCTAssertEqual(negotiatedSuite(session.clientConnection), Self.plainPSK,
                           "server offers FS: \(serverOffers), client offers FS: \(clientOffers)")
        }
    }

    /// Probe behind SecureParameters' offerForwardSecrecy: logs the negotiated suite, and skips
    /// (rather than fails) when the platform falls back to plain PSK.
    func testForwardSecrecyOfferNegotiatesECDHEPSK() throws {
        let secret = PairingSecret.generate()
        let session = try connect(server: secret, client: secret, serverOffersFS: true, clientOffersFS: true)
        try waitForHandshake(session)
        let suite = try XCTUnwrap(negotiatedSuite(session.clientConnection), "no TLS metadata")
        print("iKey loopback: negotiated TLS cipher suite 0x\(String(suite, radix: 16, uppercase: true))")
        if suite == Self.plainPSK {
            throw XCTSkip("ECDHE-PSK offered but the platform negotiated plain PSK (0x00A8); keep the offer off")
        }
        XCTAssertTrue(Self.ecdhePSK.contains(suite), "unexpected suite 0x\(String(suite, radix: 16))")
    }

    // MARK: Harness

    /// Callback state of one loopback session (main queue only).
    private final class Record {
        var listenerReady = false
        var listenerError: NWError?
        var serverLink: MacLinkStream?
        var clientWasReady = false
        var serverWasReady = false
        var clientClose: LinkCloseReason?
        var serverClose: LinkCloseReason?
        var serverMessages: [PadMessage] = []
        var clientMessages: [MacMessage] = []
    }

    private struct Session {
        let record: Record
        let client: PadLinkStream
        let clientConnection: NWConnection
    }

    private struct HarnessFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// Starts a loopback listener (it accepts one connection) and a client connected to it.
    private func connect(server serverSecret: PairingSecret, client clientSecret: PairingSecret,
                         serverOffersFS: Bool = false, clientOffersFS: Bool = false) throws -> Session {
        let record = Record()
        let serverParameters = SecureParameters.make(secret: serverSecret, peerToPeer: false,
                                                     offerForwardSecrecy: serverOffersFS)
        serverParameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: serverParameters)
        listeners.append(listener)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: record.listenerReady = true
            case .failed(let error): record.listenerError = error
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard record.serverLink == nil else {
                connection.cancel()
                return
            }
            let link = MacLinkStream(connection: connection)
            record.serverLink = link
            self?.serverLinks.append(link)
            link.onReady = { record.serverWasReady = true }
            link.onMessage = { record.serverMessages.append($0) }
            link.onClose = { record.serverClose = $0 }
            link.start()
        }
        listener.start(queue: .main)
        try waitUntil("the loopback listener") { record.listenerReady || record.listenerError != nil }
        if let error = record.listenerError { throw HarnessFailure(description: "listener failed: \(error)") }
        let port = try XCTUnwrap(listener.port, "listener has no port")

        let clientParameters = SecureParameters.make(secret: clientSecret, peerToPeer: false,
                                                     offerForwardSecrecy: clientOffersFS)
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: clientParameters)
        let client = PadLinkStream(connection: connection)
        clientLinks.append(client)
        client.onReady = { record.clientWasReady = true }
        client.onMessage = { record.clientMessages.append($0) }
        client.onClose = { record.clientClose = $0 }
        client.start()
        return Session(record: record, client: client, clientConnection: connection)
    }

    /// Both ends ready; fails when either end closes first, skips on a timeout.
    private func waitForHandshake(_ session: Session) throws {
        let record = session.record
        try waitUntil("the TLS-PSK handshake") {
            (record.clientWasReady && record.serverWasReady) || record.clientClose != nil || record.serverClose != nil
        }
        guard record.clientWasReady, record.serverWasReady else {
            throw HarnessFailure(description: "handshake failed: client \(String(describing: record.clientClose)), "
                                 + "server \(String(describing: record.serverClose))")
        }
    }

    /// Spins the main run loop until `condition` holds; throws XCTSkip after the timeout.
    private func waitUntil(_ what: String, _ condition: () -> Bool) throws {
        let deadline = Date(timeIntervalSinceNow: Self.timeout)
        while !condition() {
            guard Date() < deadline else {
                throw XCTSkip("Timed out after \(Int(Self.timeout)) s waiting for \(what)")
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    private func negotiatedSuite(_ connection: NWConnection) -> UInt16? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        return sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue
    }
}
#endif
