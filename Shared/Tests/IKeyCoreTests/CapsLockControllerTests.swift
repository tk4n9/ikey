import Foundation
import XCTest
@testable import IKeyCore

final class CapsLockControllerTests: XCTestCase {
    /// Runs advance() at every deadline before `end`.
    private func drain(_ c: inout CapsLockController, until end: TimeInterval, isOn: Bool) -> [(TimeInterval, KeyboardAction)] {
        var out: [(TimeInterval, KeyboardAction)] = []
        while let t = c.nextDeadline, t < end {
            out += c.advance(to: t, isOn: isOn).map { (t, $0) }
        }
        return out
    }

    func testShortPressIgnored() {
        var c = CapsLockController()
        XCTAssertEqual(c.down(senderTime: 1.0, at: 0, isOn: false), [])
        XCTAssertEqual(c.up(senderTime: 1.04, at: 0.04, isOn: false), [])
        XCTAssertNil(c.nextDeadline)
        XCTAssertEqual(c.advance(to: 1, isOn: false), [])
    }

    func test100msActivatesOnce() {
        var c = CapsLockController()
        _ = c.down(senderTime: 1.0, at: 0, isOn: false)
        XCTAssertEqual(c.nextDeadline ?? -1, 0.075, accuracy: 1e-9)
        let fired = drain(&c, until: 0.1, isOn: false)
        XCTAssertEqual(fired.map(\.1), [.setCapsLock(true)])
        XCTAssertEqual(fired.first?.0 ?? -1, 0.075, accuracy: 1e-9)
        XCTAssertEqual(c.up(senderTime: 1.1, at: 0.1, isOn: true), [])
        XCTAssertEqual(c.advance(to: 1, isOn: true), [])
    }

    func testUpWithoutTickStillActivatesOnce() {
        var c = CapsLockController()
        _ = c.down(senderTime: nil, at: 0, isOn: false)
        XCTAssertEqual(c.up(senderTime: nil, at: 0.1, isOn: false), [.setCapsLock(true)])
        XCTAssertEqual(c.advance(to: 1, isOn: true), [])
    }

    func testOnStateDeactivatesAtDown() {
        var c = CapsLockController()
        XCTAssertEqual(c.down(senderTime: 1.0, at: 0, isOn: true), [.setCapsLock(false)])
        XCTAssertNil(c.nextDeadline)
        XCTAssertEqual(c.advance(to: 1, isOn: false), [])
        XCTAssertEqual(c.up(senderTime: 2.0, at: 1, isOn: false), [])
    }

    func testBunchedArrivalUsesSenderTime() {
        var c = CapsLockController()
        _ = c.down(senderTime: 10.0, at: 0, isOn: false)
        XCTAssertEqual(c.up(senderTime: 10.12, at: 0.005, isOn: false), [.setCapsLock(true)])
        XCTAssertNil(c.nextDeadline)

        // Before the Mac deadline, a short sender gap is discarded.
        _ = c.down(senderTime: 20.0, at: 1, isOn: false)
        XCTAssertEqual(c.up(senderTime: 20.04, at: 1.05, isOn: false), [])
    }

    func testUpUsesSenderDurationOverLateMacClock() {
        // No tick ran; the up arrives after the Mac deadline but the sender press was 40 ms.
        var c = CapsLockController()
        _ = c.down(senderTime: 1.0, at: 0, isOn: false)
        XCTAssertEqual(c.up(senderTime: 1.04, at: 0.08, isOn: false), [])

        var s = CapsLockController(mode: .switchesInputSource)
        _ = s.down(senderTime: 5.0, at: 0, isOn: false)
        XCTAssertEqual(s.up(senderTime: 5.1, at: 0.6, isOn: false), [.symbolicHotKey(60)])
    }

    func testUpWithoutSenderTimeUsesMacClock() {
        var c = CapsLockController()
        _ = c.down(senderTime: nil, at: 0, isOn: false)
        XCTAssertEqual(c.up(senderTime: nil, at: 0.05, isOn: false), [])
        var s = CapsLockController(mode: .switchesInputSource)
        _ = s.down(senderTime: 5.0, at: 0, isOn: false)
        XCTAssertEqual(s.up(senderTime: nil, at: 0.6, isOn: false), [.setCapsLock(true)])
    }

