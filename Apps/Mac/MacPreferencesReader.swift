import AppKit
import Carbon
import CoreGraphics
import Foundation
import IKeyCore
import IOKit
import SystemConfiguration

/// The built-in trackpad's live IOHID acceleration state. A nil field means it was not readable;
/// the injector then falls back to HIDCurveTables and the preferences' tracking index.
struct LiveCurves: Equatable {
    var pointer: [HIDAccelCurve]?
    var scroll: [HIDAccelCurve]?
    var trackingIndex: Double?
}

/// One snapshot of everything the Mac side mirrors. Equatable, so a poll detects any change
/// (including keyboard shortcuts) by comparing two readings.
struct MacReadings: Equatable {
    var prefs: MacInputPreferences
    var hotKeys: SymbolicHotKeys
    var liveCurves: LiveCurves
    /// sysctl hw.model, for example "Mac16,12"; empty when unreadable.
    var hardwareModel: String
    var computerName: String
    var keyboard: KeyboardKind
    /// Points per millimetre of the active built-in display; nil when it is off or absent.
    var builtInPtPerMM: Double?
    /// Built-in display [width, height] in millimetres.
    var builtInDisplayMM: [Double]?
    /// Globe/fn key action; nil when unset or not recognised.
    var fnTapAction: FnTapAction?
    /// "Use Caps Lock to switch to and from ABC"; nil when the setting is absent.
    var capsSwitchesInputSource: Bool?
    /// Selectable keyboard input sources (layouts and input modes).
    var enabledInputSourceCount: Int
}

/// Reads the Mac's keyboard and trackpad settings. Call on the main thread (TIS requires it);
/// cheap enough for a 2 s poll.
enum MacPreferencesReader {
    static func read() -> MacReadings {
        // Other processes write these domains; pick up their latest values.
        for domain in [trackpadDomain, hotKeysDomain, toolboxDomain] { CFPreferencesAppSynchronize(domain as CFString) }
        let display = builtInDisplay()
        return MacReadings(
            prefs: readPreferences(),
            hotKeys: SymbolicHotKeys(plist: appValue("AppleSymbolicHotKeys", domain: hotKeysDomain) as? [String: Any]),
            liveCurves: readLiveCurves(),
            hardwareModel: hardwareModel(),
            computerName: computerName(),
            keyboard: .ansi,
            builtInPtPerMM: display?.ptPerMM,
            builtInDisplayMM: display?.sizeMM,
            fnTapAction: fnTapAction(),
            capsSwitchesInputSource: (appValue("TISRomanSwitchState", domain: toolboxDomain) as? Int).map { $0 != 0 },
            enabledInputSourceCount: enabledInputSourceCount())
    }

    private static let trackpadDomain = "com.apple.AppleMultitouchTrackpad"
    private static let hotKeysDomain = "com.apple.symbolichotkeys"
    private static let toolboxDomain = "com.apple.HIToolbox"

    // MARK: Preferences

    private static func readPreferences() -> MacInputPreferences {
        let defaults = UserDefaults.standard
        var prefs = MacInputPreferences()
        let delay = NSEvent.keyRepeatDelay
        prefs.keyRepeatDelay = delay > 2.0 ? nil : delay
        prefs.keyRepeatInterval = NSEvent.keyRepeatInterval
        // object(forKey:) tells absent from present; bool/double(forKey:) also parse values that
        // an untyped `defaults write` stored as strings ("3", "YES").
        let hasScrollDirection = defaults.object(forKey: "com.apple.swipescrolldirection") != nil
        prefs.naturalScrolling = hasScrollDirection ? defaults.bool(forKey: "com.apple.swipescrolldirection") : true
        let hasScaling = defaults.object(forKey: "com.apple.trackpad.scaling") != nil
        prefs.trackingIndex = hasScaling ? defaults.double(forKey: "com.apple.trackpad.scaling") : 0.6875
        prefs.fnKeysStandard = defaults.bool(forKey: "com.apple.keyboard.fnState")
        prefs.doubleClickInterval = NSEvent.doubleClickInterval
        // Low confidence: these keys hold the built-in trackpad's settings on current macOS.
        // Absent keys keep MacInputPreferences' defaults, except Clicking: macOS ships with Tap
        // to click off, while the wire default is on.
        func trackpadFlag(_ key: String) -> Bool? {
            let value = appValue(key, domain: trackpadDomain)
            if let number = value as? Int { return number != 0 }
            if let text = value as? String { return (text as NSString).boolValue }
            return nil
        }
        if let value = trackpadFlag("TrackpadThreeFingerDrag") { prefs.threeFingerDrag = value }
        if let value = trackpadFlag("DragLock") { prefs.dragLock = value }
        prefs.tapToClick = trackpadFlag("Clicking") ?? false
        if let value = trackpadFlag("TrackpadThreeFingerHorizSwipeGesture") { prefs.threeFingerSwipes = value }
        // `defaults write` can store values System Settings never offers; the wire rejects them.
        return prefs.clamped()
    }

