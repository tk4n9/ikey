import XCTest
@testable import IKeyCore

final class ConnectionSupervisorTests: XCTestCase {
    /// A paired supervisor connected at `at` (welcome at `at`), with browsing already reported.
    private func connected(at t: Double = 0, timing: LinkTiming = .init()) -> ConnectionSupervisor {
        var s = ConnectionSupervisor(paired: true, timing: timing)
        XCTAssertEqual(s.handle(.tick, now: t), [.openAttempt, .setBrowsing(true)])
        XCTAssertEqual(s.handle(.attemptReady, now: t), [.sendHello])
        XCTAssertEqual(s.handle(.welcomeReceived, now: t), [.setBrowsing(false)])
        XCTAssertEqual(s.state, .connected(since: t, lastHeard: t))
        return s
    }

    /// Fails the current attempt (ordinary failure) and returns the commands.
    private func fail(_ s: inout ConnectionSupervisor, at t: Double,
                      auth: Bool = false, known: Bool = false) -> [LinkCommand] {
        s.handle(.attemptFailed(authFailure: auth, knownGoodHost: known), now: t)
    }

    func testInitialStates() {
        var unpaired = ConnectionSupervisor(paired: false)
        XCTAssertEqual(unpaired.state, .unpaired)
        XCTAssertNil(unpaired.nextDeadline)
        XCTAssertEqual(unpaired.handle(.tick, now: 1), [.setBrowsing(true)])
        XCTAssertEqual(unpaired.handle(.deckTouched, now: 2), [])

        var paired = ConnectionSupervisor(paired: true)
        XCTAssertEqual(paired.nextDeadline, 0)
        XCTAssertEqual(paired.handle(.active, now: 5), [.openAttempt, .setBrowsing(true)])
        XCTAssertEqual(paired.state, .connecting(startedAt: 5))
    }

    func testInactiveKeepsLink() {
        var s = connected()
        XCTAssertEqual(s.handle(.inactive, now: 1), [.releaseHeldInput])
        XCTAssertEqual(s.state, .connected(since: 0, lastHeard: 0))
        XCTAssertEqual(s.handle(.active, now: 1.1), [])
        XCTAssertEqual(s.state, .connected(since: 0, lastHeard: 0))
    }

    func testBackgroundClosesWithGoodbye() {
        var s = connected()
        XCTAssertEqual(s.handle(.background, now: 1),
                       [.releaseHeldInput, .closeLink(goodbye: .background), .setBrowsing(false)])
        XCTAssertEqual(s.state, .suspended)
        XCTAssertNil(s.nextDeadline)
        // Nothing happens while suspended.
        XCTAssertEqual(s.handle(.tick, now: 30), [])
        XCTAssertEqual(s.handle(.linkClosed(nil), now: 30), [])
        XCTAssertEqual(s.handle(.background, now: 31), [])

        // An attempt in flight is cancelled instead.
        var c = ConnectionSupervisor(paired: true)
        _ = c.handle(.tick, now: 0)
        XCTAssertEqual(c.handle(.background, now: 0.5),
                       [.releaseHeldInput, .cancelAttempt, .setBrowsing(false)])
    }

    func testActiveReconnectsImmediately() {
        var s = connected()
        _ = s.handle(.background, now: 1)
        XCTAssertEqual(s.handle(.active, now: 100), [.openAttempt, .setBrowsing(true)])
        XCTAssertEqual(s.state, .connecting(startedAt: 100))
        XCTAssertEqual(s.handle(.attemptReady, now: 100.05), [.sendHello])
        XCTAssertEqual(s.handle(.welcomeReceived, now: 100.1), [.setBrowsing(false)])
        XCTAssertEqual(s.state, .connected(since: 100.1, lastHeard: 100.1))
    }

    func testBackoffSchedule() {
        var s = ConnectionSupervisor(paired: true)
        _ = s.handle(.tick, now: 0)
        var t = 0.0
        // First failure retries at once; then 0.1, 0.25, 0.5, 1, 1, 2, 2, 4 and 4 s from then on.
        XCTAssertEqual(fail(&s, at: t), [.openAttempt])
        XCTAssertEqual(s.state, .connecting(startedAt: 0))
        for expected in [0.1, 0.25, 0.5, 1, 1, 2, 2, 4, 4, 4] {
            t += 0.01
            XCTAssertEqual(fail(&s, at: t), [])
            XCTAssertEqual(s.state, .backoff(retryAt: t + expected))
            XCTAssertEqual(s.nextDeadline, t + expected)
            XCTAssertEqual(s.handle(.tick, now: t + expected - 0.001), [])
            t += expected
            XCTAssertEqual(s.handle(.tick, now: t), [.openAttempt])
            XCTAssertEqual(s.state, .connecting(startedAt: t))
        }
        // A link that stays up for 5 s resets the schedule.
        _ = s.handle(.attemptReady, now: t)
        _ = s.handle(.welcomeReceived, now: t)
        XCTAssertEqual(s.handle(.linkClosed(nil), now: t + 5), [.openAttempt, .setBrowsing(true)])
        XCTAssertEqual(fail(&s, at: t + 5.1), [])
        XCTAssertEqual(s.state, .backoff(retryAt: t + 5.1 + 0.1))
    }

