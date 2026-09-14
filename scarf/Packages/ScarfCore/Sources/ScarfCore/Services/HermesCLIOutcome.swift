import Foundation

/// The verdict on one `hermes` CLI invocation, judged by what the emitter
/// PRINTED rather than by the exit code (charter C5).
///
/// ## Why the exit code is not the truth
///
/// Most `hermes` subcommand handlers are `-> None` functions that `print()` a
/// refusal and `return`. Python turns a `None` return into exit status 0, so a
/// refused install, a not-found session, a failed OAuth flow and an ungranted
/// capability all arrive at Scarf as "exit 0". Verbatim at v2026.9.7:
///
/// - `hermes_cli/skills_hub.py:645-648` — `def do_install(...) -> None`, with
///   nine bare `return`s after printing (`:659`, `:662`, `:667`, `:669`,
///   `:685`, `:693`, `:701`, `:712`, `:718`).
/// - `hermes_cli/sessions_cmd.py:46-48` — `_not_found()` prints
///   `Session '<id>' not found.` **to stdout** and returns 1, but its callers
///   (`:319`, `:392`, `:488`) discard that and return `None`.
/// - `hermes_cli/mcp_config.py:709-713` — `cmd_mcp_login` calls
///   `_reauth_oauth_server(...)` and DISCARDS the `bool` it returns.
/// - `hermes_cli/cron.py:661-662` — a manual run that FAILED still returns 0
///   from `_job_action`, printing `  Ran now: failed.` (`_run_outcome`, `:677`).
/// - `hermes_cli/plugins_cmd.py:1092-1098` — `_run_capability_consent` prints
///   `capabilities NOT granted (fail closed).` on a non-TTY and returns False,
///   which `cmd_enable` (`:1033`) discards.
///
/// ## The rule
///
/// A run is a success only when the emitter's own SUCCESS line is present and
/// no refusal line is. Absence of both is a failure, not a success — that is
/// exactly the "unknown verb routed to the agent and 'succeeded'" case C5
/// exists to forbid.
///
/// Every marker used by Scarf's call sites has been walked back to v2026.6.19
/// (v0.17.0) and is byte-identical at every tag since, so this judgement does
/// not change behaviour on a pre-target host (charter C1).
public struct HermesCLIOutcome: Sendable, Equatable {
    /// True only when the emitter printed its own success line.
    public let succeeded: Bool
    /// The emitter's own one-line explanation of a refusal, when it printed
    /// one. `nil` on success, and on a failure with nothing quotable.
    ///
    /// **Two documented exceptions, both added by P54**, where the emitter's
    /// line is information the pane needs on a SUCCESS and lives nowhere
    /// else:
    ///
    /// - ``HermesWebhookTestVerdict`` carries `Response ({status}): {body}`
    ///   (`hermes_cli/webhook.py:216` @ `v2026.9.7`) — the gateway's own
    ///   answer to the POST, which is the entire result the button exists to
    ///   show. A test that fired and a test whose route answered are the
    ///   same event to the exit code and different events to the user.
    /// - ``HermesBackupVerdict`` carries `Backup incomplete: {path}`
    ///   (`backup.py:666`), naming WHICH archive is the partial one.
    ///
    /// Every other verdict in this file leaves it `nil` on success, and a
    /// consumer that renders `detail` unconditionally should check which
    /// verdict it is reading.
    public let detail: String?
    /// A refusal the run printed **alongside** a real success line, where the
    /// two are not a contradiction but a PARTIAL write: Hermes wrote one of
    /// the two files it mirrors a key into and refused the other.
    ///
    /// The live shape is `config set terminal.*` — `set_config_value` writes
    /// config.yaml (`hermes_cli/config.py:3506`), then mirrors the key into
    /// `.env` through `save_env_value` (`:3511`), whose
    /// `_env_write_blocked` managed-**scope** arm prints `Cannot set <KEY>: it
    /// is managed by your administrator (…)` and returns (`:2560-2565`) —
    /// after which `:3521` prints `✓ Set <key> = <value> in <config path>`
    /// anyway. `unset_config_value` has the same shape through
    /// `remove_env_value` (`:3576`, `:2610-2612`).
    ///
    /// Round-4 product decision (Alan): that is a partial write, not a
    /// failure. The verdict succeeds — config.yaml really did change — and
    /// this carries the sentence the banner shows so the user learns the
    /// mirror did not.
    ///
    /// `nil` everywhere else, which is every other verdict in this file.
    public let warning: String?

    /// How much the verdict actually KNOWS, which is three states rather than
    /// the two ``succeeded`` can carry.
    ///
    /// `succeeded` answers "may the UI claim the new state?" and is `false`
    /// for both of the negative answers. They are not the same event:
    ///
    /// - ``Confidence/confirmed`` — the emitter printed its own success line.
    /// - ``Confidence/failed`` — a POSITIVE failure signal: a refusal marker
    ///   matched, or the process exited non-zero.
    /// - ``Confidence/unconfirmed`` — exit 0, no success line, no refusal
    ///   line. The C5 answer: never read silence as success, but do not read
    ///   it as a refusal either. The live case is an s6 container host, where
    ///   `_dispatch_via_service_manager_if_s6` (`hermes_cli/gateway.py:5608-5629`
    ///   @ v2026.9.7) prints NOTHING on the success path.
    ///
    /// Two consumers need the distinction rather than the bool:
    /// `HermesFileService.stopHermes()` only takes its `kill -TERM` fallback
    /// on ``Confidence/failed`` (on s6 a bare SIGTERM is read by
    /// `s6-supervise` as a crash and the gateway comes straight back), and
    /// Analytics records `unconfirmed` as its own token instead of laundering
    /// it into `failed`.
    public let confidence: Confidence

    public enum Confidence: String, Sendable, CaseIterable {
        case confirmed, unconfirmed, failed

        /// Fold the two halves of a two-verb action (a Stop followed by a
        /// Start) into one answer. `failed` if either half positively failed,
        /// `confirmed` only when BOTH confirmed, `unconfirmed` in between —
        /// which is what "a restart only succeeded if both halves did" means
        /// once there are three states instead of two.
        public static func combined(_ first: Confidence, _ second: Confidence) -> Confidence {
            if first == .failed || second == .failed { return .failed }
            return first == .confirmed && second == .confirmed ? .confirmed : .unconfirmed
        }
    }

    /// The two-state initialiser every existing call site uses: a success is
    /// ``Confidence/confirmed``, a failure is ``Confidence/failed``. Pass
    /// `confidence:` explicitly for the third state.
    public init(succeeded: Bool, detail: String?, warning: String? = nil) {
        self.init(
            succeeded: succeeded, detail: detail, warning: warning,
            confidence: succeeded ? .confirmed : .failed
        )
    }

    public init(succeeded: Bool, detail: String?, warning: String?, confidence: Confidence) {
        self.succeeded = succeeded
        self.detail = detail
        self.warning = warning
        self.confidence = confidence
    }
}

/// Judges `hermes` CLI runs by their printed output.
public enum HermesCLIVerdict {
    /// Strips SGR/CSI escape sequences. Hermes colours its output through
    /// `rich` and `hermes_cli.colors.color()`; a `Process` pipe is not a TTY so
    /// they are normally suppressed, but `FORCE_COLOR`/`CLICOLOR_FORCE` in the
    /// user's environment (and some SSH wrappers) put them back, and a marker
    /// that starts a line would then be preceded by `ESC[32m`.
    /// NB the pattern is NOT a raw string: `\u{1B}` is a **Swift** escape for
    /// ESC, and ICU's regex dialect has no `\u{…}` form — inside a `#"…"#`
    /// literal it reached the engine verbatim and matched nothing, so this
    /// stripped no colour at all. Anchored markers depend on it.
    public static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[a-zA-Z]",
            with: "",
            options: .regularExpression
        )
    }

    /// The output's non-empty lines, ANSI-stripped and whitespace-trimmed.
    public static func significantLines(_ output: String) -> [String] {
        stripANSI(output)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// One already-trimmed line with any leading status glyph removed, so an
    /// anchored marker can be tested with `hasPrefix`. Hermes prefixes its
    /// success/refusal lines through small helpers — `  ✓ ` / `  ✗ ` / `  ⚠ `
    /// (`hermes_cli/mcp_config.py:34-36`), `⊘` (`plugins_cmd.py:1198`) — and
    /// the marker text starts immediately after.
    public static func unglyphed(_ line: String) -> String {
        var head = Substring(line)
        while let first = head.first, Self.statusGlyphs.contains(first) || first == " " {
            head = head.dropFirst()
        }
        return String(head)
    }

    private static let statusGlyphs: Set<Character> = ["\u{2713}", "\u{2717}", "\u{26A0}", "\u{2298}", "\u{2022}"]

    /// - Parameters:
    ///   - output: combined stdout+stderr (or stdout alone — both work; the
    ///     markers are line-scoped, not offset-scoped).
    ///   - exitCode: used only to fail fast; a zero exit never *implies*
    ///     success.
    ///   - successMarkers: verbatim substrings the emitter prints ONLY on the
    ///     success path.
    ///   - failureMarkers: verbatim substrings the emitter prints ONLY on a
    ///     refusal path.
    ///   - failureWins: what to do when BOTH a success and a failure marker are
    ///     present. Default `false`, which matches the usual emitter shape: the
    ///     refusal arms all `return` before the success line is reached, so a
    ///     success marker is proof and a stray failure phrase inside a report
    ///     body (a scan finding quoting "Error:", say) must not flip a real
    ///     success. `true` is for the emitters that print BOTH by design — the
    ///     one in this group is `cron run`, whose `_job_action` prints the green
    ///     `Triggered job:` line (cron.py:658) and then `  Ran now: failed.`
    ///     (`:662`, `:677`).
    ///   - fallbackDetail: quote the last significant line when no failure
    ///     marker matched. On for commands whose every refusal is a single
    ///     terminal line; off where trailing chatter (hints, next-step
    ///     instructions) would be quoted instead of the reason.
    ///   - successAnchored: require the success marker to START its line
    ///     (after ANSI stripping, trimming and any leading status glyph)
    ///     rather than appear anywhere in it. On for every emitter that
    ///     prints its success line at column 0, which is all of them except
    ///     the `plugins` ones — there the marker is a mid-sentence clause.
    ///     A bare substring is not safe there: with the usual
    ///     `failureWins: false`, a success PHRASE quoted inside a report body
    ///     outranks a real refusal. `do_install` is the live case —
    ///     `_print_tier1_advisory` (hermes_cli/skills_hub.py:704, 726-747) prints
    ///     SKILL.md-derived findings BEFORE `install_from_quarantine` can
    ///     raise (:714-720), so a skill whose own text contains
    ///     `Installed: …` used to be reported installed after it was refused.
    ///   - anchoredFailureMarkers: the `failureAnchored` half of the same
    ///     asymmetry, and for the same reason the success side has one.
    ///     A marker here must START its line (after ANSI stripping, trimming
    ///     and any leading status glyph) instead of appearing anywhere in it.
    ///
    ///     This is what a refusal marker needs whenever the emitter ECHOES
    ///     user text on its success line. `config set`'s does:
    ///     `✓ Set {key} = {value} in {config_path}`
    ///     (`hermes_cli/config.py:3521` @ v2026.9.7). As a bare substring,
    ///     `is managed by` / `Cannot set` inside a QuickCommands prompt or
    ///     any of the fifteen platform-setup forms' free text flipped a real
    ///     write into a reported failure — and with `failureWins: true`, it
    ///     did so unconditionally. Every refusal line on these paths is
    ///     printed at column 0, so anchoring costs nothing and closes it.
    public static func judge(
        output: String,
        exitCode: Int32,
        successMarkers: [String],
        failureMarkers: [String] = [],
        anchoredFailureMarkers: [String] = [],
        failureWins: Bool = false,
        fallbackDetail: Bool = true,
        successAnchored: Bool = false
    ) -> HermesCLIOutcome {
        let lines = significantLines(output)
        func matchesFailure(_ line: String) -> Bool {
            if failureMarkers.contains(where: { line.contains($0) }) { return true }
            guard !anchoredFailureMarkers.isEmpty else { return false }
            let head = unglyphed(line)
            return anchoredFailureMarkers.contains { head.hasPrefix($0) }
        }
        let refusal = lines.first(where: matchesFailure)
        func failed(_ detail: String?, confidence: HermesCLIOutcome.Confidence = .failed) -> HermesCLIOutcome {
            HermesCLIOutcome(
                succeeded: false,
                detail: detail ?? (fallbackDetail ? lines.last : nil),
                warning: nil,
                confidence: confidence
            )
        }
        func matchesSuccess(_ line: String) -> Bool {
            guard successAnchored else { return successMarkers.contains { line.contains($0) } }
            let head = unglyphed(line)
            return successMarkers.contains { head.hasPrefix($0) }
        }
        guard exitCode == 0 else { return failed(refusal) }
        if failureWins, refusal != nil { return failed(refusal) }
        if lines.contains(where: matchesSuccess) {
            return HermesCLIOutcome(succeeded: true, detail: nil)
        }
        // Exit 0 with no success line: a `None`-returning refusal we have no
        // marker for, or an unknown verb whose output the agent wrote. Never a
        // success (C5) — but only a POSITIVE failure signal (a matched refusal
        // marker) makes it ``HermesCLIOutcome/Confidence/failed``. With no
        // marker on either side all we know is that we do not know, and a
        // caller whose fallback is destructive (`stopHermes`'s `kill -TERM`)
        // must be able to tell the two apart.
        return failed(refusal, confidence: refusal == nil ? .unconfirmed : .failed)
    }
}

/// The markers each Scarf call site judges by, captured verbatim from the
/// Hermes source at tag v2026.9.7 (charter C2). Each entry cites the emitting
/// `file:line`. Substrings only — the surrounding text interpolates a name, a
/// path or a count.
public enum HermesCLIMarkers {
    // MARK: skills install / uninstall — hermes_cli/skills_hub.py

    // MARK: tools enable / disable — hermes_cli/tools_config_mcp.py

    /// `_print_success(f"{verb}: {', '.join(successful)}")` where `verb` is
    /// `"Disabled"` or `"Enabled"` — `hermes_cli/tools_config_mcp.py:284-285`
    /// @ v2026.9.7. `print_success` prefixes `✓ `
    /// (`hermes_cli/cli_output.py:13-14`), which `unglyphed` strips, so these
    /// anchor at column 0.
    public static let toolsToggleSuccess = ["Enabled:", "Disabled:"]

    /// Every refusal `tools_disable_enable_command` can print, in source
    /// order, plus ``managedRefusalAnchored`` for the `save_config` arm
    /// (`hermes_cli/config.py:2316-2318`). All are `_print_error`
    /// (`✗ ` prefix, `cli_output.py:21-22`) and NONE of them exits non-zero.
    public static let toolsToggleFailure = managedRefusalAnchored + [
        "Unknown platform '",        // tools_config_mcp.py:247
        "Unknown toolset '",         // :262
        "Toolset '",                 // :268 — "…' is not available on platform '…'"
        "MCP server '",              // :278 — "…' not found in config"
    ]

    /// `c.print(f"[bold green]Installed:[/] {…}")` — hermes_cli/skills_hub.py:720.
    /// (Same line, same prefix, at v2026.6.19:691 through v2026.8.31:799.)
    public static let skillsInstallSuccess = ["Installed:"]

    /// Every refusal `do_install` can print, in source order:
    /// - `Error:` — `_print_error` (hermes_cli/skills_hub.py:134-135), reached from
    ///   `_pinned_sources` (:582) and `_print_fetch_failure` (:592).
    /// - `Installation blocked:` — `_install_blocked` (:498), reached from the
    ///   scan verdict (:699) and `_invalid_path` (:506).
    /// - `is already installed at` (:682) / `Use --force to reinstall.` (:684).
    /// - `Cannot install from URL:` / `Invalid --name:` —
    ///   `_resolve_url_bundle_name` (:520, :525).
    /// - `Installation cancelled.` — `_confirm_install` (:642) and :537.
    public static let skillsInstallFailure = [
        "Error:",
        "Installation blocked:",
        "is already installed at",
        "Use --force to reinstall.",
        "Cannot install from URL:",
        "Invalid --name:",
        "Installation cancelled.",
    ]

    /// `_report_pair` prints `uninstall_skill`'s message green on success —
    /// `Uninstalled '<name>' from <path>` (tools/skills_hub_install.py:220),
    /// via hermes_cli/skills_hub.py:917,144-150.
    public static let skillsUninstallSuccess = ["Uninstalled"]

    /// `_report_pair`'s failure arm is `_print_error` → `Error: …`
    /// (hermes_cli/skills_hub.py:149, 134-135). `Uninstall '<name>'?` cancelled prints
    /// nothing at all, which the "no success marker" rule already catches.
    public static let skillsUninstallFailure = ["Error:"]

    // MARK: managed installs — hermes_cli/config.py

