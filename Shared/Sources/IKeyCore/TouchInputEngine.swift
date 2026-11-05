import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct TouchSample: Equatable, Sendable {
    public var id: Int
    public var point: CGPoint
    public var radius: Double
    public var radiusTolerance: Double

    public init(id: Int, point: CGPoint, radius: Double, radiusTolerance: Double = 0) {
        self.id = id
        self.point = point
        self.radius = radius
        self.radiusTolerance = radiusTolerance
    }

    var isValid: Bool {
        point.x.isFinite && point.y.isFinite && radius.isFinite && radius >= 0 &&
        radiusTolerance.isFinite && radiusTolerance >= 0
    }

    // UIKit reports a tolerance rather than a precise outline. Use the lower
    // estimate so a valid finger near a size boundary is not rejected eagerly.
    var minimumRadius: Double { max(0, radius - radiusTolerance) }
}

public enum TouchDisposition: Sendable { case pending, accepted, rejected }

public struct TouchContactIndicator: Sendable {
    public var point: CGPoint
    public var radius: Double
    public var disposition: TouchDisposition
}

/// Deterministic input state machine; callers provide monotonic times and samples.
/// Contacts rejected as palms stay rejected until lift. Palm filtering is a
/// heuristic: an ordinary-sized resting fingertip can still look like a keypress.
public struct TouchInputEngine {
    private enum Region { case key(UInt16), trackpad, outside }
    private struct Contact {
        var sample: TouchSample
        let region: Region
        let start: CGPoint
        let beganAt: TimeInterval
        var maximumDistance = 0.0
        var disposition: TouchDisposition
        var keyIsDown = false
        var broadSpace = false
    }
    private struct PadGesture {
        let beganAt: TimeInterval
        var maximumTouches: Int
        var moved = false
        var dragging = false
        var allowClick = true
        var lastCentroid: CGPoint?
    }

    private let layout: DeckLayout
    private let photoFrame: CGRect
    private let protection: TouchProtectionSettings
    private var contacts: [Int: Contact] = [:]
    private var keyCounts: [UInt16: Int] = [:]
    private var repeats: [UInt16: TimeInterval] = [:]
    private var pad: PadGesture?
    private var typingUntil: TimeInterval = -.infinity
    private var lastTime: TimeInterval = 0
    private static let modifiers: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    private let confirmationDelay: TimeInterval = 0.045
    private let typingPause: TimeInterval = 0.35
    private let thumbTapDuration: TimeInterval = 0.35
    private let thumbTapMovement = 18.0

    public init(layout: DeckLayout = .macBookANSI, photoFrame: CGRect,
                protection: TouchProtectionSettings = .init()) {
        self.layout = layout
        self.photoFrame = photoFrame
        self.protection = protection
    }

    public var pressedKeyCodes: Set<UInt16> { Set(keyCounts.filter { $0.value > 0 }.map(\.key)) }
    public var hasActiveContacts: Bool { !contacts.isEmpty }
    public var indicators: [TouchContactIndicator] {
        contacts.keys.sorted().compactMap { id in
            guard let contact = contacts[id], contact.sample.isValid else { return nil }
            return TouchContactIndicator(point: contact.sample.point, radius: contact.sample.radius,
                                         disposition: contact.disposition)
        }
    }

    public mutating func begin(_ samples: [TouchSample], at time: TimeInterval) -> [InputEvent] {
        let now = clock(time)
        var output: [InputEvent] = []
        for sample in samples where contacts[sample.id] == nil {
            let region = region(at: sample.point)
            var contact = Contact(sample: sample, region: region, start: sample.point,
                                  beganAt: now, disposition: .pending)
            if !sample.isValid {
                contact.disposition = .rejected
            } else {
                switch region {
                case .outside: contact.disposition = .rejected
                case .key(let code):
                    if protection.enabled && sample.minimumRadius > protection.sensitivity.fingerRadius {
                        if code == 49 && sample.minimumRadius <= protection.sensitivity.thumbRadius {
                            contact.broadSpace = true
                        } else {
                            contact.disposition = .rejected
                        }
                    }
                case .trackpad:
                    if shouldPausePad(at: now) || isLargeFinger(sample) { contact.disposition = .rejected }
                }
            }
            contacts[sample.id] = contact
        }
        refreshPadMembership(at: now, output: &output)
        activateKeys(at: now, quickEnding: [], excluding: [], output: &output)
        activatePad(at: now)
        updatePadHold(at: now, output: &output)
        return output
    }

