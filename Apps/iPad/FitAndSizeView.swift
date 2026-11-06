import SwiftUI
import UIKit
import IKeyCore

/// Full-screen Fit & Size over the live deck (input stays suspended while `isFitPresented`).
///
/// The true-scale check is the setup part: a drawn 200 mm and 150 mm ruler, an ID-1 card outline on the
/// trackpad and the A→' and `→= key spans, all drawn through `model.projection`, the exact resolution
/// the deck surface uses. Checking the position against a real MacBook (measured distances and the
/// peek check) is optional and collapsed. Nudges go to `model.previewPlacement` at once and are
/// committed to `preferences.appearance.placement` 250 ms after the last change and on Done.
struct FitAndSizeView: View {
    @ObservedObject var model: PadModel
    var onDone: () -> Void

    /// The placement being edited, without the peek shift.
    @State private var draft = DeckPlacement()
    @State private var started = false
    @State private var ended = false
    @State private var edited = false
    @State private var commitTask: Task<Void, Never>?
    /// mm the iPad was slid toward the user for the peek check; 0 when not peeking.
    @State private var peekShiftMM = 0.0
    @State private var showSize = false
    @State private var cardVerdict: CardVerdict?
    @State private var compareExpanded = false
    @State private var showPositionCheck = false
    @State private var positionRecord = PositionCheckRecord()
    @State private var measuredText: [String: String] = [:]
    @State private var positionResidualMM: Double?
    @State private var positionMessage: String?

    private enum CardVerdict { case matches, bigger, smaller }

    private var spec: DeckSpec { model.effectiveModel.spec }

