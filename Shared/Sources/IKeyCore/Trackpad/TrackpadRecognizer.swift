import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum ContactSize: Sendable { case fingertip, broad }

public enum TrackpadScrollPhase: String, Codable, Sendable { case mayBegin, began, changed, ended, cancelled }

/// Finger direction; `up` is toward the hinge (decreasing y).
public enum SwipeDirection: String, Codable, Sendable { case up, down, left, right }

/// Recognized trackpad intent. Distances are millimetres of finger travel in
/// trackpad coordinates (+y away from the hinge); the Mac applies acceleration,
/// scroll direction and momentum.
public enum TrackpadOutput: Equatable, Sendable {
    case motion(dxMM: Double, dyMM: Double, dt: Double, speed: Double)
    case button(PointerButton, down: Bool, clickState: Int)
    case scroll(phase: TrackpadScrollPhase, dxMM: Double, dyMM: Double, dt: Double, speed: Double,
                releaseVX: Double?, releaseVY: Double?)
    case contacts(Int)
    case swipe(fingers: Int, direction: SwipeDirection)
    case tap(fingers: Int)
}

/// Deterministic MacBook-trackpad intent recognizer working in physical
/// millimetres with caller-supplied touch timestamps.
///
/// Contacts take exclusive roles: fingers (counted; drive pointer, scroll and
/// gestures), thumbs (resting thumbs and thumb-tap candidates; never counted)
/// and ignored contacts (palm heels, typing bands, edge exits). No call to
/// `began` ever presses a button; presses come from lifts, motion or deadlines.
public struct TrackpadRecognizer {
    private struct Vec: Equatable {
        var x = 0.0, y = 0.0
        static let zero = Vec()
        static func + (a: Vec, b: Vec) -> Vec { Vec(x: a.x + b.x, y: a.y + b.y) }
        static func - (a: Vec, b: Vec) -> Vec { Vec(x: a.x - b.x, y: a.y - b.y) }
        static func / (a: Vec, d: Double) -> Vec { Vec(x: a.x / d, y: a.y / d) }
        var length: Double { hypot(x, y) }
        func distance(to other: Vec) -> Double { (self - other).length }
    }

    private enum Role { case finger, thumb, ignored }

    /// Why a counted finger drives nothing until it lifts.
    private enum Inert {
        /// Present at noteTyping (or a typing rejection); stays inert until it lifts.
        case typing
        /// Left behind when a scroll or gesture ended; a new finger brings it back.
        case lingering
    }

    private struct Contact {
        var role: Role
        let size: ContactSize
        var start: Vec
        var last: Vec
        let beganAt: TimeInterval
        var lastTime: TimeInterval
        let inClickZone: Bool
        var maxTravel = 0.0
        /// Counted for `.contacts` but excluded from pointer, scroll, gestures and taps.
        var inert: Inert?
        /// Left the trackpad; ignored until it re-enters (as a new contact) or lifts.
        var exited = false
        /// Second touch of a finger tap-drag; motion is held back until it decides.
        var tapDragCandidate = false
        /// Second touch of a thumb tap-hold drag.
        var thumbHoldCandidate = false
        /// Touch that landed while a drag lock held the button; its tap releases it.
        var lockOwner = false
        /// This contact already pressed the button once.
        var pressSpent = false
        var buffered = Vec.zero
        /// Where a button-holding thumb was when it became the only contact.
        var soleAnchor: Vec?
        var drives = false
        var velocity = VelocityEstimator()

        init(role: Role, size: ContactSize, at p: Vec, time: TimeInterval, inClickZone: Bool) {
            self.role = role
            self.size = size
            start = p
            last = p
            beganAt = time
            lastTime = time
            self.inClickZone = inClickZone
            velocity.add(x: p.x, y: p.y, at: time)
        }
    }

    private struct ScrollState {
        var began = false
        var sum = Vec.zero
        let span0: Double
        let start: TimeInterval
        var lastEmit: TimeInterval
        var velocity = VelocityEstimator()
    }

    private struct MultiState {
        var sum = Vec.zero
        let start: TimeInterval
        var lastEmit: TimeInterval
        var fingers: Int
        var swiped = false
        var dragging = false
        var allowDrag: Bool
        /// Where each finger was when the gesture began (three-finger drag needs them all moving).
        var anchors: [Int: Vec] = [:]
        var velocity = VelocityEstimator()
    }

    /// The mode of the active (non-inert) fingers; `.idle` when none.
    private enum Mode { case idle, pointer, scroll(ScrollState), multi(MultiState) }

    /// Who holds the left button.
    private enum Drag: Equatable { case tapDrag(Int?), holdToDrag(Int), thumb(Int), threeFinger }

    private struct Wait { let at: Vec; let until: TimeInterval }

