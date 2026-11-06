import Foundation

public enum KeyContactPhase: Equatable, Sendable { case pending, down, resting, done, rejected }

/// Visual hints for the drawn deck, keyed by code. `tentative` is sent when a contact lands and
/// is always followed by `committed`, `released`, `restStarted` or `rejected` for that code.
/// `restStarted` and `rejected` are not sent while another contact holds the code down; that
/// contact's `released` ends the tentative look instead.
public enum KeyFeedback: Equatable, Sendable {
    case tentative(UInt16), committed(UInt16), released(UInt16), restStarted(UInt16), rejected(UInt16)
}

public enum PipelineOutput: Equatable, Sendable {
    case key(code: UInt16, down: Bool)
    case feedback(KeyFeedback)
}

/// Deterministic key-contact pipeline: decides which touches on keys type, when, and
/// with which modifiers. Callers pass monotonic times (earlier times are clamped).
///
/// Invariants: I1 ordinary downs are posted in landing order (ties by lower id);
/// I2 each ordinary down is preceded by exactly its applicable modifiers; I3 every down
/// gets an up (or the caller's releaseAll after `reset`); I4 a lifted modifier's up waits
/// while a key from its interval is unresolved; I5 resting, rejected or cancelled
/// contacts post nothing unless already down. The Mac repeats held keys; nothing here repeats.
public struct KeyCommitPipeline {
    /// Shift, Command, Option, Control (both sides) and fn. Caps Lock (57) is an ordinary key here.
    public static let modifierCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    private static let capsLock: UInt16 = 57
    private static let space: UInt16 = 49
    private static let broadThumbMax: TimeInterval = 0.35
    private static let broadThumbTravelMM = 3.5

    private enum Policy: Equatable {
        case immediate
        case onLift(max: TimeInterval, travelMM: Double, hold: Hold)
        case modifier
    }

    /// What an onLift contact still down within its travel limit does at its deadline when it
    /// has been isolated for its whole life (only held chording modifiers around it).
    /// `chordOnly` (isolated hold off) presses only while such a modifier is held: slow Cmd+S.
    private enum Hold { case never, chordOnly, isolated }

    /// Placement-burst state of a modifier contact.
    private enum BurstRole { case none, suspect, restCandidate }

    private enum Decision { case wait, rest, press, tap }

    private struct Contact {
        let id: Int
        let code: UInt16
        let landedAt: TimeInterval
        var policy: Policy
        var phase = KeyContactPhase.pending
        var liftedAt: TimeInterval?
        var travelMM = 0.0
        /// When isolation was first lost: another key contact (other than a held modifier that
        /// applies to this one) or a foreign contact was down. nil while still isolated.
        var isolationLostAt: TimeInterval?
        var everPosted = false
        // Modifier timeline only.
        var burst = BurstRole.none
        var burstPartners: Set<Int> = []
        var revealDone = false
        var postedByReveal = false
        var used = false

        var isModifier: Bool { policy == .modifier }
        var isHeld: Bool { liftedAt == nil }
        var isUnresolvedKey: Bool { !isModifier && phase == .pending }
        /// Keys whose isolation survives held chording modifiers. Space is excluded: thumbs rest on
        /// Cmd and Space together, and that must not become Cmd+Space or repeating Shift+Space.
        var chordsWhileIsolated: Bool { !isModifier && code != KeyCommitPipeline.space }
        /// A held modifier that will apply to a key landing now (does not break its isolation).
        var isChordingModifier: Bool {
            isModifier && isHeld && (phase == .pending || phase == .down) && burst == .none
        }
    }

    private let settings: TypingSettings
    private let confirmationDelay: TimeInterval
    private let restThreshold: TimeInterval
    private let spaceRestThreshold: TimeInterval
    private let restMaxTravelMM: Double
    private let burstWindow: TimeInterval
    private let chordTolerance: TimeInterval
    private let reveal: TimeInterval
    private let loneModifierTapMax: TimeInterval
    private let staleModifier: TimeInterval
    private let burstMinContacts: Int
    private let burstMinRestCapable: Int
    private let staleRestingContacts: Int
    private var restMode: Bool { settings.resting != .off }

    private var contacts: [Int: Contact] = [:]
    private var counts: [UInt16: Int] = [:]
    private var now: TimeInterval?
    public private(set) var lastOrdinaryActivity: TimeInterval?