    /// The refusals a package-manager-managed Hermes prints, anchored, shared
    /// by every config-mutating verb Scarf shells.
    ///
    /// `get_managed_system()` (`hermes_cli/config.py:276-290` @ v2026.9.7)
    /// answers from `HERMES_MANAGED` or a `$HERMES_HOME/.managed` marker file;
    /// `is_managed()` (`:294-296`) is its bool. Three distinct guards print the
    /// refusal, and none of them is a `sys.exit` on the exit-0 arms:
    ///
    /// - `managed_error(action)` → `format_managed_message` (`:445-455`) prints
    ///   `Cannot <action>: this Hermes installation is managed by <system>.` to
    ///   **stderr** and the caller `return`s — Python turns that into **exit
    ///   0**. Reached from `set_config_value` (`:3450-3452`),
    ///   `unset_config_value` (`:3549-3551`), `save_config` (`:2316-2318`),
    ///   `edit_config` (`:2956-2958`) and `_env_write_blocked` (`:2556-2558`).
    /// - `_exit_if_key_managed(key, action)` (`:3363-3371`) prints
    ///   `Cannot <action> '<key>': it is managed by your administrator (…)`
    ///   and `sys.exit(1)`.
    /// - `_env_write_blocked`'s managed-scope arm (`:2560-2565`) prints
    ///   `Cannot <action> <KEY>: it is managed by your administrator (…)` and
    ///   returns True — but `set_config_value`'s `.env` branch prints its own
    ///   `✓ Set …` line afterwards regardless (`:3468`), which is exactly why
    ///   every verdict using this marker sets `failureWins: true`.
    ///
    /// **Why anchored, and why not the bare verb.** `set_config_value` ECHOES
    /// the user's value on its success line — `✓ Set {key} = {value} in
    /// {config_path}` (`:3521`) — so an unanchored `is managed by` /
    /// `Cannot set` turned a completed write into a reported failure under
    /// `failureWins: true` (round-4 review of P39). Every refusal line above is
    /// printed at **column 0**, so `hasPrefix` on ``HermesCLIVerdict/unglyphed``
    /// is the safe form.
    ///
    /// **Why not the bare `Cannot ` anchor** (P39c). `plugins update` echoes
    /// the raw `git pull` output (`cmd_update` prints `[dim]{out}[/dim]`,
    /// `hermes_cli/plugins_cmd.py:829`) and a post-pull
    /// `format_scan_report` (`:844`) — text Hermes does not control — and
    /// ``HermesCLIVerdict/significantLines`` trims leading whitespace, so an
    /// indented `Cannot open …` from git would be read as a managed refusal on
    /// a verdict that runs `failureWins`. The anchors are therefore the FULL
    /// action prefixes, which is every action string any `managed_error(…)` /
    /// `format_managed_message(…)` caller passes on a path Scarf shells:
    ///
    /// | source | line @ v2026.9.7 | printed prefix |
    /// | --- | --- | --- |
    /// | `save_config` | `:2317` | `Cannot save configuration` |
    /// | `set_config_value` | `:3451` | `Cannot set configuration values` |
    /// | `unset_config_value` | `:3550` | `Cannot unset configuration values` |
    /// | `save_env_value` → `_env_write_blocked` | `:2577` → `:2557`/`:2562` | `Cannot set <KEY>` |
    /// | `remove_env_value` → `_env_write_blocked` | `:2612` → `:2557`/`:2562` | `Cannot remove <KEY>` |
    /// | `_exit_if_key_managed` | `:3460`/`:3552` → `:3369` | `Cannot set '<key>'` / `Cannot unset '<key>'` |
    ///
    /// **Deliberately NOT covered**, because Scarf never shells the verb:
    /// `edit_config`'s `Cannot edit configuration` (`:2957`), `gateway`'s
    /// `Cannot run gateway setup` / `Cannot install gateway service` /
    /// `Cannot uninstall gateway service` (`hermes_cli/gateway.py:5580`,
    /// `:5919`, `:5945`), `Cannot update Hermes Agent`
    /// (`hermes_cli/main.py:2189`, `hermes_cli/cli_commands_mixin.py:2590`)
    /// and `Cannot run setup wizard` (`hermes_cli/setup.py:663`). Scarf's
    /// gateway verdict judges `start|stop|restart` only and carries its own
    /// `Cannot restart gateway as a service` anchor — see
    /// ``gatewayServiceFailureAnchored``.
    ///
    /// **Floor walk.** Every action string above is byte-identical back to
    /// **v2026.4.3**, the tag that introduced `format_managed_message`
    /// (`hermes_cli/config.py:105-129`): `save configuration` (`:1605`),
    /// `set {key}` (`:1749`), `set configuration values` (`:2041`) and
    /// `edit configuration` (`:2009`); `remove {key}` joins at v2026.5.28
    /// (`:5133`) and `unset configuration values` at v2026.7.20 (`:8871`).
    /// The v2026.4.3–v2026.7.30 spellings hard-code `NixOS`/`Homebrew` in the
    /// system half of the sentence, never in the `Cannot <action>` half, so
    /// the prefixes are stable across every tag Scarf supports (charter C1).
    public static let managedRefusalAnchored = [
        "Cannot save configuration",
        "Cannot set",
        "Cannot unset",
        "Cannot remove",
    ]

    // MARK: config set — hermes_cli/config.py

    /// `set_config_value`'s two success lines, both at column 0 behind a `✓`
    /// that `unglyphed` strips: `✓ Set {key} in {env_path}` for the `.env`
    /// branch (`hermes_cli/config.py:3468` @ v2026.9.7) and
    /// `✓ Set {key} = {value} in {config_path}` for the config.yaml branch
    /// (`:3521`). Judged ANCHORED so `Set ` cannot match mid-sentence — the
    /// same discipline `configUnsetSuccess` uses.
    ///
    /// NB `_guard_section_overwrite`'s redirect line (`:3391-3393`) is
    /// `✓ Redirecting bare 'model' to 'model.default' …`, which does NOT
    /// start with `Set ` — it precedes a real write that prints `:3521`.
    public static let configSetSuccess = ["Set "]

    /// EVERY refusal arm on `set_config_value`'s path at v2026.9.7, in source
    /// order (`hermes_cli/config.py:3445-3527`). The point of enumerating all
    /// of them rather than the managed one is that this list is what makes the
    /// verdict safe to apply to a non-managed host too:
    ///
    /// 1. `if is_managed(): managed_error("set configuration values"); return`
    ///    (`:3450-3452`) — `Cannot set configuration values: this Hermes
    ///    installation is managed by <system>.` on **stderr, exit 0**.
    /// 2. `_exit_invalid(f"✗ Invalid config key: {key!r} (empty or surrounding
    ///    whitespace).")` (`:3454-3455`) — exit 1.
    /// 3. `_exit_invalid(f"✗ Invalid config key: {key!r} — contains an empty
    ///    path segment …")` (`:3456-3458`) — exit 1.
    /// 4. `_exit_if_key_managed(key, "set")` (`:3460`, printing at `:3368-3370`)
    ///    — `Cannot set '<key>': it is managed by your administrator (…)`,
    ///    exit 1.
    /// 5. the `.env` branch's `_env_write_blocked` (`:2552-2566`, reached
    ///    through `save_provider_env_credential`) — `Cannot set <KEY>: …`,
    ///    and then `:3468` prints `✓ Set …` ANYWAY. This is the arm that
    ///    forces `failureWins: true`.
    /// 6. `_guard_section_overwrite` (`:3374-3417`) — `✗ Cannot set '<key>' to
    ///    a scalar — '<key>' is a configuration section with n sub-key(s).`,
    ///    exit 1.
    /// 7. `_set_nested`'s `ValueError` → `_exit_invalid(f"✗ {e}")` (`:3495-3497`)
    ///    — exit 1, arbitrary text, caught by the exit code.
    /// 8. `require_readable_config_before_write`'s `RuntimeError` (`:1950-1981`),
    ///    surfaced by `_run_write_command` as `✗ Refusing to overwrite …`
    ///    (`:3598-3604`) — exit 1, caught by the exit code.
    /// 9. `_usage_exit` for a missing key/value (`:3585-3593`) — exit 1.
    /// 10. the **terminal `.env` mirror** (round-4 review). After the
    ///    config.yaml write lands (`_write_user_config`, `:3506`),
    ///    `terminal_config_env_var_for_key(key)` finds an env twin for every
    ///    `terminal.*` key except `terminal.cwd` and calls `save_env_value`
    ///    (`:3509-3511`) → `_env_write_blocked` (`:2574-2578`), whose
    ///    managed-**scope** arm prints `Cannot set <KEY>: it is managed by
    ///    your administrator (…)` and returns (`:2560-2565`) — and `:3521`
    ///    prints `✓ Set …` anyway. Exit 0, both lines. This is a PARTIAL
    ///    write, not a failure (round-4 product decision): config.yaml really
    ///    did change. ``HermesConfigSet/judge(output:exitCode:)`` reports it
    ///    as a success carrying ``HermesCLIOutcome/warning``.
    ///    `unset_config_value` has the same shape through `remove_env_value`
    ///    (`:3574-3576`).
    ///
    /// Arms 7-9 print text this list cannot anchor on, which is fine: they all
    /// exit non-zero, and `HermesCLIVerdict.judge` fails fast on that. Only
    /// arms 1 and 5 can reach the "exit 0 with a refusal" state, and both are
    /// quoted here.
    ///
    /// What is deliberately NOT in this list: the two `Warning: value for
    /// '<key>' looks like a list/mapping …` lines (`:3326-3330`, `:3334-3337`)
    /// and `_print_unknown_key_notice` (`:3433-3443`). All three are printed
    /// on the SUCCESS path — the value IS saved — so quoting them as failures
    /// would invert a real write.
    ///
    /// **Consumed ANCHORED** (round-4 review): see
    /// ``managedRefusalAnchored``. `Cannot set` (and `Cannot save
    /// configuration` under it) is the anchor for arms 1, 4, 5
    /// and 6; `Invalid config key:` for arms 2 and 3, both printed through
    /// `_exit_invalid` (`:3422-3424`) behind a `✗ ` that ``unglyphed``
    /// strips. Every entry here starts its line in the Hermes source.
    public static let configSetFailure = managedRefusalAnchored + [
        "Invalid config key:",
    ]

    // MARK: config unset — hermes_cli/config.py

    /// `print(f"✓ Unset {key} from {config_path}")` — the ONLY line
    /// `unset_config_value` prints on the success path, both for the
    /// config.yaml arm (`hermes_cli/config.py:3582` @ v2026.9.7,
    /// `:8923` @ v2026.7.20) and the `.env` arm (`:3562` / `:8896`).
    /// Judged anchored, so the leading `✓` is stripped by `unglyphed`.
    public static let configUnsetSuccess = ["Unset "]

    /// `config unset` has ONE refusal that exits non-zero and one that does
    /// NOT, which is exactly why this write cannot be judged by exit code:
    ///
    /// - `is_managed()` → `managed_error("unset configuration values")` →
    ///   `format_managed_message` prints `Cannot unset configuration values:
    ///   this Hermes installation is managed by …` to stderr and the function
    ///   RETURNS (`hermes_cli/config.py:3549-3551`, `:445-455` @ v2026.9.7;
    ///   `:8870-8872`, `:659` @ v2026.7.20) — Python turns that into **exit
    ///   0**.
    /// - `_exit_if_key_managed(key, "unset")` prints `Cannot unset '<key>':
    ///   it is managed by your administrator (…)` and `sys.exit(1)`
    ///   (`:3363-3371` @ v2026.9.7; inlined at `:8873-8885` @ v2026.7.20).
    /// - `_exit_invalid(f"Config key not set: {key}")` → the same text and
    ///   `sys.exit(1)` (`:3579`, `:3422-3424` @ v2026.9.7; printed inline at
    ///   `:8916-8918` @ v2026.7.20).
    ///
    /// Both `Cannot …` spellings share the `Cannot unset` prefix, so one
    /// marker quotes either.
    ///
    /// P39: ``managedRefusalAnchored`` is prepended, and the verdict runs
    /// `failureWins`.
    /// `Cannot unset` already quotes the `unset_config_value` managed arm, but
    /// the `.env` branch reaches `_env_write_blocked` through
    /// `remove_env_value` (`:2552-2566`) and `unset_config_value` prints
    /// `✓ Unset …` (`:3582`) after it regardless — a success line and a
    /// refusal line in the same run, which only `failureWins` resolves the
    /// right way.
    ///
    /// **Consumed ANCHORED** (round-4 review): `Cannot unset` covers both
    /// `Cannot unset …` spellings and `Cannot remove` covers
    /// `_env_write_blocked`'s `Cannot remove <KEY>: …`
    /// (`:2610-2612` → `:2560-2565`);
    /// `Config key not set:` is printed at column 0 through `_exit_invalid`.
    public static let configUnsetFailure = managedRefusalAnchored + [
        "Config key not set:",
    ]

    // MARK: skills trust / untrust — hermes_cli/main_agent_cmds.py

    /// `_cmd_skills_trust`'s four terminal success lines, all at column 0 with
    /// no glyph (`hermes_cli/main_agent_cmds.py` @ v2026.9.7):
    /// `Trusted: {root}` (`:235`), `Already trusted: {root}` (`:230`),
    /// `Untrusted: {root}` (`:225`) and `{root} was not trusted.` (`:221`).
    ///
    /// The last one is a success from Scarf's side for the same reason
    /// `is already disabled.` is on the plugins path: the repo is in the state
    /// the click asked for.
    ///
    /// Judged as plain substrings, NOT anchored, because `{root} was not
    /// trusted.` opens with the interpolated path. That is safe here: the only
    /// other lines this handler prints are `Project skills from this repo will
    /// no longer load.` (`:226`), `{n} project skill(s) will load in sessions
    /// started inside this repo …` (`:242-244`) and `No project skills found
    /// yet — add them under {subdirs}.` (`:246-247`), none of which contains
    /// any of these. NB `Already trusted: ` does not contain `Trusted: ` —
    /// different case on the `t` — so the two stay distinct markers.
    ///
    /// **Tag walk** (C1): `hermes skills trust|untrust` ARRIVES at
    /// **v2026.8.16.2** (`hermes_cli/main.py:12051-12052` dispatching
    /// `_cmd_skills_trust` at `:12059`); v2026.8.16 and earlier route the
    /// action to `skills_command` instead, where it is unknown. All seven
    /// print statements are byte-identical from that tag through v2026.9.7
    /// (v2026.8.18, v2026.8.19, v2026.8.27, v2026.8.31 checked line by line;
    /// only the file moved, to `main_agent_cmds.py:179-247`).
    ///
    /// On a host BELOW that floor the verb is unknown and prints none of
    /// these, so this verdict reports a failure — which is the C5 answer, and
    /// strictly better than the exit code Scarf read before. Gating the
    /// surface itself is a separate follow-up (`t-74df283e`).
    public static let skillsTrustSuccess = [
        "Trusted: ",
        "Already trusted: ",
        "Untrusted: ",
        "was not trusted.",
    ]

    /// The refusals on that path:
    /// - `Not a directory: {root}` (`:197`) and `Not inside a git checkout.`
    ///   (`:202-204`), both `-> None` returns at **exit 0**.
    /// - the managed refusal `save_config` prints UNDER it (`:224`, `:234` →
    ///   `hermes_cli/config.py:2316-2318`), also exit 0 and followed by the
    ///   success line — hence ``HermesSkillsTrust``'s `failureWins: true`.
    ///
    /// **Consumed ANCHORED** (round-4 review). All three of this handler's
    /// own lines are printed at column 0 with no glyph
    /// (`hermes_cli/main_agent_cmds.py:197`, `:202-204` @ v2026.9.7), and the
    /// `save_config` refusal underneath is `Cannot save configuration: …`,
    /// which ``managedRefusalAnchored`` covers.
    public static let skillsTrustFailure = managedRefusalAnchored + [
        "Not a directory:",
        "Not inside a git checkout.",
    ]

    // MARK: memory off — hermes_cli/main_agent_cmds.py

    /// `_cmd_memory_off` (`hermes_cli/main_agent_cmds.py:10-18` @ v2026.9.7)
    /// is the FOURTH door onto `save_config`'s exit-0 managed refusal: it
    /// clears `memory.provider`, calls `save_config(config)` (`:16`) and then
    /// prints `  ✓ Memory provider: built-in only` (`:17`) whether or not the
    /// save happened. Anchored, so `_success`'s `✓ ` is stripped by
    /// `unglyphed`.
    ///
    /// **Tag walk** (C1): `print("\n  ✓ Memory provider: built-in only")`
    /// followed by `print("  Saved to config.yaml\n")`, byte-identical at
    /// every tag Scarf supports — `hermes_cli/main.py:11424` @ v2026.6.19
    /// (v0.17.0, the floor), `:13200` @ v2026.7.20, `:12863` @ v2026.8.31,
    /// and `hermes_cli/main_agent_cmds.py:17` @ v2026.9.7 after the file
    /// split. Only the file and the line moved.
    public static let memoryOffSuccess = ["Memory provider: built-in only"]

    /// `_cmd_memory_off` prints no refusal of its own — it has no failure arm.
    /// Everything here comes from `save_config` underneath it
    /// (`hermes_cli/config.py:2316-2318`), which is why the verdict must run
    /// `failureWins: true`.
    ///
    /// **Consumed ANCHORED** (round-4 review): the one line this verdict can
    /// see is `Cannot save configuration: this Hermes installation is managed
    /// by …`, printed at column 0 on stderr.
    public static let memoryOffFailure = managedRefusalAnchored

    // MARK: sessions export — hermes_cli/sessions_cmd.py

    /// Every file-writing export path ends in an `Exported …` summary:
    /// `_write_output` (:83) printing `_render_only` (:344), `_render_html`
    /// (:352) or `_render_jsonl` (:357); plus `:424`, `:434`, `:480`, `:508`.
    /// Stable since v2026.6.19 (main.py:12279).
    ///
    /// NB this marker only applies to a real `--output <path>` run.
    /// `_write_output` (:78-80) prints NO summary when the output is `-`; that
    /// path is judged by validating the payload instead.
    public static let sessionsExportSuccess = ["Exported "]

    /// The refusals `_cmd_export` and its renderers print, all to stdout:
    /// - `not found.` — `_not_found` (:47).
    /// - `Error:` — the filter-parse arm (:302).
    /// - the `_FLAT_EXPORTERS` usage messages (:363, :365, :366).
    /// - the markdown/QMD usage refusals (:443, :456, :459, :465-466).
    /// - `Refusing to export unredacted trace content.` (:436) and the trace
    ///   usage refusals (:389, :398, :422).
    /// - `Pass --force to overwrite.` (:476, :500).
    public static let sessionsExportFailure = [
        "not found.",
        "Error:",
        "--only user-prompts supports",
        "HTML export requires an output file path.",
        "JSONL export requires an output path",
        "Markdown/QMD export writes files;",
        "--delete-after-verified requires --yes.",
        "--delete-after-verified is only supported with --session-id.",
        "Refusing bulk export without a filter.",
        "Pass --force to overwrite.",
        "refusing to export unredacted trace content.",
        "No session found to export.",
        "--upload exports one session:",
        "No transcript to export for session",
        "--dry-run requires at least one filter.",
    ]

    // MARK: mcp login — hermes_cli/mcp_config.py

