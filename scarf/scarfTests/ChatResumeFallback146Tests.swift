import Testing
import Foundation
import SQLite3
@testable import scarf
import ScarfCore

/// #146 on the Mac: resuming a session Hermes can't reopen continues as a
/// new session and SAYS so in the transcript; a real load failure fails the
/// start instead of silently minting a new session (t-e875803c).
///
/// Drives the real `ChatViewModel` start paths against the scripted ACP
/// channel and a scratch Hermes home with a real `state.db`.
struct ChatResumeFallback146Tests {

    typealias Channel = ChatViewModelStartLifecycleTests.ScriptedACPChannel

    /// A home that passes the model preflight and holds `rows`
    /// (`id`, `source`) in `sessions`, each with one user message.
    private static func home(sessions rows: [(String, String)]) throws -> TempHermesHome {
        let home = try ChatViewModelStartLifecycleTests.configuredHome()
        var sql = HermesV0215R18bMacTests.schemaSQL
            .components(separatedBy: "INSERT INTO").first ?? ""
        for (index, row) in rows.enumerated() {
            sql += "INSERT INTO sessions (id, source, title, started_at, message_count) VALUES ('\(row.0)', '\(row.1)', 't', \(index + 1).0, 1);"
            sql += "INSERT INTO messages (id, session_id, role, content, timestamp) VALUES (\(index + 1), '\(row.0)', 'user', 'history \(row.0)', \(index + 1).5);"
        }
        try HermesV0215R18bMacTests.exec(sql, dbAt: home.url)
        return home
    }

    @Test @MainActor func nonACPSessionIsNeverLoadedAndSaysSo() async throws {
        let home = try Self.home(sessions: [("web-1", "webui")])
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = Channel(behavior: .happy(sessionId: "acp-new"))
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in ch } }

        vm.resumeSession("web-1")

        let ready = await ChatViewModelStartLifecycleTests.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready
        }
        #expect(ready)
        let methods = await ch.sentMethods
        #expect(!methods.contains("session/load"), "asked Hermes to load a webui session: \(methods)")
        #expect(methods.contains("session/new"))

        let rich = vm.richChatViewModel
        #expect(rich.sessionId == "acp-new")
        // The old transcript stays visible…
        #expect(rich.messages.contains { $0.content == "history web-1" })
        // …with the notice after it, naming where the session came from.
        let notice = try #require(rich.resumeContinuityNotice)
        #expect(notice.text.contains("webui"))
        #expect(notice.text.contains("without its earlier context"))
        #expect(notice.afterMessageId == 1)
    }

    @Test @MainActor func notRestorableACPSessionFallsBackAndSaysSo() async throws {
        let home = try Self.home(sessions: [("acp-old", "acp")])
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = Channel(behavior: .loadNotRestorable(sessionId: "acp-new"))
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in ch } }

        vm.resumeSession("acp-old")

        let ready = await ChatViewModelStartLifecycleTests.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready
        }
        #expect(ready)
        let methods = await ch.sentMethods
        #expect(methods.contains("session/load"))
        #expect(methods.contains("session/new"))
        #expect(!methods.contains("session/resume"))
        let notice = try #require(vm.richChatViewModel.resumeContinuityNotice)
        #expect(notice.text.contains("couldn’t reopen"))
        #expect(vm.richChatViewModel.sessionId == "acp-new")
    }

    @Test @MainActor func aRealLoadErrorFailsTheStartInsteadOfANewSession() async throws {
        let home = try Self.home(sessions: [("acp-old", "acp")])
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = Channel(behavior: .loadRPCError(sessionId: "acp-new"))
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in ch } }

        vm.resumeSession("acp-old")

        let failed = await ChatViewModelStartLifecycleTests.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.failed
        }
        #expect(failed)
        let methods = await ch.sentMethods
        #expect(methods.contains("session/load"))
        #expect(!methods.contains("session/new"), "a JSON-RPC load error minted a new session: \(methods)")
        #expect(vm.richChatViewModel.resumeContinuityNotice == nil)
        #expect(vm.richChatViewModel.sessionId != "acp-new")
        let stopped = await ChatViewModelStartLifecycleTests.waitUntil { await ch.closed }
        #expect(stopped, "the failed resume leaked its client")
        // Stopping its own client must not read as a dropped connection:
        // no reconnect ladder paints over the failure or re-sends the load.
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(vm.acpStatus == ChatViewModel.ACPPhase.failed)
        #expect(await ch.sentMethods.filter { $0 == "session/load" }.count == 1)
    }

    /// The other start path: typing into a chat whose connection is gone
    /// (`autoStartACPAndSend`). The notice anchors before the new echo.
    @Test @MainActor func autoStartIntoANonACPSessionSaysSoBeforeTheNewTurn() async throws {
        let home = try Self.home(sessions: [("cli-1", "cli")])
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = Channel(behavior: .happy(sessionId: "acp-new"))
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in ch } }
        await vm.richChatViewModel.loadSessionHistory(sessionId: "cli-1")
        #expect(vm.richChatViewModel.messages.map(\.content) == ["history cli-1"])

        vm.sendText("carry on")

        let promptSent = await ChatViewModelStartLifecycleTests.waitUntil {
            await ch.sentMethods.contains("session/prompt")
        }
        #expect(promptSent)
        let methods = await ch.sentMethods
        #expect(!methods.contains("session/load"))
        let notice = try #require(vm.richChatViewModel.resumeContinuityNotice)
        #expect(notice.text.contains("cli"))
        #expect(notice.afterMessageId == 1, "the notice must sit between the old history and the new turn")
    }
}
