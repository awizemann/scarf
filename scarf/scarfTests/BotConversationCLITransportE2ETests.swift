import Testing
import Foundation
import ScarfCore
@testable import scarf

/// End-to-end proof of the Bot Chat CLI transport against the REAL local
/// `hermes` binary, in a fully ISOLATED Hermes home (never `~/.hermes`).
///
/// This is the regression net for the v2.24 release blocker: a Bot Chat
/// created by Scarf's CLI path lands with `sessions.source = "cli"`, which
/// Hermes' ACP adapter refuses to `session/load` (`acp_adapter/session.py:527`
/// at v2026.8.31 — `_restore` returns `nil` for any non-`"acp"` source), so
/// the old ACP-resume path fell back to `session/new` and the canonical
/// binding verifier refused the conversation forever. The fix routes such
/// sessions over the CLI transport; this test drives that transport for
/// real:
///
///   1. create a bot profile in the isolated home,
///   2. create the canonical Bot Chat with the exact production invocation
///      (`BotConversationViewModel.createCanonicalBotChat`),
///   3. resolve it with the production locator and assert the transport
///      decision (`liveSource == "cli"`, NOT ACP-born),
///   4. send a SECOND message through the same transport,
///   5. assert both turns are in the transcript, in ONE session, whose
///      title — the key the bot-mode protocol is gated on
///      (`agent/system_prompt.py:737-747`) — is still exactly "Bot Chat".
///
/// The model behind the bot is a local OpenAI-compatible stub (a python3
/// one-shot HTTP server handing back a canned SSE completion), so the test
/// spends no tokens, needs no credentials, and never reads the developer's
/// real Hermes configuration.
///
/// `.serialized` because the suite exports `HERMES_HOME` for the spawned
/// CLI (the same way `ScarfHermesHomeOverrideE2ETests` owns
/// `SCARF_HERMES_HOME`), and env mutation must not overlap another test.
@Suite(.serialized) struct BotConversationCLITransportE2ETests {

    private static let profile = "e2ebot"

