import AppKit
import CoreGraphics
import Foundation
import IKeyCore

/// Posts only events received from the authenticated iPad. Never monitors local typing.
final class LegacyEventInjector {
    /// True while any key or mouse button is held down on the Mac.
    var hasHeldInput: Bool { !heldKeys.isEmpty || leftDown || rightDown }

    private let source = CGEventSource(stateID: .privateState)
    private var heldKeys: Set<UInt16> = []
    private var capsLockEnabled = false
    private var leftDown = false
    private var rightDown = false
    private var scrollRemainder = CGPoint.zero
    private var clicks: [String: Click] = [:]

    private struct Click {
        var time: TimeInterval
        var location: CGPoint
        var count: Int64
    }

    private let modifierFlags: [UInt16: CGEventFlags] = [
        54: .maskCommand, 55: .maskCommand,
        56: .maskShift, 60: .maskShift,
        58: .maskAlternate, 61: .maskAlternate,
        59: .maskControl, 62: .maskControl,
        63: .maskSecondaryFn
    ]

    private var flags: CGEventFlags {
        heldKeys.reduce(into: capsLockEnabled ? CGEventFlags.maskAlphaShift : CGEventFlags()) { result, code in
            if let flag = modifierFlags[code] { result.formUnion(flag) }
        }
    }

    func handle(_ event: InputEvent) {
        // Keep the input sink defensive even if called outside the wire decoder.
        guard (try? event.validate()) != nil else { return }
        switch event {
        case .key(let code, let down):
            postKey(code: code, down: down)
        case .pointer(let dx, let dy):
            move(dx: dx, dy: dy)
        case .button(let button, let down):
            postButton(button, down: down)
        case .scroll(let dx, let dy):
            scroll(dx: dx, dy: dy)
        case .releaseAll:
            releaseAll()
        case .heartbeat:
            break
        }
    }

    func releaseAll() {
        // Release regular keys while their modifiers are still held, then modifiers.
        let codes = heldKeys.sorted {
            let lhsModifier = modifierFlags[$0] != nil
            let rhsModifier = modifierFlags[$1] != nil
            return lhsModifier == rhsModifier ? $0 < $1 : !lhsModifier
        }
        for code in codes { postKey(code: code, down: false) }
        if leftDown { postButton(.left, down: false) }
        if rightDown { postButton(.right, down: false) }
        if capsLockEnabled {
            capsLockEnabled = false
            postModifierFlags(code: 57)
        }
        heldKeys.removeAll()
        leftDown = false
        rightDown = false
        scrollRemainder = .zero
        clicks.removeAll()
    }

    private func postKey(code: UInt16, down: Bool) {
        let wasHeld = heldKeys.contains(code)
        guard down || wasHeld else { return }
        let isModifier = modifierFlags[code] != nil || code == 57
        if down && wasHeld && isModifier { return }
        if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
        // Caps Lock is a virtual toggle for this session; never change keyboard LEDs.
        if code == 57 && down { capsLockEnabled.toggle() }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { return }
        event.flags = flags
        if isModifier { event.type = .flagsChanged }
        event.setIntegerValueField(.keyboardEventAutorepeat, value: down && wasHeld ? 1 : 0)
        event.post(tap: .cghidEventTap)
    }

    private func postModifierFlags(code: UInt16) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false)
        event?.type = .flagsChanged
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private var cursor: CGPoint {
        CGEvent(source: nil)?.location ?? CGPoint(x: CGDisplayBounds(CGMainDisplayID()).midX,
                                                y: CGDisplayBounds(CGMainDisplayID()).midY)
    }

    private func move(dx: Double, dy: Double) {
        let origin = cursor
        let position = visiblePoint(CGPoint(x: origin.x + dx, y: origin.y + dy))
        let type: CGEventType = leftDown ? .leftMouseDragged : (rightDown ? .rightMouseDragged : .mouseMoved)
        let button: CGMouseButton = leftDown ? .left : (rightDown ? .right : .left)
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    /// Quartz display coordinates support negative origins and mixed display layouts.
    private func visiblePoint(_ point: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return point }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return point }
        let bounds = displays.prefix(Int(count)).map { CGDisplayBounds($0) }
        if bounds.contains(where: { $0.contains(point) }) { return point }
        return bounds.map { rect -> CGPoint in
            CGPoint(x: min(max(point.x, rect.minX), rect.maxX - 0.01),
                    y: min(max(point.y, rect.minY), rect.maxY - 0.01))
        }.min { lhs, rhs in
            hypot(lhs.x - point.x, lhs.y - point.y) < hypot(rhs.x - point.x, rhs.y - point.y)
        } ?? point
    }

    private func postButton(_ button: PointerButton, down: Bool) {
        let isLeft = button == .left
        let wasDown = isLeft ? leftDown : rightDown
        guard wasDown != down else { return }
        if isLeft { leftDown = down } else { rightDown = down }
        let location = cursor
        let name = isLeft ? "left" : "right"
        if down {
            let now = ProcessInfo.processInfo.systemUptime
            let previous = clicks[name]
            let isRepeated = previous.map {
                now - $0.time <= NSEvent.doubleClickInterval && hypot(location.x - $0.location.x, location.y - $0.location.y) <= 5
            } ?? false
            clicks[name] = Click(time: now, location: location,
                                 count: isRepeated ? min((previous?.count ?? 0) + 1, 3) : 1)
        }
        let type: CGEventType = isLeft ? (down ? .leftMouseDown : .leftMouseUp) : (down ? .rightMouseDown : .rightMouseUp)
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
                            mouseButton: isLeft ? .left : .right)
        event?.flags = flags
        event?.setIntegerValueField(.mouseEventClickState, value: clicks[name]?.count ?? 1)
        event?.post(tap: .cghidEventTap)
    }

    private func scroll(dx: Double, dy: Double) {
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let x = Int32(scrollRemainder.x.rounded(.towardZero))
        let y = Int32(scrollRemainder.y.rounded(.towardZero))
        scrollRemainder.x -= CGFloat(x)
        scrollRemainder.y -= CGFloat(y)
        guard x != 0 || y != 0 else { return }
        let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                            wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}
