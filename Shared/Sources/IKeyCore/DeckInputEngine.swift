import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum ContactDisposition: Sendable { case pending, accepted, resting, rejected }

public struct DeckContactIndicator: Sendable {
    public var point: CGPoint
    public var radius: Double
    public var disposition: ContactDisposition

    public init(point: CGPoint, radius: Double, disposition: ContactDisposition) {
        self.point = point; self.radius = radius; self.disposition = disposition
    }
}

/// Side effects for the surface: open the settings panel, or update the drawn key presses.
public enum EngineSignal: Equatable, Sendable {
    case openPanel
    case feedback(KeyFeedback)
}

/// How the settings panel is opened from the deck.
public enum PanelTrigger: String, Codable, CaseIterable, Sendable {
    /// One fingertip held still on Touch ID for 0.6 s.
    case touchIDHold
    /// Two fingertips held still on the left palm rest for 0.8 s (photo mode has no Touch ID).
    case palmRestTwoFingerHold
}

/// The iPad deck's input engine: routes each touch by where it landed (key, trackpad, Touch ID,
/// elsewhere), applies palm rules, and drives `KeyCommitPipeline` and `TrackpadRecognizer`,
/// emitting protocol v2 `PadInput`. Deterministic: callers pass monotonic touch timestamps
/// (earlier times are clamped) and call `advance(to:)` at `nextDeadline`.
///
/// Every call first applies everything due at or before its time, in time order, then its
/// samples, then anything the samples made due (a hold-to-drag press that waited while another
/// contact held the button), so `nextDeadline` is always later than the last call. A contact
/// keeps the region it landed in. Held modifiers are committed right before the pointer output
/// they apply to (I6; see `handle(_:at:into:)` for trackpad output). Hold contacts (the panel
/// trigger) never produce input.
public struct DeckInputEngine {
    private enum Role {
        case key(code: UInt16, broadThumb: Bool)
        case pad(size: ContactSize)
        /// Panel-hold candidate (Touch ID or palm rest).
        case hold
        /// Rejected at touch-down or by the panel-hold rules: produces nothing until lift.
        case ignored
    }

    private struct Contact {
        /// Unique id handed to the pipeline, recognizer and hold detector, so a reused touch id
        /// never collides with a lifted contact they still track.
        let serial: Int
        var role: Role
        let start: CGPoint
        let onTouchID: Bool
        /// Landed on the trackpad (whatever its role): it can count as a broad contact.
        var onTrackpad = false
        var point: CGPoint
        var radius: Double
        var maxDistance = 0.0
        /// Sticky engine-level rejection (size, palm, typing pause, invalid sample).
        var rejected = false
        /// Trackpad contact handed to the recognizer.
        var forwarded = false
        /// Trackpad contact waiting for its confirmation delay.
        var confirmAt: TimeInterval?
        /// Trackpad contact larger than a fingertip in the bottom zone (at touch-down, or grown
        /// there later), accepted or not, suppressed or not: it counts for the two-broad-contacts
        /// rule until it lifts.
        var broadCandidate = false

        var isPipelineKey: Bool {
            if case .key = role { return true }
            return false
        }
    }

    private static let space: UInt16 = 49
    private static let touchID = "touchid"
    private static let fallbackMMPerPoint = 0.1927
    private static let padConfirmDelay: TimeInterval = 0.045
    private static let keyConfirmDelay: TimeInterval = 0.045
    private static let typingPause: TimeInterval = 0.35
    private static let broadThumbTravelPt = 18.0
    private static let broadZoneMM = 20.0
    private static let holdTravelMM = 4.0
    /// A pending trackpad fingertip that lifts within this travel is still handed over as a tap.
    private static let earlyTapSlopMM = 1.5
    private static let maxSignals = 64

