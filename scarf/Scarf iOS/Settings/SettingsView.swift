import SwiftUI
import ScarfCore

/// iOS Settings screen. Read-only browser of `~/.hermes/config.yaml`
/// as it currently stands on the remote, grouped into sections that
/// mirror the Mac app's tabs. Source-of-truth toggle at the bottom
/// reveals the raw YAML for users who want to see what the parser
/// consumed.
struct SettingsView: View {
    let config: IOSServerConfig

    @State private var vm: IOSSettingsViewModel
    @State private var showRawYAML = false

    private static let sharedContextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A1"
    )!

    init(config: IOSServerConfig) {
        self.config = config
        let ctx = config.toServerContext(id: Self.sharedContextID)
        _vm = State(initialValue: IOSSettingsViewModel(context: ctx))
    }

    var body: some View {
        List {
            if let err = vm.lastError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if !vm.isLoading || vm.config.model != "unknown" {
                modelSection
                agentSection
                displaySection
                terminalSection
                memorySection
                voiceSection
                securitySection
                compressionSection
                loggingSection
                platformsSection
                rawYAMLToggleSection
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.load() }
        .task { await vm.load() }
        .overlay {
            if vm.isLoading && vm.config.model == "unknown" {
                ProgressView("Loading config.yaml…")
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var modelSection: some View {
        Section("Model") {
            LabeledContent("Default", value: vm.config.model)
            if !vm.config.provider.isEmpty, vm.config.provider != "unknown" {
                LabeledContent("Provider", value: vm.config.provider)
            }
            LabeledContent("Reasoning effort", value: vm.config.reasoningEffort)
            if !vm.config.timezone.isEmpty {
                LabeledContent("Timezone", value: vm.config.timezone)
            }
        }
    }

    @ViewBuilder
    private var agentSection: some View {
        Section("Agent") {
            LabeledContent("Approval mode", value: vm.config.approvalMode)
            LabeledContent("Max turns", value: "\(vm.config.maxTurns)")
            LabeledContent("Service tier", value: vm.config.serviceTier)
            yesNoRow("Verbose logging", vm.config.verbose)
            LabeledContent("Tool use enforcement", value: vm.config.toolUseEnforcement)
        }
    }

    @ViewBuilder
    private var displaySection: some View {
        Section("Display") {
            yesNoRow("Streaming", vm.config.streaming)
            yesNoRow("Show reasoning", vm.config.showReasoning)
            yesNoRow("Show cost", vm.config.showCost)
            LabeledContent("Skin", value: vm.config.display.skin)
            yesNoRow("Compact", vm.config.display.compact)
            yesNoRow("Inline diffs", vm.config.display.inlineDiffs)
            LabeledContent("Personality", value: vm.config.personality)
        }
    }

    @ViewBuilder
    private var terminalSection: some View {
        Section("Terminal") {
            LabeledContent("Backend", value: vm.config.terminalBackend)
            LabeledContent("Cwd", value: vm.config.terminal.cwd)
            LabeledContent("Timeout", value: "\(vm.config.terminal.timeout)s")
            yesNoRow("Persistent shell", vm.config.terminal.persistentShell)
            if !vm.config.terminal.dockerImage.isEmpty {
                LabeledContent("Docker image", value: vm.config.terminal.dockerImage)
            }
        }
    }

    @ViewBuilder
    private var memorySection: some View {
        Section("Memory") {
            yesNoRow("Memory enabled", vm.config.memoryEnabled)
            yesNoRow("User profile enabled", vm.config.userProfileEnabled)
            if vm.config.memoryCharLimit > 0 {
                LabeledContent("Char limit", value: "\(vm.config.memoryCharLimit)")
            }
            if !vm.config.memoryProfile.isEmpty {
                LabeledContent("Profile", value: vm.config.memoryProfile)
            }
            if !vm.config.memoryProvider.isEmpty {
                LabeledContent("Provider", value: vm.config.memoryProvider)
            }
        }
    }

    @ViewBuilder
    private var voiceSection: some View {
        Section("Voice") {
            yesNoRow("Auto TTS", vm.config.autoTTS)
            LabeledContent("TTS provider", value: vm.config.voice.ttsProvider)
            yesNoRow("STT enabled", vm.config.voice.sttEnabled)
            LabeledContent("STT provider", value: vm.config.voice.sttProvider)
        }
    }

    @ViewBuilder
    private var securitySection: some View {
        Section("Security") {
            yesNoRow("Redact secrets", vm.config.security.redactSecrets)
            yesNoRow("Redact PII", vm.config.security.redactPII)
            yesNoRow("Tirith enabled", vm.config.security.tirithEnabled)
            yesNoRow("Website blocklist", vm.config.security.blocklistEnabled)
            if !vm.config.security.blocklistDomains.isEmpty {
                ForEach(vm.config.security.blocklistDomains.prefix(5), id: \.self) { domain in
                    Text(domain)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if vm.config.security.blocklistDomains.count > 5 {
                    Text("+ \(vm.config.security.blocklistDomains.count - 5) more")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var compressionSection: some View {
        Section("Compression") {
            yesNoRow("Enabled", vm.config.compression.enabled)
            LabeledContent("Threshold", value: String(format: "%.2f", vm.config.compression.threshold))
            LabeledContent("Target ratio", value: String(format: "%.2f", vm.config.compression.targetRatio))
            LabeledContent("Protect last N", value: "\(vm.config.compression.protectLastN)")
        }
    }

    @ViewBuilder
    private var loggingSection: some View {
        Section("Logging") {
            LabeledContent("Level", value: vm.config.logging.level)
            LabeledContent("Max size", value: "\(vm.config.logging.maxSizeMB) MB")
            LabeledContent("Backup count", value: "\(vm.config.logging.backupCount)")
        }
    }

    @ViewBuilder
    private var platformsSection: some View {
        Section("Platforms") {
            yesNoRow("Discord: require mention", vm.config.discord.requireMention)
            yesNoRow("Discord: auto-thread", vm.config.discord.autoThread)
            yesNoRow("Telegram: require mention", vm.config.telegram.requireMention)
            LabeledContent("Slack: reply mode", value: vm.config.slack.replyToMode)
            yesNoRow("Matrix: require mention", vm.config.matrix.requireMention)
        }
    }

    @ViewBuilder
    private var rawYAMLToggleSection: some View {
        Section {
            DisclosureGroup("View source (config.yaml)", isExpanded: $showRawYAML) {
                if vm.rawYAML.isEmpty {
                    Text("(empty)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(vm.rawYAML)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } footer: {
            Text("M6 is read-only. Edit config.yaml on the Mac app or via a shell; iOS reflects the current remote state.")
                .font(.caption)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func yesNoRow(_ label: String, _ value: Bool) -> some View {
        LabeledContent(label) {
            Text(value ? "yes" : "no")
                .foregroundStyle(value ? .primary : .secondary)
        }
    }
}
