import SwiftUI
import ScarfCore
import ScarfDesign

/// Secrets tab — Bitwarden Secrets Manager bootstrap (`secrets.bitwarden.*`,
/// Hermes v0.15). A single bootstrap access token (whose env-var NAME is set
/// here; the token VALUE lives in `~/.hermes/.env`) lets Hermes resolve
/// per-provider API keys from a Bitwarden Secrets Manager project, replacing
/// per-provider keys scattered across config/.env.
///
/// The whole tab is release-gated in `SettingsView` — pre-v0.15 hosts never
/// see it. Server URL empty = US Cloud; `https://vault.bitwarden.eu` = EU; or
/// a self-hosted vault URL.
struct SecretsTab: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    @State private var statusOutput: String = ""
    @State private var isCheckingStatus = false
    @State private var showStatus = false

    private var bitwarden: BitwardenSettings { viewModel.config.bitwarden }
    private var commandSecrets: CommandSecretsSettings { viewModel.config.commandSecrets }

    var body: some View {
        SettingsSection(title: "Bitwarden Secrets Manager", icon: "key.horizontal") {
            ToggleRow(label: "Enabled", isOn: bitwarden.enabled) { viewModel.setBitwardenEnabled($0) }
            EditableTextField(label: "Access Token Env Var", value: bitwarden.accessTokenEnv) { viewModel.setBitwardenAccessTokenEnv($0) }
            EditableTextField(label: "Project ID", value: bitwarden.projectID) { viewModel.setBitwardenProjectID($0) }
            ToggleRow(label: "Override Existing", isOn: bitwarden.overrideExisting) { viewModel.setBitwardenOverrideExisting($0) }
            EditableTextField(label: "Server URL", value: bitwarden.serverURL) { viewModel.setBitwardenServerURL($0) }
            StepperRow(label: "Cache TTL (s)", value: bitwarden.cacheTTLSeconds, range: 0...86400, step: 30) { viewModel.setBitwardenCacheTTLSeconds($0) }
            ToggleRow(label: "Auto Install SDK", isOn: bitwarden.autoInstall) { viewModel.setBitwardenAutoInstall($0) }
        }

        Text("The bootstrap access token itself goes in `~/.hermes/.env` as the env var named above (default `BWS_ACCESS_TOKEN`) — never in config.yaml. Leave Server URL empty for US Cloud, use `https://vault.bitwarden.eu` for EU, or a self-hosted vault URL.")
            .scarfStyle(.caption)
            .foregroundStyle(ScarfColor.foregroundMuted)
            .padding(.horizontal, ScarfSpace.s4)

        if capabilitiesStore?.capabilities.hasBitwardenEncryptedCache ?? false {
            encryptedCacheSection
        }

        if capabilitiesStore?.capabilities.hasCommandSecretSource ?? false {
            commandSecretsSection
        }

        SettingsSection(title: "Status", icon: "stethoscope") {
            HStack {
                Text("Actions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .trailing)
                Button("Check Status") {
                    isCheckingStatus = true
                    Task {
                        statusOutput = await viewModel.bitwardenStatus()
                        isCheckingStatus = false
                        showStatus = true
                    }
                }
                .controlSize(.small)
                .disabled(isCheckingStatus)
                if isCheckingStatus {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.3))

            if showStatus {
                Text(statusOutput.isEmpty ? "(no output)" : statusOutput)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5))
            }
        }
    }

    // MARK: - Encrypted cache (v0.20+, `secrets.bitwarden.encrypted_cache`)

    /// Optional encrypted last-good fallback for Bitwarden network/timeout
    /// outages. Auth failures never fall back — only NETWORK/TIMEOUT.
    private var encryptedCacheSection: some View {
        let cache = bitwarden.encryptedCache
        return SettingsSection(title: "Encrypted Stale Cache", icon: "lock.doc") {
            ToggleRow(label: "Enabled", isOn: cache.enabled) { viewModel.setBitwardenEncryptedCacheEnabled($0) }
            StepperRow(label: "Max Stale (s)", value: cache.maxStaleSeconds, range: 0...604_800, step: 60) { viewModel.setBitwardenEncryptedCacheMaxStaleSeconds($0) }
                .help("How long a cached secret stays usable after Bitwarden becomes unreachable due to a network or timeout error. 0 = no stale fallback (Hermes default).")
        }
    }

    // MARK: - Command helper (v0.20+, `secrets.command.*`)

    /// Any-CLI vault helper secret source — composes with Bitwarden/
    /// 1Password rather than replacing them.
    private var commandSecretsSection: some View {
        let cmd = commandSecrets
        return VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Command Helper", icon: "terminal") {
                ToggleRow(label: "Enabled", isOn: cmd.enabled) { viewModel.setCommandSecretsEnabled($0) }
                EditableTextField(label: "Command", value: cmd.command) { viewModel.setCommandSecretsCommand($0) }
                DoubleStepperRow(label: "Helper Timeout (s)", value: cmd.helperTimeoutSeconds, range: 0.5...60, step: 0.5) { viewModel.setCommandSecretsHelperTimeoutSeconds($0) }
                ToggleRow(label: "Override Existing", isOn: cmd.overrideExisting) { viewModel.setCommandSecretsOverrideExisting($0) }
            }
            Text("Run via `/bin/sh -c` with the same trust level as your own `.env` file — the requested secret key is passed only through an environment variable, never interpolated into the command string. Must print `KEY=VALUE` lines on stdout; keep it fast and non-interactive (no unlock prompts). Override Existing defaults off, unlike Bitwarden/1Password, since a local helper isn't a central rotation authority.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, ScarfSpace.s4)
        }
    }
}
