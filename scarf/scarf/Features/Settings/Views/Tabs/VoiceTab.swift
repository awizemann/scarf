import SwiftUI
import ScarfCore

/// Voice tab — push-to-talk + TTS + STT provider settings.
struct VoiceTab: View {
    @Bindable var viewModel: SettingsViewModel

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
            default:
                EmptyView()
            }
        }

        SettingsSection(title: "Speech-to-Text", icon: "waveform") {
            ToggleRow(label: "Enabled", isOn: viewModel.config.voice.sttEnabled) { viewModel.setSTTEnabled($0) }
            PickerRow(label: "Provider", selection: viewModel.config.voice.sttProvider, options: viewModel.sttProviders) { viewModel.setSTTProvider($0) }
            switch viewModel.config.voice.sttProvider {
            case "local":
                PickerRow(label: "Model", selection: viewModel.config.voice.sttLocalModel, options: ["tiny", "base", "small", "medium", "large-v3"]) { viewModel.setSTTLocalModel($0) }
                EditableTextField(label: "Language", value: viewModel.config.voice.sttLocalLanguage) { viewModel.setSTTLocalLanguage($0) }
            case "openai":
                EditableTextField(label: "Model", value: viewModel.config.voice.sttOpenAIModel) { viewModel.setSTTOpenAIModel($0) }
            case "mistral":
                EditableTextField(label: "Model", value: viewModel.config.voice.sttMistralModel) { viewModel.setSTTMistralModel($0) }
            default:
                EmptyView()
            }
        }
    }
}
