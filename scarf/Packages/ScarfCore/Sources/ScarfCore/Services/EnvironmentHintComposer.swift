import Foundation

/// Composes the `HERMES_ENVIRONMENT_HINT` value Scarf hands to the
/// `hermes acp` process it launches (gh#142), without clobbering the
/// user's own hint.
///
/// **Why compose instead of set.** Hermes resolves the hint as
/// `(os.getenv("HERMES_ENVIRONMENT_HINT") or "").strip() or
/// config agent.environment_hint` (`agent/prompt_builder.py:1054-1058`,
/// v0.21.4). A non-empty env var therefore REPLACES the config hint. Setting
/// the var to Scarf's text alone would silently drop whatever the user put
/// in their own env or `config.yaml`. So Scarf's value is: the existing env
/// hint (when non-blank) else the config hint (when non-blank), then a
/// blank line, then Scarf's hint.
///
/// "Blank" matches Hermes: whitespace-only counts as unset (`.strip()`).
///
/// Two forms:
/// - ``compose(existing:configHint:scarfHint:)`` — pure, for a LOCAL spawn
///   where Scarf can read its own environment.
/// - ``remoteShellFragment(configHint:scarfHint:)`` — a POSIX-sh fragment for
///   a REMOTE spawn, evaluated by the remote shell AFTER its login profile
///   has run, so a hint the remote user exports there is the one preserved.
///
/// The config hint is a parameter: reading `agent.environment_hint` out of
/// the (local or remote) `config.yaml` is the caller's job.
public enum EnvironmentHintComposer {

    /// The environment variable Hermes reads.
    public static let variableName = "HERMES_ENVIRONMENT_HINT"

    /// Whether `value` counts as set, the way Hermes' `.strip()` decides.
    static func isBlank(_ value: String?) -> Bool {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The local composition. Returns `scarfHint` alone when neither the
    /// existing env value nor the config hint is set; otherwise
    /// `<base>\n\n<scarfHint>`. The base is kept as written (Hermes strips
    /// the final value itself).
    public static func compose(existing: String?, configHint: String?, scarfHint: String) -> String {
        let base: String?
        if !isBlank(existing) {
            base = existing
        } else if !isBlank(configHint) {
            base = configHint
        } else {
            base = nil
        }
        guard let base else { return scarfHint }
        return base + "\n\n" + scarfHint
    }

    /// The environment for a local spawn: `environment` with the hint
    /// variable replaced by ``compose(existing:configHint:scarfHint:)``
    /// using `environment`'s own value as the existing hint. A nil/blank
    /// `scarfHint` returns `environment` unchanged.
    public static func applying(
        scarfHint: String?, configHint: String?, to environment: [String: String]
    ) -> [String: String] {
        guard let scarfHint, !isBlank(scarfHint) else { return environment }
        var env = environment
        env[variableName] = compose(
            existing: environment[variableName], configHint: configHint, scarfHint: scarfHint)
        return env
    }

    /// A POSIX-sh fragment (ending in `; `) that sets and exports
    /// `HERMES_ENVIRONMENT_HINT` on a remote host, meant to be placed in
    /// front of the command that execs `hermes`. Returns `""` for a
    /// nil/blank `scarfHint`, so callers stay byte-identical to before.
    ///
    /// At run time: if the remote shell's current value is blank it falls
    /// back to `configHint`; if the result is still blank the value is
    /// Scarf's hint alone, else `<base>\n\n<scarfHint>`. Both literals are
    /// single-quoted (fully inert: `$`, backticks, backslashes, double
    /// quotes and newlines survive verbatim; an embedded `'` uses the
    /// `'\''` close-escape-reopen). The existing value is only ever read
    /// inside double quotes, never re-evaluated.
    ///
    /// Blankness uses `[[:space:]]`, the shell's view of whitespace; a value
    /// made only of non-ASCII Unicode spaces counts as set here but blank
    /// to Hermes, which then still reads `<spaces>\n\n<scarf>` stripped to
    /// Scarf's hint. Harmless either way.
    public static func remoteShellFragment(configHint: String?, scarfHint: String?) -> String {
        guard let scarfHint, !isBlank(scarfHint) else { return "" }
        let v = variableName
        let config = HermesProfileScope.shellSingleQuote(isBlank(configHint) ? "" : configHint!)
        let scarf = HermesProfileScope.shellSingleQuote(scarfHint)
        let joined = HermesProfileScope.shellSingleQuote("\n\n" + scarfHint)
        return "case \"${\(v):-}\" in *[![:space:]]*) ;; *) \(v)=\(config) ;; esac; "
            + "case \"$\(v)\" in *[![:space:]]*) \(v)=\"$\(v)\"\(joined) ;; *) \(v)=\(scarf) ;; esac; "
            + "export \(v); "
    }
}

/// What a caller asks a transport to inject into a spawned `hermes`
/// process: Scarf's own hint plus the `agent.environment_hint` the caller
/// read from that host's `config.yaml` (nil when unknown/unset). See
/// ``EnvironmentHintComposer``.
public struct EnvironmentHintRequest: Sendable, Equatable {
    public var scarfHint: String
    public var configHint: String?

    public init(scarfHint: String, configHint: String? = nil) {
        self.scarfHint = scarfHint
        self.configHint = configHint
    }
}
