import SwiftUI
import ScarfCore
import ScarfDesign

/// Pre-flight sheet shown when a chat-start hits a server whose
/// `config.yaml` has no `model.default` / `model.provider`. Wraps the
/// existing `ModelPickerSheet` so the picker surface, validation, and
/// Nous-catalog branch all remain in one place.
///
/// The host (`ChatView`) owns persistence + retry: this sheet only
/// captures the user's selection and calls `onSelect`. The
/// `ChatViewModel` writes via `hermes config set` and replays the
/// original `startACPSession` arguments, so the chat the user
/// originally opened lands without them having to click the project
/// row again.
struct ChatModelPreflightSheet: View {
    let reason: String
    let serverDisplayName: String
    let onSelect: (_ model: String, _ provider: String) -> Void
    /// Local-tab selection (Ollama, LM Studio, …) — carries the base
    /// URL / key / mode payload the plain (model, provider) pair can't.
    var onSelectLocal: ((LocalModelSelection) -> Void)? = nil
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ModelPickerSheet(
                initialProvider: "",
                initialModel: "",
                onSelect: { modelID, providerID in
                    onSelect(modelID, providerID)
                    dismiss()
                },
                onSelectLocal: onSelectLocal.map { handler in
                    { selection in
                        handler(selection)
                        dismiss()
                    }
                },
                onCancel: {
                    onCancel()
                    dismiss()
                }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cpu")
                .foregroundStyle(ScarfColor.warning)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pick a model to start chatting")
                    .scarfStyle(.headline)
                Text(detailMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding()
    }

    private var detailMessage: String {
        let suffix = "Hermes uses `model.default` + `model.provider` from `config.yaml`. Pick one and Scarf will save it on \(serverDisplayName) before starting the chat."
        guard !reason.isEmpty else { return suffix }
        return "\(reason) \(suffix)"
    }
}
