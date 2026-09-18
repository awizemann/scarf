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
        /// Vendor or system detail, shown verbatim in small type (already
        /// redacted by the host exchange). Never localized: it is data.
        let detail: String?
        /// Offer the macOS microphone privacy pane.
        let offersMicrophoneSettings: Bool
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

    static func endedMessage(_ reason: VoiceSessionEndReason) -> String? {
        switch reason {
        case .userEnded:
            return nil
        case .stopPhrase:
            return String(localized: "Ended when you asked to stop.")
        case .idleTimeout:
            let minutes = Int((VoiceIdleMonitor.defaultTimeout / 60).rounded())
            return String(localized: "Ended after \(minutes) minutes without speech, to save cost.")
        }
    }

    static func failure(_ failure: VoiceSessionFailure) -> FailureCopy {
        switch failure {
        case .host(let error):
            return hostFailure(error)
        case .mediaUnavailable(let detail):
            return FailureCopy(
                message: String(localized: "Live Voice audio couldn't start on this Mac."),
                guidance: nil, detail: detail, offersMicrophoneSettings: false
            )
        case .microphoneDenied:
            return FailureCopy(
                message: String(localized: "Scarf can't use the microphone."),
                guidance: String(localized: "Allow Scarf in System Settings › Privacy & Security › Microphone, then try again."),
                detail: nil, offersMicrophoneSettings: true
            )
        case .audioConnectFailed(let detail):
            return FailureCopy(
                message: String(localized: "Live Voice couldn't connect its audio."),
                guidance: nil, detail: detail, offersMicrophoneSettings: false
            )
        case .connectTimedOut:
            return FailureCopy(
                message: String(localized: "Live Voice took too long to connect."),
                guidance: nil, detail: nil, offersMicrophoneSettings: false
            )
        case .connectionLost:
            return FailureCopy(
                message: String(localized: "The Live Voice connection dropped."),
                guidance: nil, detail: nil, offersMicrophoneSettings: false
            )
        case .mediaProcessTerminated:
            return FailureCopy(
                message: String(localized: "Live Voice stopped unexpectedly."),
                guidance: nil, detail: nil, offersMicrophoneSettings: false
            )
        case .closedByVendor(let reason, _):
            return FailureCopy(
                message: String(localized: "OpenAI ended the Live Voice session."),
                guidance: nil, detail: reason, offersMicrophoneSettings: false
            )
        }
    }

    private static func hostFailure(_ error: VoiceLiveHostError) -> FailureCopy {
        switch error {
        case .noKey:
            return FailureCopy(
                message: String(localized: "Live Voice needs an OpenAI API key on the Hermes host."),
                guidance: String(localized: "Set OPENAI_API_KEY in the host's Hermes .env file, or voice.gpt_live.api_key in its config.yaml, then try again. Nothing was charged."),
                detail: nil, offersMicrophoneSettings: false
            )
        case .unsupported:
            return FailureCopy(
                message: String(localized: "This server's Hermes can't run Live Voice."),
                guidance: String(localized: "Update Hermes on the host to 0.21.3 or newer, then try again."),
                detail: nil, offersMicrophoneSettings: false
            )
        case .interpreterNotFound(let detail):
            return FailureCopy(
                message: String(localized: "Scarf couldn't find Hermes's Python on the host."),
                guidance: String(localized: "Check the Hermes installation on the host, then try again."),
                detail: detail, offersMicrophoneSettings: false
            )
        case .vendor(let status, let detail):
            let message: String
            switch status {
            case 401?: message = String(localized: "OpenAI rejected the API key on the Hermes host.")
            case 403?: message = String(localized: "The OpenAI key on the Hermes host has no access to GPT-Live.")
            case 429?: message = String(localized: "OpenAI's rate limit or quota was reached for the key on the Hermes host.")
            case let code?: message = String(localized: "OpenAI refused the Live Voice session (HTTP \(code)).")
            case nil: message = String(localized: "OpenAI refused the Live Voice session.")
            }
            return FailureCopy(message: message, guidance: nil, detail: detail.isEmpty ? nil : detail, offersMicrophoneSettings: false)
        case .network:
            return FailureCopy(
                message: String(localized: "The Hermes host couldn't reach OpenAI."),
                guidance: nil, detail: nil, offersMicrophoneSettings: false
            )
        case .transport:
            return FailureCopy(
                message: String(localized: "Scarf couldn't reach the Hermes host."),
                guidance: nil, detail: nil, offersMicrophoneSettings: false
            )
        case .badRequest(let detail), .hostInternal(let detail), .malformedOutput(let detail):
            return FailureCopy(
                message: String(localized: "Live Voice couldn't start on the Hermes host."),
                guidance: nil, detail: detail.isEmpty ? nil : detail, offersMicrophoneSettings: false
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
