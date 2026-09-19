import Testing
import Foundation
@testable import ScarfCore

/// The realtime token mint: the generated shell + Python script (pure
/// string construction) and the `HermesHostRealtimeTokenMinter` error
/// contract against a fake transport. Nothing executes, nothing hits
/// the network, and no fixture contains a real secret.
@Suite struct RealtimeTokenMinterTests {

    // MARK: - Script construction

    @Test func shellScriptWrapsQuotedHeredoc() throws {
        let script = RealtimeTokenMintScript.shell(hermesHome: nil, model: "gpt-live-1", voice: "marin")

        // Heredoc fences with a QUOTED delimiter — shell interpolation
        // stays off inside the Python block.
        #expect(script.contains("<<'SCARF_PY'"))
        #expect(script.contains("\nSCARF_PY"))

        // Python candidates probed in order, then the import.
        #expect(script.contains("~/pinokio/api/hermes-agent.pinokio.git/app/.venv/bin/python"))
        #expect(script.contains("python3"))
        #expect(script.contains("command -v"))

        // The secret's only exit is stdout; every failure path is a
        // distinct exit code. Exit 3 is the SHELL probe (no Python);
        // 4–7 are the Python program's own exits.
        #expect(script.contains("sys.stdout.write(token)"))
        #expect(script.contains("echo no-python-found >&2; exit 3"))
        for code in [4, 5, 6, 7] {
            #expect(script.contains("sys.exit(\(code))"))
        }
    }

    @Test func modelAndVoiceAreEmbeddedAsJSONEscapedLiterals() {
        let script = RealtimeTokenMintScript.shell(
            hermesHome: nil,
            model: #"weird"model\name"#,
            voice: #"voice\with"quotes"#
        )
        // A double quote inside the model must arrive JSON-escaped in
        // the Python source — no way for it to terminate the literal
        // and inject code.
        #expect(script.contains(#""weird\"model\\name""#))
        #expect(script.contains(#""voice\\with\"quotes""#))
    }

    @Test func defaultHermesHomeResolvesOnTheHost() {
        let script = RealtimeTokenMintScript.shell(hermesHome: nil, model: "m", voice: "v")
        #expect(script.contains("export HERMES_HOME=$HOME/.hermes"))
    }

    @Test func tildeHermesHomeExpandsThroughHOME() {
        let script = RealtimeTokenMintScript.shell(hermesHome: "~/.hermes", model: "m", voice: "v")
        #expect(script.contains("export HERMES_HOME=$HOME/.hermes"))

        let nested = RealtimeTokenMintScript.shell(hermesHome: "~/profiles/bot", model: "m", voice: "v")
        #expect(nested.contains("export HERMES_HOME=$HOME/profiles/bot"))
    }

    @Test func absoluteHermesHomeIsQuoted() {
        let script = RealtimeTokenMintScript.shell(hermesHome: "/srv/hermes", model: "m", voice: "v")
        #expect(script.contains("export HERMES_HOME=\"/srv/hermes\""))
    }

    @Test func preexistingHermesHomeIsRespected() {
        let script = RealtimeTokenMintScript.shell(hermesHome: "/srv/hermes", model: "m", voice: "v")
        #expect(script.contains("if [ -z \"$HERMES_HOME\" ]"))
    }

    @Test func emptyCandidateListFallsBackToDefaults() {
        let script = RealtimeTokenMintScript.shell(pythonCandidates: [], hermesHome: nil, model: "m", voice: "v")
        #expect(script.contains("python3"))
    }

    // MARK: - Mint execution (fake transport)

    /// Records the script and replies with a canned `ProcessResult`.
    final class MintFakeTransport: ServerTransport, @unchecked Sendable {
        let contextID: ServerID = UUID()
        let isRemote = true
        private let lock = NSLock()
        private var result: ProcessResult
        private(set) var scripts: [String] = []
        var transportError: Error?

        init(result: ProcessResult) { self.result = result }