    public init(settings: TypingSettings = .init(), confirmationDelay: TimeInterval = 0.045) {
        func sane(_ value: Double, _ fallback: Double) -> Double {
            value.isFinite && value >= 0 ? value : fallback
        }
        let defaults = TypingSettings()
        self.settings = settings
        self.confirmationDelay = sane(confirmationDelay, 0.045)
        restThreshold = min(0.35, max(0.15, sane(settings.restThreshold, defaults.restThreshold)))
        spaceRestThreshold = sane(settings.spaceRestThreshold, defaults.spaceRestThreshold)
        restMaxTravelMM = sane(settings.restMaxTravelMM, defaults.restMaxTravelMM)
        burstWindow = sane(settings.burstWindow, defaults.burstWindow)
        chordTolerance = sane(settings.chordTolerance, defaults.chordTolerance)
        reveal = settings.resting == .off
            ? self.confirmationDelay : sane(settings.modifierReveal, defaults.modifierReveal)
        loneModifierTapMax = sane(settings.loneModifierTapMax, defaults.loneModifierTapMax)
        staleModifier = sane(settings.staleModifier, defaults.staleModifier)
        burstMinContacts = settings.burstMinContacts >= 2 ? settings.burstMinContacts : defaults.burstMinContacts
        burstMinRestCapable = settings.burstMinRestCapable >= 1
            ? settings.burstMinRestCapable : defaults.burstMinRestCapable
        staleRestingContacts = settings.staleRestingContacts >= 1
            ? settings.staleRestingContacts : defaults.staleRestingContacts
    }

    // MARK: - Input

    public mutating func land(id: Int, code: UInt16, at time: TimeInterval,
                              broadThumb: Bool = false) -> [PipelineOutput] {
        let t = clamp(time)
        var out: [PipelineOutput] = []
        process(to: t, into: &out)
        guard contacts[id] == nil else { return out }
        let kind = policy(for: code, broadThumb: broadThumb)
        let isModifier = kind == .modifier
        // A held modifier chording with a key does not break its isolation (slow Cmd+S still
        // presses S at its threshold); every other contact does. Space never chords this way.
        let chords = !isModifier && code != Self.space
        let othersDown = contacts.values.contains { $0.isHeld && (!chords || !$0.isChordingModifier) }
        for k in Array(contacts.values) where k.isHeld {
            if isModifier, k.chordsWhileIsolated, t <= k.landedAt + chordTolerance { continue }
            loseIsolation(of: k.id, at: t)
        }
        contacts[id] = Contact(id: id, code: code, landedAt: t, policy: kind,
                               isolationLostAt: othersDown ? t : nil)
        out.append(.feedback(.tentative(code)))
        if restMode { detectPlacementBurst(at: t) }
        process(to: t, into: &out)
        return out
    }

    /// `travelMM` is the largest distance from the landing point so far.
    public mutating func move(id: Int, travelMM: Double, at time: TimeInterval) -> [PipelineOutput] {
        let t = clamp(time)
        var out: [PipelineOutput] = []
        process(to: t, into: &out)
        if travelMM.isFinite, let c = contacts[id], c.isHeld {
            contacts[id]?.travelMM = max(c.travelMM, travelMM)
        }
        process(to: t, into: &out)
        return out
    }

    public mutating func lift(id: Int, at time: TimeInterval, cancelled: Bool = false) -> [PipelineOutput] {
        let t = clamp(time)
        var out: [PipelineOutput] = []
        process(to: t, into: &out)
        if let c = contacts[id], c.isHeld {
            if c.isModifier {
                liftModifier(c, at: t, cancelled: cancelled, into: &out)
            } else {
                liftKey(c, at: t, cancelled: cancelled, into: &out)
            }
        }
        process(to: t, into: &out)
        return out
    }

    /// Palm or size rejection: a posted key is released at once; the contact never types again.
    public mutating func reject(id: Int, at time: TimeInterval) -> [PipelineOutput] {
        let t = clamp(time)
        var out: [PipelineOutput] = []
        process(to: t, into: &out)
        if let c = contacts[id], c.phase != .rejected {
            if c.phase == .down {
                postUp(c.code, into: &out, feedback: false)
                if !c.isModifier { lastOrdinaryActivity = t }
            }
            contacts[id]?.phase = .rejected
            endFeedback(.rejected(c.code), into: &out)
            if c.isModifier, c.isHeld { loseIsolationOfHeldKeys(at: t) }
            if !c.isHeld { contacts[id] = nil }
        }
        process(to: t, into: &out)
        return out
    }

