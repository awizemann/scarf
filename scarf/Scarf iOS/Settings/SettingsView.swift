import SwiftUI
import ScarfCore
import ScarfDesign

/// iOS Settings screen. Read-only browser of `~/.hermes/config.yaml`
/// as it currently stands on the remote, grouped into sections that
/// mirror the Mac app's tabs. Source-of-truth toggle at the bottom
/// reveals the raw YAML for users who want to see what the parser
/// consumed.
struct SettingsView: View {
    let config: IOSServerConfig

    @State private var vm: IOSSettingsViewModel
    @State private var showRawYAML = false
    @State private var editingSpec: SettingSpec?
    @State private var showV013FeaturesSheet = false
    /// Live Voice mode write in flight / its failure, for the Voice section.
    @State private var voiceModeSaving = false
    @State private var voiceModeError: String?
    /// This device's Live Voice consents (F4). Device-local, not a Hermes key.
    private let voiceConsent = VoiceDataConsentStore.shared
    @State private var reviewingVoiceConsent: VoiceDataRecipient?
    /// v2.7 — Scarf-local opt-in to bulk-fetch tool result CONTENT
    /// when resuming past chats. Default off; the shared
    /// `RichChatViewModel` reads this same UserDefaults key on
    /// every chat resume so iOS gets the same skeleton-then-hydrate
    /// behavior as Mac.
    @AppStorage(RichChatViewModel.loadHistoricalToolResultsKey)
    private var loadHistoricalToolResults: Bool = false

