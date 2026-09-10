import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Phase P21 of the round-2 whole-surface audit — the app-target half.
/// Fixtures are VERBATIM emitter text at tag **v2026.9.7**
/// (`git -C ~/.hermes/hermes-agent show v2026.9.7:<path>`).
@Suite("Audit P21 — output-verdict correctness (app surfaces)")
struct AuditP21VerdictTests {

    // MARK: - mcp login: drain to EOF before judging

    /// A SUCCESSFUL login could be reported as a failure.
    ///
    /// `cmd_mcp_login` (mcp_config.py:709-713) discards
    /// `_reauth_oauth_server`'s bool, so P9 made the verdict depend on the
    /// `✓ Authenticated …` line (:695, :697) — and that line is written
    /// immediately before the process exits. The old termination handler nil'd
    /// the reader's `readabilityHandler` and judged on the spot, so on the
    /// losing side of the race the chunk carrying the success line was never
    /// read at all (and P12's EOF `decoder.flush()` was unreachable).
    ///
    /// This drives the real `start()` with a real `Process` and a real pipe.
    /// The fake `hermes` backgrounds the write into a SUBSHELL that inherits
    /// stdout, so the parent exits first and the success line arrives strictly
    /// AFTER termination — the failing interleaving, deterministically.
    @Test @MainActor func mcpLoginSuccessLineArrivingAfterTerminationStillWins() async throws {
        let script = """
        printf 'Starting OAuth device flow for notion...\\n'
        ( sleep 0.3; printf '  \\342\\234\\223 Authenticated \\342\\200\\224 7 tool(s) available\\n' ) &
        exit 0
        """
        let controller = MCPLoginController(context: .local) { _ in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", script]
            return proc
        }
        controller.start(server: "notion", flow: "device")

        // The parent exits almost immediately; the line lands ~0.3 s later.
        for _ in 0..<400 where controller.succeeded == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(controller.output.contains("Authenticated"))
        #expect(controller.succeeded == true)
        #expect(controller.errorMessage == nil)
        #expect(controller.isRunning == false)
    }

    /// The other half of the same seam: a real exit-0 FAILURE must still be a
    /// failure once the drain completes. `_error` prints
    /// `no OAuth token was obtained — authentication did not complete.`
    /// (mcp_config.py:677) and `cmd_mcp_login` exits 0 anyway.
    @Test @MainActor func mcpLoginExitZeroRefusalIsStillAFailureAfterTheDrain() async throws {
        let script = """
        ( sleep 0.2; printf '  \\342\\234\\227 notion: no OAuth token was obtained \\342\\200\\224 authentication did not complete.\\n' ) &
        exit 0
        """
        let controller = MCPLoginController(context: .local) { _ in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", script]
            return proc
        }
        controller.start(server: "notion", flow: nil)
        for _ in 0..<400 where controller.succeeded == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(controller.succeeded == false)
        #expect(controller.errorMessage?.contains("no OAuth token was obtained") == true)
    }