    private let hitTester: KeyHitTester
    private let geometry: TrackpadGeometry
    private let protection: TouchProtectionSettings
    private let typing: TypingSettings
    private let panelTrigger: PanelTrigger
    private let mmPerPoint: Double
    private let instantRadius: Double
    private let palmRestMaxX: CGFloat
    private let keyFieldBottom: CGFloat
    private var pipeline: KeyCommitPipeline
    private var recognizer: TrackpadRecognizer
    private var hold: HoldDetector
    private var contacts: [Int: Contact] = [:]
    /// Pipeline serial -> code of key contacts that may still show `tentative` (pruned on landing).
    private var landedKeys: [Int: UInt16] = [:]
    private var signals: [EngineSignal] = []
    private var suppressed = false
    private var nextSerial = 0
    private var lastTime: TimeInterval?

    public init(deck: ResolvedDeck, protection: TouchProtectionSettings = .init(), typing: TypingSettings = .init(),
                trackpad: TrackpadSettings = .init(), panelTrigger: PanelTrigger = .touchIDHold) {
        self.protection = protection
        self.typing = typing
        self.panelTrigger = panelTrigger
        hitTester = KeyHitTester(deck: deck, captureRadius: KeyHitTester.defaultCaptureRadius(for: deck))
        geometry = TrackpadGeometry(rect: deck.trackpad, physicalWidthMM: deck.trackpadPhysicalWidthMM,
                                    physicalHeightMM: deck.trackpadPhysicalHeightMM)
        let mmPerPoint = deck.mmPerPoint.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? Self.fallbackMMPerPoint
        self.mmPerPoint = mmPerPoint
        let protectionScale: Double
        switch protection.sensitivity {
        case .strict: instantRadius = 18; protectionScale = 1.5
        case .balanced: instantRadius = 24; protectionScale = 1.0
        case .relaxed: instantRadius = 30; protectionScale = 0.7
        }
        palmRestMaxX = deck.trackpad.minX
        keyFieldBottom = deck.keys.map(\.rect.maxY).max() ?? deck.trackpad.minY
        pipeline = KeyCommitPipeline(settings: typing, confirmationDelay: protection.enabled ? Self.keyConfirmDelay : 0)
        recognizer = TrackpadRecognizer(geometry: geometry, settings: trackpad, protectionScale: protectionScale)
        let holdTravel = Self.holdTravelMM / mmPerPoint
        switch panelTrigger {
        case .touchIDHold: hold = HoldDetector(holdTime: 0.6, maxTravelPt: holdTravel, fingers: 1)
        case .palmRestTwoFingerHold: hold = HoldDetector(holdTime: 0.8, maxTravelPt: holdTravel, fingers: 2)
        }
    }

    // MARK: - Touches

    public mutating func begin(_ samples: [TouchSample], at time: TimeInterval) -> [PadInput] {
        let t = clock(time)
        var out: [PadInput] = []
        runDeadlines(through: t, into: &out)
        for sample in samples where contacts[sample.id] == nil {
            beginContact(sample, at: t, into: &out)
        }
        runDeadlines(through: t, into: &out)
        return out
    }

    public mutating func move(_ samples: [TouchSample], at time: TimeInterval) -> [PadInput] {
        let t = clock(time)
        var out: [PadInput] = []
        runDeadlines(through: t, into: &out)
        for sample in samples { update(sample, at: t, into: &out) }
        runDeadlines(through: t, into: &out)
        return out
    }

    public mutating func end(_ samples: [TouchSample], at time: TimeInterval, cancelled: Bool = false) -> [PadInput] {
        let t = clock(time)
        var out: [PadInput] = []
        runDeadlines(through: t, into: &out)
        // Trackpad contacts take their final samples first, so every trackpad lift in this batch
        // is judged with the fingers' final state before the recognizer sees any of them end.
        var padLifts = Set<Int>()
        for sample in samples where contacts[sample.id]?.onTrackpad == true && padLifts.insert(sample.id).inserted {
            update(sample, at: t, into: &out)
        }
        if !cancelled { forwardBeforePadLift(padLifts, at: t, into: &out) }
        for sample in samples {
            if !padLifts.contains(sample.id) { update(sample, at: t, into: &out) }
            guard let c = contacts.removeValue(forKey: sample.id) else { continue }
            switch c.role {
            case .key:
                handle(pipeline.lift(id: c.serial, at: t, cancelled: cancelled), at: t, into: &out)
            case .pad:
                if c.forwarded {
                    handle(recognizer.ended(id: c.serial, time: t, cancelled: cancelled), at: t, into: &out)
                }
            case .hold:
                hold.ended(id: c.serial, time: t)
            case .ignored:
                break
            }
        }
        runDeadlines(through: t, into: &out)
        return out
    }