    private static let tapSlop = 1.5
    private static let tapMax = 0.30
    private static let dragWindow = 0.30
    private static let tapNear = 6.0
    private static let clickZoneHeight = 20.0
    private static let thumbBelow = 12.0
    private static let reclassifyTravel = 2.0
    private static let thumbTapMax = 0.25
    private static let thumbTapSlop = 1.5
    private static let thumbHoldDelay = 0.30
    private static let thumbDriveTravel = 2.0
    private static let holdToDragDelay = 0.38
    private static let scrollStart = 1.0
    private static let pinchRatio = 1.5
    private static let twoFingerTapMax = 0.3
    private static let twoFingerTapSlop = 1.5
    private static let swipeDistance = 18.0
    private static let flickDistance = 8.0
    private static let flickSpeed = 150.0
    private static let swipeDominance = 1.5
    private static let threeTapMax = 0.3
    private static let threeTapSlop = 2.0
    private static let threeDragStart = 1.5
    private static let threeDragRelease = 0.25
    /// Each finger's travel along the centroid direction before a three-finger drag engages.
    private static let threeDragFingerTravel = 0.5
    private static let edgeMargin = 0.5
    private static let clickTravel = 1.5
    private static let maxClickState = 3
    private static let dtRange = 0.001...0.5
    /// Faster than any finger; caps glitched samples.
    private static let maxSpeed = 5000.0

    private let geometry: TrackpadGeometry
    private let settings: TrackpadSettings
    private let protectionScale: Double
    private var contacts: [Int: Contact] = [:]
    private var mode: Mode = .idle
    private var drag: Drag?
    private var releaseAt: TimeInterval?
    private var tapWait: Wait?
    private var thumbWait: Wait?
    private var sessionStart: TimeInterval = 0
    private var maxFingers = 0
    /// Last `.contacts` value: every counted finger, inert ones included.
    private var reportedFingers = 0
    /// Active (non-inert) fingers the mode was last updated for.
    private var activeFingers = 0
    private var lastTyping = -Double.infinity
    private var lastClickAt: TimeInterval?
    private var lastClickState = 0
    private var travelSinceClick = 0.0
    private var lastTime: TimeInterval = 0

    public init(geometry: TrackpadGeometry, settings: TrackpadSettings = .init(), protectionScale: Double = 1.0) {
        self.geometry = geometry
        self.settings = Self.sanitized(settings)
        self.protectionScale = protectionScale.isFinite && protectionScale > 0 ? protectionScale : 1
    }

    /// Non-finite values fall back to the defaults and negative ones to 0, so no
    /// setting can hold a button forever or produce a NaN deadline.
    private static func sanitized(_ s: TrackpadSettings) -> TrackpadSettings {
        let d = TrackpadSettings()
        func clean(_ value: Double, _ fallback: Double) -> Double { value.isFinite ? max(0, value) : fallback }
        var out = s
        out.dragReleaseDelay = clean(s.dragReleaseDelay, 0)
        out.doubleClickInterval = clean(s.doubleClickInterval, d.doubleClickInterval)
        out.tapQuiet = clean(s.tapQuiet, d.tapQuiet)
        out.typingBandWindow = clean(s.typingBandWindow, d.typingBandWindow)
        out.topBandMM = clean(s.topBandMM, d.topBandMM)
        out.sideBandMM = clean(s.sideBandMM, d.sideBandMM)
        out.palmHeelCornerMM = clean(s.palmHeelCornerMM, d.palmHeelCornerMM)
        return out
    }

    public var heldButtons: Set<PointerButton> { drag == nil ? [] : [.left] }

    public var isActive: Bool { !contacts.isEmpty || drag != nil }

    public var nextDeadline: TimeInterval? {
        var best = releaseAt
        func consider(_ t: TimeInterval?) {
            guard let t else { return }
            best = best.map { min($0, t) } ?? t
        }
        consider(tapWait?.until)
        consider(thumbWait?.until)
        for contact in contacts.values { consider(pressDeadline(contact)) }
        return best
    }

    // MARK: - Public events

    public mutating func began(id: Int, at point: CGPoint, size: ContactSize, time: TimeInterval) -> [TrackpadOutput] {
        let now = clock(time)
        var out: [TrackpadOutput] = []
        // Due presses wait for the next call: a touch-down never presses a button.
        processDeadlines(now, allowPress: false, &out)
        if contacts[id] != nil { lift(id, now, allowTap: false, palm: false, edge: false, &out) }
        let mm = geometry.toMM(point)
        let p = Vec(x: mm.x, y: mm.y)
        if geometry.containsMM(x: p.x, y: p.y, expandedBy: Self.edgeMargin) {
            addContact(id: id, at: p, size: size, now: now)
        } else {
            var ghost = Contact(role: .ignored, size: size, at: p, time: now, inClickZone: false)
            ghost.exited = p.x.isFinite && p.y.isFinite
            contacts[id] = ghost
        }
        updateFingerCount(now, &out)
        return out
    }

