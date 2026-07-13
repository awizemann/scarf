import SwiftUI
import ScarfCore

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