    public mutating func move(_ samples: [TouchSample], at time: TimeInterval) -> [InputEvent] {
        let now = clock(time)
        var output: [InputEvent] = []
        update(samples, at: now, output: &output)
        activateKeys(at: now, quickEnding: [], excluding: [], output: &output)
        activatePad(at: now)
        expireBroadSpaces(at: now)
        emitPadMovement(output: &output)
        updatePadHold(at: now, output: &output)
        emitRepeats(at: now, output: &output)
        return output
    }

    public mutating func end(_ samples: [TouchSample], at time: TimeInterval,
                             cancelled: Bool = false) -> [InputEvent] {
        let now = clock(time)
        var output: [InputEvent] = []
        let ending = Set(samples.map(\.id))
        update(samples, at: now, output: &output)
        var quickEnding: Set<Int> = cancelled ? [] : ending
        // If Shift lifts just before a very quick letter, the letter already
        // touched while Shift was down. Commit that pending letter before the
        // modifier-up instead of changing its meaning because of our delay.
        if !cancelled, ending.contains(where: { id in
            guard let c = contacts[id], c.disposition != .rejected,
                  let code = keyCode(for: id) else { return false }
            return Self.modifiers.contains(code)
        }) {
            for id in contacts.keys {
                guard let c = contacts[id], c.disposition == .pending, !c.broadSpace,
                      let code = keyCode(for: id), !Self.modifiers.contains(code) else { continue }
                quickEnding.insert(id)
            }
        }
        activateKeys(at: now, quickEnding: quickEnding,
                     excluding: cancelled ? ending : [], output: &output)

        // A broad thumb is a short Space tap on lift, never a repeating hold.
        if !cancelled {
            for id in ending.sorted() {
                guard let contact = contacts[id], contact.disposition != .rejected,
                      contact.broadSpace, now - contact.beganAt <= thumbTapDuration,
                      contact.maximumDistance <= thumbTapMovement else { continue }
                pressKey(id: id, at: now, output: &output)
            }
        }
        let keyIDs = ending.filter { contacts[$0]?.keyIsDown == true }.sorted { lhs, rhs in
            let l = keyCode(for: lhs).map { Self.modifiers.contains($0) } ?? false
            let r = keyCode(for: rhs).map { Self.modifiers.contains($0) } ?? false
            return l == r ? lhs < rhs : !l
        }
        for id in keyIDs { releaseKey(id: id, at: now, output: &output) }

        let endingPad = ending.contains { id in
            guard let contact = contacts[id], case .trackpad = contact.region else { return false }
            return contact.disposition != .rejected
        }
        if cancelled && endingPad { rejectPad(output: &output) }
        for id in ending { contacts.removeValue(forKey: id) }
        if endingPad, viablePadIDs.isEmpty, let gesture = pad {
            if gesture.dragging {
                output.append(.button(button: .left, down: false))
            } else if !cancelled, gesture.allowClick, !gesture.moved,
                      now - gesture.beganAt < 0.3, (1...2).contains(gesture.maximumTouches) {
                let button: PointerButton = gesture.maximumTouches == 2 ? .right : .left
                output.append(.button(button: button, down: true))
                output.append(.button(button: button, down: false))
            }
            pad = nil
        } else if pad != nil {
            let centroid = acceptedPadCentroid
            pad?.lastCentroid = centroid
        }
        return output
    }

    public mutating func advance(to time: TimeInterval) -> [InputEvent] {
        let now = clock(time)
        var output: [InputEvent] = []
        expireBroadSpaces(at: now)
        activateKeys(at: now, quickEnding: [], excluding: [], output: &output)
        activatePad(at: now)
        updatePadHold(at: now, output: &output)
        emitRepeats(at: now, output: &output)
        return output
    }

    public mutating func reset() -> [InputEvent] {
        contacts.removeAll()
        keyCounts.removeAll()
        repeats.removeAll()
        pad = nil
        typingUntil = -.infinity
        return [.releaseAll]
    }

    private mutating func clock(_ time: TimeInterval) -> TimeInterval {
        if time.isFinite { lastTime = max(lastTime, time) }
        return lastTime
    }

    private func region(at point: CGPoint) -> Region {
        guard photoFrame.width > 0, photoFrame.height > 0, photoFrame.contains(point) else { return .outside }
        let x = Double((point.x - photoFrame.minX) / photoFrame.width)
        let y = Double((point.y - photoFrame.minY) / photoFrame.height)
        if let key = layout.key(atX: x, y: y) { return .key(key.keyCode) }
        return layout.trackpad.contains(x: x, y: y) ? .trackpad : .outside
    }

    private func isLargeFinger(_ sample: TouchSample) -> Bool {
        protection.enabled && sample.minimumRadius > protection.sensitivity.fingerRadius
    }