    /// Posts every held, non-suspect modifier before pointer output (shift-click, Cmd-drag).
    public mutating func flushModifiersForPointer(at time: TimeInterval) -> [PipelineOutput] {
        let t = clamp(time)
        var out: [PipelineOutput] = []
        process(to: t, into: &out)
        for id in modifierIDs() {
            guard let m = contacts[id], m.isHeld, m.phase == .pending, m.burst == .none else { continue }
            postModifier(id, byReveal: false, into: &out)
        }
        return out
    }

    /// Any pointer output while modifiers are held counts as their use (no stale release).
    public mutating func notePointerUse(at time: TimeInterval) {
        for id in contacts.keys where contacts[id]?.isModifier == true && contacts[id]?.isHeld == true {
            contacts[id]?.used = true
        }
    }

    /// A trackpad, Touch ID or outside contact began at `time`: held keys are no longer
    /// isolated from that time on (an isolated-hold deadline before `time` still presses).
    ///
    /// The pipeline sees only beginnings. The engine must therefore also call this right after
    /// every `land` while any non-key contact is still down, so a key landing next to a palm or
    /// a trackpad finger that is already down is not isolated either.
    public mutating func noteForeignContact(at time: TimeInterval) {
        let t = clamp(time)
        for k in Array(contacts.values) where k.isHeld { loseIsolation(of: k.id, at: t) }
    }

    public mutating func advance(to time: TimeInterval) -> [PipelineOutput] {
        var out: [PipelineOutput] = []
        process(to: clamp(time), into: &out)
        return out
    }

    /// Forgets everything without output; the caller sends its own release-all.
    public mutating func reset() {
        contacts.removeAll()
        counts.removeAll()
        now = nil
        lastOrdinaryActivity = nil
    }

    // MARK: - State

    /// The earliest time at which `advance(to:)` changes state, or nil when only input can.
    public var nextDeadline: TimeInterval? {
        var best: TimeInterval?
        func consider(_ deadline: TimeInterval) { best = min(best ?? deadline, deadline) }
        var blocked = false
        for id in queueOrder() {
            guard let c = contacts[id] else { continue }
            if c.isHeld {
                switch c.policy {
                case .immediate where !blocked: consider(c.landedAt + confirmationDelay)
                case .onLift(let max, _, _): consider(c.landedAt + max)
                default: break
                }
            }
            blocked = true
        }
        for m in contacts.values where m.isModifier {
            if revealIsDue(m, at: .infinity) { consider(m.landedAt + reveal) }
            if staleIsDue(m, at: .infinity) { consider(m.landedAt + staleModifier) }
        }
        return best
    }

    /// nil for unknown ids and for lifted contacts that are finished (I4 waits keep a lifted modifier).
    public func phase(of id: Int) -> KeyContactPhase? { contacts[id]?.phase }

    public var postedCodes: Set<UInt16> { Set(counts.keys) }

    public var hasHeldOrdinaryKey: Bool { counts.keys.contains { !Self.modifierCodes.contains($0) } }

    // MARK: - Landing

    private func policy(for code: UInt16, broadThumb: Bool) -> Policy {
        if code == Self.capsLock { return .immediate }
        if Self.modifierCodes.contains(code) { return .modifier }
        if broadThumb { return .onLift(max: Self.broadThumbMax, travelMM: Self.broadThumbTravelMM, hold: .never) }
        if settings.isRestCapable(code) {
            return .onLift(max: code == Self.space ? spaceRestThreshold : restThreshold,
                           travelMM: restMaxTravelMM, hold: settings.isolatedHold ? .isolated : .chordOnly)
        }
        return .immediate
    }

    private mutating func loseIsolation(of id: Int, at t: TimeInterval) {
        guard let c = contacts[id] else { return }
        contacts[id]?.isolationLostAt = min(c.isolationLostAt ?? t, t)
    }

    /// A held modifier stopped chording (rested or rejected): it now counts as another contact.
    private mutating func loseIsolationOfHeldKeys(at t: TimeInterval) {
        for k in Array(contacts.values) where k.isHeld && !k.isModifier { loseIsolation(of: k.id, at: t) }
    }

    /// restStarted and rejected clear the drawn key, so they are dropped while another contact
    /// still holds the same code down; that contact's `released` clears it later.
    private func endFeedback(_ feedback: KeyFeedback, into out: inout [PipelineOutput]) {
        let code: UInt16
        switch feedback {
        case .tentative(let c), .committed(let c), .released(let c), .restStarted(let c), .rejected(let c):
            code = c
        }
        if counts[code] == nil { out.append(.feedback(feedback)) }
    }