    var body: some View {
        // A ZStack, not a Group: a Group hands its modifiers to each branch, so switching from the
        // photo notice to the overlay would run onDisappear (end) and onAppear again.
        ZStack {
            if model.preferences.appearance.mode == .photo {
                photoModeNotice
            } else {
                overlay
            }
        }
        .ignoresSafeArea()
        .ignoresSafeArea(.keyboard)
        .presentationBackground(.clear)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showPositionCheck) { positionCheckSheet }
        .onAppear(perform: start)
        .onDisappear(perform: end)
        .onChange(of: model.effectiveModel) { _, newModel in modelChanged(newModel) }
    }

    // MARK: Layout

    private var overlay: some View {
        GeometryReader { proxy in
            let layout = FitLayout(resolution: model.projection, spec: spec,
                                   origin: proxy.frame(in: .global).origin, size: proxy.size)
            ZStack(alignment: .topLeading) {
                // Swallows touches between the panels so nothing reaches the deck underneath.
                Color.clear.contentShape(Rectangle())
                if let map = layout.map {
                    let drawing = FitOverlay(map: map, spec: spec, hairline: 1,
                                             references: compareExpanded ? positionRecord.measured : nil,
                                             peekTicks: peekShiftMM > 0)
                    Canvas { context, size in drawing.draw(in: &context, size: size) }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                placed(leftPanel, in: layout.left)
                placed(rightPanel(cardButtonsInPanel: layout.cardButtons == nil), in: layout.right)
                placed(nudgePad, in: layout.nudge)
                if let cardRect = layout.cardButtons {
                    placed(cardButtons, in: cardRect)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func placed<V: View>(_ view: V, in rect: CGRect) -> some View {
        view
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func panel<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Left panel: pickers, comparison with the real MacBook, provenance

    private var leftPanel: some View {
        panel {
            Text("Fit & size").font(.title3.weight(.semibold))
            Text("Lay a ruler and a bank card on the glass. At true scale the drawn ruler, the card outline and the key spans match them.")
                .font(.footnote).foregroundStyle(.secondary)
            if let warning = scaleWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            }
            LabeledContent("MacBook") { modelPicker }
            LabeledContent("Finish") {
                Picker("Finish", selection: finishChoice) {
                    ForEach(model.effectiveModel.finishes, id: \.self) { finish in
                        Text(finish.displayName).tag(finish)
                    }
                }
                .labelsHidden()
            }
            LabeledContent("iPad") {
                Picker("iPad", selection: $model.preferences.appearance.iPadOverrideID) {
                    Text("Auto (\(Self.detectedIPad()?.name ?? "not recognised"))").tag(String?.none)
                    ForEach(IPadDisplaySpec.all, id: \.id) { display in
                        Text(display.name).tag(String?.some(display.id))
                    }
                }
                .labelsHidden()
            }
            DisclosureGroup("Compare with your MacBook", isExpanded: $compareExpanded) {
                compareContent.padding(.top, 8)
            }
            Text(spec.provenance).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var modelPicker: some View {
        Picker("MacBook", selection: modelChoice) {
            Text(model.detectedMacModel.map { "Auto (detected: \($0.displayName))" } ?? "Auto")
                .tag(MacBookAirModel?.none)
            ForEach(MacBookAirModel.allCases, id: \.self) { preset in
                Text(preset.displayName).tag(MacBookAirModel?.some(preset))
            }
        }
        .labelsHidden()
    }

    @ViewBuilder private var compareContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optional. Open the lid. Lay iPad on the keyboard, screen up, front edge flush with the MacBook's front edge, and slide it until the aluminium strips on both sides look equal (about 11 mm).")
                .font(.footnote)
            Button("Position check…") { showPositionCheck = true }
            if let residual = positionResidualMM {
                residualView(residual)
            }
            Divider()
            if peekShiftMM > 0 {
                Text("Slide iPad \(Self.mm(peekShiftMM)) mm toward you. Nudge ◀ ▶ until the red marks at the top edge line up with the gaps between the real function keys behind the iPad.")
                    .font(.footnote)
                Button("I slid it back") { endPeek() }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Peek check: lines the keys up sideways against the real function-row gaps.")
                    .font(.footnote)
                Button("Start peek check") { startPeek() }
                    .disabled(availablePeekShiftMM <= 0)
            }
        }
    }

    private func residualView(_ residual: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Applied. Largest disagreement left: \(Self.mm(residual)) mm").font(.footnote)
            if residual > 1 {
                Text("Your MacBook may differ from this preset. Check the model:")
                    .font(.footnote).foregroundStyle(.orange)
                modelPicker
            }
        }
    }

    // MARK: Right panel: Done, tone, spans, card result

    /// `cardButtonsInPanel`: the trackpad has no room for them below the card outline (the deck is
    /// nudged far toward the user), so they are listed here instead of over the card.
    private func rightPanel(cardButtonsInPanel: Bool) -> some View {
        panel {
            Button(action: done) {
                Text("Done").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Tone", value: String(format: "%+.2f EV", model.preferences.appearance.tone))
                Slider(value: $model.preferences.appearance.tone, in: -0.5...0.5, step: 0.05) { Text("Tone") }
                Text("Match the aluminium beside the iPad.").font(.footnote).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Spans").font(.subheadline.weight(.semibold))
                ForEach(ScaleCheck.spanChecks(spec: spec), id: \.label) { check in
                    Text("\(check.label): \(Self.mm(check.expectedMM)) mm").font(.footnote)
                }
                Text("Rulers: 200 mm under the home row from A, 150 mm beside the trackpad.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if cardButtonsInPanel {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Card on the outline").font(.subheadline.weight(.semibold))
                    cardVerdictButtons
                }
                .buttonStyle(.bordered)
            }
            if let text = cardVerdictText {
                Text(text).font(.footnote)
            }
        }
    }

    private var cardVerdictText: String? {
        switch cardVerdict {
        case .none: return nil
        case .matches: return "True scale confirmed by the card."
        case .bigger: return "The drawing is small: tap Size + until the outline meets the card's edges."
        case .smaller: return "The drawing is large: tap Size − until the outline meets the card's edges."
        }
    }

    private var scaleWarning: String? {
        guard let resolution = model.projection else { return nil }
        switch resolution.fit {
        case .fullScreen: return nil
        case .windowed:
            // An iPad override whose screen differs from this one also resolves as windowed.
            if let overrideID = model.preferences.appearance.iPadOverrideID,
               Self.detectedIPad()?.id != overrideID {
                let name = IPadDisplaySpec.preset(id: overrideID)?.name ?? "the iPad chosen below"
                return "This iPad's screen doesn't match \(name): choose Auto under iPad. Until then the drawing is scaled and input stays paused."
            }
            return "Make iKey full screen: the drawing is scaled, so it cannot be measured."
        case .unknownDevice: return "This iPad isn't a 13-inch model: the drawing is scaled, so it cannot be measured."
        }
    }

    // MARK: Trackpad: nudge pad and card buttons

    private var nudgePad: some View {
        HStack(spacing: 8) {
            NudgeButton(systemImage: "arrowtriangle.left.fill", label: "Move deck left") { nudge(dx: 1, $0) }
            NudgeButton(systemImage: "arrowtriangle.right.fill", label: "Move deck right") { nudge(dx: -1, $0) }
            // The peek check only aligns sideways, and its preview already sits at the Y limit.
            NudgeButton(systemImage: "arrowtriangle.up.fill", label: "Move deck up") { nudge(dy: -1, $0) }
                .disabled(peekShiftMM > 0)
            NudgeButton(systemImage: "arrowtriangle.down.fill", label: "Move deck down") { nudge(dy: 1, $0) }
                .disabled(peekShiftMM > 0)
            if showSize {
                Divider().frame(height: 32)
                Button("Size −") { resize(-1) }.accessibilityLabel("Smaller")
                Button("Size +") { resize(1) }.accessibilityLabel("Larger")
            }
            Spacer(minLength: 4)
            Text(readout)
                .font(.footnote.monospacedDigit())
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .accessibilityLabel("Deck offset \(readout)")
            Button("Reset", action: reset)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The deck's shift on screen (right and up are positive) and its size.
    private var readout: String {
        "→ \(Self.signed(-draft.offsetXmm)) mm  ↑ \(Self.signed(-draft.offsetYmm)) mm\n"
            + "Size \(String(format: "%.2f", draft.scale * 100)) %"
    }

    @ViewBuilder private var cardVerdictButtons: some View {
        Button("Matches") { cardVerdict = .matches }
        Button("Card is bigger") { cardVerdict = .bigger; showSize = true }
        Button("Card is smaller") { cardVerdict = .smaller; showSize = true }
    }

    private var cardButtons: some View {
        HStack(spacing: 10) { cardVerdictButtons }
        .buttonStyle(.bordered)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Position check sheet

    private var positionCheckSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Measure these on your MacBook with a ruler before laying the iPad down.")
                }
                Section("Distances") {
                    ForEach(ScaleCheck.referenceDistances(spec: spec), id: \.id) { ref in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ref.label)
                                Text("Preset: \(Self.mm(ref.expectedMM)) mm").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            TextField("mm", text: measuredBinding(ref.id))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                            Text("mm").foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button("Apply", action: applyPositionCheck)
                    if let positionMessage {
                        Text(positionMessage).foregroundStyle(.orange)
                    }
                    if let residual = positionResidualMM {
                        residualView(residual)
                    }
                }
            }
            .navigationTitle("Position check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { showPositionCheck = false }
                }
            }
        }
        .onDisappear { saveMeasurements() }
    }

    private func measuredBinding(_ id: String) -> Binding<String> {
        Binding(get: { measuredText[id] ?? "" }, set: { measuredText[id] = $0 })
    }

    // MARK: Photo mode

    private var photoModeNotice: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            VStack(spacing: 14) {
                Text("Fit & size").font(.title3.weight(.semibold))
                Text("Fit & size checks the drawn MacBook deck. iKey is showing your photo instead.")
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Use the drawn deck") { model.preferences.appearance.mode = .drawn }
                    Button("Done", action: done).buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: Bindings

    /// nil is Auto (the model the Mac reports).
    private var modelChoice: Binding<MacBookAirModel?> {
        Binding(
            get: { model.preferences.appearance.modelIsManual ? model.preferences.appearance.model : nil },
            set: { model.noteManualModelChoice($0) })
    }

    private var finishChoice: Binding<DeckFinish> {
        Binding(get: { model.effectiveFinish }, set: { model.preferences.appearance.finish = $0 })
    }

    // MARK: Placement editing

    private func start() {
        guard !started else { return }
        started = true
        draft = model.preferences.appearance.placement.clamped(for: model.effectiveModel)
        showSize = draft.scale != 1
        model.previewPlacement = nil
        positionRecord = PositionCheckRecord.load()
        measuredText = positionRecord.measured.mapValues { Self.trimmed($0) }
    }

    private func nudge(dx: Double = 0, dy: Double = 0, _ repeating: Bool) {
        // ▲ ▼ are disabled while peeking; this also stops a repeat that was already running.
        guard dy == 0 || peekShiftMM == 0 else { return }
        let step = repeating ? DeckPlacement.repeatStepMM : DeckPlacement.stepMM
        setDraft(DeckPlacement(offsetXmm: Self.round(draft.offsetXmm + dx * step, 100),
                               offsetYmm: Self.round(draft.offsetYmm + dy * step, 100),
                               scale: draft.scale))
    }

    private func resize(_ direction: Double) {
        setDraft(DeckPlacement(offsetXmm: draft.offsetXmm, offsetYmm: draft.offsetYmm,
                               scale: Self.round(draft.scale + direction * DeckPlacement.scaleStep, 10_000)))
    }

    private func reset() {
        positionRecord.base = nil
        positionRecord.save()
        positionResidualMM = nil
        cardVerdict = nil
        showSize = false
        setDraft(DeckPlacement())
    }

    /// Clamps, previews at once (with any peek shift) and schedules the commit. Does nothing once the
    /// view has ended (a held nudge's repeat or a model change can arrive after Done), so the preview
    /// is never left set behind a closed Fit & Size.
    private func setDraft(_ placement: DeckPlacement) {
        guard started, !ended else { return }
        let clamped = placement.clamped(for: model.effectiveModel)
        // A vertical change (Reset, Apply) invalidates the slide the user made for the peek check.
        if peekShiftMM > 0, clamped.offsetYmm != draft.offsetYmm { peekShiftMM = 0 }
        draft = clamped
        edited = true
        model.previewPlacement = Self.preview(clamped, peek: peekShiftMM)
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, !ended else { return }
            commit(clamped)
        }
    }

    /// The draft was clamped for the model in effect at start; re-clamp it so the readout, the peek
    /// check and the drawn deck agree. An unedited draft is not committed (the stored placement stays
    /// as it is and the resolver clamps it the same way); an edited one is previewed and committed.
    private func modelChanged(_ newModel: MacBookAirModel) {
        guard started, !ended else { return }
        // The slide was sized for the old model's range; the user starts the peek check again.
        peekShiftMM = 0
        let clamped = draft.clamped(for: newModel)
        if edited {
            setDraft(clamped)
        } else {
            draft = clamped
            model.previewPlacement = nil
        }
    }

    private func commit(_ placement: DeckPlacement) {
        if model.preferences.appearance.placement != placement {
            model.preferences.appearance.placement = placement
        }
    }

    private static func preview(_ placement: DeckPlacement, peek: Double) -> DeckPlacement {
        DeckPlacement(offsetXmm: placement.offsetXmm, offsetYmm: placement.offsetYmm - peek, scale: placement.scale)
    }

    private func done() {
        end()
        onDone()
    }

    /// Commits the draft (a changed placement re-resolves the deck and sends one release-all) and
    /// drops the preview. Runs once, on Done or when the view goes away.
    private func end() {
        guard started, !ended else { return }
        ended = true
        commitTask?.cancel()
        commitTask = nil
        peekShiftMM = 0
        if edited { commit(draft) }
        model.previewPlacement = nil
        saveMeasurements()
    }

    // MARK: Peek check

    /// The slide for the peek check: 10 mm, less where the Y range would clamp the preview.
    private var availablePeekShiftMM: Double {
        let target = DeckPlacement(offsetXmm: draft.offsetXmm, offsetYmm: draft.offsetYmm - 10, scale: draft.scale)
            .clamped(for: model.effectiveModel)
        return Self.round(draft.offsetYmm - target.offsetYmm, 100)
    }

    private func startPeek() {
        let shift = availablePeekShiftMM
        guard started, !ended, shift > 0 else { return }
        peekShiftMM = shift
        model.previewPlacement = Self.preview(draft, peek: shift)
    }

    private func endPeek() {
        guard started, !ended else { return }
        peekShiftMM = 0
        model.previewPlacement = edited ? draft : nil
    }

    // MARK: Position check

    private func parsedMeasurements() -> [String: Double] {
        var result: [String: Double] = [:]
        for ref in ScaleCheck.referenceDistances(spec: spec) {
            let text = (measuredText[ref.id] ?? "").trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: ".")
            if let value = Double(text), value.isFinite, value > 0, value < 400 { result[ref.id] = value }
        }
        return result
    }

    private func saveMeasurements() {
        let measured = parsedMeasurements()
        guard measured != positionRecord.measured else { return }
        positionRecord.measured = measured
        positionRecord.save()
    }

    /// Always starts from the placement in effect before the first Apply, so Apply is repeatable;
    /// the current size is kept.
    private func applyPositionCheck() {
        let measured = parsedMeasurements()
        positionRecord.measured = measured
        guard !measured.isEmpty else {
            positionRecord.save()
            positionMessage = "Enter at least one measured distance."
            return
        }
        positionMessage = nil
        let base = positionRecord.base ?? draft
        positionRecord.base = base
        positionRecord.save()
        let current = DeckPlacement(offsetXmm: base.offsetXmm, offsetYmm: base.offsetYmm, scale: draft.scale)
        let suggestion = ScaleCheck.suggestPlacement(spec: spec, measured: measured, current: current)
        setDraft(DeckPlacement(offsetXmm: suggestion.offsetXmm, offsetYmm: suggestion.offsetYmm, scale: draft.scale))
        positionResidualMM = suggestion.maxResidualMM
    }

    // MARK: Helpers

    /// The iPad iKey recognises without an override: machine identifier first, then native pixels.
    private static func detectedIPad() -> IPadDisplaySpec? {
        if let display = IPadDisplaySpec.preset(forMachine: machineID) { return display }
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        return screen.flatMap { IPadDisplaySpec.detect(nativeLandscapePixels: $0.nativeBounds.size) }
    }

    private static var machineID: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func round(_ value: Double, _ scale: Double) -> Double { (value * scale).rounded() / scale }

    fileprivate static func mm(_ value: Double) -> String { String(format: "%.2f", value) }

    private static func signed(_ value: Double) -> String { String(format: "%+.2f", value == 0 ? 0 : value) }

    /// Shortest text for a stored measurement (12.5, not 12.500000).
    private static func trimmed(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Measured MacBook distances and the placement before the first Apply, stored as JSON under
/// "iKey.positionCheck.v1".
private struct PositionCheckRecord: Codable, Equatable {
    var measured: [String: Double] = [:]
    /// Every Apply starts from this placement (the suggestion is relative); Reset clears it.
    var base: DeckPlacement?

    private static let storageKey = "iKey.positionCheck.v1"

    static func load() -> PositionCheckRecord {
        UserDefaults.standard.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode(PositionCheckRecord.self, from: $0) } ?? PositionCheckRecord()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }
}

