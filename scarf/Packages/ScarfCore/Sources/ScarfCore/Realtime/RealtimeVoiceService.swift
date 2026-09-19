import Foundation

/// A full-duplex realtime voice session, backend-agnostic.
///
/// One instance runs **one** session: `start()` connects, `stop()` ends,
/// and a service that has run once never reconnects by itself — the
/// OpenAI session has no resume handle, so a restart is a fresh instance
/// and always an explicit user action. That single-session contract is
/// the reconnect guard.
///
/// Lifecycle:
/// 1. `start()` mints an ephemeral token via the injected minter (the
///    raw provider key never leaves the Hermes host), connects the
///    socket, sends `session.start`, and waits for `session.started`.
/// 2. Mic audio flows in through ``enqueueAudioChunk(_:externalID:)`` —
///    synchronous, thread-safe, ordered — from any thread, including an
///    audio render callback.
/// 3. Server frames are decoded and surfaced on ``events`` (single
///    consumer).
///
/// Conformance note: implementations are typically actors; the protocol
/// declares the intake as a synchronous `nonisolated` entry so callers
/// on audio threads never await. `AnyObject` because services own a
/// live socket — reference identity is the point, and it lets callers
/// hold them weakly across `@Sendable` audio callbacks.
public protocol RealtimeVoiceService: AnyObject, Sendable {
    /// Domain events for the session's lifetime. Single consumer — a
    /// second read gets an empty stream.
    nonisolated var events: AsyncStream<RealtimeVoiceEvent> { get }

    /// Mint the token, connect, configure the session, begin pumping.
    /// Throws `RealtimeVoiceError.tokenMintFailed` before any socket
    /// exists if the Hermes host can't mint.
    nonisolated func start() async throws

    /// Close the transport and finish the event stream. Idempotent.
    /// Never reconnects.
    nonisolated func stop() async

    /// Queue mic audio (raw LE PCM16 mono @ 24 kHz) for sending as
    /// `session.input_audio.append`. Safe from any thread; ordering is
    /// preserved; drops quietly when the session isn't running (the
    /// alternative — buffering mic audio against a dead socket — only
    /// delays the user's "it stopped" signal).
    nonisolated func enqueueAudioChunk(_ pcm16: Data)
}

/// The raw text-socket transport under a realtime service.
///
/// Exists so tests can drive the event loop with a scripted peer and so
/// pass 2's relay backend can reuse the service logic wholesale.
public protocol RealtimeSocket: Sendable {
    /// Open the socket. `bearerToken` is the ephemeral `ek_…` secret;
    /// implementations must not log it.
    nonisolated func connect(url: URL, bearerToken: String) async throws

    /// Server frames, JSON text, single consumer. Finishes when the
    /// socket closes; throws into the stream on transport failure.
    nonisolated var incoming: AsyncStream<String> { get }

    nonisolated func send(text: String) async throws
    nonisolated func close() async
}
