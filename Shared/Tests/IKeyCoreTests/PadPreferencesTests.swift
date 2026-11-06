import XCTest
@testable import IKeyCore

final class PadPreferencesTests: XCTestCase {
    private func decode(_ json: String) throws -> PadPreferences {
        try JSONDecoder().decode(PadPreferences.self, from: Data(json.utf8))
    }

    func testDefaults() {
        let p = PadPreferences()
        XCTAssertEqual(PadPreferences.storageKey, "iKey.preferences.v2")
        XCTAssertEqual(p.appearance.mode, .drawn)
        XCTAssertEqual(p.appearance.model, .air13_2025)
        XCTAssertEqual(p.appearance.model, MacBookAirModel.defaultModel)
        XCTAssertFalse(p.appearance.modelIsManual)
        XCTAssertNil(p.appearance.finish)
        XCTAssertNil(p.appearance.iPadOverrideID)
        XCTAssertEqual(p.appearance.placement, DeckPlacement())
        XCTAssertEqual(p.appearance.tone, 0)
        XCTAssertEqual(p.appearance.pressLook, .subtle)
        XCTAssertEqual(p.appearance.glow, .auto)
        XCTAssertEqual(p.typing, TypingSettings())
        XCTAssertEqual(p.trackpad, TrackpadSettings())
        XCTAssertTrue(p.trackpadFollowsMac)
        XCTAssertEqual(p.protection, TouchProtectionSettings())
        XCTAssertFalse(p.showTouchIndicators)
        XCTAssertEqual(p.panelTriggerRaw, "touchIDHold")
        XCTAssertEqual(p.peerToPeer, PeerToPeerPolicy())
        XCTAssertEqual(p.peerToPeer.setting, .automatic)
        XCTAssertEqual(PressLookSetting.allCases.map(\.rawValue), ["off", "subtle", "clear"])
        XCTAssertEqual(KeyboardGlowSetting.allCases.map(\.rawValue), ["off", "auto", "on"])
        XCTAssertEqual(PeerToPeerSetting.allCases.map(\.rawValue), ["automatic", "always", "never"])
    }