    /// `_success(f"Authenticated — {len(tools)} tool(s) available")` (:695)
    /// and `_success("Authenticated (server reported no tools)")` (:697),
    /// both `  ✓ ` -prefixed by `_success` (:34). Stable since v2026.6.19:746.
    public static let mcpLoginSuccess = ["Authenticated"]

    /// The refusals on the login path, all `_error`/`_warning` -prefixed
    /// (`  ✗ ` / `  ⚠ `, mcp_config.py:35-36):
    /// - `Server '<name>' not found in config.` — `_lookup_server` (:104);
    ///   `cmd_mcp_login` (:711-713) then does nothing at all.
    /// - `has no URL — not an OAuth-capable server` (:631).
    /// - `is not configured for OAuth` (:634).
    /// - `oauth.flow must be browser or device` (:641).
    /// - `no OAuth token was obtained — authentication did not complete.`
    ///   (:677) — the case where the probe SUCCEEDS but the flow did not.
    /// - `Authentication failed:` (:705).
    public static let mcpLoginFailure = [
        "not found in config.",
        "not an OAuth-capable server",
        "is not configured for OAuth",
        "oauth.flow must be browser or device",
        "no OAuth token was obtained",
        "Authentication failed:",
    ]

    // MARK: cron run — hermes_cli/cron.py

    /// `_job_action` prints `{success_verb} job: <name> (<id>)` (:658). The
    /// `run` action's verb is `"Triggered"` (`_JOB_ACTIONS`, cron.py:763), so
    /// the line reads `Triggered job: <name> (<id>)`. Stable since
    /// v2026.6.19:350.
    public static let cronRunSuccess = ["Triggered job:"]

    /// - `Failed to run job:` — `_job_action` (:655), the only nonzero arm.
    /// - `Ran now: failed.` — `_run_outcome` (:677), printed at :662 AFTER the
    ///   green `Triggered job:` line and still returning 0. This is the marker
    ///   that must beat the success marker, which is why a failure match wins.
    ///   A v0.17 host prints no `Ran now:` line at all (it first appears at
    ///   v2026.7.1:411), so this marker simply never fires there — the pre-
    ///   target verdict is unchanged (charter C1).
    public static let cronRunFailure = [
        "Failed to run job:",
        "Ran now: failed.",
    ]

    // MARK: plugins enable / disable — hermes_cli/plugins_cmd.py

    /// `✓ Plugin <key> enabled. Takes effect on next session.` (:1023), or
    /// `Plugin '<key>' is already enabled.` (:1012) when it was already on.
    /// Stable since v2026.6.19:801.
    public static let pluginsEnableSuccess = [
        "Takes effect on next session.",
        "is already enabled.",
    ]

    /// `capabilities NOT granted (fail closed).` —
    /// `_run_capability_consent`'s non-TTY arm (:1092-1098), which
    /// `cmd_enable` (:1033) calls and discards. Scarf has no TTY, so this is
    /// the arm it ALWAYS takes for a capability-declaring plugin.
    /// `_fail` (:1005, :999) prints `Plugin '<name>' is not installed or
    /// bundled.` / `was removed.` and exits nonzero.
    ///
    /// P39: the managed refusal rides ANCHORED alongside this set (see
    /// ``managedRefusalAnchored``), not inside it — these markers are
    /// mid-sentence clauses and cannot be anchored themselves. This
    /// verdict already runs `failureWins: true` for the consent-screen
    /// reason, which is the same shape.
    public static let pluginsEnableFailure = [
        "capabilities NOT granted",
        "is not installed or bundled.",
        "was removed.",
    ]

    /// `⊘ Plugin <key> disabled. Takes effect on next session.` (:1198), or
    /// the already-disabled line.
    public static let pluginsDisableSuccess = [
        "Takes effect on next session.",
        "is already disabled.",
    ]

    /// Same `_fail` refusal as enable, minus one: `disable` runs no consent
    /// screen and no legacy-relay refusal.
    ///
    /// `was removed.` was a DEAD marker here. The phrase is printed only by
    /// `_refuse_legacy_relay` (plugins_cmd.py:996-1002 at v2026.9.7), which is
    /// defined inside — and called only from — `cmd_enable` (`:1002`, `:1007`).
    /// Floor walk over every `v2026.*` tag carrying `hermes_cli/plugins_cmd.py`
    /// (v2026.3.23 … v2026.9.7): the string first appears at **v2026.8.19**, at
    /// lines 1424 and 1439, both inside `cmd_enable` (`:1405`) and well above
    /// `cmd_disable` (`:1710`); identical at v2026.8.27 and v2026.8.31. So no
    /// supported host has ever printed it from `plugins disable`, and carrying
    /// it here only risked flipping a real disable into a failure.
    ///
    /// P39: the managed refusal rides ANCHORED alongside this set (see
    /// ``managedRefusalAnchored``). `cmd_enable`/`cmd_disable` mutate
    /// config.yaml through `save_config` (`hermes_cli/plugins_cmd.py:115-120`),
    /// whose managed arm prints to stderr and RETURNS
    /// (`hermes_cli/config.py:2316-2318`) — after which the handler prints its
    /// own `✓ Plugin … enabled.` / `⊘ Plugin … disabled.` line
    /// (`:1022-1023`, `:1196-1198`). Both markers in one run, exit 0, so the
    /// verdict must run `failureWins`.
    public static let pluginsDisableFailure = [
        "is not installed or bundled.",
    ]

    /// `✓ Plugin <name> updated.` (:828) or
    /// `✓ Plugin <name> is already up to date.` (:826) — `cmd_update`'s two
    /// success lines, both printed AFTER the capability consent screen, which
    /// is why `update` judges with `failureWins: true` like `enable`.
    public static let pluginsUpdateSuccess = [
        "updated.",
        "is already up to date.",
    ]

    /// `cmd_update` (plugins_cmd.py:822) calls `_run_capability_consent(...)`
    /// and DISCARDS its bool exactly as `cmd_enable` does, so the non-TTY arm
    /// (:1092-1098) fires and the update still announces success. That
    /// ungranted-capability case is the ONLY failure `update` can reach at
    /// exit 0, which is why it is the only marker here.
    ///
    /// **A bare `Error:` does not belong in this set.** Every other refusal
    /// `cmd_update` can reach goes through `_fail` → `sys.exit(1)`
    /// (`:80-83`, call site `:809`), so the exit code already catches it —
    /// while the same run prints text it does NOT control: the post-pull
    /// `format_scan_report(scan_result)` over the freshly pulled tree
    /// (`:844`, via `_rescan_after_update` at `:819`) and the raw `git pull`
    /// output (`:829`). A scan finding that quotes `Error:` out of a plugin's
    /// own source, or a commit message containing it, would be matched as a
    /// bare substring — and this set is consumed with `failureWins: true`, so
    /// that turns a completed update into a reported failure. Same asymmetry
    /// the success side fixed by anchoring.
    ///
    /// P39: the managed refusal rides ANCHORED alongside this set (see
    /// ``managedRefusalAnchored``) for the same reason as
    /// ``pluginsEnableFailure``; this verdict already runs `failureWins`.
    public static let pluginsUpdateFailure = [
        "capabilities NOT granted",
    ]

    /// `cmd_install` (plugins_cmd.py:764) discards the same bool. Unlike
    /// `enable`/`update`, `install` reports through `HermesPluginInstallOutcome`,
    /// so this is the one marker that path needs.
    public static let pluginsConsentRefusal = "capabilities NOT granted"

    // MARK: skills audit / update — hermes_cli/skills_hub.py

    /// `do_audit` is `-> None` (hermes_cli/skills_hub.py:879-880) and exits 0 on its
    /// refusal too. `Auditing <n> skill(s)...` (:893) is the only line that says
    /// the scan actually ran; `No hub-installed skills to audit.` (:887) is a
    /// legitimate empty run, not a failure. Both byte-identical back to
    /// v2026.6.19.
    public static let skillsAuditSuccess = [
        "Auditing ",
        "No hub-installed skills to audit.",
    ]

    /// `_print_error` (hermes_cli/skills_hub.py:134-135) via the unknown-name arm (:891).
    public static let skillsAuditFailure = ["Error:"]

    /// `do_update`'s nothing-to-do line (hermes_cli/skills_hub.py:849), verbatim and
    /// byte-identical back to v2026.6.19.
    public static let skillsUpdateNoUpdates = "No updates available."

    /// `do_update`'s per-skill ATTEMPT line (hermes_cli/skills_hub.py:864). It is printed
    /// before `do_install` runs, so it proves an attempt and nothing more.
    public static let skillsUpdateAttempt = "Updating:"

    /// The refusals reachable on the **update** path — `skillsInstallFailure`
    /// minus the two lines `do_install` can only print for a *plain* install.
    ///
    /// `do_update` always calls `do_install(..., force=True)`
    /// (hermes_cli/skills_hub.py:868), and `do_install` prints
    /// `Warning: '<name>' is already installed at <path>` (:682)
    /// **unconditionally** whenever the lock has an entry — which, for an
    /// update, it always does — and only THEN checks `if not force` (:683).
    /// So on this path the warning is printed on every single skill,
    /// including the ones that update perfectly, and taking it as the
    /// refusal made "Update attempted — …" quote a benign warning instead of
    /// the `Installation blocked:` line that actually stopped the install.
    /// `Use --force to reinstall.` (:684) sits inside that `if not force`
    /// and is therefore unreachable under `force=True`; it is dropped here
    /// too rather than carried as a marker that can only ever misfire.
    ///
    /// Both lines stay in `skillsInstallFailure`, where they are load-bearing:
    /// a plain `skills install` of an already-installed skill IS refused by
    /// exactly that pair. This is why the two sets are no longer one list.
    public static let skillsUpdateFailure = skillsInstallFailure.filter {
        $0 != "is already installed at" && $0 != "Use --force to reinstall."
    }

    // MARK: pairing approve / revoke — hermes_cli/pairing.py

    /// `_cmd_approve`'s only success line —
    /// `\n  Approved! User {display} on {platform} can now use the bot~`
    /// (pairing.py:68 @ v2026.9.7). Anchored after the trim, since the
    /// emitter indents it by two spaces.
    ///
    /// Walked across every `v2026.*` tag: `hermes_cli/pairing.py` exists at
    /// all 32 of them and the line is byte-identical at each (v2026.3.12:74
    /// … v2026.9.7:68), so this judgement is the same on every host Scarf
    /// supports (C1).
    public static let pairingApproveSuccess = ["Approved! User "]

    /// `_cmd_approve`'s two refusal shapes, both at exit 0 because
    /// `_cmd_approve` and `pairing_command` are plain `-> None`
    /// (pairing.py:56, :3-19):
    /// - the unknown/expired arm (:80). Its wording gained a prefix at
    ///   **v2026.7.30** — NOT v2026.8.3, as this doc and the memory note both
    ///   said: `Code '<code>' not found or expired…` at `v2026.7.20:95` →
    ///   `Pairing request or code '<code>' not found or expired…` at
    ///   `v2026.7.30:100`, and still that spelling at `v2026.9.7:80`. So the
    ///   marker is the tail both spellings share.
    /// - the rate-limit lockout (:76). First tag: **v2026.5.7**; below that
    ///   `_cmd_approve` has no lockout branch at all, so the marker is
    ///   simply never printed there and the older host is judged by the
    ///   other two lines exactly as a newer one is.
    public static let pairingApproveFailure = [
        "not found or expired for platform",
        pairingLockoutRefusal,
    ]

    /// The lockout refusal itself (pairing.py:76 @ v2026.9.7), named because
    /// the detail composer has to recognise it — it is the one refusal whose
    /// reason spans two printed lines.
    ///
    /// **A grep for this string says "absent" on every tag below v2026.9.7,
    /// and that is a false negative.** Until v2026.9.7 the sentence was built
    /// from two adjacent f-string literals — `f"\n  Platform '{platform}' is
    /// locked out after too many failed "` + `f"approval attempts."`
    /// (`v2026.8.31:91-93`) — so the source never contains the marker as one
    /// run of bytes while the PRINTED text is byte-identical. Judge this
    /// floor by the emitted line, not by `git grep`.
    public static let pairingLockoutRefusal = "is locked out after too many failed approval attempts."

    /// The lockout's remediation line, `  Lockout clears in ~{mins}
    /// minute(s).` (pairing.py:77), printed immediately after the lockout
    /// refusal and byte-identical since v2026.5.7. It is quoted verbatim
    /// alongside the refusal — the countdown IS the answer to "what do I do
    /// now", and summarising it away leaves the operator with nothing.
    public static let pairingLockoutClears = "Lockout clears in ~"

    /// `_cmd_revoke`'s success line — `\n  Revoked access for user
    /// {user_id} on {platform}.\n` (pairing.py:88). Byte-identical at all
    /// 32 `v2026.*` tags.
    public static let pairingRevokeSuccess = ["Revoked access for user "]

    /// `_cmd_revoke`'s only refusal — `User {user_id} not found in approved
    /// list for {platform}.` (pairing.py:90), printed when `store.revoke`
    /// returned falsey, and still exit 0. Byte-identical at all 32 tags.
    public static let pairingRevokeFailure = ["not found in approved list for"]

    // MARK: gateway start / stop / restart — hermes_cli/gateway.py

    /// The detached fallback's success line — `✓ Started gateway as a
    /// background process instead` (`gateway.py:3614`, inside
    /// `_launchd_fallback_to_detached` `:3607-3618` @ v2026.9.7).
    ///
    /// **This is a real start, not a degradation notice.** `_spawn_detached_gateway`
    /// (`:3583-3604`) has already `Popen`ed the gateway when this prints, and
    /// the helper returns True; its own failure arm prints
    /// `✗ Failed to start the gateway as a background process.` through
    /// `print_error` and `sys.exit(1)` (`:3619-3622`, `exit_on_failure`
    /// defaults True and the one call site — `_launchd_degrade_or_raise`,
    /// `:3626-3630` — never overrides it), so the exit code owns that half.
    ///
    /// It is reached on BOTH verbs Scarf shells that can hit launchd:
    /// `gateway start` through `_launchd_bootstrap_and_kickstart` (`:3953`)
    /// and `gateway restart` through `launchd_restart`'s two
    /// `_launchd_degrade_or_raise` arms (`:4068`, `:4079`). `launchd_stop`
    /// never reaches it — it swallows the unmanageable-domain error and falls
    /// through to the PID wait, ending on `✓ Service stopped` (`:3978`).
    /// Present since v2026.6.19 (`:3315` there), so no capability floor.
    ///
    /// The `⚠ launchd cannot manage the gateway on this macOS version (…)`
    /// line printed just before it (`:3612`) matches no failure marker:
    /// `managedRefusalAnchored` anchors `Cannot save configuration` /
    /// `Cannot set` / `Cannot unset` / `Cannot remove`, and this line starts
    /// `launchd cannot` after ``HermesCLIVerdict/unglyphed(_:)``.
    public static let gatewayDetachedFallbackStarted = "Started gateway as a background process instead"

    /// Windows's "it was already up, nothing to do" line —
    /// `print(f"✓ Gateway already running (PID: {…})")`
    /// (`hermes_cli/gateway_windows.py:698`, `_report_already_running`) @
    /// v2026.9.7. A real state the user asked for, on both `start` and
    /// `restart` (`restart()` is stop + start, `:1380-1399`).
    ///
    /// **The colon is load-bearing.** `gateway/run.py:4769` prints
    /// `❌ Gateway already running (PID {n}).` — a REFUSAL, from
    /// `_start_gateway_replace_existing_instance`, which returns False and
    /// aborts startup — with no colon after `PID`. That line reaches Scarf
    /// whenever a run ends inside `run_gateway` (the foreground restart arm),
    /// and before P40c the ONLY thing keeping the bare `Gateway already
    /// running` spelling off it was that `❌` is not in
    /// ``HermesCLIVerdict``'s glyph set, so ``HermesCLIVerdict/unglyphed(_:)``
    /// left it at the head of the line and the anchor missed — an accident of
    /// one character standing in for a decision. The two are told apart by
    /// what Hermes actually prints now: this marker carries `(PID: `, and the
    /// colon-less spelling is a refusal marker in
    /// ``gatewayServiceFailure``.
    public static let gatewayWindowsAlreadyRunning = "Gateway already running (PID: "

    /// Every success line `gateway start` can print, matched ANCHORED at
    /// column 0 after the glyph. `✓ Service started` (`gateway.py:3927`,
    /// `:3940`, `launchd_start`), `✓ {User|System} service started`
    /// (`:3171`, `systemd_start` — the scope word comes from
    /// `_service_scope_label(system).capitalize()`, `:2179-2180`, so exactly
    /// these two spellings exist), the two Windows lines
    /// (`hermes_cli/gateway_windows.py:971`, `:698`) and the launchd detached
    /// fallback (``gatewayDetachedFallbackStarted``).
    public static let gatewayStartSuccess = [
        "Service started",
        "User service started",
        "System service started",
        "Gateway started via",
        gatewayWindowsAlreadyRunning,
        gatewayDetachedFallbackStarted,
    ]

    /// `gateway stop`'s success lines. The `_cmd_stop` trio all open
    /// `Stopped ` (`gateway.py:5991`, `:5996`, `:6000`), as does the s6
    /// summary (`:5653`); the backends add their own
    /// (`launchd_stop` `:3978`, `systemd_stop` `:3186`).
    public static let gatewayStopSuccess = [
        "Stopped ",
        "Service stopped",
        "User service stopped",
        "System service stopped",
    ]

    /// `gateway restart`'s success lines: launchd's two spellings
    /// (`gateway.py:4041`/`:4059` and `:4065`/`:4081`), systemd's
    /// `✓ {User|System} service restarted (PID {n})` (`:1218`), the s6
    /// summary (`:5653`), the launchd detached fallback
    /// (``gatewayDetachedFallbackStarted``, reached from `launchd_restart`'s
    /// `:4068` and `:4079` arms) and BOTH Windows lines.
    ///
    /// **Why Windows's start lines belong on the restart verb.**
    /// `gateway_windows.restart()` (`hermes_cli/gateway_windows.py:1380-1399`
    /// @ v2026.9.7) is `stop()`, a bounded absence wait, then `start()`
    /// (`:1225`); it prints no restart line of its own, so a Windows restart
    /// ends on `✓ Gateway started via {via} (PID: {n})`
    /// (`_report_gateway_start`, `:971`) or `✓ Gateway already running
    /// (PID: {n})` (`_report_already_running`, `:698`, called from `:1231`).
    /// Its own loud arms raise `RuntimeError` (`:1390-1393`) or print
    /// `✗ Gateway start via {via} FAILED …` (`:977`), both already covered.
    /// Without these two markers every Windows restart Scarf drove was
    /// reported "could not confirm".
    public static let gatewayRestartSuccess = [
        "Service restarted",
        "Service restart requested",
        "User service restarted",
        "System service restarted",
        "Restarted ",
        "Gateway started via",
        gatewayWindowsAlreadyRunning,
        gatewayDetachedFallbackStarted,
    ]

