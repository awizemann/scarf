import Foundation
import os

/// `URLSessionWebSocketTask`-backed ``RealtimeSocket``.
///
/// Auth is a header on the request (the ephemeral `ek_` token — the raw
/// provider key never reaches this process). There is no explicit
/// handshake await on URLSession websockets, so `connect` returns once
/// the task resumes; connection-level failures (DNS, TLS, 401) surface
/// through the first `receive()` error, which ends ``incoming`` — the
/// service maps that onto `.closed(.transportFailed)` and the reducer
/// turns a never-connected close into a `failed` phase.
public final class URLSessionRealtimeSocket: RealtimeSocket, @unchecked Sendable {
    private let session: URLSession

    private struct SocketState {
        var task: URLSessionWebSocketTask?
        var continuation: AsyncStream<String>.Continuation?
    }
    /// os_unfair_lock per the package's lock convention — and unlike
    /// `NSLock`, safe to touch from the async control surface.
    private let state: OSAllocatedUnfairLock<SocketState>

    public let incoming: AsyncStream<String>

    public init(session: URLSession = .shared) {
        self.session = session
        var made: AsyncStream<String>.Continuation?
        self.incoming = AsyncStream { made = $0 }
        self.state = OSAllocatedUnfairLock(initialState: SocketState(
            task: nil,
            continuation: made
        ))
    }

    public func connect(url: URL, bearerToken: String) async throws {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let webSocket = session.webSocketTask(with: request)
        let sink = state.withLock { state -> AsyncStream<String>.Continuation? in
            // A socket instance is single-session by construction (the
            // service creates a fresh one per `start()`); a stray second
            // connect still refuses to orphan the first receive loop.
            guard state.task == nil else { return nil }
            state.task = webSocket
            return state.continuation
        }
        guard let sink else {
            webSocket.cancel()
            throw RealtimeVoiceError.alreadyStarted
        }

        webSocket.resume()
        Task { [weak self] in
            await self?.runReceiveLoop(into: sink, on: webSocket)
        }
    }

    private func runReceiveLoop(into sink: AsyncStream<String>.Continuation, on webSocket: URLSessionWebSocketTask) async {
        while true {
            do {
                let message = try await webSocket.receive()
                switch message {
                case .string(let text):
                    sink.yield(text)
                case .data(let data):
                    // The realtime endpoint speaks JSON text frames; a
                    // binary frame is unexpected but harmless to forward
                    // as text — decoding will drop it if it isn't JSON.
                    if let text = String(data: data, encoding: .utf8) {
                        sink.yield(text)
                    }
                @unknown default:
                    continue
                }
            } catch {
                // Cancellation (our own `close`) ends the loop silently;
                // any other error is a transport failure the consumer
                // must see via the stream terminating.
                sink.finish()
                return
            }
        }
    }

    public func send(text: String) async throws {
        let webSocket = state.withLock { $0.task }
        guard let webSocket else { throw RealtimeVoiceError.notConnected }
        try await webSocket.send(.string(text))
    }

    public func close() async {
        let webSocket = state.withLock { state -> URLSessionWebSocketTask? in
            let task = state.task
            state.task = nil
            state.continuation?.finish()
            state.continuation = nil
            return task
        }
        webSocket?.cancel(with: .normalClosure, reason: nil)
    }

    deinit {
        state.withLock { state in
            state.task?.cancel()
            state.continuation?.finish()
        }
    }
}
