import Foundation

public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 &&
        width > 0 && height > 0 && x + width <= 1.0000001 && y + height <= 1.0000001
    }
    public func rect(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height,
               width: width * bounds.width, height: height * bounds.height)
    }
    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }
}

public struct KeyRegion: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var keyCode: UInt16
    public var frame: NormalizedRect
    public init(id: String, label: String, keyCode: UInt16, frame: NormalizedRect) {
        self.id = id; self.label = label; self.keyCode = keyCode; self.frame = frame
    }
}

public struct DeckLayout: Codable, Equatable, Sendable {
    public var keyboard: NormalizedRect
    public var trackpad: NormalizedRect
    public var keys: [KeyRegion]
    public init(keyboard: NormalizedRect, trackpad: NormalizedRect, keys: [KeyRegion]) {
        self.keyboard = keyboard; self.trackpad = trackpad; self.keys = keys
    }
    public func frame(for key: KeyRegion) -> NormalizedRect {
        NormalizedRect(x: keyboard.x + key.frame.x * keyboard.width,
                       y: keyboard.y + key.frame.y * keyboard.height,
                       width: key.frame.width * keyboard.width,
                       height: key.frame.height * keyboard.height)
    }
    public func key(atX x: Double, y: Double) -> KeyRegion? {
        keys.first { frame(for: $0).contains(x: x, y: y) }
    }
    public func validated() throws -> DeckLayout {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard keyboard.isValid, trackpad.isValid, !keys.isEmpty, keys.count <= 128,
              Set(keys.map(\.id)).count == keys.count,
              Set(keys.map(\.keyCode)).count == keys.count,
              !keyboard.rect(in: unit).intersects(trackpad.rect(in: unit)) else {
            throw LayoutError.invalidLayout
        }
        for key in keys {
            guard key.frame.isValid, !key.id.isEmpty, key.id.count <= 64,
                  key.label.count <= 32, InputEvent.supportedKeyCodes.contains(key.keyCode) else {
                throw LayoutError.invalidLayout
            }
        }
        for i in keys.indices {
            for j in keys.indices where j > i {
                if keys[i].frame.rect(in: unit).intersects(keys[j].frame.rect(in: unit)) {
                    throw LayoutError.invalidLayout
                }
            }
        }
        return self
    }

    /// Approximate US ANSI deck; calibrate against a straight-on photograph.
    public static var macBookANSI: DeckLayout {
        var keys: [KeyRegion] = []
        func row(_ labels: [String], _ codes: [UInt16], _ widths: [Double], y: Double, h: Double) {
            let total = widths.reduce(0, +)
            var x = 0.0
            let gap = 0.006
            for i in labels.indices {
                let w = widths[i] / total
                keys.append(KeyRegion(id: "key-\(codes[i])", label: labels[i], keyCode: codes[i],
                    frame: NormalizedRect(x: x + gap / 2, y: y + gap / 2,
                                          width: w - gap, height: h - gap)))
                x += w
            }
        }
        row(["esc", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"],
            [53,122,120,99,118,96,97,98,100,101,109,103,111], Array(repeating: 1, count: 13), y: 0, h: 0.12)
        row(["`","1","2","3","4","5","6","7","8","9","0","−","=","delete"],
            [50,18,19,20,21,23,22,26,28,25,29,27,24,51],
            Array(repeating: 1, count: 13) + [1.5], y: 0.12, h: 0.176)
        row(["tab","Q","W","E","R","T","Y","U","I","O","P","[","]","\\"],
            [48,12,13,14,15,17,16,32,34,31,35,33,30,42],
            [1.5] + Array(repeating: 1, count: 13), y: 0.296, h: 0.176)
        row(["caps lock","A","S","D","F","G","H","J","K","L",";","'","return"],
            [57,0,1,2,3,5,4,38,40,37,41,39,36],
            [1.75] + Array(repeating: 1, count: 11) + [1.75], y: 0.472, h: 0.176)
        row(["shift","Z","X","C","V","B","N","M",",",".","/","shift"],
            [56,6,7,8,9,11,45,46,43,47,44,60],
            [2.25] + Array(repeating: 1, count: 10) + [2.25], y: 0.648, h: 0.176)
        let labels = ["fn","control","option","command","space","command","option"]
        let codes: [UInt16] = [63,59,58,55,49,54,61]
        let units: [Double] = [1,1,1,1.25,5,1.25,1]
        var x = 0.0
        for i in labels.indices {
            let w = units[i] / 14.5
            keys.append(KeyRegion(id: "key-\(codes[i])", label: labels[i], keyCode: codes[i],
                frame: NormalizedRect(x: x + 0.003, y: 0.827, width: w - 0.006, height: 0.17)))
            x += w
        }
        let arrowW = 1.0 / 14.5
        for (label, code, column, y, height) in [
            ("←", UInt16(123), 0.0, 0.827, 0.17),
            ("↑", UInt16(126), 1.0, 0.827, 0.082),
            ("↓", UInt16(125), 1.0, 0.915, 0.082),
            ("→", UInt16(124), 2.0, 0.827, 0.17)
        ] {
            keys.append(KeyRegion(id: "key-\(code)", label: label, keyCode: code,
                frame: NormalizedRect(x: x + column * arrowW + 0.003, y: y,
                                      width: arrowW - 0.006, height: height)))
        }
        return DeckLayout(keyboard: NormalizedRect(x: 0.055, y: 0.07, width: 0.89, height: 0.55),
                          trackpad: NormalizedRect(x: 0.30, y: 0.66, width: 0.40, height: 0.31), keys: keys)
    }
}

public enum LayoutError: Error { case invalidLayout }
public enum PhotoGeometry {
    public static func aspectFit(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
