import SwiftUI
import ScarfCore
import ScarfDesign

/// Voice tab — push-to-talk + TTS + STT provider settings.
struct VoiceTab: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    private var capabilities: HermesCapabilities { capabilitiesStore?.capabilities ?? .empty }

    /// Client-side preference (NOT a Hermes config key): which engine the
    /// per-message speaker button uses. Shared with `MessageSpeechService`
    /// via the same defaults key.
    @AppStorage(MessageSpeechService.engineKey) private var playbackEngine = "system"

    /// This Mac's Live Voice consents (F4). Device-local, not a Hermes key.
    private let consent = VoiceDataConsentStore.shared
    @State private var reviewingConsent: VoiceDataRecipient?

    private var playbackEngineOptions: [(id: String, label: String)] {
        [
            ("system", String(localized: "System Voice")),
            ("hermes", String(localized: "Hermes Voice")),
        ]
    }

    /// STT providers, with the "Auto (unset)" row dropped on hosts without
    /// `hermes config unset` (pre-v0.19) — same shape as BrowserTab's
    /// cloud-provider picker: an unwritable option is hidden rather than
    /// offered-and-failing, but stays visible when it is the current state so
    /// an absent key still renders a selected label instead of a blank picker.
    private var sttProviderOptions: [(id: String, label: String)] {
        let all = SettingsViewModel.sttProviders(
            capabilities: capabilitiesStore?.capabilities ?? .empty,
            current: viewModel.config.voice.sttProvider
        )
        guard capabilitiesStore?.capabilities.hasConfigUnset == true else {
            return viewModel.config.voice.sttProvider.isEmpty
                ? all
                : all.filter { !$0.id.isEmpty }
        }
        return all
    }

    var body: some View {
        SettingsSection(title: "Push-to-Talk", icon: "mic") {
            ToggleRow(label: "Auto TTS", isOn: viewModel.config.autoTTS) { viewModel.setAutoTTS($0) }
                .help("Speak every reply aloud. Off by default on every supported host.")
            EditableTextField(label: "Record Key", value: viewModel.config.voice.recordKey) { viewModel.setRecordKey($0) }
            StepperRow(label: "Max Recording (s)", value: viewModel.config.voice.maxRecordingSeconds, range: 10...600, step: 10) { viewModel.setMaxRecordingSeconds($0) }
            StepperRow(label: "Silence Threshold", value: viewModel.config.silenceThreshold, range: 50...500, step: 10) { viewModel.setSilenceThreshold($0) }
            DoubleStepperRow(label: "Silence Duration (s)", value: viewModel.config.voice.silenceDuration, range: 0.5...10.0, step: 0.5) { viewModel.setSilenceDuration($0) }
        }

        SettingsSection(title: "Text-to-Speech", icon: "speaker.wave.3") {
            // C1: hidden below v0.20.1 (`hasHermesSpeechSynthesis`) so an
            // older host renders this section exactly as before; the
            // speaker button there always uses the system voice.
            if capabilities.hasHermesSpeechSynthesis {
                PickerRow(
                    label: "Playback Engine",
                    selection: playbackEngine,
                    options: playbackEngineOptions.map(\.id),
                    optionLabel: { id in
                        playbackEngineOptions.first { $0.id == id }?.label ?? id
                    }
                ) { playbackEngine = $0 }
                    .help("System Voice synthesizes on this Mac with the macOS Spoken Content voice. Hermes Voice synthesizes through the connected server's configured TTS provider and falls back to the system voice when the server can't synthesize.")
            }
            PickerRow(
                label: "Provider",
                selection: viewModel.config.voice.ttsProvider,
                options: SettingsViewModel.ttsProviders(
                    capabilities: capabilitiesStore?.capabilities ?? .empty,
                    current: viewModel.config.voice.ttsProvider
                )
            ) { viewModel.setTTSProvider($0) }
            switch viewModel.config.voice.ttsProvider {
            case "edge":
                EditableTextField(label: "Voice", value: viewModel.config.voice.ttsEdgeVoice) { viewModel.setTTSEdgeVoice($0) }
            case "elevenlabs":
                EditableTextField(label: "Voice ID", value: viewModel.config.voice.ttsElevenLabsVoiceID) { viewModel.setTTSElevenLabsVoiceID($0) }
                EditableTextField(label: "Model ID", value: viewModel.config.voice.ttsElevenLabsModelID) { viewModel.setTTSElevenLabsModelID($0) }
            case "openai":
                EditableTextField(label: "Model", value: viewModel.config.voice.ttsOpenAIModel) { viewModel.setTTSOpenAIModel($0) }
                PickerRow(label: "Voice", selection: viewModel.config.voice.ttsOpenAIVoice, options: ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]) { viewModel.setTTSOpenAIVoice($0) }
            case "neutts":
                EditableTextField(label: "Model", value: viewModel.config.voice.ttsNeuTTSModel) { viewModel.setTTSNeuTTSModel($0) }
                PickerRow(label: "Device", selection: viewModel.config.voice.ttsNeuTTSDevice, options: ["cpu", "cuda"]) { viewModel.setTTSNeuTTSDevice($0) }
            case "xai":
                // v0.13: xAI TTS surface. Voice ID + Model are always
                // visible (xAI TTS shipped earlier); the cloning-supported
                // badge is gated on `hasXAIVoiceCloning` so pre-v0.13 hosts
                // see the input rows but no cloning advertisement.
                EditableTextField(label: "Voice ID", value: viewModel.config.voice.ttsXAIVoiceID) { viewModel.setTTSXAIVoiceID($0) }
                // No "Model" row: xAI TTS has no `tts.xai.model` key. Its
                // v0.21 defaults are voice_id/language/speed/auto_speech_tags/
                // optimize_streaming_latency/sample_rate/bit_rate only
                // (config_defaults.py), and `_generate_xai_tts`
                // (`tools/tts_tool_providers.py:287-340` @ `v2026.9.7`,
                // imported into `tools/tts_tool.py:55`) reads none named
                // "model". The single reader anywhere is
                // `hermes_cli/xai_retirement.py:91` via `_check_section`
                // (`:82-85`), a staleness WARNING pass — so writing the key
                // could only ever produce a spurious retirement notice.
                // Removed with
                // its parse (go/no-go blocking condition 8, A5).
                // v0.15: auto-insert speech-control tags — hidden on pre-v0.15 hosts.
                if capabilitiesStore?.capabilities.hasXAITTSAutoSpeechTags == true {
                    ToggleRow(label: "Auto speech tags", isOn: viewModel.config.voice.ttsXAIAutoSpeechTags) { viewModel.setTTSXAIAutoSpeechTags($0) }
                }
                // v0.19: the rest of xAI TTS's tunable params — hidden on
                // pre-v0.19 hosts (hasXAITTSAdvancedParams). No
                // `text_normalization` row: Hermes added then dropped that
                // key before any tagged release shipped it.
                if capabilitiesStore?.capabilities.hasXAITTSAdvancedParams == true {
                    EditableTextField(label: "Language", value: viewModel.config.voice.ttsXAILanguage) { viewModel.setTTSXAILanguage($0) }
                    DoubleStepperRow(label: "Speed", value: viewModel.config.voice.ttsXAISpeed, range: 0.7...1.5, step: 0.1) { viewModel.setTTSXAISpeed($0) }
                    StepperRow(label: "Streaming Latency Opt.", value: viewModel.config.voice.ttsXAIOptimizeStreamingLatency, range: 0...2, step: 1) { viewModel.setTTSXAIOptimizeStreamingLatency($0) }
                    PickerRow(label: "Sample Rate", selection: String(viewModel.config.voice.ttsXAISampleRate), options: ["22050", "24000", "44100", "48000"]) { viewModel.setTTSXAISampleRate(Int($0) ?? 24000) }
                    StepperRow(label: "Bit Rate", value: viewModel.config.voice.ttsXAIBitRate, range: 32000...320000, step: 8000) { viewModel.setTTSXAIBitRate($0) }
                }
                if capabilitiesStore?.capabilities.hasXAIVoiceCloning == true {
                    xaiCloningBadge
                }
            case "deepinfra":
                // v0.19: DeepInfra TTS — hidden on pre-v0.19 hosts (hasDeepInfraTTS).
                if capabilitiesStore?.capabilities.hasDeepInfraTTS == true {
                    EditableTextField(label: "Model", value: viewModel.config.voice.ttsDeepInfraModel) { viewModel.setTTSDeepInfraModel($0) }
                    EditableTextField(label: "Voice", value: viewModel.config.voice.ttsDeepInfraVoice) { viewModel.setTTSDeepInfraVoice($0) }
                }
            default:
                EmptyView()
            }
        }

        SettingsSection(title: "Speech-to-Text", icon: "waveform") {
            ToggleRow(label: "Enabled", isOn: viewModel.config.voice.sttEnabled) { viewModel.setSTTEnabled($0) }
            PickerRow(
                label: "Provider",
                selection: viewModel.config.voice.sttProvider,
                options: sttProviderOptions.map(\.id),
                optionLabel: { id in
                    sttProviderOptions.first { $0.id == id }?.label ?? id
                }
            ) { viewModel.setSTTProvider($0, capabilities: capabilities) }
            // v0.19.1: global language hint applied to every provider unless a
            // per-provider language overrides it — hidden below v0.19.1
            // (hasSTTUnifiedLanguage). Default "en"; empty restores auto-detect.
            if capabilitiesStore?.capabilities.hasSTTUnifiedLanguage == true {
                EditableTextField(label: "Language (global)", value: viewModel.config.voice.sttLanguage) { viewModel.setSTTLanguage($0) }
            }
            switch viewModel.config.voice.sttProvider {
            // "" (key unset / "Auto") shows the local rows too: these are the
            // `stt.local.*` keys, which apply whenever the autodetect ladder
            // lands on local — the ladder's always-available last rung — and
            // on pre-v0.20.5 hosts unset *is* local. Hiding them would force
            // a user who only wants to tune the whisper model to pin the
            // provider and lose autodetection.
            case "local", "":
                PickerRow(label: "Model", selection: viewModel.config.voice.sttLocalModel, options: ["tiny", "base", "small", "medium", "large-v3"]) { viewModel.setSTTLocalModel($0) }
                EditableTextField(label: "Language", value: viewModel.config.voice.sttLocalLanguage) { viewModel.setSTTLocalLanguage($0) }
                // v0.19.1: faster-whisper anti-hallucination VAD tuning —
                // hidden below v0.19.1 (hasSTTLocalVADTuning).
                if capabilitiesStore?.capabilities.hasSTTLocalVADTuning == true {
                    ToggleRow(label: "VAD Filter", isOn: viewModel.config.voice.sttLocalVAD) { viewModel.setSTTLocalVAD($0) }
                    StepperRow(label: "Min Silence (ms)", value: viewModel.config.voice.sttLocalVADMinSilenceMS, range: 0...5000, step: 50) { viewModel.setSTTLocalVADMinSilenceMS($0) }
                    DoubleStepperRow(label: "No-Speech Threshold", value: viewModel.config.voice.sttLocalNoSpeechProbThreshold, range: 0.0...1.0, step: 0.05) { viewModel.setSTTLocalNoSpeechProbThreshold($0) }
                    DoubleStepperRow(label: "Logprob Threshold", value: viewModel.config.voice.sttLocalLogprobThreshold, range: -5.0...0.0, step: 0.1) { viewModel.setSTTLocalLogprobThreshold($0) }
                }
                // v0.20.4+ — releases the local whisper model after N idle
                // seconds (frees VRAM on GPU; 0 = never unload).
                if capabilitiesStore?.capabilities.isV0204OrLater ?? false {
                    StepperRow(label: "Unload After Idle (s)", value: viewModel.config.voice.sttLocalUnloadAfterIdleSeconds, range: 0...3600, step: 30) { viewModel.setSTTLocalUnloadAfterIdleSeconds($0) }
                        .help("0 = never unload the local whisper model. A positive value releases it (freeing VRAM on GPU) after this many idle seconds; the next voice message reloads it.")
                }
            case "groq":
                // v0.19.1: config-driven Groq STT knobs — hidden below v0.19.1
                // (hasSTTUnifiedLanguage; the provider itself is
                // older, but the model/language keys were env-only before).
                if capabilitiesStore?.capabilities.hasSTTUnifiedLanguage == true {
                    PickerRow(label: "Model", selection: viewModel.config.voice.sttGroqModel, options: ["whisper-large-v3", "whisper-large-v3-turbo", "distil-whisper-large-v3-en"]) { viewModel.setSTTGroqModel($0) }
                    EditableTextField(label: "Language", value: viewModel.config.voice.sttGroqLanguage) { viewModel.setSTTGroqLanguage($0) }
                }
            case "openai":
                EditableTextField(label: "Model", value: viewModel.config.voice.sttOpenAIModel) { viewModel.setSTTOpenAIModel($0) }
                EditableTextField(label: "Language", value: viewModel.config.voice.sttOpenAILanguage) { viewModel.setSTTOpenAILanguage($0) }
            case "mistral":
                EditableTextField(label: "Model", value: viewModel.config.voice.sttMistralModel) { viewModel.setSTTMistralModel($0) }
            default:
                EmptyView()
            }
            // v0.20.4+ — client-side ffmpeg silence trim applied before
            // upload to cloud STT providers (groq/openai/mistral/xai/
            // elevenlabs/deepinfra). TOP-LEVEL keys, not per-provider.
            if capabilitiesStore?.capabilities.isV0204OrLater ?? false {
                ToggleRow(label: "Trim Silence (Cloud STT)", isOn: viewModel.config.voice.sttCloudTrimSilence) { viewModel.setSTTCloudTrimSilence($0) }
                    .help("Collapses pauses with ffmpeg client-side before upload to cloud STT providers. Reduces upload time, per-minute billing, and hallucination risk. Clips under 12s skip the trim; on any failure the original uploads untouched.")
                if viewModel.config.voice.sttCloudTrimSilence {
                    DoubleStepperRow(label: "Trim Threshold (dB)", value: viewModel.config.voice.sttCloudTrimThresholdDB, range: -80.0...(-10.0), step: 1.0) { viewModel.setSTTCloudTrimThresholdDB($0) }
                        .help("Audio quieter than this counts as silence.")
                    StepperRow(label: "Trim Keep (ms)", value: viewModel.config.voice.sttCloudTrimKeepMS, range: 0...2000, step: 50) { viewModel.setSTTCloudTrimKeepMS($0) }
                        .help("How much of each pause survives the trim (keeps natural pacing).")
                }
            }
        }

        // P7b — one "Voice conversation" section for both engines. Gated
        // on `hasHermesSpeechSynthesis` (v0.20.1): below it neither engine
        // can run, so the tab renders exactly as it did before (C1).
        if Self.showsVoiceConversationSection(capabilities: capabilities) {
            SettingsSection(title: "Voice conversation", icon: "waveform.circle") {
                // The mode is a Hermes key, and `hermes config set` only
                // knows it from v0.21.3 — so on an older host the row would
                // write nothing. Chained is what runs there anyway.
                if capabilities.hasGPTLiveVoice {
                    PickerRow(
                        label: "Mode",
                        selection: VoiceChatMode.parse(viewModel.config.voice.voiceChatMode).rawValue,
                        options: VoiceChatMode.allCases.map(\.rawValue),
                        optionLabel: { Self.voiceChatModeLabel($0) }
                    ) { raw in
                        guard let mode = VoiceChatMode(rawValue: raw) else { return }
                        viewModel.setVoiceChatMode(mode, capabilities: capabilities)
                    }
                    .help("Hermes's voice.voice_chat_mode, for the whole Hermes profile — it also switches voice in Hermes's own apps. Either mode turns on the voice button in the chat composer.")
                }
                voiceConversationNote
                if resolvedVoiceMode == .gptLive {
                    liveVoiceNote
                    if let recipient = VoiceChatMode.gptLive.externalRecipient {
                        consentRow(recipient)
                    }
                } else {
                    chainedRows
                }
            }
            .sheet(item: $reviewingConsent) { recipient in
                VoiceLiveConsentSheet(recipient: recipient, mode: .review)
            }
        }

        // v0.20.4+ — "Hey Hermes" hands-free wake word capture placement.
        if capabilitiesStore?.capabilities.isV0204OrLater ?? false {
            SettingsSection(title: "Wake Word", icon: "waveform.badge.mic") {
                PickerRow(label: "Capture", selection: viewModel.config.voice.wakeWordCapture, options: ["auto", "local", "client"]) { viewModel.setWakeWordCapture($0) }
                    .help("auto: backend PortAudio mic when one exists, else a remote desktop on a mic-less (headless/VPS) backend streams its own mic via the wake.feed RPC. local: always the backend mic. client: always desktop-streamed PCM (detection stays on the backend).")
            }
        }
    }

    // MARK: - P7b: the voice-conversation section

    /// Whether Scarf can run a voice conversation against this host at all
    /// (v0.20.1, `hasHermesSpeechSynthesis`) — the floor even the free
    /// chained path needs. Below it the whole section is absent (C1).
    static func showsVoiceConversationSection(capabilities: HermesCapabilities) -> Bool {
        capabilities.hasHermesSpeechSynthesis
    }

    /// What the mode picker's value means for THIS host: a host that asks
    /// for gpt-live but is too old for it runs chained, exactly as Hermes
    /// itself falls back, so the rows must describe chained.
    private var resolvedVoiceMode: VoiceChatMode {
        guard capabilities.hasGPTLiveVoice,
              VoiceChatMode.parse(viewModel.config.voice.voiceChatMode) == .gptLive else { return .chained }
        return .gptLive
    }

    /// Whether a `tts.provider` bills the user. Free providers synthesize
    /// locally on the host or through a free endpoint (Hermes's default
    /// `edge` is Microsoft's, at no charge); paid ones spend an API key.
    /// A provider Scarf doesn't know — a plugin's
    /// (`PluginContext.register_tts_provider`) — claims nothing rather
    /// than guessing wrong about someone's bill.
    enum TTSCost { case free, paid, unknown }

    static func ttsCost(for provider: String) -> TTSCost {
        // Resolve the NAME first (an absent key is Hermes's default,
        // `edge`) and classify that - the same two steps the iOS twin
        // takes, so the two apps can't drift apart on what "" costs.
        let name = resolvedTTSProviderName(provider)
        if ["edge", "piper", "kittentts", "neutts"].contains(name) { return .free }
        if ["openai", "elevenlabs", "xai", "deepinfra", "gemini", "mistral", "minimax"].contains(name) { return .paid }
        return .unknown
    }

    static func chainedSpeechToTextLabel() -> String {
        String(localized: "On this Mac (Apple). The audio never leaves it.")
    }

    /// What speaks the chained reply, for the "Text to Speech" row.
    ///
    /// `playbackPreference` is the Playback Engine picker below it - the
    /// same preference `VoiceLiveController.chained` reads when it builds
    /// the speaker. With System Voice chosen the host's `tts.provider` is
    /// never asked to speak anything, so the row must not name it.
    static func chainedTextToSpeechLabel(provider: String, playbackPreference: String?) -> String {
        guard VoiceLiveController.chainedPlaybackEngine(preference: playbackPreference) == .hermes else {
            return String(localized: "This Mac's voice")
        }
        let name = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return String(localized: "edge (the Hermes default)") }
        return name
    }

    /// The badge next to that label. This Mac's own voice bills nobody,
    /// whatever the host's `tts.provider` happens to be.
    static func chainedTTSCost(provider: String, playbackPreference: String?) -> TTSCost {
        guard VoiceLiveController.chainedPlaybackEngine(preference: playbackPreference) == .hermes else {
            return .free
        }
        return ttsCost(for: provider)
    }

    /// The provider name a row prints and `ttsCost` classifies, with
    /// Hermes's own default filled in for an unset key and the case
    /// normalized.
    static func resolvedTTSProviderName(_ provider: String) -> String {
        let name = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name.isEmpty ? "edge" : name
    }

    static func chainedPrivacyNote() -> String {
        String(localized: "Your voice is transcribed on this Mac and never sent anywhere. Only the words you said reach Hermes, as an ordinary chat turn, and only the reply text reaches the host's text-to-speech provider.")
    }

    /// The chained path, in two rows: where each half of the loop runs.
    @ViewBuilder
    private var chainedRows: some View {
        LabeledSettingsRow(label: "Speech to Text") {
            Text(verbatim: Self.chainedSpeechToTextLabel())
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Spacer()
        }
        LabeledSettingsRow(label: "Text to Speech") {
            Text(verbatim: Self.chainedTextToSpeechLabel(
                provider: viewModel.config.voice.ttsProvider,
                playbackPreference: playbackEngine
            ))
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
            switch Self.chainedTTSCost(
                provider: viewModel.config.voice.ttsProvider,
                playbackPreference: playbackEngine
            ) {
            case .free: ScarfBadge("Free", kind: .success)
            case .paid: ScarfBadge("Paid", kind: .warning)
            case .unknown: EmptyView()
            }
            Spacer()
        }
        // The same client-side preference the per-message speaker button
        // uses, and the same control: it decides whether the chained reply
        // is spoken by the host's provider or by this Mac's own voice.
        PickerRow(
            label: "Playback Engine",
            selection: playbackEngine,
            options: playbackEngineOptions.map(\.id),
            optionLabel: { id in playbackEngineOptions.first { $0.id == id }?.label ?? id }
        ) { playbackEngine = $0 }
            .help("System Voice speaks the reply on this Mac and needs no host setup. Hermes Voice speaks it through the host's configured TTS provider, falling back to this Mac's voice for anything the host can't synthesize.")
        Text(verbatim: Self.chainedPrivacyNote())
            .scarfStyle(.caption)
            .foregroundStyle(ScarfColor.foregroundMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
    }

    /// What the two modes are, above whichever one's rows are showing.
    private var voiceConversationNote: some View {
        Text("Talk with Hermes from the chat composer. Chained, Hermes's default, is free: your voice is transcribed on this Mac, runs as a normal turn, and the reply is read aloud. GPT-Live hands the whole conversation to an OpenAI voice model.")
            .scarfStyle(.caption)
            .foregroundStyle(ScarfColor.foregroundMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
    }

    /// Picker labels for `voice.voice_chat_mode`. The stored value is
    /// Hermes's own (`chained` / `gpt-live`).
    static func voiceChatModeLabel(_ raw: String) -> String {
        switch VoiceChatMode(rawValue: raw) {
        case .gptLive: return String(localized: "GPT-Live")
        case .chained, nil: return String(localized: "Chained (default)")
        }
    }

    /// This Mac's consent to send Live Voice data to `recipient`: review
    /// the wording, or reset it so the next session asks again.
    private func consentRow(_ recipient: VoiceDataRecipient) -> some View {
        LabeledSettingsRow(label: "Privacy Consent") {
            Group {
                if let date = consent.consentDate(for: recipient) {
                    Text("Accepted on this Mac, \(date.formatted(date: .abbreviated, time: .omitted))")
                } else {
                    Text("Not accepted on this Mac. Scarf asks before the first session.")
                }
            }
            .scarfStyle(.caption)
            .foregroundStyle(ScarfColor.foregroundMuted)
            Spacer()
            Button("Review…") { reviewingConsent = recipient }
                .buttonStyle(ScarfGhostButton())
            Button("Reset") { consent.resetConsent(for: recipient) }
                .buttonStyle(ScarfGhostButton())
                .disabled(!consent.hasConsented(to: recipient))
                .help("Forget this Mac's consent. Scarf asks again before the next Live Voice session.")
        }
    }

    /// What GPT-Live needs, sends and costs, under the mode picker.
    private var liveVoiceNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Chained, Hermes's default, turns speech into text, runs a normal turn, and reads the reply aloud. GPT-Live lets you talk with Hermes from the chat composer: an OpenAI voice model listens and speaks, and hands each request to Hermes as a normal chat turn.")
            Text("With GPT-Live, your voice streams directly from this Mac to OpenAI; the Hermes host only sets up the session, so OpenAI also sees this Mac's network address. Each session also shares recent messages from the chat with OpenAI for context.")
            Text("It needs an OpenAI API key on the Hermes host (OPENAI_API_KEY in its .env, or voice.gpt_live.api_key) and bills that key about $0.05 per minute of session time. Sessions end on their own after \(Int((VoiceIdleMonitor.defaultTimeout / 60).rounded())) minutes without speech.")
            Text("This mode is a Hermes setting for the whole profile, not just Scarf: it also switches voice in Hermes's own apps.")
        }
        .scarfStyle(.caption)
        .foregroundStyle(ScarfColor.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    /// Inline hint chip+caption shown below xAI's Voice ID + Model fields
    /// on v0.13+. References `hermes voice` because Scarf doesn't manage
    /// cloned voices in-app yet — the badge is discovery-only. Out-of-scope
    /// for v2.8: an in-app cloned-voice manager (would be its own feature).
    @ViewBuilder
    private var xaiCloningBadge: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("")
                .font(.caption)
                .frame(width: 160, alignment: .trailing)
            ScarfBadge("Cloning supported", kind: .info)
            Text("Manage cloned voices in your terminal: `hermes voice` (xAI subcommands).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
