import Foundation
import Observation

// The engine-agnostic Live Voice surface. The macOS panel (P5a) and the
// ScarfGo sheet (P5b) bind ONLY to `VoiceConversationEngine`; the chat side
// of each app conforms to `VoiceTurnHost`. GPT-Live (`GPTLiveEngine`) is the
// first engine; a free chained engine (on-device STT → ACP turn → Hermes
// TTS) can sit behind the same protocol with no UI change — nothing here
// assumes WebRTC, a vendor, or a key. Mirrors the Hermes desktop, where
// `useVoiceLiveConversation` has "the same public shape as
// useVoiceConversation" (use-voice-live-conversation.ts:70-77 @ v2026.9.14).

/// A running (or finished) voice conversation. `@MainActor` and
/// `Observable`: views read the properties directly.
@MainActor
public protocol VoiceConversationEngine: AnyObject, Observable {
    var phase: VoiceConversationPhase { get }
    /// Live captions, oldest first; consecutive fragments of one speaker
    /// are merged into one caption.
    var captions: [VoiceCaption] { get }
    /// The user's microphone input level, 0…1 (for a level meter).
    var micLevel: Double { get }
    var isMuted: Bool { get }
    /// Seconds since the session went live (frozen once it ends; the
    /// vendor's billed seconds replace it when reported). Updated about
    /// once a second.
    var elapsedSeconds: TimeInterval { get }
    /// Approximate spend for this session, in US dollars (``VoiceSessionCost``).
    /// `0` for engines that cost nothing.
    var approximateCostUSD: Double { get }
    /// A non-fatal notice from the engine or vendor, for a transient banner.
    var notice: String? { get }

    /// Start a session. No-op while one is active.
    func start() async
    /// End gracefully (GPT-Live waits up to 15 s for the vendor's final
    /// usage). Safe to call in any phase.
    func end(reason: VoiceSessionEndReason)
    /// End NOW, without waiting: window close, session/server switch, app
    /// quit or backgrounding. Tries to tell the vendor, then tears down.
    func endImmediately(reason: VoiceSessionEndReason)
    func toggleMute()
}

/// One caption line.
public struct VoiceCaption: Sendable, Equatable, Identifiable {
    public let id: Int
    public let speaker: VoiceTranscriptFragment.Speaker
    public var text: String

    public init(id: Int, speaker: VoiceTranscriptFragment.Speaker, text: String) {
        self.id = id
        self.speaker = speaker
        self.text = text
    }
}

// MARK: - The chat side

/// A Hermes turn the voice layer asks for.
public struct VoiceTurnRequest: Sendable, Equatable {
    /// Correlates the reply with the request (GPT-Live: the delegation id).
    public let id: String
    /// What the user last said. This — and only this — is the user message:
    /// the chat bubble and the persisted row.
    public let prompt: String
    /// The recent spoken exchange, `User:` / `Voice assistant:` lines.
    /// Model input only.
    public let context: String

    public init(id: String, prompt: String, context: String) {
        self.id = id
        self.prompt = prompt
        self.context = context
    }

    /// Pass these to `ACPClient.sendPrompt(sessionId:text:images:contextNotes:)`
    /// with `text: prompt`: Hermes's voice turn note plus `context`, as an
    /// embedded resource the model reads and the transcript never stores.
    public var contextNotes: [ACPContextNote] {
        [VoiceLiveTurnNote.contextNote(context: context)]
    }
}

/// The assistant's reply to a voice turn, as far as it has streamed.
public struct VoiceTurnReply: Sendable, Equatable {
    /// Raw assistant text (markdown is fine — the engine sanitizes it).
    public let text: String
    /// True while more text may still arrive.
    public let isStreaming: Bool

    public init(text: String, isStreaming: Bool) {
        self.text = text
        self.isStreaming = isStreaming
    }

    /// Helper for hosts backed by `RichChatViewModel`: the assistant text
    /// after the LAST user message in `messages`, provided that message is
    /// the voice turn's (its content equals `prompt`). `nil` until the voice
    /// turn's bubble exists and some assistant text has arrived.
    public static func latest(
        in messages: [HermesMessage],
        forPrompt prompt: String,
        isStreaming: Bool
    ) -> VoiceTurnReply? {
        guard let userIndex = messages.lastIndex(where: { $0.role == "user" }),
              messages[userIndex].content.trimmingCharacters(in: .whitespacesAndNewlines)
                == prompt.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let text = messages[(userIndex + 1)...]
            .filter { $0.role == "assistant" }
            .map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        return text.isEmpty ? nil : VoiceTurnReply(text: text, isStreaming: isStreaming)
    }
}

