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
    let protection: TouchProtectionSettings
    let showTouchIndicators: Bool
    let onEvent: (InputEvent) -> Void

    func makeUIView(context: Context) -> DeckTouchView { DeckTouchView() }

    func updateUIView(_ view: DeckTouchView, context: Context) {
        view.configure(image: image, layout: layout, enabled: inputEnabled,
                       generation: resetGeneration, showRegions: showRegions,
                       selectedKeyID: selectedKeyID, protection: protection,
                       showTouchIndicators: showTouchIndicators, onEvent: onEvent)
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

    private var protection = TouchProtectionSettings()
    private var showTouchIndicators = false
    private var engine = TouchInputEngine(photoFrame: .zero)
    private var enginePhotoRect = CGRect.zero
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 0
    private var tickTimer: Timer?

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

    deinit { tickTimer?.invalidate() }

    func configure(image: UIImage?, layout: DeckLayout, enabled: Bool,
                   generation: Int, showRegions: Bool, selectedKeyID: String?,
                   protection: TouchProtectionSettings, showTouchIndicators: Bool,
                   onEvent: @escaping (InputEvent) -> Void) {
        let needsReset = self.generation != generation || self.inputEnabled != enabled ||
            self.layout != layout || self.protection != protection
        if needsReset { resetTouches(notify: self.inputEnabled) }
        self.photo = image
        self.layout = layout
        self.protection = protection
        self.inputEnabled = enabled
        self.generation = generation
        self.showRegions = showRegions
        self.selectedKeyID = selectedKeyID
        self.showTouchIndicators = showTouchIndicators
        self.onEvent = onEvent
        if needsReset || enginePhotoRect != photoRect {
            resetTouches(notify: inputEnabled)
            rebuildEngine()
        }
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if enginePhotoRect != photoRect {
            resetTouches(notify: inputEnabled)
            rebuildEngine()
        }
    }

    private func rebuildEngine() {
        enginePhotoRect = photoRect
        engine = TouchInputEngine(layout: layout, photoFrame: enginePhotoRect, protection: protection)
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
            for key in layout.keys where engine.pressedKeyCodes.contains(key.keyCode) {
                UIColor.white.withAlphaComponent(0.18).setFill()
                UIBezierPath(roundedRect: layout.frame(for: key).rect(in: deck), cornerRadius: 4).fill()
            }
        }
        if showTouchIndicators && !showRegions { drawContacts() }
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

    private func drawContacts() {
        for contact in engine.indicators {
            let color: UIColor
            switch contact.disposition {
            case .pending: color = .systemYellow
            case .accepted: color = .systemGreen
            case .rejected: color = .systemRed
            }
            let radius = CGFloat(min(120, max(6, contact.radius)))
            let rect = CGRect(x: contact.point.x - radius, y: contact.point.y - radius,
                              width: radius * 2, height: radius * 2)
            color.withAlphaComponent(0.16).setFill()
            let circle = UIBezierPath(ovalIn: rect)
            circle.fill()
            color.setStroke()
            circle.lineWidth = 2
            circle.stroke()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard inputEnabled, !showRegions else { return }
        let samples = touches.filter { $0.type == .direct }.map { touch -> TouchSample in
            let identifier = ObjectIdentifier(touch)
            nextTouchID += 1
            touchIDs[identifier] = nextTouchID
            return sample(touch, id: nextTouchID)
        }
        emit(engine.begin(samples, at: ProcessInfo.processInfo.systemUptime))
        updateTimer()
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard inputEnabled, !showRegions else { return }
        emit(engine.move(samples(for: touches), at: ProcessInfo.processInfo.systemUptime))
        updateTimer()
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        emit(engine.end(samples(for: touches), at: ProcessInfo.processInfo.systemUptime, cancelled: cancelled))
        for touch in touches { touchIDs.removeValue(forKey: ObjectIdentifier(touch)) }
        updateTimer()
        setNeedsDisplay()
    }

    private func sample(_ touch: UITouch, id: Int) -> TouchSample {
        TouchSample(id: id, point: touch.location(in: self), radius: Double(touch.majorRadius),
                    radiusTolerance: Double(touch.majorRadiusTolerance))
    }

    private func samples(for touches: Set<UITouch>) -> [TouchSample] {
        touches.compactMap { touch in
            guard let id = touchIDs[ObjectIdentifier(touch)] else { return nil }
            return sample(touch, id: id)
        }
    }

    private func emit(_ events: [InputEvent]) {
        for event in events { onEvent(event) }
    }

    private func updateTimer() {
        guard inputEnabled, engine.hasActiveContacts else {
            tickTimer?.invalidate()
            tickTimer = nil
            return
        }
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let events = self.engine.advance(to: ProcessInfo.processInfo.systemUptime)
            self.emit(events)
            if !events.isEmpty || self.showTouchIndicators { self.setNeedsDisplay() }
            self.updateTimer()
        }
        tickTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func resetTouches(notify: Bool) {
        tickTimer?.invalidate()
        tickTimer = nil
        let releases = engine.reset()
        if notify { emit(releases) }
        touchIDs.removeAll()
        nextTouchID = 0
        setNeedsDisplay()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { resetTouches(notify: true) }
        super.willMove(toWindow: newWindow)
    }
}
