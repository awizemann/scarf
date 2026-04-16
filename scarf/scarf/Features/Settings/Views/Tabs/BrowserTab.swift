import SwiftUI

/// Browser tab — browser backend + automation timeouts + camofox.
struct BrowserTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        SettingsSection(title: "Backend", icon: "globe") {
            PickerRow(label: "Backend", selection: viewModel.config.browserBackend, options: viewModel.browserBackends) { viewModel.setBrowserBackend($0) }
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
