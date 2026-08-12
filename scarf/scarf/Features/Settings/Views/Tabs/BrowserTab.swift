import SwiftUI
import ScarfCore

/// Browser tab — browser cloud provider + automation timeouts + camofox.
struct BrowserTab: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    /// Selecting the empty "Auto-detect" row removes the key via
    /// `hermes config unset`, which only exists on v0.19+. On older hosts the
    /// row is dropped rather than offered-and-failing — writing `""` instead
    /// is not an option, because Hermes normalizes a present-but-empty
    /// `browser.cloud_provider` to `local`.
    private var providerOptions: [(id: String, label: String)] {
        let all = viewModel.browserCloudProviders
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

    var body: some View {
        SettingsSection(title: "Provider", icon: "globe") {
            PickerRow(
                label: "Provider",
                selection: viewModel.config.browserCloudProvider,
                options: providerOptions.map(\.id),
                optionLabel: { id in
                    providerOptions.first { $0.id == id }?.label ?? id
                }
            ) { viewModel.setBrowserCloudProvider($0) }
        }

        SettingsSection(title: "Timeouts", icon: "hourglass") {
            StepperRow(label: "Inactivity (s)", value: viewModel.config.browser.inactivityTimeout, range: 10...3600, step: 10) { viewModel.setBrowserInactivityTimeout($0) }
            StepperRow(label: "Command (s)", value: viewModel.config.browser.commandTimeout, range: 5...600, step: 5) { viewModel.setBrowserCommandTimeout($0) }
        }

        SettingsSection(title: "Behavior", icon: "slider.horizontal.below.rectangle") {
            ToggleRow(label: "Record Sessions", isOn: viewModel.config.browser.recordSessions) { viewModel.setBrowserRecordSessions($0) }
            ToggleRow(label: "Allow Private URLs", isOn: viewModel.config.browser.allowPrivateURLs) { viewModel.setBrowserAllowPrivateURLs($0) }
        }

        SettingsSection(title: "Camofox", icon: "eye.slash") {
            ToggleRow(label: "Managed Persistence", isOn: viewModel.config.browser.camofoxManagedPersistence) { viewModel.setCamofoxManagedPersistence($0) }
        }
    }
}