    /// Hands landing together on the keys: other keys wait for lift, modifiers turn suspect.
    private mutating func detectPlacementBurst(at t: TimeInterval) {
        let start = t - burstWindow
        let candidates = contacts.values.filter {
            $0.isHeld && !$0.everPosted && $0.phase != .rejected && $0.landedAt >= start
        }
        let restCapable = candidates.filter { !$0.isModifier && settings.isRestCapable($0.code) }
        guard candidates.count >= burstMinContacts, restCapable.count >= burstMinRestCapable else { return }
        let keyIDs = Set(candidates.filter { !$0.isModifier }.map(\.id))
        for c in candidates where c.phase == .pending {
            if c.isModifier {
                guard c.burst != .restCandidate else { continue }
                contacts[c.id]?.burst = .suspect
                contacts[c.id]?.burstPartners.formUnion(keyIDs)
            } else if !settings.isRestCapable(c.code) {
                switch c.policy {
                case .immediate:
                    contacts[c.id]?.policy = .onLift(max: restThreshold, travelMM: restMaxTravelMM, hold: .never)
                case .onLift(let max, let travel, _):
                    contacts[c.id]?.policy = .onLift(max: min(max, restThreshold),
                                                     travelMM: min(travel, restMaxTravelMM), hold: .never)
                case .modifier:
                    break
                }
            }
        }
    }

    // MARK: - Lifting

    private mutating func liftKey(_ c: Contact, at t: TimeInterval, cancelled: Bool,
                                  into out: inout [PipelineOutput]) {
        switch c.phase {
        case .down:
            postUp(c.code, into: &out)
            lastOrdinaryActivity = t
            contacts[c.id] = nil
        case .pending where cancelled:
            endFeedback(.rejected(c.code), into: &out)
            contacts[c.id] = nil
        case .pending:
            contacts[c.id]?.liftedAt = t
        case .resting, .rejected, .done:
            contacts[c.id] = nil
        }
    }

    private mutating func liftModifier(_ m: Contact, at t: TimeInterval, cancelled: Bool,
                                       into out: inout [PipelineOutput]) {
        switch m.phase {
        case .down where cancelled:
            postUp(m.code, into: &out)
            contacts[m.id] = nil
        case .down:
            contacts[m.id]?.liftedAt = t
        case .pending where cancelled:
            endFeedback(.rejected(m.code), into: &out)
            contacts[m.id] = nil
        case .pending:
            var lifted = m
            lifted.liftedAt = t
            contacts[m.id] = lifted
            let partnered = contacts.values.contains {
                !$0.isModifier && $0.phase != .rejected && inInterval(lifted, $0)
            }
            // Only a modifier never posted is a lone tap; one already posted and released by a
            // reconcile finishes silently (no second fn or Ctrl tap after a modifier-click).
            if m.burst == .none, !m.everPosted, !partnered, t - m.landedAt <= loneModifierTapMax {
                postModifier(m.id, byReveal: false, into: &out)
                postUp(m.code, into: &out)
                contacts[m.id] = nil
            }
        case .resting, .rejected, .done:
            contacts[m.id] = nil
        }
    }

    // MARK: - Processing

