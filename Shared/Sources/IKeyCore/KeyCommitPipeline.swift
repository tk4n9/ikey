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
///
/// Rest modes (plan amendments, section F):
/// - Rest-capable keys (`TypingSettings.isRestCapable`, Space included) and tap-only codes type
///   only as a TAP: down+up at lift when lifted within `tapMax` and the travel limit. A longer or
///   sliding contact is a REST and posts nothing, ever (`isolatedHold` is the only opt-in
///   exception). Other keys keep the confirmation delay and stay down while held.
/// - Modifiers are lazy. Touching one posts nothing. It is posted (a) right before a key that
///   commits while it is held, and then stays down until its own contact lifts, (b) as down+up for
///   a lone tap (within `tapMax` and the travel limit, not in a placement burst, no key from its
///   interval committed without it), or (c) by `commitHeldModifiers(at:)` before pointer output.
///   A modifier that never does any of these posts nothing, however long it is held. A lone tap
///   is posted in landing order: once every key that landed before it is decided and every key
///   from its interval has rested (a key that commits there chords with it instead).
/// - Settling: a held, unposted, unused modifier rests silently (never chords again) when it
///   lands in a placement burst whose keys rest, when a key contact starts resting beside it (a
///   thumb settling with the hands, see `awaitsChord` and `pressedAfterSettle` for the
///   exceptions; a key and a modifier landing within `chordTolerance` of each other were put down
///   together), when it lands within `chordTolerance` after a home-row or Space tap and is still
///   held at that tap's commit with no key under it within 0.2 s (a thumb settling beside the
///   stroke; the tap waits up to the modifier's `tapMax` and takes it only if it lifts first, a
///   fast capital), or when it lies unused among resting hands for `staleModifier`. A modifier
///   pressed after its own hand settled (PV4) is not settled by the other hand landing.
/// - Placement bursts: `burstMinRestCapable` rest-capable keys or `burstMinKeys` keys of any kind
///   landing together within `burstWindow`, still undecided (a hand put down, also off the home row).
///
/// Thumb taps during a placement (plan amendments F3b/F5): a lone-modifier tap overlapped by a
/// burst posts nothing. Space and tap-only codes touched in a burst, held when it starts, or lifted
/// just before it formed tap only once a key of the burst taps (a roll; one finger's bounce of at
/// most 50 ms alone does not count, another thumb tap never does) and post nothing when the keys
/// rest (a hand put down). A finger's tap counts only once its key did not land again within
/// 50 ms (a bounce). A Space or tap-only tap that landed before every key of its burst while
/// typing was in flow (a key committed within 0.3 s before it) is the other thumb striking while
/// the typing hand returns home: it types unless a thumb lands on the thumb row within 0.15 s
/// after its lift. A tap-only or Space tap lifted while a burst is one landing away waits
/// (at most `burstWindow` after the last of those landings) to see whether it forms. A
/// lone-modifier tap of at most 50 ms that is still undecided when the same key lands within
/// 50 ms is a bounce and posts nothing. A tap-only or Space tap that short, followed within 50 ms
/// by the same key (for a tap-only code, also a neighbouring thumb key), is a bounce only if that
/// contact does not lift as a tap (a typed Space or a quick second switch); a tap-only tap that
/// short waits those 50 ms.
///
/// Fingers during a placement (F5): burst keys that land within 25 ms of each other and lift in a
/// chain of lifts at most 8 ms apart (three or more) are a hand patting the keys or repositioning:
/// they rest. A key tap that a held suspect modifier would join waits for a second key of the
/// burst; without one it is a bouncing finger and types plain, never posting the modifier (its own
/// key landing again within 50 ms, while a suspect rests on or just grazed its modifier, is such a
/// bounce too). A home-row or Space tap lifted within `burstWindow` of an unused held modifier's
/// landing waits until then for a burst. A key whose confirmation finds two keys that landed after
/// it still settling waits for the burst, and a typing key already down when a burst forms within
/// `burstWindow` of its landing is released at once (no key repeat from a hand put down one key
/// off). A suspect whose burst keys committed as a roll (two or more) is an ordinary modifier again.
public struct KeyCommitPipeline {
    /// Shift, Command, Option, Control (both sides) and fn. Caps Lock (57) is an ordinary key here.
    public static let modifierCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    private static let capsLock: UInt16 = 57
    private static let space: UInt16 = 49
    private static let broadThumbMax: TimeInterval = 0.35
    private static let broadThumbTravelMM = 3.5
    /// A contact this short whose key lands again within this long is a settling bounce.
    private static let bounceMax: TimeInterval = 0.05
    /// Thumb-row keys a thumb grazing a tap-only key (left Command) may settle on next: Space and
    /// both Command and Option keys.
    private static let thumbRowCodes: Set<UInt16> = [49, 54, 55, 58, 61]
    private static let leftModifierCodes: Set<UInt16> = [55, 56, 58, 59, 63]
    private static let rightModifierCodes: Set<UInt16> = [54, 60, 61, 62]
    /// Keys typed by each hand (ANSI touch typing; Space by either thumb is in neither).
    private static let leftHandCodes: Set<UInt16> =
        [0, 1, 2, 3, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23, 48, 50, 53, 57]
    private static let rightHandCodes: Set<UInt16> =
        [4, 16, 22, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44,
         45, 46, 47, 51]
    /// Burst keys landing within `patLandingWindow` of a key and lifting with it in a chain of
    /// lifts at most `patLiftGap` apart are the same hand patting the keys.
    private static let patLandingWindow: TimeInterval = 0.025
    private static let patLiftGap: TimeInterval = 0.008
    /// A thumb tap that leads a placement while typing is in flow (a key committed at most this
    /// long before it landed) is the other thumb striking Space or the switch, unless a thumb lands
    /// on the thumb row within `thumbSettleWindow` after its lift (the thumb settling).
    private static let flowWindow: TimeInterval = 0.30
    private static let thumbSettleWindow: TimeInterval = 0.15
    /// A key landing this soon under a modifier that landed just after an earlier key is what the
    /// modifier was pressed for (camelCase rollover, a quick shortcut); a later one is typing
    /// beside a thumb that came to rest.
    private static let nextKeyWindow: TimeInterval = 0.20

    private enum Policy: Equatable {
        case immediate
        /// Types only if lifted before `landedAt + max` within `travelMM`. With `hold` (opt-in
        /// isolated hold) a contact still down and isolated at that deadline presses instead.
        case onLift(max: TimeInterval, travelMM: Double, hold: Bool)
        case modifier
    }

    /// Placement-burst state of a modifier contact.
    private enum BurstRole { case none, suspect, restCandidate }

    /// `tapPlain`: a placement-burst key tap that no other key of its burst confirms as a roll (a
    /// finger bouncing while the hand is put down). It types, but without the burst's suspect
    /// modifiers, so a settling thumb or pinky is never posted for it.
    private enum Decision { case wait, rest, press, tap, tapPlain }

