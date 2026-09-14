import Testing
import Foundation
@testable import ScarfCore

/// Wire-event decoding for the realtime voice session: server frames
/// (including the assistant-delta alias families) and the client frames
/// we emit. All fixtures are captured shapes — nothing touches a socket.
@Suite struct RealtimeEventDecodingTests {

    private func decode(_ json: String) throws -> RealtimeWireEvent {
        let data = try #require(json.data(using: .utf8))
        return try JSONDecoder().decode(RealtimeWireEvent.self, from: data)
    }

    // MARK: - Server frames

    @Test func sessionStarted() throws {
        let wire = try decode("""
        {"type":"session.started","event_id":"event_1","session":{"id":"sess_A","model":"gpt-live-1"}}
        """)
        #expect(wire.domainEvent == .sessionCreated(sessionID: "sess_A"))
    }

    @Test func serverVadSpeechStarted() throws {
        let wire = try decode("""
        {"type":"input_audio_buffer.speech_started","event_id":"event_2","audio_start_ms":120,"item_id":"user_item"}
        """)
        #expect(wire.domainEvent == .userSpeechStarted)
    }

    @Test func responseCancelled() throws {
        let wire = try decode("""
        {"type":"response.cancelled","event_id":"event_3","response":{"id":"resp_1","status":"cancelled"}}
        """)
        #expect(wire.domainEvent == .responseCancelled)
    }

    @Test func responseDone() throws {
        let wire = try decode("""
        {"type":"response.done","event_id":"event_4","response":{"id":"resp_1","status":"completed"}}
        """)
        #expect(wire.domainEvent == .responseCompleted)
    }