/// Deck mm → points in the overlay's own coordinates.
private struct OverlayMap {
    let projection: DeckProjection
    /// The overlay's origin in the window; the deck surface fills the window.
    let origin: CGPoint

    func point(_ x: Double, _ y: Double) -> CGPoint {
        let p = projection.point(MMPoint(x: x, y: y))
        return CGPoint(x: p.x - origin.x, y: p.y - origin.y)
    }

    func rect(_ r: MMRect) -> CGRect { projection.rect(r).offsetBy(dx: -origin.x, dy: -origin.y) }

    func length(_ mm: Double) -> CGFloat { projection.length(mm: mm) }
}

/// Where the panels go: the left and right palm rests and the trackpad's bands above and below the
/// card outline. Falls back to fixed edges when there is no projection or the deck areas are too small,
/// but never puts a strip over the card outline: the nudge strip stays above the card whenever that
/// band fits (so it does not jump away under a held ▼), and the card buttons move into the right panel
/// (`cardButtons == nil`) once the deck is nudged so far toward the user that the band below the card
/// leaves the screen.
private struct FitLayout {
    let map: OverlayMap?
    let left: CGRect
    let right: CGRect
    let nudge: CGRect
    /// nil: list the card buttons in the right panel.
    let cardButtons: CGRect?

