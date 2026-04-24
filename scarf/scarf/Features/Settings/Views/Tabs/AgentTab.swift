import SwiftUI
import ScarfCore

/// Agent tab — turns, reasoning effort, tool use enforcement, approvals, gateway timing, service tier.
struct AgentTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        SettingsSection(title: "Turns & Reasoning", icon: "arrow.2.circlepath") {
            StepperRow(label: "Max Turns", value: viewModel.config.maxTurns, range: 1...200) { viewModel.setMaxTurns($0) }
            PickerRow(label: "Reasoning Effort", selection: viewModel.config.reasoningEffort, options: ["none", "minimal", "low", "medium", "high", "xhigh"]) { viewModel.setReasoningEffort($0) }
            PickerRow(label: "Tool Use Enforcement", selection: viewModel.config.toolUseEnforcement, options: ["auto", "true", "false"]) { viewModel.setToolUseEnforcement($0) }
        }

        SettingsSection(title: "Approvals", icon: "checkmark.shield") {
            PickerRow(label: "Approval Mode", selection: viewModel.config.approvalMode, options: ["auto", "manual", "smart", "off"]) { viewModel.setApprovalMode($0) }
            StepperRow(label: "Approval Timeout (s)", value: viewModel.config.approvalTimeout, range: 5...600, step: 5) { viewModel.setApprovalTimeout($0) }
        }

        SettingsSection(title: "Messaging Gateway", icon: "antenna.radiowaves.left.and.right") {
            ToggleRow(label: "Fast Mode", isOn: viewModel.config.serviceTier == "fast") { on in
                viewModel.setServiceTier(on ? "fast" : "normal")
            }
            StepperRow(label: "Gateway Timeout (s)", value: viewModel.config.gatewayTimeout, range: 60...7200, step: 60) { viewModel.setGatewayTimeout($0) }
            StepperRow(label: "Notify Interval (s)", value: viewModel.config.gatewayNotifyInterval, range: 0...3600, step: 30) { viewModel.setGatewayNotifyInterval($0) }
        }
    }
}
