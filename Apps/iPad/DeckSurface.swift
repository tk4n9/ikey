import SwiftUI
import UIKit
import IKeyCore

struct DeckSurface: UIViewRepresentable {
    let image: UIImage?
    let layout: DeckLayout
    let inputEnabled: Bool
    let resetGeneration: Int
    let showRegions: Bool
    let selectedKeyID: String?
    let onEvent: (InputEvent) -> Void

    func makeUIView(context: Context) -> DeckTouchView { DeckTouchView() }

    func updateUIView(_ view: DeckTouchView, context: Context) {
        view.configure(image: image, layout: layout, enabled: inputEnabled,
                       generation: resetGeneration, showRegions: showRegions,
                       selectedKeyID: selectedKeyID, onEvent: onEvent)
    }

    static func dismantleUIView(_ uiView: DeckTouchView, coordinator: ()) {
        uiView.resetTouches(notify: true)
    }
}

/// Photo painting and hit testing share one aspect-fit rectangle.
final class DeckTouchView: UIView {
    private var photo: UIImage?
    private var layout = DeckLayout.macBookANSI
    private var inputEnabled = false
    private var generation = -1
    private var showRegions = false
    private var selectedKeyID: String?
    private var onEvent: (InputEvent) -> Void = { _ in }

    private struct Contact {
        let key: KeyRegion?
        let isTrackpad: Bool
        let start: CGPoint
        var point: CGPoint
    }
    private var contacts: [ObjectIdentifier: Contact] = [:]
    private var keyCounts: [UInt16: Int] = [:]
    private var lastCentroid: CGPoint?
    private var trackpadStartedAt: TimeInterval = 0
    private var maximumTrackpadTouches = 0
    private var trackpadMoved = false
    private var dragging = false
    private var holdToDrag: DispatchWorkItem?
    private var repeatTimers: [UInt16: Timer] = [:]
    private var repeatStarts: [UInt16: DispatchWorkItem] = [:]
    private static let modifierCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = true
        backgroundColor = .black
        contentMode = .redraw
        accessibilityLabel = "MacBook keyboard and trackpad touch surface"
        accessibilityHint = "Use the settings button to connect and align your photo."
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func configure(image: UIImage?, layout: DeckLayout, enabled: Bool,
                   generation: Int, showRegions: Bool, selectedKeyID: String?,
                   onEvent: @escaping (InputEvent) -> Void) {
        if self.generation != generation || self.inputEnabled != enabled || self.layout != layout {
            resetTouches(notify: self.inputEnabled)
        }
        self.photo = image
        self.layout = layout
        self.inputEnabled = enabled
        self.generation = generation
        self.showRegions = showRegions
        self.selectedKeyID = selectedKeyID
        self.onEvent = onEvent
        setNeedsDisplay()
    }

    private var photoRect: CGRect {
        PhotoGeometry.aspectFit(imageSize: photo?.size ?? CGSize(width: 1440, height: 900), in: bounds)
    }

    override func draw(_ rect: CGRect) {
        UIColor.black.setFill()
        UIRectFill(bounds)
        let deck = photoRect
        if let photo {
            photo.draw(in: deck)
        } else {
            UIColor(white: 0.64, alpha: 1).setFill()
            UIBezierPath(roundedRect: deck, cornerRadius: deck.width * 0.018).fill()
            for key in layout.keys {
                let frame = layout.frame(for: key).rect(in: deck)
                UIColor(white: 0.09, alpha: 1).setFill()
                UIBezierPath(roundedRect: frame, cornerRadius: max(2, frame.height * 0.12)).fill()
                drawLabel(key.label, in: frame, color: .white, size: max(8, min(18, frame.height * 0.31)))
            }
            let pad = layout.trackpad.rect(in: deck)
            UIColor(white: 0.4, alpha: 1).setStroke()
            let path = UIBezierPath(roundedRect: pad, cornerRadius: 7)
            path.lineWidth = 1.5
            path.stroke()
            drawLabel("Practice layout · import your MacBook photo in Settings", in: CGRect(x: deck.minX, y: deck.minY + 4, width: deck.width, height: 22), color: .black, size: 11)
        }

        if showRegions {
            stroke(layout.keyboard.rect(in: deck), color: .systemTeal, width: 2)
            let pad = layout.trackpad.rect(in: deck)
            UIColor.systemBlue.withAlphaComponent(0.18).setFill()
            UIRectFill(pad)
            stroke(pad, color: .systemBlue, width: 2)
            for key in layout.keys {
                let frame = layout.frame(for: key).rect(in: deck)
                let selected = key.id == selectedKeyID
                stroke(frame, color: selected ? .systemOrange : .systemTeal, width: selected ? 3 : 0.75)
                if selected {
                    UIColor.systemOrange.withAlphaComponent(0.25).setFill()
                    UIRectFill(frame)
                }
                if photo != nil { drawLabel(key.label, in: frame, color: .systemYellow, size: max(7, min(13, frame.height * 0.3))) }
            }
        } else {
            for key in layout.keys where keyCounts[key.keyCode, default: 0] > 0 {
                UIColor.white.withAlphaComponent(0.18).setFill()
                UIBezierPath(roundedRect: layout.frame(for: key).rect(in: deck), cornerRadius: 4).fill()
            }
        }
    }

