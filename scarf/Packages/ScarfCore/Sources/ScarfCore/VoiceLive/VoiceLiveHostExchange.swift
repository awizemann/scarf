import Foundation

/// The vendor's answer to our SDP offer.
public struct VoiceLiveSessionAnswer: Sendable, Equatable {
    public let sessionID: String?
    /// The SDP answer. Carries ICE credentials and DTLS fingerprints —
    /// never log it.
    public let sdp: String

    public init(sessionID: String?, sdp: String) {
        self.sessionID = sessionID
        self.sdp = sdp
    }
}

/// Exchanges a WebRTC offer for a GPT-Live answer. The GPT-Live engine
/// depends on this protocol, so tests (and a future non-host exchange) can
/// stand in for the host script.
public protocol VoiceLiveSessionExchanging: Sendable {
    func createSession(offerSDP: String, history: [VoiceLiveHistoryMessage]) async throws -> VoiceLiveSessionAnswer
}

/// Why a session exchange failed. No case ever carries a key, and vendor
/// detail is redacted twice (in the host script and again here).
/// ``errorDescription`` is an English token (ScarfCore has no string
/// catalog): the apps localize one sentence per case.
public enum VoiceLiveHostError: Error, Equatable, Sendable, LocalizedError {
    /// `import tools.voice_live` failed on the host: Hermes older than
    /// 0.21.3 or the wrong interpreter.
    case unsupported
    /// No OpenAI key resolves on the host (`create_webrtc_session` raises
    /// `ValueError` before calling the vendor, `voice_live.py:171-172`), so
    /// nothing was billed.
    case noKey
    /// The vendor rejected the request (`RuntimeError`, `voice_live.py:183-186`).
    /// `status` is the HTTP status when the message carried one.
    case vendor(status: Int?, detail: String)
    /// The host could not reach the vendor (URLError / timeout — which
    /// `create_webrtc_session` lets propagate raw).
    case network(detail: String)
    /// Scarf sent a malformed request (a bug; never includes the SDP).
    case badRequest(detail: String)
    /// Hermes raised something unexpected inside the exchange.
    case hostInternal(detail: String)
    /// The host has no usable `hermes` binary / Python interpreter.
    case interpreterNotFound(detail: String)
    /// The transport failed (host unreachable, SSH down, timed out).
    case transport(detail: String)
    /// The script ran but printed no result line.
    case malformedOutput(detail: String)

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Live Voice needs Hermes 0.21.3 or newer on this server."
        case .noKey:
            return "Live Voice needs an OpenAI API key on the Hermes host. Set OPENAI_API_KEY (or voice.gpt_live.api_key) there, then try again. Nothing was charged."
        case .vendor(let status?, let detail):
            return "OpenAI refused the Live Voice session (\(status)): \(detail)"
        case .vendor(nil, let detail):
            return "OpenAI refused the Live Voice session: \(detail)"
        case .network:
            return "The Hermes host couldn't reach OpenAI to start Live Voice."
        case .badRequest(let detail):
            return "Scarf sent Live Voice a request the host couldn't read: \(detail)"
        case .hostInternal(let detail):
            return "Hermes failed while starting Live Voice: \(detail)"
        case .interpreterNotFound(let detail):
            return "Couldn't find Hermes's Python on the server: \(detail)"
        case .transport:
            return "Couldn't reach the Hermes host to start Live Voice."
        case .malformedOutput:
            return "The Hermes host returned an unexpected answer while starting Live Voice."
        }
    }
}

/// GPT-Live's session exchange, run ON the Hermes host: the OpenAI key
/// never leaves it.
///
/// The script imports Hermes's own `tools.voice_live` inside the Python that
/// runs the server's `hermes` binary (shared discovery,
/// ``HermesPythonDiscovery``), exports `HERMES_HOME` for the window's profile
/// (the same scoping the dashboard route gets from `_config_profile_scope`,
/// `hermes_cli/web_routers/audio.py:58-69` @ v2026.9.14), and calls
/// `create_webrtc_session(sdp, history)` (`tools/voice_live.py:162-186`).
///
/// - The request (offer + history) travels as one line of JSON on a
///   quoted-delimiter heredoc, so CR/LF cross as escapes and the offer
///   reaches the vendor byte-exact — the vendor rejects a stripped offer
///   (`audio.py:189-191`).
/// - The script prints one `SCARF_VOICE_LIVE:{json}` line; the LAST such
///   line is parsed, so stray import-time prints can't corrupt it.
/// - ValueError means "no key" only when its message says so: the no-key
///   raise (`voice_live.py:171-172`) is the only one before the vendor call,
///   but a 2xx with an unreadable body raises `JSONDecodeError` /
///   `UnicodeDecodeError` (both ValueErrors) from `:182` AFTER the session
///   may exist — that is a vendor error, never "nothing was charged".
/// - `python -c` puts the working directory first on `sys.path`, so the
///   script `cd /`s first: a `~/tools/` over SSH must not shadow Hermes's
///   `tools` package.
/// - Hermes logs the vendor body at WARNING (`voice_live.py:185`) and that
///   body can echo a masked key, so the script disables logging and redacts
///   `sk-…` / `Bearer …` / `ek_…` before printing; ``redact(_:)`` repeats it
///   on this side.
/// - Neither the offer nor the answer is ever logged (ICE credentials and
///   DTLS fingerprints).
public struct VoiceLiveHostExchange: VoiceLiveSessionExchanging {
    public static let marker = "SCARF_VOICE_LIVE:"
    public static let errorMarker = "SCARF_VOICE_LIVE_ERROR:"
    /// The desktop allows 45 s for the same call (`voice-live.ts:328` @
    /// v2026.9.14); Hermes's own urlopen timeout is 30 s
    /// (`voice_live.py:181`), so this leaves room for SSH + interpreter
    /// start. Charter C10: the exchange is never un-timed.
    public static let sessionTimeout: TimeInterval = 45

