import SwiftUI
import ScarfCore

struct HomeAssistantSetupView: View {
    @State private var viewModel: HomeAssistantSetupViewModel
    init(context: ServerContext) { _viewModel = State(initialValue: HomeAssistantSetupViewModel(context: context)) }


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            instructions

            SettingsSection(title: "Connection", icon: "network") {
                EditableTextField(label: "URL", value: viewModel.url) { viewModel.url = $0 }
                SecretTextField(label: "Long-Lived Token", value: viewModel.token) { viewModel.token = $0 }
            }

            SettingsSection(title: "Event Filters", icon: "line.3.horizontal.decrease.circle") {
                ToggleRow(label: "Watch All Changes", isOn: viewModel.watchAll) { viewModel.watchAll = $0 }
                StepperRow(label: "Cooldown (s)", value: viewModel.cooldownSeconds, range: 0...3600, step: 5) { viewModel.cooldownSeconds = $0 }
            }

            listFiltersSection
            saveBar
        }
        .onAppear { viewModel.load() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Create a long-lived access token in Home Assistant (Profile → Security → Long-Lived Access Tokens). By default, no events are forwarded — enable Watch All Changes, or add entity filters below.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Home Assistant Docs") { PlatformSetupHelpers.openURL("https://hermes-agent.nousresearch.com/docs/user-guide/messaging/homeassistant") }
                    .controlSize(.small)
            }
        }
    }

    /// Read-only display of list-valued filters (watch_domains, watch_entities,
    /// ignore_entities). Editing requires hand-modifying config.yaml because
    /// the `hermes config set` CLI can't produce YAML lists — it stores
    /// arrays as quoted strings, which hermes rejects.
    private var listFiltersSection: some View {
        SettingsSection(title: "Entity Filters (config.yaml only)", icon: "list.bullet") {
            ReadOnlyRow(label: "Watch Domains", value: viewModel.watchDomains.joined(separator: ", "))
            ReadOnlyRow(label: "Watch Entities", value: viewModel.watchEntities.joined(separator: ", "))
            ReadOnlyRow(label: "Ignore Entities", value: viewModel.ignoreEntities.joined(separator: ", "))
            HStack {
                Text("")
                    .frame(width: 160, alignment: .trailing)
                Text("These list fields must be edited directly in config.yaml.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Edit config.yaml") { viewModel.openConfigForLists() }
                    .controlSize(.mini)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.3))
        }
    }

    private var saveBar: some View {
        HStack {
            if let msg = viewModel.message {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button("Reload") { viewModel.load() }.controlSize(.small)
            Button("Save") { viewModel.save() }.buttonStyle(.borderedProminent).controlSize(.small)
        }
    }
}
