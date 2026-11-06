import SwiftUI
import UIKit
import os
import IKeyCore

@main
struct IKeyPadApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = PadModel()

    var body: some Scene {
        WindowGroup { PadRootView(model: model, orientation: appDelegate) }
    }
}

/// The chrome-free root (F12). While healthy only the deck shows. Problems show as the Touch ID ring,
/// a quiet hint above the function row and, when pairing is needed, the pairing card on the left palm
/// rest. Settings open by holding Touch ID (or the deck's VoiceOver action), also while disconnected.
struct PadRootView: View {
    @ObservedObject var model: PadModel
    @ObservedObject var orientation: AppDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("iKey.touchIDHintShown.v1") private var touchIDHintShown = false

    /// Advanced only at the next status threshold (see `runClock`), so the deck is not re-rendered
    /// on a fixed tick.
    @State private var clock = uptime()
    /// The deck surface's own resolution, before the rotation guard.
    @State private var surfaceProjection: ProjectionResolution?
    @State private var messageSince: Double?
    @State private var touchIDHintUntil: Double?
    /// The pairing problem the card answers, kept through the automatic retries (`.connecting`,
    /// `.awaitingWelcome`) that needsRepair and macTooOld make every 10 s, so the card, ring and hint
    /// stay put while the user types a key. Use `pairingEpisode`, which is also right in the frame
    /// the link state changes.
    @State private var lastEpisode: PairingCard.Episode?
    /// "Keep waiting" in needsRepair: hides the card for the rest of that repair episode.
    @State private var keepWaiting = false
    /// The panel sheet is on screen (until its dismissal finishes).
    @State private var panelSheetUp = false
    /// Drives the Fit & Size cover, which appears only once the panel sheet is gone; input stays
    /// paused across the hand-over because `model.isFitPresented` is already true.
    @State private var fitCoverUp = false

    private enum Timing {
        static let ringConnecting = 0.4
        static let problemHint = 5.0
        static let ringWaiting = 10.0
        static let messageHint = 8.0
        static let touchIDHint = 3.0
    }