/// The active chat, as the voice layer sees it. Each app's chat controller
/// conforms (Mac: `ChatViewModel` over `RichChatViewModel`; ScarfGo:
/// `ChatController`).
@MainActor
public protocol VoiceTurnHost: AnyObject {
    /// True while a Hermes turn runs in this chat (voice or typed).
    var isVoiceTurnBusy: Bool { get }
    /// The tool the running turn is executing, if any
    /// (`RichChatViewModel.liveActivityStatus == .runningTool(name)`).
    var activeVoiceToolName: String? { get }

    /// Submit `request` as a normal chat turn: show `request.prompt` as the
    /// user bubble and send `ACPClient.sendPrompt(sessionId:text:
    /// request.prompt, images: [], contextNotes: request.contextNotes)`.
    ///
    /// Return once the prompt is HANDED TO ACP — do not await the turn's
    /// completion (that is `isVoiceTurnBusy` going false; per convention,
    /// completion is `sendPrompt`'s return, which the host must still
    /// synthesize into `.promptComplete` as for typed turns). Throw only if
    /// the turn could not be sent (no session, not connected). The engine
    /// never submits while `isVoiceTurnBusy`; it cancels first.
    func submitVoiceTurn(_ request: VoiceTurnRequest) async throws

    /// Cancel the running turn (`ACPClient.cancel`) and return only once its
    /// `sendPrompt` has RETURNED. Hermes queues a prompt that arrives while
    /// a turn runs as text only and drops the voice note
    /// (`acp_adapter/server.py:696-715` @ v2026.9.14), so a superseding
    /// voice turn must wait for this.
    func cancelActiveVoiceTurn() async

    /// The reply to `requestID` so far, or `nil` before any assistant text
    /// for it exists. See ``VoiceTurnReply/latest(in:forPrompt:isStreaming:)``.
    func voiceTurnReply(for requestID: String) -> VoiceTurnReply?

    /// Recent text turns of this chat, oldest first, to seed a new session.
    func voiceSeedTurns() -> [VoiceLiveText.SeedTurn]
}

// MARK: - Cost and time

/// GPT-Live's price: "$0.05/min of session time on the OpenAI key, separate
/// from the Hermes turn" (`tools/voice_live.py:18-20` @ v2026.9.14). An
/// estimate for the user, not a bill: the vendor's own usage seconds replace
/// the local clock when `session.closed` reports them.
public enum VoiceSessionCost {
    public static let gptLiveUSDPerMinute = 0.05

    public static func approximateUSD(seconds: TimeInterval, perMinute: Double = gptLiveUSDPerMinute) -> Double {
        max(0, seconds) / 60 * perMinute
    }
}

/// Session clock: when billing started, when it stopped, and the vendor's
/// billed seconds if it reported them.
public struct VoiceSessionMeter: Sendable, Equatable {
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?
    public private(set) var billedSeconds: Double?

    public init() {}

    public mutating func start(at date: Date) {
        startedAt = date
        endedAt = nil
        billedSeconds = nil
    }

    public mutating func stop(at date: Date, billedSeconds: Double?) {
        guard startedAt != nil, endedAt == nil else { return }
        endedAt = date
        self.billedSeconds = billedSeconds
    }

    public func elapsed(at now: Date) -> TimeInterval {
        if let billedSeconds { return billedSeconds }
        guard let startedAt else { return 0 }
        return max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    public func approximateCostUSD(at now: Date, perMinute: Double = VoiceSessionCost.gptLiveUSDPerMinute) -> Double {
        VoiceSessionCost.approximateUSD(seconds: elapsed(at: now), perMinute: perMinute)
    }
}

/// "No speech either side for N minutes" — the idle auto-end cost guard.
/// Activity is any transcript fragment, the voice starting or stopping,
/// and the end of a delegation; while Hermes works on a delegation the
/// session is never idle.
public struct VoiceIdleMonitor: Sendable, Equatable {
    /// Default 3 minutes (Alan's decision, t-a4665c6e).
    public static let defaultTimeout: TimeInterval = 180

    public var timeout: TimeInterval
    public private(set) var lastActivity: Date

    public init(timeout: TimeInterval = defaultTimeout, now: Date) {
        self.timeout = timeout
        self.lastActivity = now
    }

    public mutating func noteActivity(at date: Date) {
        if date > lastActivity { lastActivity = date }
    }

    public func isIdle(at now: Date, busy: Bool) -> Bool {
        guard timeout > 0, !busy else { return false }
        return now.timeIntervalSince(lastActivity) >= timeout
    }
}