    public mutating func advance(to time: TimeInterval) -> [PadInput] {
        let t = clock(time)
        var out: [PadInput] = []
        runDeadlines(through: t, into: &out)
        return out
    }

    /// Forgets every contact (touches still down produce nothing until they lift) and returns
    /// `[.releaseAll]`, which also covers held trackpad buttons. The drawn deck is told too:
    /// posted keys get `released`, keys still showing `tentative` get `rejected`. Meant for a
    /// caller that forgets its touches too (their lifts may never arrive), so nothing is kept.
    public mutating func reset() -> [PadInput] {
        releaseAll(keepingHold: false, keepingTrackpad: false)
    }

    /// Panel-only mode. Turning it on returns `reset()`'s output, except that a panel hold in
    /// progress keeps going and trackpad contacts still down stay known as dead contacts (they
    /// produce nothing, but a broad one keeps counting for the two-broad-contacts rule until it
    /// lifts); afterwards new key and trackpad contacts are rejected while the panel hold keeps
    /// working. Turning it off affects new contacts only. Repeating the current state returns
    /// nothing.
    public mutating func setInputSuppressed(_ suppressed: Bool) -> [PadInput] {
        guard suppressed != self.suppressed else { return [] }
        self.suppressed = suppressed
        return suppressed ? releaseAll(keepingHold: true, keepingTrackpad: true) : []
    }

    public var isInputSuppressed: Bool { suppressed }

    /// Pending signals, oldest first (at most 64; older ones are dropped).
    public mutating func drainSignals() -> [EngineSignal] {
        defer { signals.removeAll() }
        return signals
    }

    // MARK: - State

    public var nextDeadline: TimeInterval? {
        var deadlines = [pipeline.nextDeadline, recognizer.nextDeadline, hold.nextDeadline]
        for c in contacts.values where !c.rejected { deadlines.append(c.confirmAt) }
        return deadlines.compactMap { $0 }.min()
    }

    public var indicators: [DeckContactIndicator] {
        contacts.sorted { $0.key < $1.key }.compactMap { _, c in
            guard c.point.x.isFinite, c.point.y.isFinite, c.radius.isFinite else { return nil }
            return DeckContactIndicator(point: c.point, radius: c.radius, disposition: disposition(of: c))
        }
    }

    public var hasActiveContacts: Bool { !contacts.isEmpty }
    public var heldKeyCodes: Set<UInt16> { pipeline.postedCodes }
    public var heldButtons: Set<PointerButton> { recognizer.heldButtons }

    public func panelHoldProgress(at time: TimeInterval) -> Double? { hold.progress(at: time) }

