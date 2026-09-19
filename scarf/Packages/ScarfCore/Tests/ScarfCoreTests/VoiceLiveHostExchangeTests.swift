import Testing
import Foundation
@testable import ScarfCore

/// The GPT-Live session exchange that runs on the Hermes host. Error kinds
/// mirror `create_webrtc_session` at `tools/voice_live.py:162-186` @
/// v2026.9.14: ValueError (no key, raised before the vendor is called),
/// RuntimeError "(<status>): <detail>" (vendor rejected), anything else
/// (URLError/timeouts propagate raw because only HTTPError is caught).
@Suite struct VoiceLiveHostExchangeTests {

    static let offer = "v=0\r\no=- 46117 2 IN IP4 127.0.0.1\r\ns=-\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n"

    // MARK: script construction

    @Test func pythonBodyHasNoSingleQuote() {
        // It sits inside '…' in the shell layer, unescaped.
        #expect(!VoiceLiveHostExchange.pythonBody.contains("'"))
    }

    @Test func requestIsOneLineAndCarriesTheOfferByteExact() throws {
        let json = VoiceLiveHostExchange.requestJSON(offerSDP: Self.offer, history: [])
        #expect(!json.contains("\n") && !json.contains("\r"))
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(decoded?["op"] as? String == "session")
        #expect(decoded?["sdp"] as? String == Self.offer)   // trailing CRLF intact
    }

    @Test func historyEncodesTheVendorShape() throws {
        let json = VoiceLiveHostExchange.requestJSON(offerSDP: "x", history: [
            VoiceLiveHistoryMessage(role: .user, text: "hi"),
            VoiceLiveHistoryMessage(role: .assistant, text: "hello"),
        ])
        #expect(json.contains(#"{"content":[{"text":"hi","type":"input_text"}],"role":"user","type":"message"}"#))
        #expect(json.contains(#"{"content":[{"text":"hello","type":"output_text"}],"role":"assistant","type":"message"}"#))
    }

    @Test func configPathsCannotEscapeTheirQuotes() {
        let script = VoiceLiveHostExchange.script(
            hermesBinary: "/opt/h'$(touch /tmp/pwn)/hermes", hermesHome: "/srv/it's $(id)", requestJSON: "{}")
        #expect(script.contains(#"hb='/opt/h'\''$(touch /tmp/pwn)/hermes'"#))
        #expect(script.contains(#"export HERMES_HOME='/srv/it'\''s $(id)'"#))
        #expect(script.contains("<<'SCARF_JSON'"))
    }

    @Test func tildeHomeStaysAnExpansion() {
        let script = VoiceLiveHostExchange.script(hermesBinary: "hermes", hermesHome: "~/.hermes", requestJSON: "{}")
        #expect(script.contains(#"export HERMES_HOME="$HOME/.hermes""#) || script.contains(#"export HERMES_HOME="$HOME"'/.hermes'"#))
    }

    /// Keep the worst-case script small: it crosses SSH on the exec
    /// channel's stdin (iOS, `CitadelServerTransport.streamScript`) or ssh's
    /// stdin (Mac), and the old iOS path — one base64 argv token — was bound
    /// by Linux MAX_ARG_STRLEN (128 KiB). A generous ceiling either way.
    @Test func worstCaseScriptStaysSmall() {
        let offer = String(repeating: "a=candidate:1 1 udp 2122260223 192.168.1.10 51234 typ host\r\n", count: 40)
        let turns = (0..<60).map { VoiceLiveText.SeedTurn(role: $0 % 2 == 0 ? .user : .assistant, text: String(repeating: "x", count: 1_500)) }
        let history = VoiceLiveText.liveHistory(from: turns)
        let json = VoiceLiveHostExchange.requestJSON(offerSDP: offer, history: history)
        let script = VoiceLiveHostExchange.script(hermesBinary: "/usr/local/bin/hermes", hermesHome: "/root/.hermes", requestJSON: json)
        let base64 = Data(script.utf8).base64EncodedString()
        #expect(base64.utf8.count < 32 * 1_024, "\(base64.utf8.count)")
    }

    // MARK: result parsing + error mapping

    @Test func successReturnsTheAnswer() throws {
        let out = "noise\nSCARF_VOICE_LIVE:{\"ok\": true, \"session_id\": \"sess_1\", \"sdp\": \"v=0\\r\\n\"}\n"
        let answer = try VoiceLiveHostExchange.parse(stdout: out, stderr: "", exitCode: 0)
        #expect(answer == VoiceLiveSessionAnswer(sessionID: "sess_1", sdp: "v=0\r\n"))
    }

