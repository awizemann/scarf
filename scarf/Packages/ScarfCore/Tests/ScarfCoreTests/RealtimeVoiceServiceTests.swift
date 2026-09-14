import Testing
import Foundation
@testable import ScarfCore

/// Behavior of ``OpenAIRealtimeVoiceService`` against a scripted socket:
/// session setup, mic intake, the barge-in truncate path, close-reason
/// mapping, and the single-session reconnect guard. No network.
@Suite struct RealtimeVoiceServiceTests {

    // MARK: - Mocks

    /// Scripted peer: the test fires server frames into `incoming` and
    /// inspects what the service put on the wire.
    actor MockRealtimeSocket: RealtimeSocket {
        nonisolated let incoming: AsyncStream<String>
        private let sink: AsyncStream<String>.Continuation

        private var sentFrames: [String] = []
        private(set) var connectCalls = 0
        private(set) var closeCalls = 0
        private var connected = false
        private(set) var lastBearerToken: String?
        private(set) var lastURL: URL?

        init() {
            var made: AsyncStream<String>.Continuation?
            self.incoming = AsyncStream { made = $0 }
            self.sink = made!
        }

        func connect(url: URL, bearerToken: String) async throws {
            connectCalls += 1
            lastURL = url
            lastBearerToken = bearerToken
            connected = true
        }

        func send(text: String) async throws {
            guard connected else { throw RealtimeVoiceError.notConnected }
            sentFrames.append(text)
        }

        func close() async {
            connected = false
            closeCalls += 1
            sink.finish()
        }

        // Test-side control.
        func fire(_ json: String) { sink.yield(json) }
        func endServerSide() { sink.finish() }

        // Test-side inspection.
        func frames() -> [String] { sentFrames }
        func frames(containing type: String) -> [String] {
            sentFrames.filter { $0.contains("\"type\":\"\(type)\"") }
        }
    }

    actor MockTokenMinter: RealtimeTokenMinter {
        private let result: Result<RealtimeEphemeralToken, Error>
        private(set) var mintCalls = 0

        init(result: Result<RealtimeEphemeralToken, Error> = .success(
            RealtimeEphemeralToken(value: "ek_mock_secret")
        )) {
            self.result = result
        }

        func mintToken(configuration: RealtimeVoiceConfiguration) async throws -> RealtimeEphemeralToken {
            mintCalls += 1
            return try result.get()
        }
    }

    /// Collects domain events off the service stream in the background.
    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [RealtimeVoiceEvent] = []

        func record(_ event: RealtimeVoiceEvent) {
            lock.withLock { items.append(event) }
        }

        var all: [RealtimeVoiceEvent] { lock.withLock { items } }