    /// Before trackpad contacts lift (not cancelled), the recognizer must see every fingertip
    /// that is physically down together, with its real travel, or one quick two-finger tap would
    /// reach it as two one-finger taps (a left double-click instead of a secondary click), and a
    /// two- or three-finger touch with one slid finger would reach it as one finger fewer (a left
    /// click instead of nothing, a secondary click instead of Look Up):
    /// - a pending fingertip lifting here within 1.5 mm of where it landed is a quick tap: it is
    ///   handed over and ends with the others;
    /// - a pending fingertip lifting here after sliding further is handed over too whenever the
    ///   recognizer takes part (another lift here reaches it, it holds a contact, or another
    ///   fingertip is still waiting), so it keeps the true finger count and applies its own slop
    ///   (1.5 mm for one or two fingers, 2.0 mm for three) to the real travel; alone it is dropped;
    /// - when any lift here reaches the recognizer, every fingertip still waiting for its
    ///   confirmation is handed over now too (early, as an instant fingertip would have been).
    /// Broad contacts keep their delay. Handed-over contacts begin where they landed and catch up
    /// without pointer output (`forwardPads`).
    private mutating func forwardBeforePadLift(_ lifting: Set<Int>, at t: TimeInterval, into out: inout [PadInput]) {
        func waitingFingertip(_ c: Contact) -> Bool {
            guard !c.rejected, !c.forwarded, c.confirmAt != nil, case .pad(.fingertip) = c.role else { return false }
            return true
        }
        func live(_ c: Contact) -> Bool {
            guard c.forwarded, !c.rejected, case .pad = c.role else { return false }
            return true
        }
        let waitingLifts = lifting.filter { contacts[$0].map(waitingFingertip) ?? false }
        let early = waitingLifts.filter { id in
            (contacts[id]?.maxDistance ?? .infinity) * mmPerPoint <= Self.earlyTapSlopMM
        }
        let stillDown = contacts.filter { !lifting.contains($0.key) && waitingFingertip($0.value) }.map(\.key)
        let slidJoins = waitingLifts.count > early.count && (contacts.values.contains(where: live) || !stillDown.isEmpty)
        let reachesRecognizer = !early.isEmpty || slidJoins || lifting.contains { id in
            contacts[id].map(live) ?? false
        }
        guard reachesRecognizer else { return }
        let order = (Array(waitingLifts) + stillDown).compactMap { id in contacts[id].map { (id: id, serial: $0.serial) } }
        forwardPads(order.sorted(by: { $0.serial < $1.serial }).map(\.id), at: t, into: &out)
    }

    /// Marks a trackpad contact larger than a fingertip in the bottom zone as broad. Two or more
    /// broad contacts down together are a resting hand: every one of them is rejected (including
    /// ones already rejected and still down, and this one, whatever else rejects it). Returns
    /// whether that happened.
    @discardableResult
    private mutating func markBroad(_ id: Int, at t: TimeInterval, into out: inout [PadInput]) -> Bool {
        guard let c = contacts[id], !c.broadCandidate else { return false }
        contacts[id]?.broadCandidate = true
        let others = contacts.filter { $0.key != id && $0.value.broadCandidate }.map(\.key)
        guard !others.isEmpty else { return false }
        for other in (others + [id]).sorted() { rejectPad(other, at: t, into: &out) }
        return true
    }

    private func inBroadZone(_ p: CGPoint) -> Bool {
        geometry.toMM(p).y >= geometry.physicalHeightMM - Self.broadZoneMM
    }

    // MARK: - Touch-down routing

    /// `keepingTrackpad`: trackpad contacts still down become dead contacts (rejected, never
    /// forwarded) instead of being forgotten, so a broad one keeps counting for the
    /// two-broad-contacts rule (and one growing broad later still counts) until it lifts. Used
    /// when the caller keeps tracking its touches (suppression, the panel opening).
    private mutating func releaseAll(keepingHold: Bool, keepingTrackpad: Bool) -> [PadInput] {
        let posted = pipeline.postedCodes
        for code in posted.sorted() { signal(.feedback(.released(code))) }
        let tentative = Set(landedKeys.compactMap { serial, code in
            pipeline.phase(of: serial) == .pending ? code : nil
        }).subtracting(posted)
        for code in tentative.sorted() { signal(.feedback(.rejected(code))) }
        landedKeys.removeAll()
        pipeline.reset()
        _ = recognizer.reset()
        if !keepingHold { hold.reset() }
        contacts = contacts.compactMapValues { c in
            if keepingHold, case .hold = c.role { return c }
            guard keepingTrackpad, c.onTrackpad else { return nil }
            var dead = c
            dead.role = .ignored
            dead.rejected = true
            dead.forwarded = false
            dead.confirmAt = nil
            return dead
        }
        return [.releaseAll]
    }

