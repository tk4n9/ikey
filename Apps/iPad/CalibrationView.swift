import SwiftUI
import IKeyCore

struct CalibrationView: View {
    @ObservedObject var model: PadModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DeckLayout
    @State private var region = Region.keyboard
    @State private var selectedKeyID: String
    @State private var errorMessage: String?

    private enum Region: String, CaseIterable, Identifiable {
        case keyboard = "Keyboard", trackpad = "Trackpad", key = "Single key"
        var id: Self { self }
    }

    init(model: PadModel) {
        self.model = model
        _draft = State(initialValue: model.layout)
        _selectedKeyID = State(initialValue: model.layout.keys.first?.id ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            DeckSurface(image: model.photo, layout: draft, inputEnabled: false,
                        resetGeneration: 0, showRegions: true,
                        selectedKeyID: region == .key ? selectedKeyID : nil,
                        onEvent: { _ in })
                .frame(height: 210)
                .accessibilityLabel("Photo with keyboard and trackpad alignment guides")
            Form {
                Section {
                    Text("Align the blue trackpad outline and the teal keyboard outline first. Then adjust individual key outlines. Measurements are percentages of the photo; single-key measurements are percentages of the keyboard outline.")
                        .font(.footnote)
                    Picker("Adjust", selection: $region) {
                        ForEach(Region.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if region == .key {
                        Picker("Key", selection: $selectedKeyID) {
                            ForEach(draft.keys) { key in Text(key.label).tag(key.id) }
                        }
                    }
                    RectSliders(rect: selectedRect)
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
                Section {
                    Button("Reset to approximate US MacBook layout", role: .destructive) {
                        draft = .macBookANSI
                        selectedKeyID = draft.keys.first?.id ?? ""
                        errorMessage = nil
                    }
                    Text("This first layout assumes a US ANSI keyboard. Per-key alignment changes positions, not key meanings. Exact physical size depends on your iPad and photo crop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Photo alignment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        try model.saveLayout(draft)
                        dismiss()
                    } catch {
                        errorMessage = "Could not save alignment. Keep keys inside the keyboard outline without overlaps, and keep the keyboard and trackpad outlines separate. \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private var selectedRect: Binding<NormalizedRect> {
        Binding {
            switch region {
            case .keyboard: return draft.keyboard
            case .trackpad: return draft.trackpad
            case .key: return draft.keys.first(where: { $0.id == selectedKeyID })?.frame ?? draft.keyboard
            }
        } set: { value in
            switch region {
            case .keyboard: draft.keyboard = value
            case .trackpad: draft.trackpad = value
            case .key:
                if let index = draft.keys.firstIndex(where: { $0.id == selectedKeyID }) {
                    draft.keys[index].frame = value
                }
            }
            errorMessage = nil
        }
    }
}

private struct RectSliders: View {
    @Binding var rect: NormalizedRect

    var body: some View {
        slider("Left", value: field(\.x), range: 0...0.99)
        slider("Top", value: field(\.y), range: 0...0.99)
        slider("Width", value: field(\.width), range: 0.005...max(0.005, 1 - rect.x))
        slider("Height", value: field(\.height), range: 0.005...max(0.005, 1 - rect.y))
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .percent.precision(.fractionLength(1)))
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: 0.001)
                .accessibilityLabel(title)
        }
    }

    private func field(_ path: WritableKeyPath<NormalizedRect, Double>) -> Binding<Double> {
        Binding {
            rect[keyPath: path]
        } set: { value in
            var next = rect
            next[keyPath: path] = value
            next.width = min(max(0.005, next.width), 1 - next.x)
            next.height = min(max(0.005, next.height), 1 - next.y)
            rect = next
        }
    }
}