    public mutating func moved(id: Int, to point: CGPoint, time: TimeInterval) -> [TrackpadOutput] {
        let now = clock(time)
        var out: [TrackpadOutput] = []
        processDeadlines(now, allowPress: true, &out)
        guard var c = contacts[id] else { return out }
        let mm = geometry.toMM(point)
        let p = Vec(x: mm.x, y: mm.y)
        guard p.x.isFinite, p.y.isFinite else { return out }
        if c.exited {
            if geometry.containsMM(x: p.x, y: p.y, expandedBy: 0) {
                contacts[id] = nil
                addContact(id: id, at: p, size: c.size, now: now)
                updateFingerCount(now, &out)
            }
            return out
        }
        guard c.role != .ignored else { return out }
        if !geometry.containsMM(x: p.x, y: p.y, expandedBy: Self.edgeMargin) {
            lift(id, now, allowTap: false, palm: false, edge: true, &out)
            var ghost = c
            ghost.role = .ignored
            ghost.exited = true
            contacts[id] = ghost
            return out
        }
        let delta = p - c.last
        let dt = now - c.lastTime
        c.last = p
        c.lastTime = now
        c.maxTravel = max(c.maxTravel, p.distance(to: c.start))
        c.velocity.add(x: p.x, y: p.y, at: now)
        contacts[id] = c
        switch c.role {
        case .finger: if c.inert == nil { fingerMoved(id, delta, dt, now, &out) }
        case .thumb: thumbMoved(id, delta, dt, now, &out)
        case .ignored: break
        }
        return out
    }

    public mutating func ended(id: Int, time: TimeInterval, cancelled: Bool) -> [TrackpadOutput] {
        let now = clock(time)
        var out: [TrackpadOutput] = []
        processDeadlines(now, allowPress: true, &out)
        guard contacts[id] != nil else { return out }
        lift(id, now, allowTap: !cancelled, palm: false, edge: false, &out)
        return out
    }

    /// The caller decided this contact is a palm: it ends any scroll, releases a
    /// button it holds and is ignored until it lifts.
    public mutating func rejected(id: Int, time: TimeInterval) -> [TrackpadOutput] {
        let now = clock(time)
        var out: [TrackpadOutput] = []
        processDeadlines(now, allowPress: true, &out)
        guard let c = contacts[id], c.role != .ignored else { return out }
        if c.role == .thumb, case .scroll = mode {
            out.append(Self.scrollEnd(vx: 0, vy: 0))
            makeInert(.lingering)
        }
        lift(id, now, allowTap: false, palm: true, edge: false, &out)
        var ghost = c
        ghost.role = .ignored
        contacts[id] = ghost
        return out
    }

    /// An ordinary key went down: end scrolls and drags, and keep the fingers
    /// down now inert until they lift. Fingers that land later work normally.
    public mutating func noteTyping(at time: TimeInterval) -> [TrackpadOutput] {
        let now = clock(time)
        var out: [TrackpadOutput] = []
        lastTyping = max(lastTyping, now)
        processDeadlines(now, allowPress: false, &out)
        if case .scroll = mode { out.append(Self.scrollEnd(vx: 0, vy: 0)) }
        release(&out)
        for id in contacts.keys { clearCandidacy(id) }
        tapWait = nil
        thumbWait = nil
        makeInert(.typing)
        updateFingerCount(now, &out)
        return out
    }

    public mutating func advance(to time: TimeInterval) -> [TrackpadOutput] {
        let now = clock(time)
        var out: [TrackpadOutput] = []
        processDeadlines(now, allowPress: true, &out)
        return out
    }

    /// Forgets every contact; returns an end for an open scroll and ups for held buttons.
    public mutating func reset() -> [TrackpadOutput] {
        var out: [TrackpadOutput] = []
        if case .scroll = mode { out.append(Self.scrollEnd(vx: 0, vy: 0)) }
        release(&out)
        contacts.removeAll()
        mode = .idle
        tapWait = nil
        thumbWait = nil
        maxFingers = 0
        reportedFingers = 0
        activeFingers = 0
        lastClickAt = nil
        travelSinceClick = 0
        return out
    }

    // MARK: - Contacts

    /// Active (non-inert) counted fingers: they drive pointer, scroll and gestures.
    private var fingerCount: Int { contacts.values.reduce(0) { $0 + ($1.role == .finger && $1.inert == nil ? 1 : 0) } }

    private var fingerIDs: [Int] {
        contacts.filter { $0.value.role == .finger && $0.value.inert == nil }.map(\.key).sorted()
    }

