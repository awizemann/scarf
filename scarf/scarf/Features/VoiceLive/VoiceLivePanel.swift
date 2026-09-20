import SwiftUI
import AppKit
import ScarfCore
import ScarfDesign

/// The Live Voice session strip, docked above the chat composer while a
/// session runs (and afterwards, until closed, so the user can read how it
/// ended). Binds only to `VoiceConversationEngine`.
///
/// It also hosts the bridge's web view (`VoiceLiveMediaHostView`, 1×1 and
/// invisible): the panel is on screen for the whole session, which keeps
/// the web view in the window hierarchy — WebKit plays no remote audio
/// from a detached one.
struct VoiceLivePanel: View {
    let controller: VoiceLiveController
    /// Start a fresh session after one ended ("Start Again").
    let onRestart: () -> Void
    /// The host's resolved `tts.provider`, named in the chained privacy
    /// line — but only when the Playback Engine preference actually sends
    /// the reply there. `nil` when the config hasn't been read yet.
    var ttsProvider: String?
    /// Whether "Start Again" can work right now (the chat can host turns).
    let canRestart: Bool

    /// The same client-side preference the chained session factory reads:
    /// it decides whether the reply is spoken by the host's provider or by
    /// this Mac, so the privacy line has to read it too.
    @AppStorage(MessageSpeechService.engineKey)
    private var playbackPreference = HermesSpeechService.PlaybackEngine.system.rawValue

    var body: some View {
        if let engine = controller.engine {
            content(engine)
                .modifier(PanelChrome(controller: controller))
                .onChange(of: engine.phase) { old, new in
                    if let line = VoiceLivePresentation.announcement(from: old, to: new, endNote: controller.endNote) {
                        AccessibilityNotification.Announcement(line).post()
                    }
                }
        } else if let failure = controller.startFailure {
            // A permission the engine needs was refused before anything was
            // built, so there is no engine to carry a `.failed` phase — the
            // panel shows the same copy it would have.
            failureFooter(VoiceLivePresentation.failure(failure))
                .modifier(PanelChrome(controller: controller))
        }
    }

    /// The strip's shared frame, background and accessibility identity.
    private struct PanelChrome: ViewModifier {
        let controller: VoiceLiveController

        func body(content: Content) -> some View {
            content
                .padding(.horizontal, ScarfSpace.s3)
                .padding(.vertical, ScarfSpace.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ScarfColor.backgroundSecondary)
                .overlay(Rectangle().fill(ScarfColor.border).frame(height: 1), alignment: .top)
                .background {
                    if let bridge = controller.bridge {
                        VoiceLiveMediaHostView(bridge: bridge)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Voice session"))
                .accessibilityIdentifier("chat.voiceLive.panel")
        }
    }

    @ViewBuilder
    private func content(_ engine: any VoiceConversationEngine) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            header(engine)
            if !engine.captions.isEmpty {
                VoiceLiveCaptions(captions: engine.captions)
            }
            // What the free path does with the user's voice, in one line,
            // where GPT-Live shows its per-minute cost.
            if controller.engineKind == .chained {
                Text(verbatim: VoiceLivePresentation.chainedPrivacyNote(
                    ttsProvider: ttsProvider,
                    playbackPreference: playbackPreference
                ))
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = engine.notice, engine.phase.isActive {
                Label {
                    Text(verbatim: VoiceLivePresentation.notice(notice))
                } icon: {
                    Image(systemName: "exclamationmark.bubble")
                }
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.warning)
            }
            switch engine.phase {
            case .ended(let reason):
                endedFooter(engine, reason: reason)
            case .failed(let failure):
                failureFooter(VoiceLivePresentation.failure(failure))
            default:
                EmptyView()
            }
        }
    }

    // MARK: Header: status, readout, controls

