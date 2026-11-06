import SwiftUI
import ScarfCore

/// Browser tab — browser cloud provider + automation timeouts + camofox.
struct BrowserTab: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.serverContext) private var serverContext
    private var capabilities: HermesCapabilities { capabilitiesStore?.capabilities ?? .empty }

    /// Selecting the empty "Auto-detect" row removes the key via
    /// `hermes config unset`, which only exists on v0.19+. On older hosts the
    /// row is dropped rather than offered-and-failing — writing `""` instead
    /// is not an option, because Hermes normalizes a present-but-empty
    /// `browser.cloud_provider` to `local`.
    private var providerOptions: [(id: String, label: String)] {
        let all = Self.providerRows(
            viewModel.browserCloudProviders,
            capabilities: capabilities,
            current: viewModel.config.browserCloudProvider,
            camofoxInstalled: camofoxInstalled
        )
        guard capabilitiesStore?.capabilities.hasConfigUnset == true else {
            // Keep the row visible when it is the current state, so a config
            // with the key absent still renders a selected label instead of a
            // blank picker; it just cannot be chosen back into.
            return viewModel.config.browserCloudProvider.isEmpty
                ? all
                : all.filter { !$0.id.isEmpty }
        }
        return all
    }

    /// The window's cached Plugins roster — the same `plugins list` data
    /// (through the window's transport, loaded off the main actor) that
    /// ``PluginRequiredNote`` decides with.
    private var pluginsViewModel: PluginsViewModel {
        coordinator.featureViewModel(for: .plugins) { PluginsViewModel(context: serverContext) }
    }

    /// Whether the `camofox` plugin is installed. `nil` until the roster has
    /// loaded; only consulted on `hasCamofoxLeftCore` hosts.
    private var camofoxInstalled: Bool? {
        let vm = pluginsViewModel
        guard vm.rosterLoaded else { return nil }
        return vm.pluginActivation("camofox") != nil
    }

    /// v0.22.6+: Camofox left core for the `camofox` plugin
    /// (`hermes_cli/left_core_migration.py:489-495` @ v0.23.0). The provider
    /// row is offered only when the plugin is installed — or when it is the
    /// stored value, so the picker never renders a blank selection. Older
    /// hosts get the list unchanged (C1).
    static func providerRows(
        _ all: [(id: String, label: String)],
        capabilities: HermesCapabilities,
        current: String,
        camofoxInstalled: Bool?
    ) -> [(id: String, label: String)] {
        guard capabilities.hasCamofoxLeftCore, camofoxInstalled != true, current != "camofox" else { return all }
        return all.filter { $0.id != "camofox" }
    }

    /// The Managed Persistence control: always below v0.22.6; from v0.22.6
    /// only when the plugin (which now reads the key) is installed.
    static func showsCamofoxSection(capabilities: HermesCapabilities, camofoxInstalled: Bool?) -> Bool {
        !capabilities.hasCamofoxLeftCore || camofoxInstalled == true
    }

    /// The plugin-missing note: a v0.22.6+ host whose stored provider is
    /// `camofox` while the roster (once loaded) lacks the plugin.
    static func showsCamofoxMissingNote(capabilities: HermesCapabilities, current: String, camofoxInstalled: Bool?) -> Bool {
        capabilities.hasCamofoxLeftCore && current == "camofox" && camofoxInstalled == false
    }

    /// `browser.record_sessions` is gone at v0.22.6 (`config_defaults.py:411-416`).
    static func showsRecordSessions(capabilities: HermesCapabilities) -> Bool {
        !capabilities.hasBrowserRecordSessionsRemoved
    }

    var body: some View {
        SettingsSection(title: "Provider", icon: "globe") {
            PickerRow(
                label: "Provider",
                selection: viewModel.config.browserCloudProvider,
                options: providerOptions.map(\.id),
                optionLabel: { id in
                    providerOptions.first { $0.id == id }?.label ?? id
                }
            ) { viewModel.setBrowserCloudProvider($0, capabilities: capabilities) }
            if Self.showsCamofoxMissingNote(capabilities: capabilities, current: viewModel.config.browserCloudProvider, camofoxInstalled: camofoxInstalled) {
                PluginRequiredNote(pluginID: "camofox", feature: "The Camofox browser provider")
                HStack(spacing: 6) {
                    Text("Or in Terminal:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "hermes plugins install camofox")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .task(id: capabilities.hasCamofoxLeftCore) {
            // Only v0.22.6+ hosts need the roster here; older hosts never
            // issue the probe (C1).
            if capabilities.hasCamofoxLeftCore { pluginsViewModel.load() }
        }

        SettingsSection(title: "Timeouts", icon: "hourglass") {
            StepperRow(label: "Inactivity (s)", value: viewModel.config.browser.inactivityTimeout, range: 10...3600, step: 10) { viewModel.setBrowserInactivityTimeout($0) }
            StepperRow(label: "Command (s)", value: viewModel.config.browser.commandTimeout, range: 5...600, step: 5) { viewModel.setBrowserCommandTimeout($0) }
        }

        SettingsSection(title: "Behavior", icon: "slider.horizontal.below.rectangle") {
            if Self.showsRecordSessions(capabilities: capabilities) {
                ToggleRow(label: "Record Sessions", isOn: viewModel.config.browser.recordSessions) { viewModel.setBrowserRecordSessions($0) }
            }
            ToggleRow(label: "Allow Private URLs", isOn: viewModel.config.browser.allowPrivateURLs) { viewModel.setBrowserAllowPrivateURLs($0) }
        }

        if Self.showsCamofoxSection(capabilities: capabilities, camofoxInstalled: camofoxInstalled) {
            SettingsSection(title: "Camofox", icon: "eye.slash") {
                ToggleRow(label: "Managed Persistence", isOn: viewModel.config.browser.camofoxManagedPersistence) { viewModel.setCamofoxManagedPersistence($0) }
            }
        }
    }
}
