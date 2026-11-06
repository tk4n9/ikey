import Foundation

public enum ArbiterInput: Equatable, Sendable {
    /// A new connection; `remoteHost` is `ReceiverArbiter.hostKey(fromEndpointDescription:)` of its endpoint.
    case accepted(id: UUID, remoteHost: String)
    case tlsReady(id: UUID)
    /// First frame was a valid v2 hello.
    case helloVerified(id: UUID)
    /// First frame was a protocol v1 frame.
    case legacyFrame(id: UUID)
    /// Any frame on the active session.
    case frame(id: UUID)
    /// The injector holds (true) or no longer holds (false) keys or buttons down.
    case heldInputChanged(Bool)
    case closed(id: UUID)
    /// TLS failed before any frame (typically a wrong pairing key).
    case handshakeFailed(id: UUID)
    case tick
    case stop(GoodbyeReason)
}

public enum ArbiterCommand: Equatable, Sendable {
    case cancel(UUID)
    case promote(id: UUID, version: Int)
    case sendGoodbye(UUID, GoodbyeReason)
    case releaseAllInput
    case close(UUID)
    /// The only path to pairing-key wording in the Mac's status.
    case showPairingHint(remoteHost: String)
}

public struct ArbiterTiming: Equatable, Sendable {
    public var maxPending = 4, maxPendingPerHost = 2
    public var handshakeDeadline = 3.0
    public var deadMan = 1.0
    public var linkTimeoutV2 = 4.0, linkTimeoutV1 = 3.0

    public init() {}
}

/// The Mac's session arbiter: bounds pending handshakes (per host, ignoring ports), lets the newest
/// authenticated session win, releases held input when the iPad goes quiet and closes silent links.
/// Pure: the caller executes the returned commands in order and ticks at `nextDeadline`.
public struct ReceiverArbiter: Sendable {
    private struct Pending: Sendable {
        let id: UUID
        let host: String
        let deadline: Double
    }

    private struct Active: Sendable {
        let id: UUID
        let version: Int
        var lastHeard: Double
    }

    private let timing: ArbiterTiming
    /// Oldest first.
    private var pending: [Pending] = []
    private var active: Active?
    private var inputHeld = false
    /// The dead-man fired for the current silence; re-armed by a frame or a release.
    private var deadManFired = false
    /// Consecutive handshake failures per host, most recently failed last (bounded).
    private var handshakeFailures: [(host: String, count: Int)] = []
    private static let maxTrackedHosts = 16

    public init(timing: ArbiterTiming = .init()) {
        self.timing = timing
    }

    public var activeID: UUID? { active?.id }
    public var activeVersion: Int? { active?.version }

    public var nextDeadline: Double? {
        var deadlines = pending.map(\.deadline)
        if let active {
            deadlines.append(active.lastHeard + linkTimeout(active.version))
            if inputHeld && !deadManFired { deadlines.append(active.lastHeard + timing.deadMan) }
        }
        return deadlines.min()
    }

    public mutating func handle(_ input: ArbiterInput, now: Double) -> [ArbiterCommand] {
        var out: [ArbiterCommand] = []
        switch input {
        case .accepted(let id, let remoteHost):
            // A repeated id is ignored: a second entry would later cancel the session it became.
            if active?.id == id || pending.contains(where: { $0.id == id }) { break }
            let host = Self.hostKey(fromEndpointDescription: remoteHost)
            // Per host first, so one host's flood never evicts another host's handshake.
            let fromHost = pending.filter { $0.host == host }
            if fromHost.count >= timing.maxPendingPerHost, let oldest = fromHost.first {
                out.append(.cancel(oldest.id))
                pending.removeAll { $0.id == oldest.id }
            }
            if pending.count >= timing.maxPending, let oldest = pending.first {
                out.append(.cancel(oldest.id))
                pending.removeFirst()
            }
            pending.append(Pending(id: id, host: host, deadline: now + timing.handshakeDeadline))

        case .tlsReady(let id):
            // The pairing key matched for this host.
            if let host = pending.first(where: { $0.id == id })?.host { clearHandshakeFailures(host) }

        case .helloVerified(let id):
            promote(id, version: 2, now: now, &out)

        case .legacyFrame(let id):
            if active?.id == id {
                heard(now)
            } else {
                promote(id, version: 1, now: now, &out)
            }

        case .frame(let id):
            if active?.id == id { heard(now) }

        case .heldInputChanged(let held):
            inputHeld = held
            if !held { deadManFired = false }

        case .closed(let id):
            if active?.id == id {
                out.append(.releaseAllInput)
                active = nil
                deadManFired = false
            } else {
                pending.removeAll { $0.id == id }
            }

        case .handshakeFailed(let id):
            guard let index = pending.firstIndex(where: { $0.id == id }) else { break }
            let host = pending.remove(at: index).host
            if noteHandshakeFailure(host) >= 2 { out.append(.showPairingHint(remoteHost: host)) }

        case .tick:
            let expired = pending.filter { now >= $0.deadline }
            for p in expired { out.append(.cancel(p.id)) }
            pending.removeAll { now >= $0.deadline }
            guard let current = active else { break }
            let silence = now - current.lastHeard
            if silence >= linkTimeout(current.version) {
                out += [.releaseAllInput, .close(current.id)]
                active = nil
                deadManFired = false
            } else if inputHeld && !deadManFired && silence >= timing.deadMan {
                out.append(.releaseAllInput)
                deadManFired = true
            }

        case .stop(let reason):
            out.append(.releaseAllInput)
            if let current = active {
                out += [.sendGoodbye(current.id, reason), .close(current.id)]
            }
            out += pending.map { .cancel($0.id) }
            active = nil
            pending.removeAll()
            deadManFired = false
        }
        return out
    }