    private func drawLabel(_ text: String, in rect: CGRect, color: UIColor, size: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let font = UIFont.systemFont(ofSize: size, weight: .medium)
        let textRect = CGRect(x: rect.minX + 2, y: rect.midY - font.lineHeight / 2,
                              width: max(0, rect.width - 4), height: font.lineHeight)
        (text as NSString).draw(in: textRect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    private func stroke(_ rect: CGRect, color: UIColor, width: CGFloat) {
        color.setStroke()
        let path = UIBezierPath(rect: rect)
        path.lineWidth = width
        path.stroke()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard inputEnabled, !showRegions else { return }
        let deck = photoRect
        guard deck.width > 0, deck.height > 0 else { return }
        var pressed: [KeyRegion] = []
        let oldTrackpadCount = trackpadContacts.count
        for touch in touches where touch.type == .direct && touch.majorRadius < 40 {
            let point = touch.location(in: self)
            guard deck.contains(point) else { continue }
            let x = Double((point.x - deck.minX) / deck.width)
            let y = Double((point.y - deck.minY) / deck.height)
            let key = layout.key(atX: x, y: y)
            let isTrackpad = key == nil && layout.trackpad.contains(x: x, y: y)
            guard key != nil || isTrackpad else { continue }
            contacts[ObjectIdentifier(touch)] = Contact(key: key, isTrackpad: isTrackpad, start: point, point: point)
            if let key { pressed.append(key) }
        }
        // A chord beginning in one UIKit batch must press modifiers first.
        for key in pressed.sorted(by: { Self.modifierCodes.contains($0.keyCode) && !Self.modifierCodes.contains($1.keyCode) }) {
            let count = keyCounts[key.keyCode, default: 0]
            keyCounts[key.keyCode] = count + 1
            if count == 0 {
                onEvent(.key(code: key.keyCode, down: true))
                scheduleRepeat(for: key.keyCode)
            }
        }
        let count = trackpadContacts.count
        if count > oldTrackpadCount {
            if oldTrackpadCount == 0 {
                trackpadStartedAt = ProcessInfo.processInfo.systemUptime
                trackpadMoved = false
                maximumTrackpadTouches = count
            }
            maximumTrackpadTouches = max(maximumTrackpadTouches, count)
            lastCentroid = centroid
            holdToDrag?.cancel()
            if count == 1 && maximumTrackpadTouches == 1 {
                scheduleDrag()
            } else if dragging {
                onEvent(.button(button: .left, down: false))
                dragging = false
                trackpadMoved = true
            }
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard inputEnabled else { return }
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard var contact = contacts[id] else { continue }
            contact.point = touch.location(in: self)
            contacts[id] = contact
            if contact.isTrackpad && hypot(contact.point.x - contact.start.x, contact.point.y - contact.start.y) > 8 {
                trackpadMoved = true
                if !dragging { holdToDrag?.cancel() }
            }
        }
        guard let next = centroid else { return }
        defer { lastCentroid = next }
        guard let previous = lastCentroid else { return }
        let dx = Double(next.x - previous.x)
        let dy = Double(next.y - previous.y)
        guard dx != 0 || dy != 0 else { return }
        let count = trackpadContacts.count
        if count == 1 && maximumTrackpadTouches == 1 {
            onEvent(.pointer(dx: dx, dy: dy))
        } else if count == 2 && maximumTrackpadTouches == 2 {
            onEvent(.scroll(dx: -dx, dy: -dy))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: false) }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: true) }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        let previousTrackpadCount = trackpadContacts.count
        let ending = touches.compactMap { touch -> Contact? in
            guard let contact = contacts.removeValue(forKey: ObjectIdentifier(touch)) else { return nil }
            let end = touch.location(in: self)
            if contact.isTrackpad && hypot(end.x - contact.start.x, end.y - contact.start.y) > 8 {
                trackpadMoved = true
            }
            return contact
        }
        // Release ordinary keys before modifiers if the fingers lift together.
        for key in ending.compactMap(\.key).sorted(by: { !Self.modifierCodes.contains($0.keyCode) && Self.modifierCodes.contains($1.keyCode) }) {
            let count = max(0, keyCounts[key.keyCode, default: 0] - 1)
            keyCounts[key.keyCode] = count
            if count == 0 {
                stopRepeat(for: key.keyCode)
                onEvent(.key(code: key.keyCode, down: false))
            }
        }
        if ending.contains(where: \.isTrackpad) {
            holdToDrag?.cancel()
            if cancelled { trackpadMoved = true }
        }
        if previousTrackpadCount > 0 && trackpadContacts.isEmpty {
            if dragging {
                onEvent(.button(button: .left, down: false))
            } else if !cancelled && !trackpadMoved && ProcessInfo.processInfo.systemUptime - trackpadStartedAt < 0.3 && (1...2).contains(maximumTrackpadTouches) {
                let button: PointerButton = maximumTrackpadTouches == 2 ? .right : .left
                onEvent(.button(button: button, down: true))
                onEvent(.button(button: button, down: false))
            }
            dragging = false
            maximumTrackpadTouches = 0
            lastCentroid = nil
        } else {
            lastCentroid = centroid
        }
        setNeedsDisplay()
    }

    private var trackpadContacts: [Contact] { contacts.values.filter(\.isTrackpad) }

    private var centroid: CGPoint? {
        let points = trackpadContacts.map(\.point)
        guard !points.isEmpty else { return nil }
        return CGPoint(x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
                       y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count))
    }

    private func scheduleDrag() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.inputEnabled, self.trackpadContacts.count == 1,
                  self.maximumTrackpadTouches == 1, !self.trackpadMoved else { return }
            self.dragging = true
            self.onEvent(.button(button: .left, down: true))
        }
        holdToDrag = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: work)
    }

    private func scheduleRepeat(for code: UInt16) {
        guard !Self.modifierCodes.contains(code) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.inputEnabled, self.keyCounts[code, default: 0] > 0 else { return }
            self.onEvent(.key(code: code, down: true))
            let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
                guard let self, self.inputEnabled, self.keyCounts[code, default: 0] > 0 else { return }
                self.onEvent(.key(code: code, down: true))
            }
            self.repeatTimers[code] = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        repeatStarts[code] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func stopRepeat(for code: UInt16) {
        repeatStarts.removeValue(forKey: code)?.cancel()
        repeatTimers.removeValue(forKey: code)?.invalidate()
    }

    func resetTouches(notify: Bool) {
        holdToDrag?.cancel()
        holdToDrag = nil
        repeatStarts.values.forEach { $0.cancel() }
        repeatStarts.removeAll()
        repeatTimers.values.forEach { $0.invalidate() }
        repeatTimers.removeAll()
        if notify && (!contacts.isEmpty || dragging) { onEvent(.releaseAll) }
        contacts.removeAll()
        keyCounts.removeAll()
        lastCentroid = nil
        maximumTrackpadTouches = 0
        trackpadMoved = false
        dragging = false
        setNeedsDisplay()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { resetTouches(notify: true) }
        super.willMove(toWindow: newWindow)
    }
}
