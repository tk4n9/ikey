import UIKit
import IKeyCore

/// Rasterises a `DeckScene` display list. Rects and points are view points; the ops' millimetre
/// lengths (radii, depths, blurs, stroke widths, text sizes) are converted with `ppm`.
///
/// Rendering is pure and thread-safe, so callers render off the main thread with `renderAsync`. If the
/// Main Thread Checker ever objects to the UIKit text or symbol drawing, call `render` on the main
/// thread instead; the output is identical.
enum DeckArtist {
    static func render(_ ops: [DrawOp], size: CGSize, scale: CGFloat, opaque: Bool, ppm: Double) -> CGImage? {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite,
              scale > 0, scale.isFinite, ppm > 0, ppm.isFinite else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = opaque
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            let context = rendererContext.cgContext
            if opaque {
                context.setFillColor(UIColor.black.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            }
            let painter = Painter(context: context, ppm: CGFloat(ppm), scale: scale)
            for op in ops { painter.draw(op) }
        }
        return image.cgImage
    }

    /// Renders on a serial `.userInitiated` queue and calls `completion` on the main queue, in
    /// submission order.
    static func renderAsync(_ ops: [DrawOp], size: CGSize, scale: CGFloat, opaque: Bool, ppm: Double,
                            completion: @escaping (CGImage?) -> Void) {
        queue.async {
            let image = render(ops, size: size, scale: scale, opaque: opaque, ppm: ppm)
            DispatchQueue.main.async { completion(image) }
        }
    }

    private static let queue = DispatchQueue(label: "ikey.deck-artist", qos: .userInitiated)
}

private struct Painter {
    let context: CGContext
    let ppm: CGFloat
    let scale: CGFloat

    func draw(_ op: DrawOp) {
        switch op {
        case let .fill(rect, color):
            context.setFillColor(cgColor(color))
            context.fill(rect)
        case let .roundedRect(rect, radius, fill, stroke):
            guard let path = roundedPath(rect, radius: radius) else { return }
            paint(path, rect: rect, fill)
            if let stroke { strokePath(path, stroke) }
        case let .innerShadow(rect, radius, depth, color):
            innerShadow(rect, radius: radius, depth: depth, color: color)
        case let .dropShadow(rect, radius, offsetY, blur, color):
            dropShadow(rect, radius: radius, offsetY: offsetY, blur: blur, color: color)
        case let .text(string, size, baseline, align, color):
            text(string, size: size, baseline: baseline, align: align, color: color)
        case let .symbol(name, box, color):
            symbol(name, box: box, color: color)
        case let .strokeRects(rects, width, color):
            context.setStrokeColor(cgColor(color))
            context.setLineWidth(ppm * CGFloat(width))
            context.addRects(rects)
            context.strokePath()
        case let .triangle(rect, direction, color):
            triangle(rect, direction, color)
        case let .ellipse(rect, fill, stroke):
            let path = CGPath(ellipseIn: rect, transform: nil)
            if let fill { paint(path, rect: rect, .solid(fill)) }
            if let stroke { strokePath(path, stroke) }
        case let .noise(rect, amplitude, seed):
            noise(rect, amplitude: amplitude, seed: seed)
        }
    }

    // MARK: Shapes

