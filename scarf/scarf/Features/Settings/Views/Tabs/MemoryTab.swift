import SwiftUI
import ScarfCore

/// Memory tab — built-in memory settings + external provider picker.
struct MemoryTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        SettingsSection(title: "Built-in Memory", icon: "brain") {
            ToggleRow(label: "Memory Enabled", isOn: viewModel.config.memoryEnabled) { viewModel.setMemoryEnabled($0) }
            ToggleRow(label: "User Profile Enabled", isOn: viewModel.config.userProfileEnabled) { viewModel.setUserProfileEnabled($0) }
            if !viewModel.config.memoryProfile.isEmpty {
                ReadOnlyRow(label: "Profile", value: viewModel.config.memoryProfile)
            }
            StepperRow(label: "Memory Char Limit", value: viewModel.config.memoryCharLimit, range: 500...10_000, step: 100) { viewModel.setMemoryCharLimit($0) }
            StepperRow(label: "User Char Limit", value: viewModel.config.userCharLimit, range: 500...10_000, step: 100) { viewModel.setUserCharLimit($0) }
            StepperRow(label: "Nudge Interval", value: viewModel.config.nudgeInterval, range: 1...50) { viewModel.setNudgeInterval($0) }
        }

        SettingsSection(title: "External Provider", icon: "externaldrive.connected.to.line.below") {
            PickerRow(label: "Provider", selection: viewModel.config.memoryProvider, options: viewModel.memoryProviders) { viewModel.setMemoryProvider($0) }
            if viewModel.config.memoryProvider == "honcho" {
                ToggleRow(label: "Honcho Eager Init", isOn: viewModel.config.honchoInitOnSessionStart) { viewModel.setHonchoInitOnSessionStart($0) }
            }
            HStack {
                Text("Setup")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .trailing)
                Text("Run `hermes memory setup` in Terminal for full provider configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.3))
        }
    }
}
