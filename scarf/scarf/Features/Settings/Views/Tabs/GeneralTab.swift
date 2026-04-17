import SwiftUI

/// General tab — model picker (provider auto-follows), personality, locale.
/// Credential management lives in the Credential Pools sidebar item; a hint
/// row in this tab deep-links there so users don't have to hunt for it.
struct GeneralTab: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        SettingsSection(title: "Model", icon: "cpu") {
            ModelPickerRow(
                label: "Model",
                currentModel: viewModel.config.model,
                currentProvider: viewModel.config.provider
            ) { modelID, providerID in
                // Selecting a model auto-syncs the provider so the two stay in
                // lockstep. If the picker returns an empty provider (custom
                // entry without a prefix), keep the current one.
                viewModel.setModel(modelID)
                if !providerID.isEmpty {
                    viewModel.setProvider(providerID)
                }
            }
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