    private func shouldPausePad(at time: TimeInterval) -> Bool {
        protection.enabled && protection.pauseTrackpadWhileTyping &&
        (time < typingUntil || keyCounts.contains { !Self.modifiers.contains($0.key) && $0.value > 0 })
    }

    private mutating func update(_ samples: [TouchSample], at time: TimeInterval, output: inout [InputEvent]) {
        var rejectPadGesture = false
        for sample in samples {
            guard var contact = contacts[sample.id] else { continue }
            contact.sample = sample
            contact.maximumDistance = max(contact.maximumDistance,
                hypot(Double(sample.point.x - contact.start.x), Double(sample.point.y - contact.start.y)))
            contacts[sample.id] = contact
            guard contact.disposition != .rejected else { continue }
            var reject = !sample.isValid
            switch contact.region {
            case .key(let code):
                if isLargeFinger(sample) {
                    if code == 49 && !contact.keyIsDown && sample.minimumRadius <= protection.sensitivity.thumbRadius {
                        contacts[sample.id]?.broadSpace = true
                    } else if code != 49 || !contact.broadSpace || sample.minimumRadius > protection.sensitivity.thumbRadius {
                        reject = true
                    }
                }
                if contact.broadSpace && contact.maximumDistance > thumbTapMovement { reject = true }
            case .trackpad:
                if isLargeFinger(sample) || shouldPausePad(at: time) { reject = true }
                if contact.maximumDistance > 8 { pad?.moved = true }
            case .outside: reject = true
            }
            if reject {
                if case .trackpad = contact.region { rejectPadGesture = true }
                releaseKey(id: sample.id, at: time, output: &output)
                contacts[sample.id]?.disposition = .rejected
            }
        }
        if rejectPadGesture { rejectPad(output: &output) }
    }

    private mutating func expireBroadSpaces(at time: TimeInterval) {
        for id in contacts.keys {
            guard let contact = contacts[id], contact.broadSpace,
                  time - contact.beganAt > thumbTapDuration else { continue }
            contacts[id]?.disposition = .rejected
        }
    }

    private mutating func activateKeys(at time: TimeInterval, quickEnding: Set<Int>, excluding: Set<Int>,
                                       output: inout [InputEvent]) {
        var ids = contacts.keys.filter { id in
            guard let contact = contacts[id], case .key = contact.region else { return false }
            return contact.disposition == .pending && !contact.broadSpace && !excluding.contains(id) &&
                (!protection.enabled || time - contact.beganAt >= confirmationDelay || quickEnding.contains(id))
        }
        // A very short letter/Space tap may finish before an overlapping Shift
        // contact reaches its confirmation time. Commit pending modifiers first
        // so the letter cannot escape its intended chord.
        let ordinaryKeyWillCommit = ids.contains { id in
            keyCode(for: id).map { !Self.modifiers.contains($0) } ?? false
        } || quickEnding.contains { id in
            guard let c = contacts[id] else { return false }
            return c.disposition != .rejected && c.broadSpace &&
                time - c.beganAt <= thumbTapDuration && c.maximumDistance <= thumbTapMovement
        }
        if ordinaryKeyWillCommit {
            for id in contacts.keys where !ids.contains(id) && !excluding.contains(id) {
                guard let contact = contacts[id], contact.disposition == .pending,
                      let code = keyCode(for: id), Self.modifiers.contains(code) else { continue }
                ids.append(id)
            }
        }
        ids.sort { lhs, rhs in
            let l = keyCode(for: lhs).map { Self.modifiers.contains($0) } ?? false
            let r = keyCode(for: rhs).map { Self.modifiers.contains($0) } ?? false
            return l == r ? lhs < rhs : l
        }
        for id in ids { pressKey(id: id, at: time, output: &output) }
    }

    private func keyCode(for id: Int) -> UInt16? {
        guard let contact = contacts[id], case .key(let code) = contact.region else { return nil }
        return code
    }

    private mutating func pressKey(id: Int, at time: TimeInterval, output: inout [InputEvent]) {
        guard let code = keyCode(for: id), contacts[id]?.keyIsDown == false else { return }
        contacts[id]?.keyIsDown = true
        contacts[id]?.disposition = .accepted
        let count = keyCounts[code, default: 0]
        keyCounts[code] = count + 1
        if count == 0 {
            output.append(.key(code: code, down: true))
            if !Self.modifiers.contains(code), contacts[id]?.broadSpace == false { repeats[code] = time + 0.5 }
        }
        if !Self.modifiers.contains(code) { recordTyping(at: time, output: &output) }
    }