    private func cgColor(_ c: RGBA) -> CGColor {
        UIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a)).cgColor
    }

    /// Nil for an empty rect; the radius is clamped to half the shorter side.
    private func roundedPath(_ rect: CGRect, radius: Double) -> CGPath? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let r = max(0, min(ppm * CGFloat(radius), rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    private func paint(_ path: CGPath, rect: CGRect, _ fill: Paint) {
        switch fill {
        case .solid(let color):
            guard color.a > 0 else { return }
            context.addPath(path)
            context.setFillColor(cgColor(color))
            context.fillPath()
        case let .vertical(top, bottom):
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                            colors: [cgColor(top), cgColor(bottom)] as CFArray,
                                            locations: [0, 1]) else { return }
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY),
                                       end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            context.restoreGState()
        }
    }

    private func strokePath(_ path: CGPath, _ stroke: StrokeSpec) {
        guard stroke.width > 0, stroke.color.a > 0 else { return }
        context.addPath(path)
        context.setStrokeColor(cgColor(stroke.color))
        context.setLineWidth(ppm * CGFloat(stroke.width))
        context.strokePath()
    }

    /// A gradient from `color` at the top edge to clear `depth` below it, clipped to the shape. Drawn
    /// with geometry rather than Core Graphics shadows so the result does not depend on the context's
    /// base transform.
    private func innerShadow(_ rect: CGRect, radius: Double, depth: Double, color: RGBA) {
        guard let path = roundedPath(rect, radius: radius), depth > 0 else { return }
        var mid = color, clear = color
        mid.a *= 0.35
        clear.a = 0
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [cgColor(color), cgColor(mid), cgColor(clear)] as CFArray,
                                        locations: [0, 0.4, 1]) else { return }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY),
                                   end: CGPoint(x: rect.midX, y: rect.minY + ppm * CGFloat(depth)), options: [])
        context.restoreGState()
    }

    /// The shape moved down `offsetY` and spread over `blur` as four stacked outlines (a box-filtered
    /// edge), drawn only outside the shape itself.
    private func dropShadow(_ rect: CGRect, radius: Double, offsetY: Double, blur: Double, color: RGBA) {
        guard let shape = roundedPath(rect, radius: radius), color.a > 0 else { return }
        let steps = 4
        let blurPoints = ppm * CGFloat(max(blur, 0))
        let shifted = rect.offsetBy(dx: 0, dy: ppm * CGFloat(offsetY))
        var step = color
        step.a = 1 - pow(1 - min(color.a, 1), 1 / Double(steps)) // n layers composite to color.a
        let outer = rect.insetBy(dx: -4 * (blurPoints + ppm), dy: -4 * (blurPoints + ppm))

        context.saveGState()
        context.addRect(outer)
        context.addPath(shape)
        context.clip(using: .evenOdd)
        context.setFillColor(cgColor(step))
        for i in 0..<steps {
            let spread = blurPoints * (0.5 - (CGFloat(i) + 0.5) / CGFloat(steps))
            let r = shifted.insetBy(dx: -spread, dy: -spread)
            if let path = roundedPath(r, radius: radius + Double(spread / ppm)) {
                context.addPath(path)
                context.fillPath()
            }
        }
        context.restoreGState()
    }

    private func triangle(_ rect: CGRect, _ direction: ArrowDirection, _ color: RGBA) {
        let points: [CGPoint]
        switch direction {
        case .up: points = [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        case .down: points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY)]
        case .left: points = [CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
        case .right: points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.minX, y: rect.maxY)]
        }
        context.addLines(between: points)
        context.closePath()
        context.setFillColor(cgColor(color))
        context.fillPath()
    }

    // MARK: Text and symbols

    private func text(_ string: String, size: Double, baseline: CGPoint, align: TextAlign, color: RGBA) {
        let font = UIFont.systemFont(ofSize: ppm * CGFloat(size), weight: .regular)
        let attributed = NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: UIColor(cgColor: cgColor(color)),
        ])
        let width = attributed.size().width
        let x: CGFloat
        switch align {
        case .left: x = baseline.x
        case .center: x = baseline.x - width / 2
        case .right: x = baseline.x - width
        }
        attributed.draw(at: CGPoint(x: x, y: baseline.y - font.ascender))
    }

    private func symbol(_ name: String, box: CGRect, color: RGBA) {
        guard box.width > 0, box.height > 0 else { return }
        let configuration = UIImage.SymbolConfiguration(pointSize: box.height, weight: .regular)
        guard let image = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(UIColor(cgColor: cgColor(color)), renderingMode: .alwaysOriginal),
            image.size.width > 0, image.size.height > 0 else { return }
        let fit = min(box.width / image.size.width, box.height / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        image.draw(in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                              width: size.width, height: size.height))
    }

    // MARK: Noise

    /// One device pixel per tile pixel; nearest-neighbour so the grain stays crisp.
    private func noise(_ rect: CGRect, amplitude: Double, seed: UInt64) {
        guard amplitude > 0, rect.width > 0, rect.height > 0,
              let tile = NoiseTiles.shared.tile(amplitude: amplitude, seed: seed) else { return }
        let side = CGFloat(NoiseTiles.side) / scale
        context.saveGState()
        context.clip(to: rect)
        context.interpolationQuality = .none
        context.draw(tile, in: CGRect(x: rect.minX, y: rect.minY, width: side, height: side), byTiling: true)
        context.restoreGState()
    }
}

/// Seeded xorshift grain tiles, cached by (amplitude, seed); safe to use from any thread.
private final class NoiseTiles {
    static let shared = NoiseTiles()
    static let side = 256

    private struct Key: Hashable { let amplitude: Double; let seed: UInt64 }
    private let lock = NSLock()
    private var tiles: [Key: CGImage] = [:]

    func tile(amplitude: Double, seed: UInt64) -> CGImage? {
        let key = Key(amplitude: amplitude, seed: seed)
        lock.lock()
        defer { lock.unlock() }
        if let tile = tiles[key] { return tile }
        let tile = Self.make(amplitude: min(amplitude, 1), seed: seed)
        tiles[key] = tile
        return tile
    }

    /// Each pixel is white or black with alpha |v| x amplitude, v uniform in -1...1 (premultiplied).
    private static func make(amplitude: Double, seed: UInt64) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        for i in 0..<(side * side) {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let v = Double(state >> 11) / Double(1 << 53) * 2 - 1
            let alpha = UInt8((abs(v) * amplitude * 255).rounded())
            let channel = v > 0 ? alpha : 0
            pixels[i * 4] = channel
            pixels[i * 4 + 1] = channel
            pixels[i * 4 + 2] = channel
            pixels[i * 4 + 3] = alpha
        }
        return context.makeImage()
    }
}
