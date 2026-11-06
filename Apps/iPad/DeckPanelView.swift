import SwiftUI
import IKeyCore

/// The settings panel opened by holding Touch ID. Frozen signature; W4-FIT implements the body.
struct DeckPanelView: View {
    @ObservedObject var model: PadModel
    var onFitAndSize: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Text(model.status)
                Button("Fit & size…", action: onFitAndSize)
            }
            .navigationTitle("iKey")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.isPanelPresented = false }
                }
            }
        }
    }
}