    /// Every counted finger, inert ones included; this is what `.contacts` reports.
    private var touchingFingerCount: Int { contacts.values.reduce(0) { $0 + ($1.role == .finger ? 1 : 0) } }

    private var tapDragEnabled: Bool { settings.dragStyle == .tapDrag || settings.dragStyle == .tapDragLock }

    /// Makes every counted finger inert; typing overrides lingering.
    private mutating func makeInert(_ kind: Inert) {
        for (id, c) in contacts where c.role == .finger && (kind == .typing || c.inert == nil) {
            contacts[id]?.inert = kind
        }
    }

    private mutating func addContact(id: Int, at p: Vec, size: ContactSize, now: TimeInterval) {
        let width = geometry.physicalWidthMM
        let zone = p.y >= geometry.physicalHeightMM - Self.clickZoneHeight
        var c = Contact(role: .finger, size: size, at: p, time: now, inClickZone: zone)
        let corner = settings.palmHeelCornerMM
        let side = settings.sideBandMM * protectionScale
        let typingRecent = now - lastTyping < settings.typingBandWindow
        // Fingers that can still take part in this touch: active ones and lingering
        // ones (which a new finger brings back); typing-inert fingers stay out.
        let fingerIDList = contacts.filter { $0.value.role == .finger && $0.value.inert != .typing }
            .map(\.key).sorted()
        let fingers = fingerIDList.compactMap { contacts[$0] }
        let touching = contacts.values.filter { $0.role == .finger }

        if size == .broad && zone && (p.x < corner || p.x > width - corner) {
            c.role = .ignored  // palm heel
        } else if typingRecent && (p.y < settings.topBandMM * protectionScale ||
                                   (size == .broad && (p.x < side || p.x > width - side))) {
            c.role = .ignored
        } else {
            let belowFinger = settings.restingThumb && touching.contains { p.y - $0.last.y >= Self.thumbBelow }
            let thumbLike = zone && (size == .broad || belowFinger)
            func near(_ wait: Wait?) -> Bool {
                wait.map { now < $0.until && p.distance(to: $0.at) <= Self.tapNear } == true
            }
            // Only a thumb-like contact can be a thumb tap-hold candidate; a lone
            // fingertip after a tap is a finger (a tap-drag candidate in the
            // tap-drag styles), so tap-then-point and tap-then-scroll keep working.
            let nearThumbTap = thumbLike && settings.thumbClick && drag == nil && near(thumbWait)
            let nearTap = !thumbLike && fingers.isEmpty && drag == nil && tapDragEnabled &&
                (near(tapWait) || near(thumbWait))

            if nearThumbTap {
                c.role = .thumb
                c.thumbHoldCandidate = true
            } else if thumbLike {
                c.role = .thumb
            } else {
                if fingers.isEmpty, drag == .tapDrag(nil) {
                    if releaseAt != nil {
                        releaseAt = nil  // re-landed within dragReleaseDelay: the drag continues
                    } else {
                        c.lockOwner = true
                    }
                    drag = .tapDrag(id)
                } else if nearTap {
                    c.tapDragCandidate = true
                }
                if settings.restingThumb, fingerIDList.count == 1, let fid = fingerIDList.first,
                   let f = contacts[fid], f.inClickZone, f.maxTravel < Self.reclassifyTravel,
                   f.last.y - p.y >= Self.thumbBelow {
                    reclassifyAsThumb(fid, now: now)
                }
            }
            if c.tapDragCandidate || c.thumbHoldCandidate {
                tapWait = nil
                thumbWait = nil
            } else if c.role == .finger {
                tapWait = nil
            }
            if c.role == .finger { reviveLingering(now) }
        }
        contacts[id] = c
    }

    /// A new finger joins the fingers left behind by an ended scroll or gesture,
    /// so lifting and re-landing one finger resumes a two-finger scroll.
    private mutating func reviveLingering(_ now: TimeInterval) {
        for (id, f) in contacts where f.role == .finger && f.inert == .lingering {
            var r = f
            r.inert = nil
            r.start = r.last
            r.maxTravel = 0
            r.velocity.reset()
            r.velocity.add(x: r.last.x, y: r.last.y, at: now)
            contacts[id] = r
        }
    }

    /// A lone click-zone finger turns out to be a resting thumb because a finger
    /// landed well above it.
    private mutating func reclassifyAsThumb(_ id: Int, now: TimeInterval) {
        guard var f = contacts[id] else { return }
        f.role = .thumb
        f.inert = nil
        if f.tapDragCandidate {
            f.tapDragCandidate = false
            f.thumbHoldCandidate = true
        }
        if f.lockOwner || (drag == .tapDrag(id) && settings.dragStyle == .tapDragLock) {
            // A drag lock outlives its finger: the next tap releases it.
            f.lockOwner = false
            drag = .tapDrag(nil)
        } else if drag == .tapDrag(id) || drag == .holdToDrag(id) {
            drag = .thumb(id)
        }
        f.buffered = .zero
        contacts[id] = f
    }

