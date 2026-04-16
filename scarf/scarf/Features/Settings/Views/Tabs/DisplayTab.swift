import SwiftUI

/// Display tab — streaming, reasoning, cost, skin, compact mode, inline diffs, bell, etc.
struct DisplayTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        SettingsSection(title: "Output", icon: "doc.plaintext") {
            ToggleRow(label: "Streaming", isOn: viewModel.config.streaming) { viewModel.setStreaming($0) }
            ToggleRow(label: "Show Reasoning", isOn: viewModel.config.showReasoning) { viewModel.setShowReasoning($0) }
            ToggleRow(label: "Show Cost", isOn: viewModel.config.showCost) { viewModel.setShowCost($0) }
            ToggleRow(label: "Interim Messages", isOn: viewModel.config.interimAssistantMessages) { viewModel.setInterimAssistantMessages($0) }
            ToggleRow(label: "Verbose", isOn: viewModel.config.verbose) { viewModel.setVerbose($0) }
            ToggleRow(label: "Inline Diffs", isOn: viewModel.config.display.inlineDiffs) { viewModel.setInlineDiffs($0) }
        }

        SettingsSection(title: "Layout", icon: "rectangle.3.group") {
            EditableTextField(label: "Skin", value: viewModel.config.display.skin) { viewModel.setSkin($0) }
            ToggleRow(label: "Compact", isOn: viewModel.config.display.compact) { viewModel.setDisplayCompact($0) }
            PickerRow(label: "Resume Display", selection: viewModel.config.display.resumeDisplay, options: ["full", "minimal"]) { viewModel.setResumeDisplay($0) }
            PickerRow(label: "Busy Input Mode", selection: viewModel.config.display.busyInputMode, options: ["interrupt", "queue"]) { viewModel.setBusyInputMode($0) }
        }

        SettingsSection(title: "Tool Progress", icon: "gauge") {
            ToggleRow(label: "Tool Progress Command", isOn: viewModel.config.display.toolProgressCommand) { viewModel.setToolProgressCommand($0) }
            StepperRow(label: "Preview Length", value: viewModel.config.display.toolPreviewLength, range: 0...500, step: 10) { viewModel.setToolPreviewLength($0) }
        }

        SettingsSection(title: "Feedback", icon: "bell") {
            ToggleRow(label: "Bell on Complete", isOn: viewModel.config.display.bellOnComplete) { viewModel.setBellOnComplete($0) }
        }
    }
}