    private let transport: any ServerTransport
    private let hermesBinary: String
    private let hermesHome: String

    public init(context: ServerContext, transport: (any ServerTransport)? = nil) {
        self.transport = transport ?? context.makeTransport()
        self.hermesBinary = context.paths.hermesBinary
        self.hermesHome = context.paths.home
    }

    public func createSession(
        offerSDP: String,
        history: [VoiceLiveHistoryMessage]
    ) async throws -> VoiceLiveSessionAnswer {
        let request = Self.requestJSON(offerSDP: offerSDP, history: history)
        let script = Self.script(hermesBinary: hermesBinary, hermesHome: hermesHome, requestJSON: request)
        let result: ProcessResult
        do {
            result = try await transport.streamScript(script, timeout: Self.sessionTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The transports don't propagate CancellationError: cancelling
            // mid-script surfaces as a plain transport error whose message is
            // "Script cancelled" (`SSHScriptRunner`), so the `catch is
            // CancellationError` above never fires and the caller would show
            // a connection failure for a session the user themself ended.
            // Our own cancellation is authoritative, whatever the transport
            // called it.
            if Task.isCancelled { throw CancellationError() }
            throw VoiceLiveHostError.transport(detail: Self.redact(error.localizedDescription))
        }
        try Task.checkCancellation()
        return try Self.parse(stdout: result.stdoutString, stderr: result.stderrString, exitCode: result.exitCode)
    }

    // MARK: - Request

    /// Single-line JSON: `{"history":[…],"op":"session","sdp":"…"}`. The
    /// offer is NOT trimmed.
    static func requestJSON(offerSDP: String, history: [VoiceLiveHistoryMessage]) -> String {
        struct Request: Encodable {
            let op = "session"
            let sdp: String
            let history: [VoiceLiveHistoryMessage]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Request(sdp: offerSDP, history: history)),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"   // unreachable for these types; the host answers bad_request
        }
        return json
    }

    // MARK: - Script

    static func script(hermesBinary: String, hermesHome: String, requestJSON: String) -> String {
        """
        export \(HermesConfigReader.pathPrelude)
        \(HermesPythonDiscovery.shellLines(hermesBinary: hermesBinary, errorMarker: errorMarker))
        export HERMES_HOME=\(HermesProfileScope.shellQuotePath(hermesHome))
        cd / || exit 3
        "$py" -c '\(pythonBody)' <<'SCARF_JSON'
        \(requestJSON)
        SCARF_JSON
        """
    }

