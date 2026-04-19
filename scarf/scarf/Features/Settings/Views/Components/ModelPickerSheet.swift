import SwiftUI

/// Two-column model browser sheet. Left column lists providers, right column
/// lists models for the selected provider. Supports filtering and a "Custom…"
/// option for free-form model IDs not in the catalog.
struct ModelPickerSheet: View {
    let initialProvider: String
    let initialModel: String
    let onSelect: (_ modelID: String, _ providerID: String) -> Void
    let onCancel: () -> Void

    @State private var providers: [HermesProviderInfo] = []
    @State private var selectedProviderID: String = ""
    @State private var models: [HermesModelInfo] = []
    @State private var selectedModelID: String = ""
    @State private var searchText: String = ""

    // Custom model entry — used when the catalog doesn't have the exact model
    // the user needs (e.g., provider-prefixed IDs like "openrouter/some/model").
    @State private var customMode: Bool = false
    @State private var customModelID: String = ""
    @State private var customProviderID: String = ""

    @Environment(\.serverContext) private var serverContext
    private var catalog: ModelCatalogService { ModelCatalogService(context: serverContext) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if customMode {
                customEntry
            } else {
                HSplitView {
                    providerColumn.frame(minWidth: 220, idealWidth: 240)
                    modelColumn.frame(minWidth: 340)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            providers = catalog.loadProviders()
            selectedProviderID = initialProvider.isEmpty ? (providers.first?.providerID ?? "") : initialProvider
            selectedModelID = initialModel
            loadModelsForSelection()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
            Text("Select Model")
                .font(.headline)
            Spacer()
            if !customMode {
                TextField("Search…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            Button(customMode ? "Back to Catalog" : "Custom…") {
                customMode.toggle()
                if customMode {
                    customModelID = initialModel
                    customProviderID = initialProvider
                }
            }
            .controlSize(.small)
        }
        .padding()
    }

    private var providerColumn: some View {
        List(selection: Binding(
            get: { selectedProviderID },
            set: { newValue in
                selectedProviderID = newValue
                loadModelsForSelection()
            }
        )) {
            ForEach(filteredProviders) { provider in
                HStack {
                    Text(provider.providerName)
                    Spacer()
                    Text("\(provider.modelCount)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .tag(provider.providerID)
            }
        }
        .listStyle(.inset)
    }

    private var modelColumn: some View {
        List(selection: $selectedModelID) {
            ForEach(filteredModels) { model in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(model.modelName)
                            .font(.system(.body, design: .default, weight: .medium))
                        Spacer()
                        if let ctx = model.contextDisplay {
                            Text(ctx + " ctx")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(model.modelID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        if let cost = model.costDisplay {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(cost)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if model.toolCall {
                            capsuleTag("tools")
                        }
                        if model.reasoning {
                            capsuleTag("reasoning")
                        }
                    }
                }
                .padding(.vertical, 2)
                .tag(model.modelID)
            }
        }
        .listStyle(.inset)
        .overlay {
            if filteredModels.isEmpty {
                ContentUnavailableView("No Models", systemImage: "cpu", description: Text("This provider has no catalogued models."))
            }
        }
    }

    private var customEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use a model not in the catalog. Hermes accepts any string the provider recognizes, including provider-prefixed forms like \"openrouter/anthropic/claude-opus-4.6\".")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Model ID").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. openai/gpt-4o", text: $customModelID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Provider").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. openai", text: $customProviderID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Text("Leave blank to infer from the model ID's prefix (\"openai/...\" → openai).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            if customMode {
                Text(customProviderPreview)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let preview = selectedPreview {
                Text(preview)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onCancel() }
            Button("Select") { submitSelection() }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
        }
        .padding()
    }

    // MARK: - Helpers

    private var filteredProviders: [HermesProviderInfo] {
        guard !searchText.isEmpty else { return providers }
        let q = searchText.lowercased()
        return providers.filter {
            $0.providerName.lowercased().contains(q) || $0.providerID.lowercased().contains(q)
        }
    }

    private var filteredModels: [HermesModelInfo] {
        guard !searchText.isEmpty else { return models }
        let q = searchText.lowercased()
        return models.filter {
            $0.modelName.lowercased().contains(q) || $0.modelID.lowercased().contains(q)
        }
    }

    private var canSubmit: Bool {
        if customMode {
            return !customModelID.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !selectedModelID.isEmpty
    }

    private var selectedPreview: String? {
        guard !selectedModelID.isEmpty, !selectedProviderID.isEmpty else { return nil }
        return "\(selectedProviderID) / \(selectedModelID)"
    }

    private var customProviderPreview: String {
        let resolved = resolvedCustomProvider()
        return resolved.isEmpty ? "Provider will not be changed" : "Provider → \(resolved)"
    }

    private func loadModelsForSelection() {
        guard !selectedProviderID.isEmpty else {
            models = []
            return
        }
        models = catalog.loadModels(for: selectedProviderID)
        // If the current selection is not in the new list, don't try to keep
        // stale highlight state — clear unless the user originally had this model.
        if !models.contains(where: { $0.modelID == selectedModelID }) {
            selectedModelID = models.first?.modelID ?? ""
        }
    }

    /// When the user enters a custom model ID without explicitly naming a
    /// provider, infer from a `provider/model` prefix if present. Otherwise
    /// fall back to whatever is currently selected (we never blank out the
    /// existing provider silently).
    private func resolvedCustomProvider() -> String {
        let explicit = customProviderID.trimmingCharacters(in: .whitespaces)
        if !explicit.isEmpty { return explicit }
        if let slash = customModelID.firstIndex(of: "/") {
            return String(customModelID[customModelID.startIndex..<slash])
        }
        return ""
    }

    private func submitSelection() {
        if customMode {
            let model = customModelID.trimmingCharacters(in: .whitespaces)
            let provider = resolvedCustomProvider()
            onSelect(model, provider)
        } else {
            onSelect(selectedModelID, selectedProviderID)
        }
    }

    private func capsuleTag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary)
            .clipShape(Capsule())
    }
}
