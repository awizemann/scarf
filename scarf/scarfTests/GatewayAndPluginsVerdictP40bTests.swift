import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P40b — the app-target half of the review of P40's four commits.
@Suite("GatewayAndPluginsVerdictP40b")
struct GatewayAndPluginsVerdictP40bTests {

    // MARK: - stopHermes' kill fallback

    /// Answers `runProcess` from a script and records every call, so a test
    /// can assert what Scarf DIDN'T run.
    final class ScriptedTransport: ServerTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(exe: String, args: [String])] = []
        private let answer: @Sendable (String, [String]) -> ProcessResult

        var calls: [(exe: String, args: [String])] {
            lock.lock(); defer { lock.unlock() }; return _calls
        }

        init(answer: @escaping @Sendable (String, [String]) -> ProcessResult) {
            self.answer = answer
        }

        let contextID: ServerID = UUID()
        var isRemote: Bool { true }
        func readFile(_ path: String) throws -> Data { Data() }
        func unguardedWriteFile(_ path: String, data: Data) throws {}
        func fileExists(_ path: String) -> Bool { false }
        func stat(_ path: String) -> FileStat? { nil }
        func statAll(_ paths: [String]) -> [String: FileStat]? { nil }
        func listDirectory(_ path: String) throws -> [String] { [] }
        func createDirectory(_ path: String) throws {}
        func removeFile(_ path: String) throws {}
        func runProcess(
            executable: String, args: [String], stdin: Data?, timeout: TimeInterval
        ) throws -> ProcessResult {
            lock.lock(); _calls.append((executable, args)); lock.unlock()
            return answer(executable, args)
        }
        func makeProcess(executable: String, args: [String]) -> Process { Process() }
        func makeProcess(executable: String, args: [String], cwd: String?) -> Process { Process() }
        func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
            AsyncStream { $0.finish() }
        }
        func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
            answer("sh", [script])
        }
        func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// A remote context, so `runHermesCLI` uses `context.paths.hermesBinary`
    /// rather than probing the test machine for a real `hermes`.
    private static func remoteContext() -> ServerContext {
        ServerContext(
            id: UUID(), displayName: "Box",
            kind: .ssh(SSHConfig(host: "box.local", hermesBinaryHint: "/usr/local/bin/hermes"))
        )
    }

    private static func result(_ stdout: String, _ exit: Int32) -> ProcessResult {
        ProcessResult(
            exitCode: exit,
            stdout: Data(stdout.utf8),
            stderr: Data()
        )
    }

    /// THE finding. `_dispatch_via_service_manager_if_s6`
    /// (`hermes_cli/gateway.py:5608-5629` @ v2026.9.7) dispatches `stop` to
    /// the s6 service manager and prints NOTHING on success, so the verdict
    /// is "could not confirm". P40 fell through to `pgrep` + `kill -TERM` on
    /// that — and `s6-supervise` reads a bare SIGTERM as a crash and restarts
    /// the gateway ~1s later (Hermes says so itself at `:5631-5635`).
    @Test func anUnconfirmedStopNeverReachesTheKillFallback() {
        // `hermes gateway stop` → silence at exit 0 (the s6 dispatch).
        // Anything else reaching this transport would BE the fallback, and
        // there must not be one.
        let transport = ScriptedTransport { _, _ in Self.result("", 0) }
        let service = HermesFileService(context: Self.remoteContext(), transport: transport)
        let outcome = service.stopHermes()

        #expect(outcome.succeeded == false)
        #expect(outcome.confidence == .unconfirmed)
        let ranPgrep = transport.calls.contains { $0.exe.contains("pgrep") }
        let ranKill = transport.calls.contains { $0.exe.contains("kill") }
        #expect(ranPgrep == false, "an unconfirmed stop must not probe for a PID to signal")
        #expect(ranKill == false, "SIGTERM on an s6 host is read as a crash and undoes the stop")
    }

    /// The other branch: a POSITIVE failure signal still earns the fallback,
    /// which is what it was always for.
    @Test func aPositivelyFailedStopStillFallsBackToTheKill() {
        let transport = ScriptedTransport { exe, _ in
            if exe.hasSuffix("hermes") {
                // A column-0 refusal at a non-zero exit: `_refuse_from_inside_gateway`
                // (`gateway.py:5776-5781`) via `print_error` → `sys.exit(1)`.
                return Self.result("✗ Refusing to stop the gateway from inside the gateway process.", 1)
            }
            if exe.contains("pgrep") { return Self.result("4812\n", 0) }
            return Self.result("", 0)   // /bin/kill
        }
        let service = HermesFileService(context: Self.remoteContext(), transport: transport)
        let outcome = service.stopHermes()

        #expect(outcome.succeeded, "the fallback SIGTERM landed, so the stop did happen")
        #expect(transport.calls.contains { $0.exe.contains("pgrep") })
        let kill = transport.calls.first { $0.exe.contains("kill") }
        #expect(kill?.args.first == "-TERM")
    }

    /// A confirmed stop short-circuits before either probe, as before.
    @Test func aConfirmedStopRunsNothingElse() {
        let transport = ScriptedTransport { _, _ in Self.result("✓ Service stopped", 0) }
        let service = HermesFileService(context: Self.remoteContext(), transport: transport)
        #expect(service.stopHermes().succeeded)
        #expect(transport.calls.count == 1)
    }

    // MARK: - the analytics tri-state

    /// Round-4 decision 5: the facade carries a third token rather than
    /// laundering "could not confirm" into `failed`.
    @Test(arguments: [
        (HermesCLIOutcome.Confidence.confirmed, "succeeded"),
        (.unconfirmed, "unconfirmed"),
        (.failed, "failed"),
    ])
    func theOutcomeTokenIsThreeValued(confidence: HermesCLIOutcome.Confidence, token: String) {
        #expect(UsageEvent.Outcome(confidence).rawValue == token)
    }

    /// The bool initialiser is untouched, so every other event keeps its
    /// two-token vocabulary.
    @Test func theBoolInitialiserStillOnlyProducesTwoTokens() {
        #expect(UsageEvent.Outcome(succeeded: true) == .succeeded)
        #expect(UsageEvent.Outcome(succeeded: false) == .failed)
    }

    /// A restart is two verdicts: `failed` if either half positively failed,
    /// `confirmed` only if both confirmed, `unconfirmed` in between.
    @Test(arguments: [
        (HermesCLIOutcome.Confidence.confirmed, HermesCLIOutcome.Confidence.confirmed,
         HermesCLIOutcome.Confidence.confirmed),
        (.confirmed, .unconfirmed, .unconfirmed),
        (.unconfirmed, .confirmed, .unconfirmed),
        (.unconfirmed, .unconfirmed, .unconfirmed),
        (.failed, .confirmed, .failed),
        (.confirmed, .failed, .failed),
        (.unconfirmed, .failed, .failed),
    ])
    func aRestartCombinesItsTwoHalves(
        stop: HermesCLIOutcome.Confidence,
        start: HermesCLIOutcome.Confidence,
        expected: HermesCLIOutcome.Confidence
    ) {
        #expect(HermesCLIOutcome.Confidence.combined(stop, start) == expected)
    }

    // MARK: - the OAuth verdict

    /// `auth add <provider> --type oauth` reaches
    /// `run_hermes_oauth_login_pure` (`agent/anthropic_credentials.py`),
    /// whose three refusals print at column 0: `No code entered.` (`:546`),
    /// `Token exchange failed: {exc}` (`:560`) and
    /// `No access token in response.` (`:563`).
    @Test(arguments: [
        "Token exchange failed: HTTP Error 400: Bad Request",
        "No code entered.",
        "No access token in response.",
        "Anthropic OAuth login did not return credentials.",
    ])
    func aColumnZeroRefusalIsSeen(line: String) {
        #expect(OAuthFlowController.outputSaysFailed("Authorization code:\n\(line)\n"))
    }

    /// The regression the anchoring exists for: the flow echoes whatever the
    /// provider's page and the user's own paste contain, and a bare
    /// case-insensitive `contains` over the whole blob matched a success run.
    @Test(arguments: [
        "  the docs explain what to do when token exchange failed on a retry",
        "Visit https://example.com/help#http-error-404 for help",
        "HTTP Error is explained in the troubleshooting guide",
        "✓ Added anthropic OAuth credential #1: \"claude-max\"",
    ])
    func aMidLineEchoIsNotARefusal(line: String) {
        #expect(OAuthFlowController.outputSaysFailed("Authorization code:\n\(line)\n") == false)
    }

    /// The one deliberately-unanchored marker, and the reason it is
    /// unanchored: `SystemExit`'s sentence leads with the provider name
    /// (`hermes_cli/auth_commands.py:185`).
    @Test func theSystemExitSentenceIsMatchedAsASubstringOnPurpose() {
        #expect(OAuthFlowController.substringFailureMarkers == ["did not return credentials"])
        #expect(OAuthFlowController.anchoredFailureMarkers.contains("Token exchange failed"))
        // The two retired markers must not come back: `HTTP Error` only ever
        // arrives inside `Token exchange failed: …`, and `OAuth login failed`
        // has no emitter on this argv at v2026.9.7.
        let all = OAuthFlowController.anchoredFailureMarkers
            + OAuthFlowController.substringFailureMarkers
        #expect(all.contains("HTTP Error") == false)
        #expect(all.contains("OAuth login failed") == false)
    }

    // MARK: - the migrate hint on a managed host

    /// `_cmd_config_migrate` (`hermes_cli/config.py:3653` @ v2026.9.7) reaches
    /// `save_config`, whose managed arm refuses at exit 0 (`:2315-2318`). The
    /// terminal hint names a command that cannot work there, so a managed host
    /// gets different copy (round-4 lesson 3: a hint that names a remedy is
    /// walked like a button).
    @MainActor @Test func aManagedHostGetsADifferentMigrateHint() {
        let managed = AdvancedTab.migrateHint(
            isManagedHost: true, isRemote: false, hostName: "Box"
        )
        #expect(managed.contains("managed"))
        #expect(managed.contains("Run `hermes config migrate` in a terminal") == false,
                "a managed host cannot run it — the hint must not send them there")
    }

    @MainActor @Test func anUnmanagedHostStillGetsTheTerminalHint() {
        let local = AdvancedTab.migrateHint(isManagedHost: false, isRemote: false, hostName: "Box")
        #expect(local.contains("in a terminal"))
        let remote = AdvancedTab.migrateHint(isManagedHost: false, isRemote: true, hostName: "Box")
        #expect(remote.contains("Box"), "a remote host has to be named — the Mac is the wrong machine")
    }
}