    init(resolution: ProjectionResolution?, spec: DeckSpec, origin: CGPoint, size: CGSize) {
        let margin: CGFloat = 12
        let w = max(size.width, 1), h = max(size.height, 1)
        let stripHeight: CGFloat = 60
        let leftWidth = min(340, w * 0.3), rightWidth = min(280, w * 0.25)
        var left = CGRect(x: margin, y: margin, width: leftWidth, height: max(h - 2 * margin, 1))
        var right = CGRect(x: w - margin - rightWidth, y: margin, width: rightWidth, height: max(h - 2 * margin, 1))
        let stripX = left.maxX + margin
        let stripWidth = max(right.minX - margin - stripX, 1)
        let bottomStrip = CGRect(x: stripX, y: h - margin - stripHeight, width: stripWidth, height: stripHeight)
        let topStrip = CGRect(x: stripX, y: margin, width: stripWidth, height: stripHeight)

        guard let resolution else {
            // Nothing is drawn, so nothing can be covered.
            map = nil
            self.left = left; self.right = right; nudge = bottomStrip
            cardButtons = bottomStrip.offsetBy(dx: 0, dy: -(stripHeight + margin))
            return
        }
        let map = OverlayMap(projection: resolution.projection, origin: origin)
        self.map = map
        let pad = map.rect(spec.trackpad)
        let card = map.rect(ScaleCheck.cardRect(centeredOn: spec))
        let panelTop = max(map.point(0, spec.trackpad.maxY - 10).y, margin)
        let panelHeight = h - margin - panelTop
        let rulerRight = map.point(spec.trackpad.maxX + FitOverlay.verticalRulerInsetMM + FitOverlay.rulerDepthMM, 0).x
        let leftCandidate = CGRect(x: margin, y: panelTop, width: pad.minX - 2 * margin, height: panelHeight)
        let rightCandidate = CGRect(x: rulerRight + margin, y: panelTop, width: w - 2 * margin - rulerRight,
                                    height: panelHeight)
        if leftCandidate.width >= 260, rightCandidate.width >= 220, panelHeight >= 240 {
            left = leftCandidate
            right = rightCandidate
        }
        let above = CGRect(x: pad.minX + 8, y: max(pad.minY + 6, 0), width: pad.width - 16,
                           height: card.minY - max(pad.minY, 0) - 12)
        let below = CGRect(x: pad.minX + 8, y: card.maxY + 6, width: pad.width - 16,
                           height: min(pad.maxY, h) - card.maxY - 12)
        if above.width >= 480, above.height >= 44 {
            nudge = above
        } else {
            // A scaled (windowed or unknown-iPad) drawing: an edge strip clear of the card.
            nudge = bottomStrip.intersects(card) ? topStrip : bottomStrip
        }
        cardButtons = below.width >= 360 && below.height >= 44 ? below : nil
        self.left = left; self.right = right
    }
}

