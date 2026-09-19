import Foundation

// GPT-Live's `oai-events` data-channel protocol, decoded and encoded in Swift
// so it is unit-testable (the web page is a thin media transport that only
// forwards raw strings). Shapes from the Hermes desktop at tag v2026.9.14:
// `LiveServerEvent` (`apps/desktop/src/lib/voice-live.ts:38-50`), the
// handler (`:373-441`) and the client sends (`:444-507`).

/// A server → client event on the data channel.
public enum VoiceLiveServerEvent: Sendable, Equatable {
    /// `session.started {session:{id}}`.
    case sessionStarted(id: String?)
    /// `session.input_transcript.delta` (user) /
    /// `session.output_transcript.delta` (assistant) `{delta, start_ms, end_ms}`.
    case transcript(VoiceTranscriptFragment)
    /// `session.delegation.created {delegation:{id, type, target}}` — carries
    /// no text; the turn is built from the transcript window.
    case delegationCreated(id: String)
    /// `error {error:{code, message}}` — non-fatal.
    case error(code: String?, message: String)
    /// `session.closed {reason, usage:{seconds}}` — terminal.
    case closed(reason: String, usageSeconds: Double?)
    /// Any other type (acks, future events): ignored, as the desktop does.
    case other(type: String)

    /// The desktop ignores this error code: late appends after our own
    /// close (`voice-live.ts:421-426`).
    public static let ignoredErrorCode = "context_injection_incomplete"

    /// Decode one data-channel message. `nil` for non-JSON or a missing
    /// `type` (the desktop drops those too). Missing fields default the way
    /// the desktop's `??` does.
    public static func decode(_ raw: String) -> VoiceLiveServerEvent? {
        guard let data = raw.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              let type = wire.type else { return nil }
        switch type {
        case "session.started":
            return .sessionStarted(id: wire.session?.id)
        case "session.input_transcript.delta", "session.output_transcript.delta":
            return .transcript(VoiceTranscriptFragment(
                speaker: type == "session.input_transcript.delta" ? .user : .assistant,
                text: wire.delta ?? "",
                startMs: wire.start_ms.map { Int($0) } ?? 0,
                endMs: wire.end_ms.map { Int($0) } ?? 0))
        case "session.delegation.created":
            guard let id = wire.delegation?.id, !id.isEmpty else { return .other(type: type) }
            return .delegationCreated(id: id)
        case "error":
            return .error(code: wire.error?.code, message: wire.error?.message ?? "GPT-Live error")
        case "session.closed":
            return .closed(reason: wire.reason ?? "closed", usageSeconds: wire.usage?.seconds)
        default:
            return .other(type: type)
        }
    }

    private struct Wire: Decodable {
        struct Session: Decodable { let id: String? }
        struct Delegation: Decodable { let id: String? }
        struct ErrorBody: Decodable { let code: String?; let message: String? }
        struct Usage: Decodable { let seconds: Double? }
        let type: String?
        let delta: String?
        let start_ms: Double?
        let end_ms: Double?
        let session: Session?
        let delegation: Delegation?
        let error: ErrorBody?
        let usage: Usage?
        let reason: String?
    }
}

/// A client → server event, serialized by ``VoiceLiveClientEvents``.
public enum VoiceLiveClientEvent: Sendable, Equatable {
    /// `session.commentary.append` — what the voice paraphrases aloud.
    case commentary(delegationID: String?, content: String)
    /// `session.thinking.append` — quiet progress, not a result.
    case thinking(delegationID: String?, content: String)
    /// `session.instructions.append` — a session-wide steer.
    case instructions(content: String)
    case mute
    case unmute
    /// `session.close` — the vendor answers with `session.closed`.
    case close
}

/// Numbers `event_id`s per session and encodes client events exactly as the
/// desktop does (`voice-live.ts:242-246`, `:444-507`).
public struct VoiceLiveClientEvents: Sendable {
    private var counter = 0

    public init() {}

