import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Phase P9 of the whole-surface audit (charter C5). The app-target half of
/// `HermesCLIOutcomeTests` — the four call sites that live outside ScarfCore.
///
/// Every fixture is the VERBATIM text the named Hermes emitter prints at tag
/// **v2026.9.7** (`git -C ~/.hermes/hermes-agent show v2026.9.7:<path>`), and
/// every one of them arrives with `exitCode == 0` because the handler that
/// printed it is declared `-> None`. Each test fails if the verdict goes back
/// to reading the exit code.
@Suite("Hermes CLI — exit code is not the truth (app surfaces)")
struct HermesCLIExitCodeTruthTests {

    // MARK: - sessions export — hermes_cli/sessions_cmd.py

    /// `_not_found` (sessions_cmd.py:46-48) prints this to **stdout** and
    /// returns 1 — but `_collect_sessions` (:319), `_export_trace` (:392) and
    /// `_export_markdown_single` (:488) all discard that and fall out of a
    /// `-> None` function, so the process exits 0.
    ///
    /// On the `-` (stdout) path, `_write_output` (:78-80) prints no summary at
    /// all, so this refusal text WAS the payload Scarf wrote into the user's
    /// `.jsonl` file — and then reported as a successful export.
    @Test func sessionsExportNotFoundIsNeverWrittenAsAPayload() {
        let refusal = "Session 'abc123' not found.\n"
        let data = Data(refusal.utf8)

        #expect(SessionsViewModel.payloadIsValid(data, format: .jsonl) == false)
        #expect(SessionsViewModel.payloadIsValid(data, format: .trace) == false)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p9-\(UUID().uuidString).jsonl")
        let outcome = SessionsViewModel.writeExport(
            result: (stdout: data, stderr: "", exitCode: 0), to: tmp, format: .jsonl
        )
        #expect(outcome.succeeded == false)
        #expect(outcome.message.contains("not found"))
        // The decisive assertion: nothing reached the user's disk.
        #expect(FileManager.default.fileExists(atPath: tmp.path) == false)
        try? FileManager.default.removeItem(at: tmp)
    }

    /// A real `_render_jsonl` payload (sessions_cmd.py:355-357) — one JSON
    /// object per line — must still be written.
    @Test func sessionsExportRealJSONLPayloadIsWritten() {
        let payload = """
        {"id":"abc123","source":"cli","messages":[{"role":"user","content":"hi"}]}
        {"id":"def456","source":"telegram","messages":[]}

        """
        let data = Data(payload.utf8)
        #expect(SessionsViewModel.payloadIsValid(data, format: .jsonl))

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p9-\(UUID().uuidString).jsonl")
        let outcome = SessionsViewModel.writeExport(
            result: (stdout: data, stderr: "", exitCode: 0), to: tmp, format: .jsonl
        )
        #expect(outcome.succeeded)
        #expect((try? Data(contentsOf: tmp)) == data)
        try? FileManager.default.removeItem(at: tmp)
    }

    /// An empty export is a real outcome (no sessions matched the filters), not
    /// a refusal — refusing to write it would be the regression. So is one led
    /// by blank lines, which is why the scan skips leading whitespace before it
    /// picks the line to validate.
    @Test(arguments: ["", "\n", "  \n\n"])
    func sessionsExportEmptyPayloadIsStillAnExport(fixture: String) {
        #expect(SessionsViewModel.payloadIsValid(Data(fixture.utf8), format: .jsonl))
    }

    /// A leading blank line must not let a refusal past the check.
    @Test func sessionsExportRefusalAfterBlankLinesIsStillRejected() {
        let fixture = "\n\nSession 'abc123' not found.\n"
        #expect(SessionsViewModel.payloadIsValid(Data(fixture.utf8), format: .jsonl) == false)
    }