    @Test func theLastMarkerLineWins() throws {
        let out = """
        SCARF_VOICE_LIVE:{"ok": false, "kind": "internal", "status": null, "detail": "decoy"}
        SCARF_VOICE_LIVE:{"ok": true, "session_id": null, "sdp": "v=0"}
        """
        #expect(try VoiceLiveHostExchange.parse(stdout: out, stderr: "", exitCode: 0).sdp == "v=0")
    }

    @Test(arguments: [
        (#"{"ok": false, "kind": "unsupported", "status": null, "detail": "ModuleNotFoundError"}"#, VoiceLiveHostError.unsupported),
        (#"{"ok": false, "kind": "no_key", "status": null, "detail": "GPT-Live needs an OpenAI API key"}"#, VoiceLiveHostError.noKey),
        (#"{"ok": false, "kind": "vendor", "status": 403, "detail": "no access"}"#, VoiceLiveHostError.vendor(status: 403, detail: "no access")),
        (#"{"ok": false, "kind": "vendor", "status": null, "detail": "response carried no SDP answer"}"#, VoiceLiveHostError.vendor(status: nil, detail: "response carried no SDP answer")),
        (#"{"ok": false, "kind": "network", "status": null, "detail": "URLError: timed out"}"#, VoiceLiveHostError.network(detail: "URLError: timed out")),
        (#"{"ok": false, "kind": "bad_request", "status": null, "detail": "An SDP offer is required"}"#, VoiceLiveHostError.badRequest(detail: "An SDP offer is required")),
        (#"{"ok": false, "kind": "internal", "status": null, "detail": "KeyError"}"#, VoiceLiveHostError.hostInternal(detail: "KeyError")),
        (#"{"ok": true, "session_id": "s", "sdp": ""}"#, VoiceLiveHostError.vendor(status: nil, detail: "response carried no SDP answer")),
    ])
    func errorKindsMap(_ json: String, _ expected: VoiceLiveHostError) {
        #expect(throws: expected) {
            try VoiceLiveHostExchange.parse(stdout: "SCARF_VOICE_LIVE:" + json, stderr: "", exitCode: 0)
        }
    }

    @Test func noKeyCopyIsASetupMessage() {
        let copy = VoiceLiveHostError.noKey.errorDescription ?? ""
        #expect(copy.contains("OPENAI_API_KEY"))
        #expect(copy.contains("Nothing was charged"))
    }

    @Test func interpreterFailureIsNamed() {
        #expect(throws: VoiceLiveHostError.interpreterNotFound(detail: "hermes binary not found")) {
            try VoiceLiveHostExchange.parse(stdout: "", stderr: "SCARF_VOICE_LIVE_ERROR: hermes binary not found\n", exitCode: 3)
        }
    }

    @Test func missingMarkerIsMalformed() {
        #expect(throws: VoiceLiveHostError.malformedOutput(detail: "exit 1: Traceback | boom")) {
            try VoiceLiveHostExchange.parse(stdout: "", stderr: "Traceback\nboom\n", exitCode: 1)
        }
    }

    /// SDP credentials are as sensitive as the API key: WebKit and the
    /// vendor quote the offending line back in an error message, and every
    /// caller of `redact` logs its result at `privacy: .public`.
    @Test func redactStripsSDPCredentials() {
        let sdp = """
        v=0
        a=ice-ufrag:F7gI
        a=ice-pwd:x9Cl+TsvCRyWFbEGuZaLlWFH
        a=fingerprint:sha-256 39:4A:09:1E:0E:33
        a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:NzB4d1BINUAvLEw6UzF3WSJ+PSdFcGdUJShpX1Zj
        a=rtpmap:111 opus/48000/2
        """
        let redacted = VoiceLiveHostExchange.redact(sdp)
        #expect(!redacted.contains("F7gI"))
        #expect(!redacted.contains("x9Cl+TsvCRyWFbEGuZaLlWFH"))
        #expect(!redacted.contains("39:4A:09:1E:0E:33"))
        #expect(!redacted.contains("NzB4d1BINUAvLEw6UzF3WSJ+PSdFcGdUJShpX1Zj"))
        // The attribute names survive so a failure is still diagnosable, and
        // non-credential attributes are untouched.
        #expect(redacted.contains("a=ice-pwd:<redacted>"))
        #expect(redacted.contains("a=rtpmap:111 opus/48000/2"))
    }

    /// The same, for a one-line exception message that quotes the attribute
    /// inline rather than at the start of a line.
    @Test func redactStripsSDPCredentialsQuotedInlineInAnErrorMessage() {
        let message = #"InvalidAccessError: Failed to parse SessionDescription. a=ice-pwd:SUPERSECRETPWD is invalid"#
        let redacted = VoiceLiveHostExchange.redact(message)
        #expect(!redacted.contains("SUPERSECRETPWD"))
        #expect(redacted.contains("a=ice-pwd:<redacted>"))
    }

    @Test func vendorDetailIsRedactedOnThisSideToo() throws {
        let json = #"{"ok": false, "kind": "vendor", "status": 401, "detail": "Incorrect API key provided: sk-proj-abc****wxyz. Bearer ek_12345 rejected"}"#
        do {
            _ = try VoiceLiveHostExchange.parse(stdout: "SCARF_VOICE_LIVE:" + json, stderr: "", exitCode: 0)
            Issue.record("expected a throw")
        } catch let error as VoiceLiveHostError {
            guard case .vendor(401, let detail) = error else { Issue.record("\(error)"); return }
            #expect(!detail.contains("sk-"))
            #expect(!detail.contains("ek_"))
            #expect(detail.contains("<redacted>"))
        }
    }

    // MARK: cancellation

    /// A transport whose script never finishes on its own: it waits for the
    /// caller's cancellation and then reports it the way the real ones do —
    /// as a plain `TransportError`, NOT as a `CancellationError`
    /// (`SSHScriptRunner` returns `.connectFailure("Script cancelled")`).
    final class CancelHangTransport: ServerTransport, @unchecked Sendable {
        let contextID: ServerID = UUID()
        let isRemote = false
        private let lock = NSLock()
        private var _entered = false
        var entered: Bool { lock.withLock { _entered } }

        func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
            lock.withLock { _entered = true }
            // `try?`: a sleep that throws CancellationError would make this
            // test pass without the fix under scrutiny.
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw TransportError.other(message: "Script cancelled")
        }

        func readFile(_ path: String) throws -> Data { Data() }
        func unguardedWriteFile(_ path: String, data: Data) throws {}
        func fileExists(_ path: String) -> Bool { false }
        func stat(_ path: String) -> FileStat? { nil }
        func listDirectory(_ path: String) throws -> [String] { [] }
        func createDirectory(_ path: String) throws {}
        func removeFile(_ path: String) throws {}
        func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval) throws -> ProcessResult {
            ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        #if !os(iOS)
        func makeProcess(executable: String, args: [String]) -> Process { Process() }
        #endif
        func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func streamRawBytes(executable: String, args: [String]) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
            AsyncStream { $0.finish() }
        }
    }

    /// Ending a Live Voice session mid-exchange is the user's own doing, not
    /// a connection failure: the transport calls it "Script cancelled", so
    /// only `Task.isCancelled` can tell the two apart.
    @Test func cancellationSurfacesAsCancellationErrorNotATransportFailure() async throws {
        let transport = CancelHangTransport()
        let exchange = VoiceLiveHostExchange(
            context: ServerContext(id: UUID(), displayName: "h", kind: .local),
            transport: transport
        )
        let task = Task { try await exchange.createSession(offerSDP: Self.offer, history: []) }
        while !transport.entered { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected a throw")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    // MARK: the real script, run by /bin/sh against a fake tools.voice_live

    #if os(macOS)
    @Test func realScriptDeliversTheOfferByteExactAndReturnsTheAnswer() async throws {
        let env = try await FakeHermes(mode: "ok")
        let answer = try await env.run(offer: Self.offer)
        #expect(answer.sdp == "v=0\r\nanswer\r\n")
        #expect(answer.sessionID == "sess_fake")
        #expect(try String(contentsOf: env.seenOffer, encoding: .utf8) == Self.offer)
        #expect(try String(contentsOf: env.seenHome, encoding: .utf8) == env.home.path)
    }

    @Test func realScriptMapsNoKey() async throws {
        await #expect(throws: VoiceLiveHostError.noKey) { try await FakeHermes(mode: "no_key").run(offer: Self.offer) }
    }

    @Test func realScriptMapsVendorRejectionAndRedactsTheEcho() async throws {
        do {
            _ = try await FakeHermes(mode: "vendor").run(offer: Self.offer)
            Issue.record("expected a throw")
        } catch VoiceLiveHostError.vendor(let status, let detail) {
            #expect(status == 401)
            #expect(!detail.contains("sk-proj"))
        }
    }

    @Test func realScriptMapsNetworkErrors() async throws {
        do {
            _ = try await FakeHermes(mode: "network").run(offer: Self.offer)
            Issue.record("expected a throw")
        } catch VoiceLiveHostError.network(let detail) {
            #expect(detail.contains("URLError"))
        }
    }

    /// A 2xx whose body isn't JSON raises JSONDecodeError — a ValueError —
    /// from `voice_live.py:182`, AFTER the vendor may have created the
    /// session: it must never read as "no key, nothing charged".
    @Test func realScriptMapsAnUnreadableVendorBodyToVendorNotNoKey() async throws {
        await #expect(throws: VoiceLiveHostError.vendor(status: nil, detail: "unreadable response")) {
            try await FakeHermes(mode: "unreadable").run(offer: Self.offer)
        }
    }

    @Test func realScriptMapsOtherValueErrorsToInternal() async throws {
        do {
            _ = try await FakeHermes(mode: "badurl").run(offer: Self.offer)
            Issue.record("expected a throw")
        } catch VoiceLiveHostError.hostInternal(let detail) {
            #expect(detail.contains("unknown url type"))
        }
    }

    /// Over SSH the script starts in `$HOME`, and `python -c` puts the
    /// working directory first on `sys.path`: a `~/tools/voice_live.py`
    /// must not shadow Hermes's. The script `cd /`s first.
    @Test func aToolsPackageInTheWorkingDirectoryCannotShadowHermes() async throws {
        let env = try await FakeHermes(mode: "ok")
        let cwd = env.root.appendingPathComponent("home-with-tools")
        let tools = cwd.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try Data().write(to: tools.appendingPathComponent("__init__.py"))
        try Data("""
        def create_webrtc_session(sdp_offer, history=None):
            return {"session": {"id": "SHADOW"}, "transport": {"type": "webrtc", "sdp": "shadow"}}
        """.utf8).write(to: tools.appendingPathComponent("voice_live.py"))
        let answer = try await env.run(offer: Self.offer, from: cwd)
        #expect(answer.sessionID == "sess_fake")
    }

    @Test func realScriptReportsUnsupportedWhenTheModuleIsMissing() async throws {
        await #expect(throws: VoiceLiveHostError.unsupported) { try await FakeHermes(mode: "missing").run(offer: Self.offer) }
    }

    /// A fake Hermes install: `venv/bin/hermes` (`#!/bin/sh`), a sibling
    /// `python` that runs the system python3 with a fake `tools.voice_live`
    /// on PYTHONPATH.
    private final class FakeHermes {
        let root: URL
        let home: URL
        let seenOffer: URL
        let seenHome: URL

        init(mode: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-vl-\(UUID().uuidString)")
            home = root.appendingPathComponent("home dir")
            seenOffer = root.appendingPathComponent("offer.sdp")
            seenHome = root.appendingPathComponent("home.txt")
            let fm = FileManager.default
            let bin = root.appendingPathComponent("venv/bin")
            let pkg = root.appendingPathComponent("site/tools")
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            try Self.write(bin.appendingPathComponent("hermes"), "#!/bin/sh\nexit 0\n")
            try Self.write(bin.appendingPathComponent("python"), """
            #!/bin/sh
            PYTHONPATH='\(root.appendingPathComponent("site").path)' exec python3 "$@"
            """)
            if mode != "missing" {
                try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
                try Self.write(pkg.appendingPathComponent("__init__.py"), "")
                try Self.write(pkg.appendingPathComponent("voice_live.py"), """
                import json, os, urllib.error
                def create_webrtc_session(sdp_offer, history=None):
                    open(\(pyString(seenOffer.path)), "w", newline="").write(sdp_offer)
                    open(\(pyString(seenHome.path)), "w").write(os.environ.get("HERMES_HOME", ""))
                    mode = \(pyString(mode))
                    if mode == "no_key":
                        raise ValueError("GPT-Live needs an OpenAI API key (OPENAI_API_KEY or voice.gpt_live.api_key)")
                    if mode == "vendor":
                        raise RuntimeError("GPT-Live session creation failed (401): Incorrect API key provided: sk-proj-abcd****wxyz")
                    if mode == "network":
                        raise urllib.error.URLError("timed out")
                    if mode == "unreadable":
                        return json.loads("<html>gateway</html>")
                    if mode == "badurl":
                        raise ValueError("unknown url type: 'htps://api.openai.com/v1/live/sessions'")
                    return {"session": {"id": "sess_fake"}, "transport": {"type": "webrtc", "sdp": "v=0\\r\\nanswer\\r\\n"}}
                """)
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func run(offer: String, from directory: URL? = nil) async throws -> VoiceLiveSessionAnswer {
            let script = VoiceLiveHostExchange.script(
                hermesBinary: root.appendingPathComponent("venv/bin/hermes").path,
                hermesHome: home.path,
                requestJSON: VoiceLiveHostExchange.requestJSON(offerSDP: offer, history: [VoiceLiveHistoryMessage(role: .user, text: "hi")]))
            let out = try await ShellTestRunner.run(arguments: ["-c", script], currentDirectory: directory)
            return try VoiceLiveHostExchange.parse(stdout: out.stdout, stderr: out.stderr, exitCode: out.status)
        }

        private func pyString(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }

        private static func write(_ url: URL, _ text: String) throws {
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
    #endif
}
