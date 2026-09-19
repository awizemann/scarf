import Foundation

/// Codable shape of one server frame off the realtime WebSocket.
///
/// The protocol sends one JSON object per frame whose `type` selects the
/// payload layout, so a single all-optional struct decodes every frame
/// and ``RealtimeWireEvent/domainEvent()`` maps the recognized ones onto
/// ``RealtimeVoiceEvent``. Unknown `type`s decode fine and map to `nil` —
/// the server emits many frames we deliberately ignore
/// (`rate_limits.updated`, `conversation.item.*` for non-audio items, …).
///
/// Event-name aliases: the endpoint has renamed the assistant audio and
/// transcript deltas across API generations. GPT-Live uses the
/// `session.*` names; older Realtime and Hermes gateway shims have used
/// `response.*` names. Both spellings map to the same domain event.
struct RealtimeWireEvent: Decodable, Sendable {
    let type: String
    let eventID: String?
    let delta: String?
    let transcript: String?
    let itemID: String?
    let contentIndex: Int?
    let audioEndMs: Int?
    let session: Session?
    let item: Item?
    let response: Response?
    let error: ErrorPayload?

    enum CodingKeys: String, CodingKey {
        case type
        case eventID = "event_id"
        case delta
        case transcript
        case itemID = "item_id"
        case contentIndex = "content_index"
        case audioEndMs = "audio_end_ms"
        case session
        case item
        case response
        case error
    }

    struct Session: Decodable, Sendable {
        let id: String?
        let model: String?
    }

    struct Item: Decodable, Sendable {
        let id: String?
        let type: String?
        let role: String?
    }

    struct Response: Decodable, Sendable {
        let id: String?
        let status: String?
    }

    struct ErrorPayload: Decodable, Sendable {
        let type: String?
        let message: String?
        let code: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        eventID = try container.decodeIfPresent(String.self, forKey: .eventID)
        delta = try container.decodeIfPresent(String.self, forKey: .delta)
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
        itemID = try container.decodeIfPresent(String.self, forKey: .itemID)
        contentIndex = try container.decodeIfPresent(Int.self, forKey: .contentIndex)
        audioEndMs = try container.decodeIfPresent(Int.self, forKey: .audioEndMs)
        session = try container.decodeIfPresent(Session.self, forKey: .session)
        item = try container.decodeIfPresent(Item.self, forKey: .item)
        response = try container.decodeIfPresent(Response.self, forKey: .response)
        error = try container.decodeIfPresent(ErrorPayload.self, forKey: .error)
    }
}

extension RealtimeWireEvent {
    /// Server event names that mean "assistant audio delta", across the
    /// endpoint's API generations. See the type doc for the alias story.
    static let outputAudioDeltaTypes: Set<String> = [
        "response.audio.delta",
        "response.output_audio.delta",
        "session.output_audio.delta",
    ]

    /// Same alias family for the assistant transcript deltas.
    static let assistantTranscriptDeltaTypes: Set<String> = [
        "response.audio_transcript.delta",
        "response.output_audio_transcript.delta",
        "response.output_transcript.delta",
        "session.output_audio_transcript.delta",
        "session.output_transcript.delta",
    ]

    /// Map a decoded frame onto the domain event the UI consumes.
    /// `nil` means "recognized but not surfaced" — the caller drops it.
    var domainEvent: RealtimeVoiceEvent? {
        switch type {
        case "session.started", "session.created":
            return .sessionCreated(sessionID: session?.id)
        case "session.updated":
            return .sessionUpdated
        case "input_audio_buffer.speech_started":
            return .userSpeechStarted
        case "conversation.item.input_audio_transcription.delta":
            return .userTranscriptDelta(delta ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .userTranscriptCompleted(transcript ?? "")
        case "response.output_item.added":
            // Only assistant message items carry streamed audio; function
            // calls and other item types arrive through the same event
            // and stay silent.
            if item?.type == "message", item?.role == "assistant", let id = item?.id {
                return .outputItemStarted(itemID: id)
            }
            return nil
        case "response.done":
            return .responseCompleted
        case "response.cancelled":
            return .responseCancelled
        case "error":
            let payload = error
            return .errorOccurred(
                message: payload?.message ?? "The voice service reported an error.",
                type: payload?.type
            )
        default:
            break
        }

        if Self.outputAudioDeltaTypes.contains(type) {
            let data = (delta ?? "").data(using: .utf8).flatMap { Data(base64Encoded: $0) } ?? Data()
            return .outputAudioDelta(itemID: itemID ?? "", data: data)
        }
        if Self.assistantTranscriptDeltaTypes.contains(type) {
            return .assistantTranscriptDelta(delta ?? "")
        }
        return nil
    }
}

// MARK: - Client → server frames

/// Codable builders for the frames we send. Encoded (not string-built)
/// so payloads like base64 audio can never produce malformed JSON.
enum RealtimeClientFrame: Encodable, Sendable {
    /// Configure the session (voice, guidance, VAD, transcription
    /// model). The Realtime API takes its model at connect time (URL
    /// query); everything else per-session arrives here.
    case sessionUpdate(SessionUpdate)
    /// Append mic audio. `audio` is base64 of raw LE PCM16 mono @ 24 kHz.
    case appendAudio(String)
    /// Truncate the in-flight assistant audio item (barge-in).
    case truncateItem(itemID: String, contentIndex: Int, audioEndMs: Int)

    struct SessionUpdate: Encodable, Sendable {
        let type = "realtime"
        let instructions: String
        let audio: Audio

        struct Audio: Encodable, Sendable {
            let input: Input
            let output: Output

            struct Input: Encodable, Sendable {
                let format: Format
                let transcription: Transcription
                let turnDetection: TurnDetection

                enum CodingKeys: String, CodingKey {
                    case format
                    case transcription
                    case turnDetection = "turn_detection"
                }
            }

            struct Output: Encodable, Sendable {
                let voice: String
                let format: Format
            }

            struct Format: Encodable, Sendable {
                let type = "audio/pcm"
                let rate = 24_000
            }

            struct Transcription: Encodable, Sendable {
                let model: String
            }
        }

        struct TurnDetection: Encodable, Sendable {
            let type = "server_vad"
            let threshold: Double
            let prefixPaddingMs: Int
            let silenceDurationMs: Int
            let createResponse = true
            let interruptResponse = true

            enum CodingKeys: String, CodingKey {
                case type
                case threshold
                case prefixPaddingMs = "prefix_padding_ms"
                case silenceDurationMs = "silence_duration_ms"
                case createResponse = "create_response"
                case interruptResponse = "interrupt_response"
            }
        }

        enum CodingKeys: String, CodingKey {
            case type
            case instructions
            case audio
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case session
        case audio
        case itemID = "item_id"
        case contentIndex = "content_index"
        case audioEndMs = "audio_end_ms"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessionUpdate(let session):
            try container.encode("session.update", forKey: .type)
            try container.encode(session, forKey: .session)
        case .appendAudio(let base64):
            try container.encode("input_audio_buffer.append", forKey: .type)
            try container.encode(base64, forKey: .audio)
        case .truncateItem(let itemID, let contentIndex, let audioEndMs):
            try container.encode("conversation.item.truncate", forKey: .type)
            try container.encode(itemID, forKey: .itemID)
            try container.encode(contentIndex, forKey: .contentIndex)
            try container.encode(audioEndMs, forKey: .audioEndMs)
        }
    }

    var encodedString: String {
        // Frames are internally produced (no user free-text), so a
        // force-try on a plain JSONEncoder is total. If encoding ever
        // fails the service surfaces notConnected-style errors anyway.
        let encoder = JSONEncoder()
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