    var body: some View {
        ZStack {
            deck.ignoresSafeArea()
            if !model.isFitPresented {
                GeometryReader { proxy in hints(in: proxy.size) }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.25), value: touchIDHintVisible)
                if showsPairingCard {
                    // Keyboard avoidance stays on, so the card moves up above the software keyboard.
                    GeometryReader { proxy in pairingCard(in: proxy.size) }
                        .ignoresSafeArea(.container)
                }
            }
        }
        .background(Color.black)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .sheet(isPresented: $model.isPanelPresented, onDismiss: panelDismissed) {
            DeckPanelView(model: model, onFitAndSize: {
                // Input stays paused (isFitPresented) while the sheet animates away; the cover itself
                // is presented once the sheet is gone, since two presentations cannot overlap.
                model.isFitPresented = true
                model.isPanelPresented = false
            })
        }
        .fullScreenCover(isPresented: fitCoverBinding) {
            FitAndSizeView(model: model, onDone: { model.isFitPresented = false })
                .presentationBackground(.clear)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .all)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.scenePhaseChanged(phase)
            if phase == .active { orientation.attachScene() }
        }
        .onChange(of: model.isConnected, initial: true) { _, connected in
            orientation.linkChanged(connected: connected)
            if connected { showTouchIDHintOnce() }
        }
        .onChange(of: orientation.isRotatedAway) { _, _ in reportProjection() }
        .onChange(of: model.message, initial: true) { _, message in
            messageSince = message == nil ? nil : uptime()
        }
        .onChange(of: model.isPanelPresented, initial: true) { _, shown in
            if shown { panelSheetUp = true }
        }
        .onChange(of: model.isFitPresented, initial: true) { _, fit in
            if !fit {
                fitCoverUp = false
            } else if !panelSheetUp {
                fitCoverUp = true
            }
        }
        .onChange(of: model.linkState, initial: true) { _, _ in lastEpisode = pairingEpisode }
        .onChange(of: pairingEpisode?.kind, initial: true) { _, kind in
            // Kept through the episode's retries; a new episode asks again.
            if kind != .needsRepair { keepWaiting = false }
        }
        .task(id: clockKey) { await runClock() }
    }

    // MARK: Deck

    private var deck: some View {
        let appearance = model.preferences.appearance
        let drawn = appearance.mode == .drawn
            ? DrawnDeckConfig(model: model.effectiveModel, finish: model.effectiveFinish, tone: appearance.tone,
                              placement: appearance.placement, iPadOverrideID: appearance.iPadOverrideID,
                              pressLook: PressLook(rawValue: appearance.pressLook.rawValue) ?? .subtle)
            : nil
        return DeckSurface(
            image: model.photo,
            layout: model.layout,
            inputEnabled: true,
            resetGeneration: model.resetGeneration,
            showRegions: false,
            selectedKeyID: nil,
            protection: model.touchProtection,
            showTouchIndicators: model.showTouchIndicators,
            onEvent: { model.send($0) },
            drawn: drawn,
            previewPlacement: model.previewPlacement,
            inputMode: model.deckInputMode,
            typing: model.effectiveTyping,
            trackpad: model.effectiveTrackpad,
            panelTriggerRaw: model.preferences.panelTriggerRaw,
            capsLockOn: model.capsLockOn,
            statusRing: ringStyle,
            dimmed: model.isPanelPresented,
            keyboardGlow: model.keyboardGlowLevel,
            onInputs: { model.send($0, at: $1) },
            onRequestPanel: { model.isPanelPresented = true },
            onHeldSnapshot: { model.updateHeldSnapshot(keys: $0, buttons: $1, active: $2) },
            onTouchWhileDisabled: { model.deckTouchedWhileDisconnected() },
            onProjectionResolved: { resolution in
                surfaceProjection = resolution
                reportProjection()
            })
    }

    /// Reports the surface's resolution to the model. An unexpected rotation counts as windowed, so the
    /// model pauses input exactly as for a windowed scene.
    private func reportProjection() {
        guard let r = surfaceProjection else { return }
        if orientation.isRotatedAway && r.fit != .windowed {
            model.projectionResolved(ProjectionResolution(display: r.display, fit: .windowed, projection: r.projection))
        } else {
            model.projectionResolved(r)
        }
    }

    private func panelDismissed() {
        panelSheetUp = false
        if model.isFitPresented { fitCoverUp = true }
    }

    private var fitCoverBinding: Binding<Bool> {
        Binding(get: { fitCoverUp }, set: { shown in
            fitCoverUp = shown
            if !shown { model.isFitPresented = false }
        })
    }

    // MARK: Status

    private var isDrawn: Bool { model.preferences.appearance.mode == .drawn }

    /// needsRepair or macTooOld, including the automatic retries those states make (the supervisor
    /// goes through `.connecting`/`.awaitingWelcome` and back while its hold lasts). Ends on
    /// `.connected`, `.unpaired`, `.replaced`, or `.backoff`, which the supervisor only enters once
    /// the hold is gone (the stored key worked, or the Mac now advertises protocol 2).
    private var pairingEpisode: PairingCard.Episode? {
        switch model.linkState {
        case .needsRepair, .macTooOld:
            return PairingCard.Episode(linkState: model.linkState, status: model.status)
        case .connecting, .awaitingWelcome, .suspended:
            return lastEpisode
        case .connected, .unpaired, .replaced, .backoff:
            return nil
        }
    }

    /// Seconds since the link problem began; nil counts as long-standing.
    private var problemAge: Double { model.problemSince.map { clock - $0 } ?? .infinity }

    /// Rotated, or a windowed scene: the drawn deck would draw at the wrong scale, so input pauses.
    /// Photo mode has no projection and keeps input live (`PadModel.deckInputMode`), so it shows
    /// neither guard.
    private var isDeckGuarded: Bool {
        isDrawn && (orientation.isRotatedAway || model.projection?.fit == .windowed)
    }

    private var ringStyle: StatusRingStyle {
        if model.isPanelPresented || model.isFitPresented { return .paused }
        switch model.linkState {
        case .connected:
            return isDeckGuarded ? .paused : .live
        case .suspended:
            return .paused
        case .unpaired, .needsRepair, .macTooOld:
            return .needsAction
        case .replaced:
            return .waiting
        case .backoff, .connecting, .awaitingWelcome:
            // A needsRepair / macTooOld retry still needs the user.
            if pairingEpisode != nil { return .needsAction }
            // A quick reconnect (Control Center, a short drop) never shows the ring.
            if problemAge < Timing.ringConnecting { return .live }
            return problemAge < Timing.ringWaiting ? .connecting : .waiting
        }
    }

    /// The top-band hint: guards at once, the result of a pairing action briefly, link problems after
    /// 5 s, and the scaled-drawing note while it applies.
    private var hintText: String? {
        if isDrawn, orientation.isRotatedAway {
            return orientation.interfaceOrientation.isPortrait
                ? "Turn iPad back to landscape"
                : "Turn iPad back around, or choose Flip 180° in iKey settings"
        }
        if isDrawn, model.projection?.fit == .windowed { return "Make iKey full screen" }
        if !showsPairingCard, let message = model.message, let since = messageSince,
           clock - since < Timing.messageHint {
            return message
        }
        if let link = linkHint, problemAge >= Timing.problemHint { return link }
        if isDrawn, model.projection?.fit == .unknownDevice {
            return "This iPad isn't a 13-inch model — drawing is scaled"
        }
        return nil
    }

    private var linkHint: String? {
        switch model.linkState {
        case .backoff, .connecting, .awaitingWelcome:
            if let episode = pairingEpisode { return episode.status }
            // A first pairing attempt shows its progress in the card.
            guard model.isPaired else { return nil }
            if model.lastGoodbye == .macSleeping { return "\(model.macName ?? "MacBook Air") is asleep" }
            return "Waiting for \(model.macName ?? "your Mac"). Wake it or open iKey on the Mac."
        case .replaced:
            return model.lastGoodbye == .replaced
                ? "In use by another iPad — touch to switch"
                : "Disconnected — touch the deck to reconnect"
        case .macTooOld, .needsRepair:
            return pairingEpisode?.status ?? model.status
        case .connected, .suspended, .unpaired:
            return nil
        }
    }

    private var showsPairingCard: Bool {
        switch model.linkState {
        case .unpaired: return true
        case .connected, .suspended, .replaced: return false
        case .needsRepair, .macTooOld, .connecting, .awaitingWelcome, .backoff:
            // Kept through the episode's retries and the card's own attempt, so its progress and
            // result show in place and a key being typed is not torn down.
            if let episode = pairingEpisode { return !(episode.kind == .needsRepair && keepWaiting) }
            // A first pairing attempt (unpaired) keeps the card too.
            return !model.isPaired
        }
    }

    private var touchIDHintVisible: Bool { touchIDHintUntil.map { clock < $0 } ?? false }

    private func showTouchIDHintOnce() {
        guard !touchIDHintShown else { return }
        touchIDHintShown = true
        touchIDHintUntil = uptime() + Timing.touchIDHint
    }

    // MARK: Clock

    private struct ClockKey: Equatable {
        var link: LinkState
        var problemSince: Double?
        var messageSince: Double?
        var touchIDHintUntil: Double?
    }

    private var clockKey: ClockKey {
        ClockKey(link: model.linkState, problemSince: model.problemSince, messageSince: messageSince,
                 touchIDHintUntil: touchIDHintUntil)
    }

    /// Wakes at each upcoming threshold (ring 0.4 s and 10 s, hint 5 s, message 8 s, Touch ID hint
    /// 3 s) and stops when none is left; a change of any input restarts it.
    private func runClock() async {
        while !Task.isCancelled {
            let now = uptime()
            clock = now
            var deadlines: [Double] = []
            if let since = model.problemSince {
                deadlines += [Timing.ringConnecting, Timing.problemHint, Timing.ringWaiting].map { since + $0 }
            }
            if let since = messageSince { deadlines.append(since + Timing.messageHint) }
            if let until = touchIDHintUntil { deadlines.append(until) }
            guard let next = deadlines.filter({ $0 > now }).min() else { return }
            try? await Task.sleep(nanoseconds: UInt64((next - now) * 1e9) + 1_000_000)
        }
    }

    // MARK: Overlays

    /// The drawn deck's projection (view points) and spec; nil in photo mode or before layout.
    private var deckGeometry: (projection: DeckProjection, spec: DeckSpec)? {
        guard isDrawn, let resolution = model.projection else { return nil }
        return (resolution.projection, model.effectiveModel.spec)
    }

    /// The deck surface a hint is drawn on, which its colour is derived from.
    private enum Backdrop { case deck, well, trackpad }

    private struct HintSpot {
        var centre: CGPoint
        var width: CGFloat
        var lines: Int
        var backdrop: Backdrop
    }

    /// The room an 11-pt line needs above the function row.
    private static let hintBandMinimum: CGFloat = 16

    /// Centred above the function row (within the top 30 pt) when the line fits there. The default
    /// screen-centred placement starts the screen inside the keyboard well only 7-11 pt above the
    /// function row, so the hint then sits near the top of the right palm rest (right of the trackpad;
    /// the left palm rest holds the pairing card and the two-finger settings hold) instead of over
    /// the F-keys.
    private func hintSpot(in size: CGSize) -> HintSpot {
        let fullWidth = max(size.width - 32, 0)
        guard let g = deckGeometry else {
            return HintSpot(centre: CGPoint(x: size.width / 2, y: 15), width: fullWidth, lines: 1, backdrop: .deck)
        }
        let fRowTop = g.projection.point(MMPoint(x: g.spec.keyField.midX, y: g.spec.functionRowTopY)).y
        let well = g.projection.rect(g.spec.well)
        if fRowTop >= Self.hintBandMinimum {
            let y = min(fRowTop, 30) / 2
            return HintSpot(centre: CGPoint(x: size.width / 2, y: y), width: fullWidth, lines: 1,
                            backdrop: y >= well.minY ? .well : .deck)
        }
        let trackpad = g.projection.rect(g.spec.trackpad)
        let rest = CGRect(x: trackpad.maxX, y: well.maxY,
                          width: size.width - trackpad.maxX, height: size.height - well.maxY)
        guard rest.width >= 160, rest.height >= 48 else {
            // No usable palm rest (an extreme nudge): the top of the screen, over the well.
            return HintSpot(centre: CGPoint(x: size.width / 2, y: 8), width: fullWidth, lines: 1, backdrop: .well)
        }
        return HintSpot(centre: CGPoint(x: rest.midX, y: rest.minY + min(rest.height / 2, 40)),
                        width: rest.width - 32, lines: 2, backdrop: .deck)
    }

    @ViewBuilder private func hints(in size: CGSize) -> some View {
        if let text = hintText {
            let spot = hintSpot(in: size)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hintColor(on: spot.backdrop))
                .multilineTextAlignment(.center)
                .lineLimit(spot.lines)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: spot.width)
                .position(spot.centre)
        }
        if touchIDHintVisible {
            let geometry = deckGeometry
            let trackpad = geometry.map { $0.projection.rect($0.spec.trackpad) }
            Text(settingsGestureHint)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hintColor(on: .trackpad))
                .multilineTextAlignment(.center)
                .frame(maxWidth: trackpad.map { max($0.width - 24, 0) } ?? 320)
                .position(x: trackpad?.midX ?? size.width / 2, y: trackpad?.midY ?? size.height * 0.75)
                .transition(.opacity)
        }
    }

    /// The drawn deck opens settings from Touch ID; photo mode and the palm-rest trigger use a
    /// two-finger hold on the left palm rest.
    private var usesTouchIDTrigger: Bool {
        isDrawn && (PanelTrigger(rawValue: model.preferences.panelTriggerRaw) ?? .touchIDHold) == .touchIDHold
    }

    private var settingsGestureHint: String {
        usesTouchIDTrigger
            ? "Hold the Touch ID key for iKey settings"
            : "Hold two fingers on the left palm rest for iKey settings"
    }

    /// The colour of the surface behind the hint, 25 % HSL lightness away from it: darker, unless
    /// lighter contrasts more (Midnight, and dark finishes at night, where darker would vanish).
    private func hintColor(on backdrop: Backdrop) -> Color {
        guard isDrawn else { return Color(white: 0.6) }
        let palette = DeckPalette.palette(model.effectiveFinish, tone: model.preferences.appearance.tone,
                                          night: model.keyboardGlowLevel)
        let surface: RGBA
        switch backdrop {
        case .deck: surface = palette.deck
        case .well: surface = palette.wellFloor
        case .trackpad: surface = palette.trackpad
        }
        let ink = HintInk.colour(on: surface)
        return Color(.sRGB, red: ink.r, green: ink.g, blue: ink.b, opacity: 1)
    }

    /// About 355 x 412 pt, centred on the left palm rest (left of the trackpad, below the keyboard),
    /// kept on screen and above the software keyboard (`size` excludes it).
    private func pairingCard(in size: CGSize) -> some View {
        let margin: CGFloat = 16
        let region: CGRect
        if let g = deckGeometry {
            let well = g.projection.rect(g.spec.well), trackpad = g.projection.rect(g.spec.trackpad)
            region = CGRect(x: 0, y: well.maxY, width: max(trackpad.minX, 0), height: max(size.height - well.maxY, 0))
        } else {
            region = CGRect(x: 0, y: size.height / 2, width: size.width / 3, height: size.height / 2)
        }
        let width = min(355, max(region.width - 2 * margin, 280))
        let height = min(412, max(region.height - 2 * margin, 300))
        let x = min(max(region.midX, margin + width / 2), max(size.width - margin - width / 2, margin + width / 2))
        let y = min(max(region.midY, margin + height / 2), max(size.height - margin - height / 2, margin + height / 2))
        // The card covers the left palm rest, where the two-finger settings hold lives, so that
        // trigger gets a button on the card instead.
        let openSettings: (() -> Void)? = usesTouchIDTrigger ? nil : { model.isPanelPresented = true }
        return PairingCard(model: model, episode: pairingEpisode,
                           onKeepWaiting: { keepWaiting = true }, onSettings: openSettings)
            .frame(width: width, height: height)
            .position(x: x, y: y)
    }
}