        func waitFor(
            _ predicate: @escaping (RealtimeVoiceEvent) -> Bool,
            timeoutMS: Int = 2_000
        ) async -> Bool {
            // Bounded poll with early exit — the project's replacement
            // for sleep-and-hope timing tests.
            let deadline = Date().addingTimeInterval(TimeInterval(timeoutMS) / 1000)
            while Date() < deadline {
                if all.contains(where: predicate) { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return all.contains(where: predicate)
        }
    }

    /// Wire a fresh event-pump task for a service (the log's collector).
    private func pumpEvents(_ service: OpenAIRealtimeVoiceService, into log: EventLog) {
        Task {
            for await event in service.events {
                log.record(event)
            }
        }
    }

    private func startedService() async throws -> (OpenAIRealtimeVoiceService, MockRealtimeSocket, MockTokenMinter, EventLog) {
        let socket = MockRealtimeSocket()
        let minter = MockTokenMinter()
        let service = OpenAIRealtimeVoiceService(minter: minter, socket: socket)
        let log = EventLog()
        pumpEvents(service, into: log)
        let startTask = Task {
            try await service.start()
        }
        _ = await waitForFrames(socket, type: "session.update", count: 1)
        await socket.fire(#"{"type":"session.created","session":{"id":"sess_A"}}"#)
        try await startTask.value
        return (service, socket, minter, log)
    }

    // MARK: - Session setup

    @Test func startMintsConnectsAndConfiguresSession() async throws {
        let (service, socket, minter, _) = try await startedService()
        _ = service

        #expect(await minter.mintCalls == 1)
        #expect(await socket.connectCalls == 1)
        #expect(await socket.lastBearerToken == "ek_mock_secret")

        // The model travels in the connect URL and must match the
        // minted session; the wire frames never carry it.
        let url = try #require(await socket.lastURL)
        #expect(url.absoluteString.contains("model=gpt-realtime-2.1"))

        let updates = await socket.frames(containing: "session.update")
        #expect(updates.count == 1)
        let body = try #require(updates.first)
        #expect(body.contains("\"voice\":\"marin\""))
        #expect(body.contains("audio\\/pcm"))
        #expect(body.contains("\"rate\":24000"))
        #expect(body.contains("\"server_vad\""))
        #expect(body.contains("\"transcription\""))
        #expect(!body.contains("\"gpt-realtime-2.1\""))

    }

    /// The server emits `session.created` the moment the socket is up —
    /// before the client's `session.update` goes out and before the
    /// start continuation is armed. The start must not hang on a frame
    /// that already fired, and the update frame must still be sent.
    @Test func sessionCreatedBeforeStartArmingDoesNotHangStart() async throws {
        let socket = MockRealtimeSocket()
        let service = OpenAIRealtimeVoiceService(minter: MockTokenMinter(), socket: socket)
        let startTask = Task {
            try await service.start()
        }
        // Server wins the race: created lands before any client frame.
        await socket.fire(#"{"type":"session.created","session":{"id":"sess_B"}}"#)
        try await withTimeout(seconds: 5) {
            try await startTask.value
        }
        // The configuration reached the server despite the race.
        let updates = await socket.frames(containing: "session.update")
        #expect(updates.count == 1)
    }

    private func withTimeout(seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw RealtimeVoiceError.connectionFailed(reason: "start() hung past the test timeout")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    @Test func tokenMintFailureNeverOpensASocket() async throws {
        let socket = MockRealtimeSocket()
        let minter = MockTokenMinter(result: .failure(
            RealtimeVoiceError.tokenMintFailed(reason: "the server could not resolve an OpenAI API key for audio.")
        ))
        let service = OpenAIRealtimeVoiceService(minter: minter, socket: socket)

        await #expect(throws: RealtimeVoiceError.self) {
            try await service.start()
        }
        #expect(await minter.mintCalls == 1)
        #expect(await socket.connectCalls == 0)
        // And the failure is terminal: the service can't be revived.
        await #expect(throws: RealtimeVoiceError.alreadyStarted) {
            try await service.start()
        }
    }

    // MARK: - Mic intake

    @Test func enqueuedAudioIsAppendedAsBase64InOrder() async throws {
        let (service, socket, _, _) = try await startedService()

        let first = Data(repeating: 0x11, count: 4)
        let second = Data(repeating: 0x22, count: 4)
        service.enqueueAudioChunk(first)
        service.enqueueAudioChunk(second)

        let appended = await waitForFrames(socket, type: "input_audio_buffer.append", count: 2)
        #expect(appended.count == 2)
        #expect(appended[0].contains(first.base64EncodedString()))
        #expect(appended[1].contains(second.base64EncodedString()))
    }

    // MARK: - Barge-in

    @Test func speechStartedDuringPlaybackEmitsEventAndSendsTruncate() async throws {
        let (_, socket, _, log) = try await startedService()

        await socket.fire(#"{"type":"response.output_item.added","item":{"id":"item_A","type":"message","role":"assistant"}}"#)
        // Two 20 ms deltas: 960 bytes of PCM16 @ 24 kHz each.
        let chunk = Data(repeating: 0x00, count: 960)
        for _ in 0..<2 {
            await socket.fire(#"{"type":"session.output_audio.delta","item_id":"item_A","delta":"\#(chunk.base64EncodedString())"}"#)
        }
        #expect(await log.waitFor { $0 == .outputItemStarted(itemID: "item_A") })

        await socket.fire(#"{"type":"input_audio_buffer.speech_started","audio_start_ms":1500}"#)
        #expect(await log.waitFor { $0 == .userSpeechStarted })

        let truncates = await waitForFrames(socket, type: "conversation.item.truncate", count: 1)
        #expect(truncates.count == 1)
        let frame = try #require(truncates.first)
        #expect(frame.contains("\"item_id\":\"item_A\""))
        #expect(frame.contains("\"content_index\":0"))
        // 1920 delivered bytes → 40 ms of PCM16 @ 24 kHz.
        #expect(frame.contains("\"audio_end_ms\":40"))

        // Ordering: the UI's cut-playback cue arrives even though the
        // truncate send follows it.
        let events = log.all
        let speechIndex = try #require(events.firstIndex(of: .userSpeechStarted))
        let itemIndex = try #require(events.firstIndex(of: .outputItemStarted(itemID: "item_A")))
        #expect(itemIndex < speechIndex)
    }

    @Test func speechStartedWithNoInFlightItemSendsNoTruncate() async throws {
        let (_, socket, _, log) = try await startedService()

        await socket.fire(#"{"type":"input_audio_buffer.speech_started"}"#)
        #expect(await log.waitFor { $0 == .userSpeechStarted })

        // The service actor serializes handling, so once a LATER server
        // event surfaces in the log, the speech_started handling —
        // including its no-truncate decision — has fully completed.
        await socket.fire(#"{"type":"session.updated"}"#)
        #expect(await log.waitFor { $0 == .sessionUpdated })

        let truncates = await socket.frames(containing: "conversation.item.truncate")
        #expect(truncates.isEmpty)
    }

    @Test func completedResponseClearsTheInFlightItem() async throws {
        let (service, socket, _, log) = try await startedService()
        _ = service

        await socket.fire(#"{"type":"response.output_item.added","item":{"id":"item_A","type":"message","role":"assistant"}}"#)
        await socket.fire(#"{"type":"response.done","response":{"id":"resp_1","status":"completed"}}"#)
        #expect(await log.waitFor { $0 == .responseCompleted })

        // Barge-in AFTER the response completed: nothing to truncate.
        await socket.fire(#"{"type":"input_audio_buffer.speech_started"}"#)
        #expect(await log.waitFor { $0 == .userSpeechStarted })
        await socket.fire(#"{"type":"session.updated"}"#)
        #expect(await log.waitFor { $0 == .sessionUpdated })

        let truncates = await socket.frames(containing: "conversation.item.truncate")
        #expect(truncates.isEmpty)
    }

    // MARK: - Close reasons + reconnect guard

    @Test func serverCloseSurfacesOnceAndNeverReconnects() async throws {
        let (service, socket, _, log) = try await startedService()

        await socket.endServerSide()
        #expect(await log.waitFor {
            if case .closed(.serverClosed) = $0 { return true }
            return false
        })

        // Exactly one close event — no retry storm.
        let closes = log.all.filter {
            if case .closed = $0 { return true }
            return false
        }
        #expect(closes.count == 1)
        #expect(await socket.connectCalls == 1)

        // Late mic chunks after close are dropped, not sent.
        service.enqueueAudioChunk(Data(repeating: 1, count: 4))
        let appended = await waitForFrames(socket, type: "input_audio_buffer.append", count: 0)
        _ = appended

        // The service is spent: restart means a new instance.
        await #expect(throws: RealtimeVoiceError.alreadyStarted) {
            try await service.start()
        }
        #expect(await socket.connectCalls == 1)
    }

    @Test func clientStopClosesSocketOnceAndEndsTheStream() async throws {
        let (service, socket, _, log) = try await startedService()

        await service.stop()
        #expect(await log.waitFor {
            if case .closed(.clientInitiated) = $0 { return true }
            return false
        })
        #expect(await socket.closeCalls == 1)

        // stop() is idempotent — no duplicate close events.
        await service.stop()
        let clientCloses = log.all.filter {
            if case .closed(.clientInitiated) = $0 { return true }
            return false
        }
        #expect(clientCloses.count == 1)
    }

    // MARK: - Helpers

    /// Poll (bounded, early-exit) until `count` frames of `type` are on
    /// the mock socket, then return them.
    private func waitForFrames(
        _ socket: MockRealtimeSocket,
        type: String,
        count: Int,
        timeoutMS: Int = 2_000
    ) async -> [String] {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMS) / 1000)
        var frames: [String] = []
        while Date() < deadline {
            frames = await socket.frames(containing: type)
            if frames.count >= count { return frames }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return frames
    }
}
