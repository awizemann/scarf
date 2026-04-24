import SwiftUI
import ScarfCore

/// Two-column model browser sheet. Left column lists providers, right column
/// lists models for the selected provider. Supports filtering and a "Custom…"
/// option for free-form model IDs not in the catalog.
///
/// Overlay-only providers (Nous Portal, OpenAI Codex, Qwen OAuth, …) have no
/// models.dev catalog entry, so their right column renders an overlay detail
/// view: subscription state for Nous, plus a free-form model-ID field for
/// users who know what they want. This is how the picker keeps parity with
/// `hermes model` on the CLI, which can reach these providers natively.
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

    // Overlay-provider model entry — distinct from `customMode` because the
    // provider is pinned; only the model ID is user-editable.
    @State private var overlayModelID: String = ""

    // Subscription state for the Nous Portal row / detail view. Loaded on
    // appear; stays in-memory for the life of the sheet.
    @State private var subscription: NousSubscriptionState = .absent

    /// Drives presentation of the Nous sign-in sheet. Bound to the
    /// "Sign in to Nous Portal" button in the subscription summary.
    @State private var showNousSignIn: Bool = false

    /// Validation failure surfaced on Select when the typed / selected
    /// model isn't in the chosen provider's catalog. Pass-1 M7 #5
    /// cross-platform fix — previously Scarf let you save any string
    /// and the failure only appeared hours later at runtime.
    @State private var validationIssue: ModelValidationIssue?

    @Environment(\.serverContext) private var serverContext
    private var catalog: ModelCatalogService { ModelCatalogService(context: serverContext) }
    private var subscriptionService: NousSubscriptionService { NousSubscriptionService(context: serverContext) }

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
            overlayModelID = initialModel
            subscription = subscriptionService.loadState()
            loadModelsForSelection()
        }
        .sheet(isPresented: $showNousSignIn) {
            NousSignInSheet {
                // Refresh subscription immediately so the right-column
                // status row flips to "active" without waiting for the
                // picker to be re-opened.
                subscription = subscriptionService.loadState()
            }
        }
        .alert(item: $validationIssue) { issue in
            Alert(
                title: Text("Model not available"),
                message: Text(validationMessage(for: issue)),
                primaryButton: .default(Text("Pick from catalog")) {
                    validationIssue = nil
                    customMode = false
                },
                secondaryButton: .cancel(Text("Edit"))
            )
        }
    }

    private func validationMessage(for issue: ModelValidationIssue) -> String {
        var msg = "\(issue.modelID) isn't in \(issue.providerName)'s catalog."
        if !issue.suggestions.isEmpty {
            msg += " Did you mean one of:\n• " + issue.suggestions.joined(separator: "\n• ")
        } else {
            msg += " Pick one from the catalog or double-check the spelling."
        }
        return msg
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
                providerRow(provider)
                    .tag(provider.providerID)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func providerRow(_ provider: HermesProviderInfo) -> some View {
        HStack(spacing: 6) {
            Text(provider.providerName)
            if provider.subscriptionGated {
                capsuleTag("Subscription", tint: .accentColor)
            }
            Spacer()
            if !provider.isOverlay {
                Text("\(provider.modelCount)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var modelColumn: some View {
        if let selected = providers.first(where: { $0.providerID == selectedProviderID }), selected.isOverlay {
            overlayProviderDetail(selected)
        } else {
            cachedModelList
        }
    }

    private var cachedModelList: some View {
        List(selection: $selectedModelID) {
            ForEach(filteredModels) { model in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(model.modelName)
                            .font(.system(.body, design: .default, weight: .medium))
                        Spacer()
                        if let ctx = model.contextDisplay {
                            Text("\(ctx) ctx")
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

    /// Right-column detail for overlay-only providers (Nous Portal, OpenAI
    /// Codex, Qwen OAuth, …). models.dev has no catalog for them, so the user
    /// either trusts Hermes's default (subscription providers) or types a
    /// model ID they know is valid for the provider's API.
    @ViewBuilder
    private func overlayProviderDetail(_ provider: HermesProviderInfo) -> some View {
        let overlay = catalog.overlayMetadata(for: provider.providerID)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(provider.providerName).font(.title3.bold())
                    if provider.subscriptionGated {
                        capsuleTag("Subscription", tint: .accentColor)
                    }
                }
                if provider.subscriptionGated {
                    subscriptionSummary(provider: provider, overlay: overlay)
                } else {
                    Text(overlayInstruction(for: overlay?.authType))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Model ID").font(.caption).foregroundStyle(.secondary)
                    TextField(modelIDPlaceholder(for: provider), text: $overlayModelID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    if provider.subscriptionGated {
                        Text("Leave blank to use Hermes's default Nous model.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let docURL = overlay?.docURL, let url = URL(string: docURL) {
                    Link(destination: url) {
                        Label("Setup documentation", systemImage: "book")
                            .font(.caption)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func subscriptionSummary(provider: HermesProviderInfo, overlay: HermesProviderOverlay?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paid Nous Portal subscribers route web search, image generation, TTS, and browser automation through their subscription — no separate API keys needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: subscription.subscribed ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(subscription.subscribed ? Color.green : Color.secondary)
                if subscription.subscribed {
                    Text("Subscription active — active provider is Nous.")
                } else if subscription.present {
                    Text("Signed in to Nous, but another provider is active.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not signed in yet.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            if !subscription.subscribed {
                Button {
                    showNousSignIn = true
                } label: {
                    Label("Sign in to Nous Portal", systemImage: "person.badge.key.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
    }

    private func overlayInstruction(for authType: HermesProviderOverlay.AuthType?) -> String {
        switch authType {
        case .oauthExternal:
            return "Sign in through the provider's OAuth flow — run `hermes auth` from a terminal, then pick the provider to complete sign-in. Back here, set the model ID you want to use."
        case .externalProcess:
            return "Uses an external process (e.g. a local agent bridge). Run `hermes auth` from a terminal to complete the link, then set the model ID you want to use."
        case .oauthDeviceCode:
            return "Sign in via device-code flow — run `hermes auth` from a terminal and follow the printed URL."
        default:
            return "This provider isn't in the models.dev catalog. Enter the model ID you want to use — Hermes will pass it through to the provider verbatim."
        }
    }

    private func modelIDPlaceholder(for provider: HermesProviderInfo) -> String {
        switch provider.providerID {
        case "nous":          return "e.g. hermes-3"
        case "openai-codex":  return "e.g. gpt-5-codex"
        case "qwen-oauth":    return "e.g. qwen3-coder-plus"
        default:              return "e.g. model-name"
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

    private var isSelectedProviderOverlay: Bool {
        providers.first(where: { $0.providerID == selectedProviderID })?.isOverlay ?? false
    }

    private var isSelectedProviderSubscriptionGated: Bool {
        providers.first(where: { $0.providerID == selectedProviderID })?.subscriptionGated ?? false
    }

    private var canSubmit: Bool {
        if customMode {
            return !customModelID.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if isSelectedProviderOverlay {
            // Subscription-gated providers can submit with an empty model ID
            // (Hermes picks its default). Other overlays require a model ID.
            if isSelectedProviderSubscriptionGated { return true }
            return !overlayModelID.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !selectedModelID.isEmpty
    }

    private var selectedPreview: String? {
        if isSelectedProviderOverlay {
            let trimmed = overlayModelID.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                return selectedProviderID.isEmpty ? nil : "\(selectedProviderID) / (default)"
            }
            return "\(selectedProviderID) / \(trimmed)"
        }
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
        let (model, provider): (String, String)
        if customMode {
            model = customModelID.trimmingCharacters(in: .whitespaces)
            provider = resolvedCustomProvider()
        } else if isSelectedProviderOverlay {
            model = overlayModelID.trimmingCharacters(in: .whitespaces)
            provider = selectedProviderID
        } else {
            model = selectedModelID
            provider = selectedProviderID
        }

        // Block unknown models before they land in config.yaml.
        // Overlay-only providers short-circuit to .valid inside the
        // validator because their catalogs aren't in models.dev.
        switch catalog.validateModel(model, for: provider) {
        case .valid, .unknownProvider:
            onSelect(model, provider)
        case .invalid(let providerName, let suggestions):
            validationIssue = ModelValidationIssue(
                modelID: model,
                providerName: providerName,
                suggestions: suggestions
            )
        }
    }

    private func capsuleTag(_ text: String, tint: Color = .secondary) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint == .secondary ? AnyShapeStyle(.quaternary) : AnyShapeStyle(tint.opacity(0.15)))
            .clipShape(Capsule())
    }
}

/// Carrier for the catalog-validation alert. Identifiable so SwiftUI's
/// `.alert(item:)` can key off each unique issue.
private struct ModelValidationIssue: Identifiable {
    let id = UUID()
    let modelID: String
    let providerName: String
    let suggestions: [String]
}