    /// `_cmd_restart`'s last-resort arm prints `Starting gateway...`
    /// (`gateway.py:6065`) and then calls `run_gateway(verbose=0)`, which
    /// RUNS the gateway in the foreground — it does not return, so Scarf's
    /// own CLI timeout ends the run. `_restart_all` has the same shape
    /// (`:6010-6016`), though Scarf never passes `--all`.
    ///
    /// The honest verdict is neither half of the bool: a `Starting
    /// gateway...` line followed by a timeout means the gateway was started
    /// in the foreground and Scarf cannot confirm it from here, so the
    /// restart verdict answers ``HermesCLIOutcome/Confidence/unconfirmed``
    /// and the caller's reload tells the real state. It is deliberately NOT
    /// a success marker: per the round-4 product call, nothing claims
    /// "restarted" without a confirmation line.
    public static let gatewayForegroundStarting = "Starting gateway..."

    /// The "there was nothing to stop" lines. Round-4 decision 2 makes these
    /// a SUCCESS with a neutral note rather than a failure — the user asked
    /// for the gateway to be down, and it is. Matched anchored; each is
    /// printed at column 0 behind a `✗` glyph.
    /// `gateway.py:5993` (`--all`), `:5998` (this profile), `:5644` (s6).
    public static let gatewayNothingRunning = [
        "No gateway processes found",
        "No gateway running for this profile",
        "No profile gateways registered under s6",
    ]

    /// Gateway refusals that are NOT at column 0 — mid-line clauses inside a
    /// sentence that leads with a scope label.
    /// `⚠ {scope} service process restarted (PID {n}), but gateway startup
    /// failed: {reason}` (`gateway.py:1223`),
    /// `⚠ {scope} service did not become active within {n}s.` (`:1242`), and
    /// `⏳ {scope} service is temporarily rate-limited by systemd.` (`:1284`).
    /// All three return at exit 0 having printed no success line, so the
    /// no-marker rule would already fail the run; these markers exist to put
    /// Hermes's own reason in the banner instead of the last stray line.
    ///
    /// **The run.py refusal (P40c).** `gateway/run.py:4769` prints
    /// `❌ Gateway already running (PID {n}).` from
    /// `_start_gateway_replace_existing_instance`, which returns False and
    /// aborts startup. It is reachable on exactly the path the foreground
    /// restart arm covers — `_cmd_restart`'s last-resort `run_gateway`
    /// (`hermes_cli/gateway.py:6066`) — where, without a marker, the run read
    /// as "started in the foreground, could not confirm" when the gateway had
    /// in fact refused to start. Unanchored because `❌` is not in
    /// ``HermesCLIVerdict``'s glyph set, so the sentence is not at the head of
    /// the line after ``HermesCLIVerdict/unglyphed(_:)``.
    ///
    /// It cannot collide with the Windows SUCCESS line
    /// (``gatewayWindowsAlreadyRunning``): that one spells the PID
    /// `(PID: {n})`, with a colon where this marker has a space. And even a
    /// future spelling that did overlap would not flip a real start — this
    /// verdict runs `failureWins: false`, so a matched success line wins.
    public static let gatewayServiceFailure = [
        "but gateway startup failed:",
        "did not become active within",
        "is temporarily rate-limited by systemd.",
        "Gateway already running (PID ",
    ]

    /// The column-0 gateway refusals. ``managedRefusalAnchored`` rides along
    /// for the `save_config` door, and this set adds the one `Cannot …` line
    /// that is NOT a managed-install claim:
    /// `⚠ Cannot restart gateway as a service — linger is not enabled.`
    /// (`gateway.py:6047`), a plain `return` at exit 0. It is spelled out in
    /// full rather than left to a bare `Cannot ` anchor, so a gateway log line
    /// quoted into the output cannot match it (P39c).
    /// The three `gateway` verbs Scarf shells are `start|stop|restart`, none
    /// of which reaches `gateway.py`'s own `managed_error` arms (`:5580`,
    /// `:5919`, `:5945` — setup, install service, uninstall service).
    /// `✗ Gateway service restart failed.` (`:6056`) and
    /// `✗ Gateway start via {via} FAILED …`
    /// (`hermes_cli/gateway_windows.py:977`) both exit non-zero already, and
    /// `✗ Refusing to {verb} the gateway from inside the gateway process.`
    /// (`gateway.py:5776-5781` via `print_error`,
    /// `hermes_cli/cli_output.py:21-22`) `sys.exit(1)`s — they are listed so
    /// the banner quotes the reason rather than the exit code.
    ///
    /// **The container refusal (P40c).** `gateway start` on a Docker host with
    /// no service backend reaches `_handle_no_backend("start", …)`
    /// (`gateway.py:5975`) → `_no_backend_exit` (`:5870-5874`), whose
    /// `("start", "container")` entry is `(0, "Service start is not applicable
    /// inside a Docker container.", …)` (`:5860-5866`): a real refusal that
    /// prints at column 0 with no glyph and **exits 0**. Without the marker it
    /// judged `.unconfirmed` — "Scarf could not confirm it" — when Hermes had
    /// in fact said no in as many words. The three other `_NO_BACKEND_MESSAGES`
    /// arms reachable from a verb Scarf shells (`("start", "termux")` `:5853`,
    /// `("start", "wsl")` `:5856`, `("start", "unsupported")` `:5866`) all
    /// carry exit 1 and are owned by the exit code.
    public static let gatewayServiceFailureAnchored = managedRefusalAnchored + [
        "Cannot restart gateway as a service",
        "Gateway service restart failed.",
        "Gateway start via",
        "Refusing to ",
        "Service start is not applicable inside a Docker container.",
    ]

    // MARK: mcp remove / mcp test — hermes_cli/mcp_config.py

    /// `  ✓ Removed '<name>' from config` (`mcp_config.py:524` @ v2026.9.7),
    /// through `_success` (`:34`). Anchored; the name follows the marker.
    public static let mcpRemoveSuccess = ["Removed '"]

    /// `  ✗ Server '<name>' not found in config.` (`:104`) and the
    /// non-TTY-unreachable `  Cancelled.` (`:521`), plus the managed
    /// `save_config` refusal underneath `_remove_mcp_server` (`:110-121` →
    /// `hermes_cli/config.py:2316-2318`). Anchored, because the success line
    /// echoes the server name.
    public static let mcpRemoveFailure = managedRefusalAnchored + [
        "Server '",
        "Cancelled.",
    ]

    /// `  ✓ Connected ({ms}ms)` (`:615`) and `  ✓ Tools discovered: {n}`
    /// (`:616`). Either alone proves the probe reached the server.
    public static let mcpTestSuccess = [
        "Connected (",
        "Tools discovered:",
    ]

    /// `  ✗ Connection failed ({ms}ms): {exc}` (`:613`) and `_lookup_server`'s
    /// `  ✗ Server '<name>' not found in config.` (`:104`). ANCHORED, and
    /// that is the whole point of this set: the success path prints one line
    /// per discovered tool carrying the tool's OWN description
    /// (`_print_tools`, `:49-52`), and a stdio server's stderr is merged into
    /// the same stream. A tool documented "… returns Connection failed (…)"
    /// must not turn a healthy probe red, and at column 0 it cannot.
    public static let mcpTestFailure = [
        "Connection failed (",
        "Server '",
    ]

    // MARK: plugins update — the security-disable third state

    /// The clause of `[red]Plugin '<name>' has been disabled.[/red] Review the
    /// findings, then re-enable with …` (`plugins_cmd.py:848-851`, inside
    /// `_rescan_after_update`'s `dangerous` arm `:845-851`). Printed BEFORE
    /// `cmd_update`'s `✓ Plugin <name> updated.` (`:828`), both at exit 0.
    ///
    /// Never match this clause on its own: `cmd_update` echoes the raw
    /// `git pull` body (`:829`) and `_rescan_after_update` prints the scan
    /// report (`:844`), and neither is text Hermes authors — a pulled commit
    /// message or a scan finding reading "… has been disabled." was a false
    /// third state. `HermesPluginsUpdateVerdict.isSecurityDisableLine` pairs
    /// it with the column-0 `Plugin ` prefix, the same shape as
    /// `isSuccessLine`.
    public static let pluginsUpdateSecurityDisabled = "has been disabled."

    /// `[yellow]⚠ Security scan flagged the updated plugin:[/yellow] {reason}`
    /// (`plugins_cmd.py:843`) — the line round-4 decision 3 quotes into the
    /// banner so the user learns WHY the plugin is off.
    public static let pluginsUpdateScanFlagged = "Security scan flagged the updated plugin:"
}

/// `hermes pairing approve` / `revoke`, judged by what the emitter printed.
///
/// Both handlers are `-> None` (`hermes_cli/pairing.py:56`, `:84`) reached
/// through a `pairing_command` that is itself `-> None` (`:3-19`), so every
/// refusal — an expired code, an unknown user, a rate-limit lockout — arrives
/// as exit 0. Judging by exit code made a refused revoke delete the row from
/// the list (until the next load put it back) and a refused approve report
/// nothing at all.
public enum HermesPairingVerdict {
    /// `fallbackDetail` is deliberately OFF for both verbs: each refusal is
    /// followed by a next-step hint (`Run 'hermes pairing list' …` :81, and
    /// the `To reset sooner, delete the '_lockout:…' entry` line :78), so the
    /// last significant line is chatter, not the reason.
    public static func approve(output: String, exitCode: Int32) -> HermesCLIOutcome {
        let outcome = HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: HermesCLIMarkers.pairingApproveSuccess,
            failureMarkers: HermesCLIMarkers.pairingApproveFailure,
            fallbackDetail: false,
            successAnchored: true
        )
        guard !outcome.succeeded, let detail = outcome.detail else { return outcome }
        return HermesCLIOutcome(succeeded: false, detail: withLockoutCountdown(detail, in: output))
    }

    public static func revoke(output: String, exitCode: Int32) -> HermesCLIOutcome {
        HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: HermesCLIMarkers.pairingRevokeSuccess,
            failureMarkers: HermesCLIMarkers.pairingRevokeFailure,
            fallbackDetail: false,
            successAnchored: true
        )
    }

    /// The lockout refusal is TWO lines in the emitter and only the first
    /// carries the marker; quoting one leaves the user without the countdown.
    private static func withLockoutCountdown(_ detail: String, in output: String) -> String {
        guard detail.contains(HermesCLIMarkers.pairingLockoutRefusal) else { return detail }
        let lines = HermesCLIVerdict.significantLines(output)
        guard let i = lines.firstIndex(of: detail), i + 1 < lines.count,
              lines[i + 1].hasPrefix(HermesCLIMarkers.pairingLockoutClears)
        else { return detail }
        return "\(detail) \(lines[i + 1])"
    }
}

/// `hermes security audit`'s three-way exit contract — the one site in this
/// group that does NOT return `None` on failure, and whose exit code IS
/// meaningful (in three states, not two).
///
/// `hermes_cli/security_audit.py::cmd_security_audit` (v2026.9.7:286-312):
/// - `return 2` on an unusable `--fail-on` (:293) or an OSV `RuntimeError`
///   (:307), both after printing to **stderr**;
/// - otherwise it prints the report to stdout (:309) and returns
///   `int(any(severity >= threshold))` (:311-312) — so **1 means findings at
///   or above the threshold**, not a failed run.
///
/// `hermes_cli/main.py::cmd_security` (:2074-2075) passes that straight to
/// `sys.exit`. Rendering exit 1 as "Audit failed" told the user the scan broke
/// when in fact it worked and found something.
public enum HermesSecurityAuditVerdict: Equatable, Sendable {
    /// Exit 0 — the scan ran, nothing met the threshold.
    case clean
    /// Exit 1 — the scan ran and found advisories at or above `--fail-on`.
    case findings
    /// Exit 2 (or anything else) — the scan itself failed.
    case failed(Int32)

    public init(exitCode: Int32) {
        switch exitCode {
        case 0: self = .clean
        case 1: self = .findings
        default: self = .failed(exitCode)
        }
    }
}

/// The `hermes security audit` human report, parsed just enough to tell the
/// two exit-0 cases apart.
///
/// `--fail-on critical` (Scarf's explicit threshold, and Hermes's default)
/// makes the exit code answer only "was anything CRITICAL?". Exit 0 therefore
/// covers both "nothing found at all" and "high/moderate/low advisories
/// found" — and the `.clean` arm was printing the tail of a report that was
/// listing real vulnerabilities, with no label saying so.
///
/// `_render_human` (`hermes_cli/security_audit.py:254-268` at v2026.9.7) emits
/// exactly one of two heads —
/// `No known vulnerabilities found across <n> component(s).` (:255) or
/// `Found <n> known vulnerability finding(s) across <m> component(s):` (:257) —
/// then one `  {severity.ljust(8)}  {name}=={version}  {osv-id}` row per
/// finding (:264). Both heads and the row shape are byte-identical back to
/// **v2026.5.29** — the release `security audit` shipped in and the floor of
/// `hasHermesAudit` — so this parse changes nothing on a pre-target host (C1).
///
/// A third exit-0 shape has no findings section at all:
/// `No components discovered (everything skipped, or empty environment).`
/// (`cmd_security_audit`, :299-301).
public struct HermesSecurityAuditReport: Sendable, Equatable {
    /// `n` from the `Found n known vulnerability finding(s)` head; 0 when the
    /// report's head is the clean one.
    public let findingCount: Int
    /// Severity tier → number of rows, using the emitter's own uppercase
    /// spellings (`SEVERITY_ORDER`, :29 — UNKNOWN/LOW/MODERATE/MEDIUM/HIGH/
    /// CRITICAL).
    public let severityCounts: [String: Int]

    public init(findingCount: Int, severityCounts: [String: Int]) {
        self.findingCount = findingCount
        self.severityCounts = severityCounts
    }

    /// Highest-first summary of the tiers present, e.g. `2 high · 1 moderate`.
    public var severitySummary: String {
        Self.severityOrder.compactMap { tier -> String? in
            guard let n = severityCounts[tier], n > 0 else { return nil }
            return "\(n) \(tier.lowercased())"
        }.joined(separator: " · ")
    }

    /// `SEVERITY_ORDER`'s keys, highest first. `MEDIUM` is OSV's alias for
    /// `MODERATE` (same rank, :29) and both can appear in a report.
    static let severityOrder = ["CRITICAL", "HIGH", "MODERATE", "MEDIUM", "LOW", "UNKNOWN"]

    public static func parse(_ output: String) -> HermesSecurityAuditReport {
        var count = 0
        var counts: [String: Int] = [:]
        for line in HermesCLIVerdict.significantLines(output) {
            if count == 0, line.hasPrefix(Self.foundPrefix), line.contains("known vulnerability finding(s)") {
                let digits = line.dropFirst(Self.foundPrefix.count).prefix { $0.isNumber }
                count = Int(digits) ?? 0
                continue
            }
            // A finding row: `<SEVERITY>  <name>==<version>  <OSV-ID>`. The
            // trimmed line starts with the tier word, and the `==` pins it to
            // a row rather than any prose that happens to open with one.
            guard let tier = line.split(separator: " ").first.map(String.init),
                  Self.severityOrder.contains(tier),
                  line.contains("==")
            else { continue }
            counts[tier, default: 0] += 1
        }
        return HermesSecurityAuditReport(findingCount: count, severityCounts: counts)
    }

    private static let foundPrefix = "Found "
}

/// `hermes memory off` — the fourth `save_config` door (P39).
///
/// `_cmd_memory_off` (`hermes_cli/main_agent_cmds.py:10-18` @ v2026.9.7)
/// mutates `memory.provider` through `save_config` and announces success
/// unconditionally afterwards, so a managed host printed the refusal to stderr
/// and the confirmation to stdout in the same run at exit 0.
public enum HermesMemoryOff {
    public static let argv = ["memory", "off"]

    public static func judge(output: String, exitCode: Int32) -> HermesCLIOutcome {
        HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: HermesCLIMarkers.memoryOffSuccess,
            anchoredFailureMarkers: HermesCLIMarkers.memoryOffFailure,
            failureWins: true,
            successAnchored: true
        )
    }
}