    func testRoundTrip() throws {
        var p = PadPreferences()
        p.appearance.mode = .photo
        p.appearance.model = .air13_2022
        p.appearance.modelIsManual = true
        p.appearance.finish = .skyBlue
        p.appearance.iPadOverrideID = "air13"
        p.appearance.placement = DeckPlacement(offsetXmm: 1.5, offsetYmm: -2, scale: 1)
        p.appearance.tone = -0.25
        p.appearance.pressLook = .clear
        p.appearance.glow = .on
        p.typing.resting = .allTypingKeys
        p.trackpad.dragStyle = .tapDragLock
        p.trackpadFollowsMac = false
        p.protection.sensitivity = .strict
        p.showTouchIndicators = true
        p.panelTriggerRaw = "other"
        p.peerToPeer.sessionEstablished(overInfrastructure: true)
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(PadPreferences.self, from: data), p)
    }

    func testNonFiniteValuesEncodeAsDefaults() throws {
        var p = PadPreferences()
        p.appearance.tone = .nan
        p.appearance.placement = DeckPlacement(offsetXmm: .infinity, offsetYmm: 2, scale: -.infinity)
        p.typing.restThreshold = .nan
        p.trackpad.tapQuiet = .infinity
        p.showTouchIndicators = true
        let decoded = try JSONDecoder().decode(PadPreferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.appearance.tone, 0)
        XCTAssertEqual(decoded.appearance.placement, DeckPlacement(offsetXmm: 0, offsetYmm: 2, scale: 1))
        XCTAssertEqual(decoded.typing, TypingSettings())
        XCTAssertEqual(decoded.trackpad, TrackpadSettings())
        XCTAssertTrue(decoded.showTouchIndicators)
        // The appearance alone encodes the same way.
        let a = try JSONDecoder().decode(DeckAppearanceSettings.self, from: JSONEncoder().encode(p.appearance))
        XCTAssertEqual(a.tone, 0)
        XCTAssertEqual(a, decoded.appearance)
    }

    func testDecodeIfPresentOldJSON() throws {
        XCTAssertEqual(try decode("{}"), PadPreferences())

        // An older build's file: some fields only, partial nested objects.
        let old = try decode("""
        {"appearance":{"model":"air13_2022","placement":{"offsetYmm":2}},
         "showTouchIndicators":true,"trackpad":{"dragStyle":"threeFinger"}}
        """)
        XCTAssertEqual(old.appearance.model, .air13_2022)
        XCTAssertEqual(old.appearance.placement, DeckPlacement(offsetXmm: 0, offsetYmm: 2))
        XCTAssertEqual(old.appearance.pressLook, .subtle)
        XCTAssertTrue(old.showTouchIndicators)
        XCTAssertEqual(old.trackpad.dragStyle, .threeFinger)
        XCTAssertEqual(old.trackpad.doubleClickInterval, TrackpadSettings().doubleClickInterval)
        XCTAssertEqual(old.typing, TypingSettings())
        XCTAssertEqual(old.peerToPeer, PeerToPeerPolicy())

        // Values a newer build may write fall back instead of failing the whole file.
        let newer = try decode("""
        {"appearance":{"model":"air15_2030","finish":"rainbow","glow":"pulse","mode":"drawn","tone":0.5},
         "protection":{"enabled":false},"peerToPeer":{"setting":"sometimes","infraConfirmed":true},
         "panelTriggerRaw":"futureTrigger","futureField":42}
        """)
        XCTAssertEqual(newer.appearance.model, MacBookAirModel.defaultModel)
        XCTAssertNil(newer.appearance.finish)
        XCTAssertEqual(newer.appearance.glow, .auto)
        XCTAssertEqual(newer.appearance.tone, 0.5)
        XCTAssertEqual(newer.protection, TouchProtectionSettings())
        XCTAssertEqual(newer.peerToPeer.setting, .automatic)
        XCTAssertTrue(newer.peerToPeer.infraConfirmed)
        XCTAssertEqual(newer.panelTriggerRaw, "futureTrigger")

        // Not an object at all still throws.
        XCTAssertThrowsError(try decode("[]"))
    }

    func testMigrationFromV1Keys() throws {
        let v1 = TouchProtectionSettings(enabled: false, sensitivity: .relaxed, pauseTrackpadWhileTyping: false)
        let data = try JSONEncoder().encode(v1)
        let p = PadPreferences.migrated(v1TouchProtection: data, v1ShowIndicators: true)
        XCTAssertEqual(p.protection, v1)
        XCTAssertTrue(p.showTouchIndicators)
        XCTAssertEqual(p.appearance, DeckAppearanceSettings())
        XCTAssertEqual(p.typing, TypingSettings())

        XCTAssertEqual(PadPreferences.migrated(v1TouchProtection: nil, v1ShowIndicators: nil), PadPreferences())
        let junk = PadPreferences.migrated(v1TouchProtection: Data("not json".utf8), v1ShowIndicators: false)
        XCTAssertEqual(junk, PadPreferences())
    }

    func testEffectiveTrackpadMapping() {
        var p = PadPreferences()
        p.trackpad.dragStyle = .tapDrag
        p.trackpad.doubleClickInterval = 0.4
        p.trackpad.threeFingerGestures = true
        p.trackpad.thumbClick = false

        XCTAssertEqual(p.effectiveTrackpad(mac: nil), p.trackpad)

        var mac = MacInputPreferences()
        mac.threeFingerDrag = true
        mac.dragLock = true
        mac.doubleClickInterval = 0.9
        mac.threeFingerSwipes = false
        let followed = p.effectiveTrackpad(mac: mac)
        XCTAssertEqual(followed.dragStyle, .threeFinger)
        XCTAssertEqual(followed.doubleClickInterval, 0.9)
        XCTAssertFalse(followed.threeFingerGestures)
        // iPad-only settings stay.
        XCTAssertFalse(followed.thumbClick)
        XCTAssertEqual(followed.tapQuiet, p.trackpad.tapQuiet)

        mac.threeFingerDrag = false
        XCTAssertEqual(p.effectiveTrackpad(mac: mac).dragStyle, .tapDragLock)
        mac.dragLock = false
        XCTAssertEqual(p.effectiveTrackpad(mac: mac).dragStyle, .tapDrag)
        p.trackpad.dragStyle = .threeFinger
        XCTAssertEqual(p.effectiveTrackpad(mac: mac).dragStyle, .tapDrag)

        p.trackpadFollowsMac = false
        XCTAssertEqual(p.effectiveTrackpad(mac: mac), p.trackpad)
    }

    func testGeometryChangeDetection() {
        let base = PadPreferences()
        func changed(_ edit: (inout PadPreferences) -> Void) -> Bool {
            var p = base
            edit(&p)
            return p.isGeometryChange(from: base)
        }
        XCTAssertFalse(changed { _ in })
        XCTAssertTrue(changed { $0.appearance.model = .air13_2020 })
        XCTAssertTrue(changed { $0.appearance.iPadOverrideID = "pro13" })
        XCTAssertTrue(changed { $0.appearance.placement.offsetXmm = 0.1 })
        XCTAssertTrue(changed { $0.appearance.placement.offsetYmm = -0.1 })
        XCTAssertTrue(changed { $0.appearance.mode = .photo })
        // Look-only and behaviour settings do not move the deck.
        XCTAssertFalse(changed { $0.appearance.finish = .gold })
        XCTAssertFalse(changed { $0.appearance.tone = 0.3 })
        XCTAssertFalse(changed { $0.appearance.pressLook = .off })
        XCTAssertFalse(changed { $0.appearance.glow = .on })
        XCTAssertFalse(changed { $0.appearance.modelIsManual = true })
        XCTAssertFalse(changed { $0.typing.resting = .off })
        XCTAssertFalse(changed { $0.trackpad.dragStyle = .threeFinger })
        XCTAssertFalse(changed { $0.showTouchIndicators = true })
        XCTAssertFalse(changed { $0.peerToPeer.setting = .never })
    }

    func testPeerToPeerPolicyAutomatic() throws {
        var p = PeerToPeerPolicy()
        XCTAssertTrue(p.useP2P(), "P2P until an infrastructure session is confirmed")
        p.attemptFailed(usedP2P: true)
        XCTAssertTrue(p.useP2P())
        // A P2P session does not confirm infrastructure.
        p.sessionEstablished(overInfrastructure: false)
        XCTAssertTrue(p.useP2P())
        XCTAssertFalse(p.infraConfirmed)

        p.sessionEstablished(overInfrastructure: true)
        XCTAssertTrue(p.infraConfirmed)
        XCTAssertFalse(p.useP2P())
        p.attemptFailed(usedP2P: false)
        p.attemptFailed(usedP2P: false)
        XCTAssertEqual(p.consecutiveInfraFailures, 2)
        XCTAssertFalse(p.useP2P())
        p.attemptFailed(usedP2P: false)
        XCTAssertTrue(p.useP2P(), "back to P2P after 3 infrastructure failures")
        // A P2P success keeps infraConfirmed and the fallback.
        p.sessionEstablished(overInfrastructure: false)
        XCTAssertTrue(p.infraConfirmed)
        XCTAssertTrue(p.useP2P())
        // P2P failures do not count toward the infrastructure fallback.
        var q = PeerToPeerPolicy()
        q.sessionEstablished(overInfrastructure: true)
        for _ in 0..<5 { q.attemptFailed(usedP2P: true) }
        XCTAssertFalse(q.useP2P())
        // An infrastructure session resets the count.
        p.sessionEstablished(overInfrastructure: true)
        XCTAssertEqual(p.consecutiveInfraFailures, 0)
        XCTAssertFalse(p.useP2P())

        // Manual settings override.
        p.setting = .always
        XCTAssertTrue(p.useP2P())
        p.setting = .never
        XCTAssertFalse(p.useP2P())
        var fresh = PeerToPeerPolicy()
        fresh.setting = .never
        XCTAssertFalse(fresh.useP2P())

        // Persisted state round-trips; missing fields default.
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(PeerToPeerPolicy.self, from: data), p)
        XCTAssertEqual(try JSONDecoder().decode(PeerToPeerPolicy.self, from: Data("{}".utf8)), PeerToPeerPolicy())
    }
}