private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

/// The quiet hint ink: the surface colour 25 % HSL lightness darker, or lighter when that contrasts
/// more with the surface (WCAG contrast ratio).
private enum HintInk {
    static let lightnessShift = 0.25

    static func colour(on surface: RGBA) -> RGBA {
        let darker = shifted(surface, by: -lightnessShift), lighter = shifted(surface, by: lightnessShift)
        return contrast(darker, surface) >= contrast(lighter, surface) ? darker : lighter
    }

    static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        let la = a.relativeLuminance, lb = b.relativeLuminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The colour with its HSL lightness moved by `delta` (hue and saturation kept).
    static func shifted(_ c: RGBA, by delta: Double) -> RGBA {
        let r = min(max(c.r, 0), 1), g = min(max(c.g, 0), 1), b = min(max(c.b, 0), 1)
        let hi = max(r, g, b), lo = min(r, g, b), chroma = hi - lo
        let lightness = (hi + lo) / 2
        var hue = 0.0, saturation = 0.0
        if chroma > 0 {
            saturation = min(chroma / max(1 - abs(2 * lightness - 1), 1e-9), 1)
            if hi == r {
                hue = ((g - b) / chroma).truncatingRemainder(dividingBy: 6)
            } else if hi == g {
                hue = (b - r) / chroma + 2
            } else {
                hue = (r - g) / chroma + 4
            }
            if hue < 0 { hue += 6 }
        }
        let l = min(max(lightness + delta, 0), 1)
        let c2 = (1 - abs(2 * l - 1)) * saturation
        let x = c2 * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let rgb: (r: Double, g: Double, b: Double)
        switch hue {
        case ..<1: rgb = (c2, x, 0)
        case ..<2: rgb = (x, c2, 0)
        case ..<3: rgb = (0, c2, x)
        case ..<4: rgb = (0, x, c2)
        case ..<5: rgb = (x, 0, c2)
        default: rgb = (c2, 0, x)
        }
        let m = l - c2 / 2
        return RGBA(r: min(max(rgb.r + m, 0), 1), g: min(max(rgb.g + m, 0), 1), b: min(max(rgb.b + m, 0), 1), a: c.a)
    }
}

