import SwiftUI
import ScarfCore

/// Row-style model picker that mirrors the visual style of `PickerRow`/`EditableTextField`
/// but opens a dedicated sheet browsing providers + models from the catalog.
///
/// The caller receives (modelID, providerID) and decides how to persist them —
/// Settings → General saves both; Delegation saves both to its own keys; aux
/// fields that only take a model can ignore the provider parameter.
///
/// Hosts that can persist a full local-endpoint setup (`model.base_url`
/// et al.) additionally pass `onLocalChange` — that unlocks the sheet's
/// Remote | Local source filter. Hosts without it (delegation, model
/// presets) keep the classic remote-only picker.
struct ModelPickerRow: View {
    let label: String
    let currentModel: String
    let currentProvider: String
    /// Round-trip inputs for the sheet's Local tab (current
    /// `model.base_url` / `model.api_key` / `model.api_mode`).
    var currentBaseURL: String = ""
    var currentAPIKey: String = ""
    var currentAPIMode: String = ""
    let onChange: (_ modelID: String, _ providerID: String) -> Void
    var onLocalChange: ((LocalModelSelection) -> Void)? = nil

    @State private var showSheet = false

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .trailing)

            Button {
                showSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                    Text(displayValue)
                        .font(.system(.caption, design: .monospaced))
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
        .sheet(isPresented: $showSheet) {
            ModelPickerSheet(
                initialProvider: currentProvider,
                initialModel: currentModel,
                initialBaseURL: currentBaseURL,
                initialAPIKey: currentAPIKey,
                initialAPIMode: currentAPIMode,
                onSelect: { modelID, providerID in
                    onChange(modelID, providerID)
                    showSheet = false
                },
                onSelectLocal: onLocalChange.map { handler in
                    { selection in
                        handler(selection)
                        showSheet = false
                    }
                },
                onCancel: { showSheet = false }
            )
        }
    }

    /// Format as "<provider> / <model>" when both are known; fall back to
    /// whichever side exists; fall back to a dim "Select model…" placeholder
    /// when nothing has been set yet.
    private var displayValue: String {
        let hasProvider = !currentProvider.isEmpty && currentProvider != "unknown"
        let hasModel = !currentModel.isEmpty && currentModel != "unknown"
        switch (hasProvider, hasModel) {
        case (true, true): return "\(currentProvider) / \(currentModel)"
        case (false, true): return currentModel
        case (true, false): return "\(currentProvider) / (none)"
        case (false, false): return "Select model…"
        }
    }
}