/// The true-scale overlay: rulers, ID-1 card, span highlights, position-check reference lines and
/// the peek check's function-row gap marks.
private struct FitOverlay {
    static let rulerDepthMM = 9.0
    static let verticalRulerInsetMM = 3.0

    let map: OverlayMap
    let spec: DeckSpec
    let hairline: CGFloat
    /// Measured values by reference id; nil hides the reference lines.
    let references: [String: Double]?
    let peekTicks: Bool

    private let span = Color.orange
    private let reference = Color.blue
    private let peek = Color.red

    func draw(in ctx: inout GraphicsContext, size: CGSize) {
        drawCard(&ctx)
        drawSpans(&ctx)
        // The rulers cross: both strips first, so every tick of both stays visible.
        let rulers = self.rulers
        for ruler in rulers { fillStrip(ruler, &ctx) }
        for ruler in rulers { drawTicks(ruler, &ctx) }
        if let references { drawReferences(&ctx, measured: references, size: size) }
        if peekTicks { drawPeekTicks(&ctx) }
    }

    private struct Ruler {
        /// Deck mm of the zero mark.
        let origin: MMPoint
        let lengthMM: Int
        /// Horizontal rulers run +x with ticks hanging toward the user; vertical ones run +y with
        /// ticks to the right.
        let horizontal: Bool
    }

