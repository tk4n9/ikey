import Foundation

/// The iPad's view of its link to the paired Mac. Times are seconds on the caller's monotonic clock.
public enum LinkState: Equatable, Sendable {
    /// No pairing. Only a user-started pairing attempt connects.
    case unpaired
    /// The app is in the background: no link, no browsing.
    case suspended
    /// Waiting to retry after an ordinary failure or drop.
    case backoff(retryAt: Double)
    /// TCP/TLS attempt in flight.
    case connecting(startedAt: Double)
    /// TLS is up (the pairing key matched) and hello was sent.
    case awaitingWelcome(since: Double)
    case connected(since: Double, lastHeard: Double)
    /// Parked until the deck is touched or the user connects: entered on the Mac's goodbye(.replaced)
    /// or goodbye(.user) and on userDisconnect (the caller words it from the goodbye it saw). A
    /// background/foreground round trip returns here instead of reconnecting.
    case replaced
    /// The paired Mac runs protocol v1 (TXT proto 1 or two closes right after hello), or the Mac sent
    /// goodbye(.protocolMismatch). Retries every `slowRetry`, but never connects while the Mac's TXT
    /// record still advertises proto 1. Deck touches do not cut the wait; userConnect and a proto 2
    /// advert retry at once.
    case macTooOld(retryAt: Double)
    /// Repeated authentication failures against a Mac that handshook before. The pairing is kept and
    /// retried every `slowRetry`; any success clears it.
    case needsRepair(retryAt: Double)
}

public enum LinkInput: Equatable, Sendable {
    /// A pairing was saved (after the first welcome) or loaded.
    case paired
    /// The user chose Forget.
    case forgot
    case active, inactive, background
    case pathSatisfied(Bool)
    /// Bonjour result for the paired Mac with its TXT `proto` (`WireV2.peerProtocol(txt:)`).
    case peerAdvertised(proto: Int)
    case deckTouched
    case userConnect, userDisconnect
    /// TLS is ready on the current attempt.
    case attemptReady
    case welcomeReceived
    /// The attempt failed before a welcome. `authFailure`: TLS alert / PSK mismatch. `knownGoodHost`:
    /// the remote host completed a handshake before.
    case attemptFailed(authFailure: Bool, knownGoodHost: Bool)
    /// The Mac closed the link right after hello without a welcome (a v1 receiver does this).
    case closedAfterHello
    /// An established link closed; the reason is the PEER's goodbye, if any.
    case linkClosed(GoodbyeReason?)
    /// Any message from the Mac.
    case heard
    case tick
}

public enum LinkCommand: Equatable, Sendable {
    case openAttempt, cancelAttempt, sendHello
    case closeLink(goodbye: GoodbyeReason?)
    case releaseHeldInput
    case setBrowsing(Bool)
    case deletePairing
}

public struct LinkTiming: Equatable, Sendable {
    /// Delay before the n-th consecutive retry; the last entry repeats.
    public var backoff: [Double] = [0, 0.1, 0.25, 0.5, 1, 1, 2, 2, 4]
    public var attemptTimeout = 2.5
    public var welcomeTimeout = 3.0
    public var macSilence = 2.5
    public var slowRetry = 10.0
    public var repairAfterFailures = 3
    public var repairAfterSeconds = 60.0

    public init() {}
}

/// Reconnects like a built-in keyboard: pure state machine driven by `handle(_:now:)`; the caller
/// executes the returned commands in order and calls `handle(.tick, now:)` at `nextDeadline`.
/// Only `forgot` or the Mac's authenticated goodbye(.unpaired) delete the pairing.
public struct ConnectionSupervisor: Sendable {
    public private(set) var state: LinkState
    /// When the state last left `.connected`, restarted when the app returns from the background (the
    /// suspension was not a link problem); before the first connection, the time of the first input.
    /// Nil while connected AND before the first `handle` call (`init` has no clock): the caller sends
    /// `.active` (or a `.tick`) right after creating the supervisor, and reads `state` with it.
    public private(set) var problemSince: Double?

    /// Slow-retry condition that outlives individual attempts until a success.
    private enum Hold: Sendable { case none, macTooOld, needsRepair }