    /// A burst partner that committed: its key and contact span (a press: no lift).
    private struct PartnerTap {
        let code: UInt16
        let landedAt: TimeInterval
        let liftedAt: TimeInterval?
        var length: TimeInterval { liftedAt.map { $0 - landedAt } ?? .infinity }
    }

    private struct Contact {
        let id: Int
        let code: UInt16
        let landedAt: TimeInterval
        var policy: Policy
        var phase = KeyContactPhase.pending
        var liftedAt: TimeInterval?
        var travelMM = 0.0
        /// When isolation was first lost: another contact or a foreign contact was down.
        var isolationLostAt: TimeInterval?
        var everPosted = false
        /// At landing, at least `staleRestingContacts` other contacts were resting.
        var landedAmongRestingHands = false
        /// Tap-only code (an ordinary key here). With `silentLift` (a settling bounce: the same key
        /// or a neighbouring thumb key landed right after a very short tap and did not tap) it rests
        /// instead of tapping. `bounceFollower` is that landing while it is undecided: a follower
        /// lifted as a tap (a typed Space, a quick second switch) makes no bounce.
        var tapOnly = false
        var silentLift = false
        var bounceFollower: Int?
        /// A key committed at most `flowWindow` before it landed (typing in flow).
        var landedInFlow = false
        /// The keys of the placement burst(s) this contact was part of. Modifiers: the keys that
        /// settle it. Thumb taps (Space, tap-only codes): they tap only when two of these keys tap
        /// (a roll). Other keys: a tap that a suspect modifier would join waits for one of these
        /// keys to tap too (`burstTapDecision`).
        var burstPartners: Set<Int> = []
        /// Burst partners (never thumb taps) that committed, with their contact length (a press:
        /// infinity).
        var committedPartners: [Int: PartnerTap] = [:]
        // Modifier timeline only.
        var burst = BurstRole.none
        /// Lifted as a lone tap; `walkQueue` posts it down+up in landing order.
        var loneTap = false
        /// A key from its interval committed while it was not applied (it is no lone tap then).
        var keyCommittedWithout = false
        /// Unresolved key contacts held at its landing (fingers possibly settling around it).
        var settlingAtLanding: Set<Int> = []
        /// Resting `.off` only: the reveal at the confirmation delay already happened.
        var revealDone = false
        /// A key committed with it applied, or it was committed for the pointer.
        var used = false

        var isModifier: Bool { policy == .modifier }
        var isHeld: Bool { liftedAt == nil }
        var isUnresolvedKey: Bool { !isModifier && phase == .pending }
    }

    private let settings: TypingSettings
    private let confirmationDelay: TimeInterval
    private let tapMax: TimeInterval
    private let restMaxTravelMM: Double
    private let burstWindow: TimeInterval
    private let chordTolerance: TimeInterval
    private let staleModifier: TimeInterval
    private let burstMinContacts: Int
    private let burstMinRestCapable: Int
    private let burstMinKeys: Int
    private let staleRestingContacts: Int
    private var restMode: Bool { settings.resting != .off }

