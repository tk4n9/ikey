import XCTest
@testable import IKeyCore

final class ReceiverArbiterTests: XCTestCase {
    private func ids(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }

    /// An arbiter with `id` promoted as `version` at time `t`.
    private func active(_ id: UUID, version: Int = 2, at t: Double = 0) -> ReceiverArbiter {
        var a = ReceiverArbiter()
        XCTAssertEqual(a.handle(.accepted(id: id, remoteHost: "10.0.0.2"), now: t), [])
        XCTAssertEqual(a.handle(.tlsReady(id: id), now: t), [])
        let first: ArbiterInput = version == 2 ? .helloVerified(id: id) : .legacyFrame(id: id)
        XCTAssertEqual(a.handle(first, now: t), [.promote(id: id, version: version)])
        XCTAssertEqual(a.activeID, id)
        XCTAssertEqual(a.activeVersion, version)
        return a
    }

    func testFifthPendingCancelsOldest() {
        var a = ReceiverArbiter()
        let c = ids(6)
        for (i, id) in c.prefix(4).enumerated() {
            XCTAssertEqual(a.handle(.accepted(id: id, remoteHost: "10.0.0.\(i + 1):5000"), now: 0), [])
        }
        XCTAssertEqual(a.handle(.accepted(id: c[4], remoteHost: "10.0.0.9:5000"), now: 0.1), [.cancel(c[0])])
        XCTAssertEqual(a.handle(.accepted(id: c[5], remoteHost: "10.0.0.10:5000"), now: 0.2), [.cancel(c[1])])
        // The cancelled one can no longer be promoted; a surviving one can.
        XCTAssertEqual(a.handle(.helloVerified(id: c[0]), now: 0.3), [])
        XCTAssertNil(a.activeID)
        XCTAssertEqual(a.handle(.helloVerified(id: c[2]), now: 0.3), [.promote(id: c[2], version: 2)])
    }

    func testPerHostCapIgnoresPorts() {
        XCTAssertEqual(ReceiverArbiter.hostKey(fromEndpointDescription: "192.168.1.5:50123"), "192.168.1.5")
        XCTAssertEqual(ReceiverArbiter.hostKey(fromEndpointDescription: "192.168.1.5:50124"), "192.168.1.5")
        XCTAssertEqual(ReceiverArbiter.hostKey(fromEndpointDescription: "fe80::1%en0.50000"), "fe80::1")
        XCTAssertEqual(ReceiverArbiter.hostKey(fromEndpointDescription: "fe80::1c2a:3bff:fe4d:5e6f%en0"), "fe80::1c2a:3bff:fe4d:5e6f")
        XCTAssertEqual(ReceiverArbiter.hostKey(fromEndpointDescription: "fe80::1.50000"), "fe80::1")
        XCTAssertEqual(ReceiverArbiter.hostKey(fromEndpointDescription: "[fe80::1%en0]:50000"), "fe80::1")
        XCTAssertEqual(ReceiverArbiter.hostKey(fromEndpointDescription: "::ffff:192.168.1.5.50000"), "::ffff:192.168.1.5")
        // Bare hosts are already keys.
        for host in ["192.168.1.5", "fe80::1", "::1", "::ffff:192.168.1.5", "ipad.local"] {
            XCTAssertEqual(ReceiverArbiter.hostKey(fromEndpointDescription: host), host)
        }
        XCTAssertEqual(ReceiverArbiter.hostKey(fromEndpointDescription: "My-iPad.local:6000"), "my-ipad.local")

        var a = ReceiverArbiter()
        let c = ids(4)
        XCTAssertEqual(a.handle(.accepted(id: c[0], remoteHost: "192.168.1.5:50123"), now: 0), [])
        XCTAssertEqual(a.handle(.accepted(id: c[1], remoteHost: "192.168.1.5:50124"), now: 0), [])
        // Another host is unaffected.
        XCTAssertEqual(a.handle(.accepted(id: c[2], remoteHost: "192.168.1.6:50124"), now: 0), [])
        XCTAssertEqual(a.handle(.accepted(id: c[3], remoteHost: "192.168.1.5:50125"), now: 0), [.cancel(c[0])])

        var b = ReceiverArbiter()
        let d = ids(3)
        _ = b.handle(.accepted(id: d[0], remoteHost: "fe80::1%en0.50000"), now: 0)
        _ = b.handle(.accepted(id: d[1], remoteHost: "fe80::1%en0.50001"), now: 0)
        XCTAssertEqual(b.handle(.accepted(id: d[2], remoteHost: "fe80::1%awdl0.50002"), now: 0), [.cancel(d[0])])
    }