    private let timing: LinkTiming
    private var isPaired: Bool
    private var hold = Hold.none
    /// Consecutive failures since the last stable link (see `stableLinkSeconds`), foreground, park
    /// or userConnect; indexes `timing.backoff`. A welcome alone does not reset it.
    private var failures = 0
    /// A link that closes within this long of its welcome does not reset the backoff schedule, so a
    /// Mac that drops every link right after the welcome (a decode error, say) is not hammered.
    private static let stableLinkSeconds = 5.0
    /// Parked by goodbye(.replaced/.user) or userDisconnect; survives a trip through `.suspended` and
    /// is cleared by any attempt (deck touch, userConnect) or by losing the pairing.
    private var parked = false
    /// Authentication failures against a known-good host since the last success.
    private var authFailures = 0
    private var firstAuthFailureAt: Double?
    private var closedAfterHelloStreak = 0
    /// The paired Mac's latest Bonjour TXT says proto 1.
    private var advertisedV1 = false
    /// Last browsing state sent; nil forces the next one out.
    private var browsing: Bool?

    /// A paired supervisor starts with a due retry, so the first tick (or `active`, which also skips
    /// any backoff wait) connects.
    public init(paired: Bool, timing: LinkTiming = .init()) {
        self.timing = timing
        self.isPaired = paired
        self.state = paired ? .backoff(retryAt: 0) : .unpaired
    }

    public var nextDeadline: Double? {
        switch state {
        case .backoff(let at), .macTooOld(let at), .needsRepair(let at): return at
        case .connecting(let startedAt): return startedAt + timing.attemptTimeout
        case .awaitingWelcome(let since): return since + timing.welcomeTimeout
        case .connected(_, let lastHeard): return lastHeard + timing.macSilence
        case .unpaired, .suspended, .replaced: return nil
        }
    }

