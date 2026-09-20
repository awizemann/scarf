import Foundation

// Adapted from @danmarauda's `VoiceLivePhase` / `VoiceLivePhaseReducer`
// (Scarf PR #143, RealtimeVoiceModels.swift): a pure `(state, event) → state`
// machine so the whole lifecycle is testable in the package. Reworked for the
// engine-agnostic voice surface: a `thinking` phase while Hermes answers a
// delegation, and the direct-to-OpenAI audio-item events replaced by
// speaking / delegation / live / closed events any engine can emit.

/// Why a voice session ended normally.
public enum VoiceSessionEndReason: Sendable, Equatable {
    /// The user pressed End (or the host UI ended it: window close, session
    /// or server switch, app backgrounding).
    case userEnded
    /// The user said a stop phrase ("stop", "that's all", "goodbye", …).
    case stopPhrase
    /// Nobody spoke for the idle timeout (cost guard).
    case idleTimeout
    /// Hermes worked on a spoken request for the stalled-turn cap (10
    /// minutes by default) with no speech from the user and no progress
    /// from Hermes, e.g. while it waited on a tool approval (cost guard).
    case turnStalled
}

/// A non-fatal, transient message about a running session, for a banner.
/// Structured (not text) so each app shows one localized sentence per case;
/// vendor wording never reaches the UI (it goes to the log only).
public enum VoiceSessionNotice: Sendable, Equatable {
    /// The vendor reported a non-fatal error. `code` is the vendor's error
    /// code, a diagnostic token only (e.g. `rate_limited`), never UI copy.
    case vendorError(code: String?)
    /// The session is about to end on its own (`reason` is ``VoiceSessionEndReason/idleTimeout``
    /// or ``VoiceSessionEndReason/turnStalled``) unless someone speaks.
    /// `secondsLeft` is rounded up, for "about a minute" style copy.
    case endingSoon(reason: VoiceSessionEndReason, secondsLeft: Int)
    /// The chained engine could not reach the host's TTS for a piece of the
    /// reply and used the device's system voice instead. Shown ONCE per
    /// session (``FallbackVoiceSpeaker``): the conversation continues either
    /// way, so this is information, not a failure.
    case speechFallback

    /// English diagnostic text (ScarfCore has no string catalog).
    public var englishDescription: String {
        switch self {
        case .vendorError(let code?): return "Live Voice reported a problem (\(code))."
        case .vendorError(nil): return "Live Voice reported a problem."
        case .endingSoon(.turnStalled, let seconds):
            return "Hermes is still waiting. Live Voice ends in \(seconds) s unless you speak."
        case .endingSoon(_, let seconds):
            return "No one has spoken for a while. Live Voice ends in \(seconds) s unless you speak."
        case .speechFallback:
            return "Couldn't reach the Hermes voice, so this is the system voice."
        }
    }
}

/// Why a voice session failed. Structured so each app can localize one
/// sentence per case and special-case the actionable ones (``setupHint``).
/// ScarfCore has no string catalog, so ``englishDescription`` is an English
/// fallback/diagnostic token, not UI copy.
public enum VoiceSessionFailure: Sendable, Equatable {
    /// The host-side session exchange failed — including `.noKey`, the
    /// "add an OpenAI key on the host" setup case (nothing was billed).
    case host(VoiceLiveHostError)
    /// The media layer couldn't start (page, WebKit, microphone API).
    case mediaUnavailable(detail: String)
    /// The user (or the OS) denied the microphone (`NotAllowedError`).
    case microphoneDenied
    /// Chained only: on-device speech recognition cannot run here — no
    /// recognizer for the locale, or the device/locale has no on-device
    /// language model. Never a fallback to Apple's servers: the chained path
    /// promises the audio stays on the device (``VoiceListenerError``).
    case speechRecognitionUnavailable
    /// Chained only: the user (or the OS) denied speech recognition. A
    /// SEPARATE permission from the microphone, with its own Settings row,
    /// so the apps can point at the right one.
    case speechRecognitionDenied
    /// Another app or process holds the microphone (`NotReadableError`).
    case microphoneBusy
    /// There is no microphone (`NotFoundError` / `OverconstrainedError`).
    case microphoneNotFound
    /// The vendor's answer couldn't be applied to the peer connection.
    case audioConnectFailed(detail: String)
    /// No live session within the connect timeout after the offer.
    case connectTimedOut
    /// The WebRTC connection or data channel dropped.
    case connectionLost
    /// The web content process died.
    case mediaProcessTerminated
    /// The vendor closed the session without being asked (e.g. its session
    /// length cap). `usageSeconds` is what it billed, when reported.
    case closedByVendor(reason: String, usageSeconds: Double?)

    /// True when the fix is configuration on the Hermes host (no key, old
    /// Hermes, no interpreter): show setup guidance rather than "try again".
    public var setupHint: Bool {
        switch self {
        case .host(.noKey), .host(.unsupported), .host(.interpreterNotFound): return true
        // Both are fixed in Settings (grant the permission, or install the
        // language's on-device model), never by retrying.
        case .speechRecognitionUnavailable, .speechRecognitionDenied: return true
        default: return false
        }
    }