    /// `md`/`qmd`/`html` never take the stdout path — the CLI writes the file
    /// itself — so the JSON-shape check must not be applied to them.
    @Test func sessionsExportPayloadCheckOnlyAppliesToStdoutFormats() {
        let notJSON = Data("# Session abc123\n\nHello.\n".utf8)
        #expect(SessionsViewModel.payloadIsValid(notJSON, format: .markdown))
        #expect(SessionsViewModel.payloadIsValid(notJSON, format: .jsonl) == false)
    }

    /// The `--output <path>` formats (`html`/`md`/`qmd`) exit 0 on every
    /// refusal too. Verbatim refusals from `_export_markdown` (:443, :456,
    /// :459, :465-466), `_FLAT_EXPORTERS` (:365) and `_not_found` (:47),
    /// against the `Exported …` summary every success path prints
    /// (`_write_output`, :83, and :424 / :434 / :480 / :508).
    @Test(arguments: [
        "Session 'abc123' not found.\n",
        "HTML export requires an output file path.\n",
        "Markdown/QMD export writes files; stdout (-) is only supported with --format jsonl.\n",
        "Refusing bulk export without a filter. Pass --session-id or at least one filter (e.g. --older-than 90, --source telegram).\n",
        "--delete-after-verified requires --yes.\n",
        "Skipping existing export: /tmp/x.md. Pass --force to overwrite.\n",
    ])
    func sessionsPathExportRefusalsAtExitZeroAreFailures(fixture: String) {
        let outcome = SessionsViewModel.pathExportOutcome(
            result: (stdout: Data(fixture.utf8), stderr: "", exitCode: 0)
        )
        #expect(outcome.succeeded == false)
        #expect(outcome.detail?.isEmpty == false)
    }