    private var contacts: [Int: Contact] = [:]
    /// Recent landings (about the last second), for bounce and settle checks after a contact ended.
    private var landings: [(code: UInt16, t: TimeInterval)] = []
    /// Key contacts lifted in about the last second, by id (hand-pat checks after they ended).
    private var recentSpans: [Int: PartnerTap] = [:]
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
        tapMax = min(0.35, max(0.15, sane(settings.tapMax, defaults.tapMax)))
        restMaxTravelMM = sane(settings.restMaxTravelMM, defaults.restMaxTravelMM)
        burstWindow = sane(settings.burstWindow, defaults.burstWindow)
        chordTolerance = sane(settings.chordTolerance, defaults.chordTolerance)
        staleModifier = sane(settings.staleModifier, defaults.staleModifier)
        burstMinContacts = settings.burstMinContacts >= 2 ? settings.burstMinContacts : defaults.burstMinContacts
        burstMinRestCapable = settings.burstMinRestCapable >= 1
            ? settings.burstMinRestCapable : defaults.burstMinRestCapable
        burstMinKeys = settings.burstMinKeys >= 2 ? settings.burstMinKeys : defaults.burstMinKeys
        staleRestingContacts = settings.staleRestingContacts >= 1
            ? settings.staleRestingContacts : defaults.staleRestingContacts
    }

    // MARK: - Input

    /// `broadThumb` (a broad contact): a non-rest-capable key then commits only on a lift within
    /// 0.35 s and 3.5 mm. Rest-capable keys (Space included) ignore it: they already type only as
    /// a tap within `tapMax`.
    public mutating func land(id: Int, code: UInt16, at time: TimeInterval,
                              broadThumb: Bool = false) -> [PipelineOutput] {
        let t = clamp(time)
        var out: [PipelineOutput] = []
        process(to: t, into: &out)
        guard contacts[id] == nil else { return out }
        let kind = policy(for: code, broadThumb: broadThumb)
        let isModifier = kind == .modifier
        let othersDown = contacts.values.contains { $0.isHeld }
        let resting = contacts.values.filter { $0.isHeld && $0.phase == .resting }.count
        // Thumb taps (Space, tap-only codes) are not fingers settling: a thumb that rests there
        // settles the modifier through its own rest (`awaitsChord`).
        let settling = Set(contacts.values.filter { $0.isHeld && $0.isUnresolvedKey && !isThumbTap($0) }.map(\.id))
        for k in Array(contacts.values) where k.isHeld { loseIsolation(of: k.id, at: t) }
        if restMode { dropBounces(of: code, at: t, follower: id) }
        landings.removeAll { $0.t < t - 1.0 }
        landings.append((code, t))
        var contact = Contact(id: id, code: code, landedAt: t, policy: kind,
                              isolationLostAt: othersDown ? t : nil,
                              landedAmongRestingHands: resting >= staleRestingContacts,
                              tapOnly: !isModifier && settings.tapOnlyCodes.contains(code))
        contact.settlingAtLanding = settling
        contact.landedInFlow = lastOrdinaryActivity.map { t - $0 <= Self.flowWindow } ?? false
        contacts[id] = contact
        out.append(.feedback(.tentative(code)))
        if restMode { detectPlacementBurst(at: t, into: &out) }
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
            let tapped = !cancelled && t - c.landedAt < tapMax && c.travelMM <= restMaxTravelMM
            resolveBounceFollower(id, tapped: tapped)
            if !c.isModifier {
                recentSpans = recentSpans.filter { ($0.value.liftedAt ?? t) >= t - 1.0 }
                recentSpans[id] = PartnerTap(code: c.code, landedAt: c.landedAt, liftedAt: t)
            }
            if c.isModifier {
                liftModifier(c, at: t, cancelled: cancelled, into: &out)
            } else {
                liftKey(c, at: t, cancelled: cancelled, into: &out)
            }
        }
        process(to: t, into: &out)
        return out
    }

    /// The contact that landed right after a very short thumb tap lifted or was rejected: lifted
    /// as a tap, it was typing (a Space, a second switch), so the earlier tap was no bounce;
    /// otherwise the earlier tap was a thumb settling and posts nothing.
    private mutating func resolveBounceFollower(_ id: Int, tapped: Bool) {
        for c in Array(contacts.values) where c.bounceFollower == id {
            contacts[c.id]?.bounceFollower = nil
            if !tapped { contacts[c.id]?.silentLift = true }
        }
    }

    /// Palm or size rejection: a posted key is released at once; the contact never types again.
    public mutating func reject(id: Int, at time: TimeInterval) -> [PipelineOutput] {
        let t = clamp(time)
        var out: [PipelineOutput] = []
        process(to: t, into: &out)
        if let c = contacts[id], c.phase != .rejected {
            resolveBounceFollower(id, tapped: false)
            if c.phase == .down {
                postUp(c.code, into: &out, feedback: false)
                if !c.isModifier { lastOrdinaryActivity = t }
            }
            contacts[id]?.phase = .rejected
            endFeedback(.rejected(c.code), into: &out)
            if !c.isHeld { contacts[id] = nil }
        }
        process(to: t, into: &out)
        return out
    }

    /// Pointer modifiers (Cmd-click, Shift-drag, Option-scroll). W2-ENGINE calls this right
    /// before a trackpad button press, scroll or drag begins, and forwards the returned outputs
    /// first. It posts every held modifier that has not settled: not a placement-burst thumb, not
    /// resting, not a tap-only code. A posted modifier stays down until its contact lifts and is
    /// not posted again for keys typed meanwhile; its lift posts no extra lone tap. Returns []
    /// when nothing is held. Idempotent at a given time.
    public mutating func commitHeldModifiers(at time: TimeInterval) -> [PipelineOutput] {
        let t = clamp(time)
        var out: [PipelineOutput] = []
        process(to: t, into: &out)
        for id in modifierIDs() {
            guard let m = contacts[id], m.isHeld, m.phase == .pending, m.burst == .none else { continue }
            postModifier(id, into: &out)
            contacts[id]?.used = true
        }
        return out
    }

    /// The original name of `commitHeldModifiers(at:)` (same behaviour), kept for W2-ENGINE.
    public mutating func flushModifiersForPointer(at time: TimeInterval) -> [PipelineOutput] {
        commitHeldModifiers(at: time)
    }

    /// Any pointer output while modifiers are held counts as their use (they never go stale).
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
        landings.removeAll()
        recentSpans.removeAll()
        now = nil
        lastOrdinaryActivity = nil
    }

    // MARK: - State

    /// The earliest time at which `advance(to:)` changes state, or nil when only input can.
    public var nextDeadline: TimeInterval? { nextDeadline(after: now ?? -.infinity) }

    /// Deadlines at or before `floor` are already applied (or wait on something else) and skipped.
    private func nextDeadline(after floor: TimeInterval) -> TimeInterval? {
        var best: TimeInterval?
        func consider(_ deadline: TimeInterval) {
            guard deadline > floor else { return }
            best = min(best ?? deadline, deadline)
        }
        var blocked = false
        for id in queueOrder() {
            guard let c = contacts[id] else { continue }
            if c.isHeld {
                switch c.policy {
                case .immediate where !blocked:
                    consider(max(c.landedAt + confirmationDelay, placementLeadWaitEnd(c) ?? -.infinity))
                case .onLift(let max, _, _): consider(c.landedAt + max)
                default: break
                }
            } else {
                if let end = tapWaitEnd(c), !blocked || decision(for: c, at: end, blocked: true) == .rest {
                    // Behind a blocked head only a rest is a transition (a tap waits for the head).
                    consider(end)
                }
                // The first time a burst tap's checks (bounce, pat, thumb settle, bounce follower)
                // resolve its wait into a transition.
                if decision(for: c, at: floor, blocked: blocked) == .wait {
                    for end in burstCheckTimes(c).filter({ $0 > floor }).sorted() {
                        let next = decision(for: c, at: end, blocked: blocked)
                        guard next != .wait else { continue }
                        if !blocked || next == .rest { consider(end) }
                        break
                    }
                }
            }
            blocked = true
        }
        for m in contacts.values where m.isModifier {
            if revealIsDue(m, at: .infinity) { consider(m.landedAt + confirmationDelay) }
            if staleIsDue(m, at: .infinity) { consider(m.landedAt + staleModifier) }
        }
        return best
    }

    /// nil for unknown ids and for lifted contacts that are finished (I4 waits keep a lifted modifier).
    public func phase(of id: Int) -> KeyContactPhase? { contacts[id]?.phase }

    public var postedCodes: Set<UInt16> { Set(counts.keys) }

    /// Tap-only codes are ordinary keys here even when their code is a modifier's.
    public var hasHeldOrdinaryKey: Bool {
        counts.keys.contains { !Self.modifierCodes.contains($0) || settings.tapOnlyCodes.contains($0) }
    }

    // MARK: - Landing

    private func policy(for code: UInt16, broadThumb: Bool) -> Policy {
        if code == Self.capsLock { return .immediate }
        // A key the Mac remaps to a non-modifier (left Command -> Caps Lock): an ordinary key that
        // never chords. Resting on it posts nothing; only a short tap types it.
        if settings.tapOnlyCodes.contains(code) {
            return restMode ? .onLift(max: tapMax, travelMM: restMaxTravelMM, hold: false) : .immediate
        }
        if Self.modifierCodes.contains(code) { return .modifier }
        if settings.isRestCapable(code) {
            // Space never presses by isolation: a thumb settling on it must not repeat spaces.
            return .onLift(max: tapMax, travelMM: restMaxTravelMM,
                           hold: settings.isolatedHold && code != Self.space)
        }
        if broadThumb { return .onLift(max: Self.broadThumbMax, travelMM: Self.broadThumbTravelMM, hold: false) }
        return .immediate
    }

    private mutating func loseIsolation(of id: Int, at t: TimeInterval) {
        guard let c = contacts[id] else { return }
        contacts[id]?.isolationLostAt = min(c.isolationLostAt ?? t, t)
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

    /// Hands landing together on the keys: other keys commit only as taps, modifiers turn suspect.
    private mutating func detectPlacementBurst(at t: TimeInterval, into out: inout [PipelineOutput]) {
        let start = t - burstWindow
        let candidates = contacts.values.filter {
            $0.isHeld && !$0.everPosted && $0.phase != .rejected && $0.landedAt >= start
        }
        let keys = candidates.filter { !$0.isModifier }
        let restCapable = keys.filter { settings.isRestCapable($0.code) }
        guard (candidates.count >= burstMinContacts && restCapable.count >= burstMinRestCapable)
                || keys.count >= burstMinKeys else { return }
        let keyIDs = Set(keys.map(\.id))
        let earliest = candidates.map(\.landedAt).min() ?? t
        // A typing key that already went down within the window and is still held is the leading
        // finger of the hand being put down (the index landing first on G, one key off): release it
        // now, before the Mac starts repeating it (F5). Its lift posts nothing.
        for c in contacts.values where c.isHeld && c.phase == .down && !c.isModifier && !c.tapOnly &&
            c.code != Self.space && c.landedAt >= start && TypingSettings.typingKeyCodes.contains(c.code) {
            postUp(c.code, into: &out)
            contacts[c.id]?.phase = .resting
        }
        // A thumb tap touched in the burst, held since before it, or lifted after its first key
        // landed (a bounce of a settling thumb) is part of the placement. A lone modifier tap posts
        // nothing. Space and tap-only keys (left Command remapped to Caps Lock) wait for the burst's
        // keys (`burstTapDecision`): a roll of taps types, a hand put down does not. Other keys of
        // the burst, and a key lifted just before it formed, learn their partners too, so a tap
        // that a settling thumb modifier would join waits to see whether it is a roll.
        for c in contacts.values where c.phase == .pending && (c.liftedAt ?? .infinity) >= earliest {
            if c.isModifier {
                if !c.isHeld { contacts[c.id]?.loneTap = false }
            } else if c.tapOnly || isSpaceTap(c) || c.landedAt >= start {
                contacts[c.id]?.burstPartners.formUnion(keyIDs.subtracting([c.id]))
            }
        }
        // A modifier held, unused, since before the burst is a thumb that settled first, unless it
        // was pressed after its own hand had settled (PV4: the other hand is landing, e.g. back
        // from the trackpad, while it is held for a shortcut).
        let burstKeys = keys
        for m in contacts.values where m.landedAt < start && isUnusedHeldModifier(m) && m.burst == .none &&
            !(pressedAmongSettledHands(m) && onOppositeHands(m, burstKeys)) {
            contacts[m.id]?.burst = .suspect
            contacts[m.id]?.burstPartners.formUnion(keyIDs)
        }
        for c in candidates where c.phase == .pending {
            if c.isModifier {
                guard c.burst != .restCandidate, !(pressedAmongSettledHands(c) && onOppositeHands(c, keys))
                else { continue }
                contacts[c.id]?.burst = .suspect
                contacts[c.id]?.burstPartners.formUnion(keyIDs)
            } else if !settings.isRestCapable(c.code) {
                switch c.policy {
                case .immediate:
                    contacts[c.id]?.policy = .onLift(max: tapMax, travelMM: restMaxTravelMM, hold: false)
                case .onLift(let max, let travel, _):
                    contacts[c.id]?.policy = .onLift(max: min(max, tapMax),
                                                     travelMM: min(travel, restMaxTravelMM), hold: false)
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
            // A lone tap: never posted (one posted and released by a reconcile finishes silently,
            // no second fn or Ctrl tap after a modifier-click), not part of a placement burst, no
            // key from its interval committed without it, short and still.
            guard m.burst == .none, !m.everPosted, !m.keyCommittedWithout, t - m.landedAt < tapMax,
                  m.travelMM <= restMaxTravelMM else { return }
            if restMode {
                // Posted by walkQueue in landing order, once the keys from its interval rested
                // (one that commits chords with it instead).
                contacts[m.id]?.loneTap = true
                return
            }
            let partnered = contacts.values.contains {
                !$0.isModifier && $0.phase != .rejected && inInterval(lifted, $0)
            }
            if !partnered {
                postModifier(m.id, into: &out)
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
            if let deadline = nextDeadline(after: t), deadline <= target {
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
            changed = resolveSuspects(at: t, into: &out) || changed
            changed = restStaleModifiers(at: t, into: &out) || changed
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

    private func decision(for c: Contact, at t: TimeInterval, blocked: Bool,
                          withPartners: Bool = true) -> Decision {
        switch c.policy {
        case .immediate:
            if !c.isHeld { return .tap }
            guard t >= c.landedAt + confirmationDelay else { return .wait }
            if withPartners, let end = placementLeadWaitEnd(c), t < end { return .wait }
            return .press
        case .onLift(let max, let travel, let hold):
            if c.travelMM > travel { return .rest }
            let deadline = c.landedAt + max
            if let lifted = c.liftedAt {
                guard lifted < deadline, !c.silentLift else { return .rest }
                if let fid = c.bounceFollower, let f = contacts[fid] {
                    // A thumb landed right after this very short tap and is still down: a bounce
                    // if it rests (or slides), a typed tap if it lifts in time.
                    return t >= f.landedAt + tapMax || f.travelMM > restMaxTravelMM ? .rest : .wait
                }
                guard withPartners else { return .tap }
                if let end = tapWaitEnd(c), t < end { return .wait }
                guard !c.burstPartners.isEmpty else { return .tap }
                if !isThumbTap(c) {
                    switch isHandPat(c, at: t) {
                    case true?: return .rest
                    case nil: return .wait
                    case false?: break
                    }
                }
                return burstTapDecision(c, at: t)
            }
            guard t >= deadline else { return .wait }
            let isolated = c.isolationLostAt.map { $0 >= deadline } ?? true
            return hold && isolated && !blocked ? .press : .rest
        case .modifier:
            return .wait
        }
    }

    /// Unresolved ordinary contacts and lone-modifier taps, oldest first.
    private func walkOrder() -> [Int] {
        contacts.values.filter { $0.isUnresolvedKey || isWaitingLoneTap($0) }
            .sorted { $0.landedAt == $1.landedAt ? $0.id < $1.id : $0.landedAt < $1.landedAt }
            .map(\.id)
    }

    private func isWaitingLoneTap(_ m: Contact) -> Bool {
        m.isModifier && m.loneTap && !m.isHeld && m.phase == .pending
    }

    /// Commits ordinary contacts in landing order. A contact that cannot commit yet blocks
    /// later commits; resting needs no order and happens even behind a blocked head. A lone
    /// modifier tap takes its landing-order place: it waits while a key from its interval is
    /// unresolved (that key may still chord with it, so only keys from its interval pass it).
    private mutating func walkQueue(at t: TimeInterval, into out: inout [PipelineOutput]) -> Bool {
        var changed = false
        var blocked = false
        var waitingLone: [Contact] = []
        for id in walkOrder() {
            guard let c = contacts[id] else { continue }
            if c.isModifier {
                // A key earlier in this walk may have posted it as a chord already.
                guard isWaitingLoneTap(c) else { continue }
                // A lone tap waiting on its interval keys blocks only keys outside its interval,
                // not a later lone tap (that one lifted before those keys landed).
                if blocked || contacts.values.contains(where: { $0.isUnresolvedKey && inInterval(c, $0) }) {
                    waitingLone.append(c)
                } else {
                    postModifier(id, into: &out)
                    postUp(c.code, into: &out)
                    contacts[id]?.phase = .done
                    changed = true
                }
                continue
            }
            let behind = blocked || waitingLone.contains { !inInterval($0, c) }
            let decided = decision(for: c, at: t, blocked: behind)
            switch decided {
            case .wait:
                blocked = true
            case .rest:
                contacts[id]?.phase = .resting
                endFeedback(.restStarted(c.code), into: &out)
                restUnusedModifiers(after: c, into: &out)
                changed = true
            case .press, .tap, .tapPlain:
                guard !behind else {
                    blocked = true
                    continue
                }
                let tap = !c.isHeld
                // A burst partner may have rested earlier in this walk (this key waited on it):
                // that suspect modifier is decided first and does not join this key (F04).
                if resolveSuspects(at: t, into: &out) { changed = true }
                reconcileModifiers(for: c, includingSuspects: decided != .tapPlain, into: &out)
                noteCommit(of: c, into: &out)
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

    /// chordTolerance lets a modifier landing just after a key still apply to it, unless another
    /// key landed under the modifier: then the modifier was for that later key (camelCase rollover,
    /// "a" then Shift+"S", is "aS"). A key that commits at its lift (home row, Space) went down at
    /// its landing on a real keyboard, before the modifier: a late modifier applies to it only once
    /// lifted again (a fast capital), never while still held (a thumb settling on Cmd or Option
    /// just after the other thumb struck Space does not turn it into Cmd+Space).
    private func isApplicable(_ m: Contact, to k: Contact) -> Bool {
        guard m.isModifier, m.phase == .pending || m.phase == .down, m.burst != .restCandidate,
              inInterval(m, k) else { return false }
        guard k.landedAt < m.landedAt else { return true }
        if case .onLift = k.policy, m.isHeld { return false }
        return !contacts.values.contains {
            $0.id != k.id && !$0.isModifier && $0.phase != .rejected && $0.landedAt >= m.landedAt &&
                inInterval(m, $0)
        }
    }

    /// Key `k` commits now (after its modifiers were reconciled): a pending modifier from whose
    /// interval it commits without being applied is no lone tap any more, and contacts that have
    /// `k` as a burst partner record the commit (a thumb tap is never counted: it only follows keys).
    /// A held, unused modifier that landed within `chordTolerance` after a tap committed at its
    /// lift, with no other key landed under it within `nextKeyWindow`, is a thumb or pinky
    /// settling beside the stroke (both thumbs coming down, one on Space): it rests and never
    /// chords later typing.
    private mutating func noteCommit(of k: Contact, into out: inout [PipelineOutput]) {
        for c in Array(contacts.values) where c.id != k.id && c.phase == .pending {
            if c.isModifier, inInterval(c, k) {
                contacts[c.id]?.keyCommittedWithout = true
                contacts[c.id]?.loneTap = false
            }
            if c.burstPartners.contains(k.id), !isThumbTap(k) {
                contacts[c.id]?.committedPartners[k.id] = PartnerTap(code: k.code, landedAt: k.landedAt,
                                                                     liftedAt: k.liftedAt)
            }
            if restMode, isUnusedHeldModifier(c), c.burst == .none, !k.isHeld, case .onLift = k.policy,
               c.landedAt > k.landedAt, c.landedAt <= k.landedAt + chordTolerance,
               !contacts.values.contains(where: {
                   $0.id != k.id && !$0.isModifier && $0.landedAt >= c.landedAt &&
                       $0.landedAt <= c.landedAt + Self.nextKeyWindow
               }) {
                contacts[c.id]?.phase = .resting
                endFeedback(.restStarted(c.code), into: &out)
            }
        }
    }

    private func isSpaceTap(_ c: Contact) -> Bool {
        guard c.code == Self.space, !c.isModifier, !c.tapOnly, case .onLift = c.policy else { return false }
        return true
    }

    /// A thumb tap: Space, or a tap-only code (left Command remapped to Caps Lock). In a placement
    /// burst these are the settling thumbs; they never confirm a roll for other keys.
    private func isThumbTap(_ c: Contact) -> Bool { c.tapOnly || isSpaceTap(c) }

    /// How many of `c`'s burst keys tapped (committed, or lifted as a tap and still queued), how
    /// many of those were longer than a bounce (`bounceMax`), and whether any is still undecided
    /// (held within its tap limit).
    ///
    /// A partner tap whose key lands again within `bounceMax` of its lift is a finger bouncing as
    /// the hand is put down and never counts (undecided until then); nor does a hand pat.
    private func burstPartnerTaps(_ c: Contact, at t: TimeInterval) -> (taps: Int, long: Int, undecided: Bool) {
        var taps = 0
        var long = 0
        var undecided = false
        func count(_ code: UInt16, _ landed: TimeInterval, _ lifted: TimeInterval?) {
            if let lifted = lifted {
                switch relanded(code, after: lifted, at: t) {
                case true?: return
                case nil:
                    undecided = true
                    return
                case false?: break
                }
            }
            taps += 1
            if (lifted.map { $0 - landed } ?? .infinity) > Self.bounceMax { long += 1 }
        }
        for p in c.committedPartners.values { count(p.code, p.landedAt, p.liftedAt) }
        for pid in c.burstPartners where c.committedPartners[pid] == nil {
            guard let p = contacts[pid], p.phase == .pending, !isThumbTap(p) else { continue }
            switch decision(for: p, at: t, blocked: false, withPartners: false) {
            case .tap, .tapPlain, .press:
                if p.liftedAt != nil, !p.burstPartners.isEmpty {
                    switch isHandPat(p, at: t) {
                    case true?: continue
                    case nil:
                        undecided = true
                        continue
                    case false?: break
                    }
                }
                count(p.code, p.landedAt, p.liftedAt)
            case .wait: undecided = true
            case .rest: break
            }
        }
        return (taps, long, undecided)
    }

    /// Whether `code` landed again within `bounceMax` after `lifted` (nil: that time has not passed).
    private func relanded(_ code: UInt16, after lifted: TimeInterval, at t: TimeInterval) -> Bool? {
        if landings.contains(where: { $0.code == code && $0.t > lifted && $0.t <= lifted + Self.bounceMax }) {
            return true
        }
        return t < lifted + Self.bounceMax ? nil : false
    }

    /// The span of a burst partner: a live contact, a committed tap, or one lifted recently.
    private func partnerSpan(_ c: Contact, _ pid: Int) -> PartnerTap? {
        if let p = contacts[pid] {
            guard !p.isModifier, !isThumbTap(p), p.phase != .rejected else { return nil }
            return PartnerTap(code: p.code, landedAt: p.landedAt, liftedAt: p.liftedAt)
        }
        return c.committedPartners[pid] ?? recentSpans[pid]
    }

    /// A burst key tap that lifts together with two or more burst keys that landed within
    /// `patLandingWindow` of it (lifts chained at most `patLiftGap` apart): a hand patting the keys
    /// or put down and lifted again to reposition, not a roll (whose keys lift in turn, 10 ms or
    /// more apart). nil while such a key is still held and may yet lift into the chain.
    private func isHandPat(_ c: Contact, at t: TimeInterval) -> Bool? {
        guard let lifted = c.liftedAt else { return false }
        var lifts: [TimeInterval] = []
        var held = false
        for pid in c.burstPartners {
            guard let p = partnerSpan(c, pid), abs(p.landedAt - c.landedAt) <= Self.patLandingWindow else { continue }
            if let pl = p.liftedAt {
                lifts.append(pl)
            } else if contacts[pid]?.phase == .pending {
                held = true
            }
        }
        // The chain of lifts through c's lift.
        var low = lifted
        var high = lifted
        var chain = 1
        var grew = true
        while grew {
            grew = false
            for (i, l) in lifts.enumerated() where l >= low - Self.patLiftGap && l <= high + Self.patLiftGap {
                low = min(low, l)
                high = max(high, l)
                chain += 1
                lifts.remove(at: i)
                grew = true
                break
            }
        }
        if chain >= 3 { return true }
        return held && t < high + Self.patLiftGap ? nil : false
    }

    /// Times at which `c`'s burst checks may change: partners' bounce windows, its pat window and
    /// its thumb-settle window, and a bounce follower's tap limit.
    private func burstCheckTimes(_ c: Contact) -> [TimeInterval] {
        guard let lifted = c.liftedAt else { return [] }
        var times: [TimeInterval] = []
        if let fid = c.bounceFollower, let f = contacts[fid] { times.append(f.landedAt + tapMax) }
        guard !c.burstPartners.isEmpty else { return times }
        times.append(lifted + Self.thumbSettleWindow)
        for pid in c.burstPartners {
            if let pl = partnerSpan(c, pid)?.liftedAt { times += [pl + Self.bounceMax, pl + Self.patLiftGap] }
        }
        times += [lifted + Self.patLiftGap, lifted + Self.bounceMax]
        return times
    }

    /// A thumb tap that landed while typing was in flow and before every key of its burst: the
    /// other thumb striking Space (or the switch) while the typing hand returns home. Its decision
    /// waits `thumbSettleWindow` after its lift: a thumb landing on the thumb row by then is the
    /// thumb settling (a bounce, `true`); otherwise it types (`false`). nil: not yet known.
    private func thumbResettled(_ c: Contact, at t: TimeInterval) -> Bool? {
        guard let lifted = c.liftedAt else { return true }
        let rows = Self.thumbRowCodes.union([c.code])
        if landings.contains(where: { rows.contains($0.code) && $0.t > lifted && $0.t <= lifted + Self.thumbSettleWindow }) {
            return true
        }
        return t < lifted + Self.thumbSettleWindow ? nil : false
    }

    private func leadsBurstInFlow(_ c: Contact) -> Bool {
        c.landedInFlow && c.burstPartners.allSatisfy { pid in
            partnerSpan(c, pid).map { $0.landedAt > c.landedAt } ?? true
        }
    }

    /// A tap of a placement-burst member, lifted within its tap limit.
    /// - Thumb taps (Space, tap-only codes): they tap once a key of the burst taps (a roll, e.g.
    ///   "sa d", "hull pink" while the other hand lands, or a switch inside "ask"), and rest when
    ///   the keys rest (a hand put down, the thumb grazing its key on the way). Another thumb tap
    ///   never counts, nor does one finger's bounce (a tap of at most `bounceMax`) alone, nor a
    ///   finger whose key lands again within `bounceMax` of its lift. One that led its burst while
    ///   typing was in flow types unless the thumb settles right after it (`thumbResettled`).
    /// - Other keys: a tap that no held suspect modifier would join taps as usual. One that a held
    ///   suspect would join (a thumb or pinky that settled with the hand) waits for a second key of
    ///   the burst: a roll posts the modifier with it (fast capitals); a lone tap among resting
    ///   fingers, or among other bouncing fingers, is a finger bouncing as the hand lands and types
    ///   plain, never posting the modifier (F5). A suspect already lifted within its tap limit is no
    ///   resting thumb, unless it was a graze and this key itself bounced.
    private func burstTapDecision(_ c: Contact, at t: TimeInterval) -> Decision {
        let partners = burstPartnerTaps(c, at: t)
        if isThumbTap(c) {
            if partners.taps >= 2 || partners.long >= 1 { return .tap }
            if leadsBurstInFlow(c) {
                switch thumbResettled(c, at: t) {
                case false?: return .tap
                case nil: return .wait
                case true?: break
                }
            }
            return partners.undecided ? .wait : .rest
        }
        let joining = contacts.values.filter { $0.burst == .suspect && isApplicable($0, to: c) }
        guard !joining.isEmpty else { return .tap }
        // Its own key landing again right after it, while a thumb rests on or just grazed (at
        // most `bounceMax`) its modifier: a finger bouncing as the hand is put down. Plain.
        let grazed = joining.contains { m in m.liftedAt.map { $0 - m.landedAt <= Self.bounceMax } ?? true }
        if grazed, let lifted = c.liftedAt {
            switch relanded(c.code, after: lifted, at: t) {
            case true?: return .tapPlain
            case nil: return .wait
            case false?: break
            }
        }
        guard joining.contains(where: \.isHeld) else { return .tap }
        if partners.taps >= 1 { return .tap }
        return partners.undecided ? .wait : .tapPlain
    }

    /// The latest of the waits that apply to a lifted tap before it may commit (nil: none).
    private func tapWaitEnd(_ c: Contact) -> TimeInterval? {
        [settleWaitEnd(c), freshModifierWaitEnd(c), bounceWaitEnd(c), lateModifierWaitEnd(c)]
            .compactMap { $0 }.max()
    }

    /// A tap committed at its lift (home letter, Space) while a modifier that landed up to
    /// `chordTolerance` after it is still held, unused, with no other key under it: a fast capital
    /// (Shift lifts soon and applies, `isApplicable`) or a thumb settling beside the stroke (it is
    /// still held at its tap limit: the tap commits plain and the modifier rests, `noteCommit`).
    /// It waits until that modifier lifts, reaches `tapMax`, or a key lands under it (the key it
    /// was pressed for, or typing beside a resting thumb).
    private func lateModifierWaitEnd(_ c: Contact) -> TimeInterval? {
        guard restMode, c.phase == .pending, !c.isHeld, case .onLift = c.policy else { return nil }
        return contacts.values.filter { m in
            isUnusedHeldModifier(m) && m.burst == .none && m.landedAt > c.landedAt &&
                m.landedAt <= c.landedAt + chordTolerance &&
                !contacts.values.contains { $0.id != c.id && !$0.isModifier && $0.landedAt >= m.landedAt }
        }.map { $0.landedAt + tapMax }.max()
    }

    /// A tap-only or Space tap lifted while a placement burst is one landing away (rest-capable
    /// or any keys, held and undecided, landed from `burstWindow` before it to its lift): it waits
    /// until `burstWindow` after the last of those landings, the latest a burst including them can
    /// form. nil when there is nothing to wait for.
    private func settleWaitEnd(_ c: Contact) -> TimeInterval? {
        guard restMode, c.phase == .pending, c.tapOnly || isSpaceTap(c), !c.silentLift,
              c.burstPartners.isEmpty, let lifted = c.liftedAt else { return nil }
        let companions = contacts.values.filter {
            $0.id != c.id && $0.isHeld && $0.isUnresolvedKey &&
                $0.landedAt >= c.landedAt - burstWindow && $0.landedAt <= lifted
        }
        guard let last = companions.map(\.landedAt).max() else { return nil }
        let restCapable = companions.filter { settings.isRestCapable($0.code) }.count
        guard restCapable >= burstMinRestCapable - 1 || companions.count >= burstMinKeys - 1 else { return nil }
        return last + burstWindow
    }

    /// A rest-capable tap (home letter or Space) that would post a held modifier no key has used
    /// yet, one that landed less than `burstWindow` before it: the thumb and the finger may be the
    /// start of a hand being put down (the finger bouncing off its key). It waits until
    /// `burstWindow` after the modifier landed, the latest a burst including the modifier can form;
    /// a burst that forms meanwhile makes it a burst member (`burstTapDecision`). A deliberate
    /// shortcut or capital lifts later than that, so it rarely waits at all.
    private func freshModifierWaitEnd(_ c: Contact) -> TimeInterval? {
        guard restMode, c.phase == .pending, !c.isHeld, !c.tapOnly, c.burstPartners.isEmpty,
              case .onLift = c.policy else { return nil }
        return contacts.values.filter {
            isUnusedHeldModifier($0) && $0.burst == .none && c.landedAt - $0.landedAt < burstWindow &&
                isApplicable($0, to: c)
        }.map { $0.landedAt + burstWindow }.max()
    }

    /// A tap-only tap of at most `bounceMax`: it waits `bounceMax` after its lift, because a thumb
    /// settling onto the key (or onto a neighbouring thumb key) may land right away; then it was a
    /// bounce (`dropBounces`) and posts nothing (no input-source switch while a thumb comes to rest).
    private func bounceWaitEnd(_ c: Contact) -> TimeInterval? {
        guard restMode, c.tapOnly, c.phase == .pending, !c.silentLift, let lifted = c.liftedAt,
              lifted - c.landedAt <= Self.bounceMax else { return nil }
        return lifted + Self.bounceMax
    }

    /// A key that may lead a hand being put down (an index landing first on G, one key off): at
    /// its confirmation, two or more keys that landed after it are still held and undecided, so
    /// one more landing makes a placement burst. It waits until `burstWindow` after its own
    /// landing, the latest a burst including it can form (a burst converts it to a tap).
    private func placementLeadWaitEnd(_ c: Contact) -> TimeInterval? {
        guard restMode, c.isHeld, c.phase == .pending, !c.everPosted else { return nil }
        let followers = contacts.values.filter {
            $0.id != c.id && $0.isHeld && $0.isUnresolvedKey && $0.landedAt >= c.landedAt
        }
        guard followers.count >= 2 else { return nil }
        return c.landedAt + burstWindow
    }

    /// A very short, still undecided thumb tap is a bounce when the same key, or (for a tap-only
    /// code) a neighbouring thumb key, lands again right after it: a modifier tap at once; a Space
    /// or tap-only tap once that `follower` contact does not lift as a tap (a thumb settling, not
    /// a typed Space or a quick second switch).
    private mutating func dropBounces(of code: UInt16, at t: TimeInterval, follower: Int) {
        for c in Array(contacts.values) where c.phase == .pending {
            guard c.code == code || (c.tapOnly && Self.thumbRowCodes.contains(code)),
                  let lifted = c.liftedAt, lifted - c.landedAt <= Self.bounceMax,
                  t - lifted <= Self.bounceMax else { continue }
            if c.isModifier {
                contacts[c.id]?.loneTap = false
            } else if (c.tapOnly || isSpaceTap(c)), c.bounceFollower == nil, !c.silentLift {
                contacts[c.id]?.bounceFollower = follower
            }
        }
    }

    private func isNeededByUnresolvedKey(_ m: Contact, besides k: Int? = nil) -> Bool {
        contacts.values.contains { $0.id != k && $0.isUnresolvedKey && isApplicable(m, to: $0) }
    }

    /// Before k goes down: exactly k's applicable modifiers are posted (I2) unless a posted
    /// one is still needed by another unresolved key (I4). Without `includingSuspects` (a bouncing
    /// finger in a placement burst) the burst's suspect modifiers do not join k.
    private mutating func reconcileModifiers(for k: Contact, includingSuspects: Bool = true,
                                             into out: inout [PipelineOutput]) {
        let ordered = modifierIDs()
        let applicable = Set(ordered.filter { id in
            guard let m = contacts[id], includingSuspects || m.burst != .suspect else { return false }
            return isApplicable(m, to: k)
        })
        for id in ordered.reversed() {
            guard let m = contacts[id], m.phase == .down, !applicable.contains(id),
                  !isNeededByUnresolvedKey(m, besides: k.id) else { continue }
            releaseModifier(id, into: &out)
        }
        for id in ordered where applicable.contains(id) {
            if contacts[id]?.phase == .pending { postModifier(id, into: &out) }
            contacts[id]?.used = true
        }
    }

    /// Resting `.off` only: a held modifier is posted at the confirmation delay (today's behaviour).
    private func revealIsDue(_ m: Contact, at t: TimeInterval) -> Bool {
        !restMode && m.isModifier && m.isHeld && m.phase == .pending && !m.revealDone &&
            t >= m.landedAt + confirmationDelay
    }

    /// Held, never posted and never used (no key committed with it, no pointer use).
    private func isUnusedHeldModifier(_ m: Contact) -> Bool {
        m.isModifier && m.isHeld && m.phase == .pending && !m.everPosted && !m.used
    }

    /// Key contact `key` just started resting: a modifier held unused around it is a resting
    /// thumb or pinky (hands settling), so it rests too and never joins a later chord, unless it
    /// still waits for a chord (`awaitsChord`). A burst suspect always rests here: this settles
    /// it before a partner tap queued behind the resting partners commits (F04).
    private mutating func restUnusedModifiers(after key: Contact, into out: inout [PipelineOutput]) {
        guard restMode else { return }
        for id in modifierIDs() {
            guard let m = contacts[id], isUnusedHeldModifier(m) else { continue }
            if m.burst == .suspect {
                contacts[id]?.burst = .restCandidate
            } else if awaitsChord(m, restedKey: key) || pressedAfterSettle(m, restedKey: key) ||
                        (pressedAmongSettledHands(m) && onOppositeHands(m, [key])) {
                continue
            }
            contacts[id]?.phase = .resting
            endFeedback(.restStarted(m.code), into: &out)
        }
    }

    /// A deliberate chord may still come: a key the modifier applies to is unresolved (a shortcut
    /// typed right after a finger or the thumb on Space came back to rest waits behind that
    /// contact, I1), or the key that rested is one it applied to, was pressed among hands already
    /// resting (or is the only key on the deck: hands hovering), and is the first key touched since
    /// the modifier landed (a slow Shift+K that rested; Shift stays for the retry). Space is
    /// excluded: thumbs settle on Cmd and Space together. A key that rested after other keys landed
    /// beside the modifier is a hand settling with it (a staggered placement), not a slow chord.
    private func awaitsChord(_ m: Contact, restedKey k: Contact) -> Bool {
        if isNeededByUnresolvedKey(m) { return true }
        let onlyKeyDown = !contacts.values.contains { $0.id != k.id && !$0.isModifier && $0.isHeld }
        guard k.code != Self.space, k.landedAmongRestingHands || onlyKeyDown, isApplicable(m, to: k),
              k.landedAt - m.landedAt > chordTolerance else { return false }
        return !contacts.values.contains {
            $0.id != k.id && !$0.isModifier && $0.landedAt >= m.landedAt - chordTolerance &&
                $0.landedAt < k.landedAt
        }
    }

    /// PV4 with a finger re-landing or anchoring: the modifier was pressed after `k` (the only key
    /// then still settling, not Space) landed, with or without resting hands, so `k` resting is
    /// not the modifier settling (a hover typist's index anchored on J, then Cmd+C). A key landing
    /// within `chordTolerance` of the modifier was put down with it (a hand settling).
    private func pressedAfterSettle(_ m: Contact, restedKey k: Contact) -> Bool {
        settlingCount(m) <= 1 && k.landedAt < m.landedAt - chordTolerance && k.code != Self.space
    }

    /// Keys (not thumb taps) that were held and undecided at the modifier's landing and are still
    /// held, undecided or resting (a letter tap in flight then is not a finger settling).
    private func settlingCount(_ m: Contact) -> Int {
        m.settlingAtLanding.filter { id in
            guard let c = contacts[id] else { return false }
            return c.isHeld && (c.phase == .pending || c.phase == .resting)
        }.count
    }

    /// PV4: pressed among hands already resting, at most one finger still settling.
    private func pressedAmongSettledHands(_ m: Contact) -> Bool {
        m.landedAmongRestingHands && settlingCount(m) <= 1
    }

    /// Every key in `keys` is on the other hand from the modifier's side (the other hand landing).
    private func onOppositeHands(_ m: Contact, _ keys: [Contact]) -> Bool {
        let other: Set<UInt16>
        if Self.leftModifierCodes.contains(m.code) {
            other = Self.rightHandCodes
        } else if Self.rightModifierCodes.contains(m.code) {
            other = Self.leftHandCodes
        } else {
            return false
        }
        return !keys.isEmpty && keys.allSatisfy { other.contains($0.code) }
    }

    private mutating func revealModifiers(at t: TimeInterval, into out: inout [PipelineOutput]) -> Bool {
        var changed = false
        for id in modifierIDs() {
            guard let m = contacts[id], revealIsDue(m, at: t) else { continue }
            postModifier(id, into: &out)
            changed = true
        }
        return changed
    }

    /// A suspect modifier is decided once every key of its burst is decided without having posted
    /// it (a partner that commits while it applies posts the modifier through the reconcile, ending
    /// the suspicion). When two or more of those keys committed (as taps the modifier did not apply
    /// to: it landed late in a fast roll, "lad" then Cmd+V), the burst was typing, not a hand put
    /// down: the modifier is an ordinary held modifier again and joins the next key. Otherwise
    /// (rested, rejected, dropped, at most one bouncing finger) it rests and never joins a chord.
    private mutating func resolveSuspects(at t: TimeInterval, into out: inout [PipelineOutput]) -> Bool {
        var changed = false
        for id in modifierIDs() {
            guard let m = contacts[id], m.burst == .suspect, m.phase == .pending else { continue }
            let settled = m.burstPartners.allSatisfy { pid in
                guard let p = contacts[pid] else { return true }
                return p.phase != .pending
            }
            guard settled else { continue }
            let typed = m.committedPartners.values.filter { p in
                p.liftedAt.map { relanded(p.code, after: $0, at: t) != true } ?? true
            }
            if typed.count >= 2 {
                contacts[id]?.burst = .none
                contacts[id]?.burstPartners = []
                contacts[id]?.committedPartners = [:]
                changed = true
                continue
            }
            contacts[id]?.burst = .restCandidate
            contacts[id]?.phase = .resting
            endFeedback(.restStarted(m.code), into: &out)
            changed = true
        }
        return changed
    }

    /// A held modifier never posted nor used, lying `staleModifier` since landing among at least
    /// `staleRestingContacts` resting contacts, with no key waiting for it (rest modes only).
    private func staleIsDue(_ m: Contact, at t: TimeInterval) -> Bool {
        guard restMode, isUnusedHeldModifier(m), t >= m.landedAt + staleModifier else { return false }
        let resting = contacts.values.filter { $0.id != m.id && $0.isHeld && $0.phase == .resting }.count
        return resting >= staleRestingContacts && !isNeededByUnresolvedKey(m)
    }

    /// Stale modifiers rest silently: they were never posted, so there is nothing to release.
    private mutating func restStaleModifiers(at t: TimeInterval, into out: inout [PipelineOutput]) -> Bool {
        var changed = false
        for id in modifierIDs() {
            guard let m = contacts[id], staleIsDue(m, at: t) else { continue }
            if m.burst == .suspect { contacts[id]?.burst = .restCandidate }
            contacts[id]?.phase = .resting
            endFeedback(.restStarted(m.code), into: &out)
            changed = true
        }
        return changed
    }

    /// Lifted modifiers finish once no key from their interval is unresolved (I4).
    private mutating func finishLiftedModifiers(into out: inout [PipelineOutput]) -> Bool {
        var changed = false
        for id in modifierIDs() {
            guard let m = contacts[id], !m.isHeld, m.phase == .pending || m.phase == .down,
                  !isWaitingLoneTap(m),
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

    private mutating func postModifier(_ id: Int, into out: inout [PipelineOutput]) {
        guard let m = contacts[id] else { return }
        postDown(m.code, into: &out)
        out.append(.feedback(.committed(m.code)))
        contacts[id]?.phase = .down
        contacts[id]?.everPosted = true
        contacts[id]?.burst = .none
        contacts[id]?.revealDone = true
    }

    /// A held modifier released for a key it does not apply to may be posted again later.
    private mutating func releaseModifier(_ id: Int, into out: inout [PipelineOutput]) {
        guard let m = contacts[id] else { return }
        postUp(m.code, into: &out)
        contacts[id]?.phase = m.isHeld ? .pending : .done
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