    func testLinkDroppedRightAfterWelcomeKeepsBackingOff() {
        // A Mac that closes every link just after the welcome (e.g. one bad frame) is not hammered.
        var s = connected()
        var t = 0.0
        var delays: [Double] = []
        for _ in 0..<6 {
            t += 1
            _ = s.handle(.linkClosed(nil), now: t)
            if case .backoff(let at) = s.state {
                delays.append(at - t)
                t = at
                XCTAssertEqual(s.handle(.tick, now: t), [.openAttempt])
            } else {
                delays.append(0)
            }
            XCTAssertEqual(s.state, .connecting(startedAt: t))
            _ = s.handle(.attemptReady, now: t)
            _ = s.handle(.welcomeReceived, now: t)
        }
        let expected = [0, 0.1, 0.25, 0.5, 1, 1]
        XCTAssertEqual(delays.count, expected.count)
        for (got, want) in zip(delays, expected) { XCTAssertEqual(got, want, accuracy: 1e-9) }
        // Mac silence right after a welcome continues the schedule too.
        XCTAssertEqual(s.handle(.tick, now: t + 2.5), [.closeLink(goodbye: nil), .setBrowsing(true)])
        XCTAssertEqual(s.state, .backoff(retryAt: t + 2.5 + 2))
        // A stable link restarts it.
        t += 4.5
        _ = s.handle(.tick, now: t)
        _ = s.handle(.attemptReady, now: t)
        _ = s.handle(.welcomeReceived, now: t)
        _ = s.handle(.heard, now: t + 9)
        XCTAssertEqual(s.handle(.tick, now: t + 11.5), [.closeLink(goodbye: nil), .openAttempt, .setBrowsing(true)])
    }

    /// Builds up `count` consecutive ordinary failures, then connects; returns the welcome time.
    private func failThenConnect(_ s: inout ConnectionSupervisor, failures count: Int) -> Double {
        var t = 0.0
        _ = s.handle(.tick, now: t)
        for _ in 0..<count {
            t += 0.01
            _ = fail(&s, at: t)
            if case .backoff(let at) = s.state {
                t = at
                _ = s.handle(.tick, now: t)
            }
        }
        XCTAssertEqual(s.state, .connecting(startedAt: t))
        _ = s.handle(.attemptReady, now: t)
        _ = s.handle(.welcomeReceived, now: t)
        XCTAssertEqual(s.state, .connected(since: t, lastHeard: t))
        return t
    }

    func testUserDisconnectAfterHealthySessionRestartsBackoff() {
        // Many failures, then an hour-long session that the user ends.
        var s = ConnectionSupervisor(paired: true)
        var t = failThenConnect(&s, failures: 12)
        for _ in 0..<3600 { t += 1; _ = s.handle(.heard, now: t) }
        XCTAssertEqual(s.handle(.userDisconnect, now: t), [.closeLink(goodbye: .user), .setBrowsing(true)])
        XCTAssertEqual(s.state, .replaced)
        // The first failure after the user reconnects retries at once, not after the capped 4 s.
        t += 30
        XCTAssertEqual(s.handle(.deckTouched, now: t), [.openAttempt])
        XCTAssertEqual(fail(&s, at: t + 0.5), [.openAttempt])
        XCTAssertEqual(s.state, .connecting(startedAt: t + 0.5))
        XCTAssertEqual(fail(&s, at: t + 1), [])
        XCTAssertEqual(s.state, .backoff(retryAt: t + 1 + 0.1))

        // Same via userConnect, and even when the user disconnects a link that just welcomed.
        var u = ConnectionSupervisor(paired: true)
        let w = failThenConnect(&u, failures: 12)
        _ = u.handle(.userDisconnect, now: w + 0.2)
        XCTAssertEqual(u.handle(.userConnect, now: w + 1), [.openAttempt])
        XCTAssertEqual(fail(&u, at: w + 1.5), [.openAttempt])

        // A Mac goodbye(.user) parks and restarts the schedule too.
        var g = ConnectionSupervisor(paired: true)
        let gw = failThenConnect(&g, failures: 12)
        _ = g.handle(.linkClosed(.user), now: gw + 0.2)
        XCTAssertEqual(g.state, .replaced)
        XCTAssertEqual(g.handle(.deckTouched, now: gw + 1), [.openAttempt])
        XCTAssertEqual(fail(&g, at: gw + 1.5), [.openAttempt])
    }

