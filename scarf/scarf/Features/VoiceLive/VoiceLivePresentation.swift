import Foundation
import ScarfCore

/// User-facing copy for a Live Voice session, one localized sentence per
/// engine state. ScarfCore's `englishDescription` strings are diagnostics
/// only (it has no string catalog); everything the panel shows comes from
/// here. Pure, so the mapping is unit-tested.
enum VoiceLivePresentation {

    /// A failure as the panel shows it.
    struct FailureCopy: Equatable {
        /// One sentence: what went wrong.
        let message: String
        /// What to do about it, when the fix is setup on the host or Mac.
        let guidance: String?
        // No vendor or system detail: it is untranslated vendor wording
        // that may echo request data. The engine logs it (redacted) under
        // com.scarf / LiveVoice; the panel never shows it (F4).
        /// Offer the macOS microphone privacy pane.
        let offersMicrophoneSettings: Bool
        /// Offer the macOS speech-recognition privacy pane (chained only —
        /// speech recognition is a SEPARATE TCC entry from the microphone,
        /// with its own pane, so pointing at the microphone one would send
        /// the user to a switch that is already on).
        var offersSpeechRecognitionSettings = false
    }

    /// Whether this engine's panel shows the elapsed/cost readout's cost
    /// half. Chained costs nothing — no vendor minute, no key — so a
    /// "$0.00" would be noise pretending to be a bill.
    static func showsCost(for kind: VoiceEngineKind) -> Bool {
        switch kind {
        case .gptLive: return true
        case .chained: return false
        }
    }

    /// The chained panel's one privacy line, in place of GPT-Live's cost
    /// line.
    ///
    /// It names the host's provider only when the reply actually goes
    /// there: `playbackPreference` is the Settings > Voice "Playback
    /// Engine" choice, the SAME preference `VoiceLiveController.chained`
    /// reads when it builds the speaker. With System Voice chosen the reply
    /// is synthesized on this Mac and the provider is never asked to speak
    /// anything, so naming it would claim a data flow that isn't
    /// happening. `ttsProvider` is `nil` when Scarf hasn't read the host's
    /// config yet - same answer, for the same reason: never invent a
    /// recipient.
    static func chainedPrivacyNote(ttsProvider: String?, playbackPreference: String?) -> String {
        let spokenOnThisMac = String(
            localized: "Your voice stays on this Mac; replies are spoken by this Mac's own voice."
        )
        guard VoiceLiveController.chainedPlaybackEngine(preference: playbackPreference) == .hermes else {
            return spokenOnThisMac
        }
        guard let provider = ttsProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
              !provider.isEmpty else {
            return spokenOnThisMac
        }
        return String(localized: "Your voice stays on this Mac; replies are spoken by \(provider) on the Hermes host.")
    }

    static func phaseLabel(_ phase: VoiceConversationPhase) -> String {
        switch phase {
        case .idle, .connecting: return String(localized: "Connecting…")
        case .listening: return String(localized: "Listening")
        case .speaking: return String(localized: "Speaking")
        case .thinking: return String(localized: "Hermes is working…")
        case .ending: return String(localized: "Ending…")
        case .ended: return String(localized: "Voice session ended")
        case .failed: return String(localized: "Live Voice")
        }
    }

    /// The ended footer's line. A host end note (the Hermes connection
    /// died) wins over the engine's reason, which reads `.userEnded` then.
    static func endedMessage(
        _ reason: VoiceSessionEndReason,
        endNote: VoiceLiveController.EndNote? = nil
    ) -> String? {
        switch endNote {
        case .hermesConnectionLost?:
            return String(localized: "Ended because the connection to Hermes was lost.")
        case nil:
            break
        }
        switch reason {
        case .userEnded:
            return nil
        case .stopPhrase:
            return String(localized: "Ended when you asked to stop.")
        case .idleTimeout:
            let minutes = Int((VoiceIdleMonitor.defaultTimeout / 60).rounded())
            return String(localized: "Ended after \(minutes) minutes without speech, to save cost.")
        case .turnStalled:
            return String(localized: "Ended after Hermes waited 10 minutes with no speech, to save cost. The request is still in the chat.")
        }
    }

    /// A running session's notice. Vendor wording never shows (the engine
    /// logs it).
    static func notice(_ notice: VoiceSessionNotice) -> String {
        switch notice {
        case .vendorError:
            return String(localized: "OpenAI reported a problem with Live Voice. The session is still running.")
        case .endingSoon(.turnStalled, _):
            return String(localized: "Hermes has been waiting a long time. Live Voice ends in about a minute unless you speak, to save cost.")
        case .endingSoon:
            return String(localized: "No one has spoken for a while. Live Voice ends in about a minute unless you speak, to save cost.")
        case .speechFallback:
            return String(localized: "The Hermes host couldn't speak part of that reply, so Scarf used this Mac's system voice.")
        }
    }

    /// What VoiceOver announces when the phase changes, or `nil` for a
    /// change not worth interrupting for (speaking ↔ listening flips many
    /// times a minute, and the voice itself is audible).
    static func announcement(
        from old: VoiceConversationPhase,
        to new: VoiceConversationPhase,
        endNote: VoiceLiveController.EndNote? = nil
    ) -> String? {
        guard old != new else { return nil }
        switch new {
        case .connecting:
            return String(localized: "Live Voice connecting")
        case .listening where !old.isLive:
            return String(localized: "Live Voice is listening")
        case .thinking:
            return String(localized: "Hermes is working on your request")
        case .ended(let reason):
            guard let detail = endedMessage(reason, endNote: endNote) else {
                return String(localized: "Voice session ended")
            }
            return String(localized: "Voice session ended. \(detail)")
        case .failed(let failure):
            return self.failure(failure).message
        case .idle, .listening, .speaking, .ending:
            return nil
        }
    }