    /// 200 mm with zero at the A key's left edge just under the home row (so ' falls on 190), and
    /// 150 mm with zero at the trackpad's front edge just right of the trackpad.
    private var rulers: [Ruler] {
        var result: [Ruler] = []
        if let a = spec.key(id: "a") {
            result.append(Ruler(origin: MMPoint(x: a.cap.minX, y: a.cap.minY - 0.3), lengthMM: 200, horizontal: true))
        }
        result.append(Ruler(origin: MMPoint(x: spec.trackpad.maxX + Self.verticalRulerInsetMM, y: spec.trackpad.minY),
                            lengthMM: 150, horizontal: false))
        return result
    }

    private func tickLength(_ kind: ScaleCheck.Tick.Kind) -> Double {
        switch kind {
        case .mm: return 2
        case .half: return 3.5
        case .cm: return 5
        }
    }

    private var labelFont: Font { .system(size: max(map.length(2.4), 8), weight: .medium).monospacedDigit() }

    private func fillStrip(_ ruler: Ruler, _ ctx: inout GraphicsContext) {
        let o = ruler.origin, length = Double(ruler.lengthMM), depth = Self.rulerDepthMM
        let strip = ruler.horizontal
            ? MMRect(minX: o.x - 3, minY: o.y - depth, width: length + 8, height: depth + 0.3)
            : MMRect(minX: o.x - 0.3, minY: o.y - 2, width: depth + 0.3, height: length + 6)
        ctx.fill(Path(roundedRect: map.rect(strip), cornerRadius: 3), with: .color(.white.opacity(0.9)))
    }

