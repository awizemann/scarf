import Foundation

/// An ephemeral realtime client secret (`ek_…`, ≈10-minute TTL).
///
/// The value is intentionally NOT printable: `description` redacts so a
/// stray `\(token)` in a log line or error dialog can't leak it. The
/// raw provider API key never leaves the Hermes host — only this
/// short-lived secret crosses to the client, and it is held in memory
/// for the duration of one session, never persisted.
public struct RealtimeEphemeralToken: Sendable, Equatable {
    public let value: String
    public let expiresAt: Date?

    public init(value: String, expiresAt: Date? = nil) {
        self.value = value
        self.expiresAt = expiresAt
    }
}

extension RealtimeEphemeralToken: CustomStringConvertible {
    public var description: String { "RealtimeEphemeralToken(<redacted>)" }
}

/// Mints the ephemeral session token a realtime service authenticates
/// with. Implemented against the Hermes host for production; mocked in
/// tests (nothing here may touch the network from a test).
public protocol RealtimeTokenMinter: Sendable {
    nonisolated func mintToken(configuration: RealtimeVoiceConfiguration) async throws -> RealtimeEphemeralToken
}

// MARK: - Mint script

/// Builds the shell + Python script `HermesHostRealtimeTokenMinter`
/// pipes to the Hermes host. Pure and string-total so the script body
/// is unit-testable without executing anything.
///
/// The script is passed to `/bin/sh -s` as an opaque byte stream (via
/// ``ServerTransport/streamScript(_:timeout:)``) so no argument quoting
/// can mangle it — the same reason `SSHScriptRunner` exists. The Python
/// program travels inside a quoted heredoc (`<<'SCARF_PY'`), which
/// disables shell interpolation for the entire block: `$`, backticks,
/// and quotes inside the Python are inert.
///
/// Exit-code contract (mirrored by the minter's error mapping):
/// - `0` — success, stdout is exactly the `ek_…` secret
/// - `3` — no Python interpreter found on the host
/// - `4` — the Hermes `tools` package isn't importable by that interpreter
/// - `5` — the host could not resolve an OpenAI API key
/// - `6` — the mint HTTP request failed (`mint-http-<status>` marker)
/// - `7` — the mint response had no `value`
public enum RealtimeTokenMintScript {
    /// Python interpreters to try, in order — the first that exists and
    /// can import Hermes wins. Bare names (no `/`) resolve via PATH.
    /// `~`-prefixed paths expand because the candidate list is emitted
    /// unquoted (the entries are ours, no spaces or metacharacters).
    public static let defaultPythonCandidates: [String] = [
        "~/pinokio/api/hermes-agent.pinokio.git/app/.venv/bin/python",
        "python3",
    ]

    public static func shell(
        pythonCandidates: [String] = defaultPythonCandidates,
        hermesHome: String?,
        model: String,
        voice: String
    ) -> String {
        let candidates = pythonCandidates.isEmpty ? defaultPythonCandidates : pythonCandidates
        var lines: [String] = []
        lines.append("PY=\"\"")
        lines.append("for candidate in \(candidates.joined(separator: " ")); do")
        lines.append("  if command -v \"$candidate\" >/dev/null 2>&1; then PY=\"$candidate\"; break; fi")
        lines.append("done")
        lines.append("if [ -z \"$PY\" ]; then echo no-python-found >&2; exit 3; fi")
        lines.append(homeExport(for: hermesHome))
        lines.append("\"$PY\" - <<'SCARF_PY'")
        lines.append(pythonBody(model: model, voice: voice))
        lines.append("SCARF_PY")
        return lines.joined(separator: "\n") + "\n"
    }

    /// `HERMES_HOME` export line. `nil` (and `~`-relative homes) resolve
    /// to `$HOME/...` on the host itself, so a remote server's real home
    /// is used without Scarf hard-coding a path.
    private static func homeExport(for hermesHome: String?) -> String {
        let home: String
        switch hermesHome {
        case nil, "":
            home = "$HOME/.hermes"
        case .some(let explicit) where explicit.hasPrefix("~"):
            let remainder = explicit.drop(while: { $0 == "~" })
            home = remainder.hasPrefix("/")
                ? "$HOME" + remainder
                : "$HOME/" + remainder
        case .some(let absolute):
            // Absolute paths are quoted; they cannot contain a double
            // quote in practice (POSIX paths from our own config), and
            // an exotic path would fail visibly at the shell, not
            // silently mis-direct the mint.
            home = "\"" + absolute + "\""
        }
        return "if [ -z \"$HERMES_HOME\" ]; then export HERMES_HOME=\(home); fi"
    }

