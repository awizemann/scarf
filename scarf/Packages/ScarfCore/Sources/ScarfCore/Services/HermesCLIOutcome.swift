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
    public let detail: String?
    /// A refusal the run printed **alongside** a real success line, where the
    /// two are not a contradiction but a PARTIAL write: Hermes wrote one of
    /// the two files it mirrors a key into and refused the other.
    ///
    /// The live shape is `config set terminal.*` — `set_config_value` writes
    /// config.yaml (`hermes_cli/config.py:3508`), then mirrors the key into
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

    public init(succeeded: Bool, detail: String?, warning: String? = nil) {
        self.succeeded = succeeded
        self.detail = detail
        self.warning = warning
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
        func failed(_ detail: String?) -> HermesCLIOutcome {
            HermesCLIOutcome(succeeded: false, detail: detail ?? (fallbackDetail ? lines.last : nil))
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
        // success (C5).
        return failed(refusal)
    }
}

/// The markers each Scarf call site judges by, captured verbatim from the
/// Hermes source at tag v2026.9.7 (charter C2). Each entry cites the emitting
/// `file:line`. Substrings only — the surrounding text interpolates a name, a
/// path or a count.
public enum HermesCLIMarkers {
    // MARK: skills install / uninstall — hermes_cli/skills_hub.py

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

    /// The ONE refusal a package-manager-managed Hermes prints, shared by
    /// every config-mutating verb Scarf shells.
    ///
    /// `get_managed_system()` (`hermes_cli/config.py:276-290` @ v2026.9.7)
    /// answers from `HERMES_MANAGED` or a `$HERMES_HOME/.managed` marker file;
    /// `is_managed()` (`:294-296`) is its bool. Three distinct guards print a
    /// line carrying `is managed by`, and none of them is a `sys.exit`:
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
    /// - `_env_write_blocked`'s managed-scope arm (`:2560-2564`) prints
    ///   `Cannot <action> <KEY>: it is managed by your administrator (…)` and
    ///   returns True — but `set_config_value`'s `.env` branch prints its own
    ///   `✓ Set …` line afterwards regardless (`:3468`), which is exactly why
    ///   every verdict using this marker sets `failureWins: true`.
    ///
    /// **Tag walk.** The managed arms on `set_config_value`/`save_config` first
    /// appear at **v2026.3.28**, whose `managed_error` (`hermes_cli/config.py:65-72`)
    /// printed `Cannot <action>: configuration is managed by NixOS (HERMES_MANAGED=true).`.
    /// v2026.4.3 introduces `format_managed_message` (`:105-113`) with the
    /// `this Hermes installation is managed by …` wording, unchanged in shape
    /// through v2026.6.19 (`:585`), v2026.7.20 (`:659`), v2026.8.31 (`:700`)
    /// and v2026.9.7 (`:445`). The substring `is managed by` is present in
    /// **every** one of those spellings, so one marker covers every tag Scarf
    /// supports and this adds no host-specific behaviour (charter C1).
    ///
    /// **Why not the `Cannot …` prefix alone.** It is per-verb (`Cannot set`,
    /// `Cannot unset`, `Cannot save configuration`), so each verdict still
    /// carries its own; this one is the cross-verb half, and it is what makes
    /// `plugins enable`, `mcp remove` and `skills trust` — which never print a
    /// `Cannot …` line of their own, because the refusal comes from
    /// `save_config` underneath them — judgeable at all.
    ///
    /// **Not a false positive on a success.** The two other `managed by`
    /// strings in the file are `Note: n managed setting(s) were not saved
    /// (managed by your administrator): …` (`_strip_managed_keys_for_save`,
    /// `:2289-2291`) and `⚠ Some settings are managed by your administrator …`
    /// (`_show_managed_banner`, `:2768`). Neither contains `is managed by`
    /// (`were not saved (managed by`, `are managed by`), which is why the
    /// marker carries the `is `.
    public static let managedRefusal = ["is managed by"]

    /// The ANCHORED form of ``managedRefusal``, and the one every
    /// config-mutating verdict actually judges by (round-4 review, P39).
    ///
    /// `is managed by` as a bare substring was unsafe on exactly the verbs it
    /// was added for: `set_config_value` ECHOES the user's value on its
    /// success line — `✓ Set {key} = {value} in {config_path}`
    /// (`hermes_cli/config.py:3521` @ v2026.9.7) — so a QuickCommands prompt
    /// or a platform-setup field containing the phrase turned a completed
    /// write into a reported failure, unconditionally, because these verdicts
    /// run `failureWins: true`.
    ///
    /// Every refusal line on these paths is printed at **column 0** and every
    /// one of them opens with `Cannot `:
    /// - `format_managed_message` → `Cannot {action}: this Hermes
    ///   installation is managed by {system}.` (`:445-450`, printed by
    ///   `managed_error` at `:453-455`) — the `is_managed()` arm of
    ///   `set_config_value` (`:3450`), `unset_config_value` (`:3549`) and
    ///   `save_config` (`:2316`), i.e. the door under `plugins
    ///   enable/disable/update`, `skills trust` and `memory off` too.
    /// - `_env_write_blocked`'s managed-scope arm → `Cannot {action} {key}:
    ///   it is managed by your administrator (…)` (`:2560-2565`).
    /// - `_exit_if_key_managed` → `Cannot {action} '{key}': it is managed by
    ///   your administrator (…)` (`:3363-3371`).
    ///
    /// So the anchor is the verb-agnostic `Cannot `, which also subsumes the
    /// per-verb `Cannot set` / `Cannot unset` / `Cannot save configuration`
    /// spellings the sets used to carry separately.
    public static let managedRefusalAnchored = ["Cannot "]

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
    ///    config.yaml write lands (`_write_user_config`, `:3508`),
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
    /// ``managedRefusalAnchored``. `Cannot ` is the anchor for arms 1, 4, 5
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
    /// P39: `managedRefusal` is appended, and the verdict runs `failureWins`.
    /// `Cannot unset` already quotes the `unset_config_value` managed arm, but
    /// the `.env` branch reaches `_env_write_blocked` through
    /// `remove_env_value` (`:2552-2566`) and `unset_config_value` prints
    /// `✓ Unset …` (`:3583`) after it regardless — a success line and a
    /// refusal line in the same run, which only `failureWins` resolves the
    /// right way.
    ///
    /// **Consumed ANCHORED** (round-4 review): `Cannot ` covers both
    /// `Cannot unset …` spellings and `_env_write_blocked`'s
    /// `Cannot remove <KEY>: …` (`:2610-2612` → `:2560-2565`);
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
/// `hermes_cli/config.py:3508` @ v2026.9.7), then mirrors every `terminal.*`
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
///   where the `.env` write was the ONLY write and it was refused ⇒ a plain
///   failure, judged unchanged.
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