    /// Drives v0.13 read-only surfaces (features-active badge,
    /// platforms-section additions). Defensive `?? .empty` resolves
    /// every gate to `false` outside `ContextBoundRoot` (preview /
    /// smoke harness) so the v2.7.5 layout is the unconditional
    /// fallback.
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    private var caps: HermesCapabilities {
        capabilitiesStore?.capabilities ?? .empty
    }

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
                        .foregroundStyle(ScarfColor.warning)
                }
            }

            if caps.isV013OrLater {
                v013ActiveBadgeSection
            }

            // P39 (round-4 review): the iOS twin of the Mac's managed-host
            // banner. A package-manager-managed Hermes refuses every config
            // write at exit 0, so the editor rows are locked behind ONE
            // banner rather than each sheet ending in the same refusal.
            if let managed = vm.managedBannerText {
                Section {
                    Label(managed, systemImage: "lock.fill")
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .accessibilityLabel("This Hermes installation is managed; settings are read-only")
                }
            }

            if !vm.isLoading || vm.config.model != "unknown" {
                Group {
                    quickEditsSection
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
                }
                // The write rows only. `diagnosticsSection` and
                // `rawYAMLToggleSection` below are reads, and `.disabled`
                // reaches every descendant — including text selection — so a
                // managed host would otherwise lose the ability to read the
                // config its package manager pinned.
                .disabled(vm.isManagedHost)

                // Outside the managed-host lock: the consent is this
                // device's, not a Hermes setting.
                liveVoicePrivacySection
                diagnosticsSection
                rawYAMLToggleSection
            }
        }
        .scarfGoListDensity()
        .scrollContentBackground(.hidden)
        .background(ScarfColor.backgroundPrimary)
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
        .sheet(item: $editingSpec) { spec in
            SettingEditorSheet(
                spec: spec.resolved(capabilities: caps),
                currentValue: currentValue(for: spec.key),
                vm: vm,
                onDismiss: {}
            )
        }
        .sheet(isPresented: $showV013FeaturesSheet) {
            V013FeaturesSheet()
        }
    }

    /// v0.13 features-active badge. Only shown when the connected host
    /// is on the v0.13 line; tap presents `V013FeaturesSheet`. Read-only
    /// — there's no settings change behind the badge, just a
    /// what's-new affordance.
    @ViewBuilder
    private var v013ActiveBadgeSection: some View {
        Section {
            Button {
                showV013FeaturesSheet = true
            } label: {
                HStack(spacing: 8) {
                    ScarfBadge("v0.13 features active", kind: .success)
                    Spacer()
                    Text("Learn more")
                        .font(.caption)
                        .foregroundStyle(.tint)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(ScarfColor.success.opacity(0.06))
    }

    @ViewBuilder
    private var quickEditsSection: some View {
        Section {
            ForEach(SettingSpec.v1Editable) { spec in
                Button {
                    editingSpec = spec
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spec.displayName)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(verbatim: displayValue(for: spec.key))
                                .font(.caption.monospaced())
                                .foregroundStyle(ScarfColor.foregroundMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Image(systemName: "square.and.pencil")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
                .scarfGoCompactListRow()
            }
        } header: {
            Text("Quick edits")
        } footer: {
            Text("These flip common config.yaml values via `hermes config set` on the remote. Other fields below are read-only; edit them from the Mac app.")
                .font(.caption)
        }
    }

    /// What the Quick-edits row shows. Same string as `currentValue` except
    /// for an ABSENT `approvals.mode`, where the empty sentinel would render
    /// as a blank caption instead of naming the mode the host runs.
    private func displayValue(for key: String) -> String {
        let value = currentValue(for: key)
        if key == "approvals.mode", value.isEmpty {
            return HermesConfig.approvalModeHostDefaultLabel(capabilities: caps)
        }
        return value
    }

    /// Map a config-set key to the current value from the parsed
    /// HermesConfig. String-based so the Picker / Stepper / Toggle in
    /// the editor sheet can pre-fill correctly. Unknown keys return
    /// empty string (the sheet falls back to defaults).
    private func currentValue(for key: String) -> String {
        switch key {
        case "model.default": return vm.config.model
        case "model.provider": return vm.config.provider
        // Empty when the key is ABSENT, which selects the sheet's "Host
        // default (…)" sentinel row. The sheet must not prime a concrete mode
        // for it: on a stock v0.19+ host the absent key means `smart`, and
        // writing `manual` there would pin the mode the sentinel exists to
        // avoid claiming (round-2 decision 5).
        case "approvals.mode": return vm.config.storedApprovalMode?.rawValue ?? ""
        // "Unlimited" for the no-ceiling case; the sheet's `Int(...) ?? 0`
        // priming maps that straight back onto the 0 sentinel.
        case "agent.max_turns": return vm.config.displayMaxTurnsText(capabilities: caps)
        case "display.show_cost": return vm.config.showCost ? "true" : "false"
        // Sentinel-aware: absent key primes the host's own default (true on
        // v0.18.1+), so saving the sheet without touching the toggle cannot
        // flip reasoning off.
        case "display.show_reasoning":
            return vm.config.displayShowReasoning(capabilities: caps) ? "true" : "false"
        case "display.streaming": return vm.config.streaming ? "true" : "false"
        default: return ""
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
            // Absent key = HERMES's own default, not the model provider's
            // and not `medium` (P44b walked the consumers: the
            // chat-completions transport substitutes `medium` explicitly,
            // `agent/transports/chat_completions.py:420-422` @ `v2026.9.7`;
            // only the Anthropic adapter leaves it to the model).
            LabeledContent(
                "Reasoning effort",
                // P46b: emptiness is asked of the NORMALISED form, the way
                // Hermes asks it (`str(effort).strip()`) — a whitespace-only
                // value is the absent key here too, and read raw it rendered
                // as a blank value beside the label.
                value: HermesReasoningEffort.pickerSelection(for: vm.config.reasoningEffort).isEmpty
                    ? String(localized: "Hermes default") : vm.config.reasoningEffort
            )
            // Round-5 decision 17. The Mac renders this beside its picker
            // (`UnsupportedEffortNote`, `SettingsComponents.swift:395-415`);
            // iOS is READ-ONLY here, which makes the affordance MORE needed,
            // not less — with no control to move, a value the host ignores is
            // otherwise indistinguishable from one it honours, and there is
            // nothing on screen to hint otherwise.
            //
            // Same capability question, same ScarfCore function, so the two
            // platforms cannot drift: `unsupportedLevelNotice` is `nil` for a
            // level in this host's vocabulary, for the disable spellings it
            // accepts, and for the empty sentinel. No new string — the
            // sentence and its six locales already exist.
            if let notice = HermesReasoningEffort.unsupportedLevelNotice(
                for: vm.config.reasoningEffort,
                capabilities: caps
            ) {
                Text(verbatim: notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text(verbatim: notice))
            }
            if !vm.config.timezone.isEmpty {
                LabeledContent("Timezone", value: vm.config.timezone)
            }
        }
    }

    @ViewBuilder
    private var agentSection: some View {
        Section("Agent") {
            // Sentinel-aware: absent key shows the mode the host enforces
            // (smart on v0.19.0+, manual before, "unknown" undetected).
            LabeledContent(
                "Approval mode",
                value: vm.config.storedApprovalMode?.rawValue
                    ?? vm.config.approvalModeHostDefaultLabel(capabilities: caps)
            )
            // Sentinel-aware: absent key shows the host's effective default
            // ("Unlimited" on v0.20.5+, 500 on v0.20.0–v0.20.4, 60 before)
            // rather than 0.
            LabeledContent("Max turns", value: vm.config.displayMaxTurnsText(capabilities: caps))
            LabeledContent("Service tier", value: vm.config.serviceTier)
            LabeledContent("Tool use enforcement", value: vm.config.toolUseEnforcement)
        }
    }

    @ViewBuilder
    private var displaySection: some View {
        Section("Display") {
            yesNoRow("Streaming", vm.config.streaming)
            yesNoRow("Show reasoning", vm.config.displayShowReasoning(capabilities: caps))
            yesNoRow("Show cost", vm.config.showCost)
            LabeledContent("Skin", value: vm.config.display.skin)
            yesNoRow("Compact", vm.config.display.compact)
            yesNoRow("Inline diffs", vm.config.display.inlineDiffs)
            LabeledContent("Personality", value: vm.config.personality)
        }
        chatScarfSection
    }

    /// v2.7 — Scarf-local chat preferences. Mirrors the Mac Settings
    /// → Display → "Load tool results in past chats" toggle. Lives in
    /// its own section so it's clear these are app-side settings, not
    /// Hermes config values.
    @ViewBuilder
    private var chatScarfSection: some View {
        Section {
            Toggle(isOn: $loadHistoricalToolResults) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Load tool results in past chats")
                        .font(.body)
                    Text("Off (default) keeps past chat resumes fast on slow remotes — tool call cards still render, but the inspector lazy-loads each result when you open it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Chat (Scarf)")
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
            // Empty = `stt.provider` absent = Hermes decides (autodetect
            // ladder on v0.20.5+, the seeded `local` default before).
            LabeledContent(
                "STT provider",
                value: vm.config.voice.sttProvider.isEmpty ? "Auto (unset)" : vm.config.voice.sttProvider
            )
        }
        if SettingsView.showsVoiceConversationSection(capabilities: caps) {
            liveVoiceSection
        }
    }

    /// Whether ScarfGo can run a voice conversation against this host at
    /// all: Hermes v0.20.1+ (charter C1), the floor even the free chained
    /// path needs, because the reply is spoken by the HOST's text-to-speech.
    /// P7c lowered it from v0.21.3, which is now only the mode PICKER's
    /// floor. Below it the whole section is absent and Settings renders
    /// exactly as it did before P7c. A static so the gate is one testable
    /// expression rather than a condition buried in a `body` (mirrors the
    /// Mac's `VoiceTab.showsVoiceConversationSection(capabilities:)`).
    static func showsVoiceConversationSection(capabilities: HermesCapabilities) -> Bool {
        capabilities.hasHermesSpeechSynthesis
    }

    /// The host's `voice.voice_chat_mode`, and what that mode means on this
    /// iPhone. One section since P7c: BOTH modes now have an engine, so the
    /// picker is the only thing that differs and the rows below it explain
    /// whichever mode is selected. Written through the verified
    /// `hermes config set` argv (see `VoiceChatMode`, charter C5).
    private var selectedVoiceChatMode: VoiceChatMode {
        VoiceChatMode.parse(vm.config.voice.voiceChatMode)
    }

    @ViewBuilder
    private var liveVoiceSection: some View {
        Section {
            // `voice.voice_chat_mode` only EXISTS on v0.21.3+ (and
            // `IOSSettingsViewModel.saveVoiceChatMode` refuses below it), so
            // an older host shows the mode it is in, read-only, rather than
            // a picker whose other option can't be written (charter C1/C5).
            if caps.hasGPTLiveVoice {
                Picker(selection: Binding(
                    get: { selectedVoiceChatMode },
                    set: { newMode in saveVoiceChatMode(newMode) }
                )) {
                    Text("Chained (default)").tag(VoiceChatMode.chained)
                    Text("Live Voice (GPT-Live)").tag(VoiceChatMode.gptLive)
                } label: {
                    HStack(spacing: ScarfSpace.s2) {
                        Text("Mode")
                        if voiceModeSaving {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(voiceModeSaving)
            } else {
                LabeledContent("Mode") { Text("Chained") }
            }
            if let voiceModeError {
                Label {
                    Text(verbatim: voiceModeError)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(ScarfColor.warning)
            }
            if caps.hasGPTLiveVoice, selectedVoiceChatMode == .gptLive {
                gptLiveModeRows
            } else {
                chainedModeRows
            }
        } header: {
            Text("Voice conversation")
        } footer: {
            Group {
                if caps.hasGPTLiveVoice, selectedVoiceChatMode == .gptLive {
                    Text("Live Voice is a spoken, back-and-forth conversation with Hermes from the Chat tab. Your voice streams directly from this device to OpenAI; the Hermes host only sets up the session, so OpenAI also sees this device's network address, and each session shares recent chat messages for context. It needs an OpenAI API key on the Hermes host (OPENAI_API_KEY, or voice.gpt_live.api_key) and bills that key about $0.05 per minute while a session is open. This mode is a Hermes setting for the whole profile: it also switches voice in Hermes's own apps.")
                } else {
                    Text("Chained is a spoken conversation from the Chat tab that costs nothing extra. Your voice is turned into words on this iPhone and never leaves it \u{2014} only the words you said go to Hermes, exactly like a typed message. Replies are read aloud by the host's text-to-speech provider, which sees the reply text (Hermes's default, edge, sends it to Microsoft). This mode is a Hermes setting for the whole profile: it also switches voice in Hermes's own apps.")
                }
            }
            .font(.caption)
        }
    }

    /// GPT-Live rows: what the vendor path needs. Shown only in that mode.
    @ViewBuilder
    private var gptLiveModeRows: some View {
        LabeledContent("Speech to text", value: "OpenAI")
        LabeledContent("Text to speech", value: "OpenAI")
        LabeledContent("Cost") {
            Text("About $0.05 per minute")
        }
    }

    /// Chained rows: the two halves of the client loop, and what each costs.
    @ViewBuilder
    private var chainedModeRows: some View {
        LabeledContent("Speech to text") {
            Text("On this iPhone")
        }
        LabeledContent("Text to speech") {
            HStack(spacing: ScarfSpace.s2) {
                Text(verbatim: ttsProviderName)
                ttsCostBadge
            }
        }
    }

    /// The host's `tts.provider`, or Hermes's own default when unset.
    private var ttsProviderName: String {
        SettingsView.ttsProviderLabel(of: vm.config.voice.ttsProvider)
    }

    /// Free or paid, by provider. A conservative split: anything not known
    /// to be free is labelled nothing at all rather than guessed at.
    private var ttsCostBadge: some View {
        Group {
            switch SettingsView.ttsCost(of: ttsProviderName) {
            case .free:
                Text("Free").foregroundStyle(ScarfColor.success)
            case .paid:
                Text("Paid").foregroundStyle(ScarfColor.warning)
            case .unknown:
                EmptyView()
            }
        }
        .font(.caption.weight(.semibold))
    }

    enum TTSCost: Equatable { case free, paid, unknown }

    /// What the row NAMES as the provider: an absent `tts.provider` is
    /// Hermes's own default, `edge`. The single place the default is
    /// resolved — the label and ``ttsCost(of:)`` both go through it, so the
    /// row can never read "edge" while the badge next to it reads nothing
    /// (the Mac's `VoiceTab.ttsCost(for:)` already treated "" as edge).
    static func ttsProviderLabel(of provider: String) -> String {
        let raw = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "edge" : raw
    }

    /// Which of Hermes's `tts.provider` values bill the user. Free ones run
    /// on the host (piper, kittentts, neutts) or on a free public endpoint
    /// (edge); the rest are vendor APIs on the host's own key. A provider
    /// Scarf doesn't know — a plugin's — claims nothing rather than
    /// guessing wrong about someone's bill.
    static func ttsCost(of provider: String) -> TTSCost {
        switch ttsProviderLabel(of: provider).lowercased() {
        case "edge", "piper", "kittentts", "neutts": return .free
        case "openai", "elevenlabs", "xai", "deepinfra", "gemini", "mistral", "minimax": return .paid
        default: return .unknown
        }
    }

    /// Review or reset this device's consent to send Live Voice data to
    /// OpenAI. Hermes v0.21.3+ only, like the mode picker (charter C1).
    @ViewBuilder
    private var liveVoicePrivacySection: some View {
        if caps.hasGPTLiveVoice, let recipient = VoiceChatMode.gptLive.externalRecipient {
            Section {
                LabeledContent("Consent") {
                    if let date = voiceConsent.consentDate(for: recipient) {
                        Text("Accepted \(date.formatted(date: .abbreviated, time: .omitted))")
                    } else {
                        Text("Not accepted")
                    }
                }
                Button("Review what Live Voice shares") {
                    reviewingVoiceConsent = recipient
                }
                Button("Reset consent", role: .destructive) {
                    voiceConsent.resetConsent(for: recipient)
                }
                .disabled(!voiceConsent.hasConsented(to: recipient))
            } header: {
                Text("Live Voice Privacy")
            } footer: {
                Text("ScarfGo asks before the first Live Voice (GPT-Live) session on this device. After a reset it asks again. Chained mode sends no voice to anyone, so it never asks.")
                    .font(.caption)
            }
            .sheet(item: $reviewingVoiceConsent) { recipient in
                VoiceLiveConsentSheet(recipient: recipient, mode: .review)
            }
        }
    }

    private func saveVoiceChatMode(_ mode: VoiceChatMode) {
        guard mode != selectedVoiceChatMode else { return }
        voiceModeSaving = true
        voiceModeError = nil
        let capabilities = caps
        Task {
            defer { voiceModeSaving = false }
            do {
                try await vm.saveVoiceChatMode(mode, capabilities: capabilities)
            } catch {
                voiceModeError = error.localizedDescription
            }
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
                        .foregroundStyle(ScarfColor.foregroundMuted)
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

            // v0.13 additions: each is independently capability-gated
            // and read-only on iOS in v2.8.0. Editing lives on Mac.
            if caps.hasGoogleChatPlatform {
                LabeledContent("Google Chat", value: googleChatStatusLabel)
            }
            if caps.hasGatewayBusyAckToggle {
                gatewayBusyAckRow
            }
            if caps.hasGatewayRestartNotification {
                gatewayRestartNotificationRow
            }
            if caps.hasGatewayAllowlists {
                gatewayAllowlistsRows
            }
        }
    }

    /// Google Chat status. Checks for a top-level `google_chat:` block in
    /// the raw YAML — the same config-block presence probe the Mac app's
    /// `PlatformsViewModel.hasConfigBlock` uses. It can't key off
    /// `gatewayPlatforms` anymore: google_chat has no allowlist keys (Wave
    /// B4 removed it from `gatewayAllowlistPlatforms`), so the parser never
    /// creates an entry for it. The real Hermes identifier is `google_chat`
    /// (plugins/platforms/google_chat/adapter.py); the legacy hyphenated
    /// spellings are checked so configs written by older Scarf builds
    /// still read as configured.
    private var googleChatStatusLabel: String {
        let topLevelBlocks = Set(
            vm.rawYAML.components(separatedBy: "\n")
                .filter { !$0.hasPrefix(" ") && !$0.hasPrefix("\t") }
                .compactMap { line -> String? in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasSuffix(":") else { return nil }
                    return String(trimmed.dropLast())
                }
        )
        for name in ["google_chat", "google-chat", "googlechat"] where topLevelBlocks.contains(name) {
            return "configured"
        }
        return "not configured"
    }

    /// Busy-ack toggle is GLOBAL (`display.busy_ack_enabled`) — Hermes
    /// never had a working per-platform variant, so surface the single
    /// global value rather than a per-platform summary.
    @ViewBuilder
    private var gatewayBusyAckRow: some View {
        LabeledContent("Gateway: busy ack",
                       value: vm.config.displayBusyAckEnabled ? "on" : "off")
    }

    @ViewBuilder
    private var gatewayRestartNotificationRow: some View {
        let value = summariseGatewayBool(\GatewayPlatformSettings.gatewayRestartNotification, defaultLabel: "off")
        LabeledContent("Gateway: restart notification", value: value)
    }

    /// Render a per-key summary across `gatewayPlatforms`. When all
    /// configured platforms agree on the same value we show a single
    /// "yes" / "no". When they disagree we show "mixed (N platforms)"
    /// to nudge the user to the Mac app for the per-platform detail.
    private func summariseGatewayBool(
        _ keyPath: KeyPath<GatewayPlatformSettings, Bool>,
        defaultLabel: String
    ) -> String {
        let values = vm.config.gatewayPlatforms.values.map { $0[keyPath: keyPath] }
        guard !values.isEmpty else { return defaultLabel + " (default)" }
        let allTrue = values.allSatisfy { $0 }
        let allFalse = values.allSatisfy { !$0 }
        if allTrue { return "yes" }
        if allFalse { return "no" }
        return "mixed (\(values.count) platforms)"
    }

    /// v0.13 cross-platform allowlist summaries. Each kind
    /// (channels / chats / rooms) renders as a DisclosureGroup with the
    /// total count in the label and a flat list of "platform: id" rows
    /// when expanded. iPhone-friendly: collapsed by default so the
    /// section stays compact.
    @ViewBuilder
    private var gatewayAllowlistsRows: some View {
        gatewayAllowlistDisclosure(kind: .channels)
        gatewayAllowlistDisclosure(kind: .chats)
        gatewayAllowlistDisclosure(kind: .rooms)
    }

    @ViewBuilder
    private func gatewayAllowlistDisclosure(kind: GatewayAllowlistKind) -> some View {
        let entries = gatewayAllowlistEntries(kind: kind)
        if !entries.isEmpty {
            DisclosureGroup {
                ForEach(entries, id: \.self) { entry in
                    Text(verbatim: entry)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } label: {
                LabeledContent(allowedHeading(kind)) {
                    Text(verbatim: entries.count.formatted())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// `GatewayAllowlistKind.pluralNoun` is an English YAML-side token, so
    /// interpolating it produced the unusable key `"Allowed %@"`. One whole
    /// extractable sentence per case instead — the Mac side does the same in
    /// `AllowlistEditor.swift`.
    private func allowedHeading(_ kind: GatewayAllowlistKind) -> LocalizedStringKey {
        switch kind {
        case .channels: return "Allowed channels"
        case .chats:    return "Allowed chats"
        case .rooms:    return "Allowed rooms"
        }
    }

    /// Flatten the per-platform allowlists for `kind` across every
    /// configured platform. Each entry is rendered as
    /// `"platformName: id"` so the user sees which platform the id
    /// belongs to without an extra DisclosureGroup level.
    private func gatewayAllowlistEntries(kind: GatewayAllowlistKind) -> [String] {
        var out: [String] = []
        for (platform, settings) in vm.config.gatewayPlatforms.sorted(by: { $0.key < $1.key }) {
            guard GatewayAllowlistKind.kind(for: platform) == kind else { continue }
            for item in settings.items(for: kind) where !item.isEmpty {
                out.append("\(platform): \(item)")
            }
        }
        return out
    }

    /// Diagnostics → Performance entry point. Hidden from the
    /// `quickEditsSection` flow because it doesn't touch config.yaml
    /// — it controls the in-process ScarfMon backend set instead. Off
    /// by default users still get Instruments-visible signposts; flip
    /// to Full when investigating a specific perf complaint.
    @ViewBuilder
    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                ScarfMonDiagnosticsView()
            } label: {
                Label("Performance", systemImage: "speedometer")
            }
            // Show the share affordance only when MetricKit has actually
            // persisted a payload to Documents/ScarfDiagnostics/. Apple
            // delivers payloads roughly once per 24h after a crash/hang,
            // so on a healthy device the row stays hidden — no
            // misleading "share crash" affordance when nothing has
            // crashed.
            if let url = MetricKitSubscriber.mostRecentDiagnosticFile() {
                ShareLink(item: url) {
                    Label("Share Latest Diagnostic", systemImage: "doc.badge.arrow.up")
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Performance instrumentation. Default mode emits Instruments signposts only; Full mode also keeps a 4096-entry in-memory ring you can copy as JSON. Crash + hang diagnostics from MetricKit are persisted locally and appear here for sharing when Apple delivers them (~once per day after a crash).")
                .font(.caption)
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
                        .foregroundStyle(ScarfColor.foregroundMuted)
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