    /// sessions_cmd.py:508 — the `--session-id` markdown success summary.
    @Test func sessionsPathExportSummaryLineIsTheSuccessLine() {
        let fixture = "Exported 1 session (42 messages) to /Users/a/exports/abc123.md\n"
        #expect(SessionsViewModel.pathExportOutcome(
            result: (stdout: Data(fixture.utf8), stderr: "", exitCode: 0)
        ).succeeded)
    }

    // MARK: - mcp login — hermes_cli/mcp_config.py

    /// `cmd_mcp_login` (mcp_config.py:709-713) calls `_reauth_oauth_server` and
    /// DISCARDS the `bool` it returns, so every OAuth failure exits 0 and the
    /// sheet said "Signed in."
    ///
    /// The `_error` / `_warning` helpers (:35-36) prefix `  ✗ ` / `  ⚠ `.
    @Test(arguments: [
        // _lookup_server (:104) — cmd_mcp_login then does nothing at all
        "  ✗ Server 'notion' not found in config.\n  Available servers: linear, sentry\n",
        // :631
        "  ✗ Server 'notion' has no URL — not an OAuth-capable server\n",
        // :634-635
        "  ✗ Server 'notion' is not configured for OAuth (auth=bearer)\n  Use `hermes mcp remove` + `hermes mcp add` to reconfigure auth.\n",
        // :641
        "  ✗ oauth.flow must be browser or device\n",
        // :705
        "\n  Starting OAuth flow for 'notion'...\n  ✗ Authentication failed: dynamic client registration returned HTTP 400\n",
    ])
    func mcpLoginFailuresAtExitZeroAreNotSignedIn(fixture: String) {
        let outcome = MCPLoginController.loginOutcome(exitCode: 0, output: fixture)
        #expect(outcome.succeeded == false)
        #expect(outcome.detail?.isEmpty == false)
    }

    /// The subtle one (mcp_config.py:673-693): some servers serve
    /// `initialize` + `tools/list` WITHOUT auth, so the probe succeeds and the
    /// run looks perfect — but no token landed. Hermes says so and returns
    /// False; the sheet used to say "Signed in."
    ///
    /// Note the remediation block printed AFTER the reason (:679-692) — this is
    /// why the verdict must not simply quote the last line.
    @Test func mcpLoginProbeSucceededButNoTokenIsAFailure() {
        let fixture = """
          Starting OAuth flow for 'gdrive'...
          ⚠ Server responded, but no OAuth token was obtained — authentication did not complete.

          Some providers (e.g. Google Drive, Atlassian) do not support automatic client registration. For those you must create an OAuth client yourself and add its credentials to config.yaml:

            mcp_servers:
              gdrive:
                url: https://mcp.example.com/sse
                auth: oauth
                oauth:
                  client_id: "<your-oauth-client-id>"
                  client_secret: "<your-oauth-client-secret>"

          Then re-run `hermes mcp login gdrive`.
        """
        let outcome = MCPLoginController.loginOutcome(exitCode: 0, output: fixture)
        #expect(outcome.succeeded == false)
        #expect(outcome.detail?.contains("no OAuth token was obtained") == true)
    }

    /// `_success` (:34) printing :695 / :697 — the only two success lines.
    @Test(arguments: [
        "  Starting OAuth flow for 'linear'...\n  ✓ Authenticated — 14 tool(s) available\n",
        "  Starting OAuth flow for 'linear'...\n  ✓ Authenticated (server reported no tools)\n",
    ])
    func mcpLoginSuccessLines(fixture: String) {
        #expect(MCPLoginController.loginOutcome(exitCode: 0, output: fixture).succeeded)
    }

    // MARK: - cron run — hermes_cli/cron.py

    /// `_job_action` (cron.py:635-663) prints the GREEN `Triggered job:` line
    /// (:658, verb from `_JOB_ACTIONS` :763) and THEN `_run_outcome`'s verdict
    /// (:662). For a synchronous failure that verdict is `Ran now: failed.`
    /// (:677) — and `_job_action` still `return 0`s.
    ///
    /// This is the one site where a failure marker must beat a success marker
    /// that is genuinely present in the same output.
    @Test func cronRanNowFailedIsAFailureDespiteTheGreenTriggeredLine() {
        let fixture = """
        Triggered job: Nightly backup (nightly-backup)
          Ran now: failed.
        """
        let outcome = CronViewModel.runOutcome(exitCode: 0, output: fixture)
        #expect(outcome.succeeded == false)
        #expect(outcome.detail?.contains("Ran now: failed.") == true)
    }

    /// The three outcomes that ARE successes: a synchronous success (:677), a
    /// background dispatch (:673-675) and a deferred run (:678). None of them
    /// may regress to "Run failed to queue".
    @Test(arguments: [
        "Triggered job: Nightly backup (nightly-backup)\n  Ran now: succeeded.\n",
        "Triggered job: Digest (digest-1)\n  Running in background (delegation d-88).\n",
        "Triggered job: Digest (digest-1)\n  Running in background.\n",
        "Triggered job: Digest (digest-1)\n  It will run on the next scheduler tick.\n",
        // v0.17 (v2026.6.19:350) printed no `Ran now:` line at all — charter C1.
        "Triggered job: Digest (digest-1)\n",
    ])
    func cronSuccessfulRunsStaySuccessful(fixture: String) {
        #expect(CronViewModel.runOutcome(exitCode: 0, output: fixture).succeeded)
    }

    /// `_job_action`'s only nonzero arm (cron.py:654-656).
    @Test func cronFailedToRunIsAFailure() {
        let fixture = "Failed to run job: no job matching 'digest-9'\n"
        let outcome = CronViewModel.runOutcome(exitCode: 1, output: fixture)
        #expect(outcome.succeeded == false)
        #expect(outcome.detail?.contains("Failed to run job:") == true)
    }

    // MARK: - plugins enable — hermes_cli/plugins_cmd.py

    /// `cmd_enable` (plugins_cmd.py:1033) calls `_run_capability_consent` and
    /// discards its `bool`. On a non-TTY — which Scarf ALWAYS is — that
    /// function takes the :1092-1098 arm, prints this, and returns False. The
    /// plugin lands on the allow-list but runs without the host surfaces it
    /// declared, which "Enabled" does not say.
    @Test @MainActor func pluginsEnableNonInteractiveConsentRefusalIsAFailure() async {
        let fixture = """
        ✓ Plugin web/firecrawl enabled. Takes effect on next session.

          Plugin web/firecrawl requests the following capabilities:
            tools.override — replace built-in tools
          Granting trusts the plugin author with these host surfaces. This is consent, not a sandbox — plugins run as regular Python in-process.
          Non-interactive session: capabilities NOT granted (fail closed). Run `hermes plugins capabilities web/firecrawl` to review and `hermes plugins enable web/firecrawl` to grant interactively.
        """
        let vm = Self.pluginsViewModel(returning: fixture, exitCode: 0)
        vm.enable(Self.plugin("web/firecrawl"))
        let message = await Self.awaitMessage(on: vm)

        // The verdict rules (markers + `failureWins`) live in `enable` itself,
        // so this has to run through `enable` — a test that passes
        // `failureWins: true` to `HermesCLIVerdict.judge` by hand stays green
        // even when the production call site loses it.
        #expect(vm.messageIsFailure)
        #expect(message?.contains("NOT granted") == true)
        // The banner keeps the remedy — the refusal line's actionable half is
        // its LAST clause, so a leading truncation would have thrown it away.
        #expect(message?.contains("terminal") == true)
        // …and it is prose, not a re-indented multi-line literal.
        #expect(message?.contains("   ") == false)
    }

    /// A plugin with no `capabilities:` declaration runs no consent screen
    /// (plugins_cmd.py:1031-1037), and the idempotent re-enable (:1012) is a
    /// success too — neither may regress.
    @Test(arguments: [
        "✓ Plugin web/tavily enabled. Takes effect on next session.\n",
        "Plugin \'web/tavily\' is already enabled.\n",
    ])
    @MainActor func pluginsEnableSuccessLines(fixture: String) async {
        let vm = Self.pluginsViewModel(returning: fixture, exitCode: 0)
        vm.enable(Self.plugin("web/tavily"))
        let message = await Self.awaitMessage(on: vm)
        #expect(vm.messageIsFailure == false)
        #expect(message == "Enabled")
    }

    /// `plugins disable` has no consent screen, so its failure markers must
    /// NOT win over a success line — the mirror of the enable case.
    @Test @MainActor func pluginsDisableSuccessLine() async {
        let vm = Self.pluginsViewModel(returning: "✓ Plugin web/tavily disabled. Takes effect on next session.\n", exitCode: 0)
        vm.disable(Self.plugin("web/tavily"))
        let message = await Self.awaitMessage(on: vm)
        #expect(vm.messageIsFailure == false)
        #expect(message == "Disabled")
    }

    // MARK: - plugins test helpers

    /// A `PluginsViewModel` whose CLI seam answers with one canned result and
    /// whose home is an empty temp dir, so the post-run `load(force:)` reads
    /// nothing on the developer's machine.
    @MainActor private static func pluginsViewModel(returning output: String, exitCode: Int32) -> PluginsViewModel {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-plugins-\(UUID().uuidString)")
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

    /// The verdict is committed from a detached task hopping back to the main
    /// actor; poll rather than sleep a fixed interval.
    @MainActor private static func awaitMessage(on vm: PluginsViewModel) async -> String? {
        for _ in 0..<400 {
            if let message = vm.message { return message }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return vm.message
    }

    // MARK: - security audit — hermes_cli/security_audit.py

    /// The threshold that produces the exit code must be Scarf's choice, not a
    /// Hermes default that could move (`--fail-on` default `critical`,
    /// hermes_cli/subcommands/security.py:26 at v2026.9.7, and identically at
    /// v2026.6.19:41-44 so a pre-target host is unaffected — charter C1/C2).
    /// The verb is `security audit`; bare `hermes audit` routes to the agent.
    @Test func securityAuditArgvPinsTheFailOnThreshold() {
        #expect(HealthViewModel.auditArgs == ["security", "audit", "--fail-on", "critical"])
    }
}