    @Test(.timeLimit(.minutes(5)))
    func cliBornBotChatCarriesAWholeConversation() async throws {
        // Gate: this test only means something against a real binary. A
        // machine without `hermes` (CI without the toolchain) records the
        // skip loudly instead of green-lighting nothing.
        guard let hermesBinary = HermesFileService(context: .local).hermesBinaryPath() else {
            // Not an Issue: a machine without the toolchain (bare CI) must
            // not fail the suite — but the skip is printed so a green run
            // that silently skipped is at least visible in the log.
            print("[BotConversationCLITransportE2ETests] SKIPPED — no local hermes binary found")
            return
        }

        // -- Isolated world ------------------------------------------------
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-botchat-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stub = try StubModelServer.start(scratch: root)
        defer { stub.stop() }

        let config = """
        model:
          default: "stub-model"
          provider: "custom"
          base_url: "http://127.0.0.1:\(stub.port)/v1"
          api_key: "stub-key"
          api_mode: "chat_completions"
        """
        try config.write(to: root.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        // The spawned CLI resolves its home from HERMES_HOME. Scoped to
        // this suite (`.serialized`) and restored on exit; it never points
        // anywhere near ~/.hermes.
        let savedHome = ProcessInfo.processInfo.environment["HERMES_HOME"]
        setenv("HERMES_HOME", root.path, 1)
        defer {
            if let savedHome { setenv("HERMES_HOME", savedHome, 1) } else { unsetenv("HERMES_HOME") }
        }

        let ctx = ServerContext.local(home: root)
        _ = hermesBinary // documented gate; runHermes re-resolves the same binary

        // -- 1. the bot ----------------------------------------------------
        let created = ctx.runHermes(["profile", "create", Self.profile], timeout: 120)
        #expect(created.exitCode == 0, "profile create failed: \(created.output)")
        let profileHome = root.appendingPathComponent("profiles/\(Self.profile)")
        try config.write(to: profileHome.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        let pinned = ctx.pinnedToProfile(Self.profile)

        // -- 2. first message: creates the canonical Bot Chat --------------
        let firstFailure = await BotConversationViewModel.createCanonicalBotChat(
            context: pinned, profile: Self.profile, text: "hello bot, first message"
        )
        #expect(firstFailure == nil, "first send failed: \(firstFailure ?? "")")

        // -- 3. resolve with the production locator ------------------------
        let svc = HermesDataService(context: pinned)
        #expect(await svc.open(), "the bot profile's state.db must open")
        let found = try #require(await svc.locateCanonicalBotChat())
        // The transport decision that fixes the release blocker: this
        // session is real, titled, and NOT loadable over ACP.
        #expect(found.liveSource == "cli")
        #expect(!found.isACPBorn)

        // -- 4. second message: the same transport, now a pure append ------
        let secondFailure = await BotConversationViewModel.createCanonicalBotChat(
            context: pinned, profile: Self.profile, text: "second message please"
        )
        #expect(secondFailure == nil, "second send failed: \(secondFailure ?? "")")

        // -- 5. one session, both turns, title intact ----------------------
        _ = await svc.refresh(forceFresh: true)
        let after = try #require(await svc.locateCanonicalBotChat())
        #expect(after.registryId == found.registryId, "the second send must not mint a second session")
        #expect(after.liveId == found.liveId)

        let registry = try #require(await svc.fetchSession(id: after.registryId))
        #expect(registry.title == BotChatSession.canonicalTitle,
                "the title is the bot-mode protocol's gate and must survive both turns")

        let messages = await svc.fetchMessages(sessionId: after.liveId, limit: 100)
        let userTexts = messages.filter(\.isUser).map(\.content)
        #expect(userTexts.contains { $0.contains("hello bot, first message") })
        #expect(userTexts.contains { $0.contains("second message please") })
        let assistantTurns = messages.filter { $0.isAssistant && $0.content.contains("STUB REPLY") }
        #expect(assistantTurns.count >= 2, "both turns must have completed replies, got: \(messages.map(\.role))")
        await svc.close()
    }
}

/// A minimal OpenAI-compatible chat-completions endpoint (python3 stdlib,
/// no dependencies) that answers every prompt with a canned reply — SSE
/// when `stream: true` (what Hermes actually requests), plain JSON
/// otherwise. Binds port 0 and prints the chosen port on stdout.
private struct StubModelServer {
    let port: Int
    private let process: Process

    static func start(scratch: URL) throws -> StubModelServer {
        let script = scratch.appendingPathComponent("stub_llm.py")
        try Self.python.write(to: script, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [script.path]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        // First line of stdout is the bound port.
        guard let line = out.fileHandleForReading.availableData.split(separator: 10).first,
              let port = Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)) else {
            proc.terminate()
            throw TransportError.other(message: "stub model server failed to report a port")
        }
        return StubModelServer(port: port, process: proc)
    }

    func stop() { process.terminate() }

    private static let python = #"""
    import json, http.server, socketserver

    REPLY = "STUB REPLY: acknowledged."

    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def do_POST(self):
            n = int(self.headers.get('Content-Length', 0))
            try:
                req = json.loads(self.rfile.read(n) or b"{}")
            except Exception:
                req = {}
            if req.get("stream"):
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Cache-Control', 'no-cache')
                self.send_header('Connection', 'close')
                self.end_headers()
                def sse(obj):
                    self.wfile.write(b"data: " + json.dumps(obj).encode() + b"\n\n")
                base = {"id": "chatcmpl-stub", "object": "chat.completion.chunk", "created": 0, "model": "stub-model"}
                sse({**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": REPLY}, "finish_reason": None}]})
                sse({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                     "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}})
                self.wfile.write(b"data: [DONE]\n\n")
            else:
                data = json.dumps({
                    "id": "chatcmpl-stub", "object": "chat.completion", "created": 0, "model": "stub-model",
                    "choices": [{"index": 0, "message": {"role": "assistant", "content": REPLY}, "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
                }).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        def do_GET(self):
            data = json.dumps({"object": "list", "data": [{"id": "stub-model", "object": "model"}]}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        def log_message(self, *a): pass

    class Srv(socketserver.ThreadingTCPServer):
        allow_reuse_address = True

    with Srv(("127.0.0.1", 0), H) as srv:
        print(srv.server_address[1], flush=True)
        srv.serve_forever()
    """#
}