    func testNonFiniteThresholdsUseDefaults() {
        var c = CapsLockController(delay: .nan)
        _ = c.down(senderTime: nil, at: 0, isOn: false)
        XCTAssertEqual(c.nextDeadline ?? -1, 0.075, accuracy: 1e-9)
        var s = CapsLockController(mode: .switchesInputSource, switchHold: .infinity)
        _ = s.down(senderTime: nil, at: 0, isOn: false)
        XCTAssertEqual(s.nextDeadline ?? -1, 0.5, accuracy: 1e-9)
    }

    func testHeldActivatesAtDeadline() {
        var c = CapsLockController()
        _ = c.down(senderTime: nil, at: 0, isOn: false)
        XCTAssertEqual(c.advance(to: 0.07, isOn: false), [])
        XCTAssertEqual(c.advance(to: 0.075, isOn: false), [.setCapsLock(true)])
        XCTAssertNil(c.nextDeadline)
        XCTAssertEqual(c.advance(to: 2, isOn: true), [])
        XCTAssertEqual(c.up(senderTime: nil, at: 2, isOn: true), [])
    }

    func testDuplicateDownAndOrphanUpIgnored() {
        var c = CapsLockController()
        XCTAssertEqual(c.up(senderTime: nil, at: 0, isOn: false), [])
        _ = c.down(senderTime: nil, at: 0, isOn: false)
        XCTAssertEqual(c.down(senderTime: nil, at: 0.05, isOn: false), [])
        XCTAssertEqual(c.nextDeadline ?? -1, 0.075, accuracy: 1e-9)
    }

    func testVirtualModeTogglesOnDown() {
        var c = CapsLockController(mode: .virtual)
        XCTAssertEqual(c.down(senderTime: nil, at: 0, isOn: false),
                       [.flagsChanged(code: MacKeyCode.capsLock, flags: [.nonCoalesced, .alphaShift])])
        XCTAssertTrue(c.virtualOn)
        XCTAssertNil(c.nextDeadline)
        XCTAssertEqual(c.up(senderTime: nil, at: 0.01, isOn: false), [])
        XCTAssertEqual(c.down(senderTime: nil, at: 1, isOn: false),
                       [.flagsChanged(code: MacKeyCode.capsLock, flags: .nonCoalesced)])
        XCTAssertFalse(c.virtualOn)
    }

    func testSwitchModeTapPostsHotKey60() {
        var c = CapsLockController(mode: .switchesInputSource)
        XCTAssertEqual(c.down(senderTime: 5.0, at: 0, isOn: false), [])
        XCTAssertEqual(c.nextDeadline ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.up(senderTime: 5.1, at: 0.1, isOn: false), [.symbolicHotKey(60)])
        XCTAssertNil(c.nextDeadline)
    }

    func testSwitchModeHoldTogglesCaps() {
        var c = CapsLockController(mode: .switchesInputSource)
        _ = c.down(senderTime: 5.0, at: 0, isOn: false)
        let fired = drain(&c, until: 0.6, isOn: false)
        XCTAssertEqual(fired.map(\.1), [.setCapsLock(true)])
        XCTAssertEqual(fired.first?.0 ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.up(senderTime: 5.6, at: 0.6, isOn: true), [])

        // Held again while on: turns it off.
        _ = c.down(senderTime: 6.0, at: 1, isOn: true)
        XCTAssertEqual(c.advance(to: 1.5, isOn: true), [.setCapsLock(false)])
    }

    func testSwitchModeBunchedLongHoldTogglesAtUp() {
        var c = CapsLockController(mode: .switchesInputSource)
        _ = c.down(senderTime: 5.0, at: 0, isOn: false)
        XCTAssertEqual(c.up(senderTime: 5.7, at: 0.01, isOn: false), [.setCapsLock(true)])
    }