    /// EOF alone is not the signal: the verdict also needs the exit status,
    /// or a run that closed its pipe early would be judged while the process
    /// was still deciding what to exit with.
    ///
    /// Deterministic by construction rather than by timing — the fake `hermes`
    /// closes both descriptors (so the reader reaches EOF and the success line
    /// is fully drained) and then BLOCKS until this test creates a file. It
    /// therefore cannot exit before the "not judged yet" assertion runs, at
    /// any machine load.
    @Test @MainActor func mcpLoginVerdictWaitsForTheExitStatusToo() async throws {
        let gate = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p21-gate-\(UUID().uuidString)")
        let script = """
        printf '  \\342\\234\\223 Authenticated (server reported no tools)\\n'
        exec 1>&- 2>&-
        while [ ! -f '\(gate.path)' ]; do sleep 0.02; done
        exit 0
        """
        let controller = MCPLoginController(context: .local) { _ in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", script]
            return proc
        }
        controller.start(server: "notion", flow: nil)

        // Wait for the drain, not for the clock: EOF has landed once the
        // success line is in `output`.
        for _ in 0..<600 where !controller.output.contains("Authenticated") {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(controller.output.contains("Authenticated"))
        // The process is still alive on the gate, so nothing may be decided.
        #expect(controller.succeeded == nil)
        #expect(controller.isRunning)

        try Data().write(to: gate)
        for _ in 0..<600 where controller.succeeded == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(controller.succeeded == true)
        #expect(controller.isRunning == false)
        try? FileManager.default.removeItem(at: gate)
    }

    // MARK: - pairing list: the two hint lines are not pairings

    /// `_cmd_list` prints two hints after the pending block
    /// (hermes_cli/pairing.py:38-39). They sit INSIDE the pending section and
    /// have a row's shape, so they parsed as two pending pairings — each with
    /// a live "Approve" button that would run
    /// `hermes pairing approve Approve with:`.
    ///
    /// Fixture rendered from the tag's own f-strings: `{:<12}` / `{:<18}` /
    /// `{:<20}` / `{:<20}` columns at indent 2 (`pairing.py:32-37`).
    @Test func pairingHintLinesAreNotPendingPairings() {
        let output = """

          Pending Pairing Requests (1):
          Platform     Request ID         User ID              Name                 Age
          --------     ----------         -------              ----                 ---
          telegram     req-7f3a           4815162342           Ada Lovelace         3m ago

          Approve with: hermes pairing approve <platform> <request-id>
          The code the bot DM'd the user also works if they relay it.

          Approved Users (2):
          Platform     User ID              Name
          --------     -------              ----
          telegram     90210                Grace Hopper
          slack        U0ABCDEF

        """
        let result = MessagingGatewayViewModel.parsePairing(output: output)

        #expect(result.pending.count == 1)
        #expect(result.pending.first?.platform == "telegram")
        #expect(result.pending.first?.code == "req-7f3a")
        #expect(result.pending.contains { $0.platform == "Approve" } == false)
        #expect(result.pending.contains { $0.platform == "The" } == false)

        // And the 2-token approved row — `user_name` is
        // `a.get("user_name") or ""` (pairing.py:48), so a user who never set
        // a display name yielded two tokens and was dropped entirely:
        // invisible in the list, and impossible to revoke.
        #expect(result.approved.count == 2)
        #expect(result.approved.map { $0.userId } == ["90210", "U0ABCDEF"])
        #expect(result.approved.last?.name == "")
    }

    /// The empty sections (`pairing.py:42`, `:52`) must not become rows
    /// either — the headers the section tracker keys off are capitalised.
    @Test func emptyPairingSectionsParseToNothing() {
        let result = MessagingGatewayViewModel.parsePairing(output: """

          No pending pairing requests.

          No approved users.

        """)
        #expect(result.pending.isEmpty)
        #expect(result.approved.isEmpty)
    }

    // MARK: - plugins install / update: the discarded consent bool

    /// `cmd_update` (plugins_cmd.py:822) calls `_run_capability_consent(...)`
    /// and discards the bool exactly as `cmd_enable` (:1033) does — round 1
    /// only caught `enable`. Scarf has no TTY, so :1092-1098 is the arm it
    /// always takes, and the success lines (:826, :828) are printed AFTER it.
    ///
    /// This runs through `update` itself, so reverting the call site's markers
    /// or its `failureWins` makes it fail.
    @Test @MainActor func pluginsUpdateConsentRefusalIsAFailure() async {
        let fixture = """
        Updating web/firecrawl...

          Plugin web/firecrawl now requests the following capabilities:
            tools.override — replace built-in tools
          Granting trusts the plugin author with these host surfaces. This is consent, not a sandbox — plugins run as regular Python in-process.
          Non-interactive session: capabilities NOT granted (fail closed). Run `hermes plugins capabilities web/firecrawl` to review and `hermes plugins enable web/firecrawl` to grant interactively.
        ✓ Plugin web/firecrawl updated.
        Updating 3 files, 21 insertions(+)
        """
        let vm = Self.pluginsViewModel(returning: fixture, exitCode: 0)
        vm.update(Self.plugin("web/firecrawl"))
        let message = await Self.awaitMessage(on: vm)
        #expect(vm.messageIsFailure)
        #expect(message?.contains("NOT granted") == true)
        // Verb-neutral: the same screen runs from install/enable/update.
        #expect(message?.hasPrefix("Enabled") == false)
    }

    /// A plugin that declares no capabilities runs no consent screen, and the
    /// already-up-to-date line (:826) is a success too. Both lines go back to
    /// v2026.6.19, so a pre-target host is judged identically (C1).
    @Test(arguments: [
        "✓ Plugin web/tavily updated.\nFast-forward\n",
        "✓ Plugin web/tavily is already up to date.\n",
    ])
    @MainActor func pluginsUpdateSuccessLines(fixture: String) async {
        let vm = Self.pluginsViewModel(returning: fixture, exitCode: 0)
        vm.update(Self.plugin("web/tavily"))
        let message = await Self.awaitMessage(on: vm)
        #expect(vm.messageIsFailure == false)
        #expect(message == "Updated")
    }

    /// `cmd_install` (plugins_cmd.py:764) discards the same bool, and the
    /// install path reports through `HermesPluginInstallOutcome` rather than
    /// `HermesCLIVerdict`, so it needs its own signal.
    @Test func pluginsInstallParsesTheConsentRefusal() {
        let granted = HermesPluginInstallOutcome.parse("""
        ✓ Plugin web/tavily enabled.
        Restart the gateway for the plugin to take effect:
          hermes gateway restart
        """)
        #expect(granted.capabilitiesNotGranted == false)
        #expect(granted.enabled)

        let refused = HermesPluginInstallOutcome.parse("""
        ✓ Plugin web/firecrawl enabled.
          Plugin web/firecrawl requests the following capabilities:
            tools.override — replace built-in tools
          Non-interactive session: capabilities NOT granted (fail closed). Run `hermes plugins capabilities web/firecrawl` to review and `hermes plugins enable web/firecrawl` to grant interactively.
        Restart the gateway for the plugin to take effect:
        """)
        #expect(refused.capabilitiesNotGranted)
        // The install DID happen and the plugin IS enabled — what is wrong is
        // reporting that as an unqualified success.
        #expect(refused.enabled)
    }

    /// `cmd_remove`'s only refusal is `_fail` (plugins_cmd.py:895 → :80-83),
    /// which exits 1 — so the exit code is a sound verdict there, but it is
    /// not the MESSAGE. The old exit-code arm passed `detail: nil` and left
    /// the user a bare "Failed".
    @Test @MainActor func pluginsRemoveForwardsTheFailureLine() async {
        let vm = Self.pluginsViewModel(
            returning: "Error: Could not remove plugin 'web/tavily': [Errno 13] Permission denied\n",
            exitCode: 1
        )
        vm.remove(Self.plugin("web/tavily"))
        let message = await Self.awaitMessage(on: vm)
        #expect(vm.messageIsFailure)
        #expect(message?.contains("Could not remove plugin") == true)
        #expect(message != "Failed")
    }

    // MARK: - plugins test helpers (mirrors HermesCLIExitCodeTruthTests)

    @MainActor private static func pluginsViewModel(returning output: String, exitCode: Int32) -> PluginsViewModel {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p21-plugins-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return PluginsViewModel(
            context: .local(home: home),
            cliRunner: { _, _ in (output, exitCode) }
        )
    }

    private static func plugin(_ name: String) -> HermesPlugin {
        HermesPlugin(
            name: name, source: name, activation: .enabled,
            description: "", version: "", path: "", toolOverride: false
        )
    }

    @MainActor private static func awaitMessage(on vm: PluginsViewModel) async -> String? {
        for _ in 0..<400 {
            if let message = vm.message { return message }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return vm.message
    }
}