    /// The host shim. Contains NO single quote (it sits inside `'…'` in the
    /// shell layer — pinned by a test). Reads one JSON request on stdin and
    /// prints one marker line; kinds: unsupported | no_key | vendor |
    /// network | bad_request | internal.
    static let pythonBody = #"""
    import json, logging, re, sys
    logging.disable(logging.CRITICAL)
    MARK = "SCARF_VOICE_LIVE:"
    SECRET = re.compile(r"(sk-[A-Za-z0-9_\-\*\.]+|Bearer\s+\S+|ek_[A-Za-z0-9_\-]+)")
    def out(obj):
        sys.stdout.write(MARK + json.dumps(obj) + "\n")
        sys.stdout.flush()
    def redact(text):
        return SECRET.sub("<redacted>", str(text))[:600]
    def fail(kind, detail, status=None):
        out({"ok": False, "kind": kind, "status": status, "detail": redact(detail)})
    def main():
        try:
            req = json.loads(sys.stdin.read() or "{}")
        except Exception as exc:
            return fail("bad_request", type(exc).__name__)
        try:
            import tools.voice_live as vl
        except Exception as exc:
            return fail("unsupported", type(exc).__name__)
        if req.get("op") != "session":
            return fail("bad_request", "unknown op")
        sdp = req.get("sdp")
        if not isinstance(sdp, str) or not sdp.strip():
            return fail("bad_request", "An SDP offer is required")
        history = req.get("history") if isinstance(req.get("history"), list) else None
        try:
            res = vl.create_webrtc_session(sdp, history)
        except ValueError as exc:
            if isinstance(exc, (json.JSONDecodeError, UnicodeError)):
                return fail("vendor", "unreadable response")
            if "API key" in str(exc):
                return fail("no_key", exc)
            return fail("internal", exc)
        except RuntimeError as exc:
            m = re.search(r"\((\d{3})\)", str(exc))
            return fail("vendor", exc, int(m.group(1)) if m else None)
        except Exception as exc:
            return fail("network", "%s: %s" % (type(exc).__name__, exc))
        if not isinstance(res, dict):
            return fail("vendor", "unexpected response")
        transport = res.get("transport") or {}
        answer = transport.get("sdp") if isinstance(transport, dict) else None
        if not isinstance(answer, str) or not answer:
            return fail("vendor", "response carried no SDP answer")
        session = res.get("session") if isinstance(res.get("session"), dict) else {}
        out({"ok": True, "session_id": session.get("id"), "sdp": answer})
    try:
        main()
    except Exception as exc:
        fail("internal", type(exc).__name__)
    """#

    // MARK: - Result

    static func parse(stdout: String, stderr: String, exitCode: Int32) throws -> VoiceLiveSessionAnswer {
        guard let line = stdout.split(whereSeparator: \.isNewline)
            .last(where: { $0.hasPrefix(marker) }) else {
            if let setup = stderr.split(whereSeparator: \.isNewline)
                .last(where: { $0.hasPrefix(errorMarker) }) {
                let detail = setup.dropFirst(errorMarker.count).trimmingCharacters(in: .whitespaces)
                throw VoiceLiveHostError.interpreterNotFound(detail: redact(detail))
            }
            throw VoiceLiveHostError.malformedOutput(detail: redact(diagnosticTail(stderr: stderr, exitCode: exitCode)))
        }
        struct DTO: Decodable {
            let ok: Bool
            let kind: String?
            let status: Int?
            let detail: String?
            let session_id: String?
            let sdp: String?
        }
        guard let data = String(line.dropFirst(marker.count)).data(using: .utf8),
              let dto = try? JSONDecoder().decode(DTO.self, from: data) else {
            throw VoiceLiveHostError.malformedOutput(detail: "unreadable result line")
        }
        if dto.ok {
            guard let sdp = dto.sdp, !sdp.isEmpty else {
                throw VoiceLiveHostError.vendor(status: nil, detail: "response carried no SDP answer")
            }
            return VoiceLiveSessionAnswer(sessionID: dto.session_id, sdp: sdp)
        }
        let detail = redact(dto.detail ?? "")
        switch dto.kind {
        case "unsupported": throw VoiceLiveHostError.unsupported
        case "no_key": throw VoiceLiveHostError.noKey
        case "vendor": throw VoiceLiveHostError.vendor(status: dto.status, detail: detail)
        case "network": throw VoiceLiveHostError.network(detail: detail)
        case "bad_request": throw VoiceLiveHostError.badRequest(detail: detail)
        default: throw VoiceLiveHostError.hostInternal(detail: detail)
        }
    }

    /// Strip anything key-shaped: OpenAI secret keys (`sk-…`, including the
    /// masked `sk-proj-****` echo), bearer tokens and ephemeral keys
    /// (`ek_…`). Bounded to 600 characters, like the host side.
    ///
    /// Also strips the SDP attributes that ARE credentials — `a=ice-ufrag:`,
    /// `a=ice-pwd:`, `a=fingerprint:` and `a=crypto:`. Offers and answers are
    /// never logged deliberately, but WebKit and the vendor quote the
    /// offending SDP line back inside an error message, and every caller of
    /// this function feeds its result to a `privacy: .public` log line. The
    /// attribute name survives (so a diagnosis is still possible); its value
    /// does not.
    public static func redact(_ text: String) -> String {
        let sdpPattern = #"(?im)^(a=(?:ice-ufrag|ice-pwd|fingerprint|crypto):).*$"#
        var text = text
        if let sdp = try? NSRegularExpression(pattern: sdpPattern) {
            text = sdp.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1<redacted>"
            )
        }
        // WebKit's exception text is one line: the attribute is quoted inline
        // rather than at the start of a line, so match it there too.
        let inlinePattern = #"(a=(?:ice-ufrag|ice-pwd|fingerprint|crypto):)[^\s"']+"#
        if let inline = try? NSRegularExpression(pattern: inlinePattern) {
            text = inline.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1<redacted>"
            )
        }
        let pattern = #"(sk-[A-Za-z0-9_\-\*\.]+|Bearer\s+\S+|ek_[A-Za-z0-9_\-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let range = NSRange(text.startIndex..., in: text)
        let redacted = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "<redacted>")
        return String(redacted.prefix(600))
    }

    private static func diagnosticTail(stderr: String, exitCode: Int32) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = lines.suffix(3).joined(separator: " | ")
        return tail.isEmpty ? "exit \(exitCode), no output" : "exit \(exitCode): \(tail)"
    }
}