    func testUserConnectDuringCappedBackoffRestartsSchedule() {
        var s = ConnectionSupervisor(paired: true)
        _ = s.handle(.tick, now: 0)
        var t = 0.0
        for _ in 0..<12 {
            t += 0.01
            _ = fail(&s, at: t)
            if case .backoff(let at) = s.state { t = at; _ = s.handle(.tick, now: t) }
        }
        t += 0.01
        XCTAssertEqual(fail(&s, at: t), [])
        XCTAssertEqual(s.state, .backoff(retryAt: t + 4))
        // A deck touch only skips the wait; the schedule stays capped.
        XCTAssertEqual(s.handle(.deckTouched, now: t + 1), [.openAttempt])
        XCTAssertEqual(fail(&s, at: t + 1.5), [])
        XCTAssertEqual(s.state, .backoff(retryAt: t + 1.5 + 4))
        // The user's Connect starts it over.
        XCTAssertEqual(s.handle(.userConnect, now: t + 2), [.openAttempt])
        XCTAssertEqual(fail(&s, at: t + 2.5), [.openAttempt])
        XCTAssertEqual(fail(&s, at: t + 3), [])
        XCTAssertEqual(s.state, .backoff(retryAt: t + 3 + 0.1))
    }

    func testUserConnectWhileAttemptInFlightRestartsSchedule() {
        /// A supervisor whose schedule is capped, with an attempt opened at the returned time.
        func cappedAttempt() -> (ConnectionSupervisor, Double) {
            var s = ConnectionSupervisor(paired: true)
            _ = s.handle(.tick, now: 0)
            var t = 0.0
            for _ in 0..<12 {
                t += 0.01
                _ = fail(&s, at: t)
                if case .backoff(let at) = s.state { t = at; _ = s.handle(.tick, now: t) }
            }
            XCTAssertEqual(s.state, .connecting(startedAt: t))
            return (s, t)
        }
        // Control: without userConnect the failure waits the capped 4 s.
        var c = cappedAttempt()
        XCTAssertEqual(fail(&c.0, at: c.1 + 0.5), [])
        XCTAssertEqual(c.0.state, .backoff(retryAt: c.1 + 0.5 + 4))

        // While connecting: no second attempt, but the failure retries at once.
        var (s, t) = cappedAttempt()
        XCTAssertEqual(s.handle(.userConnect, now: t + 0.2), [])
        XCTAssertEqual(s.state, .connecting(startedAt: t))
        XCTAssertEqual(fail(&s, at: t + 0.5), [.openAttempt])
        XCTAssertEqual(fail(&s, at: t + 0.6), [])
        XCTAssertEqual(s.state, .backoff(retryAt: t + 0.6 + 0.1))

        // While awaiting the welcome: same, and a welcome timeout also retries at once.
        var (w, wt) = cappedAttempt()
        XCTAssertEqual(w.handle(.attemptReady, now: wt + 0.1), [.sendHello])
        XCTAssertEqual(w.handle(.userConnect, now: wt + 0.2), [])
        XCTAssertEqual(w.state, .awaitingWelcome(since: wt + 0.1))
        XCTAssertEqual(w.handle(.tick, now: wt + 0.1 + 3), [.closeLink(goodbye: nil), .openAttempt])
        XCTAssertEqual(fail(&w, at: wt + 3.5), [])
        XCTAssertEqual(w.state, .backoff(retryAt: wt + 3.5 + 0.1))

        // Connected and suspended stay ignored.
        var k = connected()
        XCTAssertEqual(k.handle(.userConnect, now: 1), [])
        XCTAssertEqual(k.state, .connected(since: 0, lastHeard: 0))
        _ = k.handle(.background, now: 2)
        XCTAssertEqual(k.handle(.userConnect, now: 3), [])
        XCTAssertEqual(k.state, .suspended)
    }

