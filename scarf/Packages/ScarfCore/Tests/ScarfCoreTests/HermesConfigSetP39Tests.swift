import Foundation
import Testing
@testable import ScarfCore

/// P39 — the exit-0 refusal family on Hermes's config writers, judged.
///
/// Every fixture below is the Hermes emitter's own text at **v2026.9.7**,
/// pasted from the tagged source rather than paraphrased. The one thing they
/// all share is the shape that makes exit codes useless here: a handler that
/// `print()`s a refusal and bare-`return`s, which Python turns into exit 0.
@Suite("P39 — `config set` / `save_config` verdicts")
struct HermesConfigSetP39Tests {

    // MARK: - argv

    /// Both positionals are `nargs="?"` (`hermes_cli/subcommands/config.py:24-31`
    /// @ v2026.9.7), so a value that looks like an option was parsed as one
    /// and argparse exited 2. `--` is the separator argparse has always
    /// honoured, and the parser declares nothing that could swallow it.
    @Test func argvSeparatesTheOptionsFromThePositionals() {
        #expect(HermesConfigSet.argv(key: "model.context_length", value: "-1")
                == ["config", "set", "--", "model.context_length", "-1"])
        #expect(HermesConfigUnset.argv(key: "approvals.mode")
                == ["config", "unset", "--", "approvals.mode"])
    }

    // MARK: - `config set` success

    /// `print(f"✓ Set {key} = {_display_value} in {config_path}")` —
    /// `hermes_cli/config.py:3521`.
    @Test func theConfigYAMLSuccessLineIsASuccess() {
        let out = HermesConfigSet.judge(
            output: "✓ Set model.default = gpt-5 in /Users/a/.hermes/config.yaml\n",
            exitCode: 0)
        #expect(out.succeeded)
        #expect(out.detail == nil)
    }

    /// `print(f"✓ Set {key} in {get_env_path()}")` — `:3468`, the `.env` arm.
    @Test func theEnvSuccessLineIsASuccess() {
        #expect(HermesConfigSet.judge(
            output: "✓ Set OPENROUTER_API_KEY in /Users/a/.hermes/.env\n",
            exitCode: 0).succeeded)
    }

    /// The post-write notices are printed on the SUCCESS path — the value IS
    /// saved (`_print_unknown_key_notice`, `:3433-3443`; the two coercion
    /// warnings at `:3326-3330` and `:3334-3337`). Quoting any of them as a
    /// failure would invert a real write.
    @Test func thePostWriteNoticesDoNotFlipASuccess() {
        let out = HermesConfigSet.judge(output: """
        ✓ Set gateway.wibble = 1 in /Users/a/.hermes/config.yaml
        ⚠ 'gateway.wibble' is not a recognized config key — it was saved anyway, but Hermes may not read it.
          Did you mean: gateway.wibble_mode
        """, exitCode: 0)
        #expect(out.succeeded)
    }

    /// `_guard_section_overwrite`'s redirect (`:3391-3393`) precedes a REAL
    /// write, and its line does not start with `Set ` — so the anchored
    /// success marker matches the write's own line, not the redirect's.
    @Test func theBareModelRedirectStillReportsTheWriteItPerformed() {
        let out = HermesConfigSet.judge(output: """
        ✓ Redirecting bare 'model' to 'model.default' (preserving 3 existing model sub-key(s))
        ✓ Set model.default = gpt-5 in /Users/a/.hermes/config.yaml
        """, exitCode: 0)
        #expect(out.succeeded)
    }

    // MARK: - `config set` refusals — the whole family

    /// **Arm 1**, and the reason this phase exists. `if is_managed():
    /// managed_error("set configuration values"); return`
    /// (`hermes_cli/config.py:3450-3452`) → `format_managed_message`
    /// (`:445-450`) on stderr, then a bare `return` → **exit 0**. Judged by
    /// the exit code this was "Saved model.default".
    @Test func theManagedInstallRefusalExitsZeroAndIsStillAFailure() {
        let out = HermesConfigSet.judge(output: """
        Cannot set configuration values: this Hermes installation is managed by nixos.
        Use your package manager to upgrade or reinstall Hermes.
        """, exitCode: 0)
        #expect(out.succeeded == false)
        #expect(out.detail?.contains("managed by nixos") == true)
    }

    /// **Arm 5** — the one that forces `failureWins`. The `.env` branch's
    /// managed-SCOPE guard (`_env_write_blocked`, `:2560-2564`) refuses the
    /// write and returns True, and `:3468` prints `✓ Set …` anyway. Both
    /// markers, one run, exit 0.
    @Test func aRefusedEnvWriteThatStillPrintsItsSuccessLineIsAFailure() {
        let out = HermesConfigSet.judge(output: """
        Cannot set OPENROUTER_API_KEY: it is managed by your administrator (/etc/hermes/.env) and cannot be changed. Contact your administrator to modify it.
        ✓ Set OPENROUTER_API_KEY in /Users/a/.hermes/.env
        """, exitCode: 0)
        #expect(out.succeeded == false)
        #expect(out.detail?.contains("managed by your administrator") == true)
    }

    /// **Arms 2 and 3** — `_exit_invalid(f"✗ Invalid config key: …")`
    /// (`:3454-3458`), exit 1.
    @Test(arguments: [
        "✗ Invalid config key: 'agent. ' (empty or surrounding whitespace).",
        "✗ Invalid config key: 'agent..max_turns' — contains an empty path segment (leading, trailing, or doubled '.').",
    ])
    func theInvalidKeyArmsAreFailures(_ line: String) {
        let out = HermesConfigSet.judge(output: line + "\n", exitCode: 1)
        #expect(out.succeeded == false)
        #expect(out.detail == line)
    }

    /// **Arm 4** — `_exit_if_key_managed(key, "set")`, `:3368-3370`, exit 1.
    @Test func theAdministratorPinnedKeyArmIsAFailure() {
        let out = HermesConfigSet.judge(
            output: "Cannot set 'model.default': it is managed by your administrator (/etc/hermes/config.yaml) and cannot be changed. Contact your administrator to modify it.\n",
            exitCode: 1)
        #expect(out.succeeded == false)
        #expect(out.detail?.hasPrefix("Cannot set 'model.default'") == true)
    }

    /// **Arm 6** — `_guard_section_overwrite`'s scalar-over-section refusal
    /// (`:3394-3417`), exit 1. The hint lines that follow must not be what
    /// gets quoted.
    @Test func theSectionOverwriteArmQuotesItsFirstLine() {
        let out = HermesConfigSet.judge(output: """
        ✗ Cannot set 'terminal' to a scalar — 'terminal' is a configuration section with 4 sub-key(s).
          Sub-keys: backend, cwd, env, image
          Use a dotted path to set a specific leaf key:
            hermes config set terminal.<sub-key> <value>
        """, exitCode: 1)
        #expect(out.succeeded == false)
        #expect(out.detail?.contains("is a configuration section") == true)
    }

    /// **Arms 7-9** print text no marker can anchor on — a `ValueError` body
    /// (`:3495-3497`), the fail-closed write guard surfaced by
    /// `_run_write_command` (`:3598-3604`), and `_usage_exit` (`:3585-3593`).
    /// They are caught by the exit code, and the last significant line is
    /// quoted.
    @Test func theUnmarkedArmsAreCaughtByTheExitCode() {
        let out = HermesConfigSet.judge(
            output: "✗ Refusing to overwrite /Users/a/.hermes/config.yaml: it is not valid YAML.\n",
            exitCode: 1)
        #expect(out.succeeded == false)
        #expect(out.detail?.contains("Refusing to overwrite") == true)
    }

    /// The C5 rule: exit 0 with neither marker is not a success. An unknown
    /// verb routed to the agent lands exactly here.
    @Test func silenceAtExitZeroIsNotASuccess() {
        #expect(HermesConfigSet.judge(output: "", exitCode: 0).succeeded == false)
    }

    // MARK: - `config unset`

    /// `unset_config_value`'s `.env` arm can print a managed-scope refusal
    /// through `remove_env_value` (`:2552-2566`) and STILL print
    /// `✓ Unset …` (`:3583`) — which is why P39 gave this verdict
    /// `failureWins: true` as well.
    @Test func aRefusedUnsetThatStillPrintsItsSuccessLineIsAFailure() {
        let out = HermesConfigUnset.judge(output: """
        Cannot unset OPENROUTER_API_KEY: it is managed by your administrator (/etc/hermes/.env) and cannot be changed. Contact your administrator to modify it.
        ✓ Unset OPENROUTER_API_KEY from /Users/a/.hermes/.env
        """, exitCode: 0)
        #expect(out.succeeded == false)
    }

    /// And the plain success still is one.
    @Test func aCleanUnsetIsStillASuccess() {
        #expect(HermesConfigUnset.judge(
            output: "✓ Unset approvals.mode from /Users/a/.hermes/config.yaml\n",
            exitCode: 0).succeeded)
    }

    // MARK: - `memory off` — the fourth `save_config` door

    /// `_cmd_memory_off` (`hermes_cli/main_agent_cmds.py:10-18`) calls
    /// `save_config` (`:16`) and then prints its confirmation (`:17`)
    /// unconditionally.
    @Test func memoryOffReportsTheManagedRefusalUnderItsOwnSuccessLine() {
        let out = HermesMemoryOff.judge(output: """
        Cannot save configuration: this Hermes installation is managed by home-manager.
        Use your package manager to upgrade or reinstall Hermes.

          ✓ Memory provider: built-in only
          Saved to config.yaml
        """, exitCode: 0)
        #expect(out.succeeded == false)
        #expect(out.detail?.contains("home-manager") == true)
    }

    @Test func memoryOffOnAnOrdinaryHostIsASuccess() {
        #expect(HermesMemoryOff.judge(output: """
          ✓ Memory provider: built-in only
          Saved to config.yaml
        """, exitCode: 0).succeeded)
    }

    // MARK: - `skills trust` — the third `save_config` door

    /// `_cmd_skills_trust` (`hermes_cli/main_agent_cmds.py:224`, `:234`) hands
    /// the config to `save_config` and prints `Trusted: <root>` (`:235`)
    /// afterwards regardless.
    @Test func skillsTrustReportsTheManagedRefusalUnderItsOwnSuccessLine() {
        let out = HermesSkillsTrust.judge(output: """
        Cannot save configuration: this Hermes installation is managed by nixos.
        Use your package manager to upgrade or reinstall Hermes.
        Trusted: /Users/a/dev/scarf
        2 project skill(s) will load in sessions started inside this repo (they take precedence over same-named profile skills).
        """, exitCode: 0)
        #expect(out.succeeded == false)
    }

    @Test(arguments: [
        "Trusted: /Users/a/dev/scarf",
        "Already trusted: /Users/a/dev/scarf",
        "Untrusted: /Users/a/dev/scarf",
        "/Users/a/dev/scarf was not trusted.",
    ])
    func everySkillsTrustSuccessLineIsRecognised(_ line: String) {
        #expect(HermesSkillsTrust.judge(output: line + "\n", exitCode: 0).succeeded)
    }

    /// Two of `_cmd_skills_trust`'s OWN refusals are bare `return`s at exit 0
    /// (`:197`, `:202-204`) — Scarf used to banner "Trusted" for both.
    @Test(arguments: [
        "Not a directory: /Users/a/nope",
        "Not inside a git checkout. Run from a project directory or pass the project root path explicitly.",
    ])
    func skillsTrustOwnExitZeroRefusalsAreFailures(_ line: String) {
        let out = HermesSkillsTrust.judge(output: line + "\n", exitCode: 0)
        #expect(out.succeeded == false)
    }

    // MARK: - plugins enable/disable — the first two `save_config` doors

    /// `cmd_disable` prints `⊘ Plugin <key> disabled. Takes effect on next
    /// session.` (`hermes_cli/plugins_cmd.py:1196-1198`) AFTER the
    /// `save_config` underneath it refused (`:115-120` →
    /// `hermes_cli/config.py:2316-2318`), at exit 0.
    @Test func thePluginsDisableMarkersSeeTheManagedRefusal() {
        let out = HermesCLIVerdict.judge(
            output: """
            Cannot save configuration: this Hermes installation is managed by nixos.
            Use your package manager to upgrade or reinstall Hermes.
            ⊘ Plugin weather disabled. Takes effect on next session.
            """,
            exitCode: 0,
            successMarkers: HermesCLIMarkers.pluginsDisableSuccess,
            failureMarkers: HermesCLIMarkers.pluginsDisableFailure,
            // The managed refusal rides anchored alongside the set now
            // (round-4 review) — the same pair `PluginsViewModel` passes.
            anchoredFailureMarkers: HermesCLIMarkers.managedRefusalAnchored,
            failureWins: true
        )
        #expect(out.succeeded == false)
    }

    /// Round-4 review: the shared marker is matched ANCHORED now, so what has
    /// to hold is that every config-mutating set can SEE the refusal line
    /// Hermes prints — not that each carries the same substring.
    @Test func everyConfigMutatingMarkerSetSeesTheSharedManagedRefusal() {
        // P39c: the anchors are the FULL action prefixes, not a bare
        // `Cannot ` — see `HermesManagedRefusalP39cTests`.
        #expect(HermesCLIMarkers.managedRefusalAnchored == [
            "Cannot save configuration", "Cannot set", "Cannot unset", "Cannot remove",
        ])
        let refusal = "Cannot save configuration: this Hermes installation is managed by nixos."
        for set in [
            HermesCLIMarkers.configSetFailure,
            HermesCLIMarkers.configUnsetFailure,
            HermesCLIMarkers.skillsTrustFailure,
            HermesCLIMarkers.memoryOffFailure,
        ] {
            let out = HermesCLIVerdict.judge(
                output: refusal, exitCode: 0,
                successMarkers: ["nothing prints this"],
                anchoredFailureMarkers: set,
                failureWins: true
            )
            #expect(out.succeeded == false)
            #expect(out.detail == refusal)
        }
        // The plugins sets carry mid-sentence markers and cannot be anchored
        // themselves; they ride the shared anchored list alongside.
        for set in [
            HermesCLIMarkers.pluginsEnableFailure,
            HermesCLIMarkers.pluginsDisableFailure,
            HermesCLIMarkers.pluginsUpdateFailure,
        ] {
            let out = HermesCLIVerdict.judge(
                output: refusal, exitCode: 0,
                successMarkers: ["nothing prints this"],
                failureMarkers: set,
                anchoredFailureMarkers: HermesCLIMarkers.managedRefusalAnchored,
                failureWins: true
            )
            #expect(out.succeeded == false)
        }
    }

    /// The marker carries `is ` for a reason: two OTHER lines in the same
    /// Hermes file say "managed by" on a path that is NOT a refusal —
    /// `_strip_managed_keys_for_save` (`hermes_cli/config.py:2289-2291`) and
    /// `_show_managed_banner` (`:2768`). Neither may flip a real write.
    @Test(arguments: [
        "Note: 2 managed setting(s) were not saved (managed by your administrator): model.default, model.provider",
        "  ⚷ Some settings are managed by your administrator (/etc/hermes) and cannot be changed",
    ])
    func theNonRefusalManagedLinesDoNotMatchTheMarker(_ line: String) {
        let out = HermesConfigSet.judge(output: """
        \(line)
        ✓ Set display.streaming = true in /Users/a/.hermes/config.yaml
        """, exitCode: 0)
        #expect(out.succeeded)
    }
}

/// P39 / round-4 decision 11 — the seventh `config unset` door.
///
/// `BotAgentConfigService.unsetValue` hand-built `["config", "unset", key]`,
/// shelled it on any host, and left the verdict to the exit code. All three
/// are fixed here; the outcome half lives in `BotAgentViewModel.isBenignUnset`
/// (Mac target, `BotAgentClearPinP39Tests`).
@Suite("P39 — bot model-pin clears")
struct BotAgentUnsetP39Tests {

    static let v0210 = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
    /// v0.18.2 — below BOTH floors. See `theFloorIsMootButStructural`.
    static let v0182 = HermesCapabilities.parseLine("Hermes Agent v0.18.2 (2026.7.7.2)")

    static func service(_ capabilities: HermesCapabilities) -> BotAgentConfigService {
        BotAgentConfigService(
            context: ServerContext(
                id: UUID(), displayName: "box",
                kind: .ssh(SSHConfig(host: "box", remoteHome: "~/.hermes"))
            ),
            capabilities: capabilities
        )
    }

    /// **The `hasConfigUnset` gate on this path is MOOT, not missing — and
    /// that is worth pinning rather than asserting in a comment.** Bot Mode's
    /// floor is `isV0203OrLater` (`HermesCapabilities.hasBotMode`) and
    /// `hasConfigUnset` is v0.19.0, so every host that can reach a bot's
    /// config surface at all already has the verb. The guard is there for the
    /// P37 reason — the compiler asks before anything can be cleared, and a
    /// future floor change cannot silently open a door — not because a host
    /// in the gap exists today. If this expectation ever fails, the gap is
    /// real and the gate started earning its keep.
    @Test func theConfigUnsetFloorIsMootUnderBotModeButStillStructural() {
        #expect(Self.v0210.hasBotMode)
        #expect(Self.v0210.hasConfigUnset)
        // No host has Bot Mode without `config unset`.
        #expect(Self.v0182.hasBotMode == false)
        #expect(Self.v0182.hasConfigUnset == false)

        // Below the floor NOTHING is shelled (charter C5). The throw is what
        // proves it: `run` would need a live transport to get further, and
        // `unsetValue` never reaches it.
        #expect(throws: BotsError.unsupported) {
            try Self.service(Self.v0182).unsetValue(forProfile: "scout", key: "model.default")
        }
        #expect(throws: BotsError.unsupported) {
            _ = try Self.service(Self.v0182).clearModelPin(forProfile: "scout")
        }
    }

    /// The argv now comes from the shared builder, `--` included, so the bot
    /// door cannot drift away from the two Settings doors.
    @Test func theBotArgvIsTheSharedBuilderUnderTheProfileFlag() {
        let argv = Self.service(Self.v0210).argv(
            forProfile: "scout", args: HermesConfigUnset.argv(key: "model.default"))
        #expect(argv == ["-p", "scout", "config", "unset", "--", "model.default"])
    }

    /// And the `set` side, for the same reason.
    @Test func theBotSetArgvIsTheSharedBuilderToo() {
        let argv = Self.service(Self.v0210).argv(
            forProfile: "scout", args: HermesConfigSet.argv(key: "model.default", value: "-1"))
        #expect(argv == ["-p", "scout", "config", "set", "--", "model.default", "-1"])
    }
}
