import Testing
import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
@testable import ScarfCore

/// #146 / t-238d2ab3 / t-e875803c — how a chat resumes a past session.
///
/// Hermes restores only `source == "acp"` rows (acp_adapter/session.py:428 @
/// v0.21.5); everything else answers `session/load` with `{}`. Scarf must
/// not ask for a load it knows will fail, must fall back to a new session
/// ONLY on that not-restorable answer, and must say so in the transcript.
///
/// Serialized: the analytics recorder is process-wide.
@Suite("Session resume fallback (#146)", .serialized)
struct SessionResumeFallbackTests {

    private final class Capture: ScarfAnalyticsRecording, @unchecked Sendable {
        private let lock = NSLock()
        private var _kinds: [String] = []
        /// `kind`s of the `session_resume_fallback` events THIS suite's
        /// code paths emit (other suites emit other kinds of the same name).
        var resolveKinds: [String] {
            lock.lock(); defer { lock.unlock() }
            return _kinds.filter { $0 == "non_acp_source" || $0 == "new_session_fallback" }
        }
        func record(_ name: String, _ props: [String: String]) {
            guard name == "session_resume_fallback", let kind = props["kind"] else { return }
            lock.lock(); defer { lock.unlock() }
            _kinds.append(kind)
        }
    }

    /// Counts calls to the closures `resolve` is handed.
    private actor Calls {
        var loads: [String] = []
        var news = 0
        func load(_ id: String) { loads.append(id) }
        func new() { news += 1 }
    }

    // MARK: - Source gate

    @Test("only a known, non-acp source skips the load")
    func unloadableSource() {
        #expect(SessionResume.unloadableSource("acp") == nil)
        #expect(SessionResume.unloadableSource(nil) == nil)
        #expect(SessionResume.unloadableSource("") == nil)
        #expect(SessionResume.unloadableSource("  ") == nil)
        #expect(SessionResume.unloadableSource("webui") == "webui")
        #expect(SessionResume.unloadableSource("cli") == "cli")
        #expect(SessionResume.unloadableSource("cron") == "cron")
        // Hermes compares exactly (`row.get("source") != "acp"`), so do we.
        #expect(SessionResume.unloadableSource("ACP") == "ACP")
    }

    @Test("only sessionNotRestorable counts as not-restorable")
    func notRestorableClassification() {
        #expect(SessionResume.isNotRestorable(ACPClientError.sessionNotRestorable(sessionId: "x")))
        #expect(!SessionResume.isNotRestorable(ACPClientError.requestTimeout(method: "session/load")))
        #expect(!SessionResume.isNotRestorable(ACPClientError.rpcError(code: -32602, message: "Invalid params")))
        #expect(!SessionResume.isNotRestorable(ACPClientError.processTerminated(exitCode: 1, stderrTail: "")))
        #expect(!SessionResume.isNotRestorable(ACPClientError.invalidResponse("session is not restorable")))
        #expect(!SessionResume.isNotRestorable(CancellationError()))
    }

    // MARK: - resolve

    @Test("a non-ACP session never asks Hermes to load it")
    func nonACPSkipsLoad() async throws {
        let capture = Capture()
        ScarfAnalytics.install(capture)
        defer { ScarfAnalytics.install(nil) }
        let calls = Calls()

        let outcome = try await SessionResume.resolve(
            sessionId: "webui-1", source: "webui",
            load: { id in await calls.load(id); return (id, nil) },
            newSession: { await calls.new(); return "acp-new" }
        )

        #expect(outcome == .continuedAsNew(sessionId: "acp-new", reason: .nonACPSource("webui")))
        #expect(await calls.loads.isEmpty)
        #expect(await calls.news == 1)
        #expect(capture.resolveKinds == ["non_acp_source"])
    }

    @Test("an ACP session that loads is reopened, with its head")
    func acpLoads() async throws {
        let capture = Capture()
        ScarfAnalytics.install(capture)
        defer { ScarfAnalytics.install(nil) }
        let calls = Calls()

        let outcome = try await SessionResume.resolve(
            sessionId: "s1", source: "acp",
            load: { id in await calls.load(id); return (id, "s1-head") },
            newSession: { await calls.new(); return "never" }
        )

        #expect(outcome == .loaded(sessionId: "s1", head: "s1-head"))
        #expect(outcome.fallbackReason == nil)
        #expect(outcome.loadedHead == "s1-head")
        #expect(await calls.loads == ["s1"])
        #expect(await calls.news == 0)
        #expect(capture.resolveKinds.isEmpty)
    }