    private func drawTicks(_ ruler: Ruler, _ ctx: inout GraphicsContext) {
        let o = ruler.origin
        var ticks = Path()
        for tick in ScaleCheck.rulerTicks(lengthMM: ruler.lengthMM) {
            let len = tickLength(tick.kind)
            let from = ruler.horizontal ? MMPoint(x: o.x + tick.posMM, y: o.y) : MMPoint(x: o.x, y: o.y + tick.posMM)
            let to = ruler.horizontal ? MMPoint(x: from.x, y: o.y - len) : MMPoint(x: o.x + len, y: from.y)
            ticks.move(to: map.point(from.x, from.y))
            ticks.addLine(to: map.point(to.x, to.y))
            guard let label = tick.label else { continue }
            let text = Text(label).font(labelFont).foregroundStyle(Color.black)
            if ruler.horizontal {
                ctx.draw(text, at: map.point(to.x, to.y - 0.3), anchor: .top)
            } else {
                ctx.draw(text, at: map.point(to.x + 0.4, to.y), anchor: .leading)
            }
        }
        ctx.stroke(ticks, with: .color(.black), lineWidth: hairline)
        let unit = Text("cm").font(labelFont).foregroundStyle(Color.black)
        let length = Double(ruler.lengthMM)
        if ruler.horizontal {
            ctx.draw(unit, at: map.point(o.x + length + 1, o.y - 1), anchor: .topLeading)
        } else {
            ctx.draw(unit, at: map.point(o.x + 1, o.y + length + 1), anchor: .bottomLeading)
        }
    }

