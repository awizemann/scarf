import SwiftUI
import ScarfCore

/// Security tab — redaction, command allowlist (read-only), Tirith sandbox, website blocklist, human delay.
struct SecurityTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        SettingsSection(title: "Redaction", icon: "eye.slash") {
            ToggleRow(label: "Redact Secrets", isOn: viewModel.config.security.redactSecrets) { viewModel.setRedactSecrets($0) }
            ToggleRow(label: "Redact PII", isOn: viewModel.config.security.redactPII) { viewModel.setRedactPII($0) }
        }

        SettingsSection(title: "Tirith Sandbox", icon: "shield.checkerboard") {
            ToggleRow(label: "Enabled", isOn: viewModel.config.security.tirithEnabled) { viewModel.setTirithEnabled($0) }
            EditableTextField(label: "Binary Path", value: viewModel.config.security.tirithPath) { viewModel.setTirithPath($0) }
            StepperRow(label: "Timeout (s)", value: viewModel.config.security.tirithTimeout, range: 1...60) { viewModel.setTirithTimeout($0) }
            ToggleRow(label: "Fail Open", isOn: viewModel.config.security.tirithFailOpen) { viewModel.setTirithFailOpen($0) }
        }

        SettingsSection(title: "Website Blocklist", icon: "xmark.shield") {
            ToggleRow(label: "Enabled", isOn: viewModel.config.security.blocklistEnabled) { viewModel.setBlocklistEnabled($0) }
            if !viewModel.config.security.blocklistDomains.isEmpty {
                ReadOnlyRow(label: "Domains", value: viewModel.config.security.blocklistDomains.joined(separator: ", "))
            }
        }

        if !viewModel.config.commandAllowlist.isEmpty {
            SettingsSection(title: "Command Allowlist", icon: "checkmark.shield") {
                ReadOnlyRow(label: "Commands", value: viewModel.config.commandAllowlist.joined(separator: ", "))
            }
        }

        SettingsSection(title: "Human Delay", icon: "hourglass.tophalf.filled") {
            PickerRow(label: "Mode", selection: viewModel.config.humanDelay.mode, options: ["off", "natural", "custom"]) { viewModel.setHumanDelayMode($0) }
            StepperRow(label: "Min (ms)", value: viewModel.config.humanDelay.minMS, range: 0...10_000, step: 50) { viewModel.setHumanDelayMinMS($0) }
            StepperRow(label: "Max (ms)", value: viewModel.config.humanDelay.maxMS, range: 0...10_000, step: 50) { viewModel.setHumanDelayMaxMS($0) }
        }
    }
}