    func testFlappingLinkStillBacksOffAfterWelcomes() {
        // Welcomes followed by immediate drops (closes or Mac silence) never reset the count, even
        // after a long healthy session ended by a drop restarted it.
        var s = connected()
        var t = 0.0
        for _ in 0..<60 { t += 1; _ = s.handle(.heard, now: t) }
        XCTAssertEqual(s.handle(.linkClosed(nil), now: t), [.openAttempt, .setBrowsing(true)])
        var delays: [Double] = []
        for i in 0..<10 {
            _ = s.handle(.attemptReady, now: t)
            _ = s.handle(.welcomeReceived, now: t)
            t += 0.3
            if i.isMultiple(of: 2) {
                _ = s.handle(.linkClosed(nil), now: t)
            } else {
                // Silence ends this one; .heard just after the welcome does not make it stable.
                let heardAt = t - 0.2
                _ = s.handle(.heard, now: heardAt)
                t = heardAt + 2.6
                XCTAssertEqual(s.handle(.tick, now: t).first, .closeLink(goodbye: nil))
            }
            if case .backoff(let at) = s.state {
                delays.append(at - t)
                t = at
                XCTAssertEqual(s.handle(.tick, now: t), [.openAttempt])
            } else {
                delays.append(0)
            }
            XCTAssertEqual(s.state, .connecting(startedAt: t))
        }
        let expected = [0.1, 0.25, 0.5, 1, 1, 2, 2, 4, 4, 4]
        XCTAssertEqual(delays.count, expected.count)
        for (got, want) in zip(delays, expected) { XCTAssertEqual(got, want, accuracy: 1e-9) }
    }

    func testProtocolMismatchGoodbyeSlowRetries() {
        var s = connected()
        XCTAssertEqual(s.handle(.linkClosed(.protocolMismatch), now: 1), [.setBrowsing(true)])
        XCTAssertEqual(s.state, .macTooOld(retryAt: 11))
        XCTAssertEqual(s.handle(.tick, now: 5), [])
        XCTAssertEqual(s.handle(.deckTouched, now: 6), [])
        XCTAssertEqual(s.handle(.tick, now: 11), [.openAttempt])
        _ = s.handle(.attemptReady, now: 11.1)
        // Refused again before a welcome: still the slow retry.
        XCTAssertEqual(s.handle(.linkClosed(.protocolMismatch), now: 11.2), [])
        XCTAssertEqual(s.state, .macTooOld(retryAt: 21.2))
        // The user may retry at once; a success clears the hold.
        XCTAssertEqual(s.handle(.userConnect, now: 12), [.openAttempt])
        _ = s.handle(.attemptReady, now: 12.1)
        _ = s.handle(.welcomeReceived, now: 12.2)
        XCTAssertEqual(s.handle(.linkClosed(nil), now: 30), [.openAttempt, .setBrowsing(true)])
    }

    func testPathSatisfiedSkipsWait() {
        var s = ConnectionSupervisor(paired: true)
        _ = s.handle(.tick, now: 0)
        _ = fail(&s, at: 0)
        _ = fail(&s, at: 1)
        XCTAssertEqual(s.state, .backoff(retryAt: 1 + 0.1))
        XCTAssertEqual(s.handle(.pathSatisfied(false), now: 1.01), [])
        XCTAssertEqual(s.handle(.pathSatisfied(true), now: 1.02), [.openAttempt])
        XCTAssertEqual(s.state, .connecting(startedAt: 1.02))
        // Not while an attempt is in flight.
        XCTAssertEqual(s.handle(.pathSatisfied(true), now: 1.03), [])

        _ = fail(&s, at: 2)
        XCTAssertEqual(s.handle(.peerAdvertised(proto: 2), now: 2.01), [.openAttempt])
        _ = fail(&s, at: 3)
        XCTAssertEqual(s.handle(.deckTouched, now: 3.01), [.openAttempt])
        _ = fail(&s, at: 4)
        XCTAssertEqual(s.handle(.userConnect, now: 4.01), [.openAttempt])
    }

    func testAttemptTimeout() {
        var s = ConnectionSupervisor(paired: true)
        _ = s.handle(.tick, now: 0)
        XCTAssertEqual(s.nextDeadline, 2.5)
        XCTAssertEqual(s.handle(.tick, now: 2.4), [])
        XCTAssertEqual(s.handle(.tick, now: 2.5), [.cancelAttempt, .openAttempt])
        XCTAssertEqual(s.state, .connecting(startedAt: 2.5))
        XCTAssertEqual(s.handle(.tick, now: 5.0), [.cancelAttempt])
        XCTAssertEqual(s.state, .backoff(retryAt: 5.0 + 0.1))
    }