/// The tenth arm of `set_config_value` (and its `unset` twin): Hermes wrote
/// config.yaml and then REFUSED the `.env` mirror of the same key.
///
/// `set_config_value` writes config.yaml (`_write_user_config`,
/// `hermes_cli/config.py:3506` @ v2026.9.7), then mirrors every `terminal.*`
/// key except `terminal.cwd` into `.env` through `save_env_value`
/// (`:3509-3511`); `_env_write_blocked`'s managed-**scope** arm prints
/// `Cannot set <KEY>: it is managed by your administrator (…)` and returns
/// (`:2574-2578` → `:2560-2565`), after which `:3521` prints
/// `✓ Set <key> = <value> in <config path>` regardless. Exit 0, a refusal
/// line and a success line. `unset_config_value` reaches the same shape
/// through `remove_env_value` (`:3574-3576` → `:2610-2612`).
///
/// **Round-4 product decision (Alan): that is a PARTIAL write, not a
/// failure.** config.yaml really did change, and reporting "Couldn't save"
/// over a file that now holds the new value is the same class of lie this
/// phase exists to end, pointed the other way.
///
/// The discriminator is the destination Hermes names on its own success
/// line, because the two exit-0 shapes are otherwise identical:
/// - `✓ Set <key> = <value> in …/config.yaml` — the config.yaml write landed
///   and only the mirror was refused ⇒ partial.
/// - `✓ Set <key> in …/.env` — the `_is_env_config_key` branch (`:3461-3468`),
///   where the `.env` write is the only write `set_config_value` makes on
///   that arm and it was refused ⇒ a plain failure, judged unchanged.
///
/// **"the only write" is scoped to this CLI path** (P39c). Hermes has another
/// `.env` writer that does NOT stop at the refusal:
/// `save_provider_env_credential` (`hermes_cli/credential_lifecycle.py:167-193`
/// @ v2026.9.7) calls `save_env_value(env_var, value)` (`:186`) and **discards
/// its bool**, then runs `_scrub_config_yaml_mirrors(old_value, value)`
/// (`:190`), which rewrites config.yaml through `atomic_yaml_write` (`:142`) —
/// bypassing `save_config`, and therefore bypassing the `is_managed()` guard at
/// `hermes_cli/config.py:2316-2318`. So on a managed host that call can refuse
/// the `.env` write and still touch config.yaml. No code change: that path is
/// the Desktop credential API, not a verb Scarf shells, and this
/// discriminator errs toward FAILURE on it — a refused `.env` write with no
/// `✓ Set … in …/config.yaml` line stays a failure, which is the safe answer.
public enum HermesConfigMirror {
    /// Does this line name config.yaml as the file Hermes wrote? The path is
    /// the last token of both success lines, and `get_config_path()` is
    /// `get_hermes_home() / "config.yaml"` at every tag
    /// (`hermes_cli/config.py:491-493` @ v2026.9.7), so the suffix is exact
    /// and a `HERMES_HOME` override does not move it.
    static func namesConfigFile(_ line: String) -> Bool {
        guard let tail = line.split(separator: " ").last else { return false }
        return tail.hasSuffix("config.yaml")
    }

    /// Promote a `failureWins` verdict to a partial-write success when the run
    /// printed BOTH a refusal and a config.yaml success line. Everything else
    /// passes through untouched — including the whole-command managed refusal,
    /// which returns before any success line is printed.
    static func resolve(
        _ verdict: HermesCLIOutcome,
        output: String,
        exitCode: Int32,
        successMarkers: [String]
    ) -> HermesCLIOutcome {
        guard exitCode == 0, !verdict.succeeded, let refusal = verdict.detail else { return verdict }
        let saved = HermesCLIVerdict.significantLines(output).first { line in
            let head = HermesCLIVerdict.unglyphed(line)
            return successMarkers.contains { head.hasPrefix($0) } && namesConfigFile(line)
        }
        guard saved != nil else { return verdict }
        return HermesCLIOutcome(succeeded: true, detail: nil, warning: partialWriteMessage(refusal: refusal))
    }

    /// The banner sentence for a partial write. Quotes Hermes's own refusal
    /// line, because "the mirror was refused" without the reason is the same
    /// dead end `managedBannerText` avoids by naming the package manager.
    public static func partialWriteMessage(refusal: String) -> String {
        String(localized: "Saved to config.yaml; the .env mirror was refused: \(refusal)")
    }
}

/// `hermes config set <key> <value>` — argv and verdict in one place, the
/// `set` twin of ``HermesConfigUnset`` (P39).
///
/// **argv** (charter C5): `config set -- <key> <value>`, two positionals, both
/// `nargs="?"` (`hermes_cli/subcommands/config.py:24-31` @ v2026.9.7). The
/// `--` is the P39 fix for a value like `-1`, which argparse otherwise reads
/// as an option and exits 2; the parser declares no positional that could
/// swallow the separator, and argparse has honoured it at every tag, so it is
/// inert on a pre-target host (charter C1). `--force` is NOT passed by Scarf:
/// it would authorize replacing a whole mapping section with a scalar
/// (`_guard_section_overwrite`, `hermes_cli/config.py:3374-3417`).
///
/// **Verdict**: by output, never by exit code. `set_config_value` opens with
/// `if is_managed(): managed_error("set configuration values"); return`
/// (`hermes_cli/config.py:3450-3452` @ v2026.9.7, `managed_error` at
/// `:453-455`), which Python exits **0** — so on a managed host every write
/// Scarf made banner'd "Saved" over a file the host never touched. Two doc
/// comments on this branch asserted the opposite ("every `config set` refusal
/// `sys.exit(1)`s"); that claim was false at every tag from **v2026.3.28**,
/// where the arm first appears. See ``HermesCLIMarkers/configSetFailure`` for
/// the full enumeration of the nine refusal arms.
///
/// `failureWins: true`, because the `.env` branch genuinely prints BOTH: the
/// managed-scope guard refuses the write (`:2560-2564`) and `:3468` prints
/// `✓ Set <key> in <env path>` anyway.
public enum HermesConfigSet {
    public static func argv(key: String, value: String) -> [String] {
        ["config", "set", "--", key, value]
    }

    public static func judge(output: String, exitCode: Int32) -> HermesCLIOutcome {
        let verdict = HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: HermesCLIMarkers.configSetSuccess,
            anchoredFailureMarkers: HermesCLIMarkers.configSetFailure,
            failureWins: true,
            successAnchored: true
        )
        return HermesConfigMirror.resolve(
            verdict, output: output, exitCode: exitCode,
            successMarkers: HermesCLIMarkers.configSetSuccess
        )
    }
}

/// `hermes tools enable|disable <name> --platform <p>` — the FOURTH door onto
/// `save_config`'s exit-0 managed refusal (P46 finding 4).
///
/// Walked at v2026.9.7. `cmd_tools` dispatches `enable`/`disable` to
/// `tools_disable_enable_command` (`hermes_cli/main_agent_cmds.py:93-95` →
/// `hermes_cli/tools_config_mcp.py:237`). Every refusal that command can
/// print is a `_print_error` followed by a bare `return` or a `continue`, so
/// **every one of them exits 0**:
///
/// - `Unknown platform '<p>'. Valid: …` — `:247`, then `return` at `:248`:
///   nothing is saved and nothing else is printed.
/// - `Unknown toolset '<name>'` — `:262`. The name is dropped from
///   `toolset_targets` (`:269-270`) and the command CONTINUES.
/// - `Toolset '<name>' is not available on platform '<p>' (only: …)` —
///   `:268`, same treatment.
/// - `MCP server '<srv>' not found in config` — `:278`.
///
/// and the write itself is `save_config(config)` (`:279`), whose managed arm
/// is `if is_managed(): managed_error("save configuration"); return`
/// (`hermes_cli/config.py:2316-2318`) — the same `print(…, file=sys.stderr)`
/// + bare `return` shape `HermesSkillsTrust` documents, covered by
/// ``HermesCLIMarkers/managedRefusalAnchored``.
///
/// The success line is `_print_success(f"{verb}: {', '.join(successful)}")`
/// (`:284-285`) — `✓ Enabled: web` / `✓ Disabled: web` — and it is printed
/// from the `successful` list, which is computed BEFORE `save_config` can
/// refuse and is not conditioned on it. So a managed host prints the refusal
/// on stderr and `✓ Enabled: web` on stdout in the same run, which is exactly
/// why this verdict must run `failureWins: true`.
///
/// Anchored on both sides. The success line interpolates the toolset NAMES
/// the caller passed, so an unanchored `Enabled:` would match a name that
/// contained it; and the refusals interpolate a name or a platform, which is
/// the echo `anchoredFailureMarkers` exists for.
public enum HermesToolsToggle {
    public static func argv(toolset: String, platform: String, enabled: Bool) -> [String] {
        ["tools", enabled ? "enable" : "disable", toolset, "--platform", platform]
    }

    public static func judge(output: String, exitCode: Int32) -> HermesCLIOutcome {
        HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: HermesCLIMarkers.toolsToggleSuccess,
            anchoredFailureMarkers: HermesCLIMarkers.toolsToggleFailure,
            failureWins: true,
            successAnchored: true
        )
    }
}

/// `hermes skills trust|untrust <root>` — the third door onto `save_config`'s
/// exit-0 managed refusal (P39).
///
/// `_cmd_skills_trust` (`hermes_cli/main_agent_cmds.py:179-247` @ v2026.9.7)
/// edits `skills.trusted_project_dirs`, calls `save_config(config)` (`:224`,
/// `:234`) and then prints its own success line (`:225`, `:235`) — so on a
/// managed host `save_config` printed `Cannot save configuration: … is managed
/// by …` to stderr, returned, and Scarf read the `Trusted: <root>` line that
/// followed as proof. `failureWins: true` is mandatory here, not cosmetic.
public enum HermesSkillsTrust {
    public static func judge(output: String, exitCode: Int32) -> HermesCLIOutcome {
        HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: HermesCLIMarkers.skillsTrustSuccess,
            anchoredFailureMarkers: HermesCLIMarkers.skillsTrustFailure,
            failureWins: true
        )
    }
}

/// `hermes config unset <key>` — argv and verdict in one place, because both
/// platforms drive it from their "Host default" approvals row (round-3
/// decision 10) and neither may judge it by exit code.
///
/// **argv** (charter C5): `config unset <key>`, one positional. Verified at
/// the target tag — `hermes_cli/subcommands/config.py:33-34` @ v2026.9.7,
/// `add_parser("unset", …)` + `add_argument("key", nargs="?")` — and at the
/// `hasConfigUnset` floor, `hermes_cli/subcommands/config.py:51-54` @
/// v2026.7.20 (0.19.0), where it is byte-equivalent. There are no flags, so
/// there is nothing here that a 0.19 host would reject.
///
/// **Verdict**: by output (see ``HermesCLIMarkers/configUnsetFailure``) — the
/// managed-install refusal prints and returns, i.e. exits 0.
public enum HermesConfigUnset {
    /// `config unset -- <key>`. The `--` is P39: `key` is `nargs="?"`, so a
    /// key that begins with `-` was parsed as an option and exited 2.
    /// argparse has always honoured `--` as the end-of-options separator and
    /// the parser declares no positional that could swallow it
    /// (`hermes_cli/subcommands/config.py:33-34` @ v2026.9.7,
    /// `:51-54` @ v2026.7.20 — the `hasConfigUnset` floor), so this is inert
    /// on every host Scarf gates the verb for (charter C1).
    public static func argv(key: String) -> [String] { ["config", "unset", "--", key] }

    public static func judge(output: String, exitCode: Int32) -> HermesCLIOutcome {
        let verdict = HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: HermesCLIMarkers.configUnsetSuccess,
            anchoredFailureMarkers: HermesCLIMarkers.configUnsetFailure,
            failureWins: true,
            successAnchored: true
        )
        return HermesConfigMirror.resolve(
            verdict, output: output, exitCode: exitCode,
            successMarkers: HermesCLIMarkers.configUnsetSuccess
        )
    }

    /// What a host-default row says on a host below the `hasConfigUnset`
    /// floor, where the row stays inert: Scarf will not shell a verb the host
    /// does not have (C5), so it names the one gesture that does work there.
    public static func belowFloorHint(key: String) -> String {
        String(localized: "This Hermes is older than v0.19, which added `hermes config unset`. To go back to the host default, remove the `\(key)` line from config.yaml on the host.")
    }
}

// MARK: - gateway start / stop / restart — hermes_cli/gateway.py

/// The verdict on `hermes gateway start|stop|restart`, judged by what the
/// service backend PRINTED.
///
/// ## Why the exit code was never enough
///
/// `cmd_gateway` (`hermes_cli/main.py:1736-1742` @ v2026.9.7) discards what
/// `gateway_command` returns, and `gateway_command` (`gateway.py:5659-5667`)
/// returns `None` for every one of these three verbs — so the whole family
/// lands at exit 0 whatever happened. The exit-0 refusal is a FAMILY here,
/// not one handler; every arm on each verb's path was walked at the tag:
///
/// **stop** (`_cmd_stop`, `gateway.py:5974-6000`)
/// - `✗ No gateway processes found` (`:5993`, the `--all` arm) and
///   `✗ No gateway running for this profile` (`:5998`) — plain `return`s.
/// - `_dispatch_all_via_service_manager_if_s6` prints
///   `✗ No profile gateways registered under s6` and returns True (`:5644`).
/// - successes: `✓ Stopped {n} gateway process(es) across all profiles`
///   (`:5991`), `✓ Stopped gateway for this profile` (`:5996`),
///   `✓ Stopped {service} service` (`:6000`), plus the backend's own line —
///   `✓ Service stopped` (`launchd_stop`, `:3978`) or
///   `✓ {User|System} service stopped` (`systemd_stop`, `:3186`).
///
/// **start** (`_cmd_start`, `gateway.py:5955-5972`)
/// - `_no_backend_exit` (`:5870-5874`): of the four `start` rows only
///   `("start", "container")` carries an exit code of `0` (`:5854-5860`), and
///   it prints no success line at all — the no-marker rule covers it. The
///   other three `sys.exit(1)`.
/// - `launchd_start` (`:3914-3940`) returns WITHOUT `✓ Service started` when
///   `_launchd_bootstrap_and_kickstart` degrades (`:3926-3928`, `:3938-3939`)
///   — but the degradation is itself a START: `_launchd_degrade_or_raise`
///   (`:3626-3630`) calls `_launchd_fallback_to_detached` (`:3607-3618`),
///   which `Popen`s the gateway and prints `✓ Started gateway as a background
///   process instead` (`:3614`). See
///   ``HermesCLIMarkers/gatewayDetachedFallbackStarted``.
/// - successes: `✓ Service started` (`:3927`, `:3940`),
///   `✓ {User|System} service started` (`systemd_start`, `:3171`), and on
///   Windows `✓ Gateway started via {via} (PID: …)` /
///   `✓ Gateway already running (PID: …)`
///   (`hermes_cli/gateway_windows.py:971`, `:698`) against
///   `✗ Gateway start via {via} FAILED …` (`:977`).
///
/// **restart** (`_cmd_restart`, `gateway.py:6019-6067`)
/// - `⚠ Cannot restart gateway as a service — linger is not enabled.`
///   (`:6047`) is a plain `return` at exit 0 — caught by
///   ``HermesCLIMarkers/gatewayServiceFailureAnchored``'s own
///   `Cannot restart gateway as a service` anchor, which is a column-0 anchor
///   and not a managed-install claim.
/// - `✗ Gateway service restart failed.` (`:6056`) does `sys.exit(1)`.
/// - `_wait_for_systemd_service_restart` can end with
///   `⚠ … but gateway startup failed: {reason}` (`:1223`),
///   `⚠ … did not become active within {n}s.` (`:1242`) or
///   `_print_systemd_start_limit_wait`'s
///   `⏳ … is temporarily rate-limited by systemd.` (`:1284`) — all exit 0
///   with no success line.
/// - the two no-service arms print `Starting gateway...` and then
///   `run_gateway(verbose=0)`, which runs the gateway in the FOREGROUND and
///   never returns: `_cmd_restart`'s last resort (`:6062-6066`) and
///   `_restart_all` (`:6003-6016`, `--all`, which Scarf never passes). Scarf's
///   CLI timeout ends the run. Neither half of the bool is honest there, so
///   ``HermesCLIMarkers/gatewayForegroundStarting`` maps that shape to
///   ``HermesCLIOutcome/Confidence/unconfirmed`` — "started in the
///   foreground, could not confirm" — and nothing claims "restarted" without
///   a confirmation line. `_restart_all`'s own `✓ Stopped {n} gateway
///   process(es) across all profiles` (`:6007`) and `_cmd_restart`'s
///   `✓ Stopped gateway for this profile` (`:6063`) are STOP lines and are
///   deliberately absent from the restart success set.
/// - successes: `✓ Service restart requested` (`:4041`, `:4059`),
///   `✓ Service restarted` (`:4065`, `:4081`),
///   `✓ {User|System} service restarted (PID {n})` (`:1218`),
///   `✓ {Stopped|Restarted} {n} profile gateway(s) under s6` (`:5653`), the
///   launchd detached fallback (`:3614`, via `launchd_restart`'s `:4068` and
///   `:4079` arms) and, on Windows, `start()`'s own two lines — `restart()`
///   is `stop()` + `start()` (`hermes_cli/gateway_windows.py:1380-1399`).
///
/// ## Known blind spot: a bare s6 dispatch
///
/// `_dispatch_via_service_manager_if_s6` (`:5608-5629`) hands the verb to the
/// s6 service manager and prints NOTHING on the success path
/// (`hermes_cli/service_manager.py:529-566` prints nothing either). On such a
/// host — a container whose gateway Scarf drives over SSH — a real
/// start/stop/restart reports "could not confirm". That is the C5 answer
/// (never read silence as success) and the call sites all reload the real
/// state afterwards, so the banner is corrected within seconds. It is called
/// out here rather than papered over.
///
/// It is also why the verdict carries ``HermesCLIOutcome/Confidence``.
/// "Could not confirm" is NOT a failure signal, and a caller must not run a
/// destructive fallback on it: `HermesFileService.stopHermes()` used to fall
/// through to `pgrep` + `kill -TERM` whenever `succeeded` was false, and on
/// an s6 host `s6-supervise` reads that SIGTERM as a crash and brings the
/// gateway straight back — Stop looked like it worked and then undid itself.
/// The fallback is gated on ``HermesCLIOutcome/Confidence/failed`` now: a
/// matched refusal marker, or a non-zero exit.
///
/// The helper's own failure arm is not silent and needs no marker — it prints
/// `✗ {exc}` and `sys.exit(1)` (`:5625-5627`), so the exit code owns it.
///
/// ## `--all` under s6, for completeness
///
/// `_dispatch_all_via_service_manager_if_s6` (`:5631-5656`) stops or restarts
/// EVERY registered profile gateway and prints a per-profile
/// `✗ Could not {action} gateway-{profile}: {exc}` for each failure ALONGSIDE
/// the `✓ {Stopped|Restarted} {n} profile gateway(s) under s6` summary
/// (`:5653-5655`) — a partial failure that this verdict, which does not run
/// `failureWins`, would report as a flat success. Scarf never passes `--all`
/// (``argv(_:)`` is the bare verb), so the shape is unreachable; it is named
/// here so the day a `--all` surface appears, the verdict is known to need a
/// `failureWins` pass and a partial-outcome note first.
///
/// ## Round-4 product decision 2
///
/// The banner claims the real state ("Gateway started" / "Gateway stopped"),
/// not "requested". A Stop that found nothing running is a **success**
/// carrying a neutral note, not a failure — the user asked for the gateway to
/// be down and it is down. That rides on ``HermesCLIOutcome/warning``, the
/// same channel the partial-write case uses.
public enum HermesGatewayServiceVerdict {
    public enum Verb: String, Sendable, CaseIterable {
        case start, stop, restart
    }