    private mutating func clearCandidacy(_ id: Int) {
        guard var c = contacts[id] else { return }
        c.tapDragCandidate = false
        c.thumbHoldCandidate = false
        c.lockOwner = false
        c.buffered = .zero
        contacts[id] = c
    }

    /// Reports the touching-finger count and moves the mode with the active count.
    private mutating func updateFingerCount(_ now: TimeInterval, _ out: inout [TrackpadOutput]) {
        let touching = touchingFingerCount
        let active = fingerCount
        guard touching != reportedFingers || active != activeFingers else { return }
        if touching != reportedFingers {
            reportedFingers = touching
            out.append(.contacts(touching))
        }
        for id in contacts.keys {
            guard var c = contacts[id] else { continue }
            c.velocity.reset()
            c.velocity.add(x: c.last.x, y: c.last.y, at: c.lastTime)
            contacts[id] = c
        }
        let old = activeFingers
        activeFingers = active
        if old != active { fingerCountChanged(from: old, to: active, now, &out) }
    }

    private mutating func fingerCountChanged(from old: Int, to new: Int, _ now: TimeInterval,
                                             _ out: inout [TrackpadOutput]) {
        if new == 0 {
            if drag == .threeFinger { releaseAt = now + Self.threeDragRelease }
            mode = .idle
            return
        }
        if old == 0 {
            sessionStart = now
            maxFingers = new
            if drag == .threeFinger, releaseAt != nil {
                // Fingers re-landed before the three-finger drag released.
                releaseAt = nil
                mode = .multi(MultiState(start: now, lastEmit: now, fingers: new, dragging: true, allowDrag: false))
            } else {
                mode = .pointer
                if new >= 2 { enterGesture(fingers: new, now, &out) }
            }
            return
        }
        maxFingers = max(maxFingers, new)
        guard new > old else { return }
        switch mode {
        case .pointer:
            leavePointer(&out)
            enterGesture(fingers: new, now, &out)
        case .scroll:
            if new >= 3 {
                out.append(Self.scrollEnd(vx: 0, vy: 0))
                enterGesture(fingers: new, now, &out)
            }
        case .multi(var m):
            m.fingers = max(m.fingers, new)
            if !m.dragging { m.allowDrag = false }
            mode = .multi(m)
        case .idle:
            break
        }
    }

    private mutating func enterGesture(fingers: Int, _ now: TimeInterval, _ out: inout [TrackpadOutput]) {
        // A pending thumb tap-hold belongs to one-finger pointing; it must not
        // press the button in the middle of a scroll or gesture.
        for (id, c) in contacts where c.thumbHoldCandidate { clearCandidacy(id) }
        if fingers == 2 {
            let ids = fingerIDs
            let span = ids.count == 2 ? (contacts[ids[0]]?.last ?? .zero).distance(to: contacts[ids[1]]?.last ?? .zero) : 0
            var s = ScrollState(span0: span, start: now, lastEmit: now)
            s.velocity.add(x: 0, y: 0, at: now)
            mode = .scroll(s)
            out.append(.scroll(phase: .mayBegin, dxMM: 0, dyMM: 0, dt: 0, speed: 0, releaseVX: nil, releaseVY: nil))
        } else {
            var m = MultiState(start: now, lastEmit: now, fingers: fingers,
                               allowDrag: settings.dragStyle == .threeFinger && fingers == 3 && drag == nil)
            for id in fingerIDs { m.anchors[id] = contacts[id]?.last }
            m.velocity.add(x: 0, y: 0, at: now)
            mode = .multi(m)
        }
    }

    /// A second finger ends one-finger intent: finger-held drags end (a drag lock stays).
    private mutating func leavePointer(_ out: inout [TrackpadOutput]) {
        for id in fingerIDs { clearCandidacy(id) }
        switch drag {
        case .tapDrag(let id?) where contacts[id]?.role == .finger:
            if settings.dragStyle == .tapDragLock { drag = .tapDrag(nil) } else { release(&out) }
        case .holdToDrag:
            release(&out)
        default:
            break
        }
    }

    // MARK: - Lifts

    private mutating func lift(_ id: Int, _ now: TimeInterval, allowTap: Bool, palm: Bool, edge: Bool,
                               _ out: inout [TrackpadOutput]) {
        guard let c = contacts[id] else { return }
        var gesture: [TrackpadOutput] = []
        switch c.role {
        case .finger:
            if c.inert == nil { fingerLifted(id, c, now, allowTap: allowTap, palm: palm, edge: edge, &gesture) }
        case .thumb: thumbLifted(id, c, now, allowTap: allowTap, &gesture)
        case .ignored: break
        }
        contacts[id] = nil
        // The count goes first so a Mac never stops momentum the lift just started.
        updateFingerCount(now, &out)
        out += gesture
    }

