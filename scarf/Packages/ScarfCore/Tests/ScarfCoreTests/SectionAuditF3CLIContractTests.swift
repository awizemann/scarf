import Testing
import Foundation
@testable import ScarfCore

/// F3 — CLI-contract rewrites for Plugins / Webhooks / Profiles / MCP add.
///
/// Every fixture in this file is transcribed from the emitting Python at
/// tag `v2026.8.31` (Hermes v0.21.0), not from memory:
///
/// * `hermes_cli/plugins_cmd.py::cmd_list` / `_plugin_status` / `cmd_install`
/// * `hermes_cli/webhook.py::_cmd_list`
/// * `hermes_cli/profiles.py::export_profile`
/// * `hermes_cli/mcp_config.py::cmd_mcp_add`
@Suite("F3 CLI contracts")
struct SectionAuditF3CLIContractTests {

    // MARK: - Plugins

    /// Exact shape of `json.dumps(payload, indent=2)` from `cmd_list`.
    static let pluginsListJSON = """
    [
      {
        "description": "Control Chrome profiles from the agent",
        "name": "chrome-profiles",
        "source": "git",
        "status": "enabled",
        "version": "1.2.0"
      },
      {
        "description": "Noisy experiment",
        "name": "loud",
        "source": "git",
        "status": "disabled",
        "version": "0.1.0"
      },
      {
        "description": "Ships with Hermes",
        "name": "langfuse",
        "source": "bundled",
        "status": "not enabled",
        "version": "0.21.0"
      }
    ]
    """

    @Test("plugins list --json decodes all three activation states")
    func pluginsListJSONDecodes() throws {
        let entries = try #require(HermesPluginList.parseJSON(Self.pluginsListJSON))
        #expect(entries.count == 3)
        #expect(entries[0].name == "chrome-profiles")
        #expect(entries[0].status == .enabled)
        #expect(entries[0].version == "1.2.0")
        #expect(entries[1].status == .disabled)
        // "not enabled" is a real third state, not a synonym for enabled.
        #expect(entries[2].status == .notEnabled)
        #expect(entries[2].status.isActive == false)
        #expect(entries[2].source == "bundled")
    }

    @Test("unparseable plugin output yields nil, never an empty list")
    func pluginsListJSONFailsClosed() {
        // A pre-v0.16 host rejects `--json` at argparse time; the error
        // text must not be read as "no plugins installed".
        #expect(HermesPluginList.parseJSON("usage: hermes plugins list [-h]\nerror: unrecognized arguments: --json") == nil)
        #expect(HermesPluginList.parseJSON("") == nil)
    }

    @Test("config.yaml fallback reads plugins.enabled / plugins.disabled")
    func pluginConfigFallback() {
        let yaml = """
        model: nous/hermes-4
        plugins:
          enabled:
          - chrome-profiles
          - "observability/langfuse"
          disabled:
            - loud
          scan_on_install: true
        gateway:
          enabled:
          - not-a-plugin
        """
        let lists = HermesPluginList.parseConfigActivationLists(yaml)
        #expect(lists.enabled == ["chrome-profiles", "observability/langfuse"])
        #expect(lists.disabled == ["loud"])
        // A same-named key under a different top-level block must not leak in.
        #expect(lists.enabled.contains("not-a-plugin") == false)
    }

    @Test("config fallback reproduces _plugin_status exactly, key aliases included")
    func pluginStatusMatchesCLI() {
        let enabled: Set<String> = ["chrome-profiles", "observability/langfuse"]
        let disabled: Set<String> = ["loud"]
        #expect(HermesPluginList.status(name: "chrome-profiles", enabled: enabled, disabled: disabled) == .enabled)
        #expect(HermesPluginList.status(name: "loud", enabled: enabled, disabled: disabled) == .disabled)
        // Installed on disk, in neither list — the state Scarf's `.disabled`
        // marker walk used to render as "enabled".
        #expect(HermesPluginList.status(name: "orphan", enabled: enabled, disabled: disabled) == .notEnabled)
        // The registry key alias resolves too.
        #expect(HermesPluginList.status(name: "langfuse", key: "observability/langfuse", enabled: enabled, disabled: disabled) == .enabled)
        // disabled wins over enabled, as in the Python.
        #expect(HermesPluginList.status(name: "both", enabled: ["both"], disabled: ["both"]) == .disabled)
    }

