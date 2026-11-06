import IKeyCore
import SwiftUI

/// 'Check Top-Row Keys': tries every strategy of each top-row function on this Mac and saves the
/// one that works, so the iPad's F1-F12 do what their icons show. A function without a choice
/// uses its default chain (the first strategy, skipping disabled Mac shortcuts).
struct TopRowCheckView: View {
    @ObservedObject var receiver: ReceiverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Press Try and watch this Mac: each key should do what its icon shows (brightness, Mission Control, Spotlight, Dictation, Do Not Disturb, media, volume). Mark the strategy that works (Dictation and Do Not Disturb also offer Nothing). If no strategy works, leave the row unconfirmed (it keeps the default) and note it in docs/device-validation.md.")
                .fixedSize(horizontal: false, vertical: true)
            if !receiver.hasInputPermission {
                Text("Try needs the input control permission (see the iKey menu).")
                    .foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(TopRowFunction.allCases, id: \.self) { function in
                        row(function)
                        Divider()
                    }
                }
                .padding(.trailing, 8)
            }
            HStack {
                Text("Option+F11 opens Sound settings (verify).").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Use Defaults") { receiver.topRowChoices = TopRowChoices() }
                    .disabled(receiver.topRowChoices.choices.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 540, minHeight: 420)
    }

    private func row(_ function: TopRowFunction) -> some View {
        let chosen = receiver.topRowChoices.strategies()[function]
        let chain = TopRowDefaults.chain(for: function)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Self.fKey(function)) · \(Self.name(function))").font(.headline)
                Spacer()
                Text(chosen == nil ? "Not confirmed: uses the default" : "Confirmed")
                    .font(.caption).foregroundStyle(chosen == nil ? Color.secondary : Color.green)
            }
            Text(fnStateLine(function)).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(chain.enumerated()), id: \.offset) { index, strategy in
                HStack {
                    Button("Try") { receiver.tryTopRow(function, strategy) }
                        .disabled(!receiver.hasInputPermission || strategy == TopRowStrategy.none)
                        .controlSize(.small)
                    Text(Self.describe(strategy) + (index == 0 ? " (default)" : ""))
                        .font(.callout)
                    Spacer()
                    Button {
                        var choices = receiver.topRowChoices
                        choices.set(function, strategy)
                        receiver.topRowChoices = choices
                    } label: {
                        Label("Works", systemImage: chosen == strategy ? "largecircle.fill.circle" : "circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    /// What the key does alone and with fn, following "Use F1, F2, etc. keys as standard
    /// function keys" (fnState).
    private func fnStateLine(_ function: TopRowFunction) -> String {
        let key = Self.fKey(function)
        let action = Self.name(function)
        return receiver.fnKeysStandard
            ? "\(key) alone sends \(key); fn + \(key): \(action) (standard function keys on)"
            : "\(key) alone: \(action); fn + \(key) sends \(key)"
    }

    private static func fKey(_ function: TopRowFunction) -> String {
        "F\((TopRowFunction.allCases.firstIndex(of: function) ?? 0) + 1)"
    }

    private static func name(_ function: TopRowFunction) -> String {
        switch function {
        case .brightnessDown: return "Brightness Down"
        case .brightnessUp: return "Brightness Up"
        case .missionControl: return "Mission Control"
        case .spotlight: return "Spotlight"
        case .dictation: return "Dictation"
        case .doNotDisturb: return "Do Not Disturb"
        case .rewind: return "Previous Track"
        case .playPause: return "Play/Pause"
        case .fastForward: return "Next Track"
        case .mute: return "Mute"
        case .volumeDown: return "Volume Down"
        case .volumeUp: return "Volume Up"
        }
    }

    private static func describe(_ strategy: TopRowStrategy) -> String {
        switch strategy {
        case .aux(let key):
            return "System key: \(auxNames[key] ?? "aux \(key)")"
        case let .keyCode(code, secondaryFn):
            let name = keyCodeNames[code].map { "\($0) key (\(code))" } ?? "Key code \(code)"
            return secondaryFn ? name + " with fn" : name
        case .hotKey(let id):
            return "Your Mac's \(hotKeyNames[id] ?? "shortcut \(id)") shortcut"
        case .openApplication(let path):
            let app = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return "Open \(app)"
        case .none:
            return "Nothing"
        }
    }

    /// NX_KEYTYPE_* names.
    private static let auxNames: [Int: String] = [
        0: "volume up", 1: "volume down", 2: "brightness up", 3: "brightness down", 7: "mute",
        16: "play/pause", 17: "next", 18: "previous", 19: "fast forward", 20: "rewind",
    ]

    private static let keyCodeNames: [UInt16: String] = [
        144: "Brightness Up", 145: "Brightness Down", 160: "Mission Control", 129: "Spotlight",
        176: "Dictation", 178: "Do Not Disturb",
    ]

    /// Symbolic hot key ids.
    private static let hotKeyNames: [Int: String] = [
        32: "Mission Control", 53: "Decrease Display Brightness", 54: "Increase Display Brightness",
        64: "Spotlight",
    ]
}