    /// `hermes gateway <verb>`. No positional and no flag, so there is
    /// nothing here for a `--` to guard.
    public static func argv(_ verb: Verb) -> [String] { ["gateway", verb.rawValue] }

    /// The neutral note decision 2 asks for on a Stop with nothing running.
    public static let nothingWasRunningNote = String(
        localized: "Nothing was running on this profile."
    )

    /// What a restart that fell through to `run_gateway(verbose=0)` says —
    /// the gateway IS being started, in the foreground, and this run cannot
    /// see it come up. See ``HermesCLIMarkers/gatewayForegroundStarting``.
    public static let foregroundStartNote = String(
        localized: "Hermes is starting the gateway in the foreground on this host — Scarf can't confirm it from here."
    )

    /// Did the run print one of the gateway service's own refusal lines?
    /// Shared by the foreground-restart arm and the "nothing was running"
    /// arm, both of which must never launder a genuine refusal.
    private static func sawServiceRefusal(_ lines: [String]) -> Bool {
        lines.contains { line in
            HermesCLIMarkers.gatewayServiceFailure.contains { line.contains($0) }
                || HermesCLIMarkers.gatewayServiceFailureAnchored.contains {
                    HermesCLIVerdict.unglyphed(line).hasPrefix($0)
                }
        }
    }

    public static func judge(verb: Verb, output: String, exitCode: Int32) -> HermesCLIOutcome {
        let successMarkers: [String]
        switch verb {
        case .start: successMarkers = HermesCLIMarkers.gatewayStartSuccess
        case .stop: successMarkers = HermesCLIMarkers.gatewayStopSuccess
        case .restart: successMarkers = HermesCLIMarkers.gatewayRestartSuccess
        }
        let verdict = HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: successMarkers,
            failureMarkers: HermesCLIMarkers.gatewayServiceFailure,
            anchoredFailureMarkers: HermesCLIMarkers.gatewayServiceFailureAnchored,
            successAnchored: true
        )
        let lines = HermesCLIVerdict.significantLines(output)
        if verb == .restart, !verdict.succeeded, !sawServiceRefusal(lines),
           lines.contains(where: {
               HermesCLIVerdict.unglyphed($0).hasPrefix(HermesCLIMarkers.gatewayForegroundStarting)
           }) {
            // `_cmd_restart`'s no-service arm (`gateway.py:6062-6066`):
            // `Starting gateway...` and then a foreground `run_gateway`, which
            // NEVER RETURNS — the run ends at Scarf's own CLI timeout, so the
            // exit code Scarf sees is the transport's `-1`, not 0.
            //
            // Gating this on exit 0 made the arm unreachable: `judge` fails
            // fast on a non-zero exit (`.failed`, no confidence to inspect),
            // and `runHermesCLI` used to throw the partial stdout away with
            // the `TransportError.timeout` too. So the honest answer is keyed
            // on what the output SHOWS — `Starting gateway...` with no
            // matched refusal — which covers the exit-0 shape and the timeout
            // shape alike. A timeout WITHOUT the line stays a failure, and a
            // run that also printed a real refusal keeps it.
            //
            // "Started in the foreground, could not confirm" is the honest
            // answer; the banner does not claim "restarted".
            return HermesCLIOutcome(
                succeeded: false,
                detail: foregroundStartNote,
                warning: nil,
                confidence: .unconfirmed
            )
        }
        guard verb == .stop, !verdict.succeeded, exitCode == 0 else { return verdict }
        // Decision 2: "nothing was running" is the state the user asked for.
        // Only ever reached when no success line printed — `_cmd_stop`'s ✓/✗
        // arms are mutually exclusive branches (`gateway.py:5989-6000`).
        //
        // `verdict.detail == nil` when no failure marker matched, because
        // `fallbackDetail` is on and `judge` quotes the last line otherwise.
        // A run that ALSO printed a real refusal (`Refusing to stop the
        // gateway from inside the gateway process.`, `:5776-5781`) keeps that
        // refusal: "nothing was running" must never launder a genuine one.
        let sawNothingRunning = !sawServiceRefusal(lines) && lines.contains { line in
            let head = HermesCLIVerdict.unglyphed(line)
            return HermesCLIMarkers.gatewayNothingRunning.contains { head.hasPrefix($0) }
        }
        guard sawNothingRunning else { return verdict }
        return HermesCLIOutcome(succeeded: true, detail: nil, warning: nothingWasRunningNote)
    }
}

// MARK: - mcp remove / mcp test — hermes_cli/mcp_config.py

/// `hermes mcp remove <name>`, judged by output.
///
/// `cmd_mcp_remove` (`hermes_cli/mcp_config.py:515-532` @ v2026.9.7) is a
/// `-> None` with two exit-0 refusals and one exit-0 partial:
///
/// - `_lookup_server` prints `  ✗ Server '<name>' not found in config.`
///   (`:104`) and returns None; `cmd_mcp_remove` returns (`:518-519`).
/// - the `_confirm` "Cancelled." arm (`:520-522`). Scarf gives the CLI no
///   TTY, and `_confirm`'s `input()` raises `EOFError`, which it catches and
///   answers with its `default=True` (`:39-45`) — so Scarf never takes that
///   arm. The marker is here anyway because the arm is one line away from
///   the one Scarf does take.
/// - on a managed install `_remove_mcp_server` (`:110-121`) calls
///   `save_config`, whose managed arm prints `Cannot save configuration: …`
///   and returns (`hermes_cli/config.py:2316-2318`) — and `:524` prints
///   `  ✓ Removed '<name>' from config` regardless. Hence `failureWins`.
///
/// The success line echoes the SERVER NAME, so the refusal side is matched
/// ANCHORED (the P39b rule); `Removed '` can never be mistaken for `Cannot `
/// at column 0.
public enum HermesMCPRemoveVerdict {
    /// `mcp remove -- <name>`. `name` is the subparser's only positional and
    /// there is no flag after it (`hermes_cli/subcommands/mcp.py:44-45` @
    /// v2026.9.7), so `--` is both safe and necessary: a server name is
    /// user-chosen text from `mcp_servers` and one starting with `-` exits 2.
    public static func argv(name: String) -> [String] { ["mcp", "remove", "--", name] }

    public static func judge(output: String, exitCode: Int32) -> HermesCLIOutcome {
        HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: HermesCLIMarkers.mcpRemoveSuccess,
            anchoredFailureMarkers: HermesCLIMarkers.mcpRemoveFailure,
            failureWins: true,
            successAnchored: true
        )
    }
}

/// `hermes mcp test <name>`, judged by output.
///
/// `cmd_mcp_test` (`hermes_cli/mcp_config.py:583-620` @ v2026.9.7) is a
/// `-> None`: an unknown name returns after `_lookup_server`'s
/// `✗ Server '<name>' not found in config.` (`:104`), and a failed probe
/// returns after `✗ Connection failed ({ms}ms): {exc}` (`:613`). Success is
/// `✓ Connected ({ms}ms)` (`:615`) followed by `✓ Tools discovered: {n}`
/// (`:616`).
///
/// The previous verdict was a bare `output.contains("✗")` over text Hermes
/// does not author: `_print_tools` (`:49-52`) prints every discovered tool's
/// own DESCRIPTION on the SUCCESS path, and a stdio server's stderr is merged
/// into the same stream. One tool documented with a `✗` turned a healthy
/// server red. Both sides are anchored — every line here comes from
/// `_success`/`_error` (`:34-36`), which print at a two-space indent with one
/// glyph, exactly what ``HermesCLIVerdict/unglyphed(_:)`` strips.
public enum HermesMCPTestVerdict {
    /// `mcp test -- <name>` — same reasoning as ``HermesMCPRemoveVerdict``
    /// (`hermes_cli/subcommands/mcp.py:49-50` @ v2026.9.7).
    public static func argv(name: String) -> [String] { ["mcp", "test", "--", name] }

    public static func judge(output: String, exitCode: Int32) -> HermesCLIOutcome {
        HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: HermesCLIMarkers.mcpTestSuccess,
            anchoredFailureMarkers: HermesCLIMarkers.mcpTestFailure,
            failureWins: true,
            successAnchored: true
        )
    }
}

// MARK: - plugins update — hermes_cli/plugins_cmd.py

/// `hermes plugins update <name>`, which has THREE outcomes rather than two.
///
/// `cmd_update` calls `_rescan_after_update` (`hermes_cli/plugins_cmd.py:810`
/// @ v2026.9.7) BEFORE it announces anything. When the post-pull security scan
/// returns a `dangerous` verdict that rescan DISABLES the plugin and prints
///
/// ```
/// ⚠ Security scan flagged the updated plugin: {reason}
/// …the scan report…
/// Plugin '<name>' has been disabled. Review the findings, then re-enable
/// with `hermes plugins enable <name>` if you trust them.
/// ```
///
/// (`:842-851`) — and then `:828` prints `✓ Plugin <name> updated.` anyway.
/// Both at exit 0. The tree really was pulled, so this is not a failure; the
/// plugin really is off, so it is not the plain success Scarf used to report.
/// Round-4 product decision 3 makes it a third state carried on
/// ``HermesCLIOutcome/warning``, quoting Hermes's own reason line (`:843`).
///
/// **The flag and the disable are two different arms.** `_rescan_after_update`
/// returns early only when `should_allow_plugin_install` said `allowed is
/// True` (`:840-841`); every other verdict prints the `⚠ Security scan
/// flagged the updated plugin: {reason}` line and the report (`:843-844`),
/// and ONLY `scan_result.verdict == "dangerous"` goes on to disable the
/// plugin (`:845-851`). A `suspicious` verdict therefore leaves the plugin
/// enabled with a flag against it — which Scarf reported as a flat "Updated"
/// while it keyed the third state on `has been disabled.`. The warning is
/// keyed on the FLAGGED line now; the disable line only chooses between the
/// two wordings.
///
/// **Why the success side needed anchoring.** `pluginsUpdateSuccess`'s
/// `"updated."` was a bare substring over output Hermes does not author — the
/// raw `git pull` body (`:829`) and the scan report (`:844`). A commit message
/// reading "docs updated." in a run that printed no success line of its own
/// was a false success. The real line is `✓ Plugin <name> updated.`, so this
/// requires the column-0 `Plugin ` prefix AND one of the two tails, which no
/// pull body or scan finding satisfies by accident.
///
/// **Why this stays bespoke rather than calling `HermesCLIVerdict.judge`.**
/// `judge`'s third outcome is `.unconfirmed` — the shape where a verb can
/// finish printing NOTHING the client recognises, and silence must not read
/// as success. `cmd_update` (`:794-830`) has no such arm: every path through
/// it ends in either a refusal (`_require_installed_plugin` `:797`, `_fail`
/// on a `PluginOperationError` `:809-810`, the capability-consent abort
/// `:826`) or one of the two `✓ Plugin <name> …` lines (`:825-829`),
/// so `!succeeded` is already a failure and there is nothing for
/// `.unconfirmed` to carry. What this verb has instead is a third SUCCESS
/// state — updated-but-flagged / updated-then-disabled (`:842-851`) — which
/// `judge` has no vocabulary for: it produces an `HermesCLIOutcome` with a
/// `warning` on the success side. Fold this into `judge` only if that warning
/// shape becomes general.
public enum HermesPluginsUpdateVerdict {
    public static func argv(name: String) -> [String] { ["plugins", "update", "--", name] }

    /// `✓ Plugin <name> updated.` (`:828`) /
    /// `✓ Plugin <name> is already up to date.` (`:826`), matched as the whole
    /// shape rather than either half.
    static func isSuccessLine(_ line: String) -> Bool {
        let head = HermesCLIVerdict.unglyphed(line)
        guard head.hasPrefix("Plugin ") else { return false }
        return HermesCLIMarkers.pluginsUpdateSuccess.contains { head.hasSuffix($0) }
    }

    /// `Plugin '<name>' has been disabled.` (`:848-851`). Anchored on the
    /// column-0 `Plugin ` prefix so the `git pull` echo (`:829`) and the scan
    /// report (`:844`) — text Hermes does not author — cannot supply it.
    ///
    /// `contains`, not `hasSuffix`: the emitter continues the same print with
    /// " Review the findings, then re-enable with `hermes plugins enable
    /// <name>` if you trust them.", so the clause is never at end of line.
    /// `rich` wraps at its 80-column non-TTY default; the clause survives the
    /// first wrap for any plugin name under ~45 characters, and a longer name
    /// that splits it only costs the wording (the `⚠ Security scan flagged`
    /// line at `:843` prints for EVERY not-allowed verdict, so the warning
    /// itself still fires).
    static func isSecurityDisableLine(_ line: String) -> Bool {
        let head = HermesCLIVerdict.unglyphed(line)
        return head.hasPrefix("Plugin ")
            && head.contains(HermesCLIMarkers.pluginsUpdateSecurityDisabled)
    }

    public static func judge(output: String, exitCode: Int32) -> HermesCLIOutcome {
        let lines = HermesCLIVerdict.significantLines(output)
        let succeeded = lines.contains(where: isSuccessLine)
        let refusal = lines.first { line in
            HermesCLIMarkers.pluginsUpdateFailure.contains { line.contains($0) }
                || HermesCLIMarkers.managedRefusalAnchored.contains {
                    HermesCLIVerdict.unglyphed(line).hasPrefix($0)
                }
        }
        // `failureWins`, as before: the consent refusal and the managed
        // refusal both print BEFORE the success line by design.
        if exitCode != 0 || refusal != nil || !succeeded {
            return HermesCLIOutcome(succeeded: false, detail: refusal ?? lines.last)
        }
        // The scan verdict is keyed on the FLAGGED line, not on the disable.
        // `_rescan_after_update` prints `⚠ Security scan flagged the updated
        // plugin: {reason}` plus the report for EVERY not-allowed verdict
        // (`plugins_cmd.py:842-844`) and only adds
        // `Plugin '<name>' has been disabled.` when the verdict is
        // `dangerous` (`:845-851`). Keying the third state on the disable
        // reported a flagged-but-still-enabled update as a plain "Updated" —
        // the user never learned the scan had found anything.
        let flagged = lines.first { $0.contains(HermesCLIMarkers.pluginsUpdateScanFlagged) }
        let disabled = lines.first(where: isSecurityDisableLine)
        guard let reason = flagged ?? disabled else {
            return HermesCLIOutcome(succeeded: true, detail: nil)
        }
        // `has been disabled.` selects the wording; the flagged line is the
        // reason either way.
        let warning = disabled != nil
            ? String(localized: "Updated, then disabled by the security scan. \(reason)")
            : String(localized: "Updated, but the security scan flagged it. \(reason)")
        return HermesCLIOutcome(succeeded: true, detail: nil, warning: warning)
    }
}

// MARK: - auth logout — hermes_cli/auth.py

/// `hermes auth logout <provider>`, judged by output.
///
/// P47, round-5 decision 2. `logout_command` (`hermes_cli/auth.py:2173-2196`
/// @ `v2026.9.7`) is a `-> None` with **two exit-0 arms that clear nothing**:
///
/// - `No provider is currently logged in.` (`:2180`) — no `--provider`
///   argument, no active provider and no config default.
/// - `No auth state found for {provider_name}.` (`:2185`) — the provider is
///   known, but `clear_provider_auth` found nothing to clear and no config
///   reset was due.
///
/// Both `return`, so Python exits 0 and `CredentialPoolsViewModel` reported
/// `Removed OAuth provider <p>` over a run that removed nothing. The only
/// nonzero exit on the verb is the unknown-provider guard
/// (`:2177-2179`, `raise SystemExit(1)`), which the exit code already covers.
///
/// Success is `Logged out of {provider_name}.` (`:2189`) — column 0, no glyph,
/// byte-identical from `v2026.6.19` through `v2026.9.7` (walked at
/// `v2026.6.19`, `v2026.7.30`, `v2026.8.19`, `v2026.9.7`).
///
/// **Decision 2: the no-op arms are a SUCCESS with a neutral note**, the same
/// shape ``HermesGatewayServiceVerdict/nothingWasRunningNote`` uses for
/// "nothing was running": the user asked for the provider to be logged out
/// and it is. The note is what stops the banner claiming a removal happened.
///
/// The success line echoes the provider's DISPLAY NAME, which is Hermes's own
/// text rather than the user's, so nothing here needs the anchored-failure
/// treatment `config set` does — but the markers are matched anchored anyway,
/// because every one of the three lines is printed at column 0.
public enum HermesAuthLogoutVerdict {
    /// `auth logout -- <provider>`. `provider` is the subparser's only
    /// positional and no flag follows it
    /// (`hermes_cli/subcommands/auth.py:59-61` @ `v2026.9.7`), so `--` is
    /// accepted and stops a provider id that begins with a dash from being
    /// read as an option (argparse would exit 2).
    public static func argv(provider: String) -> [String] {
        ["auth", "logout", "--", provider]
    }

    /// `Logged out of {provider_name}.` (`auth.py:2189`).
    static let successPrefix = "Logged out of "

    /// The two arms that cleared nothing (`:2180`, `:2185`).
    static let nothingToClear = [
        "No provider is currently logged in.",
        "No auth state found for ",
    ]

    /// The neutral note decision 2 asks for.
    public static let nothingToClearNote = String(
        localized: "There was no stored auth state for this provider."
    )

    public static func judge(output: String, exitCode: Int32) -> HermesCLIOutcome {
        let lines = HermesCLIVerdict.significantLines(output)
        guard exitCode == 0 else {
            return HermesCLIOutcome(succeeded: false, detail: lines.last)
        }
        if lines.contains(where: { HermesCLIVerdict.unglyphed($0).hasPrefix(successPrefix) }) {
            return HermesCLIOutcome(succeeded: true, detail: nil)
        }
        let idle = lines.contains { line in
            let head = HermesCLIVerdict.unglyphed(line)
            return nothingToClear.contains { head.hasPrefix($0) }
        }
        if idle { return HermesCLIOutcome(succeeded: true, detail: nil, warning: nothingToClearNote) }
        // Exit 0, no success line, neither idle arm: C5's "we do not know".
        return HermesCLIOutcome(
            succeeded: false, detail: lines.last, warning: nil, confidence: .unconfirmed
        )
    }
}

