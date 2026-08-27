import SwiftUI
import ScarfCore
import ScarfDesign

/// Voice tab — push-to-talk + TTS + STT provider settings.
struct VoiceTab: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    /// STT providers, with the "Auto (unset)" row dropped on hosts without
    /// `hermes config unset` (pre-v0.19) — same shape as BrowserTab's
    /// cloud-provider picker: an unwritable option is hidden rather than
    /// offered-and-failing, but stays visible when it is the current state so
    /// an absent key still renders a selected label instead of a blank picker.
    private var sttProviderOptions: [(id: String, label: String)] {
        let all = viewModel.sttProviders
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
            EditableTextField(label: "Record Key", value: viewModel.config.voice.recordKey) { viewModel.setRecordKey($0) }
            StepperRow(label: "Max Recording (s)", value: viewModel.config.voice.maxRecordingSeconds, range: 10...600, step: 10) { viewModel.setMaxRecordingSeconds($0) }
            StepperRow(label: "Silence Threshold", value: viewModel.config.silenceThreshold, range: 50...500, step: 10) { viewModel.setSilenceThreshold($0) }
            DoubleStepperRow(label: "Silence Duration (s)", value: viewModel.config.voice.silenceDuration, range: 0.5...10.0, step: 0.5) { viewModel.setSilenceDuration($0) }
        }

        SettingsSection(title: "Text-to-Speech", icon: "speaker.wave.3") {
            PickerRow(label: "Provider", selection: viewModel.config.voice.ttsProvider, options: viewModel.ttsProviders) { viewModel.setTTSProvider($0) }
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
                EditableTextField(label: "Model", value: viewModel.config.voice.ttsXAIModel) { viewModel.setTTSXAIModel($0) }
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
            ) { viewModel.setSTTProvider($0) }
            // v0.20: global language hint applied to every provider unless a
            // per-provider language overrides it — hidden on pre-v0.20 hosts
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
                // v0.20: faster-whisper anti-hallucination VAD tuning —
                // hidden on pre-v0.20 hosts (hasSTTLocalVADTuning).
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
                // v0.20: config-driven Groq STT knobs — hidden on pre-v0.20
                // hosts (hasSTTUnifiedLanguage; the provider itself is
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

        // v0.20.4+ — "Hey Hermes" hands-free wake word capture placement.
        if capabilitiesStore?.capabilities.isV0204OrLater ?? false {
            SettingsSection(title: "Wake Word", icon: "waveform.badge.mic") {
                PickerRow(label: "Capture", selection: viewModel.config.voice.wakeWordCapture, options: ["auto", "local", "client"]) { viewModel.setWakeWordCapture($0) }
                    .help("auto: backend PortAudio mic when one exists, else a remote desktop on a mic-less (headless/VPS) backend streams its own mic via the wake.feed RPC. local: always the backend mic. client: always desktop-streamed PCM (detection stays on the backend).")
            }
        }
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