    @Test("flow-sequence config is accepted")
    func pluginConfigFlowSequence() {
        let lists = HermesPluginList.parseConfigActivationLists("plugins:\n  enabled: [a, \"b\"]\n  disabled: []\n")
        #expect(lists.enabled == ["a", "b"])
        #expect(lists.disabled.isEmpty)
    }

    @Test("install output distinguishes enabled from installed-but-disabled")
    func installOutcome() {
        let enabledOut = """
          Cloning https://github.com/owner/repo...
          ✓ Plugin chrome-profiles enabled.
          Restart the gateway for the plugin to take effect:
            hermes gateway restart
        """
        let a = HermesPluginInstallOutcome.parse(enabledOut)
        #expect(a.enabled)
        #expect(a.installedDisabled == false)
        #expect(a.needsGatewayRestart)

        let disabledOut = """
          Cloning https://github.com/owner/repo...
          Plugin installed but not enabled. Run `hermes plugins enable chrome-profiles` to activate.
          Restart the gateway for the plugin to take effect:
        """
        let b = HermesPluginInstallOutcome.parse(disabledOut)
        // Exit code is 0 for both — only the text separates them.
        #expect(b.enabled == false)
        #expect(b.installedDisabled)
        #expect(b.needsGatewayRestart)
    }

    @Test("install output surfaces unset requires_env names")
    func installMissingEnv() {
        let out = """
          This plugin needs environment variables set in ~/.hermes/.env:
            CHROME_PROFILE_DIR
            CHROME_API_TOKEN
          Plugin installed but not enabled.
        """
        let outcome = HermesPluginInstallOutcome.parse(out)
        #expect(outcome.missingEnvVars == ["CHROME_PROFILE_DIR", "CHROME_API_TOKEN"])
    }

    // MARK: - Webhooks

    /// Transcribed from `webhook.py::_cmd_list` — note that every line,
    /// including the bullet rows, carries leading whitespace.
    static let webhookListOutput = """

      2 webhook subscription(s):

      ◆ deploys
        Notify the team when a deploy lands
        URL:     http://localhost:8787/webhooks/deploys
        Events:  push, release
        Deliver: slack
        Script:  filter_deploys.py

      ◆ alerts
        URL:     http://localhost:8787/webhooks/alerts
        Events:  (all)
        Deliver: telegram (direct — no agent)

    """

    @Test("webhook list parses the indented ◆ format")
    func webhookListParses() throws {
        let entries = HermesWebhookList.parse(Self.webhookListOutput)
        #expect(entries.count == 2)

        let deploys = try #require(entries.first)
        #expect(deploys.name == "deploys")
        #expect(deploys.description == "Notify the team when a deploy lands")
        // The URL keeps its scheme colon and port colon.
        #expect(deploys.url == "http://localhost:8787/webhooks/deploys")
        #expect(deploys.events == ["push", "release"])
        #expect(deploys.deliver == "slack")
        #expect(deploys.script == "filter_deploys.py")
        #expect(deploys.deliverOnly == false)

        let alerts = entries[1]
        #expect(alerts.name == "alerts")
        // No description line — the next line is a label, so nothing is stolen.
        #expect(alerts.description.isEmpty)
        // `(all)` is the CLI's no-filter placeholder, not an event name.
        #expect(alerts.events.isEmpty)
        #expect(alerts.deliver == "telegram")
        #expect(alerts.deliverOnly)
        #expect(alerts.script.isEmpty)
    }

    @Test("webhook empty state is recognised as empty, not as a record")
    func webhookEmptyState() {
        let out = """
          No dynamic webhook subscriptions.
          Create one with: hermes webhook subscribe <name>
        """
        #expect(HermesWebhookList.isEmptyListing(out))
        #expect(HermesWebhookList.parse(out).isEmpty)
    }

    @Test("header and preamble lines never become webhook records")
    func webhookPreambleIgnored() {
        let entries = HermesWebhookList.parse("\n  1 webhook subscription(s):\n\n  ◆ solo\n    URL:     http://h/webhooks/solo\n")
        #expect(entries.map(\.name) == ["solo"])
    }

