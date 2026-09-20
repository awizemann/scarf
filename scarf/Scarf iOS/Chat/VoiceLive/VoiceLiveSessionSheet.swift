import SwiftUI
import ScarfCore
import ScarfDesign

/// The Live Voice session screen (P5b), presented as a sheet over Chat.
///
/// Binds only to `VoiceConversationEngine` (P4), so a future free chained
/// engine renders here unchanged. `VoiceLiveMediaHostView` stays mounted for
/// the sheet's whole life: WebKit plays the remote audio only while its web
/// view is in the view hierarchy. Dismissing the sheet ends the session
/// (`VoiceLiveSessionModel.teardown(.sheetDismissed)` from ChatView).
struct VoiceLiveSessionSheet: View {
    let model: VoiceLiveSessionModel
    let session: VoiceLiveSessionModel.Session
    let onTryAgain: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var engine: any VoiceConversationEngine { session.engine }
    /// Chained runs on-device speech + the host's own voice: no vendor, no
    /// per-minute cost, so the cost line is replaced by a privacy line.
    private var isChained: Bool { session.kind == .chained }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ScarfSpace.s5) {
                    statusHeader
                    if engine.phase.isTerminal {
                        outcome
                    } else {
                        meterRow
                        if let notice = engine.notice {
                            noticeRow(notice)
                        }
                        captionsList
                    }
                }
                .padding(.horizontal, ScarfSpace.s4)
                .padding(.vertical, ScarfSpace.s4)
            }
            .safeAreaInset(edge: .bottom) { controls }
            .background(ScarfColor.backgroundPrimary.ignoresSafeArea())
            .navigationTitle(isChained ? Text("Voice conversation") : Text("Live Voice"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        if engine.phase.isActive { Text("Close") } else { Text("Done") }
                    }
                    .accessibilityHint(engine.phase.isActive
                            ? Text("Ends the Live Voice session.")
                            : Text("Returns to the chat."))
                }
            }
        }
        // Keep the web view mounted for the whole session (1×1, alpha 0,
        // hidden from accessibility). Without it no audio plays.
        .background {
            if let bridge = session.bridge {
                VoiceLiveMediaHostView(bridge: bridge)
            }
        }
        .onChange(of: engine.phase) { _, _ in
            model.phaseDidChange()
        }
    }

    // MARK: - Status

    private var statusHeader: some View {
        VStack(spacing: ScarfSpace.s3) {
            ZStack {
                Circle()
                    .fill(phaseTint.opacity(0.16))
                    .frame(width: 96, height: 96)
                    .scaleEffect(engine.phase == .listening ? 1 + engine.micLevel * 0.25 : 1)
                    .animation(ScarfAnimation.fast, value: engine.micLevel)
                if engine.phase == .connecting || engine.phase == .ending {
                    ProgressView()
                        .controlSize(.large)
                        .tint(phaseTint)
                } else {
                    Image(systemName: phaseSymbol)
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(phaseTint)
                        .symbolEffect(.variableColor.iterative, isActive: engine.phase == .speaking)
                }
            }
            .accessibilityHidden(true)
            phaseLabel
                .font(.headline)
                .multilineTextAlignment(.center)
            if engine.isMuted, engine.phase.isActive {
                Label("Microphone muted", systemImage: "mic.slash.fill")
                    .font(.subheadline)
                    .foregroundStyle(ScarfColor.warning)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var phaseLabel: Text {
        switch engine.phase {
        case .idle, .connecting: Text("Connecting…")
        case .listening: Text("Listening")
        case .speaking: Text("Speaking")
        case .thinking: Text("Hermes is working on it…")
        case .ending: Text("Ending…")
        case .ended: Text("Live Voice ended")
        case .failed(let failure) where failure.setupHint: Text("Live Voice needs setup")
        case .failed: Text("Live Voice stopped")
        }
    }

    private var phaseSymbol: String {
        switch engine.phase {
        case .speaking: "waveform"
        case .thinking: "ellipsis.bubble"
        case .ended: "checkmark.circle"
        case .failed(let failure) where failure.setupHint: "wrench.and.screwdriver"
        case .failed: "exclamationmark.triangle"
        default: "mic"
        }
    }

    private var phaseTint: Color {
        switch engine.phase {
        case .failed(let failure): failure.setupHint ? ScarfColor.warning : ScarfColor.danger
        case .ended: ScarfColor.success
        case .thinking: ScarfColor.info
        default: ScarfColor.accent
        }
    }

    // MARK: - Time and cost

    /// Elapsed time plus the approximate spend, always visible while live:
    /// GPT-Live bills the host's OpenAI key $0.05/min.
    @ViewBuilder
    private var meterRow: some View {
        if isChained { chainedMeterRow } else { gptLiveMeterRow }
    }

    /// Chained: elapsed time and the privacy promise, no cost — the speech
    /// is recognized on this device and the reply is spoken by the host's
    /// own voice (or, if that fails, the system voice).
    private var chainedMeterRow: some View {
        VStack(spacing: 2) {
            Label {
                Text(verbatim: Self.elapsedText(engine.elapsedSeconds))
                    .monospacedDigit()
            } icon: {
                Image(systemName: "clock")
            }
            .font(.subheadline)
            Text("Your voice stays on this iPhone; replies are spoken by the host's voice or the system voice.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Elapsed \(Self.elapsedText(engine.elapsedSeconds)). Your voice stays on this iPhone; replies are spoken by the host's voice or the system voice."))
    }

    private var gptLiveMeterRow: some View {
        VStack(spacing: 2) {
            HStack(spacing: ScarfSpace.s3) {
                Label {
                    Text(verbatim: Self.elapsedText(engine.elapsedSeconds))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "clock")
                }
                Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                Text("≈ \(Self.costText(engine.approximateCostUSD))")
                    .monospacedDigit()
            }
            .font(.subheadline)
            Text("$0.05 per minute on the host's OpenAI key")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Elapsed \(Self.elapsedText(engine.elapsedSeconds)), approximately \(Self.costText(engine.approximateCostUSD)), billed at 5 cents per minute on the host's OpenAI key"))
    }

    static func elapsedText(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .minuteSecond))
    }

    static func costText(_ usd: Double) -> String {
        usd.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    // MARK: - Captions

    private var captionsList: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            if engine.captions.isEmpty {
                Group {
                    if engine.phase == .connecting {
                        Text("Starting the microphone and connecting through your Hermes host.")
                    } else {
                        Text("Speak naturally. Say “stop” or tap End when you're done.")
                    }
                }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                ForEach(engine.captions.suffix(12)) { caption in
                    captionRow(caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func captionRow(_ caption: VoiceCaption) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if caption.speaker == .user {
                    Text("You")
                } else {
                    Text("Voice")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(caption.speaker == .user ? ScarfColor.accent : ScarfColor.foregroundMuted)
            Text(verbatim: caption.text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func noticeRow(_ notice: VoiceSessionNotice) -> some View {
        Label {
            Self.noticeText(notice)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Outcome

    @ViewBuilder
    private var outcome: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            outcomeText
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if case .failed(let failure) = engine.phase, failure.setupHint {
                setupSteps(failure)
            }
            if engine.elapsedSeconds > 0 {
                Group {
                    if isChained {
                        Text("Session time \(Self.elapsedText(engine.elapsedSeconds)). Nothing was charged.")
                    } else {
                        Text("Session time \(Self.elapsedText(engine.elapsedSeconds)), approximately \(Self.costText(engine.approximateCostUSD)).")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ScarfSpace.s4)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
    }

    /// One localized sentence per notice. Vendor wording never shows; the
    /// engine logs it.
    static func noticeText(_ notice: VoiceSessionNotice) -> Text {
        switch notice {
        case .vendorError:
            Text("OpenAI reported a problem with Live Voice. The session is still running.")
        case .endingSoon(.turnStalled, _):
            Text("Hermes has been waiting a long time. Live Voice ends in about a minute unless you speak, to save cost.")
        case .endingSoon:
            Text("No one has spoken for a while. Live Voice ends in about a minute unless you speak, to save cost.")
        case .speechFallback:
            Text("Couldn't reach your Hermes host's voice, so replies are being read by this iPhone's system voice.")
        }
    }

    /// One localized sentence per outcome. `VoiceSessionFailure.englishDescription`
    /// is a diagnostic token only (ScarfCore has no string catalog).
    private var outcomeText: Text {
        // The host's own reason wins: the engine reports a host-driven end
        // as a plain `.userEnded`, which would otherwise read as if the
        // user had pressed End.
        if case .ended = engine.phase, model.endNote == .hermesConnectionLost {
            return Text("Live Voice ended because the connection to Hermes was lost. Your spoken turns and Hermes's replies so far are in the chat.")
        }
        return switch engine.phase {
        case .ended(.idleTimeout):
            Text("Live Voice ended on its own after \(Int(VoiceIdleMonitor.defaultTimeout / 60)) minutes with no speech, so it stopped billing.")
        case .ended(.stopPhrase):
            Text("You said stop, so Live Voice ended.")
        case .ended(.turnStalled):
            Text("Live Voice ended on its own after Hermes waited 10 minutes with no speech, so it stopped billing. The request is still in the chat.")
        case .ended:
            Text("Live Voice ended. Your spoken turns and Hermes's replies are in the chat.")
        case .failed(let failure):
            Self.failureText(failure)
        default:
            Text(verbatim: "")
        }
    }

    static func failureText(_ failure: VoiceSessionFailure) -> Text {
        switch failure {
        case .host(.noKey):
            Text("Live Voice needs an OpenAI API key on your Hermes host. Nothing was charged.")
        case .host(.unsupported):
            Text("Live Voice needs Hermes 0.21.3 or newer on this server.")
        case .host(.interpreterNotFound):
            Text("Scarf couldn't find Hermes's Python on the server, so Live Voice couldn't start.")
        case .host(.vendor(let status?, _)):
            Text("OpenAI refused the Live Voice session (error \(status)). Check the key's access and quota on the host.")
        case .host(.vendor(nil, _)):
            Text("OpenAI refused the Live Voice session. Check the key's access and quota on the host.")
        case .host(.network):
            Text("Your Hermes host couldn't reach OpenAI to start Live Voice.")
        case .host(.transport):
            Text("Couldn't reach your Hermes host to start Live Voice.")
        case .host(.badRequest), .host(.hostInternal), .host(.malformedOutput):
            Text("Hermes couldn't start Live Voice. Try again; if it keeps failing, check the host's Hermes logs.")
        case .mediaUnavailable:
            Text("Couldn't start Live Voice audio on this device.")
        case .microphoneDenied:
            Text("ScarfGo can't use the microphone. Allow microphone access in Settings, then try again.")
        case .speechRecognitionDenied:
            Text("ScarfGo can't use speech recognition, so it can't turn your voice into words on this iPhone.")
        case .speechRecognitionUnavailable:
            Text("This iPhone has no on-device speech recognition for your language, and ScarfGo never sends your voice away to transcribe it.")
        case .microphoneBusy:
            Text("Another app is using the microphone. Finish there, then try again.")
        case .microphoneNotFound:
            Text("No microphone is available.")
        case .audioConnectFailed:
            Text("Live Voice couldn't connect its audio.")
        case .connectTimedOut:
            Text("Live Voice took too long to connect.")
        case .connectionLost:
            Text("The Live Voice connection dropped.")
        case .mediaProcessTerminated:
            Text("Live Voice stopped unexpectedly.")
        case .closedByVendor:
            Text("OpenAI ended the Live Voice session.")
        }
    }

    @ViewBuilder
    private func setupSteps(_ failure: VoiceSessionFailure) -> some View {
        switch failure {
        case .host(.noKey):
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                Text("To set it up, on the Hermes host:")
                    .font(.callout.weight(.semibold))
                Label {
                    Text("Add `OPENAI_API_KEY=…` to `~/.hermes/.env`, or set `voice.gpt_live.api_key` in config.yaml.")
                } icon: {
                    Image(systemName: "1.circle")
                }
                Label {
                    Text("Come back here and tap Try Again. Live Voice bills that key $0.05 per minute while a session is open.")
                } icon: {
                    Image(systemName: "2.circle")
                }
            }
            .font(.callout)
        case .host(.unsupported):
            Text("Update Hermes on the host (`hermes update`), then try again.")
                .font(.callout)
        case .speechRecognitionDenied:
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                Label {
                    Text("Open Settings \u{203A} Privacy & Security \u{203A} Speech Recognition and turn ScarfGo on.")
                } icon: {
                    Image(systemName: "1.circle")
                }
                Label {
                    Text("Do the same under Settings \u{203A} Privacy & Security \u{203A} Microphone, then tap Try Again.")
                } icon: {
                    Image(systemName: "2.circle")
                }
            }
            .font(.callout)
        case .speechRecognitionUnavailable:
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                Label {
                    Text("Open Settings \u{203A} General \u{203A} Keyboard and turn on Dictation, so iOS downloads your language's on-device model.")
                } icon: {
                    Image(systemName: "1.circle")
                }
                Label {
                    Text("If your language has no on-device model, switch to Live Voice (GPT-Live) in Settings.")
                } icon: {
                    Image(systemName: "2.circle")
                }
            }
            .font(.callout)
        default:
            EmptyView()
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: ScarfSpace.s3) {
            if engine.phase.isActive {
                Button {
                    model.toggleMute()
                } label: {
                    Group {
                        if engine.isMuted {
                            Label("Unmute", systemImage: "mic.fill")
                        } else {
                            Label("Mute", systemImage: "mic.slash")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(engine.phase == .ending)

                Button(role: .destructive) {
                    model.endFromUser()
                } label: {
                    Label("End", systemImage: "phone.down.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(ScarfDestructiveButton())
                .disabled(engine.phase == .ending)
                .accessibilityHint(Text("Ends the session and stops billing."))
            } else {
                Button {
                    onTryAgain()
                } label: {
                    Text("Try Again")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(ScarfPrimaryButton())
            }
        }
        .padding(.horizontal, ScarfSpace.s4)
        .padding(.vertical, ScarfSpace.s3)
        .background(.regularMaterial)
    }
}
