import Foundation

/// Tuning + identity for one realtime voice session.
///
/// The values here are the ones the OpenAI Realtime API shapes require:
/// PCM16 mono at 24 kHz in both directions, a server-side VAD with the
/// thresholds the Hermes `hermes-s2s` reference implementation ships, and
/// the model/voice pair that the ephemeral token is minted against.
///
/// Pass 2 (the gpt-live-1 server-relay backend) conforms to the same
/// configuration so the UI never learns which transport is live.
public struct RealtimeVoiceConfiguration: Sendable, Hashable {
    /// Realtime model identifier, e.g. `gpt-realtime-2.1`. The
    /// gpt-live family (`gpt-live-1`) is NOT valid here — that model is
    /// served only by `/v1/live/sessions`, which rejects ephemeral
    /// tokens (verified 2026-09-15: HTTP 401) and so needs the pass-2
    /// server-relay backend.
    public var model: String
    /// Voice name pinned into the minted session, e.g. `marin`.
    public var voice: String
    /// Short conversation guidance sent in `session.update`.
    public var instructions: String
    /// VAD sensitivity (0–1). Lower = more sensitive.
    public var vadThreshold: Double
    /// Mic audio kept before detected speech, in milliseconds.
    public var vadPrefixPaddingMs: Int
    /// Silence that ends a user turn, in milliseconds.
    public var vadSilenceDurationMs: Int
    /// Base URL of the realtime endpoint (the model query is appended
    /// by ``websocketURL``). Injectable so tests never touch the network.
    public var endpoint: URL

    public init(
        model: String = "gpt-realtime-2.1",
        voice: String = "marin",
        instructions: String = "Be concise and natural. Keep replies short enough to speak aloud.",
        vadThreshold: Double = 0.5,
        vadPrefixPaddingMs: Int = 300,
        vadSilenceDurationMs: Int = 500,
        endpoint: URL = URL(string: "wss://api.openai.com/v1/realtime")!
    ) {
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.vadThreshold = vadThreshold
        self.vadPrefixPaddingMs = vadPrefixPaddingMs
        self.vadSilenceDurationMs = vadSilenceDurationMs
        self.endpoint = endpoint
    }

    /// Full WebSocket URL the service connects to. The Realtime API
    /// takes the model as a URL query, and the ephemeral token is bound
    /// to the model minted at `client_secrets` — the two must agree or
    /// the server rejects the session with `invalid_model`.
    public var websocketURL: URL {
        URL(string: endpoint.absoluteString + "?model=\(model)") ?? endpoint
    }
}

/// Domain events a realtime voice session surfaces to the UI.
///
/// These are backend-agnostic: the OpenAI implementation maps its wire
/// events onto them, and the pass-2 relay backend maps its own. Wire
/// event *aliases* (the endpoint has used more than one name for the
/// assistant audio delta across API generations) are collapsed here so
/// consumers never branch on spelling.
public enum RealtimeVoiceEvent: Sendable, Equatable {
    /// The server accepted the session.
    case sessionCreated(sessionID: String?)
    /// The server accepted a live session update.
    case sessionUpdated
    /// Server VAD detected the start of user speech — barge-in. The
    /// service has already sent `conversation.item.truncate` for any
    /// in-flight assistant audio; the client must cut local playback
    /// the moment it sees this.
    case userSpeechStarted
    /// Incremental user-side (input audio) transcript.
    case userTranscriptDelta(String)
    /// Final user-side transcript for the finished utterance.
    case userTranscriptCompleted(String)
    /// Incremental assistant transcript.
    case assistantTranscriptDelta(String)
    /// An assistant output item began streaming (audio will follow).
    case outputItemStarted(itemID: String)
    /// Decoded assistant audio: raw little-endian PCM16 mono @ 24 kHz,
    /// base64 already stripped on the wire.
    case outputAudioDelta(itemID: String, data: Data)
    /// The assistant finished its response.
    case responseCompleted
    /// The in-flight response was cancelled (barge-in aftermath).
    case responseCancelled
    /// Server-reported error (transient or fatal — see the reducer).
    case errorOccurred(message: String, type: String?)
    /// The transport went away. Reasons distinguish a user-initiated
    /// stop from a server cap / failure so the UI can decide between
    /// "ended" and "failed".
    case closed(reason: RealtimeCloseReason)
}