    func testHandshakeDeadline() {
        var a = ReceiverArbiter()
        let c = ids(2)
        _ = a.handle(.accepted(id: c[0], remoteHost: "10.0.0.1"), now: 0)
        _ = a.handle(.accepted(id: c[1], remoteHost: "10.0.0.2"), now: 1)
        XCTAssertEqual(a.nextDeadline, 3)
        XCTAssertEqual(a.handle(.tick, now: 2.9), [])
        XCTAssertEqual(a.handle(.tlsReady(id: c[0]), now: 2.95), [])
        XCTAssertEqual(a.handle(.tick, now: 3), [.cancel(c[0])])
        XCTAssertEqual(a.nextDeadline, 4)
        XCTAssertEqual(a.handle(.tick, now: 4.5), [.cancel(c[1])])
        XCTAssertNil(a.nextDeadline)
        XCTAssertEqual(a.handle(.helloVerified(id: c[1]), now: 4.6), [])
        XCTAssertNil(a.activeID)
    }

    func testDuplicateAcceptIgnored() {
        let id = UUID()
        var a = ReceiverArbiter()
        XCTAssertEqual(a.handle(.accepted(id: id, remoteHost: "10.0.0.1:5000"), now: 0), [])
        XCTAssertEqual(a.handle(.accepted(id: id, remoteHost: "10.0.0.1:5000"), now: 0), [])
        XCTAssertEqual(a.handle(.helloVerified(id: id), now: 0.1), [.promote(id: id, version: 2)])
        // No leftover pending entry expires and cancels the live session.
        XCTAssertEqual(a.nextDeadline, 0.1 + 4)
        XCTAssertEqual(a.handle(.frame(id: id), now: 3), [])
        XCTAssertEqual(a.handle(.tick, now: 3.5), [])
        XCTAssertEqual(a.activeID, id)
        // A repeat after promotion is ignored too.
        XCTAssertEqual(a.handle(.accepted(id: id, remoteHost: "10.0.0.1:5000"), now: 4), [])
        XCTAssertEqual(a.nextDeadline, 3 + 4)
    }

    func testNewestAuthenticatedReplacesWithReleaseFirst() {
        let c = ids(3)
        var a = active(c[0])
        _ = a.handle(.accepted(id: c[1], remoteHost: "10.0.0.3"), now: 5)
        XCTAssertEqual(a.activeID, c[0])
        XCTAssertEqual(a.handle(.helloVerified(id: c[1]), now: 5.1),
                       [.releaseAllInput, .sendGoodbye(c[0], .replaced), .close(c[0]), .promote(id: c[1], version: 2)])
        XCTAssertEqual(a.activeID, c[1])
        // The replaced one's later close changes nothing.
        XCTAssertEqual(a.handle(.closed(id: c[0]), now: 5.2), [])
        XCTAssertEqual(a.activeID, c[1])
        // A v1 client also wins when it is the newest.
        _ = a.handle(.accepted(id: c[2], remoteHost: "10.0.0.4"), now: 6)
        XCTAssertEqual(a.handle(.legacyFrame(id: c[2]), now: 6.1),
                       [.releaseAllInput, .sendGoodbye(c[1], .replaced), .close(c[1]), .promote(id: c[2], version: 1)])
        XCTAssertEqual(a.activeVersion, 1)
        // Later legacy frames on the active v1 session are ordinary frames.
        XCTAssertEqual(a.handle(.legacyFrame(id: c[2]), now: 8), [])
        XCTAssertEqual(a.handle(.tick, now: 10.9), [])
        // Closing the active session releases input.
        XCTAssertEqual(a.handle(.closed(id: c[2]), now: 11), [.releaseAllInput])
        XCTAssertNil(a.activeID)
        XCTAssertNil(a.activeVersion)
    }

    func testV2SilenceClosesAt4sV1At3s() {
        let id = UUID()
        var v2 = active(id, version: 2, at: 10)
        XCTAssertEqual(v2.nextDeadline, 14)
        XCTAssertEqual(v2.handle(.tick, now: 13.9), [])
        XCTAssertEqual(v2.handle(.tick, now: 14), [.releaseAllInput, .close(id)])
        XCTAssertNil(v2.activeID)
        XCTAssertNil(v2.nextDeadline)
        XCTAssertEqual(v2.handle(.closed(id: id), now: 14.1), [])

        var v1 = active(id, version: 1, at: 10)
        XCTAssertEqual(v1.nextDeadline, 13)
        XCTAssertEqual(v1.handle(.tick, now: 12.9), [])
        XCTAssertEqual(v1.handle(.tick, now: 13), [.releaseAllInput, .close(id)])
        XCTAssertNil(v1.activeID)
    }

    func testDeadManReleasesAt1sKeepsLink() {
        let id = UUID()
        var a = active(id)
        XCTAssertEqual(a.handle(.frame(id: id), now: 1), [])
        XCTAssertEqual(a.handle(.heldInputChanged(true), now: 1), [])
        XCTAssertEqual(a.nextDeadline, 2)
        XCTAssertEqual(a.handle(.tick, now: 1.9), [])
        XCTAssertEqual(a.handle(.tick, now: 2), [.releaseAllInput])
        // Once per silence; the link stays up.
        XCTAssertEqual(a.handle(.tick, now: 2.5), [])
        XCTAssertEqual(a.activeID, id)
        XCTAssertEqual(a.nextDeadline, 5)
        // A frame re-arms it.
        _ = a.handle(.frame(id: id), now: 3)
        XCTAssertEqual(a.handle(.tick, now: 4), [.releaseAllInput])
        // Nothing held: no dead-man.
        _ = a.handle(.heldInputChanged(false), now: 4.1)
        _ = a.handle(.frame(id: id), now: 4.25)
        XCTAssertEqual(a.handle(.tick, now: 6), [])
        XCTAssertEqual(a.nextDeadline, 8.25)
        // Frames from a non-active connection do not keep the session alive.
        _ = a.handle(.frame(id: UUID()), now: 8)
        XCTAssertEqual(a.handle(.tick, now: 8.25), [.releaseAllInput, .close(id)])
    }