        func readFile(_ path: String) throws -> Data { Data() }
        func unguardedWriteFile(_ path: String, data: Data) throws {}
        func fileExists(_ path: String) -> Bool { false }
        func stat(_ path: String) -> FileStat? { nil }
        func listDirectory(_ path: String) throws -> [String] { [] }
        func createDirectory(_ path: String) throws {}
        func removeFile(_ path: String) throws {}
        func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval) throws -> ProcessResult {
            result
        }
        #if !os(iOS)
        func makeProcess(executable: String, args: [String]) -> Process { Process() }
        #endif
        func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
            if let transportError { throw transportError }
            lock.withLock { scripts.append(script) }
            return lock.withLock { result }
        }
        func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> { AsyncStream { $0.finish() } }
    }

    private func minter(transport: MintFakeTransport) -> HermesHostRealtimeTokenMinter {
        HermesHostRealtimeTokenMinter(transport: transport)
    }

    @Test func successfulMintReturnsTheSecret() async throws {
        let transport = MintFakeTransport(result: ProcessResult(
            exitCode: 0,
            stdout: Data("ek_fixture_token\n".utf8),
            stderr: Data()
        ))
        let token = try await minter(transport: transport).mintToken(configuration: RealtimeVoiceConfiguration())
        #expect(token.value == "ek_fixture_token")

        // The executed script is the contract: quoted heredoc, key stays
        // host-side, only ek_ on stdout.
        let script = try #require(transport.scripts.first)
        #expect(script.contains("resolve_openai_audio_api_key"))
        #expect(script.contains("client_secrets"))
    }

    @Test func keyResolutionFailureMapsToStableReason() async {
        let transport = MintFakeTransport(result: ProcessResult(
            exitCode: 5,
            stdout: Data(),
            stderr: Data("key-resolution-failed: empty key\n".utf8)
        ))
        await #expect(throws: RealtimeVoiceError.self) {
            _ = try await minter(transport: transport).mintToken(configuration: RealtimeVoiceConfiguration())
        }
    }

    @Test func httpRejectionCarriesTheStatusCode() async throws {
        let transport = MintFakeTransport(result: ProcessResult(
            exitCode: 6,
            stdout: Data(),
            stderr: Data("mint-http-401\n".utf8)
        ))
        do {
            _ = try await minter(transport: transport).mintToken(configuration: RealtimeVoiceConfiguration())
            Issue.record("Expected a tokenMintFailed error")
        } catch let error as RealtimeVoiceError {
            guard case .tokenMintFailed(let reason) = error else {
                Issue.record("Wrong error kind: \(error)")
                return
            }
            #expect(reason.contains("HTTP 401"))
        }
    }

    @Test func nonEkStdoutIsRejected() async {
        // A compromised or misbehaving host answering with something
        // that isn't an ephemeral secret must not be passed downstream.
        let transport = MintFakeTransport(result: ProcessResult(
            exitCode: 0,
            stdout: Data("sk-not-a-session-token\n".utf8),
            stderr: Data()
        ))
        await #expect(throws: RealtimeVoiceError.self) {
            _ = try await minter(transport: transport).mintToken(configuration: RealtimeVoiceConfiguration())
        }
    }

    @Test func transportFailureMapsToTokenMintFailed() async {
        let transport = MintFakeTransport(result: ProcessResult(
            exitCode: 0, stdout: Data(), stderr: Data()
        ))
        transport.transportError = TransportError.other(message: "host unreachable")
        await #expect(throws: RealtimeVoiceError.self) {
            _ = try await minter(transport: transport).mintToken(configuration: RealtimeVoiceConfiguration())
        }
    }

    @Test func tokenRedactsInDescription() {
        let token = RealtimeEphemeralToken(value: "ek_super_secret")
        #expect(!String(describing: token).contains("ek_super_secret"))
        #expect(String(describing: token).contains("redacted"))
    }
}