    func testLateWelcomeIsOrdinaryFailureThenSuccess() {
        var s = ConnectionSupervisor(paired: true)
        _ = s.handle(.tick, now: 0)
        XCTAssertEqual(s.handle(.attemptReady, now: 0.2), [.sendHello])
        XCTAssertEqual(s.nextDeadline, 0.2 + 3.0)
        XCTAssertEqual(s.handle(.tick, now: 3.1), [])
        XCTAssertEqual(s.handle(.tick, now: 3.2), [.closeLink(goodbye: nil), .openAttempt])
        XCTAssertEqual(s.state, .connecting(startedAt: 3.2))
        // The late welcome of the closed link is ignored.
        XCTAssertEqual(s.handle(.welcomeReceived, now: 3.3), [])
        XCTAssertEqual(s.state, .connecting(startedAt: 3.2))
        // A second missing welcome is still an ordinary failure, not macTooOld.
        _ = s.handle(.attemptReady, now: 3.4)
        XCTAssertEqual(s.handle(.tick, now: 6.25), [])
        XCTAssertEqual(s.handle(.tick, now: 6.5), [.closeLink(goodbye: nil)])
        XCTAssertEqual(s.state, .backoff(retryAt: 6.5 + 0.1))
        XCTAssertEqual(s.handle(.tick, now: 7), [.openAttempt])
        _ = s.handle(.attemptReady, now: 7.25)
        XCTAssertEqual(s.handle(.welcomeReceived, now: 7.5), [.setBrowsing(false)])
        XCTAssertEqual(s.state, .connected(since: 7.5, lastHeard: 7.5))
    }

    func testTXTProto1MacTooOldWithoutConnecting() {
        var s = ConnectionSupervisor(paired: true)
        _ = s.handle(.tick, now: 0)
        // The attempt in flight is cancelled.
        XCTAssertEqual(s.handle(.peerAdvertised(proto: 1), now: 0.1), [.cancelAttempt])
        let retryAt = 0.1 + 10
        XCTAssertEqual(s.state, .macTooOld(retryAt: retryAt))
        XCTAssertEqual(s.nextDeadline, retryAt)
        // The slow retry never connects while the TXT still says proto 1.
        XCTAssertEqual(s.handle(.tick, now: retryAt), [])
        XCTAssertEqual(s.state, .macTooOld(retryAt: retryAt + 10))
        XCTAssertEqual(s.handle(.userConnect, now: 11), [])
        XCTAssertEqual(s.handle(.deckTouched, now: 12), [])
        XCTAssertEqual(s.handle(.pathSatisfied(true), now: 13), [])
        XCTAssertEqual(s.state, .macTooOld(retryAt: 21))

        // From backoff too.
        var b = ConnectionSupervisor(paired: true)
        _ = b.handle(.tick, now: 0)
        _ = fail(&b, at: 0)
        _ = fail(&b, at: 0.5)
        XCTAssertEqual(b.handle(.peerAdvertised(proto: 1), now: 0.55), [])
        XCTAssertEqual(b.state, .macTooOld(retryAt: 0.55 + 10))

        // A stale v1 advert while connected changes nothing.
        var c = connected()
        XCTAssertEqual(c.handle(.peerAdvertised(proto: 1), now: 1), [])
        XCTAssertEqual(c.state, .connected(since: 0, lastHeard: 0))

        // Unpaired: adverts are ignored.
        var u = ConnectionSupervisor(paired: false)
        _ = u.handle(.peerAdvertised(proto: 1), now: 0)
        XCTAssertEqual(u.state, .unpaired)
    }

    func testClosedAfterHelloTwiceMacTooOld() {
        var s = ConnectionSupervisor(paired: true)
        _ = s.handle(.tick, now: 0)
        _ = s.handle(.attemptReady, now: 0.1)
        // Once: ordinary failure.
        XCTAssertEqual(s.handle(.closedAfterHello, now: 0.2), [.openAttempt])
        XCTAssertEqual(s.state, .connecting(startedAt: 0.2))
        _ = s.handle(.attemptReady, now: 0.3)
        XCTAssertEqual(s.handle(.closedAfterHello, now: 0.4), [])
        XCTAssertEqual(s.state, .macTooOld(retryAt: 0.4 + 10))
        // Retries every slowRetry; failures keep macTooOld until a success.
        XCTAssertEqual(s.handle(.tick, now: 10.25), [])
        XCTAssertEqual(s.handle(.tick, now: 10.5), [.openAttempt])
        XCTAssertEqual(fail(&s, at: 11), [])
        XCTAssertEqual(s.state, .macTooOld(retryAt: 21))
        _ = s.handle(.tick, now: 21)
        _ = s.handle(.attemptReady, now: 21.1)
        _ = s.handle(.welcomeReceived, now: 21.2)
        XCTAssertEqual(s.state, .connected(since: 21.2, lastHeard: 21.2))

        // Not "in a row" when another failure comes between.
        var r = ConnectionSupervisor(paired: true)
        _ = r.handle(.tick, now: 0)
        _ = r.handle(.closedAfterHello, now: 0.1)
        _ = fail(&r, at: 0.2)
        _ = r.handle(.tick, now: 1)
        _ = r.handle(.closedAfterHello, now: 1.5)
        XCTAssertEqual(r.state, .backoff(retryAt: 1.75))
    }