    static func failure(_ failure: VoiceSessionFailure) -> FailureCopy {
        switch failure {
        case .host(let error):
            return hostFailure(error)
        case .mediaUnavailable:
            return FailureCopy(
                message: String(localized: "Live Voice audio couldn't start on this Mac."),
                guidance: nil, offersMicrophoneSettings: false
            )
        case .microphoneDenied:
            return FailureCopy(
                message: String(localized: "Scarf can't use the microphone."),
                guidance: String(localized: "Allow Scarf in System Settings › Privacy & Security › Microphone, then try again."),
                offersMicrophoneSettings: true
            )
        case .speechRecognitionDenied:
            return FailureCopy(
                message: String(localized: "Scarf can't use speech recognition."),
                guidance: String(localized: "Allow Scarf in System Settings › Privacy & Security › Speech Recognition, then try again."),
                offersMicrophoneSettings: false,
                offersSpeechRecognitionSettings: true
            )
        case .speechRecognitionUnavailable:
            return FailureCopy(
                message: String(localized: "This Mac can't transcribe your language without sending audio away."),
                guidance: String(localized: "Download the language in System Settings › Keyboard › Dictation, or switch your Mac's language to one it can transcribe on-device, then try again. Scarf never falls back to a server for this."),
                offersMicrophoneSettings: false
            )
        case .microphoneBusy:
            return FailureCopy(
                message: String(localized: "Another app is using the microphone."),
                guidance: String(localized: "Finish there, then try again."),
                offersMicrophoneSettings: false
            )
        case .microphoneNotFound:
            return FailureCopy(
                message: String(localized: "No microphone is available."),
                guidance: String(localized: "Connect or select a microphone in System Settings › Sound, then try again."),
                offersMicrophoneSettings: false
            )
        case .audioConnectFailed:
            return FailureCopy(
                message: String(localized: "Live Voice couldn't connect its audio."),
                guidance: nil, offersMicrophoneSettings: false
            )
        case .connectTimedOut:
            return FailureCopy(
                message: String(localized: "Live Voice took too long to connect."),
                guidance: nil, offersMicrophoneSettings: false
            )
        case .connectionLost:
            return FailureCopy(
                message: String(localized: "The Live Voice connection dropped."),
                guidance: nil, offersMicrophoneSettings: false
            )
        case .mediaProcessTerminated:
            return FailureCopy(
                message: String(localized: "Live Voice stopped unexpectedly."),
                guidance: nil, offersMicrophoneSettings: false
            )
        case .closedByVendor:
            return FailureCopy(
                message: String(localized: "OpenAI ended the Live Voice session."),
                guidance: nil, offersMicrophoneSettings: false
            )
        }
    }

    private static func hostFailure(_ error: VoiceLiveHostError) -> FailureCopy {
        switch error {
        case .noKey:
            return FailureCopy(
                message: String(localized: "Live Voice needs an OpenAI API key on the Hermes host."),
                guidance: String(localized: "Set OPENAI_API_KEY in the host's Hermes .env file, or voice.gpt_live.api_key in its config.yaml, then try again. Nothing was charged."),
                offersMicrophoneSettings: false
            )
        case .unsupported:
            return FailureCopy(
                message: String(localized: "This server's Hermes can't run Live Voice."),
                guidance: String(localized: "Update Hermes on the host to 0.21.3 or newer, then try again."),
                offersMicrophoneSettings: false
            )
        case .interpreterNotFound:
            return FailureCopy(
                message: String(localized: "Scarf couldn't find Hermes's Python on the host."),
                guidance: String(localized: "Check the Hermes installation on the host, then try again."),
                offersMicrophoneSettings: false
            )
        case .vendor(let status, _):
            let message: String
            switch status {
            case 401?: message = String(localized: "OpenAI rejected the API key on the Hermes host.")
            case 403?: message = String(localized: "The OpenAI key on the Hermes host has no access to GPT-Live.")
            case 429?: message = String(localized: "OpenAI's rate limit or quota was reached for the key on the Hermes host.")
            case let code?: message = String(localized: "OpenAI refused the Live Voice session (HTTP \(code)).")
            case nil: message = String(localized: "OpenAI refused the Live Voice session.")
            }
            return FailureCopy(message: message, guidance: nil, offersMicrophoneSettings: false)
        case .network:
            return FailureCopy(
                message: String(localized: "The Hermes host couldn't reach OpenAI."),
                guidance: nil, offersMicrophoneSettings: false
            )
        case .transport:
            return FailureCopy(
                message: String(localized: "Scarf couldn't reach the Hermes host."),
                guidance: nil, offersMicrophoneSettings: false
            )
        case .badRequest, .hostInternal, .malformedOutput:
            return FailureCopy(
                message: String(localized: "Live Voice couldn't start on the Hermes host."),
                guidance: nil, offersMicrophoneSettings: false
            )
        }
    }

    /// "1:05", for the elapsed readout.
    static func elapsed(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds.rounded(.down))).formatted(.time(pattern: .minuteSecond))
    }

    /// "$0.05", for the approximate cost readout.
    static func cost(_ usd: Double) -> String {
        usd.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}