/// Why a realtime session ended.
public enum RealtimeCloseReason: Sendable, Equatable {
    /// We called `stop()`. Expected; UI shows "ended".
    case clientInitiated
    /// The server closed the socket (most commonly the ~30-minute
    /// session cap — there is no resume handle, so the UI offers a
    /// fresh start, never an automatic reconnect).
    case serverClosed(detail: String?)
    /// The transport failed (DNS, TLS, dropped connection).
    case transportFailed(detail: String)
}

/// Failures a realtime voice session can produce. All carry a
/// user-presentable message; none embed credentials.
public enum RealtimeVoiceError: Error, LocalizedError, Equatable {
    /// `start()` was called on a service that already ran a session.
    /// Services are single-session by design — restart means a fresh
    /// instance, which is also the reconnect guard: nothing retries
    /// on its own.
    case alreadyStarted
    /// The ephemeral token could not be minted on the Hermes host.
    case tokenMintFailed(reason: String)
    /// The WebSocket could not be established.
    case connectionFailed(reason: String)
    /// A send was attempted with no live socket.
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "This voice session already ran. Start a new session instead."
        case .tokenMintFailed(let reason):
            return "Couldn't start voice: \(reason)"
        case .connectionFailed(let reason):
            return "Couldn't connect the voice session: \(reason)"
        case .notConnected:
            return "The voice session is no longer connected."
        }
    }
}

/// The UI-facing session phase, advanced by ``VoiceLivePhaseReducer``.
public enum VoiceLivePhase: Sendable, Equatable {
    case idle
    case connecting
    case listening
    case speaking
    case ended
    case failed(String)

    public var isTerminal: Bool {
        switch self {
        case .ended, .failed: return true
        default: return false
        }
    }
}

/// Pure state machine for the live-voice UI: `(phase, event) → phase`.
///
/// Keeping the transition table here (rather than inside the view model)
/// makes the whole lifecycle testable in the ScarfCore package — the view
/// model only routes audio side effects alongside the transitions.
public enum VoiceLivePhaseReducer {
    public static func next(_ phase: VoiceLivePhase, after event: RealtimeVoiceEvent) -> VoiceLivePhase {
        switch event {
        case .sessionCreated, .sessionUpdated:
            switch phase {
            case .connecting, .listening, .speaking:
                // `connecting → listening` on the first sessionCreated;
                // later session echoes (updated) must not regress a live
                // speaking turn back to listening.
                return phase == .connecting ? .listening : phase
            default:
                return phase
            }

        case .outputItemStarted, .outputAudioDelta:
            switch phase {
            case .listening, .speaking:
                return .speaking
            default:
                return phase
            }

        case .userTranscriptDelta, .userTranscriptCompleted, .assistantTranscriptDelta:
            // Transcript deltas update the view but do not change who owns
            // the microphone/audio floor.
            return phase

        case .userSpeechStarted, .responseCancelled, .responseCompleted:
            // Barge-in and turn end both hand the floor back to the mic.
            switch phase {
            case .speaking, .listening:
                return .listening
            default:
                return phase
            }

        case .errorOccurred(let message, _):
            switch phase {
            case .idle, .ended:
                return phase
            case .connecting, .listening, .speaking:
                return .failed(message)
            case .failed:
                return phase
            }
        case .closed(let reason):
            switch phase {
            case .idle, .ended, .failed:
                return phase
            case .connecting:
                // Died before the session was ever created — that is a
                // connection failure, not a session end.
                switch reason {
                case .clientInitiated: return .ended
                case .serverClosed(let detail?), .transportFailed(let detail):
                    return .failed(detail)
                case .serverClosed(detail: .none):
                    return .failed("The voice session closed before it started.")
                }
            case .listening, .speaking:
                switch reason {
                case .clientInitiated:
                    return .ended
                case .serverClosed(let detail?):
                    return .failed("\(detail) Start a new session to continue.")
                case .serverClosed(detail: .none):
                    return .failed("The voice session ended (server closed the connection). Start a new session to continue.")
                case .transportFailed(let detail):
                    return .failed("\(detail) Start a new session to continue.")
                }
            }
        }
    }
}