// MARK: - memory reset — hermes_cli/main_agent_cmds.py

/// `hermes memory reset --yes`, judged by output.
///
/// P47, round-5 decision 3. `_cmd_memory_reset`
/// (`hermes_cli/main_agent_cmds.py:21-56` @ `v2026.9.7`) is a `-> None` whose
/// **nothing-to-do arm exits 0**:
/// `Nothing to reset — no memory files found in {home}/memories/` (`:32-33`),
/// then a bare `return`. Both Mac (`MemoryView.resetMemoryRemotely`) and iOS
/// (`MemoryListView.resetMemory`) judged that by exit code and then reloaded
/// as though the wipe had happened.
///
/// Success is `Memory reset complete. New sessions will start with a blank
/// slate.` (`:55`). Every line this handler prints is indented two spaces;
/// ``HermesCLIVerdict/significantLines`` trims, so both markers are anchored
/// after the trim.
///
/// The `Cancelled.` arms (`:46`, `:48`) are unreachable from Scarf — both
/// callers pass `--yes`, which short-circuits the `input()` (`:43`).
///
/// **Decision 3: nothing-to-reset is a SUCCESS with a neutral note**, the
/// same shape as decision 2's `auth logout` and round-4 decision 2's gateway
/// stop.
public enum HermesMemoryResetVerdict {
    /// `memory reset --yes`. There is no positional to separate, so no `--`.
    public static let argv = ["memory", "reset", "--yes"]

    /// `Memory reset complete.` (`main_agent_cmds.py:55`).
    static let successPrefix = "Memory reset complete."

    /// `Nothing to reset — no memory files found in …` (`:33`). Matched on
    /// the ASCII head alone: the em dash and the interpolated home path are
    /// downstream of it, and the head is unique in the file.
    static let nothingToResetPrefix = "Nothing to reset"

    /// The neutral note decision 3 asks for.
    public static let nothingToResetNote = String(
        localized: "There were no memory files to reset."
    )

    public static func judge(output: String, exitCode: Int32) -> HermesCLIOutcome {
        let lines = HermesCLIVerdict.significantLines(output)
        guard exitCode == 0 else {
            return HermesCLIOutcome(succeeded: false, detail: lines.last)
        }
        if lines.contains(where: { HermesCLIVerdict.unglyphed($0).hasPrefix(successPrefix) }) {
            return HermesCLIOutcome(succeeded: true, detail: nil)
        }
        if lines.contains(where: { HermesCLIVerdict.unglyphed($0).hasPrefix(nothingToResetPrefix) }) {
            return HermesCLIOutcome(succeeded: true, detail: nil, warning: nothingToResetNote)
        }
        return HermesCLIOutcome(
            succeeded: false, detail: lines.last, warning: nil, confidence: .unconfirmed
        )
    }

    /// The text a failed `hermes memory reset` shows — three branches, not
    /// two (round-6 P59).
    ///
    /// `.unconfirmed` is gated on the CONFIDENCE ALONE, not on whether there
    /// is a line to quote — the same invariant
    /// ``SettingsViewModel/backupFailureSummary(outcome:)`` and
    /// `HealthViewModel.sessionsOptimizeSummary` carry. `judge` fills
    /// `detail` with `lines.last` on the unconfirmed arm too, and on a run
    /// that printed neither marker that tail is some unrelated line —
    /// rendering it as the alert's reason presents a sentence Hermes never
    /// said as its refusal. Both consumers (Mac `MemoryView`, iOS
    /// `MemoryListView`) had `outcome.detail ?? (exit-code branch)`, which
    /// reaches the honest sentence only when the output was EMPTY.
    ///
    /// A `static` formatter rather than an inline branch in each view,
    /// because inline this text is reachable only through a live `hermes` —
    /// and because there are two views, which is how the arms diverged.
    public static func failureSummary(outcome: HermesCLIOutcome, exitCode: Int32) -> String {
        if outcome.confidence == .unconfirmed {
            return String(localized: "hermes memory reset printed no result. Check the host.")
        }
        if let detail = outcome.detail, !detail.isEmpty { return detail }
        return String(localized: "hermes memory reset exited with status \(exitCode).")
    }
}

// MARK: - sessions optimize — hermes_cli/sessions_cmd.py

/// `hermes sessions optimize`, judged by output.
///
/// P47. `_cmd_optimize` (`hermes_cli/sessions_cmd.py:809-819` @ `v2026.9.7`)
/// catches every exception from `db.vacuum()`, prints
/// `Error: optimization failed: {e}` (`:815`) and **returns** — exit 0. The
/// Health pane rendered the last two lines of that output as its summary, so
/// a failed VACUUM read as an optimisation report.
///
/// Success is `Optimized {n} FTS index(es).` (`:817`), followed by
/// `_print_size_change`'s `Database size: … -> … (…)` (`:806`). The summary
/// the pane shows is still the output tail; this decides only whether it is
/// presented as one.
public enum HermesSessionsOptimizeVerdict {
    public static let argv = ["sessions", "optimize"]

    /// `Optimized {n} FTS index(es).` (`sessions_cmd.py:817`) — column 0, no
    /// glyph. The trailing space is load-bearing: it is what separates the
    /// line from any other word beginning "Optimiz…", in particular the
    /// in-progress `Optimizing session store (FTS merge + VACUUM)…` (`:811`)
    /// that every run prints FIRST.
    static let successPrefix = "Optimized "

    /// `Error: optimization failed: {e}` (`:815`).
    static let failurePrefix = "Error: optimization failed:"

    public static func judge(output: String, exitCode: Int32) -> HermesCLIOutcome {
        let lines = HermesCLIVerdict.significantLines(output)
        guard exitCode == 0 else {
            return HermesCLIOutcome(succeeded: false, detail: lines.last)
        }
        let refusal = lines.first { HermesCLIVerdict.unglyphed($0).hasPrefix(failurePrefix) }
        // `failureWins` in spirit: the two arms are exclusive branches, but a
        // refusal is a positive signal and must outrank a stray prefix match.
        if let refusal { return HermesCLIOutcome(succeeded: false, detail: refusal) }
        if lines.contains(where: { HermesCLIVerdict.unglyphed($0).hasPrefix(successPrefix) }) {
            return HermesCLIOutcome(succeeded: true, detail: nil)
        }
        return HermesCLIOutcome(
            succeeded: false, detail: lines.last, warning: nil, confidence: .unconfirmed
        )
    }
}

// MARK: - backup — hermes_cli/backup.py

/// `hermes backup`, judged by output.
///
/// P54, round-6. `_run_backup_locked` (`hermes_cli/backup.py:622-681`
/// @ `v2026.9.7`) is a `-> None` with **two exit-0 arms Scarf reported as a
/// saved backup**:
///
/// - `No files to back up.` (`:633`) — the scan found nothing, and the
///   function `return`s before an archive is ever created. There is no zip.
/// - `Backup incomplete: {path}` (`:666`, the `'incomplete' if errors else
///   'complete'` interpolation) followed by
///   `Warnings ({n} files skipped):` (`:679`) — the archive exists but is
///   missing files, typically an unreadable `state.db` or a permission
///   error. `errors` is appended by `_write_zip_entries`'s `on_db_failure`
///   / `on_error` callbacks (`:652-653`) and by the external-entry loop
///   (`:660-661`); nothing in either path raises, so the run exits 0.
///
/// `import` is the only verb whose SUCCESS line the old code could have
/// distinguished, and it did not look at either: `runBackup` keyed on
/// `result.exitCode == 0` and then on whether a `.zip` path could be
/// regexed out of the output — which `Backup incomplete: /…/x.zip` satisfies
/// exactly as well as the complete form, so a partial archive was revealed
/// in Finder under "Backup saved".
///
/// The incomplete arm is a **partial success**, not a failure, and takes the
/// ``HermesCLIOutcome/warning`` channel `config set`'s mirror refusal uses:
/// the zip is real and restorable, it just is not everything. The
/// nothing-to-back-up arm is the house "nothing to do" answer — a success
/// with a neutral note (P47's third convention, after `auth logout` and
/// `memory reset`).
///
/// **The tag walk, and what C1 turns on.** Opened at `v2026.6.19`,
/// `v2026.7.30`, `v2026.8.19` and `v2026.9.7`:
///
/// - `Backup complete: {out_path}` is present at all four (`:314`, `:647`,
///   `:816`, `:666`). The v0.21.1 spelling is the interpolation
///   `Backup {'incomplete' if errors else 'complete'}: {out_path}`; the
///   earlier tags print the two as separate `print` calls. Same bytes on the
///   wire either way.
/// - `Backup incomplete: {out_path}` exists from `v2026.7.30` (`:645`)
///   onward. **`v2026.6.19` has no incomplete arm at all** — it prints the
///   complete line unconditionally — so on such a host this verdict's
///   incomplete branch can never fire and the pane renders exactly as it did
///   before P54. That is the C1 answer for the one range outside the window:
///   nothing is hidden there, because Hermes emits nothing to hide.
/// - `No files to back up.` (`:266`, `:585`, `:734`, `:633`) and
///   `Warnings ({n} files skipped):` (`:326`, `:673`, `:842`, `:679`) are
///   byte-identical at all four.
///
/// **C1 below the window — `v0.6.0`–`v0.17.0` (lesson 13).** The
/// `.unconfirmed` arm this verdict added is a GATE on a surface that had
/// none, so it owes an answer for every range outside the walk.
/// `hermes_cli/backup.py` does not exist before `v2026.4.13`; at the oldest
/// tag in the repo, `v2026.3.30` (v0.6.0), `hermes_cli/main.py` carries no
/// `backup` parser at all, so the verb is unknown and routes to the agent at
/// exit 0 (C5). Agent prose never contains `Backup complete: `, so this
/// verdict returns `.unconfirmed` and the pane says "hermes backup printed
/// no result. Check the host." — where, before P54, the SAME host read
/// "Backup saved" over a backup that never happened. The gate makes that
/// range strictly more honest, which is what C1 asks of an added gate. From
/// `v2026.4.13` onward the markers are really there (`:217` complete, `:175`
/// nothing-to-back-up, `:229` warnings), so the confirmed and refusal arms
/// fire exactly as at the target tag.
public enum HermesBackupVerdict {
    /// `backup`, before the host's flags are applied. No positional — nothing
    /// to separate. Call sites use ``argv(capabilities:)``.
    public static let baseArgv = ["backup"]

    /// The argv for this host. On v0.21.2+ (`HermesCapabilities.hasBackupKeep`)
    /// appends `--keep 0` so Hermes's new default (`--keep 3`, `hermes_cli/
    /// subcommands/backup.py:23-26` @ v2026.9.11) does not delete the user's
    /// older `~/hermes-backup-*.zip` files on Scarf's "Backup Now"; below the
    /// floor the flag does not parse, so the argv is the bare verb.
    public static func argv(capabilities: HermesCapabilities) -> [String] {
        capabilities.hasBackupKeep ? baseArgv + ["--keep", "0"] : baseArgv
    }

    /// `Backup complete: {out_path}` (`backup.py:666`). The trailing space
    /// and colon are load-bearing: `Backup incomplete: ` is NOT a superset
    /// of this string, so the two prefixes cannot both match one line.
    static let successPrefix = "Backup complete: "

    /// `Backup incomplete: {out_path}` (`:666`) — the archive was written,
    /// but `errors` is non-empty.
    static let incompletePrefix = "Backup incomplete: "

    /// `Warnings ({len(errors)} files skipped):` (`:679`), printed by
    /// `_print_capped` right after the incomplete line.
    static let warningsPrefix = "Warnings ("

    /// `No files to back up.` (`:633`) — the scan arm that writes no zip.
    static let nothingToBackUpPrefix = "No files to back up."

    /// The neutral note for the nothing-to-back-up arm.
    public static let nothingToBackUpNote = String(
        localized: "Hermes found no files to back up, so no archive was written."
    )

    /// The warning a partial archive carries.
    public static let incompleteNote = String(
        localized: "Some files were skipped — the archive is incomplete."
    )

    public static func judge(output: String, exitCode: Int32) -> HermesCLIOutcome {
        let lines = HermesCLIVerdict.significantLines(output)
        guard exitCode == 0 else {
            return HermesCLIOutcome(succeeded: false, detail: lines.last)
        }
        func head(_ line: String) -> String { HermesCLIVerdict.unglyphed(line) }
        // The incomplete arm is checked FIRST: it is a distinct prefix, but
        // reading it before the success prefix makes the precedence explicit
        // rather than incidental.
        if let incomplete = lines.first(where: { head($0).hasPrefix(incompletePrefix) }) {
            let skipped = lines.first { head($0).hasPrefix(warningsPrefix) }
            // The archive IS written, so this succeeds — with Hermes's own
            // "Warnings (N files skipped):" line when it printed one, which
            // is the only place the count lives.
            return HermesCLIOutcome(
                succeeded: true,
                detail: incomplete,
                warning: skipped.map { "\(incompleteNote) \($0)" } ?? incompleteNote
            )
        }
        if lines.contains(where: { head($0).hasPrefix(successPrefix) }) {
            return HermesCLIOutcome(succeeded: true, detail: nil)
        }
        if lines.contains(where: { head($0).hasPrefix(nothingToBackUpPrefix) }) {
            return HermesCLIOutcome(succeeded: true, detail: nil, warning: nothingToBackUpNote)
        }
        return HermesCLIOutcome(
            succeeded: false, detail: lines.last, warning: nil, confidence: .unconfirmed
        )
    }
}

// MARK: - import — hermes_cli/backup.py

/// `hermes import --force <zip>`, judged by output.
///
/// P54, round-6 **decision 1** — and the HIGH finding of the round: before
/// this, `hermes import <path>` could not restore into a live Hermes home AT
/// ALL from Scarf.
///
/// `run_import` (`hermes_cli/backup.py:919-…` @ `v2026.9.7`) gates on
/// `if not args.force and not _confirm_import_overwrite(hermes_root)`
/// (`:942`). `_confirm_import_overwrite` (`:829-843`) returns `True` only
/// when the target has neither `config.yaml` nor `.env` — i.e. only into an
/// EMPTY home. On any real home it prints the overwrite warning and calls
/// bare `input("Continue? [y/N] ")` (`:836`). Scarf's CLI child inherits a
/// closed/`/dev/null` stdin, so `input()` raises `EOFError`, which the
/// handler catches to print `Aborted.` and `sys.exit(1)` (`:837-839`).
/// Every restore therefore exited 1 and the Settings pane showed a bare
/// "Restore failed" with no hint that a prompt nobody could answer was the
/// cause.
///
/// **Decision 1: pass `--force`; Scarf's restore sheet is the consent.**
/// The flag is `--force`/`-f` on the `import` subparser
/// (`hermes_cli/subcommands/import_cmd.py:16-17` @ `v2026.9.7`) and exists
/// precisely to say the confirmation was collected elsewhere. Scarf already
/// collects it: the user picks the archive and confirms the restore in the
/// sheet before this runs. **No stdin pipe** — writing `y\n` into the child
/// would be Scarf answering a question on the user's behalf, which is the
/// opposite of consent.
///
/// The verb is `_forward_command`ed without `forward_return`
/// (`hermes_cli/main.py:1755-1772`), so beyond the three `sys.exit(1)`
/// guards (`:924`, `:927`, `:935`) every arm exits 0 — including the two
/// partial-restore arms, which is why this is a verdict and not an exit-code
/// check even with `--force` in place.
///
/// **The tag walk, and what C1 turns on.** Opened at `v2026.6.19`,
/// `v2026.7.30`, `v2026.8.19` and `v2026.9.7`:
///
/// - `--force`/`-f` is on the `import` subparser at ALL four
///   (`hermes_cli/subcommands/import_cmd.py:25-30` @ `v2026.6.19`, `:16-17`
///   @ `v2026.9.7`), and the gate reads it at all four (`backup.py:425`,
///   `:773`, `:1066`, `:942`). So the flag is safe on every host Scarf
///   supports at these tags — argparse never sees an unknown option — and on
///   every one of them it turns a guaranteed `EOFError` exit 1 into a real
///   restore. There is no range where adding it makes a host worse.
/// - `Import complete: {restored} files restored in {elapsed}s` is present
///   at all four (`:494`, `:876`, `:1170`, `:950`); only `v2026.9.7` appends
///   the `  Target: …` second line, which is downstream of the prefix.
/// - `Warnings ({n} files skipped):` is present at all four (`:498`, `:886`,
///   `:1180`, `:955`).
/// - `⚠ Session data replaced by older backup contents:` is **new at
///   `v2026.9.7`** (`:959`; absent at the other three). An older host never
///   prints it, so the shrink note simply never fires there — additive, and
///   the only arm of this verdict that is.
///
/// **C1 below the window — `v0.6.0`–`v0.17.0` (lesson 13).** Same shape as
/// ``HermesBackupVerdict``: `hermes_cli/backup.py` (which hosts
/// `run_import`) and `hermes_cli/subcommands/import_cmd.py` are both absent
/// before `v2026.4.13`, and `v2026.3.30` has no `import` parser in
/// `hermes_cli/main.py`. On such a host `hermes import --force -- <path>`
/// is an unknown verb routed to the agent at exit 0, prints no
/// `Import complete: `, and lands on `.unconfirmed` — "hermes import printed
/// no result. Check the host." Before P54 that host read "Restore complete —
/// restart Scarf". `Import complete: ` and `Warnings ({n} files skipped):`
/// are present from `v2026.4.13` (`:384`, `:388`), so the confirmed arm
/// fires from there on.
public enum HermesImportVerdict {
    /// `import --force -- <path>`.
    ///
    /// The flag comes FIRST and the separator after it: `zipfile` is the
    /// subparser's only positional and nothing follows it
    /// (`hermes_cli/subcommands/import_cmd.py:15-17` @ `v2026.9.7`), so
    /// everything past `--` is read as that positional and a backup path
    /// beginning with a dash stops exiting 2. An appended flag after `--`
    /// would be the error P47 documented on `sessions delete`.
    ///
    /// `--force` is a **parameter that IS the fix**, so it is not optional
    /// and there is no non-forced spelling to reach for by accident.
    public static func argv(path: String) -> [String] {
        ["import", "--force", "--", path]
    }