    private func clamp(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return now ?? 0 }
        return max(now ?? time, time)
    }

    /// Applies every transition due up to `target`, each at its own time.
    private mutating func process(to target: TimeInterval, into out: inout [PipelineOutput]) {
        var t = now ?? target
        while true {
            settle(at: t, into: &out)
            if let deadline = nextDeadline, deadline <= target, deadline > t {
                t = deadline
            } else if t < target {
                t = target
            } else {
                break
            }
        }
        now = target
    }

    private mutating func settle(at t: TimeInterval, into out: inout [PipelineOutput]) {
        var changed = true
        while changed {
            changed = revealModifiers(at: t, into: &out)
            changed = walkQueue(at: t, into: &out) || changed
            changed = resolveSuspects(into: &out) || changed
            changed = releaseStaleModifiers(at: t, into: &out) || changed
            changed = finishLiftedModifiers(into: &out) || changed
        }
        for id in Array(contacts.keys) {
            guard let c = contacts[id], !c.isHeld, c.phase != .pending, c.phase != .down else { continue }
            contacts[id] = nil
        }
    }

    /// Unresolved ordinary contacts, oldest first.
    private func queueOrder() -> [Int] {
        contacts.values.filter(\.isUnresolvedKey)
            .sorted { $0.landedAt == $1.landedAt ? $0.id < $1.id : $0.landedAt < $1.landedAt }
            .map(\.id)
    }

    /// Modifier contacts in ascending keycode (ties by id).
    private func modifierIDs() -> [Int] {
        contacts.values.filter(\.isModifier)
            .sorted { $0.code == $1.code ? $0.id < $1.id : $0.code < $1.code }
            .map(\.id)
    }

    private func decision(for c: Contact, at t: TimeInterval, blocked: Bool) -> Decision {
        switch c.policy {
        case .immediate:
            if !c.isHeld { return .tap }
            return t >= c.landedAt + confirmationDelay ? .press : .wait
        case .onLift(let max, let travel, let hold):
            if c.travelMM > travel { return .rest }
            let deadline = c.landedAt + max
            if let lifted = c.liftedAt { return lifted < deadline ? .tap : .rest }
            guard t >= deadline else { return .wait }
            let isolated = c.isolationLostAt.map { $0 >= deadline } ?? true
            guard isolated, !blocked else { return .rest }
            switch hold {
            case .never: return .rest
            case .isolated: return .press
            case .chordOnly:
                let chorded = contacts.values.contains { $0.isChordingModifier && isApplicable($0, to: c) }
                return chorded ? .press : .rest
            }
        case .modifier:
            return .wait
        }
    }

    /// Commits ordinary contacts in landing order. A contact that cannot commit yet blocks
    /// later commits; resting needs no order and happens even behind a blocked head.
    private mutating func walkQueue(at t: TimeInterval, into out: inout [PipelineOutput]) -> Bool {
        var changed = false
        var blocked = false
        for id in queueOrder() {
            guard let c = contacts[id] else { continue }
            switch decision(for: c, at: t, blocked: blocked) {
            case .wait:
                blocked = true
            case .rest:
                contacts[id]?.phase = .resting
                endFeedback(.restStarted(c.code), into: &out)
                changed = true
            case .press, .tap:
                guard !blocked else { continue }
                let tap = !c.isHeld
                // A burst partner may have rested earlier in this walk (this key waited on it):
                // that suspect modifier is decided first and does not join this key (F04).
                if resolveSuspects(into: &out) { changed = true }
                reconcileModifiers(for: c, into: &out)
                postDown(c.code, into: &out)
                out.append(.feedback(.committed(c.code)))
                contacts[id]?.everPosted = true
                contacts[id]?.phase = .down
                if tap {
                    postUp(c.code, into: &out)
                    contacts[id]?.phase = .done
                }
                lastOrdinaryActivity = t
                changed = true
            }
        }
        return changed
    }

    /// Same expression everywhere so applicability and I4 waits never disagree by rounding.
    private func inInterval(_ m: Contact, _ k: Contact) -> Bool {
        m.landedAt <= k.landedAt + chordTolerance && (m.liftedAt.map { $0 > k.landedAt } ?? true)
    }

    private func isApplicable(_ m: Contact, to k: Contact) -> Bool {
        m.isModifier && (m.phase == .pending || m.phase == .down) && m.burst != .restCandidate &&
            inInterval(m, k)
    }

    private func isNeededByUnresolvedKey(_ m: Contact, besides k: Int? = nil) -> Bool {
        contacts.values.contains { $0.id != k && $0.isUnresolvedKey && isApplicable(m, to: $0) }
    }

    /// Before k goes down: exactly k's applicable modifiers are posted (I2) unless a posted
    /// one is still needed by another unresolved key (I4).
    private mutating func reconcileModifiers(for k: Contact, into out: inout [PipelineOutput]) {
        let ordered = modifierIDs()
        let applicable = Set(ordered.filter { contacts[$0].map { isApplicable($0, to: k) } ?? false })
        for id in ordered.reversed() {
            guard let m = contacts[id], m.phase == .down, !applicable.contains(id),
                  !isNeededByUnresolvedKey(m, besides: k.id) else { continue }
            releaseModifier(id, into: &out)
        }
        for id in ordered where applicable.contains(id) {
            if contacts[id]?.phase == .pending { postModifier(id, byReveal: false, into: &out) }
            contacts[id]?.used = true
        }
    }

    private func revealIsDue(_ m: Contact, at t: TimeInterval) -> Bool {
        m.isModifier && m.isHeld && m.phase == .pending && m.burst == .none && !m.revealDone &&
            t >= m.landedAt + reveal
    }

    private mutating func revealModifiers(at t: TimeInterval, into out: inout [PipelineOutput]) -> Bool {
        var changed = false
        for id in modifierIDs() {
            guard let m = contacts[id], revealIsDue(m, at: t) else { continue }
            postModifier(id, byReveal: true, into: &out)
            changed = true
        }
        return changed
    }

    /// A suspect modifier rests once every key of its burst is decided without having posted it:
    /// rested, rejected, dropped, or committed while the modifier did not apply to it (a partner
    /// that commits while it applies posts the modifier through the reconcile, ending the suspicion).
    private mutating func resolveSuspects(into out: inout [PipelineOutput]) -> Bool {
        var changed = false
        for id in modifierIDs() {
            guard let m = contacts[id], m.burst == .suspect, m.phase == .pending else { continue }
            let settled = m.burstPartners.allSatisfy { pid in
                guard let p = contacts[pid] else { return true }
                return p.phase != .pending
            }
            guard settled else { continue }
            contacts[id]?.burst = .restCandidate
            contacts[id]?.phase = .resting
            endFeedback(.restStarted(m.code), into: &out)
            changed = true
        }
        return changed
    }

    private func staleIsDue(_ m: Contact, at t: TimeInterval) -> Bool {
        guard restMode, m.isModifier, m.isHeld, m.phase == .down, m.postedByReveal, !m.used,
              t >= m.landedAt + staleModifier else { return false }
        let resting = contacts.values.filter { $0.id != m.id && $0.isHeld && $0.phase == .resting }.count
        return resting >= staleRestingContacts && !isNeededByUnresolvedKey(m)
    }

    private mutating func releaseStaleModifiers(at t: TimeInterval, into out: inout [PipelineOutput]) -> Bool {
        var changed = false
        for id in modifierIDs() {
            guard let m = contacts[id], staleIsDue(m, at: t) else { continue }
            postUp(m.code, into: &out, feedback: false)
            contacts[id]?.phase = .resting
            endFeedback(.restStarted(m.code), into: &out)
            loseIsolationOfHeldKeys(at: t)
            changed = true
        }
        return changed
    }

    /// Lifted modifiers finish once no key from their interval is unresolved (I4).
    private mutating func finishLiftedModifiers(into out: inout [PipelineOutput]) -> Bool {
        var changed = false
        for id in modifierIDs() {
            guard let m = contacts[id], !m.isHeld, m.phase == .pending || m.phase == .down,
                  !contacts.values.contains(where: { $0.isUnresolvedKey && inInterval(m, $0) }) else { continue }
            if m.phase == .down {
                postUp(m.code, into: &out)
            } else {
                out.append(.feedback(.released(m.code)))
            }
            contacts[id]?.phase = .done
            changed = true
        }
        return changed
    }

    // MARK: - Posting

    private mutating func postModifier(_ id: Int, byReveal: Bool, into out: inout [PipelineOutput]) {
        guard let m = contacts[id] else { return }
        postDown(m.code, into: &out)
        out.append(.feedback(.committed(m.code)))
        contacts[id]?.phase = .down
        contacts[id]?.everPosted = true
        contacts[id]?.burst = .none
        contacts[id]?.revealDone = true
        contacts[id]?.postedByReveal = byReveal
    }

    /// A held modifier released for a key it does not apply to may be posted again later.
    private mutating func releaseModifier(_ id: Int, into out: inout [PipelineOutput]) {
        guard let m = contacts[id] else { return }
        postUp(m.code, into: &out)
        contacts[id]?.phase = m.isHeld ? .pending : .done
        contacts[id]?.postedByReveal = false
    }

    private mutating func postDown(_ code: UInt16, into out: inout [PipelineOutput]) {
        let count = counts[code, default: 0]
        counts[code] = count + 1
        if count == 0 { out.append(.key(code: code, down: true)) }
    }

    private mutating func postUp(_ code: UInt16, into out: inout [PipelineOutput], feedback: Bool = true) {
        let count = counts[code, default: 0]
        guard count > 0 else { return }
        if count > 1 {
            counts[code] = count - 1
            return
        }
        counts[code] = nil
        out.append(.key(code: code, down: false))
        if feedback { out.append(.feedback(.released(code))) }
    }
}