private let orientationLog = Logger(subsystem: "com.ikey.pad", category: "orientation")

/// Best-effort orientation guard (F12). While connected the interface is held on the landscape side it
/// is on; a rotation the system makes anyway, or portrait, is published so the shell pauses input.
/// "Flip 180°" in the panel posts the "iKeyFlipOrientation" notification, handled here.
final class AppDelegate: NSObject, UIApplicationDelegate, ObservableObject {
    @Published private(set) var interfaceOrientation: UIInterfaceOrientation = .unknown
    /// The landscape side the interface is held on; nil allows both.
    @Published private(set) var lockedSide: UIInterfaceOrientation?

    private var connected = false
    /// A flip holds its side across a disconnect until the next connection.
    private var heldByFlip = false
    private weak var scene: UIWindowScene?
    private var geometryObservation: NSKeyValueObservation?

    /// Portrait, or the landscape side opposite the held one.
    var isRotatedAway: Bool {
        if interfaceOrientation.isPortrait { return true }
        guard let lockedSide, interfaceOrientation.isLandscape else { return false }
        return interfaceOrientation != lockedSide
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationCenter.default.addObserver(self, selector: #selector(flipRequested(_:)),
                                               name: Notification.Name("iKeyFlipOrientation"), object: nil)
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.mask(for: lockedSide)
    }