    private mutating func beginContact(_ s: TouchSample, at t: TimeInterval, into out: inout [PadInput]) {
        let hit: KeyHitTester.Hit = s.isValid ? hitTester.hit(s.point) : .outside
        let serial = nextSerial
        nextSerial += 1
        var c = Contact(serial: serial, role: .ignored, start: s.point, onTouchID: hit == .inert(id: Self.touchID),
                        point: s.point, radius: s.radius)
        c.rejected = true
        let r = s.minimumRadius
        switch hit {
        case .key(let code, _):
            guard !suppressed else { break }
            let broad = protection.enabled && r > fingerRadius
            guard !broad || (code == Self.space && r <= thumbRadius) else { break }
            c.role = .key(code: code, broadThumb: broad)
            c.rejected = false
            contacts[s.id] = c
            landedKeys = landedKeys.filter { pipeline.phase(of: $0.key) == .pending }
            landedKeys[serial] = code
            handle(pipeline.land(id: serial, code: code, at: t, broadThumb: broad), at: t, into: &out)
            // A key landing next to a palm or trackpad finger that is already down is not isolated.
            if contacts.values.contains(where: { $0.serial != serial && !$0.isPipelineKey }) {
                pipeline.noteForeignContact(at: t)
            }
            return
        case .trackpad:
            c.onTrackpad = true
            contacts[s.id] = c
            pipeline.noteForeignContact(at: t)
            beginPad(id: s.id, sample: s, at: t, into: &out)
            return
        case .inert:
            if c.onTouchID, panelTrigger == .touchIDHold { beginTouchIDHold(&c, sample: s, at: t) }
        case .outside:
            if panelTrigger == .palmRestTwoFingerHold, s.isValid, r <= fingerRadius,
               s.point.x < palmRestMaxX, s.point.y > keyFieldBottom {
                hold.began(id: serial, at: s.point, time: t)
                if hold.isTracking(serial) { c.role = .hold; c.rejected = false }
            }
        }
        contacts[s.id] = c
        pipeline.noteForeignContact(at: t)
    }

    /// Only a fingertip that is the only contact on Touch ID starts a hold; a second contact
    /// landing there ends a hold in progress.
    private mutating func beginTouchIDHold(_ c: inout Contact, sample s: TouchSample, at t: TimeInterval) {
        if contacts.values.contains(where: { $0.onTouchID }) {
            cancelHold()
            return
        }
        guard s.minimumRadius <= fingerRadius else { return }
        hold.began(id: c.serial, at: s.point, time: t)
        if hold.isTracking(c.serial) { c.role = .hold; c.rejected = false }
    }

    private mutating func beginPad(id: Int, sample s: TouchSample, at t: TimeInterval, into out: inout [PadInput]) {
        let r = s.minimumRadius
        let bottom = inBroadZone(s.point)
        // Counted even while input is suppressed, so it still guards a later newcomer.
        if protection.enabled, bottom, r > fingerRadius, markBroad(id, at: t, into: &out) { return }
        guard !suppressed else { return }
        if protection.enabled, protection.pauseTrackpadWhileTyping,
           t < (pipeline.lastOrdinaryActivity ?? -.infinity) + Self.typingPause || pipeline.hasHeldOrdinaryKey {
            return
        }
        let size: ContactSize
        if r <= fingerRadius {
            size = .fingertip
        } else if !protection.enabled {
            size = bottom ? .broad : .fingertip
        } else if bottom && r <= thumbRadius {
            size = .broad
        } else {
            return
        }
        contacts[id]?.role = .pad(size: size)
        contacts[id]?.rejected = false
        if !protection.enabled || r <= instantRadius {
            forwardPads([id], at: t, into: &out)
        } else {
            contacts[id]?.confirmAt = t + Self.padConfirmDelay
        }
    }