    private mutating func fingerLifted(_ id: Int, _ c: Contact, _ now: TimeInterval, allowTap: Bool, palm: Bool,
                                       edge: Bool, _ out: inout [TrackpadOutput]) {
        let duration = now - c.beganAt
        let still = c.maxTravel <= Self.tapSlop
        switch mode {
        case .pointer:
            if drag == .tapDrag(id) {
                if palm || (c.lockOwner && allowTap && duration <= Self.tapMax && still) {
                    release(&out)
                } else if settings.dragStyle == .tapDragLock {
                    drag = .tapDrag(nil)
                } else if edge || settings.dragReleaseDelay <= 0 {
                    release(&out)
                } else {
                    drag = .tapDrag(nil)
                    releaseAt = now + settings.dragReleaseDelay
                }
            } else if drag == .holdToDrag(id) {
                release(&out)
            } else if drag == .tapDrag(nil), releaseAt == nil {
                // Drag lock held while this finger was not its owner: a tap still ends it.
                if allowTap, duration <= Self.tapMax, still { release(&out) }
            } else if drag == nil, allowTap, maxFingers == 1, duration <= Self.tapMax, still, quiet(since: c.beganAt) {
                click(now, touchDown: c.beganAt, &out)
                if tapDragEnabled { tapWait = Wait(at: c.last, until: now + Self.dragWindow) }
                if settings.thumbClick, c.inClickZone, duration < Self.thumbTapMax, c.maxTravel < Self.thumbTapSlop {
                    thumbWait = Wait(at: c.last, until: now + Self.thumbHoldDelay)
                }
            }
        case .scroll(let s):
            let fingersStill = fingerIDs.allSatisfy { (contacts[$0]?.maxTravel ?? 0) < Self.twoFingerTapSlop }
            if !s.began, allowTap, maxFingers == 2, now - sessionStart < Self.twoFingerTapMax, fingersStill,
               quiet(since: sessionStart) {
                out.append(.scroll(phase: .cancelled, dxMM: 0, dyMM: 0, dt: 0, speed: 0, releaseVX: nil, releaseVY: nil))
                out.append(.button(.right, down: true, clickState: 1))
                out.append(.button(.right, down: false, clickState: 1))
                lastClickAt = nil
            } else {
                let v = s.began && !palm ? s.velocity.releaseVelocity(at: now) : (vx: 0, vy: 0)
                out.append(Self.scrollEnd(vx: v.vx, vy: v.vy))
            }
            makeInert(.lingering)
        case .multi(let m):
            guard !m.dragging else { break }
            if !m.swiped, !palm, swipeAllowed(m), let direction = Self.direction(of: m.sum, minimum: Self.flickDistance) {
                let v = m.velocity.releaseVelocity(at: now)
                if hypot(v.vx, v.vy) >= Self.flickSpeed {
                    out.append(.swipe(fingers: min(m.fingers, 5), direction: direction))
                    makeInert(.lingering)
                    return
                }
            }
            let fingersStill = fingerIDs.allSatisfy { (contacts[$0]?.maxTravel ?? 0) < Self.threeTapSlop }
            if !m.swiped, allowTap, m.fingers == 3, settings.threeFingerGestures, settings.lookUpTap,
               now - sessionStart < Self.threeTapMax, fingersStill, quiet(since: sessionStart) {
                out.append(.tap(fingers: 3))
            }
            makeInert(.lingering)
        case .idle:
            break
        }
    }

    private mutating func thumbLifted(_ id: Int, _ c: Contact, _ now: TimeInterval, allowTap: Bool,
                                      _ out: inout [TrackpadOutput]) {
        if drag == .thumb(id) {
            release(&out)
            return
        }
        guard allowTap, settings.thumbClick, now - c.beganAt < Self.thumbTapMax, c.maxTravel < Self.thumbTapSlop,
              quiet(since: c.beganAt) else { return }
        if drag == .tapDrag(nil), releaseAt == nil {
            release(&out)  // a tap ends a drag lock
            return
        }
        guard drag == nil else { return }
        click(now, touchDown: c.beganAt, &out)
        thumbWait = Wait(at: c.last, until: now + Self.thumbHoldDelay)
    }

    // MARK: - Motion

