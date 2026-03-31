import SwiftUI

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @State private var showRawConfig = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                configSection
                gatewaySection
                pathsSection
                rawConfigSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Settings")
        .onAppear { viewModel.load() }
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                SettingRow(label: "Model", value: viewModel.config.model)
                SettingRow(label: "Provider", value: viewModel.config.provider)
                SettingRow(label: "Personality", value: viewModel.config.personality)
                SettingRow(label: "Max Turns", value: "\(viewModel.config.maxTurns)")
                SettingRow(label: "Terminal Backend", value: viewModel.config.terminalBackend)
                SettingRow(label: "Memory Enabled", value: viewModel.config.memoryEnabled ? "Yes" : "No")
                SettingRow(label: "Memory Char Limit", value: "\(viewModel.config.memoryCharLimit)")
                SettingRow(label: "User Char Limit", value: "\(viewModel.config.userCharLimit)")
                SettingRow(label: "Nudge Interval", value: "\(viewModel.config.nudgeInterval) turns")
                SettingRow(label: "Streaming", value: viewModel.config.streaming ? "Yes" : "No")
                SettingRow(label: "Show Reasoning", value: viewModel.config.showReasoning ? "Yes" : "No")
                SettingRow(label: "Verbose", value: viewModel.config.verbose ? "Yes" : "No")
            }
        }
    }

    private var gatewaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gateway")
                .font(.headline)
            HStack(spacing: 16) {
                Label(
                    viewModel.gatewayState?.statusText ?? "unknown",
                    systemImage: viewModel.gatewayState?.isRunning == true ? "circle.fill" : "circle"
                )
                .foregroundStyle(viewModel.gatewayState?.isRunning == true ? .green : .secondary)
                if let reason = viewModel.gatewayState?.exitReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var pathsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paths")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                PathRow(label: "Hermes Home", path: HermesPaths.home)
                PathRow(label: "State DB", path: HermesPaths.stateDB)
                PathRow(label: "Config", path: HermesPaths.configYAML)
                PathRow(label: "Memory", path: HermesPaths.memoriesDir)
                PathRow(label: "Sessions", path: HermesPaths.sessionsDir)
                PathRow(label: "Skills", path: HermesPaths.skillsDir)
                PathRow(label: "Logs", path: HermesPaths.errorsLog)
            }
        }
    }

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

struct SettingRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
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
                .frame(width: 100, alignment: .trailing)
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            } label: {
                Image(systemName: "folder")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
    }
}