    /// Hands confirmed trackpad contacts to the recognizer. Each begins where it landed (due
    /// recognizer deadlines are applied first, separately); once all have begun, so the
    /// recognizer counts every finger, each one that travelled while pending catches up to its
    /// current point. The recognizer thus judges taps, slop and drags on the real travel, but the
    /// catch-up never reaches the Mac as motion: no retroactive pointer jump or scroll distance.
    private mutating func forwardPads(_ ids: [Int], at t: TimeInterval, into out: inout [PadInput]) {
        var begun: [Int] = []
        for id in ids {
            guard let c = contacts[id], !c.rejected, !c.forwarded, case .pad(let size) = c.role else { continue }
            contacts[id]?.forwarded = true
            contacts[id]?.confirmAt = nil
            handle(recognizer.advance(to: t), at: t, into: &out)
            handle(recognizer.began(id: c.serial, at: c.start, size: size, time: t), at: t, into: &out)
            begun.append(id)
        }
        for id in begun {
            guard let c = contacts[id], c.forwarded, !c.rejected, c.point != c.start else { continue }
            handle(Self.withoutMotion(recognizer.moved(id: c.serial, to: c.point, time: t)), at: t, into: &out)
        }
    }

    /// Catch-up output: pointer motion and scroll deltas are dropped (a scroll that starts keeps
    /// its `.began`, with zero distance); buttons, counts and gestures stay.
    private static func withoutMotion(_ outputs: [TrackpadOutput]) -> [TrackpadOutput] {
        outputs.compactMap { output in
            switch output {
            case .motion: return nil
            case .scroll(.changed, _, _, _, _, _, _): return nil
            case let .scroll(.began, _, _, dt, _, vx, vy):
                return .scroll(phase: .began, dxMM: 0, dyMM: 0, dt: dt, speed: 0, releaseVX: vx, releaseVY: vy)
            default: return output
            }
        }
    }

    // MARK: - Samples

    private mutating func update(_ s: TouchSample, at t: TimeInterval, into out: inout [PadInput]) {
        guard var c = contacts[s.id] else { return }
        c.point = s.point
        c.radius = s.radius
        if s.isValid {
            c.maxDistance = max(c.maxDistance, hypot(Double(s.point.x - c.start.x), Double(s.point.y - c.start.y)))
        }
        contacts[s.id] = c
        let r = s.minimumRadius
        // A contact that grows past a fingertip in the bottom zone is broad from then on.
        if c.onTrackpad, !c.broadCandidate, protection.enabled, s.isValid, r > fingerRadius, inBroadZone(s.point) {
            markBroad(s.id, at: t, into: &out)
        }
        guard let c = contacts[s.id] else { return }
        switch c.role {
        case .key(let code, let broadThumb):
            guard !c.rejected else { return }
            // A Space contact may grow into a thumb while pending only where Space commits at
            // lift (rest modes); under the .off policy it would press at 45 ms and stay held.
            let tolerant = broadThumb
                || (code == Self.space && spaceCommitsOnLift && pipeline.phase(of: c.serial) == .pending)
            let tooLarge = protection.enabled && r > (tolerant ? thumbRadius : fingerRadius)
            if !s.isValid || tooLarge || (broadThumb && c.maxDistance > Self.broadThumbTravelPt) {
                contacts[s.id]?.rejected = true
                handle(pipeline.reject(id: c.serial, at: t), at: t, into: &out)
            } else {
                handle(pipeline.move(id: c.serial, travelMM: c.maxDistance * mmPerPoint, at: t), at: t, into: &out)
            }
        case .pad(let size):
            guard !c.rejected else { return }
            let tooLarge = protection.enabled && r > (size == .fingertip ? fingerRadius : thumbRadius)
            if !s.isValid || tooLarge {
                rejectPad(s.id, at: t, into: &out)
            } else if c.forwarded {
                handle(recognizer.moved(id: c.serial, to: s.point, time: t), at: t, into: &out)
            }
        case .hold:
            if !s.isValid || r > fingerRadius {
                cancelHold()
            } else {
                hold.moved(id: c.serial, to: s.point, time: t)
            }
        case .ignored:
            break
        }
    }

    private mutating func rejectPad(_ id: Int, at t: TimeInterval, into out: inout [PadInput]) {
        guard let c = contacts[id], !c.rejected else { return }
        contacts[id]?.rejected = true
        contacts[id]?.confirmAt = nil
        if c.forwarded { handle(recognizer.rejected(id: c.serial, time: t), at: t, into: &out) }
    }

