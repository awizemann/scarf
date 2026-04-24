import SwiftUI
import ScarfCore

/// Advanced tab — network, compression, checkpoints, logging, delegation, file read cap,
/// cron wrap, config diagnostics, backup/restore, paths, raw config.
struct AdvancedTab: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var showRawConfig = false
    @State private var showRestoreConfirm = false
    @State private var pendingRestoreURL: URL?
    @State private var diagnosticsOutput: String = ""
    @State private var showDiagnostics = false

    var body: some View {
        SettingsSection(title: "Network", icon: "network") {
            ToggleRow(label: "Force IPv4", isOn: viewModel.config.forceIPv4) { viewModel.setForceIPv4($0) }
        }

        SettingsSection(title: "Context & Compression", icon: "arrow.down.right.and.arrow.up.left") {
            ReadOnlyRow(label: "Context Engine", value: viewModel.config.contextEngine)
            StepperRow(label: "File Read Max", value: viewModel.config.fileReadMaxChars, range: 1000...1_000_000, step: 1000) { viewModel.setFileReadMaxChars($0) }
            ToggleRow(label: "Compression Enabled", isOn: viewModel.config.compression.enabled) { viewModel.setCompressionEnabled($0) }
            DoubleStepperRow(label: "Threshold", value: viewModel.config.compression.threshold, range: 0.1...1.0, step: 0.05) { viewModel.setCompressionThreshold($0) }
            DoubleStepperRow(label: "Target Ratio", value: viewModel.config.compression.targetRatio, range: 0.05...0.9, step: 0.05) { viewModel.setCompressionTargetRatio($0) }
            StepperRow(label: "Protect Last N", value: viewModel.config.compression.protectLastN, range: 0...100) { viewModel.setCompressionProtectLastN($0) }
        }

        SettingsSection(title: "Checkpoints", icon: "clock.arrow.circlepath") {
            ToggleRow(label: "Enabled", isOn: viewModel.config.checkpoints.enabled) { viewModel.setCheckpointsEnabled($0) }
            StepperRow(label: "Max Snapshots", value: viewModel.config.checkpoints.maxSnapshots, range: 1...500, step: 5) { viewModel.setCheckpointsMaxSnapshots($0) }
        }

        SettingsSection(title: "Logging", icon: "doc.text") {
            PickerRow(label: "Level", selection: viewModel.config.logging.level, options: ["DEBUG", "INFO", "WARNING", "ERROR"]) { viewModel.setLoggingLevel($0) }
            StepperRow(label: "Max Size (MB)", value: viewModel.config.logging.maxSizeMB, range: 1...100) { viewModel.setLoggingMaxSizeMB($0) }
            StepperRow(label: "Backup Count", value: viewModel.config.logging.backupCount, range: 0...20) { viewModel.setLoggingBackupCount($0) }
        }

        SettingsSection(title: "Delegation", icon: "arrow.triangle.branch") {
            // Delegation has its own model/provider pair (tasks spawned by the
            // agent use this instead of the main model). The picker keeps the
            // two in sync just like Settings → General.
            ModelPickerRow(
                label: "Model",
                currentModel: viewModel.config.delegation.model,
                currentProvider: viewModel.config.delegation.provider
            ) { modelID, providerID in
                viewModel.setDelegationModel(modelID)
                if !providerID.isEmpty {
                    viewModel.setDelegationProvider(providerID)
                }
            }
            ReadOnlyRow(label: "Provider", value: viewModel.config.delegation.provider)
            EditableTextField(label: "Base URL", value: viewModel.config.delegation.baseURL) { viewModel.setDelegationBaseURL($0) }
            StepperRow(label: "Max Iterations", value: viewModel.config.delegation.maxIterations, range: 1...500, step: 5) { viewModel.setDelegationMaxIterations($0) }
        }

        SettingsSection(title: "Cron", icon: "clock") {
            ToggleRow(label: "Wrap Response", isOn: viewModel.config.cronWrapResponse) { viewModel.setCronWrapResponse($0) }
        }

        SettingsSection(title: "Config Diagnostics", icon: "stethoscope") {
            HStack {
                Text("Actions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .trailing)
                Button("Check") {
                    diagnosticsOutput = viewModel.runConfigCheck()
                    showDiagnostics = true
                }
                .controlSize(.small)
                Button("Migrate") {
                    diagnosticsOutput = viewModel.runConfigMigrate()
                    showDiagnostics = true
                }
                .controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.3))

            if showDiagnostics {
                Text(diagnosticsOutput.isEmpty ? "(no output)" : diagnosticsOutput)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5))
            }
        }

        backupSection
        pathsSection
        rawConfigSection
    }

    private var backupSection: some View {
        SettingsSection(title: "Backup & Restore", icon: "externaldrive") {
            HStack {
                Text("Archive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .trailing)
                Button {
                    viewModel.runBackup()
                } label: {
                    Label("Backup Now", systemImage: "arrow.down.doc")
                }
                .controlSize(.small)
                .disabled(viewModel.backupInProgress)
                Button {
                    if let url = viewModel.presentRestorePicker() {
                        pendingRestoreURL = url
                        showRestoreConfirm = true
                    }
                } label: {
                    Label("Restore…", systemImage: "arrow.up.doc")
                }
                .controlSize(.small)
                .disabled(viewModel.backupInProgress)
                if viewModel.backupInProgress {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.3))
        }
        .confirmationDialog("Restore from backup?", isPresented: $showRestoreConfirm) {
            Button("Restore", role: .destructive) {
                if let url = pendingRestoreURL {
                    viewModel.runRestore(from: url)
                }
                pendingRestoreURL = nil
            }
            Button("Cancel", role: .cancel) { pendingRestoreURL = nil }
        } message: {
            Text("This will overwrite files under ~/.hermes/ with the archive contents.")
        }
    }

    private var pathsSection: some View {
        let paths = viewModel.context.paths
        return SettingsSection(title: "Paths", icon: "folder") {
            PathRow(label: "Hermes Home", path: paths.home)
            PathRow(label: "State DB", path: paths.stateDB)
            PathRow(label: "Config", path: paths.configYAML)
            PathRow(label: "Memory", path: paths.memoriesDir)
            PathRow(label: "Sessions", path: paths.sessionsDir)
            PathRow(label: "Skills", path: paths.skillsDir)
            PathRow(label: "Agent Log", path: paths.agentLog)
            PathRow(label: "Error Log", path: paths.errorsLog)
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