    func testMacTooOldRetriesOnProto2Advert() {
        var s = ConnectionSupervisor(paired: true)
        _ = s.handle(.tick, now: 0)
        _ = s.handle(.peerAdvertised(proto: 1), now: 0.1)
        XCTAssertEqual(s.handle(.peerAdvertised(proto: 2), now: 3), [.openAttempt])
        XCTAssertEqual(s.state, .connecting(startedAt: 3))
        // The Mac was updated: an ordinary failure now backs off normally.
        XCTAssertEqual(fail(&s, at: 3.5), [.openAttempt])

        // macTooOld from closedAfterHello also retries at once on a proto 2 advert.
        var c = ConnectionSupervisor(paired: true)
        _ = c.handle(.tick, now: 0)
        _ = c.handle(.closedAfterHello, now: 0.1)
        _ = c.handle(.closedAfterHello, now: 0.2)
        XCTAssertEqual(c.state, .macTooOld(retryAt: 0.2 + 10))
        XCTAssertEqual(c.handle(.peerAdvertised(proto: 2), now: 1), [.openAttempt])
        _ = c.handle(.attemptReady, now: 1.1)
        _ = c.handle(.welcomeReceived, now: 1.2)
        XCTAssertEqual(c.state, .connected(since: 1.2, lastHeard: 1.2))
    }

    func testUnknownHostAuthFailuresIgnored() {
        var s = ConnectionSupervisor(paired: true)
        _ = s.handle(.tick, now: 0)
        for i in 0..<20 {
            let t = Double(i) * 10
            if case .connecting = s.state {} else { XCTAssertEqual(s.handle(.userConnect, now: t), [.openAttempt]) }
            _ = fail(&s, at: t, auth: true, known: false)
            if case .needsRepair = s.state { XCTFail("unknown-host auth failures must not need repair") }
        }
    }

    func testRepairNeeds3FailuresOver60s() {
        var s = ConnectionSupervisor(paired: true)
        _ = s.handle(.tick, now: 0)
        // Three quick failures: not yet.
        _ = fail(&s, at: 0, auth: true, known: true)
        _ = fail(&s, at: 1, auth: true, known: true)
        _ = s.handle(.tick, now: 2)
        _ = fail(&s, at: 2, auth: true, known: true)
        XCTAssertEqual(s.state, .backoff(retryAt: 2.25))
        // The streak spans 60 s at the fourth.
        _ = s.handle(.tick, now: 59)
        _ = fail(&s, at: 59.9, auth: true, known: true)
        if case .backoff = s.state {} else { XCTFail("\(s.state)") }
        _ = s.handle(.tick, now: 61)
        XCTAssertEqual(fail(&s, at: 61, auth: true, known: true), [])
        XCTAssertEqual(s.state, .needsRepair(retryAt: 71))

        // Two failures over 70 s are not enough; a success in between restarts the streak.
        var r = ConnectionSupervisor(paired: true)
        _ = r.handle(.tick, now: 0)
        _ = fail(&r, at: 0, auth: true, known: true)
        _ = r.handle(.tick, now: 0)
        _ = fail(&r, at: 70, auth: true, known: true)
        if case .backoff = r.state {} else { XCTFail("\(r.state)") }
        _ = r.handle(.tick, now: 71)
        _ = r.handle(.attemptReady, now: 71)
        _ = r.handle(.closedAfterHello, now: 71.5)
        _ = r.handle(.tick, now: 72)
        _ = fail(&r, at: 72, auth: true, known: true)
        _ = r.handle(.tick, now: 75)
        _ = fail(&r, at: 140, auth: true, known: true)
        if case .backoff = r.state {} else { XCTFail("\(r.state)") }
        _ = r.handle(.tick, now: 145)
        _ = fail(&r, at: 145, auth: true, known: true)
        XCTAssertEqual(r.state, .needsRepair(retryAt: 155))
    }

