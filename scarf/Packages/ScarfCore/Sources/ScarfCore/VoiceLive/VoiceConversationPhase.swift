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
    /// Closed on an error; the message is user-presentable.
    case failed(String)

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
    case failed(String)
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

        case .failed(let message):
            guard state.phase.isActive else { return state }
            return VoiceConversationState(phase: .failed(message))
        }
        return next
    }

    private static func livePhase(_ state: VoiceConversationState) -> VoiceConversationPhase {
        if state.assistantSpeaking { return .speaking }
        if state.delegationActive { return .thinking }
        return .listening
    }
}