    @Test("not-restorable falls back to a new session", arguments: ["acp", nil] as [String?])
    func notRestorableFallsBack(source: String?) async throws {
        let capture = Capture()
        ScarfAnalytics.install(capture)
        defer { ScarfAnalytics.install(nil) }
        let calls = Calls()

        let outcome = try await SessionResume.resolve(
            sessionId: "gone", source: source,
            load: { id in await calls.load(id); throw ACPClientError.sessionNotRestorable(sessionId: id) },
            newSession: { await calls.new(); return "acp-new" }
        )

        #expect(outcome == .continuedAsNew(sessionId: "acp-new", reason: .notRestorable))
        #expect(outcome.loadedHead == nil)
        #expect(await calls.loads == ["gone"])
        #expect(await calls.news == 1)
        #expect(capture.resolveKinds == ["new_session_fallback"])
    }

    @Test("any other load error surfaces instead of a silent new session",
          arguments: [
            ACPClientError.requestTimeout(method: "session/load"),
            ACPClientError.rpcError(code: -32602, message: "Invalid params"),
            ACPClientError.processTerminated(exitCode: nil, stderrTail: "ssh: connection reset"),
            ACPClientError.notConnected,
          ])
    func otherErrorsRethrow(error: ACPClientError) async {
        let capture = Capture()
        ScarfAnalytics.install(capture)
        defer { ScarfAnalytics.install(nil) }
        let calls = Calls()

        await #expect(throws: ACPClientError.self) {
            _ = try await SessionResume.resolve(
                sessionId: "s1", source: "acp",
                load: { id in await calls.load(id); throw error },
                newSession: { await calls.new(); return "never" }
            )
        }
        #expect(await calls.news == 0)
        #expect(capture.resolveKinds.isEmpty)
    }

    @Test("a failing session/new in the fallback surfaces too")
    func fallbackNewSessionErrorRethrows() async {
        await #expect(throws: ACPClientError.self) {
            _ = try await SessionResume.resolve(
                sessionId: "w", source: "webui",
                load: { id in (id, nil) },
                newSession: { throw ACPClientError.requestTimeout(method: "session/new") }
            )
        }
    }

    // MARK: - Against the real ACPClient wire

    @MainActor
    private func startedClient() async throws -> (ACPClient, M1ACPTests.MockACPChannel) {
        let mock = M1ACPTests.MockACPChannel()
        let client = ACPClient(context: .local) { _ in mock }
        let startTask = Task { try await client.start() }
        try await waitFor { await mock.sent.count >= 1 }
        let initId = await mock.lastSentRequestId() ?? 1
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(initId),"result":{}}"#)
        try await startTask.value
        return (client, mock)
    }

    private func waitFor(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<6000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("condition never became true")
    }

    @Test("Hermes's {} load answer drives the fallback through the real client") @MainActor
    func wireNotRestorableFallsBack() async throws {
        let (client, mock) = try await startedClient()
        let resolveTask = Task { @MainActor in
            try await SessionResume.resolve(
                sessionId: "old-acp", source: "acp",
                load: { id in
                    let loaded = try await client.loadSessionWithProvenance(cwd: "/tmp", sessionId: id)
                    return (loaded.sessionId, loaded.provenance?.currentHermesSessionId)
                },
                newSession: { try await client.newSession(cwd: "/tmp") }
            )
        }
        try await waitFor { await mock.sent.count >= 2 }
        let loadId = await mock.lastSentRequestId() ?? 2
        // The frame Hermes emits for a not-restorable session.
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(loadId),"result":{}}"#)
        try await waitFor { await mock.sent.count >= 3 }
        let newId = await mock.lastSentRequestId() ?? 3
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(newId),"result":{"sessionId":"fresh-1"}}"#)

        let outcome = try await resolveTask.value
        #expect(outcome == .continuedAsNew(sessionId: "fresh-1", reason: .notRestorable))
        await client.stop()
    }

    @Test("a JSON-RPC error from session/load is not a fallback") @MainActor
    func wireRPCErrorSurfaces() async throws {
        let (client, mock) = try await startedClient()
        let resolveTask = Task { @MainActor in
            try await SessionResume.resolve(
                sessionId: "old-acp", source: "acp",
                load: { id in
                    let loaded = try await client.loadSessionWithProvenance(cwd: "/tmp", sessionId: id)
                    return (loaded.sessionId, nil)
                },
                newSession: { try await client.newSession(cwd: "/tmp") }
            )
        }
        try await waitFor { await mock.sent.count >= 2 }
        let loadId = await mock.lastSentRequestId() ?? 2
        await mock.reply(with: #"{"jsonrpc":"2.0","id":\#(loadId),"error":{"code":-32603,"message":"Internal error"}}"#)

        do {
            _ = try await resolveTask.value
            Issue.record("expected the load error to surface")
        } catch let error as ACPClientError {
            guard case .rpcError(let code, _, _) = error else {
                Issue.record("expected .rpcError, got \(error)"); return
            }
            #expect(code == -32603)
        }
        // No session/new went out.
        #expect(await mock.sent.count == 2)
        await client.stop()
    }

    // MARK: - Notice copy

    @Test("the non-ACP notice names the source and never mentions Kanban")
    func nonACPNotice() {
        let text = SessionResume.notice(for: .nonACPSource("webui"), mentionsKanban: true)
        #expect(text.contains("webui"))
        #expect(text.contains("new session"))
        #expect(text.contains("without its earlier context"))
        // A non-ACP session never stamped Kanban tasks (`--session` is the
        // originating ACP session), so there is nothing to warn about.
        #expect(!text.contains("Kanban"))
    }

    @Test("the not-restorable notice adds Kanban only where the badge shows")
    func notRestorableNotice() {
        let plain = SessionResume.notice(for: .notRestorable)
        #expect(plain.contains("without its earlier context"))
        #expect(!plain.contains("Kanban"))
        let mac = SessionResume.notice(for: .notRestorable, mentionsKanban: true)
        #expect(mac.hasPrefix(plain))
        #expect(mac.contains("Kanban board"))
    }

    // MARK: - Transcript notice state

    private static func row(_ id: Int, role: String = "user") -> HermesMessage {
        HermesMessage(
            id: id, sessionId: "s", role: role, content: "m\(id)", toolCallId: nil, toolCalls: [],
            toolName: nil, timestamp: nil, tokenCount: nil, finishReason: nil, reasoning: nil
        )
    }

    @Test("the notice anchors after the last history row and survives setSessionId") @MainActor
    func noticeAnchorsAndPersists() {
        let vm = RichChatViewModel(context: .local)
        vm.messages = [Self.row(3), Self.row(4, role: "assistant"), Self.row(-1)]
        vm.showResumeContinuityNotice("continued")

        let notice = vm.resumeContinuityNotice
        #expect(notice != nil)
        #expect(notice?.text == "continued")
        // The local echo (negative id) is the new session's, not history.
        #expect(notice?.afterMessageId == 4)
        #expect(notice?.anchorIndex(in: vm.messages) == 1)

        // The fallback itself calls setSessionId with the NEW id.
        vm.setSessionId("acp-new")
        #expect(vm.resumeContinuityNotice == notice)

        // Moving the chat to another session clears it.
        vm.reset()
        #expect(vm.resumeContinuityNotice == nil)
    }

    @Test("empty history anchors nothing, so views render the notice first") @MainActor
    func noticeWithoutHistory() {
        let vm = RichChatViewModel(context: .local)
        vm.messages = [Self.row(-1)]
        vm.showResumeContinuityNotice("continued")
        #expect(vm.resumeContinuityNotice?.afterMessageId == nil)
        #expect(vm.resumeContinuityNotice?.anchorIndex(in: vm.messages) == nil)
        #expect(vm.resumeContinuityNotice?.anchorGroupIndex(in: []) == nil)
    }

    @Test("new-session rows after the anchor never move it")
    func anchorIgnoresLaterRows() {
        let notice = RichChatViewModel.ResumeContinuityNotice(text: "t", afterMessageId: 10)
        // Reconcile turned the new session's echo into DB row 11, and
        // Load earlier prepended rows 1-2.
        let messages = [Self.row(1), Self.row(2), Self.row(9), Self.row(10, role: "tool"), Self.row(11), Self.row(-5)]
        #expect(notice.anchorIndex(in: messages) == 3)

        // The Mac renders turns; the anchor may be a tool row, which lives
        // in `toolResults`, not `allMessages`.
        let history = MessageGroup(id: 8, userMessage: Self.row(8),
                                   assistantMessages: [Self.row(9, role: "assistant")],
                                   toolResults: ["call": Self.row(10, role: "tool")])
        let fresh = MessageGroup(id: 11, userMessage: Self.row(11), assistantMessages: [], toolResults: [:])
        let earlier = MessageGroup(id: 1, userMessage: Self.row(1), assistantMessages: [Self.row(2, role: "assistant")], toolResults: [:])
        #expect(notice.anchorGroupIndex(in: [earlier, history, fresh]) == 1)
        // Anchor's turn outside the render window → nil (render first).
        #expect(notice.anchorGroupIndex(in: [fresh]) == nil)
    }

    // MARK: - Source lookup (read-only state.db)

    #if canImport(SQLite3)
    @Test("fetchSource reads sessions.source; unknown ids and missing DBs are nil")
    func fetchSourceFromStateDB() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: """
            INSERT INTO sessions (id, source, started_at) VALUES ('web-1', 'webui', 1.0), ('acp-1', 'acp', 2.0);
            """)
        defer { try? FileManager.default.removeItem(at: home) }
        let ctx = ServerContext.local(home: home)

        #expect(await SessionResume.fetchSource(context: ctx, sessionId: "web-1") == "webui")
        #expect(await SessionResume.fetchSource(context: ctx, sessionId: "acp-1") == "acp")
        #expect(await SessionResume.fetchSource(context: ctx, sessionId: "nope") == nil)

        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-146-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(await SessionResume.fetchSource(context: .local(home: empty), sessionId: "web-1") == nil)
    }
    #endif
}
