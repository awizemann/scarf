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

    /// A subscription's `description` is agent-written and `_cmd_list`
    /// prints it raw (`print(f"    {desc}")`) with no escaping — so a
    /// description containing newlines can emit lines that look exactly like
    /// a record header. A forged record would show the user a webhook row
    /// that does not exist, pointing at an endpoint of the forger's choosing.
    ///
    /// Three properties keep it out: the bullet must START the trimmed line,
    /// sit at the CLI's two-space bullet indent, and follow a blank line
    /// (every real record does; a description's own lines never do). (F9)
    @Test("a forged ◆ record inside a description does not open a record")
    func webhookForgedDescriptionIgnored() throws {
        // The description the agent wrote was:
        //   "Harmless\n  ◆ prod-deploy\n    URL:     https://evil.test/hook"
        let output = """

          2 webhook subscription(s):

          ◆ real
            Harmless
          ◆ prod-deploy
            URL:     https://evil.test/hook
            URL:     http://localhost:8787/webhooks/real
            Events:  (all)
            Deliver: log

          ◆ second
            URL:     http://localhost:8787/webhooks/second
            Events:  (all)
            Deliver: log

        """
        let entries = HermesWebhookList.parse(output)
        // Only the two genuine records — the forged bullet is not preceded
        // by a blank line, so it stays description text.
        #expect(entries.map(\.name) == ["real", "second"])
        let real = try #require(entries.first)
        // And the forged URL never becomes the real record's URL: the first
        // `URL:` line the forger injected is inside the record body, so the
        // record keeps whichever URL the CLI itself emitted last.
        #expect(!real.url.contains("evil.test"))
        #expect(real.url == "http://localhost:8787/webhooks/real")
    }

    /// A description that merely MENTIONS the bullet is ordinary text.
    @Test("a description containing ◆ mid-line is not a record boundary")
    func webhookDescriptionMentioningBulletIsText() throws {
        let output = """

          1 webhook subscription(s):

          ◆ solo
            Fires on deploy ◆ and release
            URL:     http://h/webhooks/solo
            Events:  (all)
            Deliver: log

        """
        let entries = HermesWebhookList.parse(output)
        #expect(entries.map(\.name) == ["solo"])
        #expect(try #require(entries.first).description == "Fires on deploy ◆ and release")
    }

    /// A forged bullet at the FIELD indent (4) is rejected on the indent
    /// rule alone, even where a blank line precedes it.
    @Test("a bullet at the field indent never opens a record")
    func webhookBulletAtWrongIndentIgnored() {
        let output = """

          1 webhook subscription(s):

          ◆ solo
            URL:     http://h/webhooks/solo

            ◆ fake
            URL:     https://evil.test/hook

        """
        #expect(HermesWebhookList.parse(output).map(\.name) == ["solo"])
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
    func mcpStdioPlan() throws {
        let plan = try HermesMCPAdd.stdioPlan(name: "gh", command: "npx", args: ["-y", "@modelcontextprotocol/server-github"])
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
    func mcpStdioEnvOrdering() throws {
        let plan = try HermesMCPAdd.stdioPlan(name: "gh", command: "npx", args: ["server"], env: ["TOKEN": "t", "A": "b"])
        let envIndex = plan.arguments.firstIndex(of: "--env")!
        let argsIndex = plan.arguments.firstIndex(of: "--args")!
        #expect(envIndex < argsIndex)
        #expect(plan.arguments[envIndex + 1] == "A=b")
        #expect(plan.arguments[envIndex + 2] == "TOKEN=t")
    }

    @Test("no-auth HTTP declines the auth prompt instead of feeding a bare y")
    func mcpNoAuthPlan() throws {
        let plan = try HermesMCPAdd.urlPlan(name: "ink", url: "https://mcp.ml.ink/mcp", auth: .none)
        #expect(plan.arguments == ["mcp", "add", "ink", "--url", "https://mcp.ml.ink/mcp"])
        // The CLI prompt defaults to YES, so the `n` is load-bearing:
        // the old `y\ny\ny\n` accepted it, then handed `y` to the bearer
        // token read.
        #expect(plan.stdin.hasPrefix("n\n"))
        #expect(plan.stdin.contains("y") == false)
    }

    @Test("oauth passes --auth oauth and answers nothing but defaults")
    func mcpOAuthPlan() throws {
        let plan = try HermesMCPAdd.urlPlan(name: "linear", url: "https://mcp.linear.app/mcp", auth: .oauth)
        #expect(plan.arguments.contains("--auth"))
        #expect(plan.arguments.contains("oauth"))
        #expect(plan.stdin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("header auth sends the real token at the value read")
    func mcpHeaderPlan() throws {
        let plan = try HermesMCPAdd.urlPlan(name: "acme", url: "https://acme.test/mcp", auth: .header(token: "sk-live-abc123"))
        #expect(plan.arguments.contains("header"))
        // y answers the yes/no question; the token answers the value read.
        #expect(plan.stdin.hasPrefix("y\nsk-live-abc123\n"))
    }

    // MARK: - MCP add: host-state-dependent prompt shifts (F9)

    /// `mcp_config.py:483-487` — when the name is already in
    /// `_get_mcp_servers()`, an "already exists. Overwrite?" prompt is asked
    /// BEFORE the auth stage. That extra prompt eats the first stdin line,
    /// so the `y` meant for "requires authentication?" answers *it* and the
    /// bearer token then answers the auth question. Refuse rather than
    /// guess: the caller must resolve the user's intent first.
    @Test("an existing server name refuses the plan instead of shifting stdin")
    func mcpExistingNameRefusesPlan() {
        let taken = HermesMCPAdd.HostState(serverNameExists: true)
        #expect(throws: HermesMCPAdd.PlanError.serverAlreadyExists(name: "acme")) {
            _ = try HermesMCPAdd.urlPlan(
                name: "acme", url: "https://acme.test/mcp",
                auth: .header(token: "sk-live-abc123"), state: taken
            )
        }
        #expect(throws: HermesMCPAdd.PlanError.serverAlreadyExists(name: "gh")) {
            _ = try HermesMCPAdd.stdioPlan(name: "gh", command: "npx", args: [], state: taken)
        }
    }

    /// With the user's explicit confirmation, the extra prompt IS answered —
    /// and answered `y`, because `_confirm(default=False)` would otherwise
    /// cancel — and every later answer keeps its correct position.
    @Test("a confirmed overwrite prepends exactly one y and keeps auth aligned")
    func mcpConfirmedOverwriteKeepsAlignment() throws {
        let confirmed = HermesMCPAdd.HostState(serverNameExists: true, overwriteConfirmed: true)
        let plan = try HermesMCPAdd.urlPlan(
            name: "acme", url: "https://acme.test/mcp",
            auth: .header(token: "sk-live-abc123"), state: confirmed
        )
        // overwrite-y, auth-y, token — in that order, one line each.
        #expect(plan.stdin.hasPrefix("y\ny\nsk-live-abc123\n"))
        let noAuth = try HermesMCPAdd.urlPlan(
            name: "ink", url: "https://mcp.ml.ink/mcp", auth: .none, state: confirmed
        )
        #expect(noAuth.stdin.hasPrefix("y\nn\n"))
        let stdio = try HermesMCPAdd.stdioPlan(
            name: "gh", command: "npx", args: ["server"], state: confirmed
        )
        #expect(stdio.stdin.hasPrefix("y\n"))
    }

    /// `mcp_config.py:545-548` — when `MCP_<NAME>_API_KEY` already resolves,
    /// the CLI prints "already configured" and never prompts for the key.
    /// A queued token line would then be read by the NEXT prompt ("Enable
    /// all N tools?"), mis-answering it and echoing the secret at a prompt
    /// we never meant to answer. The token must simply not be sent.
    @Test("a pre-existing MCP_<NAME>_API_KEY suppresses the token line")
    func mcpExistingEnvKeySuppressesToken() throws {
        let keyed = HermesMCPAdd.HostState(
            serverNameExists: false, apiKeyAlreadyConfigured: true
        )
        let plan = try HermesMCPAdd.urlPlan(
            name: "acme", url: "https://acme.test/mcp",
            auth: .header(token: "sk-live-abc123"), state: keyed
        )
        #expect(plan.stdin.hasPrefix("y\n"))
        // The secret must not appear anywhere in what we pipe.
        #expect(!plan.stdin.contains("sk-live-abc123"))
        // …and the caller is told, so the user learns their typed token was
        // NOT the one the server will use. Dropping it silently would leave
        // the server authenticating with the old key with nothing on screen
        // to say so.
        #expect(plan.discardedSuppliedToken)
    }

    /// The flag is only for a token we actually withheld — a fresh host
    /// sends the token normally and must not raise the notice.
    @Test("no discarded-token notice when the token was actually sent")
    func mcpFreshHostDoesNotFlagDiscard() throws {
        let plan = try HermesMCPAdd.urlPlan(
            name: "acme", url: "https://acme.test/mcp",
            auth: .header(token: "sk-live-abc123"), state: .fresh
        )
        #expect(plan.stdin.contains("sk-live-abc123"))
        #expect(!plan.discardedSuppliedToken)
    }

    /// Residual uncertainty is a refusal, never a default. If we can't tell
    /// whether the key exists, we can't tell whether a token line will be
    /// consumed — and being wrong leaks it into the wrong prompt.
    @Test("an unknown API-key state refuses rather than guessing")
    func mcpUnknownKeyStateRefuses() {
        let unknown = HermesMCPAdd.HostState(
            serverNameExists: false, apiKeyAlreadyConfigured: nil
        )
        #expect(throws: HermesMCPAdd.PlanError.apiKeyStateUnknown(envKey: "MCP_ACME_API_KEY")) {
            _ = try HermesMCPAdd.urlPlan(
                name: "acme", url: "https://acme.test/mcp",
                auth: .header(token: "sk-live-abc123"), state: unknown
            )
        }
        // A no-auth or oauth plan asks no key question, so an unknown key
        // state is irrelevant there and must NOT refuse.
        #expect(throws: Never.self) {
            _ = try HermesMCPAdd.urlPlan(
                name: "acme", url: "https://acme.test/mcp", auth: .none, state: unknown
            )
        }
    }

    /// Mirrors `_env_key_for_server` (`mcp_config.py:153-156`) — the Python
    /// `re.sub` runs per character, so `a--b` yields a doubled underscore,
    /// and `.strip("_")` only trims the ends.
    @Test("envKeyForServer matches the CLI's _env_key_for_server exactly")
    func mcpEnvKeyDerivation() {
        #expect(HermesMCPAdd.envKeyForServer("acme") == "MCP_ACME_API_KEY")
        #expect(HermesMCPAdd.envKeyForServer("my-server") == "MCP_MY_SERVER_API_KEY")
        #expect(HermesMCPAdd.envKeyForServer("a--b") == "MCP_A__B_API_KEY")
        #expect(HermesMCPAdd.envKeyForServer("_lead_") == "MCP_LEAD_API_KEY")
        #expect(HermesMCPAdd.envKeyForServer("dot.name") == "MCP_DOT_NAME_API_KEY")
    }

    /// The F2/F3 "guard the user-supplied positional with `--`" rule does
    /// NOT generalise to `mcp add`: its `name` positional is followed on the
    /// command line by `--command` / `--url` / `--env` / `--args`, and
    /// argparse treats everything after the first `--` as positional, so a
    /// leading `--` makes every flag an `unrecognized argument`. Verified by
    /// running the real subparser shape; pinned here so nobody "fixes" it
    /// back for consistency.
    @Test("mcp add emits no `--` separator anywhere — argparse rejects it")
    func mcpAddNeverEmitsDoubleDash() throws {
        let stdio = try HermesMCPAdd.stdioPlan(name: "gh", command: "npx", args: ["-y", "pkg"])
        let url = try HermesMCPAdd.urlPlan(name: "ink", url: "https://x.test/mcp", auth: .none)
        #expect(!stdio.arguments.contains("--"))
        #expect(!url.arguments.contains("--"))
        #expect(stdio.arguments[2] == "gh")
        #expect(url.arguments[2] == "ink")
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
