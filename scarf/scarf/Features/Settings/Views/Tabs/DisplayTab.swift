import SwiftUI
import ScarfCore
import ScarfDesign

/// Display tab — streaming, reasoning, cost, skin, compact mode, inline diffs, bell, etc.
struct DisplayTab: View {
    @Bindable var viewModel: SettingsViewModel

    /// Scarf-local chat density preferences (issues #47 / #48).
    /// Independent of the Hermes config flags rendered in the
    /// "Output" section below — those control what Hermes EMITS,
    /// these control how Scarf RENDERS what was emitted.
    @AppStorage(ChatDensityKeys.toolCardStyle)
    private var toolCardStyle: String = ToolCardStyle.full.rawValue
    @AppStorage(ChatDensityKeys.reasoningStyle)
    private var reasoningStyle: String = ReasoningStyle.disclosure.rawValue
    @AppStorage(ChatDensityKeys.fontScale)
    private var fontScale: Double = ChatFontScale.default

    var body: some View {
        SettingsSection(title: "Chat density", icon: "rectangle.compress.vertical") {
            DensityPickerRow(
                label: "Tool calls",
                selection: $toolCardStyle,
                options: ToolCardStyle.allCases.map { ($0.rawValue, $0.displayName) }
            )
            DensityPickerRow(
                label: "Reasoning",
                selection: $reasoningStyle,
                options: ReasoningStyle.allCases.map { ($0.rawValue, $0.displayName) }
            )
            FontScaleRow(scale: $fontScale)
            DensityFootnote()
        }

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

// MARK: - Density-section primitives

/// Segmented picker over (rawValue, displayName) tuples — keeps the
/// existing `PickerRow` simple-string contract while still letting us
/// render distinct user-facing labels for each density enum case.
/// Cannot reuse the generic `PickerRow` in `SettingsComponents.swift`:
/// that one is `.menu` style and doesn't accept a separate display
/// name per option.
private struct DensityPickerRow: View {
    let label: String
    @Binding var selection: String
    let options: [(rawValue: String, displayName: String)]

    var body: some View {
        HStack {
            Text(label)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .frame(width: 160, alignment: .trailing)
            Picker("", selection: $selection) {
                ForEach(options, id: \.rawValue) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer()
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, 6)
        .background(ScarfColor.backgroundTertiary.opacity(0.5))
    }
}

private struct FontScaleRow: View {
    @Binding var scale: Double

    var body: some View {
        HStack {
            Text("Chat font size")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .frame(width: 160, alignment: .trailing)
            Slider(
                value: $scale,
                in: ChatFontScale.min...ChatFontScale.max,
                step: ChatFontScale.step
            )
            .frame(maxWidth: 240)
            Text(ChatFontScale.percentLabel(for: scale))
                .font(ScarfFont.monoSmall)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .frame(width: 48, alignment: .leading)
            Button("Reset") {
                scale = ChatFontScale.default
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(abs(scale - ChatFontScale.default) < 0.001)
            Spacer()
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, 6)
        .background(ScarfColor.backgroundTertiary.opacity(0.5))
    }
}

private struct DensityFootnote: View {
    var body: some View {
        Text("Controls how Scarf renders the chat. Use Output → Show Reasoning to control what Hermes sends.")
            .scarfStyle(.caption)
            .foregroundStyle(ScarfColor.foregroundFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.vertical, 6)
    }
}