    private func header(_ engine: any VoiceConversationEngine) -> some View {
        HStack(spacing: ScarfSpace.s3) {
            VoiceLiveStatusOrb(phase: engine.phase, level: engine.micLevel, isMuted: engine.isMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: VoiceLivePresentation.phaseLabel(engine.phase))
                    .scarfStyle(.bodyEmph)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                // Nothing to report before the session went live (a start
                // failure bills nothing).
                if engine.elapsedSeconds > 0 || engine.phase.isLive {
                    readout(engine)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: ScarfSpace.s2)
            if engine.phase.isActive {
                activeControls(engine)
            } else {
                Button {
                    controller.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel(Text("Close Live Voice panel"))
            }
        }
    }

    @ViewBuilder
    private func readout(_ engine: any VoiceConversationEngine) -> some View {
        let elapsed = VoiceLivePresentation.elapsed(engine.elapsedSeconds)
        // Chained costs nothing, so its readout is the clock alone; a
        // "$0.00" would read as a bill that just hasn't grown yet.
        if VoiceLivePresentation.showsCost(for: controller.engineKind ?? .gptLive) {
            let cost = VoiceLivePresentation.cost(engine.approximateCostUSD)
            Text("\(elapsed) · about \(cost)")
                .font(ScarfFont.monoSmall)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .help("Approximate GPT-Live cost at $0.05 per minute, billed to the OpenAI key on the Hermes host.")
                .accessibilityLabel(Text("Elapsed \(elapsed), approximate cost \(cost)"))
        } else {
            Text(verbatim: elapsed)
                .font(ScarfFont.monoSmall)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .accessibilityLabel(Text("Elapsed \(elapsed)"))
        }
    }

    private func activeControls(_ engine: any VoiceConversationEngine) -> some View {
        HStack(spacing: ScarfSpace.s2) {
            Button {
                controller.toggleMute()
            } label: {
                Image(systemName: engine.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(engine.isMuted ? ScarfColor.warning : ScarfColor.foregroundMuted)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                            .fill(ScarfColor.backgroundTertiary)
                    )
            }
            .buttonStyle(.plain)
            .disabled(engine.phase == .ending)
            .help(engine.isMuted ? Text("Unmute microphone") : Text("Mute microphone"))
            .accessibilityLabel(engine.isMuted ? Text("Unmute microphone") : Text("Mute microphone"))
            .accessibilityIdentifier("chat.voiceLive.mute")

            Button {
                controller.end()
            } label: {
                Label("End", systemImage: "phone.down.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ScarfColor.onAccent)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                            .fill(ScarfColor.danger)
                    )
            }
            .buttonStyle(.plain)
            .disabled(engine.phase == .ending)
            // ⌘. is the Mac's "stop what's running" key.
            .keyboardShortcut(".", modifiers: .command)
            .help("End voice session (⌘.)")
            .accessibilityLabel(Text("End voice session"))
            .accessibilityIdentifier("chat.voiceLive.end")
        }
    }

    // MARK: Footers

    private func endedFooter(_ engine: any VoiceConversationEngine, reason: VoiceSessionEndReason) -> some View {
        HStack(spacing: ScarfSpace.s2) {
            if let message = VoiceLivePresentation.endedMessage(reason, endNote: controller.endNote) {
                Text(verbatim: message)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer(minLength: 0)
            restartButton(title: Text("Start Again"))
        }
    }

    private func failureFooter(_ copy: VoiceLivePresentation.FailureCopy) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s1) {
            Label {
                Text(verbatim: copy.message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .scarfStyle(.body)
            .foregroundStyle(ScarfColor.danger)
            if let guidance = copy.guidance {
                Text(verbatim: guidance)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: ScarfSpace.s2) {
                Spacer(minLength: 0)
                if copy.offersMicrophoneSettings {
                    Button("Open Privacy Settings") {
                        openPrivacyPane("Privacy_Microphone")
                    }
                }
                // Speech recognition is its own TCC entry with its own
                // pane; the microphone pane would show an already-on switch.
                if copy.offersSpeechRecognitionSettings {
                    Button("Open Privacy Settings") {
                        openPrivacyPane("Privacy_SpeechRecognition")
                    }
                }
                restartButton(title: Text("Try Again"))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private var restartHelp: Text {
        if canRestart { return Text("Start a new voice session in this chat") }
        if controller.isBlockedByAnotherWindow {
            return Text("A voice session is running in another Scarf window. End it there first.")
        }
        return Text("Open a chat session to talk with Hermes.")
    }

    private func restartButton(title: Text) -> some View {
        Button(action: onRestart) { title }
            .disabled(!canRestart)
            .help(restartHelp)
            .accessibilityIdentifier("chat.voiceLive.restart")
    }
}

/// The phase indicator: a dot that pulses with the mic level while live.
private struct VoiceLiveStatusOrb: View {
    let phase: VoiceConversationPhase
    let level: Double
    let isMuted: Bool

    private var tint: Color {
        switch phase {
        case .failed: return ScarfColor.danger
        case .ended, .idle: return ScarfColor.foregroundFaint
        case .connecting, .ending: return ScarfColor.foregroundMuted
        case .thinking: return ScarfColor.info
        case .listening, .speaking: return isMuted ? ScarfColor.warning : ScarfColor.accent
        }
    }

    private var symbol: String {
        switch phase {
        case .failed: return "exclamationmark"
        case .ended, .idle: return "waveform"
        case .connecting, .ending: return "ellipsis"
        case .thinking: return "sparkles"
        case .speaking: return "speaker.wave.2.fill"
        case .listening: return isMuted ? "mic.slash.fill" : "mic.fill"
        }
    }

    var body: some View {
        let live = phase.isLive && !isMuted
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
                .scaleEffect(live ? 1 + min(max(level, 0), 1) * 0.45 : 1)
                .animation(.easeOut(duration: 0.12), value: level)
            Circle()
                .fill(tint)
                .frame(width: 22, height: 22)
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(ScarfColor.onAccent)
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}

/// The last few caption lines, newest at the bottom.
private struct VoiceLiveCaptions: View {
    let captions: [VoiceCaption]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(captions) { caption in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(caption.speaker == .user ? "You" : "Voice")
                                .scarfStyle(.caption)
                                .foregroundStyle(ScarfColor.foregroundFaint)
                                .frame(width: 40, alignment: .trailing)
                            Text(verbatim: caption.text)
                                .scarfStyle(.caption)
                                .foregroundStyle(caption.speaker == .user ? ScarfColor.foregroundMuted : ScarfColor.foregroundPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .id(caption.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 84)
            .onChange(of: captions.last?.text) { _, _ in
                if let last = captions.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}