    /// The Python program: resolve the OpenAI key via Hermes' own
    /// sanctioned helper, POST to `/v1/realtime/client_secrets`, print
    /// ONLY the resulting `ek_` secret to stdout. The key itself never
    /// appears in any stream this process can see.
    ///
    /// `model` and `voice` are embedded as JSON string literals —
    /// encoded by `JSONEncoder`, not interpolated — so no character in
    /// either can break out of the Python string.
    public static func pythonBody(model: String, voice: String) -> String {
        let modelLiteral = jsonStringLiteral(model)
        let voiceLiteral = jsonStringLiteral(voice)
        return """
            import json
            import sys
            import urllib.error
            import urllib.request

            try:
                from tools.tool_backend_helpers import resolve_openai_audio_api_key
            except Exception as exc:
                sys.stderr.write("hermes-import-failed: %s\\n" % exc)
                sys.exit(4)

            try:
                key = resolve_openai_audio_api_key()
            except Exception as exc:
                sys.stderr.write("key-resolution-failed: %s\\n" % exc)
                sys.exit(5)
            if not key:
                sys.stderr.write("key-resolution-failed: empty key\\n")
                sys.exit(5)

            payload = json.dumps({
                "session": {
                    "type": "realtime",
                    "model": \(modelLiteral),
                    "audio": {"output": {"voice": \(voiceLiteral)}},
                }
            }).encode("utf-8")
            request = urllib.request.Request(
                "https://api.openai.com/v1/realtime/client_secrets",
                data=payload,
                headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
                method="POST",
            )
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    document = json.load(response)
            except urllib.error.HTTPError as exc:
                sys.stderr.write("mint-http-%d\\n" % exc.code)
                sys.exit(6)
            except Exception as exc:
                sys.stderr.write("mint-http-failed: %s\\n" % exc)
                sys.exit(6)

            token = document.get("value") if isinstance(document, dict) else None
            if not isinstance(token, str) or not token:
                sys.stderr.write("mint-response-missing-value\\n")
                sys.exit(7)
            sys.stdout.write(token)
            """
    }

    /// JSON-encode a string and emit it as a Python string literal.
    /// JSON string escaping is a subset of Python's, so the encoded
    /// literal is valid in both — and injection-proof for any input.
    private static func jsonStringLiteral(_ value: String) -> String {
        let encoded = (try? JSONEncoder().encode([value])).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "\"\""
        // `["abc"]` → `"abc"` — strip the array brackets JSONEncoder added.
        return String(encoded.dropFirst().dropLast())
    }
}

// MARK: - Hermes-host minter

/// Mints realtime tokens by exec'ing the mint script on the Hermes host
/// over the existing ``ServerTransport`` — local hosts run it directly,
/// remote hosts over SSH. Only the `ek_…` stdout line crosses back.
public struct HermesHostRealtimeTokenMinter: RealtimeTokenMinter {
    private let transport: any ServerTransport
    private let hermesHome: String?
    private let pythonCandidates: [String]
    private let timeout: TimeInterval

    public init(
        transport: any ServerTransport,
        hermesHome: String? = nil,
        pythonCandidates: [String] = RealtimeTokenMintScript.defaultPythonCandidates,
        timeout: TimeInterval = 60
    ) {
        self.transport = transport
        self.hermesHome = hermesHome
        self.pythonCandidates = pythonCandidates
        self.timeout = timeout
    }

    public func mintToken(configuration: RealtimeVoiceConfiguration) async throws -> RealtimeEphemeralToken {
        let script = RealtimeTokenMintScript.shell(
            pythonCandidates: pythonCandidates,
            hermesHome: hermesHome,
            model: configuration.model,
            voice: configuration.voice
        )
        let result: ProcessResult
        do {
            result = try await transport.streamScript(script, timeout: timeout)
        } catch {
            throw RealtimeVoiceError.tokenMintFailed(
                reason: "couldn't run the mint command on the Hermes host (\(error.localizedDescription))"
            )
        }

        let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0 else {
            throw RealtimeVoiceError.tokenMintFailed(reason: Self.failureReason(exitCode: result.exitCode, stderr: result.stderrString))
        }
        guard stdout.hasPrefix("ek_"), stdout.contains(where: \.isWhitespace) == false else {
            throw RealtimeVoiceError.tokenMintFailed(reason: "the Hermes host returned an unexpected mint response.")
        }
        return RealtimeEphemeralToken(value: stdout)
    }

    /// Map the script's exit-code contract onto stable user-facing
    /// reasons. Stderr content is deliberately not surfaced verbatim —
    /// only the fixed markers — so nothing a host-side exception might
    /// embed can leak into the UI.
    private static func failureReason(exitCode: Int32, stderr: String) -> String {
        let firstLine = stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        switch exitCode {
        case 3:
            return "no Python interpreter with Hermes was found on the server."
        case 4:
            return "the server's Hermes installation isn't importable by its Python."
        case 5:
            return "the server could not resolve an OpenAI API key for audio."
        case 6:
            if firstLine.hasPrefix("mint-http-") {
                let status = firstLine.dropFirst("mint-http-".count)
                return "the token mint was rejected by OpenAI (HTTP \(status))."
            }
            return "the token mint request to OpenAI failed."
        case 7:
            return "OpenAI returned an unexpected mint response."
        default:
            return "the mint command on the server failed (exit \(exitCode))."
        }
    }
}
