import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import IKeyCore

final class CoreTests: XCTestCase {
    func testEveryEventRoundTripsAcrossEverySplitPoint() throws {
        let events: [InputEvent] = [.key(code: 55, down: true), .key(code: 0, down: false),
            .pointer(dx: -17.5, dy: 12), .button(button: .right, down: true),
            .scroll(dx: 8, dy: -23), .releaseAll, .heartbeat]
        for event in events {
            let bytes = try WireCodec.encode(event)
            for i in 0...bytes.count {
                var decoder = LineDecoder()
                let first = try decoder.append(bytes.prefix(i))
                let second = try decoder.append(bytes.dropFirst(i))
                XCTAssertEqual(first + second, [event])
            }
        }
    }

    func testCoalescedFramesPreserveModifierOrdering() throws {
        let events: [InputEvent] = [.key(code: 55, down: true), .key(code: 0, down: true),
            .key(code: 0, down: false), .key(code: 55, down: false), .releaseAll]
        let bytes = try events.reduce(into: Data()) { $0.append(try WireCodec.encode($1)) }
        var decoder = LineDecoder()
        XCTAssertEqual(try decoder.append(bytes), events)
    }

    func testOversizedUnterminatedFrameRejected() {
        var decoder = LineDecoder()
        XCTAssertThrowsError(try decoder.append(Data(repeating: 0x61, count: WireCodec.maxFrameBytes + 1))) {
            XCTAssertEqual($0 as? ProtocolError, .frameTooLarge)
        }
    }

    func testMalformedAndUnsupportedMessagesRejected() throws {
        var decoder = LineDecoder()
        XCTAssertThrowsError(try decoder.append(Data("not json\n".utf8)))
        XCTAssertThrowsError(try WireCodec.decode(Data()))
        let data = try WireCodec.encode(.heartbeat)
        let unsupported = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"version\":1", with: "\"version\":999")
        XCTAssertThrowsError(try WireCodec.decode(Data(unsupported.utf8))) {
            XCTAssertEqual($0 as? ProtocolError, .unsupportedVersion)
        }
    }

    func testInvalidKeyAndNonFiniteMovementRejected() {
        for event in [InputEvent.key(code: 65535, down: true), .pointer(dx: .infinity, dy: 0),
                      .scroll(dx: .nan, dy: 0), .pointer(dx: 4097, dy: 0)] {
            XCTAssertThrowsError(try WireCodec.encode(event))
        }
    }

    func testPairingSecretStrictnessAndRoundTrip() throws {
        let secret = PairingSecret.generate()
        XCTAssertEqual(secret.hex.count, 64)
        XCTAssertEqual(secret.bytes.count, 32)
        XCTAssertEqual(try PairingSecret(hex: secret.hex.uppercased()), secret)
        XCTAssertEqual(try PairingSecret(hex: " \n" + secret.hex + "\n"), secret)
        for value in ["", "1234", String(repeating: "g", count: 64), String(repeating: "é", count: 64)] {
            XCTAssertThrowsError(try PairingSecret(hex: value))
        }
    }

    func testDefaultLayoutValidUniqueAndEveryKeyHitTests() throws {
        let layout = try DeckLayout.macBookANSI.validated()
        XCTAssertGreaterThan(layout.keys.count, 70)
        for key in layout.keys {
            let frame = layout.frame(for: key)
            XCTAssertTrue(frame.isValid)
            XCTAssertEqual(layout.key(atX: frame.x + frame.width / 2, y: frame.y + frame.height / 2), key)
        }
        XCTAssertNil(layout.key(atX: layout.trackpad.x + 0.1, y: layout.trackpad.y + 0.1))
        XCTAssertNil(layout.key(atX: -1, y: -1))
    }

    func testPhotoLetterboxingAndKeyCoordinatesAgree() {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let image = PhotoGeometry.aspectFit(imageSize: CGSize(width: 3000, height: 1600), in: bounds)
        XCTAssertEqual(image, CGRect(x: 0, y: 80, width: 1200, height: 640))
        let layout = DeckLayout.macBookANSI
        for key in layout.keys {
            let drawn = layout.frame(for: key).rect(in: image)
            let x = (drawn.midX - image.minX) / image.width
            let y = (drawn.midY - image.minY) / image.height
            XCTAssertEqual(layout.key(atX: x, y: y)?.id, key.id)
        }
    }

    func testCalibrationJSONRoundTrip() throws {
        var layout = DeckLayout.macBookANSI
        layout.keyboard.x = 0.03
        layout.keys[0].frame.width *= 0.9
        let decoded = try JSONDecoder().decode(DeckLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(try decoded.validated(), layout)
    }

    func testOverlappingOrOutOfBoundsCalibrationRejected() {
        var layout = DeckLayout.macBookANSI
        layout.trackpad = layout.keyboard
        XCTAssertThrowsError(try layout.validated())
        layout = .macBookANSI
        layout.keys[1].frame = layout.keys[0].frame
        XCTAssertThrowsError(try layout.validated())
        layout = .macBookANSI
        layout.keyboard.x = .nan
        XCTAssertThrowsError(try layout.validated())
        layout = .macBookANSI
        layout.keys[0].frame.width = 2
        XCTAssertThrowsError(try layout.validated())
    }

    func testInvalidImageDimensionsDoNotDivideByZero() {
        XCTAssertEqual(PhotoGeometry.aspectFit(imageSize: .zero, in: CGRect(x: 0, y: 0, width: 10, height: 10)), .zero)
        XCTAssertEqual(PhotoGeometry.aspectFit(imageSize: CGSize(width: CGFloat.infinity, height: 10), in: .zero), .zero)
    }
}