    func testRepairNeverDeletesPairing() {
        var s = ConnectionSupervisor(paired: true)
        _ = s.handle(.tick, now: 0)
        var all: [LinkCommand] = []
        for t in [0.0, 30, 61] {
            if case .connecting = s.state {} else { all += s.handle(.userConnect, now: t) }
            all += fail(&s, at: t, auth: true, known: true)
        }
        XCTAssertEqual(s.state, .needsRepair(retryAt: 71))
        // Keeps retrying every slowRetry; failures of any kind keep needsRepair.
        var t = 71.0
        for i in 0..<10 {
            all += s.handle(.tick, now: t)
            XCTAssertEqual(s.state, .connecting(startedAt: t))
            all += fail(&s, at: t + 1, auth: i % 2 == 0, known: true)
            XCTAssertEqual(s.state, .needsRepair(retryAt: t + 11))
            t += 11
        }
        XCTAssertFalse(all.contains(.deletePairing))
        // A deck touch retries at once; TLS success (the key works) clears it.
        XCTAssertEqual(s.handle(.deckTouched, now: t - 5), [.openAttempt])
        XCTAssertEqual(s.handle(.attemptReady, now: t - 4), [.sendHello])
        // Back on the ordinary schedule, restarted by the user's Connect at 61 (slow-retry failures
        // under the hold did not advance it).
        XCTAssertEqual(fail(&s, at: t - 3), [.openAttempt])
        XCTAssertEqual(fail(&s, at: t - 2.5), [])
        XCTAssertEqual(s.state, .backoff(retryAt: t - 2.5 + 0.1))
    }

    func testReplacedWaitsForTouch() {
        var s = connected()
        XCTAssertEqual(s.handle(.linkClosed(.replaced), now: 1), [.setBrowsing(true)])
        XCTAssertEqual(s.state, .replaced)
        XCTAssertNil(s.nextDeadline)
        XCTAssertEqual(s.handle(.tick, now: 100), [])
        XCTAssertEqual(s.handle(.pathSatisfied(true), now: 101), [])
        XCTAssertEqual(s.handle(.peerAdvertised(proto: 2), now: 102), [])
        XCTAssertEqual(s.handle(.active, now: 103), [])
        XCTAssertEqual(s.handle(.deckTouched, now: 104), [.openAttempt])

        var u = connected()
        _ = u.handle(.linkClosed(.replaced), now: 1)
        XCTAssertEqual(u.handle(.userConnect, now: 2), [.openAttempt])

        // The user's own disconnect parks the same way.
        var d = connected()
        XCTAssertEqual(d.handle(.userDisconnect, now: 1), [.closeLink(goodbye: .user), .setBrowsing(true)])
        XCTAssertEqual(d.state, .replaced)
        XCTAssertEqual(d.handle(.tick, now: 50), [])

        // Parking survives a background round trip: never take the Mac back or undo a Disconnect.
        for parkingInput in [LinkInput.linkClosed(.replaced), .linkClosed(.user), .userDisconnect] {
            var b = connected()
            _ = b.handle(parkingInput, now: 1)
            XCTAssertEqual(b.handle(.background, now: 2), [.releaseHeldInput, .setBrowsing(false)])
            XCTAssertEqual(b.state, .suspended)
            XCTAssertEqual(b.handle(.active, now: 3), [.setBrowsing(true)], "\(parkingInput)")
            XCTAssertEqual(b.state, .replaced)
            XCTAssertEqual(b.problemSince, 3)
            XCTAssertEqual(b.handle(.tick, now: 60), [])
            XCTAssertEqual(b.handle(.deckTouched, now: 61), [.openAttempt])
            // Once an attempt was made, the next foreground reconnects normally.
            _ = b.handle(.background, now: 62)
            XCTAssertEqual(b.handle(.active, now: 63), [.openAttempt, .setBrowsing(true)])
        }
        // A Disconnect requested while suspended parks too.
        var p = connected()
        _ = p.handle(.background, now: 1)
        XCTAssertEqual(p.handle(.userDisconnect, now: 2), [])
        XCTAssertEqual(p.handle(.active, now: 3), [.setBrowsing(true)])
        XCTAssertEqual(p.state, .replaced)
        XCTAssertEqual(p.handle(.userConnect, now: 4), [.openAttempt])
    }

    func testAuthenticatedUnpairedDeletes() {
        var s = connected()
        XCTAssertEqual(s.handle(.linkClosed(.unpaired), now: 1), [.deletePairing, .setBrowsing(true)])
        XCTAssertEqual(s.state, .unpaired)
        XCTAssertEqual(s.handle(.tick, now: 30), [])

        // Forget: closes the link, deletes, unpaired.
        var f = connected()
        XCTAssertEqual(f.handle(.forgot, now: 1),
                       [.closeLink(goodbye: .user), .deletePairing, .setBrowsing(true)])
        XCTAssertEqual(f.state, .unpaired)
        var b = ConnectionSupervisor(paired: true)
        _ = b.handle(.tick, now: 0)
        _ = fail(&b, at: 0)
        _ = fail(&b, at: 0.1)
        XCTAssertEqual(b.handle(.forgot, now: 0.15), [.deletePairing])
        XCTAssertEqual(b.state, .unpaired)

        // macSleeping goes to backoff (no immediate retry into a sleeping Mac) and keeps the pairing.
        var m = connected()
        XCTAssertEqual(m.handle(.linkClosed(.macSleeping), now: 1), [.setBrowsing(true)])
        XCTAssertEqual(m.state, .backoff(retryAt: 1 + 0.1))

        // Failures never delete; only the authenticated goodbye or forgot do.
        var p = ConnectionSupervisor(paired: false)
        XCTAssertEqual(p.handle(.userConnect, now: 0), [.openAttempt, .setBrowsing(true)])
        XCTAssertEqual(fail(&p, at: 0.5, auth: true, known: false), [])
        XCTAssertEqual(p.state, .unpaired)
        // Pairing flow: welcome, then paired.
        _ = p.handle(.userConnect, now: 1)
        _ = p.handle(.attemptReady, now: 1.1)
        _ = p.handle(.welcomeReceived, now: 1.2)
        XCTAssertEqual(p.handle(.paired, now: 1.3), [])
        XCTAssertEqual(p.handle(.linkClosed(nil), now: 2), [.openAttempt, .setBrowsing(true)])
    }