    /// Ends the panel hold; its contacts produce nothing until they lift.
    private mutating func cancelHold() {
        hold.reset()
        for (id, c) in contacts {
            guard case .hold = c.role else { continue }
            contacts[id]?.role = .ignored
            contacts[id]?.rejected = true
        }
    }

    // MARK: - Deadlines

    /// Applies every deadline at or before `t` in time order across the pipeline, pending
    /// trackpad confirmations, the recognizer and the panel hold.
    private mutating func runDeadlines(through t: TimeInterval, into out: inout [PadInput]) {
        var previous = -Double.infinity
        var stalls = 0
        while let d = nextDeadline, d <= t {
            // Every component consumes its deadline when advanced to it; this only guards a bug.
            if d <= previous { stalls += 1; if stalls > 16 { break } } else { stalls = 0 }
            previous = d
            handle(pipeline.advance(to: d), at: d, into: &out)
            let due = contacts.compactMap { id, c -> (id: Int, at: TimeInterval, serial: Int)? in
                guard !c.rejected, let at = c.confirmAt, at <= d else { return nil }
                return (id, at, c.serial)
            }.sorted { ($0.at, $0.serial) < ($1.at, $1.serial) }
            // Contacts confirming at the same moment are handed over together.
            var i = 0
            while i < due.count {
                let at = due[i].at
                var group: [Int] = []
                while i < due.count, due[i].at == at { group.append(due[i].id); i += 1 }
                forwardPads(group, at: at, into: &out)
            }
            handle(recognizer.advance(to: d), at: d, into: &out)
            if hold.advance(to: d) {
                signal(.openPanel)
                // The surface keeps tracking its touches, so trackpad contacts stay known.
                out += releaseAll(keepingHold: false, keepingTrackpad: true)
            }
        }
    }

    // MARK: - Output

    private mutating func handle(_ outputs: [PipelineOutput], at t: TimeInterval, into out: inout [PadInput]) {
        for output in outputs {
            switch output {
            case .key(let code, let down):
                out.append(.key(code: code, down: down))
                if down && isOrdinary(code) { noteTyping(at: t, into: &out) }
            case .feedback(let feedback):
                signal(.feedback(feedback))
            }
        }
    }

    /// An ordinary key went down: the recognizer ends drags and scrolls, and trackpad contacts
    /// still waiting for confirmation are typing palms.
    private mutating func noteTyping(at t: TimeInterval, into out: inout [PadInput]) {
        for (id, c) in contacts where c.confirmAt != nil && !c.rejected { rejectPad(id, at: t, into: &out) }
        handle(recognizer.noteTyping(at: t), at: t, into: &out)
    }

    /// Pointer modifiers (amendment F3): right before every pointer output a held modifier applies
    /// to, `commitHeldModifiers` posts the held, unsettled modifiers, and its keys go out first
    /// (Cmd-click, Shift-click, Ctrl-click, Option-scroll, a modified swipe or Look Up tap, a
    /// modifier pressed during a drag such as Option-drag to copy). A committed modifier then stays
    /// down until its contact lifts, so it never goes stale while the pointer uses it.
    ///
    /// Plain pointer motion (no button held), button ups and the other scroll phases commit
    /// nothing, and the engine never calls `notePointerUse`: a thumb resting on Cmd while the
    /// other hand points must stay free to settle with its hand (then it never chords and every
    /// later click stays plain), as on a real MacBook where a resting thumb presses nothing.
    private mutating func handle(_ outputs: [TrackpadOutput], at t: TimeInterval, into out: inout [PadInput]) {
        for output in outputs {
            if Self.takesModifiers(output, dragging: !recognizer.heldButtons.isEmpty), holdsModifierContact {
                handle(pipeline.commitHeldModifiers(at: t), at: t, into: &out)
            }
            out.append(Self.padInput(output))
        }
    }

    /// Pointer outputs a held modifier applies to: a button press (click, drag start, secondary
    /// click), motion while a button is held (a drag), the start of a scroll, and gestures.
    private static func takesModifiers(_ output: TrackpadOutput, dragging: Bool) -> Bool {
        switch output {
        case .button(_, let down, _): return down
        case .motion: return dragging
        case .scroll(let phase, _, _, _, _, _, _): return phase == .began
        case .swipe, .tap: return true
        case .contacts: return false
        }
    }