    private static func appValue(_ key: String, domain: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }

    /// AppleFnUsageType: 0 do nothing, 1 change input source, 2 emoji & symbols, 3 dictation
    /// (low-confidence mapping; dictation cannot be posted, so it maps to .none).
    private static func fnTapAction() -> FnTapAction? {
        switch appValue("AppleFnUsageType", domain: toolboxDomain) as? Int {
        case 0, 3: return FnTapAction.none
        case 1: return .changeInputSource
        case 2: return .emojiAndSymbols
        default: return nil
        }
    }

    private static func enabledInputSourceCount() -> Int {
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() else { return 0 }
        return CFArrayGetCount(list)
    }

    // MARK: Live HID curves (medium confidence)

    private static func readLiveCurves() -> LiveCurves {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return LiveCurves() }
        defer { IOObjectRelease(iterator) }
        var fallback: LiveCurves?
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard hidProperty(service, "HIDPointerAccelerationType") as? String == "HIDTrackpadAcceleration" else { continue }
            let curves = LiveCurves(
                pointer: (hidProperty(service, "HIDAccelCurves") as? [[String: Any]]).flatMap(HIDCurveTables.parse),
                scroll: (hidProperty(service, "HIDScrollAccelCurves") as? [[String: Any]]).flatMap(HIDCurveTables.parse),
                trackingIndex: (hidProperty(service, "HIDTrackpadAcceleration") as? NSNumber).flatMap(trackingIndex))
            // A Magic Trackpad may be attached too; the built-in one is the deck being mirrored.
            if hidProperty(service, "Built-In") as? Bool == true { return curves }
            if fallback == nil { fallback = curves }
        }
        return fallback ?? LiveCurves()
    }

    /// A service property, looked up directly and then in its HIDEventServiceProperties dictionary.
    private static func hidProperty(_ service: io_service_t, _ key: String) -> Any? {
        if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() {
            return value
        }
        let nested = IORegistryEntryCreateCFProperty(service, "HIDEventServiceProperties" as CFString,
                                                     kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (nested as? [String: Any])?[key]
    }

    /// HIDTrackpadAcceleration is 16.16 fixed point when integral.
    private static func trackingIndex(_ number: NSNumber) -> Double? {
        let value = CFNumberIsFloatType(number as CFNumber) ? number.doubleValue
            : HIDCurveTables.fixedToDouble(number.int64Value)
        return value.isFinite && value >= 0 ? value : nil
    }

    // MARK: Hardware

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func computerName() -> String {
        let name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ""
        return name.isEmpty ? "Mac" : name
    }

    /// The active built-in display (it need not be the main display), or nil when the lid is
    /// closed or the size is unknown.
    private static func builtInDisplay() -> (ptPerMM: Double, sizeMM: [Double])? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        guard let display = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return nil }
        let size = CGDisplayScreenSize(display)
        let bounds = CGDisplayBounds(display)
        guard size.width > 0, size.height > 0, bounds.width > 0 else { return nil }
        return (Double(bounds.width / size.width), [Double(size.width), Double(size.height)])
    }
}
