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

    // MARK: the real script, run by /bin/sh against a fake tools.voice_live

    #if os(macOS)
    @Test func realScriptDeliversTheOfferByteExactAndReturnsTheAnswer() throws {
        let env = try FakeHermes(mode: "ok")
        let answer = try env.run(offer: Self.offer)
        #expect(answer.sdp == "v=0\r\nanswer\r\n")
        #expect(answer.sessionID == "sess_fake")
        #expect(try String(contentsOf: env.seenOffer, encoding: .utf8) == Self.offer)
        #expect(try String(contentsOf: env.seenHome, encoding: .utf8) == env.home.path)
    }

    @Test func realScriptMapsNoKey() throws {
        #expect(throws: VoiceLiveHostError.noKey) { try FakeHermes(mode: "no_key").run(offer: Self.offer) }
    }

    @Test func realScriptMapsVendorRejectionAndRedactsTheEcho() throws {
        do {
            _ = try FakeHermes(mode: "vendor").run(offer: Self.offer)
            Issue.record("expected a throw")
        } catch VoiceLiveHostError.vendor(let status, let detail) {
            #expect(status == 401)
            #expect(!detail.contains("sk-proj"))
        }
    }

    @Test func realScriptMapsNetworkErrors() throws {
        do {
            _ = try FakeHermes(mode: "network").run(offer: Self.offer)
            Issue.record("expected a throw")
        } catch VoiceLiveHostError.network(let detail) {
            #expect(detail.contains("URLError"))
        }
    }

    /// A 2xx whose body isn't JSON raises JSONDecodeError — a ValueError —
    /// from `voice_live.py:182`, AFTER the vendor may have created the
    /// session: it must never read as "no key, nothing charged".
    @Test func realScriptMapsAnUnreadableVendorBodyToVendorNotNoKey() throws {
        #expect(throws: VoiceLiveHostError.vendor(status: nil, detail: "unreadable response")) {
            try FakeHermes(mode: "unreadable").run(offer: Self.offer)
        }
    }

    @Test func realScriptMapsOtherValueErrorsToInternal() throws {
        do {
            _ = try FakeHermes(mode: "badurl").run(offer: Self.offer)
            Issue.record("expected a throw")
        } catch VoiceLiveHostError.hostInternal(let detail) {
            #expect(detail.contains("unknown url type"))
        }
    }

    /// Over SSH the script starts in `$HOME`, and `python -c` puts the
    /// working directory first on `sys.path`: a `~/tools/voice_live.py`
    /// must not shadow Hermes's. The script `cd /`s first.
    @Test func aToolsPackageInTheWorkingDirectoryCannotShadowHermes() throws {
        let env = try FakeHermes(mode: "ok")
        let cwd = env.root.appendingPathComponent("home-with-tools")
        let tools = cwd.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try Data().write(to: tools.appendingPathComponent("__init__.py"))
        try Data("""
        def create_webrtc_session(sdp_offer, history=None):
            return {"session": {"id": "SHADOW"}, "transport": {"type": "webrtc", "sdp": "shadow"}}
        """.utf8).write(to: tools.appendingPathComponent("voice_live.py"))
        let answer = try env.run(offer: Self.offer, from: cwd)
        #expect(answer.sessionID == "sess_fake")
    }

    @Test func realScriptReportsUnsupportedWhenTheModuleIsMissing() throws {
        #expect(throws: VoiceLiveHostError.unsupported) { try FakeHermes(mode: "missing").run(offer: Self.offer) }
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

        func run(offer: String, from directory: URL? = nil) throws -> VoiceLiveSessionAnswer {
            let script = VoiceLiveHostExchange.script(
                hermesBinary: root.appendingPathComponent("venv/bin/hermes").path,
                hermesHome: home.path,
                requestJSON: VoiceLiveHostExchange.requestJSON(offerSDP: offer, history: [VoiceLiveHistoryMessage(role: .user, text: "hi")]))
            let out = try ShellTestRunner.run(arguments: ["-c", script], currentDirectory: directory)
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
