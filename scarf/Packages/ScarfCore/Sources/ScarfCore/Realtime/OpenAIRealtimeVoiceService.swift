import Foundation
import os

/// ``RealtimeVoiceService`` over the OpenAI Realtime WebSocket API.
///
/// Wire shape (endpoint model probe, 2026-09-15): connect to
/// `wss://api.openai.com/v1/realtime?model=<model>` authenticated with
/// an ephemeral `ek_…` client secret minted server-side at
/// `/v1/realtime/client_secrets` — the token is bound to the minted
/// model, so the URL query and the mint body must agree. The server
/// emits `session.created` on connect; `session.update` carries voice,
/// guidance, VAD, and transcription config. Audio is base64 raw LE
/// PCM16 mono @ 24 kHz in both directions; server VAD owns turn
/// boundaries.
///
/// NOT for the gpt-live family: `gpt-live-1` is served only by
/// `/v1/live/sessions`, which rejects ephemeral tokens (HTTP 401,
/// verified 2026-09-15) — that model needs the pass-2 server-relay
/// backend behind the same ``RealtimeVoiceService`` protocol.
///
/// Barge-in lives HERE, not in the view model: on
/// `input_audio_buffer.speech_started` the service emits
/// `.userSpeechStarted` (the client's cue to cut local playback) and
/// immediately sends `conversation.item.truncate` for the in-flight
/// assistant audio item, using its own count of delivered audio
/// milliseconds as `audio_end_ms`. Doing both inside the event loop
/// keeps the truncate on the wire within one socket hop of the server's
/// own detection — no MainActor round-trip in the critical path.
///
/// Single session, no reconnect: when the socket dies (most commonly
/// the ~30-minute cap) the service surfaces `.closed` and stays down.
/// Restarting is always a fresh instance driven by the user.
public actor OpenAIRealtimeVoiceService: RealtimeVoiceService {
    public nonisolated let events: AsyncStream<RealtimeVoiceEvent>
    private let eventSink: AsyncStream<RealtimeVoiceEvent>.Continuation

    /// Mic intake. Bounded so audio queued before the socket is live
    /// (or after it died) can't accumulate without bound — the newest
    /// ~1.5 s survive, older chunks drop.
    private nonisolated let audioInbox: AsyncStream<Data>.Continuation
    private let audioSource: AsyncStream<Data>

    private let configuration: RealtimeVoiceConfiguration
    private let minter: any RealtimeTokenMinter
    private let socket: any RealtimeSocket

    private enum Phase {
        case idle
        case starting
        case running
        case finished
    }
    private var phase: Phase = .idle
    private var startContinuation: CheckedContinuation<Void, Error>?
    /// The server emits `session.created` on connect, possibly before
    /// the start continuation is armed. Recorded so arming can resume
    /// immediately instead of waiting for a frame that already fired.
    private var sawSessionCreated = false

    private var receiveTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?

    /// The assistant audio item currently streaming (set from
    /// `response.output_item.added` or lazily by the first audio delta
    /// that names an item), plus how many milliseconds of its audio we
    /// have delivered to the client. Reset when the item completes or
    /// is truncated.
    private var inFlightItemID: String?
    private var inFlightDeliveredMs = 0

    private static let logger = Logger(
        subsystem: "com.scarf.ScarfCore",
        category: "RealtimeVoice"
    )

    public init(
        configuration: RealtimeVoiceConfiguration = RealtimeVoiceConfiguration(),
        minter: any RealtimeTokenMinter,
        socket: any RealtimeSocket
    ) {
        self.configuration = configuration
        self.minter = minter
        self.socket = socket

        var eventContinuation: AsyncStream<RealtimeVoiceEvent>.Continuation?
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { eventContinuation = $0 }
        self.eventSink = eventContinuation!

        var audioContinuation: AsyncStream<Data>.Continuation?
        self.audioSource = AsyncStream(Data.self, bufferingPolicy: .bufferingNewest(16)) { audioContinuation = $0 }
        self.audioInbox = audioContinuation!
    }

    // MARK: - RealtimeVoiceService

    public nonisolated func enqueueAudioChunk(_ pcm16: Data) {
        audioInbox.yield(pcm16)
    }

    public func start() async throws {
        guard phase == .idle else { throw RealtimeVoiceError.alreadyStarted }

        let token: RealtimeEphemeralToken
        do {
            token = try await minter.mintToken(configuration: configuration)
        } catch {
            phase = .finished
            throw error
        }

        do {
            try await socket.connect(url: configuration.websocketURL, bearerToken: token.value)
        } catch {
            phase = .finished
            await socket.close()
            throw RealtimeVoiceError.connectionFailed(reason: error.localizedDescription)
        }

        phase = .starting
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }

        do {
            try await sendStartAndWaitForSessionStarted()
        } catch {
            phase = .finished
            await socket.close()
            throw RealtimeVoiceError.connectionFailed(reason: error.localizedDescription)
        }

        phase = .running
        Self.logger.info("Realtime session started (model \(self.configuration.model, privacy: .public))")

        let source = audioSource
        drainTask = Task { [weak self] in
            await self?.drainAudio(from: source)
        }
    }

    public func stop() async {
        guard phase == .running || phase == .starting else { return }
        phase = .finished
        startContinuation?.resume(throwing: RealtimeVoiceError.connectionFailed(reason: "The voice session was stopped before it started."))
        startContinuation = nil
        receiveTask?.cancel()
        drainTask?.cancel()
        audioInbox.finish()
        await socket.close()
        Self.logger.info("Realtime session stopped (client)")
        eventSink.yield(.closed(reason: .clientInitiated))
        eventSink.finish()
    }

    // MARK: - Event loop

    private func runReceiveLoop() async {
        for await text in socket.incoming {
            guard let data = text.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(RealtimeWireEvent.self, from: data)
            else {
                Self.logger.warning("Dropped non-JSON realtime frame")
                continue
            }
            await handle(wire)
        }

        // The incoming stream only ends when the socket is gone. If we
        // were still running, the server dropped us — the 30-minute
        // session cap being the common case. No reconnect: surface it.
        guard phase == .running || phase == .starting else { return }
        phase = .finished
        audioInbox.finish()
        Self.logger.info("Realtime socket closed by server")
        startContinuation?.resume(throwing: RealtimeVoiceError.connectionFailed(reason: "The voice session closed before it started."))
        startContinuation = nil
        eventSink.yield(.closed(reason: .serverClosed(
            detail: "The voice session ended (the server closed the connection, likely the 30-minute session cap)."
        )))
        eventSink.finish()
    }

    private func drainAudio(from source: AsyncStream<Data>) async {
        for await chunk in source {
            guard phase == .running else { return }
            guard let frame = base64Frame(for: chunk) else { continue }
            // A send failure while still marked running means the socket
            // is dying; the receive loop owns the terminal event.
            try? await socket.send(text: frame)
        }
    }

    private func base64Frame(for chunk: Data) -> String? {
        guard !chunk.isEmpty else { return nil }
        return RealtimeClientFrame.appendAudio(chunk.base64EncodedString()).encodedString
    }

    private func handle(_ wire: RealtimeWireEvent) async {
        guard let event = wire.domainEvent else { return }

        switch event {
        case .sessionCreated:
            sawSessionCreated = true
            startContinuation?.resume(returning: ())
            startContinuation = nil
            eventSink.yield(event)

        case .outputItemStarted(let itemID):
            inFlightItemID = itemID
            inFlightDeliveredMs = 0
            eventSink.yield(event)

        case .outputAudioDelta(let itemID, let data):
            trackInFlightAudio(itemID: itemID, bytes: data.count)
            eventSink.yield(event)

        case .userSpeechStarted:
            // Barge-in: the client cuts playback off this event; the
            // truncate follow-up must not wait on the UI to be sent.
            eventSink.yield(event)
            await truncateInFlightItem()

        case .responseCompleted, .responseCancelled:
            inFlightItemID = nil
            inFlightDeliveredMs = 0
            eventSink.yield(event)

        default:
            eventSink.yield(event)
        }
    }

    private func sendStartAndWaitForSessionStarted() async throws {
        let socket = self.socket
        let frame = RealtimeClientFrame.sessionUpdate(Self.sessionUpdateBody(configuration)).encodedString
        // Send first: the configuration must reach the server even when
        // `session.created` has already landed (see below). A send
        // failure fails start() directly — the socket is dying.
        try await socket.send(text: frame)
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            // The server emits `session.created` the moment the socket
            // is up — possibly BEFORE this continuation is armed. The
            // handler records that in `sawSessionCreated`; resume now
            // if it already fired.
            if sawSessionCreated {
                startContinuation = nil
                continuation.resume()
            }
        }
    }

    private func failPendingStart(_ error: Error) {
        startContinuation?.resume(throwing: error)
        startContinuation = nil
    }

    /// PCM16 mono @ 24 kHz → milliseconds: two bytes per sample, 24 000
    /// samples per second.
    private static func deliveredMs(forBytes bytes: Int) -> Int {
        bytes * 1000 / 48_000
    }

    private func trackInFlightAudio(itemID: String, bytes: Int) {
        if let current = inFlightItemID {
            if !itemID.isEmpty, itemID != current {
                // A delta naming a different item without an
                // `output_item.added` we honored — follow the server.
                inFlightItemID = itemID
                inFlightDeliveredMs = 0
            }
        } else if !itemID.isEmpty {
            inFlightItemID = itemID
            inFlightDeliveredMs = 0
        }
        inFlightDeliveredMs += Self.deliveredMs(forBytes: bytes)
    }

    private func truncateInFlightItem() async {
        guard let itemID = inFlightItemID else { return }
        let audioEndMs = inFlightDeliveredMs
        inFlightItemID = nil
        inFlightDeliveredMs = 0
        let frame = RealtimeClientFrame.truncateItem(
            itemID: itemID,
            contentIndex: 0,
            audioEndMs: audioEndMs
        ).encodedString
        // Best effort by design: if the response already finished
        // server-side the truncate is a harmless no-op error frame.
        try? await socket.send(text: frame)
    }

    private static func sessionUpdateBody(_ configuration: RealtimeVoiceConfiguration) -> RealtimeClientFrame.SessionUpdate {
        RealtimeClientFrame.SessionUpdate(
            instructions: configuration.instructions,
            audio: .init(
                input: .init(
                    format: .init(),
                    transcription: .init(model: "gpt-4o-mini-transcribe"),
                    turnDetection: .init(
                        threshold: configuration.vadThreshold,
                        prefixPaddingMs: configuration.vadPrefixPaddingMs,
                        silenceDurationMs: configuration.vadSilenceDurationMs
                    )
                ),
                output: .init(
                    voice: configuration.voice,
                    format: .init()
                )
            )
        )
    }
}
