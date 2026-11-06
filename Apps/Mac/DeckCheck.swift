import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// 'Deck check': counts this Mac's own keyboard and trackpad events while the user types on
/// iKey, to see whether the real keys and trackpad under the iPad register. iKey's own events
/// carry eventSourceUserData 0x694B6579 and are not counted. A listen-only session event tap
/// (Input Monitoring permission), removed on stop. Counts are by event type only; no key codes
/// or positions are kept. Main-queue confined.
///
/// Events are counted after `stopGrace`: a manual Stop drops the events of its last second, so the
/// Mac's own trackpad click (and the move to the button) that pressed Stop is not counted. Known
/// extra counts: the hardware Caps Lock that iKey sets can show as a modifier change, and a v1
/// iPad's input is not tagged as iKey's.
final class DeckCheck: ObservableObject {
    /// Event type name (see `countedTypes`) → events seen.
    @Published private(set) var counts: [String: Int] = [:]
    @Published private(set) var running = false
    /// When the running check ends by itself.
    @Published private(set) var endsAt: Date?
    /// The last start found no Input Monitoring permission.
    @Published private(set) var needsPermission = false
    /// How long the last check ran, once it has ended.
    @Published private(set) var lastDuration: TimeInterval?

    /// The counted event types in display order (type 29 is the trackpad gesture event).
    static let countedTypes: [(name: String, type: UInt32)] = [
        ("keyDown", CGEventType.keyDown.rawValue),
        ("flagsChanged", CGEventType.flagsChanged.rawValue),
        ("mouseMoved", CGEventType.mouseMoved.rawValue),
        ("leftMouseDown", CGEventType.leftMouseDown.rawValue),
        ("leftMouseUp", CGEventType.leftMouseUp.rawValue),
        ("leftMouseDragged", CGEventType.leftMouseDragged.rawValue),
        ("rightMouseDown", CGEventType.rightMouseDown.rawValue),
        ("rightMouseUp", CGEventType.rightMouseUp.rawValue),
        ("rightMouseDragged", CGEventType.rightMouseDragged.rawValue),
        ("scrollWheel", CGEventType.scrollWheel.rawValue),
        ("gesture", 29),
    ]

    private static let iKeyUserData: Int64 = 0x694B6579
    private static let names = Dictionary(uniqueKeysWithValues: countedTypes.map { ($0.type, $0.name) })
    private static let eventMask = countedTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.type)) }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var startedAt: Date?
    private var endWork: DispatchWorkItem?
    /// Counted in the tap callback and published a few times a second (pointer moves arrive at
    /// the display rate).
    private var tally: [String: Int] = [:]
    /// Seen but not yet counted (younger than `stopGrace`), oldest first.
    private var recent: [(at: TimeInterval, name: String)] = []
    private var publishTimer: Timer?
    private static let stopGrace: TimeInterval = 1

    deinit {
        stop()
    }

    func start(duration: TimeInterval = 120) {
        stop()
        guard CGPreflightListenEventAccess() || CGRequestListenEventAccess(),
              let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: Self.eventMask,
                                          callback: Self.callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            needsPermission = true
            return
        }
        needsPermission = false
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source

        tally = Dictionary(uniqueKeysWithValues: Self.countedTypes.map { ($0.name, 0) })
        recent = []
        counts = tally
        lastDuration = nil
        let now = Date()
        startedAt = now
        endsAt = now.addingTimeInterval(duration)
        running = true

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.publishTally() }
        RunLoop.main.add(timer, forMode: .common)
        publishTimer = timer
        let work = DispatchWorkItem { [weak self] in self?.finish(countingRecent: true) }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Removes the tap and keeps the counts, without the events of the last `stopGrace` seconds
    /// (the click that chose Stop).
    func stop() {
        finish(countingRecent: false)
    }

    /// `countingRecent`: the check ran its full time, so every event seen counts.
    private func finish(countingRecent: Bool) {
        endWork?.cancel()
        endWork = nil
        publishTimer?.invalidate()
        publishTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        guard running else { return }
        publishTally(countingAll: countingRecent)
        recent = []
        lastDuration = startedAt.map {
            max(0, Date().timeIntervalSince($0) - (countingRecent ? 0 : Self.stopGrace))
        }
        startedAt = nil
        endsAt = nil
        running = false
    }

    /// The counts as plain text for device-validation notes.
    var resultText: String {
        let elapsed = lastDuration ?? startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let seconds = Int(elapsed.rounded())
        var lines = ["iKey Deck check: \(seconds / 60) min \(seconds % 60) s, this Mac's own input events (iKey's excluded)"]
        for (name, _) in Self.countedTypes { lines.append("\(name): \(counts[name] ?? 0)") }
        lines.append("(Not counted: the last second before a manual Stop. May be counted: the hardware Caps Lock iKey sets as flagsChanged, a v1 iPad's input.)")
        return lines.joined(separator: "\n")
    }

    func copyResult() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(resultText, forType: .string)
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Tap

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        if let userInfo {
            Unmanaged<DeckCheck>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if running, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard running, event.getIntegerValueField(.eventSourceUserData) != Self.iKeyUserData,
              let name = Self.names[type.rawValue] else { return }
        recent.append((ProcessInfo.processInfo.systemUptime, name))
    }

    /// Counts the events older than `stopGrace` (all of them with `countingAll`) and publishes.
    private func publishTally(countingAll: Bool = false) {
        let cutoff = countingAll ? TimeInterval.infinity : ProcessInfo.processInfo.systemUptime - Self.stopGrace
        var counted = 0
        for event in recent {
            guard event.at <= cutoff else { break }
            tally[event.name, default: 0] += 1
            counted += 1
        }
        recent.removeFirst(counted)
        if tally != counts { counts = tally }
    }
}