    /// The host part of an NWEndpoint description, without port or `%interface` scope, lowercased:
    /// "192.168.1.5:50123" → "192.168.1.5", "fe80::1%en0.50000" → "fe80::1", "[::1]:80" → "::1".
    /// A bare host is returned unchanged (apart from case).
    public static func hostKey(fromEndpointDescription d: String) -> String {
        var s = Substring(d.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            s = s[s.index(after: s.startIndex)..<close]
        }
        let colons = s.filter { $0 == ":" }.count
        if colons == 1, let colon = s.firstIndex(of: ":") {
            s = s[..<colon]
        } else if colons > 1 {
            if let percent = s.firstIndex(of: "%") {
                // The scope (and the ".port" after it) ends the address.
                s = s[..<percent]
            } else if let lastColon = s.lastIndex(of: ":") {
                // IPv6 prints its port as ".port": one dot after the last colon, or a fourth one
                // after an embedded IPv4 address.
                let tail = s[s.index(after: lastColon)...]
                let dots = tail.filter { $0 == "." }.count
                if dots == 1 || dots == 4, let dot = s.lastIndex(of: ".") { s = s[..<dot] }
            }
        }
        return s.lowercased()
    }

    // MARK: - Private

    private func linkTimeout(_ version: Int) -> Double {
        version >= 2 ? timing.linkTimeoutV2 : timing.linkTimeoutV1
    }

    private mutating func heard(_ now: Double) {
        guard var current = active else { return }
        current.lastHeard = max(current.lastHeard, now)
        active = current
        deadManFired = false
    }

    /// Newest authenticated session wins; the old one's held input is released first.
    private mutating func promote(_ id: UUID, version: Int, now: Double, _ out: inout [ArbiterCommand]) {
        guard let host = pending.first(where: { $0.id == id })?.host else { return }
        pending.removeAll { $0.id == id }
        clearHandshakeFailures(host)
        if let old = active {
            out += [.releaseAllInput, .sendGoodbye(old.id, .replaced), .close(old.id)]
        }
        out.append(.promote(id: id, version: version))
        active = Active(id: id, version: version, lastHeard: now)
        deadManFired = false
    }

    private mutating func noteHandshakeFailure(_ host: String) -> Int {
        let count = (handshakeFailures.first { $0.host == host }?.count ?? 0) + 1
        handshakeFailures.removeAll { $0.host == host }
        handshakeFailures.append((host, count))
        if handshakeFailures.count > Self.maxTrackedHosts { handshakeFailures.removeFirst() }
        return count
    }

    private mutating func clearHandshakeFailures(_ host: String) {
        handshakeFailures.removeAll { $0.host == host }
    }
}

/// Restart delays for the Mac's listener after it fails or waits: in order, then the last repeatedly.
public struct ListenerBackoff: Sendable {
    private let delays: [Double]
    private var index = 0

    public init(delays: [Double] = [0.5, 1, 2, 5]) {
        self.delays = delays
    }

    public mutating func nextDelay() -> Double {
        guard let last = delays.last else { return 0 }
        let delay = index < delays.count ? delays[index] : last
        index = min(index + 1, delays.count)
        return delay
    }

    public mutating func reset() {
        index = 0
    }
}