    func testMacSilenceReconnects() {
        var s = connected()
        XCTAssertEqual(s.nextDeadline, 2.5)
        _ = s.handle(.heard, now: 1)
        XCTAssertEqual(s.state, .connected(since: 0, lastHeard: 1))
        XCTAssertEqual(s.nextDeadline, 3.5)
        XCTAssertEqual(s.handle(.tick, now: 3.4), [])
        XCTAssertEqual(s.handle(.tick, now: 3.5),
                       [.closeLink(goodbye: nil), .openAttempt, .setBrowsing(true)])
        XCTAssertEqual(s.state, .connecting(startedAt: 3.5))
    }

    func testBrowsingOnlyWhileDisconnected() {
        var s = ConnectionSupervisor(paired: true)
        var browsing: Bool?
        func apply(_ cmds: [LinkCommand]) {
            for case .setBrowsing(let on) in cmds { browsing = on }
        }
        func isConnected() -> Bool { if case .connected = s.state { return true } else { return false } }
        let script: [(LinkInput, Double)] = [
            (.tick, 0), (.attemptReady, 0.1), (.welcomeReceived, 0.2), (.heard, 1), (.inactive, 1.5),
            (.active, 1.6), (.tick, 5), (.attemptReady, 5.1), (.welcomeReceived, 5.2),
            (.linkClosed(.replaced), 6), (.deckTouched, 7), (.attemptReady, 7.1), (.welcomeReceived, 7.2),
            (.background, 8), (.active, 9), (.attemptReady, 9.1), (.welcomeReceived, 9.2),
            (.linkClosed(.unpaired), 10), (.userConnect, 11),
        ]
        for (input, t) in script {
            apply(s.handle(input, now: t))
            if s.state == .suspended {
                XCTAssertEqual(browsing, false, "\(input)")
            } else {
                XCTAssertEqual(browsing, !isConnected(), "\(input) → \(s.state)")
            }
        }
    }

    func testProblemSince() {
        var s = ConnectionSupervisor(paired: true)
        // No clock before the first input: the caller sends `.active` (or a tick) right away.
        XCTAssertNil(s.problemSince)
        _ = s.handle(.tick, now: 2)
        XCTAssertEqual(s.problemSince, 2)
        _ = s.handle(.attemptReady, now: 2.1)
        _ = s.handle(.welcomeReceived, now: 2.2)
        XCTAssertNil(s.problemSince)
        _ = s.handle(.linkClosed(nil), now: 10)
        XCTAssertEqual(s.problemSince, 10)
        _ = fail(&s, at: 11)
        _ = s.handle(.tick, now: 12)
        _ = fail(&s, at: 13)
        XCTAssertEqual(s.problemSince, 10)
        _ = s.handle(.background, now: 14)
        // Returning from the background restarts the clock.
        _ = s.handle(.active, now: 500)
        XCTAssertEqual(s.problemSince, 500)
        _ = s.handle(.attemptReady, now: 500.1)
        _ = s.handle(.welcomeReceived, now: 500.2)
        XCTAssertNil(s.problemSince)
    }

    func testTimingDefaults() {
        let t = LinkTiming()
        XCTAssertEqual(t.backoff, [0, 0.1, 0.25, 0.5, 1, 1, 2, 2, 4])
        XCTAssertEqual(t.attemptTimeout, 2.5)
        XCTAssertEqual(t.welcomeTimeout, 3.0)
        XCTAssertEqual(t.macSilence, 2.5)
        XCTAssertEqual(t.slowRetry, 10)
        XCTAssertEqual(t.repairAfterFailures, 3)
        XCTAssertEqual(t.repairAfterSeconds, 60)
    }
}