    /// Holds the current landscape side on connect; releases it on disconnect unless a flip holds it.
    func linkChanged(connected: Bool) {
        attachScene()
        guard connected != self.connected else { return }
        self.connected = connected
        if connected {
            heldByFlip = false
            lock(to: interfaceOrientation.isLandscape ? interfaceOrientation : nil)
        } else if !heldByFlip {
            lock(to: nil)
        }
    }

    /// Starts following the window scene's geometry (once a scene exists).
    func attachScene() {
        guard scene == nil,
              let found = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene = found
        geometryObservation = found.observe(\.effectiveGeometry, options: [.initial, .new]) { [weak self] scene, _ in
            MainActor.assumeIsolated { _ = self?.geometryChanged(scene) }
        }
    }

    private func geometryChanged(_ scene: UIWindowScene) {
        let orientation = scene.effectiveGeometry.interfaceOrientation
        if orientation != interfaceOrientation { interfaceOrientation = orientation }
    }

    /// Turns the deck to the other landscape side, or, after a rotation the lock did not stop, accepts
    /// the side the interface is now on.
    @objc private func flipRequested(_ note: Notification) {
        attachScene()
        let current = interfaceOrientation
        guard current.isLandscape else { return }
        heldByFlip = true
        lock(to: isRotatedAway ? current : (current == .landscapeLeft ? .landscapeRight : .landscapeLeft))
    }

    private func lock(to side: UIInterfaceOrientation?) {
        lockedSide = side
        guard let scene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: Self.mask(for: side))) { [weak self] error in
            orientationLog.notice("Orientation request refused: \(error.localizedDescription, privacy: .public)")
            let owner = self
            Task { @MainActor in owner?.geometryRequestRefused() }
        }
    }

    /// Keeps the side the interface is on instead of pausing the deck on a side it cannot reach.
    private func geometryRequestRefused() {
        guard let lockedSide, interfaceOrientation.isLandscape, interfaceOrientation != lockedSide else { return }
        self.lockedSide = interfaceOrientation
    }

    private static func mask(for side: UIInterfaceOrientation?) -> UIInterfaceOrientationMask {
        switch side {
        case .landscapeLeft?: return .landscapeLeft
        case .landscapeRight?: return .landscapeRight
        default: return .landscape
        }
    }
}
