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
    private var capabilities: HermesCapabilities { capabilitiesStore?.capabilities ?? .empty }
    @State private var showRawConfig = false
    @State private var showRestoreConfirm = false
    @State private var pendingRestorePath: String?
    @State private var showRemoteRestoreSheet = false
    @State private var diagnosticsOutput: String = ""
    @State private var showDiagnostics = false
    /// Local mirror of `Analytics.isEnabled`. Starts `true` to match
    /// swift-stats' documented default (enabled) — this avoids an
    /// off-then-on flash while the async read in `.task` completes; if the
    /// real persisted value is `false` the toggle corrects itself once that
    /// read lands, same as any other async-loaded toggle.
    @State private var analyticsEnabled = true
    /// Guards against the `.task` load's write to `analyticsEnabled`
    /// re-triggering as if the user flipped the toggle — that write must
    /// not turn around and call `Analytics.setEnabled` again.
    @State private var hasLoadedAnalyticsEnabled = false

    var body: some View {
        // P39 (round-4 review): the read-only lock for a managed host stops
        // here, at the write controls. `SettingsView` no longer blacks out
        // this whole tab, because everything below Config Diagnostics is a
        // READ — `hermes config check` (`_cmd_config_check` mutates nothing,
        // `hermes_cli/config.py:3693-3720`), "Backup Now", the Raw Config
        // disclosure, ScarfMon's "Copy as JSON" — and `.disabled` reaches
        // every descendant, text selection included. A managed host has more
        // reason to read its own config than any other, not less.
        //
        // Two Groups only because ViewBuilder tops out at ten children.
        Group {
            Group {
                if capabilitiesStore?.capabilities.hasPromptCacheTTL ?? false {
                    v012CachingSection
                }

                SettingsSection(title: "Network", icon: "network") {
                    ToggleRow(label: "Force IPv4", isOn: viewModel.config.forceIPv4) { viewModel.setForceIPv4($0) }
                    // v0.21.1 — default ON upstream. Turning it off is the fix for a
                    // gateway that inherits a proxy it must not use.
                    if capabilities.isV0211OrLater {
                        ToggleRow(label: "Gateway Trusts Proxy Env", isOn: viewModel.config.gatewayTrustEnv) { viewModel.setGatewayTrustEnv($0) }
                            .help("Lets gateway adapters read HTTP_PROXY / HTTPS_PROXY / NO_PROXY / SSL_CERT_FILE and auto-detect system proxies. Turn OFF when the gateway inherits a proxy it must not use. Per-platform vars (DISCORD_PROXY, …) are honored either way.")
                    }
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
                    // Absent keys show the CONNECTED host's own defaults rather than
                    // one release's. `enabled` has defaulted to false on every
                    // supported host (cli.py `cp_cfg.get("enabled", False)` since
                    // long before the v0.6.0 minimum); `max_snapshots` went 50 → 20
                    // at v0.13.0 (tag v2026.5.7, cli.py:2311). Nothing is written
                    // back until the user actually touches a control.
                    ToggleRow(label: "Enabled", isOn: viewModel.config.displayCheckpointsEnabled(capabilities: capabilities)) { viewModel.setCheckpointsEnabled($0) }
                    StepperRow(label: "Max Snapshots", value: viewModel.config.displayCheckpointsMaxSnapshots(capabilities: capabilities), range: 1...500, step: 5) { viewModel.setCheckpointsMaxSnapshots($0) }
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
                    // Absent keys resolve against the host: v0.20.2 raised the
                    // server-side defaults 50→250 and 3→10 (tag v2026.8.16,
                    // hermes_cli/config_defaults.py:1821 / :1846).
                    StepperRow(label: "Max Iterations", value: viewModel.config.displayDelegationMaxIterations(capabilities: capabilities), range: 1...500, step: 5) { viewModel.setDelegationMaxIterations($0) }
                    // v0.20.4+ — server default 10, floor 1, no ceiling.
                    if capabilitiesStore?.capabilities.isV0204OrLater ?? false {
                        StepperRow(label: "Max Concurrent Children", value: viewModel.config.displayDelegationMaxConcurrentChildren(capabilities: capabilities), range: 1...500, step: 1) { viewModel.setDelegationMaxConcurrentChildren($0) }
                            .help("Max parallel child agents per delegation batch. Values above 10 multiply API cost linearly.")
                    }
                    // v0.21.1+.
                    if capabilities.isV0211OrLater {
                        ToggleRow(label: "Independent Completions", isOn: viewModel.config.delegation.independentCompletions) { viewModel.setDelegationIndependentCompletions($0) }
                            .help("Off (default): a background fan-out returns as one message when the whole call finishes. On: each task returns as it finishes — more orchestrator turns.")
                        // Hermes only enables the cap at >= 16000 and treats
                        // 1...15999 as a config error it warns about and ignores, so
                        // the stepper jumps straight from 0 (off) to the floor
                        // rather than offering values the host would discard.
                        StepperRow(
                            label: "Subagent Compaction Cap",
                            value: viewModel.config.delegation.compressionThresholdTokens,
                            range: 0...1_000_000,
                            step: DelegationSettings.compressionThresholdTokensMinimum,
                            valueLabel: { $0 == 0 ? String(localized: "Off") : $0.formatted() }
                        ) { viewModel.setDelegationCompressionThresholdTokens($0) }
                            .help("Absolute token cap on a subagent's compaction trigger, applied as the lower of this and the child's ratio threshold. Off (0) means children compact at the same ratio as the parent. Hermes ignores any value below 16,000.")
                    }
                }
            }
            Group {
                SettingsSection(title: "Cron", icon: "clock") {
                    ToggleRow(label: "Wrap Response", isOn: viewModel.config.cronWrapResponse) { viewModel.setCronWrapResponse($0) }
                }

                if capabilities.isV0211OrLater {
                    v0211Section
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
            }
        }
        .disabled(viewModel.isManagedHost)

        // OUTSIDE the lock (P39c): this toggle is Scarf's own app-local
        // `UserDefaults` state (swift-stats, keyed by app id) — it never
        // reaches `HermesConfig`, never shells `config set`, and so a managed
        // Hermes has nothing to refuse. See its own doc below. It sat inside
        // the Group, which made the one setting a managed host CAN change the
        // one it could not.
        usageAnalyticsSection

        SettingsSection(title: "Config Diagnostics", icon: "stethoscope") {
            HStack {
                Text("Actions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .trailing)
                Button("Check") {
                    // `config check` spawns `hermes` (an SSH round-trip on a
                    // remote host); running it from the Button action froze
                    // the window until the CLI returned. The output panel
                    // opens immediately and fills in when it lands. It is
                    // read-only (`_cmd_config_check`,
                    // `hermes_cli/config.py:3693-3720` @ v2026.9.7), so it
                    // stays enabled on a managed host too.
                    diagnosticsOutput = String(localized: "Running…")
                    showDiagnostics = true
                    Task { diagnosticsOutput = await viewModel.runConfigCheck() }
                }
                .controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.3))

            // `hermes config migrate` has no button (round-4 decision 4).
            // `_cmd_config_migrate` runs `migrate_config(interactive=True)`
            // (`hermes_cli/config.py:3653-3690` @ v2026.9.7), which reaches
            // `_prompt_and_save_env` → `line_input` → a bare `input()` with no
            // `EOFError` guard (`:1289-1297`, `:1354-1369`;
            // `hermes_cli/cli_output.py:29-37`). Scarf gives the CLI no stdin,
            // so the prompt raises and the run dies AFTER the migrations have
            // been applied and BEFORE `_config_version` is stamped
            // (`:1374-1378`) — a half-migrated config.yaml with the old
            // version number on it. Alan's call: no piped defaults (blank
            // lines are answers to questions we cannot read), so the pane
            // points at the one place the prompts can be answered.
            HStack {
                Text("Migrate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .trailing)
                Text(migrateHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

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

    /// The one-line hint that replaces the old Migrate button. It names the
    /// host the command has to be typed on, because on a remote context the
    /// user's own Mac is the wrong machine.
    ///
    /// **On a managed install the terminal hint is a dead end.**
    /// `_cmd_config_migrate` (`hermes_cli/config.py:3653` @ v2026.9.7) reaches
    /// `save_config`, whose first act is `if is_managed(): managed_error("save
    /// configuration"); return` (`:2315-2318`) — so the command the hint names
    /// refuses at exit 0 no matter where it is typed. A hint that names a
    /// remedy has to be walked like a button (round-4 lesson 3): here the walk
    /// says there is no remedy the user can run, so the copy says who owns the
    /// migration instead.
    private var migrateHint: String {
        Self.migrateHint(
            isManagedHost: viewModel.isManagedHost,
            isRemote: viewModel.context.isRemote,
            hostName: viewModel.context.displayName
        )
    }

    /// The copy itself, separated from the view so it can be asserted
    /// directly (a `View`'s private computed property has no test seam).
    static func migrateHint(isManagedHost: Bool, isRemote: Bool, hostName: String) -> String {
        if isManagedHost {
            return String(localized: "This Hermes is managed by a package manager, so `hermes config migrate` refuses to save. The migration comes with the next managed update.")
        }
        return isRemote
            ? String(localized: "Run `hermes config migrate` in a terminal on \(hostName) — it asks questions Scarf can't answer for you.")
            : String(localized: "Run `hermes config migrate` in a terminal — it asks questions Scarf can't answer for you.")
    }

    /// v0.21.1 knobs that have no older home: the passive update check and
    /// the unattended tool-loop hard stop. Both default ON upstream, so the
    /// toggles render ON for an untouched config — the readers in
    /// `HermesConfig+YAML` default them to `true` for exactly this reason.
    @ViewBuilder
    private var v0211Section: some View {
        SettingsSection(title: "Updates & Guardrails", icon: "arrow.triangle.2.circlepath") {
            ToggleRow(
                label: "Check for updates",
                isOn: viewModel.config.updatesCheck
            ) { viewModel.setUpdatesCheck($0) }
                .help("Passive version and banner checks. `hermes update --check` still works when this is off.")
            ToggleRow(
                label: "Hard-stop tool loops (unattended)",
                isOn: viewModel.config.toolLoopNonInteractiveHardStop
            ) { viewModel.setToolLoopNonInteractiveHardStop($0) }
                .help("Gateway and cron sessions stop a model that keeps repeating failed tool calls — nobody is there to /stop it. Interactive sessions stay warning-only either way.")
        }
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

    /// Telemetry — TWO separate opt-ins, not one.
    ///
    /// `telemetry.shared_metrics.enabled` (v0.20+) turns on local
    /// COLLECTION into this profile's telemetry directory.
    /// `telemetry.shared_metrics.send` (v0.21.1+) is what TRANSMITS the
    /// collected packages to Nous. Through v0.21.0 no sink existed, and
    /// this tab said so; from v0.21.1 that copy is false, so it is now
    /// written per host generation. `send` requires `enabled` (alone it
    /// only logs an error upstream), hence the disabled state rather than
    /// a hidden row — a user who has turned collection off should still
    /// see that transmission exists and is off.
    @ViewBuilder
    private var telemetrySection: some View {
        let hasSend = capabilities.hasSharedMetricsSend
        let collecting = viewModel.config.telemetry.sharedMetricsEnabled
        SettingsSection(title: "Telemetry", icon: "chart.bar") {
            ToggleRow(
                label: "Shared usage metrics",
                isOn: collecting
            ) { viewModel.setSharedMetricsEnabled($0) }
            if hasSend {
                ToggleRow(
                    label: "Send metrics to Nous",
                    isOn: viewModel.config.telemetry.sharedMetricsSend
                ) { viewModel.setSharedMetricsSend($0) }
                    .disabled(!collecting)
                    .help(collecting
                          ? "Uploads the locally collected aggregates. Only data recorded inside an opt-in window is ever sent."
                          : "Turn on Shared usage metrics first — Hermes refuses to send without local collection enabled.")
            }
        }
        telemetryHint(hasSend: hasSend)
    }

    /// Footnote under the Telemetry section. Split out so the two host
    /// generations state exactly what is true of each — the pre-v0.21.1
    /// wording is the byte-identical original.
    @ViewBuilder
    private func telemetryHint(hasSend: Bool) -> some View {
        HStack {
            Text("")
                .font(.caption)
                .frame(width: 160, alignment: .trailing)
            if hasSend {
                Text("Privacy-safe aggregate metrics collected into this profile's local telemetry directory. Collection and sending are separate opt-ins: with sending off, nothing leaves this machine. With both on, only data recorded inside an opt-in window is uploaded to \(viewModel.config.telemetry.sharedMetricsEndpointHost).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Privacy-safe aggregate metrics written only to this profile's local telemetry directory. Collection is opt-in and there is no remote sink — nothing leaves this machine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// Scarf's own opt-out analytics, distinct from the Hermes-side
    /// "Telemetry" section above: this toggle is **app-local** state
    /// persisted by swift-stats in `UserDefaults` (keyed by app id), not a
    /// Hermes config setting — it must never go through
    /// `viewModel.setSetting`/`HermesConfig`.
    @ViewBuilder
    private var usageAnalyticsSection: some View {
        SettingsSection(title: "Usage Analytics", icon: "chart.bar.xaxis") {
            ToggleRow(
                label: "Share anonymous usage statistics",
                isOn: analyticsEnabled
            ) { newValue in
                analyticsEnabled = newValue
                Task { await Analytics.setEnabled(newValue) }
            }
        }
        HStack {
            Text("")
                .font(.caption)
                .frame(width: 160, alignment: .trailing)
            Text("Anonymous usage statistics only — never message content, hostnames, or file paths. Sent to the app developer to improve Scarf. A random identifier for this install is stored on this Mac and sent only as a hash, so active installs can be counted without identifying you.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .task {
            guard !hasLoadedAnalyticsEnabled else { return }
            let enabled = await Analytics.isEnabled
            analyticsEnabled = enabled
            hasLoadedAnalyticsEnabled = true
        }
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

            // `customSeed: 1000` — SQLite's own default autocheckpoint
            // threshold, and the value the footnote below promises. Seeding
            // `range.lowerBound` instead meant flipping "Custom" on wrote
            // `wal_autocheckpoint: 0`, which DISABLES automatic checkpointing
            // outright (`hermes_state_wal.py:466-487` passes the int straight
            // into `PRAGMA wal_autocheckpoint=<n>`) — an unbounded WAL on a
            // gesture the user reads as "let me set a value".
            optionalIntRow(
                label: "WAL Autocheckpoint (pages)",
                customLabel: "WAL Autocheckpoint (pages) — Custom",
                value: viewModel.config.database.walAutocheckpoint,
                range: 0...1_000_000,
                step: 100,
                customSeed: Self.walAutocheckpointSQLiteDefault,
                onChange: { viewModel.setDatabaseWalAutocheckpoint($0, capabilities: capabilities) }
            )
            optionalIntRow(
                label: "Journal Size Limit (bytes)",
                customLabel: "Journal Size Limit (bytes) — Custom",
                value: viewModel.config.database.journalSizeLimit,
                range: 0...1_073_741_824,
                step: 1_048_576,
                onChange: { viewModel.setDatabaseJournalSizeLimit($0, capabilities: capabilities) }
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

    /// SQLite's own `wal_autocheckpoint` threshold, in pages — the value the
    /// database section's footnote promises and the one the "Custom" toggle
    /// seeds. Named rather than inlined because the WRONG seed here (0) is
    /// not a cosmetic default: `hermes_state_wal.py:466-487` passes the
    /// configured int straight into `PRAGMA wal_autocheckpoint=<n>`, and 0
    /// DISABLES automatic checkpointing, leaving the WAL to grow unbounded.
    static let walAutocheckpointSQLiteDefault = 1000

    /// The value the "Custom" toggle writes when switched ON: the current
    /// one if the key is already set, else the row's explicit seed, else the
    /// range's lower bound. Extracted from `optionalIntRow` so the seed is
    /// assertable — the bug it replaces was invisible in a View body.
    static func customToggleValue(current: Int?, seed: Int?, lowerBound: Int) -> Int {
        current ?? seed ?? lowerBound
    }

    /// A true-optional integer row: a "Custom" toggle gates a Stepper.
    /// Turning the toggle off calls `onChange(nil)`, which the caller
    /// wires to `unsetSetting` rather than writing an empty/zero scalar —
    /// this is the empty-string-vs-unset hazard case, so 0 must stay a
    /// distinct, reachable value from "unset".
    @ViewBuilder
    private func optionalIntRow(
        label: LocalizedStringKey,
        customLabel: LocalizedStringKey,
        value: Int?,
        range: ClosedRange<Int>,
        step: Int,
        customSeed: Int? = nil,
        onChange: @escaping (Int?) -> Void
    ) -> some View {
        // `customSeed` is the value the toggle writes when it is switched ON
        // and the key was absent. It defaults to `range.lowerBound` only where
        // that bound is a harmless starting point; pass an explicit seed
        // wherever 0 is a REAL setting with its own meaning (see the WAL
        // autocheckpoint caller).
        ToggleRow(label: customLabel, isOn: value != nil) { isOn in
            onChange(isOn ? Self.customToggleValue(
                current: value, seed: customSeed, lowerBound: range.lowerBound) : nil)
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
        SettingsSection(title: "Caching", icon: "lock.shield") {
            PickerRow(
                label: "Prompt Cache TTL",
                selection: viewModel.config.cacheTTL,
                options: ["5m", "1h"]
            ) { viewModel.setSetting("prompt_caching.cache_ttl", value: $0) }

            // `redaction.enabled` had no reader in Hermes at any version
            // Scarf supports — re-verified at v2026.9.7 (v0.21.1): the only
            // redaction switch is `security.redact_secrets`
            // (`hermes_cli/config_defaults.py:1591`, default `True`, bridged
            // to `HERMES_REDACT_SECRETS` at `cli.py:368-371`), which the
            // Security tab already
            // surfaces. The row wrote a key nobody reads and its "default
            // flipped in v0.13" hint described the OTHER key's history
            // (go/no-go blocking condition 8, A5). Removed with its parse:
            // there is no real host value left to blank.

            ToggleRow(
                label: "Runtime metadata footer",
                isOn: viewModel.config.runtimeMetadataFooter
            ) { viewModel.setSetting("display.runtime_footer.enabled", value: $0 ? "true" : "false") }
        }
    }


    private var backupSection: some View {
        SettingsSection(title: "Backup & Restore", icon: "externaldrive") {
            HStack {
                Text("Archive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .trailing)
                Button {
                    viewModel.runBackup(capabilities: capabilities)
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
                // Restore rewrites config.yaml and `.env` on the host — the
                // same files the package manager owns and reinstates. "Backup
                // Now" above it only READS them into an archive, so it stays
                // enabled on a managed host.
                .disabled(viewModel.backupInProgress || viewModel.isManagedHost)
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
        panel.message = String(localized: "Choose a Hermes backup archive to restore")
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