    private mutating func releaseKey(id: Int, at time: TimeInterval, output: inout [InputEvent]) {
        guard let code = keyCode(for: id), contacts[id]?.keyIsDown == true else { return }
        contacts[id]?.keyIsDown = false
        let count = max(0, keyCounts[code, default: 0] - 1)
        keyCounts[code] = count
        if count == 0 {
            output.append(.key(code: code, down: false))
            repeats.removeValue(forKey: code)
        }
        if !Self.modifiers.contains(code) { recordTyping(at: time, output: &output) }
    }

    private mutating func emitRepeats(at time: TimeInterval, output: inout [InputEvent]) {
        for code in repeats.keys.sorted() where keyCounts[code, default: 0] > 0 {
            guard let deadline = repeats[code], time >= deadline else { continue }
            output.append(.key(code: code, down: true))
            repeats[code] = time + 0.06
            recordTyping(at: time, output: &output)
        }
    }

    private mutating func recordTyping(at time: TimeInterval, output: inout [InputEvent]) {
        typingUntil = max(typingUntil, time + typingPause)
        if protection.enabled && protection.pauseTrackpadWhileTyping { rejectPad(output: &output) }
    }

    private var viablePadIDs: [Int] {
        contacts.keys.filter { id in
            guard let contact = contacts[id], case .trackpad = contact.region else { return false }
            return contact.disposition != .rejected
        }.sorted()
    }

    private var acceptedPadCentroid: CGPoint? {
        let values = viablePadIDs.compactMap { id -> CGPoint? in
            guard let c = contacts[id], c.disposition == .accepted else { return nil }
            return c.sample.point
        }
        guard !values.isEmpty else { return nil }
        let divisor = CGFloat(values.count)
        return CGPoint(x: values.reduce(0) { $0 + $1.x } / divisor,
                       y: values.reduce(0) { $0 + $1.y } / divisor)
    }

    private mutating func refreshPadMembership(at time: TimeInterval, output: inout [InputEvent]) {
        let count = viablePadIDs.count
        guard count > 0 else { return }
        if pad == nil { pad = PadGesture(beganAt: time, maximumTouches: count) }
        let maximumTouches = max(pad?.maximumTouches ?? count, count)
        pad?.maximumTouches = maximumTouches
        if count > 1, pad?.dragging == true {
            output.append(.button(button: .left, down: false))
            pad?.dragging = false
            pad?.allowClick = false
        }
        if count > 2 { pad?.allowClick = false }
        let centroid = acceptedPadCentroid
        pad?.lastCentroid = centroid
    }

    private mutating func activatePad(at time: TimeInterval) {
        var changed = false
        for id in viablePadIDs {
            guard let contact = contacts[id], contact.disposition == .pending,
                  !protection.enabled || time - contact.beganAt >= confirmationDelay else { continue }
            contacts[id]?.disposition = .accepted
            changed = true
        }
        if changed {
            let centroid = acceptedPadCentroid
            pad?.lastCentroid = centroid
        }
    }

    private mutating func emitPadMovement(output: inout [InputEvent]) {
        guard let next = acceptedPadCentroid, var gesture = pad else { return }
        let previous = gesture.lastCentroid
        gesture.lastCentroid = next
        pad = gesture
        guard let previous else { return }
        let dx = min(4096, max(-4096, Double(next.x - previous.x)))
        let dy = min(4096, max(-4096, Double(next.y - previous.y)))
        guard dx != 0 || dy != 0 else { return }
        let ids = viablePadIDs
        guard ids.allSatisfy({ contacts[$0]?.disposition == .accepted }) else { return }
        if ids.count == 1 && gesture.maximumTouches == 1 {
            output.append(.pointer(dx: dx, dy: dy))
        } else if ids.count == 2 && gesture.maximumTouches == 2 {
            output.append(.scroll(dx: -dx, dy: -dy))
        }
    }

    private mutating func updatePadHold(at time: TimeInterval, output: inout [InputEvent]) {
        guard var gesture = pad, !gesture.dragging, !gesture.moved,
              gesture.maximumTouches == 1, viablePadIDs.count == 1,
              contacts[viablePadIDs[0]]?.disposition == .accepted,
              time - gesture.beganAt >= 0.38 else { return }
        gesture.dragging = true
        pad = gesture
        output.append(.button(button: .left, down: true))
    }

    private mutating func rejectPad(output: inout [InputEvent]) {
        if pad?.dragging == true { output.append(.button(button: .left, down: false)) }
        for id in viablePadIDs { contacts[id]?.disposition = .rejected }
        pad = nil
    }
}
