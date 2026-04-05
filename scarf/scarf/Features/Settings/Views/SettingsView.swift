import SwiftUI

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @State private var showRawConfig = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerBar
                modelSection
                displaySection
                terminalSection
                voiceSection
                memorySection
                pathsSection
                rawConfigSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Settings")
        .onAppear { viewModel.load() }
    }

    private var headerBar: some View {
        HStack {
            if let msg = viewModel.saveMessage {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button("Open in Editor") { viewModel.openConfigInEditor() }
                .controlSize(.small)
            Button("Reload") { viewModel.load() }
                .controlSize(.small)
        }
    }

    // MARK: - Model & Provider

    private var modelSection: some View {
        SettingsSection(title: "Model", icon: "cpu") {
            EditableTextField(label: "Model", value: viewModel.config.model) { viewModel.setModel($0) }
            PickerRow(label: "Provider", selection: viewModel.config.provider, options: viewModel.providers) { viewModel.setProvider($0) }
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        SettingsSection(title: "Display", icon: "paintbrush") {
            if !viewModel.personalities.isEmpty {
                PickerRow(label: "Personality", selection: viewModel.config.personality, options: viewModel.personalities) { viewModel.setPersonality($0) }
            } else {
                EditableTextField(label: "Personality", value: viewModel.config.personality) { viewModel.setPersonality($0) }
            }
            ToggleRow(label: "Streaming", isOn: viewModel.config.streaming) { viewModel.setStreaming($0) }
            ToggleRow(label: "Show Reasoning", isOn: viewModel.config.showReasoning) { viewModel.setShowReasoning($0) }
            ToggleRow(label: "Show Cost", isOn: viewModel.config.showCost) { viewModel.setShowCost($0) }
            ToggleRow(label: "Verbose", isOn: viewModel.config.verbose) { viewModel.setVerbose($0) }
        }
    }

    // MARK: - Terminal

    private var terminalSection: some View {
        SettingsSection(title: "Terminal", icon: "terminal") {
            PickerRow(label: "Backend", selection: viewModel.config.terminalBackend, options: viewModel.terminalBackends) { viewModel.setTerminalBackend($0) }
            StepperRow(label: "Max Turns", value: viewModel.config.maxTurns, range: 1...200) { viewModel.setMaxTurns($0) }
            PickerRow(label: "Reasoning Effort", selection: viewModel.config.reasoningEffort, options: ["low", "medium", "high"]) { viewModel.setReasoningEffort($0) }
            PickerRow(label: "Approval Mode", selection: viewModel.config.approvalMode, options: ["auto", "manual", "smart"]) { viewModel.setApprovalMode($0) }
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        SettingsSection(title: "Voice", icon: "mic") {
            ToggleRow(label: "Auto TTS", isOn: viewModel.config.autoTTS) { viewModel.setAutoTTS($0) }
            StepperRow(label: "Silence Threshold", value: viewModel.config.silenceThreshold, range: 50...500) { viewModel.setSilenceThreshold($0) }
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        SettingsSection(title: "Memory", icon: "brain") {
            ToggleRow(label: "Memory Enabled", isOn: viewModel.config.memoryEnabled) { viewModel.setMemoryEnabled($0) }
            StepperRow(label: "Memory Char Limit", value: viewModel.config.memoryCharLimit, range: 500...10000) { viewModel.setMemoryCharLimit($0) }
            StepperRow(label: "User Char Limit", value: viewModel.config.userCharLimit, range: 500...10000) { viewModel.setUserCharLimit($0) }
            StepperRow(label: "Nudge Interval", value: viewModel.config.nudgeInterval, range: 1...50) { viewModel.setNudgeInterval($0) }
        }
    }

    // MARK: - Paths

    private var pathsSection: some View {
        SettingsSection(title: "Paths", icon: "folder") {
            PathRow(label: "Hermes Home", path: HermesPaths.home)
            PathRow(label: "State DB", path: HermesPaths.stateDB)
            PathRow(label: "Config", path: HermesPaths.configYAML)
            PathRow(label: "Memory", path: HermesPaths.memoriesDir)
            PathRow(label: "Sessions", path: HermesPaths.sessionsDir)
            PathRow(label: "Skills", path: HermesPaths.skillsDir)
            PathRow(label: "Logs", path: HermesPaths.errorsLog)
        }
    }

    // MARK: - Raw Config

    private var rawConfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Raw Config")
                    .font(.headline)
                Button(showRawConfig ? "Hide" : "Show") {
                    showRawConfig.toggle()
                }
                .controlSize(.small)
            }
            if showRawConfig {
                Text(viewModel.rawConfigYAML)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Reusable Components

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            VStack(spacing: 1) {
                content
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct EditableTextField: View {
    let label: String
    let value: String
    let onCommit: (String) -> Void
    @State private var text: String = ""
    @State private var isEditing = false

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            if isEditing {
                TextField(label, text: $text, onCommit: {
                    if text != value { onCommit(text) }
                    isEditing = false
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                Button("Cancel") { isEditing = false }
                    .controlSize(.mini)
            } else {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                Button("Edit") {
                    text = value
                    isEditing = true
                }
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }
}

struct PickerRow: View {
    let label: String
    let selection: String
    let options: [String]
    let onChange: (String) -> Void

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            Picker("", selection: Binding(
                get: { selection },
                set: { onChange($0) }
            )) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .frame(maxWidth: 250)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }
}

struct ToggleRow: View {
    let label: String
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { onChange($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }
}

struct StepperRow: View {
    let label: String
    let value: Int
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            Text("\(value)")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 50)
            Stepper("", value: Binding(
                get: { value },
                set: { onChange($0) }
            ), in: range)
            .labelsHidden()
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }
}

struct PathRow: View {
    let label: String
    let path: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            } label: {
                Image(systemName: "folder")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }
}