    func testHeartbeatsKeepIdleSessionUp() {
        let id = UUID()
        var a = active(id)
        var all: [ArbiterCommand] = []
        for second in 1...20 {
            let t = Double(second)
            all += a.handle(.frame(id: id), now: t)
            all += a.handle(.tick, now: t + 0.25)
            all += a.handle(.tick, now: t + 0.75)
        }
        XCTAssertEqual(all, [])
        XCTAssertEqual(a.activeID, id)

        // While input is held, 100 ms heartbeats keep the dead-man quiet.
        _ = a.handle(.heldInputChanged(true), now: 21)
        for step in 0...30 {
            let t = 21 + Double(step) * 0.1
            all += a.handle(.frame(id: id), now: t)
            all += a.handle(.tick, now: t + 0.05)
        }
        XCTAssertEqual(all, [])
    }

    func testStopSendsGoodbye() {
        let c = ids(3)
        var a = active(c[0])
        _ = a.handle(.accepted(id: c[1], remoteHost: "10.0.0.7"), now: 1)
        _ = a.handle(.accepted(id: c[2], remoteHost: "10.0.0.8"), now: 1)
        XCTAssertEqual(a.handle(.stop(.macSleeping), now: 2),
                       [.releaseAllInput, .sendGoodbye(c[0], .macSleeping), .close(c[0]), .cancel(c[1]), .cancel(c[2])])
        XCTAssertNil(a.activeID)
        XCTAssertNil(a.nextDeadline)
        XCTAssertEqual(a.handle(.tick, now: 10), [])

        var idle = ReceiverArbiter()
        XCTAssertEqual(idle.handle(.stop(.receiverStopping), now: 0), [.releaseAllInput])
    }

    func testTwoHandshakeFailuresShowPairingHint() {
        var a = ReceiverArbiter()
        let c = ids(6)
        _ = a.handle(.accepted(id: c[0], remoteHost: "10.0.0.5:6000"), now: 0)
        XCTAssertEqual(a.handle(.handshakeFailed(id: c[0]), now: 0.1), [])
        // A failure from another host does not count toward this one.
        _ = a.handle(.accepted(id: c[1], remoteHost: "10.0.0.6:6000"), now: 0.2)
        XCTAssertEqual(a.handle(.handshakeFailed(id: c[1]), now: 0.3), [])
        _ = a.handle(.accepted(id: c[2], remoteHost: "10.0.0.5:6001"), now: 0.4)
        XCTAssertEqual(a.handle(.handshakeFailed(id: c[2]), now: 0.5), [.showPairingHint(remoteHost: "10.0.0.5")])
        XCTAssertNil(a.nextDeadline)

        // A successful handshake from the host resets its count.
        _ = a.handle(.accepted(id: c[3], remoteHost: "10.0.0.6:6001"), now: 1)
        _ = a.handle(.tlsReady(id: c[3]), now: 1.1)
        _ = a.handle(.helloVerified(id: c[3]), now: 1.2)
        _ = a.handle(.accepted(id: c[4], remoteHost: "10.0.0.6:6002"), now: 2)
        XCTAssertEqual(a.handle(.handshakeFailed(id: c[4]), now: 2.1), [])
        // Unknown ids are ignored.
        XCTAssertEqual(a.handle(.handshakeFailed(id: c[5]), now: 2.2), [])
    }

    func testListenerBackoff() {
        var b = ListenerBackoff()
        XCTAssertEqual((0..<7).map { _ in b.nextDelay() }, [0.5, 1, 2, 5, 5, 5, 5])
        b.reset()
        XCTAssertEqual(b.nextDelay(), 0.5)
        XCTAssertEqual(b.nextDelay(), 1)

        var custom = ListenerBackoff(delays: [3])
        XCTAssertEqual([custom.nextDelay(), custom.nextDelay()], [3, 3])
        var empty = ListenerBackoff(delays: [])
        XCTAssertEqual(empty.nextDelay(), 0)
    }

    func testTimingDefaults() {
        let t = ArbiterTiming()
        XCTAssertEqual(t.maxPending, 4)
        XCTAssertEqual(t.maxPendingPerHost, 2)
        XCTAssertEqual(t.handshakeDeadline, 3)
        XCTAssertEqual(t.deadMan, 1)
        XCTAssertEqual(t.linkTimeoutV2, 4)
        XCTAssertEqual(t.linkTimeoutV1, 3)
    }
}
