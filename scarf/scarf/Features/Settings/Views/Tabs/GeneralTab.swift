import SwiftUI
import ScarfCore
import ScarfDesign

/// General tab — model picker (provider auto-follows), personality, locale.
/// Credential management lives in the Credential Pools sidebar item; a hint
/// row in this tab deep-links there so users don't have to hunt for it.
struct GeneralTab: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    var body: some View {
        SettingsSection(title: "Model", icon: "cpu") {
            ModelPickerRow(
                label: "Model",
                currentModel: viewModel.config.model,
                currentProvider: viewModel.config.provider,
                currentBaseURL: viewModel.config.modelBaseURL,
                currentAPIKey: viewModel.config.modelAPIKey,
                currentAPIMode: viewModel.config.modelAPIMode,
                onChange: { modelID, providerID in
                    // Selecting a model auto-syncs the provider so the two
                    // stay in lockstep (an empty provider — custom entry
                    // without a prefix — keeps the current one). Routed
                    // through LocalModelConfigPlan so a switch away from a
                    // local provider also scrubs its stale
                    // base_url/api_key/api_mode keys.
                    viewModel.applyModelPickerSelection(model: modelID, provider: providerID, local: nil)
                },
                onLocalChange: { selection in
                    viewModel.applyModelPickerSelection(
                        model: selection.modelID,
                        provider: selection.providerID,
                        local: selection
                    )
                }
            )
            // Provider is shown read-only for clarity; users change it via the
            // Model picker, which presents providers and models together.
            ReadOnlyRow(label: "Provider", value: viewModel.config.provider)
            credentialsHint
        }

        // v0.20: `model_catalog.excluded_providers` — hide providers from
        // model pickers and Hermes's built-in resolution. Hidden pre-v0.20.
        if let capabilities = capabilitiesStore?.capabilities, capabilities.isV020OrLater {
            ExcludedProvidersSection(viewModel: viewModel, capabilities: capabilities)
        }

        SettingsSection(title: "Personality", icon: "theatermasks") {
            if !viewModel.personalities.isEmpty {
                PickerRow(label: "Personality", selection: viewModel.config.personality, options: viewModel.personalities) { viewModel.setPersonality($0) }
            } else {
                EditableTextField(label: "Personality", value: viewModel.config.personality) { viewModel.setPersonality($0) }
            }
        }

        SettingsSection(title: "Locale", icon: "globe.americas") {
            EditableTextField(label: "Timezone (IANA)", value: viewModel.config.timezone) { viewModel.setTimezone($0) }
            // v0.13: `display.language` picker. Hidden on pre-v0.13 hosts
            // because writing the key would no-op silently. Two "English"
            // entries by design — empty string preserves "no key" semantics
            // (Hermes-default), explicit `en` pins it.
            if capabilitiesStore?.capabilities.hasDisplayLanguage == true {
                PickerRow(
                    label: "Display language",
                    selection: viewModel.config.display.language,
                    options: viewModel.displayLanguages.map(\.code),
                    optionLabel: { code in
                        viewModel.displayLanguages.first { $0.code == code }?.label ?? code
                    }
                ) { viewModel.setDisplayLanguage($0) }
            }
        }

        UpdatesSection()
    }

    /// Breadcrumb-style row that points users to the Credential Pools sidebar
    /// item. Replaces the old "Remove Credentials" button — that action lived
    /// here historically but duplicated Credential Pools' per-credential UI.
    private var credentialsHint: some View {
        HStack {
            Text("Credentials")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .trailing)
            Button {
                coordinator.selectedSection = .credentialPools
            } label: {
                HStack(spacing: 4) {
                    Text("Manage in Credential Pools")
                        .font(.caption)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                }
            }
            .buttonStyle(.link)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }
}

/// Editor for `model_catalog.excluded_providers` (v0.20+) — a simple list
/// of provider IDs hidden from model pickers and Hermes's built-in model
/// resolution (matched case-insensitively by Hermes). Lists are
/// inexpressible via `hermes config set`, so writes go through the
/// direct-YAML path; removing the last row deletes the key entirely.
private struct ExcludedProvidersSection: View {
    @Bindable var viewModel: SettingsViewModel
    let capabilities: HermesCapabilities
    @State private var newProvider = ""
    @State private var knownProviderIDs: [String] = []

    var body: some View {
        SettingsSection(title: "Excluded Providers", icon: "eye.slash") {
            ForEach(viewModel.config.excludedProviders, id: \.self) { provider in
                HStack {
                    Text(provider)
                        .font(ScarfFont.monoSmall)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                    Spacer()
                    Button {
                        save(viewModel.config.excludedProviders.filter { $0 != provider })
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Stop excluding this provider")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(ScarfColor.backgroundTertiary.opacity(0.5))
            }
            HStack {
                TextField("Provider ID (e.g. openrouter)", text: $newProvider)
                    .textFieldStyle(.roundedBorder)
                    .font(ScarfFont.monoSmall)
                    .onSubmit { addNew(newProvider) }
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { id in
                            Button(id) { addNew(id) }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                    .help("Known provider IDs")
                }
                Button("Add") { addNew(newProvider) }
                    .controlSize(.small)
                    .disabled(newProvider.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(ScarfColor.backgroundTertiary.opacity(0.5))
            .help("Excluded providers are hidden from model pickers and skipped by Hermes's built-in model resolution.")
        }
        .task {
            let ids = await ModelCatalogService(context: viewModel.context)
                .loadProvidersAsync()
                .map(\.providerID)
            knownProviderIDs = ids.sorted()
        }
    }

    private var suggestions: [String] {
        let excluded = Set(viewModel.config.excludedProviders.map { $0.lowercased() })
        return knownProviderIDs.filter { !excluded.contains($0.lowercased()) }
    }

    private func addNew(_ raw: String) {
        let id = raw.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        guard !viewModel.config.excludedProviders.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else {
            newProvider = ""
            return
        }
        save(viewModel.config.excludedProviders + [id])
        newProvider = ""
    }

    private func save(_ providers: [String]) {
        viewModel.saveExcludedProviders(providers, capabilities: capabilities)
    }
}