    public var englishDescription: String {
        switch self {
        case .host(let error): return error.errorDescription ?? "Live Voice couldn't start."
        case .mediaUnavailable(let detail): return "Couldn't start Live Voice audio: \(detail)"
        case .microphoneDenied: return "Scarf can't use the microphone. Allow microphone access for Scarf, then try again."
        case .speechRecognitionUnavailable: return "On-device speech recognition isn't available for this language."
        case .speechRecognitionDenied: return "Scarf can't use speech recognition. Allow it for Scarf, then try again."
        case .microphoneBusy: return "Another app is using the microphone."
        case .microphoneNotFound: return "No microphone was found."
        case .audioConnectFailed(let detail): return "Live Voice couldn't connect its audio: \(detail)"
        case .connectTimedOut: return "Live Voice took too long to connect."
        case .connectionLost: return "The Live Voice connection dropped."
        case .mediaProcessTerminated: return "Live Voice stopped unexpectedly."
        case .closedByVendor(let reason, let seconds?): return "Live Voice ended: \(reason) (\(Int(seconds.rounded())) s)."
        case .closedByVendor(let reason, nil): return "Live Voice ended: \(reason)."
        }
    }
}

/// The UI-facing phase of a voice conversation. Engine-agnostic: GPT-Live
/// and a future chained engine report the same phases.
public enum VoiceConversationPhase: Sendable, Equatable {
    /// No session.
    case idle
    /// Opening the microphone / media / vendor session.
    case connecting
    /// Live; the voice is idle and listening.
    case listening
    /// Live; the voice is speaking.
    case speaking
    /// Live; Hermes is working on a delegated request.
    case thinking
    /// Closing gracefully (waiting for the vendor's final usage).
    case ending
    /// Closed normally.
    case ended(VoiceSessionEndReason)
    /// Closed on an error.
    case failed(VoiceSessionFailure)

    public var isTerminal: Bool {
        switch self {
        case .ended, .failed: return true
        default: return false
        }
    }

    /// Listening, speaking or thinking.
    public var isLive: Bool {
        switch self {
        case .listening, .speaking, .thinking: return true
        default: return false
        }
    }

    /// A session exists (anything from connecting through ending).
    public var isActive: Bool {
        switch self {
        case .connecting, .listening, .speaking, .thinking, .ending: return true
        default: return false
        }
    }
}

/// Inputs to ``VoiceConversationReducer``.
public enum VoiceConversationEvent: Sendable, Equatable {
    case startRequested
    /// The session is live (GPT-Live: `session.started`).
    case sessionLive
    /// The voice started / stopped producing audio.
    case assistantSpeaking(Bool)
    /// A delegation was handed to Hermes / settled.
    case delegationStarted
    case delegationSettled
    /// A graceful end was requested.
    case endRequested
    /// Terminal outcomes.
    case ended(VoiceSessionEndReason)
    case failed(VoiceSessionFailure)
}

/// Phase plus the two flags the live phase is derived from.
public struct VoiceConversationState: Sendable, Equatable {
    public var phase: VoiceConversationPhase = .idle
    public var assistantSpeaking = false
    public var delegationActive = false

    public init(phase: VoiceConversationPhase = .idle, assistantSpeaking: Bool = false, delegationActive: Bool = false) {
        self.phase = phase
        self.assistantSpeaking = assistantSpeaking
        self.delegationActive = delegationActive
    }
}

/// Pure state machine for a voice conversation.
///
/// While live, the phase is derived the way the Hermes desktop does it
/// (`refreshStatus`, `use-voice-live-conversation.ts:159-173` @ v2026.9.14):
/// speaking wins, then thinking (a delegation in flight), else listening.
/// Terminal phases ignore everything except a new start.
public enum VoiceConversationReducer {
    public static func reduce(_ state: VoiceConversationState, _ event: VoiceConversationEvent) -> VoiceConversationState {
        var next = state
        switch event {
        case .startRequested:
            guard state.phase == .idle || state.phase.isTerminal else { return state }
            return VoiceConversationState(phase: .connecting)

        case .sessionLive:
            guard state.phase == .connecting else { return state }
            next.phase = livePhase(next)

        case .assistantSpeaking(let speaking):
            guard state.phase.isActive else { return state }
            next.assistantSpeaking = speaking
            if state.phase.isLive { next.phase = livePhase(next) }

        case .delegationStarted, .delegationSettled:
            guard state.phase.isActive else { return state }
            next.delegationActive = event == .delegationStarted
            if state.phase.isLive { next.phase = livePhase(next) }

        case .endRequested:
            guard state.phase == .connecting || state.phase.isLive else { return state }
            next.phase = .ending

        case .ended(let reason):
            guard state.phase.isActive else { return state }
            return VoiceConversationState(phase: .ended(reason))

        case .failed(let failure):
            guard state.phase.isActive else { return state }
            return VoiceConversationState(phase: .failed(failure))
        }
        return next
    }

    private static func livePhase(_ state: VoiceConversationState) -> VoiceConversationPhase {
        if state.assistantSpeaking { return .speaking }
        if state.delegationActive { return .thinking }
        return .listening
    }
}