    // MARK: - Profiles

    @Test("export paths are normalised to the extension the CLI writes")
    func profileArchivePaths() {
        // export_profile strips .tar.gz/.tgz then make_targz re-appends
        // .tar.gz — so a .zip path becomes foo.zip.tar.gz on disk.
        #expect(HermesProfileArchive.normalizedOutputPath("/Users/a/dev.tar.gz") == "/Users/a/dev.tar.gz")
        #expect(HermesProfileArchive.normalizedOutputPath("/Users/a/dev.zip") == "/Users/a/dev.tar.gz")
        #expect(HermesProfileArchive.normalizedOutputPath("/Users/a/dev") == "/Users/a/dev.tar.gz")
        #expect(HermesProfileArchive.normalizedOutputPath("/Users/a/dev.tgz") == "/Users/a/dev.tgz")
        #expect(HermesProfileArchive.suggestedFilename(for: "dev") == "dev-profile.tar.gz")
    }

    @Test("remote scratch path is a tar.gz the download step can find")
    func profileRemoteScratch() {
        let path = HermesProfileArchive.remoteScratchPath()
        #expect(path.hasSuffix(".tar.gz"))
        #expect(path.hasPrefix("/tmp/scarf-profile-export-"))
        // Two calls must not collide.
        #expect(path != HermesProfileArchive.remoteScratchPath())
    }

    @Test("import validator accepts tar archives and warns on zip")
    func profileImportValidation() {
        #expect(HermesProfileArchive.validateImportPath("~/dev.tar.gz") == .ok)
        #expect(HermesProfileArchive.validateImportPath("~/dev.tgz") == .ok)
        #expect(HermesProfileArchive.validateImportPath("~/dev.zip") == .wrongExtension)
    }

    // MARK: - MCP add

    @Test("stdio plan passes args at add time so the probe can succeed")
    func mcpStdioPlan() {
        let plan = HermesMCPAdd.stdioPlan(name: "gh", command: "npx", args: ["-y", "@modelcontextprotocol/server-github"])
        // No `--` after `--args`: argparse eats the first `--` itself
        // before REMAINDER sees it, and the rest of the line then fails as
        // `unrecognized arguments` (verified on CPython 3.14). REMAINDER
        // carries the leading-dash `-y` fine on its own.
        #expect(plan.arguments == ["mcp", "add", "gh", "--command", "npx", "--args", "-y", "@modelcontextprotocol/server-github"])
        #expect(plan.arguments.contains("--") == false)
        // `--args` is REMAINDER and must be last.
        #expect(plan.arguments.firstIndex(of: "--args") == plan.arguments.count - 3)
        // stdio reaches no auth prompt — never feed it a y.
        #expect(plan.stdin.contains("y") == false)
    }

    @Test("stdio plan orders --env before the --args remainder")
    func mcpStdioEnvOrdering() {
        let plan = HermesMCPAdd.stdioPlan(name: "gh", command: "npx", args: ["server"], env: ["TOKEN": "t", "A": "b"])
        let envIndex = plan.arguments.firstIndex(of: "--env")!
        let argsIndex = plan.arguments.firstIndex(of: "--args")!
        #expect(envIndex < argsIndex)
        #expect(plan.arguments[envIndex + 1] == "A=b")
        #expect(plan.arguments[envIndex + 2] == "TOKEN=t")
    }

    @Test("no-auth HTTP declines the auth prompt instead of feeding a bare y")
    func mcpNoAuthPlan() {
        let plan = HermesMCPAdd.urlPlan(name: "ink", url: "https://mcp.ml.ink/mcp", auth: .none)
        #expect(plan.arguments == ["mcp", "add", "ink", "--url", "https://mcp.ml.ink/mcp"])
        // The CLI prompt defaults to YES, so the `n` is load-bearing:
        // the old `y\ny\ny\n` accepted it, then handed `y` to the bearer
        // token read.
        #expect(plan.stdin.hasPrefix("n\n"))
        #expect(plan.stdin.contains("y") == false)
    }