    private mutating func fingerMoved(_ id: Int, _ delta: Vec, _ dt: Double, _ now: TimeInterval,
                                      _ out: inout [TrackpadOutput]) {
        switch mode {
        case .pointer:
            if drag == nil, delta != .zero,
               let thumb = contacts.keys.sorted().first(where: { contacts[$0]?.thumbHoldCandidate == true }) {
                engage(thumb, now, &out)
            }
            guard var c = contacts[id] else { return }
            if c.tapDragCandidate {
                c.buffered = c.buffered + delta
                if drag != nil {
                    // Someone else holds the button: this touch is plain pointing.
                    let pending = c.buffered
                    c.tapDragCandidate = false
                    c.buffered = .zero
                    contacts[id] = c
                    emitMotion(pending, dt: now - c.beganAt, speed: c.velocity.speed(), &out)
                    return
                }
                contacts[id] = c
                if c.maxTravel > Self.tapSlop { engage(id, now, &out) }
                return
            }
            emitMotion(delta, dt: dt, speed: c.velocity.speed(), &out)
        case .scroll(var s):
            let d = delta / 2
            s.sum = s.sum + d
            s.velocity.add(x: s.sum.x, y: s.sum.y, at: now)
            if !s.began {
                let travel = s.sum.length
                let ids = fingerIDs
                let span = ids.count == 2 ? (contacts[ids[0]]?.last ?? .zero).distance(to: contacts[ids[1]]?.last ?? .zero) : s.span0
                if travel >= Self.scrollStart && abs(span - s.span0) < Self.pinchRatio * travel {
                    s.began = true
                    out.append(.scroll(phase: .began, dxMM: s.sum.x, dyMM: s.sum.y, dt: Self.clampDT(now - s.start),
                                       speed: Self.cap(s.velocity.speed()), releaseVX: nil, releaseVY: nil))
                    s.lastEmit = now
                }
            } else if d != .zero {
                out.append(.scroll(phase: .changed, dxMM: d.x, dyMM: d.y, dt: Self.clampDT(now - s.lastEmit),
                                   speed: Self.cap(s.velocity.speed()), releaseVX: nil, releaseVY: nil))
                s.lastEmit = now
            }
            mode = .scroll(s)
        case .multi(var m):
            let d = delta / Double(max(1, fingerCount))
            m.sum = m.sum + d
            m.velocity.add(x: m.sum.x, y: m.sum.y, at: now)
            if m.dragging {
                if d != .zero {
                    emitMotion(d, dt: now - m.lastEmit, speed: m.velocity.speed(), &out)
                    m.lastEmit = now
                }
            } else if m.allowDrag, fingerCount == 3, drag == nil, m.sum.length >= Self.threeDragStart,
                      movingTogether(m) {
                out.append(.button(.left, down: true, clickState: 1))
                drag = .threeFinger
                m.dragging = true
                forgetClicks()
                emitMotion(m.sum, dt: now - m.start, speed: m.velocity.speed(), &out)
                m.lastEmit = now
            } else if !m.swiped, swipeAllowed(m),
                      let direction = Self.direction(of: m.sum, minimum: Self.swipeDistance) {
                out.append(.swipe(fingers: min(m.fingers, 5), direction: direction))
                m.swiped = true
            }
            mode = .multi(m)
        case .idle:
            break
        }
    }

    /// Every finger has moved at least `threeDragFingerTravel` along the centroid's direction.
    private func movingTogether(_ m: MultiState) -> Bool {
        let length = m.sum.length
        guard length > 0 else { return false }
        let unit = m.sum / length
        return fingerIDs.allSatisfy { id in
            guard let c = contacts[id], let anchor = m.anchors[id] else { return false }
            let d = c.last - anchor
            return d.x * unit.x + d.y * unit.y >= Self.threeDragFingerTravel
        }
    }

    private mutating func thumbMoved(_ id: Int, _ delta: Vec, _ dt: Double, _ now: TimeInterval,
                                     _ out: inout [TrackpadOutput]) {
        // A tap-hold candidate presses only after 0.30 s or when a finger moves;
        // its own motion is not a trigger.
        guard drag == .thumb(id), var c = contacts[id] else { return }
        if fingerCount > 0 {
            c.soleAnchor = nil
            c.drives = false
            contacts[id] = c
            return
        }
        if !c.drives {
            let anchor = c.soleAnchor ?? (c.last - delta)
            c.soleAnchor = anchor
            c.drives = c.last.distance(to: anchor) > Self.thumbDriveTravel
        }
        contacts[id] = c
        if c.drives { emitMotion(delta, dt: dt, speed: c.velocity.speed(), &out) }
    }

    private mutating func emitMotion(_ d: Vec, dt: Double, speed: Double, _ out: inout [TrackpadOutput]) {
        guard d != .zero else { return }
        out.append(.motion(dxMM: d.x, dyMM: d.y, dt: Self.clampDT(dt), speed: Self.cap(speed)))
        travelSinceClick += d.length
    }