    private func drawCard(_ ctx: inout GraphicsContext) {
        let rect = map.rect(ScaleCheck.cardRect(centeredOn: spec))
        let outline = Path(roundedRect: rect, cornerRadius: map.length(ScaleCheck.idCardCornerMM))
        ctx.stroke(outline, with: .color(.black.opacity(0.6)), lineWidth: hairline * 3)
        ctx.stroke(outline, with: .color(.white), style: StrokeStyle(lineWidth: hairline, dash: [8, 4]))
        let caption = Text("Lay a bank or ID card on this outline\n85.60 × 53.98 mm")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white)
        pill(&ctx, caption, at: CGPoint(x: rect.midX, y: rect.midY), color: .black.opacity(0.55))
    }

    /// Left edges of both keys, joined by a bracket in the gap above the first key's row.
    private func drawSpans(_ ctx: inout GraphicsContext) {
        for check in ScaleCheck.spanChecks(spec: spec) {
            guard let from = spec.key(id: check.fromKeyID), let to = spec.key(id: check.toKeyID) else { continue }
            let top = from.cap.maxY + 0.75
            var path = Path()
            for x in [from.cap.minX, to.cap.minX] {
                path.move(to: map.point(x, from.cap.minY))
                path.addLine(to: map.point(x, top))
            }
            path.move(to: map.point(from.cap.minX, top))
            path.addLine(to: map.point(to.cap.minX, top))
            ctx.stroke(path, with: .color(span), lineWidth: 2)
            let label = Text("\(check.label) \(FitAndSizeView.mm(check.expectedMM)) mm")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
            pill(&ctx, label, at: map.point((from.cap.minX + to.cap.minX) / 2, top), color: span)
        }
    }

    /// Dimension lines from the deck's front edge or left side (often off screen) to each reference.
    /// The front-edge lines run in the trackpad's strip left of the card outline (4 mm apart, clear of
    /// the card's edge) with their labels turned along the line, so they never cover the card check.
    private func drawReferences(_ ctx: inout GraphicsContext, measured: [String: Double], size: CGSize) {
        var nextX = spec.trackpad.minX + 4, nextY = spec.trackpad.maxY - 4
        for ref in ScaleCheck.referenceDistances(spec: spec) {
            let start: CGPoint, end: CGPoint, tick: CGVector
            switch ref.axis {
            case .y:
                start = map.point(nextX, spec.chassis.minY)
                end = map.point(nextX, spec.chassis.minY + ref.expectedMM)
                tick = CGVector(dx: map.length(1.5), dy: 0)
                nextX += 8
            case .x:
                start = map.point(spec.chassis.minX, nextY)
                end = map.point(spec.chassis.minX + ref.expectedMM, nextY)
                tick = CGVector(dx: 0, dy: map.length(1.5))
                nextY += 4.5
            }
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            for p in [start, end] {
                path.move(to: CGPoint(x: p.x - tick.dx, y: p.y - tick.dy))
                path.addLine(to: CGPoint(x: p.x + tick.dx, y: p.y + tick.dy))
            }
            ctx.stroke(path, with: .color(reference), lineWidth: 1.5)
            var text = "\(FitAndSizeView.mm(ref.expectedMM)) mm"
            if let value = measured[ref.id] { text += " (yours \(FitAndSizeView.mm(value)))" }
            let label = Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white)
            // The label sits on the middle of the part of the line that is on screen.
            let visible = CGRect(origin: .zero, size: size)
            let lo = CGPoint(x: max(min(start.x, end.x), visible.minX), y: max(min(start.y, end.y), visible.minY))
            let hi = CGPoint(x: min(max(start.x, end.x), visible.maxX), y: min(max(start.y, end.y), visible.maxY))
            guard lo.x <= hi.x, lo.y <= hi.y else { continue }
            let mid = CGPoint(x: (lo.x + hi.x) / 2, y: (lo.y + hi.y) / 2)
            switch ref.axis {
            case .y:
                var along = ctx
                along.translateBy(x: mid.x, y: mid.y)
                along.rotate(by: .degrees(-90))
                pill(&along, label, at: .zero, color: reference)
            case .x:
                pill(&ctx, label, at: CGPoint(x: mid.x, y: mid.y - 10), color: reference)
            }
        }
    }

    /// Marks at the screen's top edge over the gaps between the function-row keys.
    private func drawPeekTicks(_ ctx: inout GraphicsContext) {
        let row = spec.keys.filter { $0.row == 0 }.sorted { $0.cap.minX < $1.cap.minX }
        var path = Path()
        for (left, right) in zip(row, row.dropFirst()) {
            let x = map.point((left.cap.maxX + right.cap.minX) / 2, 0).x
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: 28))
        }
        ctx.stroke(path, with: .color(.white), lineWidth: hairline * 4)
        ctx.stroke(path, with: .color(peek), lineWidth: hairline * 2)
    }

    private func pill(_ ctx: inout GraphicsContext, _ text: Text, at center: CGPoint, color: Color) {
        let resolved = ctx.resolve(text)
        let size = resolved.measure(in: CGSize(width: 600, height: 200))
        let box = CGRect(x: center.x - size.width / 2 - 6, y: center.y - size.height / 2 - 2,
                         width: size.width + 12, height: size.height + 4)
        ctx.fill(Path(roundedRect: box, cornerRadius: min(box.height / 2, 10)), with: .color(color))
        ctx.draw(resolved, at: center, anchor: .center)
    }
}

/// A nudge arrow: a tap moves by `DeckPlacement.stepMM`; holding repeats `repeatStepMM` steps.
private struct NudgeButton: View {
    let systemImage: String
    let label: String
    /// `true` for each auto-repeat step, `false` for a tap.
    let action: (Bool) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @GestureState private var pressing = false
    @State private var active = false
    @State private var repeated = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .frame(width: 44, height: 40)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(pressing ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.1)))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($pressing) { _, state, _ in state = true }
                .onChanged { _ in
                    guard isEnabled, !active else { return }
                    active = true
                    repeated = false
                    beginRepeat()
                }
                .onEnded { _ in
                    let didRepeat = repeated, wasActive = active
                    endPress()
                    if isEnabled, wasActive, !didRepeat { action(false) }
                })
            .allowsHitTesting(isEnabled)
            // A cancelled gesture resets `pressing` without onEnded; this stops its repeat.
            .onChange(of: pressing) { _, isPressing in
                if !isPressing { endPress() }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { endPress() }
            }
            .onDisappear(perform: endPress)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if isEnabled { action(false) } }
    }

    private func beginRepeat() {
        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            while !Task.isCancelled {
                repeated = true
                action(true)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private func endPress() {
        repeatTask?.cancel()
        repeatTask = nil
        active = false
        repeated = false
    }
}