    @Test("oauth passes --auth oauth and answers nothing but defaults")
    func mcpOAuthPlan() {
        let plan = HermesMCPAdd.urlPlan(name: "linear", url: "https://mcp.linear.app/mcp", auth: .oauth)
        #expect(plan.arguments.contains("--auth"))
        #expect(plan.arguments.contains("oauth"))
        #expect(plan.stdin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("header auth sends the real token at the value read")
    func mcpHeaderPlan() {
        let plan = HermesMCPAdd.urlPlan(name: "acme", url: "https://acme.test/mcp", auth: .header(token: "sk-live-abc123"))
        #expect(plan.arguments.contains("header"))
        // y answers the yes/no question; the token answers the value read.
        #expect(plan.stdin.hasPrefix("y\nsk-live-abc123\n"))
    }

    @Test("mcp add outcome is read from stdout, never from exit 0")
    func mcpOutcomeParsing() {
        let saved = "\n  ✓ Saved 'gh' to ~/.hermes/config.yaml (7/7 tools enabled)\n  Start a new session to use these tools.\n"
        #expect(HermesMCPAdd.parseOutcome(saved, name: "gh") == .savedEnabled(toolsEnabled: 7, toolsTotal: 7))

        let partial = "  ✓ Saved 'gh' to ~/.hermes/config.yaml (3/7 tools enabled)"
        #expect(HermesMCPAdd.parseOutcome(partial, name: "gh") == .savedEnabled(toolsEnabled: 3, toolsTotal: 7))

        // The old failure mode: probe dies, entry is written disabled, and
        // the process still exits 0.
        let disabled = "  ✗ Failed to connect: spawn npx ENOENT\n  ✓ Saved 'gh' to config (disabled)\n"
        #expect(HermesMCPAdd.parseOutcome(disabled, name: "gh") == .savedDisabled)

        let noTools = "  ⚠ Server connected but reported no tools.\n  ✓ Saved 'gh' to config\n"
        #expect(HermesMCPAdd.parseOutcome(noTools, name: "gh") == .savedWithoutTools)
    }

    @Test("nothing-saved paths report the CLI's own reason")
    func mcpOutcomeNotSaved() {
        let failed = HermesMCPAdd.parseOutcome("  ✗ Failed to connect: spawn npx ENOENT\n", name: "gh")
        #expect(failed.didSave == false)
        #expect(failed == .notSaved(reason: "Failed to connect: spawn npx ENOENT"))

        let rejected = HermesMCPAdd.parseOutcome("  ⚠ Server 'gh' was NOT saved due to suspicious configuration.\n", name: "gh")
        #expect(rejected.didSave == false)

        let cancelled = HermesMCPAdd.parseOutcome("  Cancelled.\n", name: "gh")
        #expect(cancelled.didSave == false)

        // Silence is a failure, not a success.
        let silent = HermesMCPAdd.parseOutcome("", name: "gh")
        #expect(silent.didSave == false)
        #expect(silent.isLive == false)
    }

    @Test("a save line for a different server is not our success")
    func mcpOutcomeNameScoped() {
        let other = "  ✓ Saved 'other' to ~/.hermes/config.yaml (2/2 tools enabled)"
        #expect(HermesMCPAdd.parseOutcome(other, name: "gh").didSave == false)
    }

    // MARK: - Capability floors

    @Test("plugin CLI capability floors match the tag walk")
    func pluginCapabilityFloors() {
        let caps = HermesCapabilities.parseLine
        // --json absent at v0.15.2 (v2026.5.29.2), present at v0.16.0 (v2026.6.5).
        #expect(caps("Hermes Agent v0.15.2 (2026.5.29.2)").hasPluginsListJSON == false)
        #expect(caps("Hermes Agent v0.16.0 (2026.6.5)").hasPluginsListJSON)
        // --allow-tool-override absent at v0.17.0, present at v0.18.0 (v2026.7.1).
        #expect(caps("Hermes Agent v0.17.0 (2026.6.19)").hasPluginEnableToolOverrideFlag == false)
        #expect(caps("Hermes Agent v0.18.0 (2026.7.1)").hasPluginEnableToolOverrideFlag)
        // The v0.14 manifest-badge flag is a different, earlier thing.
        #expect(caps("Hermes Agent v0.14.0 (2026.5.16)").hasPluginToolOverride)
        #expect(caps("Hermes Agent v0.14.0 (2026.5.16)").hasPluginEnableToolOverrideFlag == false)
    }
}