    @Test func serverError() throws {
        let wire = try decode("""
        {"type":"error","event_id":"event_5","error":{"type":"invalid_request_error","code":"unknown","message":"Session already has an active response"}}
        """)
        #expect(wire.domainEvent == .errorOccurred(
            message: "Session already has an active response",
            type: "invalid_request_error"
        ))
    }

    @Test func errorWithoutPayloadFallsBackToGenericMessage() throws {
        let wire = try decode(#"{"type":"error"}"#)
        #expect(wire.domainEvent == .errorOccurred(
            message: "The voice service reported an error.",
            type: nil
        ))
    }

    // MARK: - Assistant audio delta alias family

    @Test func audioDeltaBetaName() throws {
        // The spelling the Hermes `hermes-s2s` reference speaks.
        let pcm = Data([0x01, 0x02, 0xFF, 0xFE])
        let json = """
        {"type":"response.audio.delta","event_id":"e","item_id":"item_A","delta":"\(pcm.base64EncodedString())"}
        """
        let event = try decode(json).domainEvent
        #expect(event == .outputAudioDelta(itemID: "item_A", data: pcm))
    }

    @Test func audioDeltaCurrentSessionName() throws {
        // The spelling GPT-Live uses.
        let pcm = Data([0x10, 0x20])
        let json = """
        {"type":"session.output_audio.delta","event_id":"e","item_id":"item_B","delta":"\(pcm.base64EncodedString())"}
        """
        let event = try decode(json).domainEvent
        #expect(event == .outputAudioDelta(itemID: "item_B", data: pcm))
    }

    @Test func audioDeltaWithInvalidBase64YieldsEmptyAudio() throws {
        let wire = try decode("""
        {"type":"response.audio.delta","item_id":"item_C","delta":"!!!not-base64!!!"}
        """)
        #expect(wire.domainEvent == .outputAudioDelta(itemID: "item_C", data: Data()))
    }

    // MARK: - Transcript events

    @Test func assistantTranscriptDeltaAliases() throws {
        let names = [
            "response.audio_transcript.delta",
            "response.output_audio_transcript.delta",
            "response.output_transcript.delta",
            "session.output_audio_transcript.delta",
            "session.output_transcript.delta",
        ]
        for name in names {
            let wire = try decode(#"{"type":"\#(name)","delta":"Hello"}"#)
            #expect(wire.domainEvent == .assistantTranscriptDelta("Hello"))
        }
    }

    @Test func userTranscriptDeltaAndCompleted() throws {
        let delta = try decode("""
        {"type":"conversation.item.input_audio_transcription.delta","item_id":"item_U","delta":"Hey"}
        """)
        #expect(delta.domainEvent == .userTranscriptDelta("Hey"))

        let completed = try decode("""
        {"type":"conversation.item.input_audio_transcription.completed","item_id":"item_U","transcript":"Hey there"}
        """)
        #expect(completed.domainEvent == .userTranscriptCompleted("Hey there"))
    }

    // MARK: - Output items

    @Test func assistantAudioItemStarted() throws {
        let wire = try decode("""
        {"type":"response.output_item.added","item":{"id":"item_A","type":"message","role":"assistant"}}
        """)
        #expect(wire.domainEvent == .outputItemStarted(itemID: "item_A"))
    }

    @Test func nonAssistantItemsStaySilent() throws {
        // Function-call items arrive on the same event; v1 voice does
        // not surface them, and they must not fake a speaking turn.
        let functionCall = try decode("""
        {"type":"response.output_item.added","item":{"id":"call_1","type":"function_call","role":"assistant"}}
        """)
        #expect(functionCall.domainEvent == nil)

        let userEcho = try decode("""
        {"type":"response.output_item.added","item":{"id":"item_U","type":"message","role":"user"}}
        """)
        #expect(userEcho.domainEvent == nil)
    }

    @Test func unrecognizedFramesAreDropped() throws {
        let rateLimits = try decode(#"{"type":"rate_limits.updated","rate_limits":[]}"#)
        #expect(rateLimits.domainEvent == nil)
    }

    // MARK: - Client frames

    @Test func sessionUpdateFrameCarriesRealtimeConfiguration() throws {
        let frame = RealtimeClientFrame.sessionUpdate(.init(
            instructions: "Be concise.",
            audio: .init(
                input: .init(
                    format: .init(),
                    transcription: .init(model: "gpt-4o-mini-transcribe"),
                    turnDetection: .init(threshold: 0.5, prefixPaddingMs: 300, silenceDurationMs: 500)
                ),
                output: .init(voice: "marin", format: .init())
            )
        )).encodedString

        let frameData = try #require(frame.data(using: .utf8))
        let decoded = try #require(JSONSerialization.jsonObject(with: frameData) as? [String: Any])
        #expect(decoded["type"] as? String == "session.update")

        let session = try #require(decoded["session"] as? [String: Any])
        #expect(session["type"] as? String == "realtime")
        #expect(session["instructions"] as? String == "Be concise.")
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let inputFormat = try #require(input["format"] as? [String: Any])
        #expect(inputFormat["type"] as? String == "audio/pcm")
        #expect(inputFormat["rate"] as? Int == 24_000)
        let transcription = try #require(input["transcription"] as? [String: Any])
        #expect(transcription["model"] as? String == "gpt-4o-mini-transcribe")
        let turnDetection = try #require(input["turn_detection"] as? [String: Any])
        #expect(turnDetection["type"] as? String == "server_vad")
        #expect(turnDetection["threshold"] as? Double == 0.5)
        #expect(turnDetection["create_response"] as? Bool == true)
        #expect(turnDetection["interrupt_response"] as? Bool == true)
        let output = try #require(audio["output"] as? [String: Any])
        #expect(output["voice"] as? String == "marin")
        let outputFormat = try #require(output["format"] as? [String: Any])
        #expect(outputFormat["type"] as? String == "audio/pcm")
        #expect(outputFormat["rate"] as? Int == 24_000)
    }

    @Test func appendAudioFrameIsBase64Only() throws {
        let pcm = Data([0xAB, 0xCD])
        let frame = RealtimeClientFrame.appendAudio(pcm.base64EncodedString()).encodedString
        let frameData = try #require(frame.data(using: .utf8))
        let decoded = try #require(JSONSerialization.jsonObject(with: frameData) as? [String: Any])
        #expect(decoded["type"] as? String == "input_audio_buffer.append")
        #expect(decoded["audio"] as? String == pcm.base64EncodedString())
    }

    @Test func truncateFrameCarriesItemAndPlayhead() throws {
        let frame = RealtimeClientFrame.truncateItem(
            itemID: "item_A",
            contentIndex: 0,
            audioEndMs: 1720
        ).encodedString
        let frameData = try #require(frame.data(using: .utf8))
        let decoded = try #require(JSONSerialization.jsonObject(with: frameData) as? [String: Any])
        #expect(decoded["type"] as? String == "conversation.item.truncate")
        #expect(decoded["item_id"] as? String == "item_A")
        #expect(decoded["content_index"] as? Int == 0)
        #expect(decoded["audio_end_ms"] as? Int == 1720)
    }
}
