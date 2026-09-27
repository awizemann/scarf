import Testing
import Foundation
@testable import ScarfCore

/// R17: channel writes go out in the order the client issued them.
///
/// Each request used to be written from its own detached task, so two
/// prompts sent back to back — the held sends an autostart releases once its
/// `session/load` has drained — could reach Hermes in either order, and a
/// `session/cancel` could overtake the prompt it was cancelling. The gate
/// test `ChatSessionsR16bMacTests.secondSendDuringAutostartWaitsForTheReplayToDrain`
/// caught it as `["second", "first"]` on a loaded machine.
@Suite struct ACPClientWriteOrderR17Tests {

    /// Answers `initialize`, never answers anything else, and holds the
    /// FIRST `session/prompt` write for a while before recording it — so a
    /// later write that was not queued behind it would be recorded first.
    actor SlowFirstPromptChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private var promptWritesStarted = 0
        private(set) var recorded: [String] = []
        private(set) var closed = false
        private(set) var refusedWrites = 0
        private let refusePrompts: Bool
        var diagnosticID: String? { "slow-first-prompt" }

        init(refusePrompts: Bool = false) {
            self.refusePrompts = refusePrompts
            let (s, c) = AsyncThrowingStream<String, Error>.makeStream()
            incoming = s
            incomingCont = c
            let (es, ec) = AsyncThrowingStream<String, Error>.makeStream()
            stderr = es
            stderrCont = ec
        }

        var startedPromptWrites: Int { promptWritesStarted }

        func send(_ line: String) async throws {
            if closed { throw ACPChannelError.writeEndClosed }
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let method = obj["method"] as? String else { return }
            if method == "initialize", let id = obj["id"] as? Int {
                let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": ["protocolVersion": 1]]
                if let d = try? JSONSerialization.data(withJSONObject: reply),
                   let l = String(data: d, encoding: .utf8) { incomingCont.yield(l) }
                return
            }
            if method == "session/prompt" {
                if refusePrompts {
                    refusedWrites += 1
                    throw ACPChannelError.writeEndClosed
                }
                promptWritesStarted += 1
                // The actor is released across this sleep: an unqueued
                // second write would enter `send` and record first.
                if promptWritesStarted == 1 {
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
                let blocks = (obj["params"] as? [String: Any])?["prompt"] as? [[String: Any]] ?? []
                recorded.append(blocks.compactMap { $0["text"] as? String }.joined())
            } else {
                recorded.append(method)
            }
        }

        func close() async {
            guard !closed else { return }
            closed = true
            incomingCont.finish()
            stderrCont.finish()
        }
    }

    private func waitFor(_ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    @Test func promptsAndACancelReachTheChannelInIssueOrder() async throws {
        let ch = SlowFirstPromptChannel()
        let client = ACPClient(context: .local) { _ in ch }
        try await client.start()

        let first = Task { try? await client.sendPrompt(sessionId: "s", text: "first") }
        // The first write is in flight (and sleeping) before the rest are issued.
        #expect(await waitFor { await ch.startedPromptWrites == 1 })
        let second = Task { try? await client.sendPrompt(sessionId: "s", text: "second") }
        // Give the second request time to be issued while the first sleeps.
        try await Task.sleep(nanoseconds: 50_000_000)
        try await client.cancel(sessionId: "s")

        #expect(await waitFor { await ch.recorded.count == 3 })
        #expect(await ch.recorded == ["first", "second", "session/cancel"])

        await client.stop()
        _ = await first.value
        _ = await second.value
    }

    /// A write the channel refuses still fails its own request promptly —
    /// the queued write reports its error back to the request that issued it.
    @Test func aRefusedWriteFailsItsRequest() async throws {
        let ch = SlowFirstPromptChannel(refusePrompts: true)
        let client = ACPClient(context: .local) { _ in ch }
        try await client.start()
        let failed = Task { () -> Bool in
            do { _ = try await client.sendPrompt(sessionId: "s", text: "x"); return false } catch { return true }
        }
        let done = await waitFor { await ch.refusedWrites == 1 }
        #expect(done)
        #expect(await failed.value)
        await client.stop()
    }
}