    /// The pipeline commits only modifiers whose contact is still down, so pointer output skips
    /// it (a full pipeline pass per drag sample) when no such contact exists.
    private var holdsModifierContact: Bool {
        contacts.values.contains { c in
            guard !c.rejected, case .key(let code, _) = c.role else { return false }
            return KeyCommitPipeline.modifierCodes.contains(code) && !typing.tapOnlyCodes.contains(code)
        }
    }

    private mutating func signal(_ s: EngineSignal) {
        signals.append(s)
        if signals.count > Self.maxSignals { signals.removeFirst(signals.count - Self.maxSignals) }
    }

    /// Clamped to the wire limits, so one odd sample can never fail a batch.
    private static func padInput(_ output: TrackpadOutput) -> PadInput {
        func mm(_ v: Double) -> Double { v.isFinite ? min(max(v, -300), 300) : 0 }
        func speed(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 5000) : 0 }
        func velocity(_ v: Double) -> Double { v.isFinite ? min(max(v, -5000), 5000) : 0 }
        func liveDT(_ v: Double) -> Double { v.isFinite && v > 0 ? min(v, 0.5) : 0.001 }
        func boundaryDT(_ v: Double) -> Double { v.isFinite && v >= 0 ? v : 0 }
        switch output {
        case let .motion(dx, dy, dt, s):
            return .motion(PointerMotion(dx: mm(dx), dy: mm(dy), dt: liveDT(dt), speed: speed(s)))
        case let .button(button, down, clickState):
            return .button(button: button, down: down, clickState: min(max(clickState, 1), 3))
        case let .scroll(phase, dx, dy, dt, s, vx, vy):
            let wire: WireScrollPhase
            switch phase {
            case .mayBegin: wire = .mayBegin
            case .began: wire = .began
            case .changed: wire = .changed
            case .ended: wire = .ended
            case .cancelled: wire = .cancelled
            }
            let live = wire == .began || wire == .changed
            return .scroll(ScrollMotion(phase: wire, dx: mm(dx), dy: mm(dy), dt: live ? liveDT(dt) : boundaryDT(dt),
                                        speed: speed(s), releaseVX: vx.map(velocity), releaseVY: vy.map(velocity)))
        case .contacts(let n):
            return .contacts(min(max(n, 0), 10))
        case let .swipe(fingers, direction):
            return .gesture(WireGesture(kind: .swipe, fingers: fingers, direction: direction.rawValue))
        case .tap(let fingers):
            return .gesture(WireGesture(kind: .tap, fingers: fingers))
        }
    }

    // MARK: - Helpers

    private var fingerRadius: Double { protection.sensitivity.fingerRadius }
    private var thumbRadius: Double { protection.sensitivity.thumbRadius }

    /// Mirrors the pipeline's Space policy: onLift (never pressed while held) in rest modes.
    private var spaceCommitsOnLift: Bool {
        typing.resting != .off && (typing.tapOnlyCodes.contains(Self.space) || typing.isRestCapable(Self.space))
    }

    /// Caps Lock and tap-only codes are ordinary keys (they type); modifiers are not.
    private func isOrdinary(_ code: UInt16) -> Bool {
        !KeyCommitPipeline.modifierCodes.contains(code) || typing.tapOnlyCodes.contains(code)
    }

    private func disposition(of c: Contact) -> ContactDisposition {
        if c.rejected { return .rejected }
        switch c.role {
        case .key:
            switch pipeline.phase(of: c.serial) {
            case .pending: return .pending
            case .resting: return .resting
            case .rejected: return .rejected
            case .down, .done, nil: return .accepted
            }
        case .pad: return c.forwarded ? .accepted : .pending
        case .hold: return .pending
        case .ignored: return .rejected
        }
    }

    private mutating func clock(_ time: TimeInterval) -> TimeInterval {
        if time.isFinite { lastTime = max(lastTime ?? time, time) }
        return lastTime ?? 0
    }
}