    /// JSON strings to send for `event`, in order. Commentary is split into
    /// vendor-sized chunks (one event each); empty content sends nothing.
    public mutating func encode(_ event: VoiceLiveClientEvent) -> [String] {
        switch event {
        case .commentary(let id, let content):
            return VoiceLiveText.chunkForCommentary(content).map { chunk in
                json(["type": "session.commentary.append", "delegation_id": id.map { $0 as Any } ?? NSNull(),
                      "content": chunk, "event_id": nextID("say")])
            }
        case .thinking(let id, let content):
            let text = String(VoiceLiveText.collapseWhitespace(content).prefix(VoiceLiveText.appendCharLimit))
            guard !text.isEmpty else { return [] }
            return [json(["type": "session.thinking.append", "delegation_id": id.map { $0 as Any } ?? NSNull(),
                          "content": text, "event_id": nextID("think")])]
        case .instructions(let content):
            let text = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(VoiceLiveText.appendCharLimit))
            guard !text.isEmpty else { return [] }
            return [json(["type": "session.instructions.append", "delegation_id": NSNull(),
                          "content": text, "event_id": nextID("instr")])]
        case .mute:
            return [json(["type": "session.input_audio.mute", "event_id": nextID("mute")])]
        case .unmute:
            return [json(["type": "session.input_audio.unmute", "event_id": nextID("unmute")])]
        case .close:
            return [json(["type": "session.close"])]
        }
    }

    private mutating func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)_\(counter)"
    }

    private func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Media bridge

/// What the media layer (the WKWebView page, or a test double) reports.
public enum VoiceMediaEvent: Sendable, Equatable {
    /// The page loaded; `secureContext` must be true for getUserMedia.
    case pageReady(secureContext: Bool)
    /// The local SDP offer, complete (ICE gathered). Never log it.
    case offer(sdp: String)
    /// The `oai-events` data channel opened.
    case channelOpen
    /// A raw data-channel message (decode with ``VoiceLiveServerEvent/decode(_:)``).
    case serverMessage(String)
    /// The remote (assistant) track started / stopped producing audio.
    case assistantSpeaking(Bool)
    /// The microphone input level, 0…1.
    case micLevel(Double)
    /// The media transport ended on its own: `connection_lost`,
    /// `microphone_denied`, `microphone_busy`, `microphone_not_found`,
    /// `microphone_failed`, `web_process_terminated`, …
    case transportClosed(reason: String)

    /// Decode a `WKScriptMessage.body` from the page. Unknown or malformed
    /// messages are `nil` (ignored).
    public static func decode(messageBody body: Any) -> VoiceMediaEvent? {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return nil }
        switch type {
        case "ready":
            return .pageReady(secureContext: dict["secure"] as? Bool ?? false)
        case "offer":
            guard let sdp = dict["sdp"] as? String, !sdp.isEmpty else { return nil }
            return .offer(sdp: sdp)
        case "channelOpen":
            return .channelOpen
        case "event":
            guard let data = dict["data"] as? String else { return nil }
            return .serverMessage(data)
        case "speaking":
            return .assistantSpeaking(dict["value"] as? Bool ?? false)
        case "level":
            guard let value = (dict["value"] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
            return .micLevel(min(1, max(0, value)))
        case "closed":
            return .transportClosed(reason: (dict["reason"] as? String) ?? "closed")
        default:
            return nil
        }
    }
}

/// The media half of a GPT-Live session: microphone, WebRTC and the data
/// channel. `WebViewVoiceMediaBridge` is the production conformer (a hidden
/// WKWebView, shared by both apps); a native WebRTC package could replace it
/// without touching the engine.
@MainActor
public protocol VoiceMediaBridge: AnyObject {
    /// Set by the engine before `startMedia()`.
    var onEvent: (@MainActor @Sendable (VoiceMediaEvent) -> Void)? { get set }
    /// Open the microphone, build the peer connection and data channel, and
    /// produce an offer (reported as ``VoiceMediaEvent/offer(sdp:)``).
    /// Throws if the media layer can't start (no secure context, microphone
    /// denied, WebKit failure).
    func startMedia() async throws
    /// Apply the vendor's SDP answer.
    func applyAnswer(sdp: String) async throws
    /// Send one JSON string on the data channel (dropped if not open).
    func send(_ json: String)
    func setMicrophoneEnabled(_ enabled: Bool)
    /// Stop the microphone, close the peer connection, forget the session.
    /// Idempotent; the bridge can start again afterwards. The microphone is
    /// released at once; an open data channel first gets a short, bounded
    /// flush so a just-sent `session.close` reaches the vendor. `onReleased`
    /// runs (on the main actor, exactly once) when all of it has finished,
    /// or at once if there was nothing to release.
    func teardown(onReleased: (@MainActor @Sendable () -> Void)?)
}

extension VoiceMediaBridge {
    public func teardown() { teardown(onReleased: nil) }
}
