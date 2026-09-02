import Testing
import Foundation
@testable import ScarfCore

/// Regression coverage for the v2.24.0 audit-board item "ACPClient
/// half-open start()/double-connect footgun".
///
/// `start()` guarded on `channel == nil`, but that guard ran BEFORE the
/// `await channelFactory(context)` suspension. Actors are reentrant, so
/// a second `start()` arriving while the factory was still spawning
/// `hermes acp` also saw `channel == nil`, spawned a SECOND subprocess,
/// and clobbered `self.channel` / `self._eventStream` — orphaning the
/// first process and leaving its event stream permanently unfinished.
@Suite struct ACPClientStartIdempotenceTests {

    /// A channel whose factory blocks until released, so a start can be
    /// held half-open while a second one is issued.
    actor GatedChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private(set) var sent: [String] = []
        private(set) var closed = false

        var diagnosticID: String? { "gated" }

        init() {
            let (s, c) = AsyncThrowingStream<String, Error>.makeStream()
            incoming = s
            incomingCont = c
            let (es, ec) = AsyncThrowingStream<String, Error>.makeStream()
            stderr = es
            stderrCont = ec
        }

        func send(_ line: String) async throws {
            if closed { throw ACPChannelError.writeEndClosed }
            sent.append(line)
        }

        func close() async {
            guard !closed else { return }
            closed = true
            incomingCont.finish()
            stderrCont.finish()
        }

        func reply(with line: String) { incomingCont.yield(line) }

        func lastSentId() -> Int? {
            guard let last = sent.last,
                  let d = last.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { return nil }
            return obj["id"] as? Int
        }
    }

    /// Counts how many channels the client asked for — the direct
    /// stand-in for "how many `hermes acp` processes did we spawn".
    actor SpawnLedger {
        private(set) var spawned: [GatedChannel] = []
        private var gateOpen = false

        func record(_ channel: GatedChannel) { spawned.append(channel) }
        var count: Int { spawned.count }
        func openGate() { gateOpen = true }
        func waitForGate() async {
            while !gateOpen {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }

    private func waitFor(
        _ condition: @Sendable () async -> Bool,
        timeout: TimeInterval = 3
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("timed out waiting for condition")
    }

    /// THE regression: a second `start()` issued while the first is
    /// still inside the channel factory must not spawn a second
    /// channel. It joins the in-flight start instead.
    @Test func concurrentStartsSpawnOneChannel() async throws {
        let ledger = SpawnLedger()
        let client = ACPClient(context: .local) { _ in
            let ch = GatedChannel()
            await ledger.record(ch)
            // Hold the factory open so the second start() lands while
            // the first is half-open.
            await ledger.waitForGate()
            return ch
        }

        let first = Task { try await client.start() }
        // Let the first start reach the factory suspension.
        try await waitFor { await ledger.count == 1 }
        #expect(await client.state == .starting)

        let second = Task { try await client.start() }
        try await Task.sleep(nanoseconds: 50_000_000)
        // The second call must NOT have entered the factory.
        #expect(await ledger.count == 1)

        await ledger.openGate()
        // Answer `initialize` so both starts can complete.
        try await waitFor {
            guard let ch = await ledger.spawned.first else { return false }
            return await ch.sent.count >= 1
        }
        let ch = await ledger.spawned[0]
        let initId = await ch.lastSentId() ?? 1
        await ch.reply(with: #"{"jsonrpc":"2.0","id":\#(initId),"result":{}}"#)

        try await first.value
        try await second.value

        #expect(await ledger.count == 1)
        #expect(await client.state == .running)
        #expect(await client.isConnected)
        await client.stop()
    }

    /// A plain sequential second `start()` on a running client is a
    /// no-op — no second spawn, no torn-down stream.
    @Test func repeatStartOnRunningClientIsANoOp() async throws {
        let ledger = SpawnLedger()
        await ledger.openGate()
        let client = ACPClient(context: .local) { _ in
            let ch = GatedChannel()
            await ledger.record(ch)
            return ch
        }

        let startTask = Task { try await client.start() }
        try await waitFor {
            guard let ch = await ledger.spawned.first else { return false }
            return await ch.sent.count >= 1
        }
        let ch = await ledger.spawned[0]
        let initId = await ch.lastSentId() ?? 1
        await ch.reply(with: #"{"jsonrpc":"2.0","id":\#(initId),"result":{}}"#)
        try await startTask.value

        let streamBefore = await client.events
        try await client.start()
        #expect(await ledger.count == 1)
        #expect(await client.state == .running)
        // The live event stream survived — a re-entered start used to
        // replace `_eventStream`, stranding the running event loop.
        let streamAfter = await client.events
        #expect(await ch.closed == false)
        _ = streamBefore
        _ = streamAfter
        await client.stop()
    }

    /// A failed start leaves the client reusable: state back to `idle`
    /// and a retry is allowed to spawn.
    @Test func failedStartResetsToIdleAndAllowsRetry() async throws {
        struct Boom: Error {}
        let ledger = SpawnLedger()
        await ledger.openGate()
        let attempts = SpawnLedger()

        let client = ACPClient(context: .local) { _ in
            await attempts.record(GatedChannel())
            if await attempts.count == 1 { throw Boom() }
            let ch = GatedChannel()
            await ledger.record(ch)
            return ch
        }

        await #expect(throws: Boom.self) { try await client.start() }
        #expect(await client.state == .idle)

        let retry = Task { try await client.start() }
        try await waitFor {
            guard let ch = await ledger.spawned.first else { return false }
            return await ch.sent.count >= 1
        }
        let ch = await ledger.spawned[0]
        let initId = await ch.lastSentId() ?? 1
        await ch.reply(with: #"{"jsonrpc":"2.0","id":\#(initId),"result":{}}"#)
        try await retry.value
        #expect(await client.state == .running)
        await client.stop()
        #expect(await client.state == .stopped)
    }

    /// A `stop()` that lands while a start is half-open must not leave
    /// an orphaned channel: the superseded `performStart` closes the
    /// one it spawned instead of publishing it. `stop()` itself must
    /// not block on the in-flight start (its `initialize` carries a
    /// 60s watchdog and stop is on the user's cancel path).
    @Test func stopDuringHalfOpenStartClosesTheOrphanChannel() async throws {
        let ledger = SpawnLedger()
        let client = ACPClient(context: .local) { _ in
            let ch = GatedChannel()
            await ledger.record(ch)
            await ledger.waitForGate()
            return ch
        }

        let startTask = Task { try? await client.start() }
        try await waitFor { await ledger.count == 1 }

        // Must return promptly — not await the gated factory.
        await client.stop()
        #expect(await client.state == .stopped)

        await ledger.openGate()
        _ = await startTask.value

        let ch = await ledger.spawned[0]
        try await waitFor { await ch.closed }
        #expect(await client.isConnected == false)
        #expect(await client.channelCountForTesting == 0)
    }
}

extension ACPClient {
    /// 0 or 1 — exposes whether a channel is currently published, so a
    /// superseded start can be asserted not to have installed one.
    var channelCountForTesting: Int { isHealthy ? 1 : 0 }
}
