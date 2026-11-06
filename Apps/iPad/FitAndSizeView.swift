import SwiftUI
import IKeyCore

/// Full-screen Fit & Size over the live deck. Frozen signature; W4-FIT implements the body.
struct FitAndSizeView: View {
    @ObservedObject var model: PadModel
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            Text(model.effectiveModel.displayName)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
        }
    }
}