    /// The sender stamps the down `senderLead` after the touch landed (the iPad's key
    /// confirmation), so an up adds it back: thresholds count from the touch. The Mac-clock
    /// deadline keeps the full threshold.
    func testSenderLeadCountsHoldFromTouchDown() {
        var c = CapsLockController(senderLead: 0.045)
        _ = c.down(senderTime: 1.045, at: 0, isOn: false)
        XCTAssertEqual(c.nextDeadline ?? -1, 0.075, accuracy: 1e-9)
        XCTAssertEqual(c.up(senderTime: 1.10, at: 0.055, isOn: false), [.setCapsLock(true)])  // a 100 ms touch
        _ = c.down(senderTime: 2.045, at: 1, isOn: false)
        XCTAssertEqual(c.up(senderTime: 2.07, at: 1.025, isOn: false), [])                   // a 70 ms touch
        // Without sender times the Mac clock decides, with no lead.
        _ = c.down(senderTime: nil, at: 3, isOn: false)
        XCTAssertEqual(c.up(senderTime: nil, at: 3.05, isOn: false), [])

        var s = CapsLockController(mode: .switchesInputSource, senderLead: 0.045)
        _ = s.down(senderTime: 5.045, at: 0, isOn: false)
        XCTAssertEqual(s.up(senderTime: 5.47, at: 0.425, isOn: false), [.symbolicHotKey(60)])
        _ = s.down(senderTime: 6.045, at: 1, isOn: false)
        XCTAssertEqual(s.up(senderTime: 6.52, at: 1.475, isOn: false), [.setCapsLock(true)])

        // A corrupt lead is clamped (negative/non-finite → none, at most 0.25 s).
        let leads: [(TimeInterval, [KeyboardAction])] = [(-1, []), (.nan, []), (.infinity, []), (10, [.setCapsLock(true)])]
        for (lead, expected) in leads {
            var bad = CapsLockController(senderLead: lead)
            _ = bad.down(senderTime: 1, at: 0, isOn: false)
            XCTAssertEqual(bad.up(senderTime: 1.04, at: 0.04, isOn: false), expected, "lead \(lead)")
        }
    }

    /// A key whose lone tap arrives as down+up at one sender instant (a deck modifier remapped
    /// to Caps Lock) is a full press in .system and a tap in .switchesInputSource.
    func testTapAtLiftIsAFullPressInSystemMode() {
        var c = CapsLockController(senderLead: 0.045)
        _ = c.down(senderTime: 1, at: 0, isOn: false, tapAtLift: true)
        XCTAssertEqual(c.up(senderTime: 1, at: 0, isOn: false), [.setCapsLock(true)])
        XCTAssertEqual(c.down(senderTime: 2, at: 1, isOn: true, tapAtLift: true), [.setCapsLock(false)])
        XCTAssertEqual(c.up(senderTime: 2, at: 1, isOn: false), [])
        // Timed (chorded) presses of the same key keep the normal threshold.
        _ = c.down(senderTime: 3, at: 2, isOn: false, tapAtLift: true)
        XCTAssertEqual(c.up(senderTime: 3.01, at: 2.01, isOn: false), [])
        // Without the flag, a same-instant tap is a touch shorter than the confirmation: ignored.
        _ = c.down(senderTime: 4, at: 3, isOn: false)
        XCTAssertEqual(c.up(senderTime: 4, at: 3, isOn: false), [])

        var s = CapsLockController(mode: .switchesInputSource, senderLead: 0.045)
        _ = s.down(senderTime: 1, at: 0, isOn: false, tapAtLift: true)
        XCTAssertEqual(s.up(senderTime: 1, at: 0, isOn: false), [.symbolicHotKey(60)])
    }

    func testModeChangeAndResetDropState() {
        var c = CapsLockController(mode: .virtual)
        _ = c.down(senderTime: nil, at: 0, isOn: false)
        c.mode = .system
        XCTAssertFalse(c.virtualOn)
        XCTAssertEqual(c.up(senderTime: nil, at: 0.2, isOn: false), [])

        _ = c.down(senderTime: nil, at: 1, isOn: false)
        c.reset()
        XCTAssertNil(c.nextDeadline)
        XCTAssertEqual(c.up(senderTime: nil, at: 1.2, isOn: false), [])
    }
}