    private func swipeAllowed(_ m: MultiState) -> Bool {
        settings.threeFingerGestures && m.fingers >= (settings.dragStyle == .threeFinger ? 4 : 3)
    }

    private static func direction(of v: Vec, minimum: Double) -> SwipeDirection? {
        let ax = abs(v.x), ay = abs(v.y)
        guard v.length >= minimum else { return nil }
        if ax >= swipeDominance * ay { return v.x < 0 ? .left : .right }
        if ay >= swipeDominance * ax { return v.y < 0 ? .up : .down }
        return nil
    }

    // MARK: - Buttons and deadlines

    /// When this contact's pending press fires, if it can fire at all.
    private func pressDeadline(_ c: Contact) -> TimeInterval? {
        guard drag == nil, !c.exited else { return nil }
        switch c.role {
        case .finger:
            guard case .pointer = mode, c.inert == nil else { return nil }
            if c.tapDragCandidate { return c.beganAt + Self.tapMax }
            if settings.dragStyle == .holdToDrag, maxFingers == 1, !c.pressSpent, c.maxTravel <= Self.tapSlop {
                return c.beganAt + Self.holdToDragDelay
            }
            return nil
        case .thumb:
            guard c.thumbHoldCandidate else { return nil }
            switch mode {
            case .idle, .pointer: return c.beganAt + Self.thumbHoldDelay
            case .scroll, .multi: return nil
            }
        case .ignored:
            return nil
        }
    }

    private mutating func processDeadlines(_ now: TimeInterval, allowPress: Bool, _ out: inout [TrackpadOutput]) {
        if let r = releaseAt, now >= r { release(&out) }
        if let w = tapWait, now >= w.until { tapWait = nil }
        if let w = thumbWait, now >= w.until { thumbWait = nil }
        guard allowPress else { return }
        for id in contacts.keys.sorted() {
            guard let c = contacts[id], let deadline = pressDeadline(c), now >= deadline else { continue }
            engage(id, now, &out)
        }
    }

    /// Presses the left button for a tap-drag, thumb tap-hold or hold-to-drag contact.
    private mutating func engage(_ id: Int, _ now: TimeInterval, _ out: inout [TrackpadOutput]) {
        guard drag == nil, var c = contacts[id], c.role != .ignored else { return }
        out.append(.button(.left, down: true, clickState: 1))
        forgetClicks()
        c.pressSpent = true
        let pending = c.buffered
        c.buffered = .zero
        if c.role == .thumb {
            drag = .thumb(id)
            c.thumbHoldCandidate = false
            c.drives = false
            contacts[id] = c
        } else if c.tapDragCandidate {
            drag = .tapDrag(id)
            c.tapDragCandidate = false
            contacts[id] = c
            emitMotion(pending, dt: now - c.beganAt, speed: c.velocity.speed(), &out)
        } else {
            drag = .holdToDrag(id)
            contacts[id] = c
        }
    }

    private mutating func release(_ out: inout [TrackpadOutput]) {
        releaseAt = nil
        guard drag != nil else { return }
        drag = nil
        for id in contacts.keys { contacts[id]?.lockOwner = false }
        out.append(.button(.left, down: false, clickState: 1))
    }

    /// Counts from the previous click to this touch-down, so a second touch that
    /// lands inside the drag window and lifts quickly is always a double click.
    private mutating func click(_ now: TimeInterval, touchDown: TimeInterval, _ out: inout [TrackpadOutput]) {
        var n = 1
        if let last = lastClickAt, touchDown - last <= settings.doubleClickInterval,
           travelSinceClick <= Self.clickTravel {
            n = min(lastClickState + 1, Self.maxClickState)
        }
        out.append(.button(.left, down: true, clickState: n))
        out.append(.button(.left, down: false, clickState: n))
        lastClickAt = now
        lastClickState = n
        travelSinceClick = 0
    }

    private mutating func forgetClicks() {
        lastClickAt = nil
        tapWait = nil
        thumbWait = nil
    }

    private func quiet(since t: TimeInterval) -> Bool {
        t - lastTyping >= settings.tapQuiet * protectionScale
    }

    private mutating func clock(_ time: TimeInterval) -> TimeInterval {
        if time.isFinite { lastTime = max(lastTime, time) }
        return lastTime
    }

    private static func clampDT(_ dt: Double) -> Double {
        min(max(dt.isFinite ? dt : dtRange.lowerBound, dtRange.lowerBound), dtRange.upperBound)
    }

    private static func cap(_ speed: Double) -> Double {
        min(max(speed, -maxSpeed), maxSpeed)
    }

    private static func scrollEnd(vx: Double, vy: Double) -> TrackpadOutput {
        .scroll(phase: .ended, dxMM: 0, dyMM: 0, dt: 0, speed: 0, releaseVX: cap(vx), releaseVY: cap(vy))
    }
}
