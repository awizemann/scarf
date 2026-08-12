import AppKit
import SwiftUI
import ScarfCore
import UniformTypeIdentifiers

/// Advanced tab — network, compression, checkpoints, logging, delegation, file read cap,
/// cron wrap, config diagnostics, backup/restore, paths, raw config.
///
/// v0.12 added a "Caching & Redaction" section near the top: prompt cache
/// TTL picker (5m / 1h), the redaction toggle (off-by-default in v0.12 —
/// we surface a toggle so security-sensitive users can flip it back on),
/// and the runtime metadata footer toggle. All three are gated on
/// `HermesCapabilities` so a v0.11 host doesn't see toggles that write
/// keys it ignores.
struct AdvancedTab: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    @State private var showRawConfig = false
    @State private var showRestoreConfirm = false
    @State private var pendingRestorePath: String?
    @State private var showRemoteRestoreSheet = false
    @State private var diagnosticsOutput: String = ""
    @State private var showDiagnostics = false

    var body: some View {
        if capabilitiesStore?.capabilities.hasPromptCacheTTL ?? false {
            v012CachingSection
        }

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
            // v0.20 tuning keys — hidden on older hosts so the tab renders
            // exactly as before and no ignored keys get written.
            if capabilitiesStore?.capabilities.isV020OrLater ?? false {
                StepperRow(label: "Token Threshold", value: viewModel.config.compression.thresholdTokens, range: 0...1_000_000, step: 25_000) { viewModel.setCompressionThresholdTokens($0) }
                    .help("Absolute token cap: compression triggers at the LOWER of the ratio Threshold above and this token count. 0 = use the ratio threshold only.")
                StepperRow(label: "Min Tail User Msgs", value: viewModel.config.compression.minTailUserMessages, range: 1...20) { viewModel.setCompressionMinTailUserMessages($0) }
                    .help("Recent real user messages guaranteed to survive uncompressed, even when bulky tool output fills the tail budget. Hermes default: 1.")
                StepperRow(label: "Idle Compact (s)", value: viewModel.config.compression.idleCompactAfterSeconds, range: 0...86_400, step: 300) { viewModel.setCompressionIdleCompactAfterSeconds($0) }
                    .help("Compact a session's history up front when it resumes after this many seconds idle, before the first reply. 0 = off. Example: 1800 = 30 minutes.")
                ToggleRow(label: "Progress Notices", isOn: viewModel.config.compression.progressNotices) { viewModel.setCompressionProgressNotices($0) }
                    .help("Deliver routine compression progress statuses to chat gateway platforms. Off keeps routine compaction silent on chat surfaces; failures and manual /compress feedback always show.")
            }
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

        if capabilitiesStore?.capabilities.isV017OrLater ?? false {
            v017Section
        }

        if capabilitiesStore?.capabilities.hasSharedMetricsTelemetry ?? false {
            telemetrySection
        }

        if capabilitiesStore?.capabilities.hasDatabaseJournalSettings ?? false {
            databaseSection
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
        ScarfMonDiagnosticsSection()
        rawConfigSection
    }

    /// v0.17 knobs — curator consolidation (now opt-in) + a concurrent-session
    /// cap. Gated so a pre-v0.17 host never sees toggles that write keys it
    /// ignores.
    @ViewBuilder
    private var v017Section: some View {
        SettingsSection(title: "Sessions & Curator", icon: "sparkles") {
            ToggleRow(
                label: "Curator consolidation pass",
                isOn: viewModel.config.curatorConsolidate
            ) { viewModel.setCuratorConsolidate($0) }

            consolidationHint

            StepperRow(
                label: "Max concurrent sessions (0 = unlimited)",
                value: viewModel.config.maxConcurrentSessions,
                range: 0...64
            ) { viewModel.setMaxConcurrentSessions($0) }
        }
    }

    /// Inline hint clarifying that v0.17 flipped curator consolidation to
    /// opt-in, so a user who relied on the automatic merge pass knows to
    /// re-enable it.
    @ViewBuilder
    private var consolidationHint: some View {
        HStack {
            Text("")
                .font(.caption)
                .frame(width: 160, alignment: .trailing)
            Text("v0.17 made the LLM skill-merge pass opt-in. Turn this on to restore it; deterministic pruning runs either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// `telemetry.shared_metrics.enabled` — v0.20+, privacy-safe opt-in
    /// aggregate metrics written only to this profile's local telemetry
    /// directory. No remote sink exists; collection is off by default.
    @ViewBuilder
    private var telemetrySection: some View {
        SettingsSection(title: "Telemetry", icon: "chart.bar") {
            ToggleRow(
                label: "Shared usage metrics",
                isOn: viewModel.config.telemetry.sharedMetricsEnabled
            ) { viewModel.setSharedMetricsEnabled($0) }
        }
        HStack {
            Text("")
                .font(.caption)
                .frame(width: 160, alignment: .trailing)
            Text("Privacy-safe aggregate metrics written only to this profile's local telemetry directory. Collection is opt-in and there is no remote sink — nothing leaves this machine.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// `database.*` — SQLite journal mode + WAL sizing pragmas (v0.20+).
    /// Framed for remote/container server operators: WAL is the normal
    /// default, but weak-fsync/shared filesystems (macOS virtiofs, NFS,
    /// SMB) need `delete` instead. `walAutocheckpoint` /
    /// `journalSizeLimit` are true optionals (nil = SQLite default);
    /// unset either via the "Custom" toggle rather than a 0 value, which
    /// means something different (see `DatabaseSettings` doc).
    @ViewBuilder
    private var databaseSection: some View {
        SettingsSection(title: "Database (SQLite)", icon: "cylinder.split.1x2") {
            PickerRow(
                label: "Journal Mode",
                selection: viewModel.config.database.journalMode,
                options: ["wal", "delete"]
            ) { viewModel.setDatabaseJournalMode($0) }

            optionalIntRow(
                label: "WAL Autocheckpoint (pages)",
                value: viewModel.config.database.walAutocheckpoint,
                range: 0...1_000_000,
                step: 100,
                onChange: { viewModel.setDatabaseWalAutocheckpoint($0) }
            )
            optionalIntRow(
                label: "Journal Size Limit (bytes)",
                value: viewModel.config.database.journalSizeLimit,
                range: 0...1_073_741_824,
                step: 1_048_576,
                onChange: { viewModel.setDatabaseJournalSizeLimit($0) }
            )
        }
        HStack {
            Text("")
                .font(.caption)
                .frame(width: 160, alignment: .trailing)
            Text("`delete` trades WAL's crash-safety guarantees for compatibility with weak-fsync or shared filesystems — use it for macOS virtiofs, NFS, or SMB-backed Hermes homes. Autocheckpoint/size-limit pragmas apply only when set; leave them off for SQLite's own defaults (1000-page autocheckpoint, no size cap).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// A true-optional integer row: a "Custom" toggle gates a Stepper.
    /// Turning the toggle off calls `onChange(nil)`, which the caller
    /// wires to `unsetSetting` rather than writing an empty/zero scalar —
    /// this is the empty-string-vs-unset hazard case, so 0 must stay a
    /// distinct, reachable value from "unset".
    @ViewBuilder
    private func optionalIntRow(
        label: String,
        value: Int?,
        range: ClosedRange<Int>,
        step: Int,
        onChange: @escaping (Int?) -> Void
    ) -> some View {
        ToggleRow(label: "\(label) — Custom", isOn: value != nil) { isOn in
            onChange(isOn ? (value ?? range.lowerBound) : nil)
        }
        if let value {
            StepperRow(label: label, value: value, range: range, step: step) { onChange($0) }
        }
    }

    /// Caching, redaction, and runtime-metadata footer — all v0.12+
    /// knobs. The cache_ttl picker is two options today (5m default,
    /// 1h opt-in); when Hermes adds more they should be surfaced here
    /// without changing the writer (`hermes config set` accepts arbitrary
    /// scalars, Hermes validates).
    @ViewBuilder
    private var v012CachingSection: some View {
        SettingsSection(title: "Caching & Redaction", icon: "lock.shield") {
            PickerRow(
                label: "Prompt Cache TTL",
                selection: viewModel.config.cacheTTL,
                options: ["5m", "1h"]
            ) { viewModel.setSetting("prompt_caching.cache_ttl", value: $0) }

            ToggleRow(
                label: "Redact secrets in patches",
                isOn: viewModel.config.redactionEnabled
            ) { viewModel.setSetting("redaction.enabled", value: $0 ? "true" : "false") }

            redactionDefaultsHint

            ToggleRow(
                label: "Runtime metadata footer",
                isOn: viewModel.config.runtimeMetadataFooter
            ) { viewModel.setSetting("display.runtime_footer.enabled", value: $0 ? "true" : "false") }
        }
    }

    /// Inline hint below the redaction toggle. The server-side default
    /// flipped from OFF (v0.12) to ON (v0.13), but Scarf's parser still
    /// reads "absent key" as `false` — meaning a v0.13 host with no
    /// explicit key in `config.yaml` shows the toggle OFF while the
    /// agent treats redaction as ON. Hint copy disambiguates so users
    /// can tell what's actually happening server-side.
    @ViewBuilder
    private var redactionDefaultsHint: some View {
        let isV013 = capabilitiesStore?.capabilities.isV013OrLater ?? false
        HStack {
            Text("")
                .font(.caption)
                .frame(width: 160, alignment: .trailing)
            Text(isV013
                 ? "Recommended: ON. Hermes v0.13+ defaults to redacting secrets unless you opt out."
                 : "Default OFF in Hermes v0.12. Toggle ON to redact secrets in logs and shares.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
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
                    if viewModel.context.isRemote {
                        // The backup zip lives on the remote (that's where
                        // `hermes backup` ran). NSOpenPanel can only browse
                        // the user's Mac, so present a remote-path input
                        // sheet instead.
                        showRemoteRestoreSheet = true
                    } else {
                        if let path = pickLocalBackupZip() {
                            pendingRestorePath = path
                            showRestoreConfirm = true
                        }
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
                if let path = pendingRestorePath {
                    viewModel.runRestore(fromPath: path)
                }
                pendingRestorePath = nil
            }
            Button("Cancel", role: .cancel) { pendingRestorePath = nil }
        } message: {
            Text("This will overwrite files under \(viewModel.context.paths.home) with the archive contents.")
        }
        .sheet(isPresented: $showRemoteRestoreSheet) {
            RemoteBackupPathSheet(
                context: viewModel.context,
                onCancel: { showRemoteRestoreSheet = false },
                onConfirm: { path in
                    showRemoteRestoreSheet = false
                    pendingRestorePath = path
                    showRestoreConfirm = true
                }
            )
        }
    }

    /// NSOpenPanel for local backup zip. Lifted from
    /// `SettingsViewModel.presentRestorePicker` — kept in the view layer
    /// because it's a UI concern that has no business on the VM.
    private func pickLocalBackupZip() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Hermes backup archive to restore"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
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

/// Remote-backup-path picker. NSOpenPanel can only browse the user's
/// Mac, which is the wrong host for a remote restore — `hermes backup`
/// produced the zip on the remote, so the path the user wants is on
/// the remote too. This sheet takes a remote path string + verifies
/// it via `transport.fileExists` before handing it back to the
/// caller. Future iteration: add an "Upload local zip first" path so
/// users can restore from a backup that lives on this Mac.
private struct RemoteBackupPathSheet: View {
    let context: ServerContext
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var path: String = ""
    @State private var verification: Verification = .idle

    private enum Verification: Equatable {
        case idle
        case verifying
        case ok
        case warn(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore from remote backup")
                .font(.headline)
            Text("Enter the path to a Hermes backup `.zip` on \(context.displayName). Hermes ran the backup there, so the file lives on the remote — Scarf can't browse the remote from a local file picker.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("e.g. ~/.hermes-backups/hermes-2026-04-28.zip", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onChange(of: path) { _, _ in
                        if verification != .idle { verification = .idle }
                    }
                Button("Verify") { Task { await verify() } }
                    .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty
                              || verification == .verifying)
            }
            verificationBadge
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restore…") {
                    let trimmed = path.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onConfirm(trimmed)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private var verificationBadge: some View {
        switch verification {
        case .idle:
            EmptyView()
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking on \(context.displayName)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ok:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("File found on \(context.displayName).")
                    .font(.caption)
            }
        case .warn(let detail):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(detail).font(.caption)
            }
        }
    }

    private func verify() async {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        verification = .verifying
        let snapshot = context
        let result: Verification = await Task.detached {
            let transport = snapshot.makeTransport()
            guard transport.fileExists(trimmed) else {
                return .warn("Path doesn't exist on \(snapshot.displayName).")
            }
            guard let stat = transport.stat(trimmed) else {
                return .warn("Found, but couldn't stat — check permissions.")
            }
            if stat.isDirectory {
                return .warn("Path is a directory, not a file. Restore expects a `.zip` archive.")
            }
            if !trimmed.lowercased().hasSuffix(".zip") {
                return .warn("File found, but extension isn't `.zip`. Restore expects a Hermes backup archive.")
            }
            return .ok
        }.value
        verification = result
    }
}