    /// `Import complete: {restored} files restored in {elapsed}s`
    /// (`backup.py:950`).
    static let successPrefix = "Import complete: "

    /// `Warnings ({len(errors)} files skipped):` (`:955`) — path-traversal
    /// blocks and per-file `PermissionError`/`OSError`, collected by
    /// `_import_members` (`:889`, `:911`) and printed at exit 0.
    static let warningsPrefix = "Warnings ("

    /// `⚠ Session data replaced by older backup contents:` (`:959`) — the
    /// restore overwrote a session database with one holding FEWER rows
    /// (`db_shrunk`, `:899`). Hermes's own `⚠` is stripped by
    /// ``HermesCLIVerdict/unglyphed(_:)`` before this is matched.
    static let sessionsShrankPrefix = "Session data replaced by older backup contents:"

    /// The warning a restore that skipped files carries.
    public static let skippedNote = String(
        localized: "Some files were skipped — the restore is incomplete."
    )

    /// The warning a restore that shrank a session database carries. This
    /// is data loss the user cannot see from the Settings pane, so it names
    /// the remedy Hermes names (`:963-964`).
    public static let sessionsShrankNote = String(
        localized: """
            The backup is older than this host's session data — anything \
            recorded after it was taken is gone. Recover from a newer \
            backup or snapshot.
            """
    )

    public static func judge(output: String, exitCode: Int32) -> HermesCLIOutcome {
        let lines = HermesCLIVerdict.significantLines(output)
        guard exitCode == 0 else {
            return HermesCLIOutcome(succeeded: false, detail: lines.last)
        }
        func head(_ line: String) -> String { HermesCLIVerdict.unglyphed(line) }
        guard lines.contains(where: { head($0).hasPrefix(successPrefix) }) else {
            return HermesCLIOutcome(
                succeeded: false, detail: lines.last, warning: nil, confidence: .unconfirmed
            )
        }
        // Both partial arms can fire on ONE run, and the shrink is the more
        // serious of the two — it is silent data loss, where a skipped file
        // is merely absent. Both are reported when both are present.
        var notes: [String] = []
        if lines.contains(where: { head($0).hasPrefix(sessionsShrankPrefix) }) {
            notes.append(sessionsShrankNote)
        }
        if lines.contains(where: { head($0).hasPrefix(warningsPrefix) }) {
            notes.append(skippedNote)
        }
        return HermesCLIOutcome(
            succeeded: true,
            detail: nil,
            warning: notes.isEmpty ? nil : notes.joined(separator: " ")
        )
    }
}

// MARK: - webhook remove / test — hermes_cli/webhook.py

/// The refusal `hermes webhook` prints before ANY subcommand runs.
///
/// `webhook_command` (`hermes_cli/webhook.py:92-103` @ `v2026.9.7`) checks
/// `_is_webhook_enabled()` and, when the platform is off in config, prints
/// `_setup_hint()` (`:100`) and `return`s — the handler never dispatches.
/// `webhook` is `_forward_command`ed WITHOUT `forward_return`
/// (`hermes_cli/main.py:1755-1772`), so this exits 0 and every webhook
/// mutation Scarf ran on a webhook-disabled host reported success.
///
/// The hint's first line is `  Webhook platform is not enabled. To set it
/// up:` (`:70`, inside the `_setup_hint()` f-string at `:67-88`);
/// ``HermesCLIVerdict/significantLines(_:)`` trims the indent, so it anchors.
///
/// **The tag walk.** Every marker in this enum and in the two webhook
/// verdicts below was opened at `v2026.6.19`, `v2026.7.30`, `v2026.8.19` and
/// `v2026.9.7` and is byte-identical at all four — only the line numbers
/// moved (`Webhook platform is not enabled.` `:108`/`:110`/`:110`/`:70`;
/// `No subscription named '{name}'.` `:249`,`:264` / `:258`,`:273` /
/// `:258`,`:273` / `:188`,`:201`; `Removed webhook subscription: {name}`
/// `:255`/`:264`/`:264`/`:193`; `Response ({status}): {body}`
/// `:295`/`:304`/`:304`/`:216`; `Error: {e}` `:297`/`:306`/`:306`/`:218`;
/// `Is the gateway running? (hermes gateway run)`
/// `:298`/`:307`/`:307`/`:219`). So the verdicts change no pane's rendering
/// on any host in that range except where it was already wrong (C1).
///
/// **C1 below the window — `v0.6.0`–`v0.17.0` (lesson 13).** Unlike backup,
/// import and debug share, `hermes_cli/webhook.py` exists at the OLDEST tag
/// in the repo, `v2026.3.30` (v0.6.0), and every marker these three verdicts
/// judge by is already there:
/// `  Webhook platform is not enabled. To set it up:` (`:84`),
/// `  No subscription named '{name}'.` (`:211`, `:226`),
/// `  Removed webhook subscription: {name}` (`:217`),
/// `  Response ({status}): {body}` (`:257`) and
/// `  Is the gateway running? (hermes gateway run)` (`:260`). So on every
/// host Scarf supports the confirmed and refusal arms fire on real lines,
/// and the `.unconfirmed` arm can only be reached by a genuinely silent
/// run — there is no version range where this added gate hides a working
/// surface.
enum HermesWebhookGate {
    static let disabledPrefix = "Webhook platform is not enabled."

    /// `  No subscription named '{name}'.` — printed by `_cmd_remove`
    /// (`:188`) and by `_cmd_test` (`:201`), both followed by a bare
    /// `return` at exit 0.
    static let notFoundPrefix = "No subscription named "

    /// The sentence a disabled-platform refusal shows. Names the cause the
    /// hint names, which the anchored marker DOES prove here: unlike
    /// `"Cannot "`, this line has exactly one emitter.
    static let disabledNote = String(
        localized: "The webhook platform is not enabled on this host. Run the gateway setup wizard first."
    )
}

/// `hermes webhook remove <name>`, judged by output.
///
/// P54, round-6. Three exit-0 arms, all previously reported as "Removed":
/// the disabled-platform gate (``HermesWebhookGate/disabledPrefix``),
/// `No subscription named '{name}'.` (`webhook.py:188`, which also notes
/// that static config.yaml routes cannot be removed here), and the real
/// removal `  Removed webhook subscription: {name}` (`:193`).
public enum HermesWebhookRemoveVerdict {
    /// `webhook remove -- <name>`. `name` is the subparser's only positional
    /// and carries no flags (`hermes_cli/subcommands/webhook.py:42-43` @
    /// `v2026.9.7`).
    public static func argv(name: String) -> [String] {
        ["webhook", "remove", "--", name]
    }

    /// `  Removed webhook subscription: {name}` (`webhook.py:193`).
    static let successPrefix = "Removed webhook subscription: "

    public static func judge(output: String, exitCode: Int32) -> HermesCLIOutcome {
        let lines = HermesCLIVerdict.significantLines(output)
        guard exitCode == 0 else {
            return HermesCLIOutcome(succeeded: false, detail: lines.last)
        }
        func head(_ line: String) -> String { HermesCLIVerdict.unglyphed(line) }
        // A refusal outranks a success line the way `failureWins` does: the
        // gate returns BEFORE the handler, so the two cannot co-occur, but a
        // positive refusal signal must never lose to a stray prefix match.
        if lines.contains(where: { head($0).hasPrefix(HermesWebhookGate.disabledPrefix) }) {
            return HermesCLIOutcome(succeeded: false, detail: HermesWebhookGate.disabledNote)
        }
        if let notFound = lines.first(where: { head($0).hasPrefix(HermesWebhookGate.notFoundPrefix) }) {
            return HermesCLIOutcome(succeeded: false, detail: notFound)
        }
        if lines.contains(where: { head($0).hasPrefix(successPrefix) }) {
            return HermesCLIOutcome(succeeded: true, detail: nil)
        }
        return HermesCLIOutcome(
            succeeded: false, detail: lines.last, warning: nil, confidence: .unconfirmed
        )
    }
}

/// `hermes webhook test <name>`, judged by output.
///
/// P54, round-6. `_cmd_test` (`webhook.py:196-219` @ `v2026.9.7`) wraps the
/// POST in a bare `except Exception` that prints `  Error: {e}` (`:218`) and
/// `  Is the gateway running? (hermes gateway run)` (`:219`) — then falls off
/// the end of the function at exit 0. A connection refused because the
/// gateway is down looked exactly like a delivered test.
///
/// Success is `  Response ({resp.status}): {body}` (`:216`), printed only
/// inside the `with urllib.request.urlopen(...)` block — and **only for a
/// 2xx**. `urllib.request`'s default opener installs `HTTPErrorProcessor`,
/// which raises `HTTPError` for any code outside `200..<300`, so a gateway
/// that answers 401 or 500 takes the `except Exception` arm below and prints
/// `  Error: HTTP Error 500: Internal Server Error` — NOT a
/// `Response (500)` line, which Hermes can never emit.
///
/// That has a consequence worth knowing: on a non-2xx answer Hermes also
/// prints its `Is the gateway running?` hint, and the gateway plainly IS
/// running. Scarf quotes Hermes's own two lines rather than second-guessing
/// them (the `Error:` text names the real status), but the misleading half
/// of that sentence is Hermes's, not ours — `t-<filed>` tracks proposing a
/// narrower hint upstream. Either way a non-2xx is a FAILURE here, which is
/// the part the exit code got wrong.
///
/// The success `detail` carries the response line because the gateway's own
/// 2xx body is the result the button exists to show.
public enum HermesWebhookTestVerdict {
    /// `webhook test -- <name>`. `name` is the first positional and Scarf
    /// passes no `--payload` (`hermes_cli/subcommands/webhook.py:45-48` @
    /// `v2026.9.7`), so the separator is the last token before it.
    public static func argv(name: String) -> [String] {
        ["webhook", "test", "--", name]
    }

    /// `  Response ({status}): {body}` (`webhook.py:216`).
    static let successPrefix = "Response ("

    /// `  Error: {e}` (`:218`), the `except Exception` arm.
    static let failurePrefix = "Error: "

    /// `  Is the gateway running? (hermes gateway run)` (`:219`) — always
    /// printed with the `Error:` line, and the more useful of the two when
    /// the exception's `str()` is something like `<urlopen error [Errno 61]
    /// Connection refused>`.
    static let gatewayHintPrefix = "Is the gateway running?"

    public static func judge(output: String, exitCode: Int32) -> HermesCLIOutcome {
        let lines = HermesCLIVerdict.significantLines(output)
        guard exitCode == 0 else {
            return HermesCLIOutcome(succeeded: false, detail: lines.last)
        }
        func head(_ line: String) -> String { HermesCLIVerdict.unglyphed(line) }
        if lines.contains(where: { head($0).hasPrefix(HermesWebhookGate.disabledPrefix) }) {
            return HermesCLIOutcome(succeeded: false, detail: HermesWebhookGate.disabledNote)
        }
        if let notFound = lines.first(where: { head($0).hasPrefix(HermesWebhookGate.notFoundPrefix) }) {
            return HermesCLIOutcome(succeeded: false, detail: notFound)
        }
        if let error = lines.first(where: { head($0).hasPrefix(failurePrefix) }) {
            let hint = lines.first { head($0).hasPrefix(gatewayHintPrefix) }
            return HermesCLIOutcome(
                succeeded: false,
                detail: hint.map { "\(error) \($0)" } ?? error
            )
        }
        if let response = lines.first(where: { head($0).hasPrefix(successPrefix) }) {
            // The detail rides along on SUCCESS here, unlike every other
            // verdict in this file: the gateway's own 2xx answer (status and
            // body) is the result the button exists to show, and it lives
            // nowhere else once the run is judged.
            return HermesCLIOutcome(succeeded: true, detail: response, warning: nil, confidence: .confirmed)
        }
        return HermesCLIOutcome(
            succeeded: false, detail: lines.last, warning: nil, confidence: .unconfirmed
        )
    }
}

// MARK: - debug share — hermes_cli/debug.py

/// `hermes debug share`, judged by output.
///
/// P54, round-6. `run_debug_share` (`hermes_cli/debug.py:460-497` @
/// `v2026.9.7`) uploads the report to several paste targets and prints
/// `Debug report uploaded:` (`:490`) followed by one `  {label}  {url}` line
/// per target. When SOME targets failed it then prints
/// `  (failed to upload: {', '.join(result.failures)})` (`:494`) — **at exit
/// 0, after the success block**. Only a total failure raises `RuntimeError`,
/// which prints `Upload failed: …` to stderr and `sys.exit(1)` (`:485-488`).
///
/// The Health pane keyed on `exitCode == 0` and said "Upload complete", so a
/// run that got two of three pastes up read identically to a clean one. The
/// URLs are in `diagnosticsOutput` either way; what was missing was any
/// signal that the list is short.
///
/// **The tag walk.** Both lines opened at `v2026.6.19` (`debug.py:779`,
/// `:784`), `v2026.7.30` (`:866`, `:871`), `v2026.8.19` (`:899`, `:904`) and
/// `v2026.9.7` (`:490`, `:494`) — byte-identical at all four, only the line
/// numbers moved, so C1 holds.
public enum HermesDebugShareVerdict {
    // **C1 below the window — `v0.6.0`–`v0.17.0` (lesson 13).**
    // `hermes_cli/debug.py` does not exist before `v2026.4.13`, and
    // `v2026.3.30` (v0.6.0) has no `debug` parser in `hermes_cli/main.py`:
    // `hermes debug share` is an unknown verb there, routed to the agent at
    // exit 0, so no `Debug report uploaded:` line appears and this verdict
    // returns `.unconfirmed` — "hermes debug share printed no result. Check
    // the host." Before P54 the same host read "Upload complete". From
    // `v2026.4.13` both markers are present and unchanged
    // (`debug.py:311` uploaded, `:316` `(failed to upload: …)`), so the
    // confirmed and partial arms fire there as they do at the target tag.

    /// `Debug report uploaded:` (`debug.py:490`). Column 0 after the
    /// leading `\n`.
    static let successPrefix = "Debug report uploaded:"

    /// `  (failed to upload: {…})` (`:494`).
    static let partialPrefix = "(failed to upload:"

    /// The warning a partial upload carries.
    public static let partialNote = String(
        localized: "Some upload targets failed — not every link below was created."
    )

    /// `--local` never uploads: `run_debug_share`'s first branch prints the
    /// report and returns, so there is no `Debug report uploaded:` line to
    /// find. The local run is judged by its exit code alone, which is why
    /// this takes the flag rather than guessing from the output.
    public static func judge(output: String, exitCode: Int32, local: Bool) -> HermesCLIOutcome {
        let lines = HermesCLIVerdict.significantLines(output)
        guard exitCode == 0 else {
            return HermesCLIOutcome(succeeded: false, detail: lines.last)
        }
        guard !local else { return HermesCLIOutcome(succeeded: true, detail: nil) }
        func head(_ line: String) -> String { HermesCLIVerdict.unglyphed(line) }
        guard lines.contains(where: { head($0).hasPrefix(successPrefix) }) else {
            return HermesCLIOutcome(
                succeeded: false, detail: lines.last, warning: nil, confidence: .unconfirmed
            )
        }
        if let partial = lines.first(where: { head($0).hasPrefix(partialPrefix) }) {
            // Hermes's own line names WHICH targets failed; the note alone
            // would lose that.
            return HermesCLIOutcome(
                succeeded: true, detail: nil, warning: "\(partialNote) \(partial)"
            )
        }
        return HermesCLIOutcome(succeeded: true, detail: nil)
    }
}

// MARK: - curator run — hermes_cli/curator.py

/// The prune-only note `hermes curator run` prints when the LLM
/// consolidation pass is off.
///
/// P54, round-6 **decision 2**. `_cmd_run` (`hermes_cli/curator.py:145-186`
/// @ `v2026.9.7`) reads `curator.consolidate` from config when `--consolidate`
/// is absent, and when it is false prints
/// `curator: consolidation is off — running prune-only (deterministic
/// stale/archive). Pass --consolidate or set \`curator.consolidate: true\` to
/// enable the LLM merge pass.` (`:159-163`) before running. The pass still
/// happens and still `return 0`s (`:186`) — it simply does half of what
/// "Run Now" implies.
///
/// **Decision 2: a neutral note beside the success, and NO `--consolidate`
/// on Run Now.** Forcing the LLM pass from a button would spend the user's
/// tokens on a setting they turned off (or never turned on — it defaults to
/// false); the honest answer is to say what ran and let them change the
/// config. This is the `pin`/`unpin` unmanaged-nudge shape
/// (``CuratorService/pin(_:)``): Hermes's own sentence, surfaced instead of
/// discarded, in place of the terse success message.
///
/// **The tag walk.** `curator: consolidation is off — running prune-only …`
/// opened at `v2026.6.19` (`:191`), `v2026.7.30` (`:232`), `v2026.8.19`
/// (`:232`) and `v2026.9.7` (`:161`) — byte-identical at all four.
public enum HermesCuratorRunNote {
    /// `curator: consolidation is off — running prune-only …`
    /// (`curator.py:161`). Matched on the ASCII head alone: the em dash and
    /// the backticked remedy are downstream of it, and the head is unique in
    /// the file.
    static let pruneOnlyPrefix = "curator: consolidation is off"

    /// The note, when the run printed one. `nil` for a full run.
    ///
    /// Detected by CONTENT rather than version-gated, exactly as
    /// `unmanagedNudge` is: a host too old to print this line simply never
    /// matches, so the check is a no-op there and no capability flag is
    /// needed (C1).
    public static func pruneOnlyNote(in output: String) -> String? {
        HermesCLIVerdict.significantLines(output).first {
            HermesCLIVerdict.unglyphed($0).hasPrefix(pruneOnlyPrefix)
        }
    }
}