    public mutating func handle(_ input: LinkInput, now: Double) -> [LinkCommand] {
        var out: [LinkCommand] = []
        switch input {
        case .paired:
            isPaired = true
            if state == .unpaired { open(now, &out) }

        case .forgot:
            endLink(goodbye: .user, &out)
            out.append(.deletePairing)
            forgetPairing()

        case .active:
            switch state {
            case .suspended:
                failures = 0
                problemSince = now
                if !isPaired {
                    state = .unpaired
                } else if parked {
                    // Still parked: never take the Mac back from another iPad or undo a Disconnect.
                    state = .replaced
                } else {
                    open(now, &out)
                }
            case .backoff:
                open(now, &out)
            default:
                break
            }

        case .inactive:
            out.append(.releaseHeldInput)

        case .background:
            guard state != .suspended else { break }
            out.append(.releaseHeldInput)
            endLink(goodbye: .background, &out)
            state = .suspended
            browsing = nil

        case .pathSatisfied(let satisfied):
            if satisfied { skipWait(now, &out) }

        case .peerAdvertised(let proto):
            guard isPaired else { break }
            if proto < WireV2.version {
                switch state {
                case .backoff, .connecting, .awaitingWelcome, .needsRepair, .macTooOld:
                    advertisedV1 = true
                    endLink(goodbye: nil, &out)
                    hold = .macTooOld
                    state = .macTooOld(retryAt: now + timing.slowRetry)
                case .replaced:
                    advertisedV1 = true
                case .unpaired, .suspended, .connected:
                    break
                }
            } else {
                let wasV1 = advertisedV1
                advertisedV1 = false
                if case .macTooOld = state {
                    if wasV1 { hold = .none }
                    open(now, &out)
                } else {
                    skipWait(now, &out)
                }
            }

        case .deckTouched:
            switch state {
            case .replaced, .backoff, .needsRepair: open(now, &out)
            default: break
            }

        case .userConnect:
            switch state {
            case .unpaired, .replaced, .backoff, .needsRepair, .macTooOld:
                // A deliberate reconnect starts the schedule over: its first failure retries at once.
                failures = 0
                open(now, &out)
            case .connecting, .awaitingWelcome:
                // An attempt is already in flight: keep it (no second attempt), but start the
                // schedule over so its failure retries at once.
                failures = 0
            case .suspended, .connected:
                break
            }

        case .userDisconnect:
            switch state {
            case .unpaired, .replaced:
                break
            case .suspended:
                parked = isPaired
            default:
                endLink(goodbye: .user, &out)
                park()
            }

        case .attemptReady:
            guard case .connecting = state else { break }
            out.append(.sendHello)
            state = .awaitingWelcome(since: now)
            // TLS-PSK succeeded, so the pairing key works.
            clearAuthFailures()
            if hold == .needsRepair { hold = .none }

        case .welcomeReceived:
            guard case .awaitingWelcome = state else { break }
            state = .connected(since: now, lastHeard: now)
            // `failures` is reset only when the link proves stable (see `droppedLink`).
            closedAfterHelloStreak = 0
            clearAuthFailures()
            hold = .none
            advertisedV1 = false

        case .attemptFailed(let authFailure, let knownGoodHost):
            guard isAttempting else { break }
            closedAfterHelloStreak = 0
            if authFailure && knownGoodHost {
                authFailures += 1
                let first = firstAuthFailureAt ?? now
                firstAuthFailureAt = first
                if authFailures >= timing.repairAfterFailures && now - first >= timing.repairAfterSeconds {
                    hold = .needsRepair
                }
            }
            failed(now, &out)

        case .closedAfterHello:
            guard isAttempting else { break }
            closedAfterHelloStreak += 1
            if isPaired && closedAfterHelloStreak >= 2 { hold = .macTooOld }
            failed(now, &out)

        case .linkClosed(let reason):
            switch state {
            case .awaitingWelcome, .connected: break
            default: return finish(out, now: now)
            }
            droppedLink(now)
            switch reason {
            case .replaced?, .user?:
                park()
            case .unpaired?:
                out.append(.deletePairing)
                forgetPairing()
            case .macSleeping?, .receiverStopping?:
                // The Mac is going away: no pointless immediate retry.
                failures = max(failures, 1)
                failed(now, &out)
            case .protocolMismatch?:
                // Authenticated refusal of our protocol version: retrying on the fast schedule
                // cannot help. Slow retry, and at once on a fresh advert or userConnect.
                hold = .macTooOld
                failed(now, &out)
            case .background?, nil:
                failed(now, &out)
            }

        case .heard:
            if case .connected(let since, let lastHeard) = state {
                state = .connected(since: since, lastHeard: max(lastHeard, now))
            }

        case .tick:
            switch state {
            case .backoff(let at), .needsRepair(let at), .macTooOld(let at):
                if now >= at { open(now, &out) }
            case .connecting(let startedAt):
                if now - startedAt >= timing.attemptTimeout {
                    out.append(.cancelAttempt)
                    closedAfterHelloStreak = 0
                    failed(now, &out)
                }
            case .awaitingWelcome(let since):
                // A missing welcome is an ordinary failure, never evidence of an old Mac.
                if now - since >= timing.welcomeTimeout {
                    out.append(.closeLink(goodbye: nil))
                    closedAfterHelloStreak = 0
                    failed(now, &out)
                }
            case .connected(_, let lastHeard):
                if now - lastHeard >= timing.macSilence {
                    out.append(.closeLink(goodbye: nil))
                    droppedLink(now)
                    failed(now, &out)
                }
            case .unpaired, .suspended, .replaced:
                break
            }
        }
        return finish(out, now: now)
    }

    // MARK: - Private

    private var isAttempting: Bool {
        switch state {
        case .connecting, .awaitingWelcome: return true
        default: return false
        }
    }

    /// Starts an attempt now, except while the paired Mac advertises proto 1.
    private mutating func open(_ now: Double, _ out: inout [LinkCommand]) {
        parked = false
        if isPaired && advertisedV1 {
            hold = .macTooOld
            state = .macTooOld(retryAt: now + timing.slowRetry)
            return
        }
        out.append(.openAttempt)
        state = .connecting(startedAt: now)
    }

    /// Waits in `.replaced` (paired) for a deck touch or userConnect. Every way out of a park is a
    /// user action, so the backoff schedule restarts: the first failure after it retries at once.
    /// A Mac that parks us right after each welcome cannot cause a retry storm, since none of those
    /// retries is automatic.
    private mutating func park() {
        failures = 0
        if isPaired {
            parked = true
            state = .replaced
        } else {
            state = .unpaired
        }
    }