/// The 'Deck check' window.
struct DeckCheckView: View {
    @ObservedObject var check: DeckCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Counts this Mac's own keyboard and trackpad events. iKey's input is not counted, so with nothing else touching the Mac every count stays at 0. Let the timer run out, or press Stop with iKey's trackpad; the last second before Stop is not counted.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Lay the iPad on the keyboard and type firmly on iKey for 2 minutes, including near the corners.")
                .bold()
                .fixedSize(horizontal: false, vertical: true)
            if check.needsPermission {
                Text("Allow iKey in System Settings → Privacy & Security → Input Monitoring, then start again (if it still fails, quit and reopen iKey).")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Input Monitoring Settings") { check.openInputMonitoringSettings() }
            }
            HStack {
                Button(check.running ? "Stop" : "Start") {
                    if check.running { check.stop() } else { check.start() }
                }
                .buttonStyle(.borderedProminent)
                if let endsAt = check.endsAt {
                    TimelineView(.periodic(from: Date(), by: 1)) { context in
                        Text(Self.remaining(until: endsAt, now: context.date))
                            .font(.callout.monospacedDigit())
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(DeckCheck.countedTypes.map { $0.name }, id: \.self) { name in
                    GridRow {
                        Text(Self.label(name))
                        Text(check.counts[name].map { String($0) } ?? "–")
                            .font(.body.monospacedDigit())
                            .foregroundStyle((check.counts[name] ?? 0) > 0 ? Color.orange : Color.primary)
                    }
                }
            }
            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Copy Result") { check.copyResult() }
                    .disabled(check.counts.isEmpty || check.running)
            }
        }
        .padding(18)
        .frame(minWidth: 420)
    }

    private var summary: String {
        guard !check.counts.isEmpty else { return "Not run yet." }
        let total = check.counts.values.reduce(0, +)
        if check.running { return "\(total) events so far (counted after 1 s)." }
        return total == 0 ? "No events from the Mac's own keyboard or trackpad."
            : "\(total) events from the Mac's own input. A few modifier changes can come from the Caps Lock iKey sets; a v1 iPad's input also counts."
    }

    private static func remaining(until end: Date, now: Date) -> String {
        let left = max(0, Int(end.timeIntervalSince(now).rounded()))
        return String(format: "%ld:%02ld left", left / 60, left % 60)
    }

    private static func label(_ name: String) -> String {
        switch name {
        case "keyDown": return "Key presses"
        case "flagsChanged": return "Modifier changes"
        case "mouseMoved": return "Pointer moves"
        case "leftMouseDown": return "Clicks (down)"
        case "leftMouseUp": return "Clicks (up)"
        case "leftMouseDragged": return "Drags"
        case "rightMouseDown": return "Secondary clicks (down)"
        case "rightMouseUp": return "Secondary clicks (up)"
        case "rightMouseDragged": return "Secondary drags"
        case "scrollWheel": return "Scrolls"
        case "gesture": return "Trackpad gestures"
        default: return name
        }
    }
}