    /// An established link closed: a link that stayed up for `stableLinkSeconds` restarts the backoff
    /// schedule; a shorter one continues it.
    private mutating func droppedLink(_ now: Double) {
        if case .connected(let since, _) = state, now - since >= Self.stableLinkSeconds {
            failures = 0
        }
    }

    private mutating func skipWait(_ now: Double, _ out: inout [LinkCommand]) {
        switch state {
        case .backoff, .needsRepair: open(now, &out)
        default: break
        }
    }

    /// Cancels the attempt or closes the link that the current state owns.
    private mutating func endLink(goodbye: GoodbyeReason?, _ out: inout [LinkCommand]) {
        switch state {
        case .connecting: out.append(.cancelAttempt)
        case .awaitingWelcome, .connected: out.append(.closeLink(goodbye: goodbye))
        default: break
        }
    }

    /// The attempt or link failed: slow retry while a hold applies, else the backoff schedule.
    private mutating func failed(_ now: Double, _ out: inout [LinkCommand]) {
        guard isPaired else {
            state = .unpaired
            return
        }
        switch hold {
        case .macTooOld:
            state = .macTooOld(retryAt: now + timing.slowRetry)
        case .needsRepair:
            state = .needsRepair(retryAt: now + timing.slowRetry)
        case .none:
            let delay = timing.backoff.isEmpty ? 0 : timing.backoff[min(failures, timing.backoff.count - 1)]
            failures += 1
            if delay > 0 {
                state = .backoff(retryAt: now + delay)
            } else {
                open(now, &out)
            }
        }
    }

    private mutating func clearAuthFailures() {
        authFailures = 0
        firstAuthFailureAt = nil
    }

    private mutating func forgetPairing() {
        isPaired = false
        parked = false
        hold = .none
        failures = 0
        closedAfterHelloStreak = 0
        advertisedV1 = false
        clearAuthFailures()
        if state != .suspended { state = .unpaired }
    }

    /// Browsing runs only while not connected (and not suspended); problemSince follows the state.
    private mutating func finish(_ commands: [LinkCommand], now: Double) -> [LinkCommand] {
        var out = commands
        let wantBrowsing: Bool
        switch state {
        case .connected, .suspended: wantBrowsing = false
        default: wantBrowsing = true
        }
        if browsing != wantBrowsing {
            out.append(.setBrowsing(wantBrowsing))
            browsing = wantBrowsing
        }
        if case .connected = state {
            problemSince = nil
        } else if problemSince == nil {
            problemSince = now
        }
        return out
    }
}

public enum PeerToPeerSetting: String, Codable, CaseIterable, Sendable {
    case automatic, always, never
}

/// Adaptive peer-to-peer (AWDL): automatic mode allows it until a session over infrastructure Wi-Fi
/// is confirmed, and again after 3 consecutive infrastructure-only failures.
public struct PeerToPeerPolicy: Codable, Equatable, Sendable {
    public var setting: PeerToPeerSetting = .automatic
    public var infraConfirmed = false
    public var consecutiveInfraFailures = 0

    public init() {}

    /// Missing or unreadable fields keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setting = ((try? c.decodeIfPresent(PeerToPeerSetting.self, forKey: .setting)) ?? nil) ?? .automatic
        infraConfirmed = ((try? c.decodeIfPresent(Bool.self, forKey: .infraConfirmed)) ?? nil) ?? false
        consecutiveInfraFailures = ((try? c.decodeIfPresent(Int.self, forKey: .consecutiveInfraFailures)) ?? nil) ?? 0
    }

    private static let infraFailuresBeforeFallback = 3

    public func useP2P() -> Bool {
        switch setting {
        case .always: return true
        case .never: return false
        case .automatic: return !infraConfirmed || consecutiveInfraFailures >= Self.infraFailuresBeforeFallback
        }
    }

    /// A P2P (AWDL) session leaves the policy unchanged.
    public mutating func sessionEstablished(overInfrastructure: Bool) {
        guard overInfrastructure else { return }
        infraConfirmed = true
        consecutiveInfraFailures = 0
    }

    public mutating func attemptFailed(usedP2P: Bool) {
        guard !usedP2P else { return }
        consecutiveInfraFailures = min(consecutiveInfraFailures + 1, 1000)
    }
}
