import Foundation

/// Pure resolution of a *selected* Hermes profile to the effective
/// `HERMES_HOME` directory, for ScarfGo's per-connection profile scoping
/// (issue #120, "Design B").
///
/// Unlike `HermesProfileResolver` — which reads the LOCAL
/// `~/.hermes/active_profile` for the Mac app and performs filesystem I/O
/// — this type does **no** I/O. It maps a `(base home, selected profile
/// name)` pair to a path string, so it works for remote homes reached over
/// SSH (where there is no local `active_profile` to read) and is trivially
/// testable on any platform.
///
/// **Design B.** ScarfGo points its own reads/writes/CLI at a chosen
/// profile WITHOUT mutating the host's `active_profile`:
/// - File layer: `resolveHome` becomes the `remoteHome` override, so every
///   `HermesPathSet` path (state.db, memories, cron, sessions, …) follows.
/// - Process layer: the (normalized) name is passed to `hermes -p <name>`.
///
/// Hermes treats a missing/empty/`"default"` selection as the root home,
/// and lays named profiles out at `<root>/profiles/<name>` for both
/// standard (`~/.hermes/profiles/x`) and Docker (`/opt/data/profiles/x`)
/// roots. See the memory note "Hermes profile / HERMES_HOME resolution
/// (source-verified v0.16)".
public enum HermesProfileScope {

    /// The sentinel name for the default (root) profile.
    public static let defaultProfileName = "default"

    /// Hermes's own profile-id validation, mirrored from
    /// `hermes_cli/profiles.py` (`^[a-z0-9][a-z0-9_-]{0,63}$`). Mirrored
    /// here so we never build a filesystem path or a `-p` argument from a
    /// malformed name — the regex rejects `/`, `.`, whitespace, and shell
    /// metacharacters, which is also our path-injection guard.
    private static let nameRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]{0,63}$")
    }()

    /// Whether `name` is a syntactically valid Hermes profile id.
    ///
    /// **Two anchors, deliberately.** ICU's `$` matches *before a trailing
    /// line terminator*, so the plain `^…$` pattern accepted `"work\n"` —
    /// and every caller that validated first and normalized later then wrote
    /// into the `work` profile while believing it had rejected the input.
    /// The full-string match below is the `\A…\z` semantics Python's
    /// `re.fullmatch` gives Hermes.
    ///
    /// The second condition is the belt to that suspenders: a name is only
    /// valid if it is byte-identical to what ``normalize`` would return for
    /// it. That closes the whole class of "validated one string, used a
    /// different one" bugs — leading/trailing whitespace included — without
    /// depending on any one regex flavor's edge cases.
    public static func isValidName(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = nameRegex.firstMatch(in: name, range: range),
              match.range == range else { return false }
        // `normalize` maps "default" to nil (it IS the root home, not a named
        // profile), so exclude it here rather than call it a malformed name.
        guard name != defaultProfileName else { return true }
        return normalizedCandidate(name) == name
    }

    /// The trim-only half of ``normalize``, split out so ``isValidName`` can
    /// compare against it without recursing back through validation.
    private static func normalizedCandidate(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalize a raw selection to either a valid named profile or `nil`
    /// (meaning "default / root home"). Whitespace is trimmed; empty,
    /// `"default"`, and invalid names all normalize to `nil` — the
    /// fail-safe that keeps ScarfGo on the root home rather than a bogus
    /// path or argument.
    public static func normalize(_ selection: String?) -> String? {
        guard let raw = selection?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw != defaultProfileName,
              isValidName(raw)
        else { return nil }
        return raw
    }

    /// Effective Hermes home for a selected profile.
    ///
    /// - Parameters:
    ///   - baseHome: the ROOT hermes home for the host — the value ScarfGo
    ///     uses with no profile selected (e.g. `"~/.hermes"` unexpanded,
    ///     which the remote shell resolves, or a custom `"/opt/data"`).
    ///     Trailing slashes are trimmed.
    ///   - profile: the selected profile name. `nil`/empty/`"default"`/
    ///     invalid → returns `baseHome` unchanged (default profile).
    /// - Returns: `baseHome` for the default profile, else
    ///   `"<baseHome>/profiles/<name>"`.
    public static func resolveHome(baseHome: String, profile: String?) -> String {
        let base = trimmedBase(baseHome)
        guard let name = normalize(profile) else { return base }
        // `trimmedBase` strips trailing slashes except a lone "/", so guard
        // against a double slash for the degenerate `baseHome == "/"` case.
        let separator = base.hasSuffix("/") ? "" : "/"
        return base + separator + "profiles/" + name
    }

    /// Whether `home` is a named-profile home (`<root>/profiles/<name>`)
    /// rather than a root/default home. Mirrors Hermes' own check
    /// (`hermes_constants.get_default_hermes_root`): the immediate parent
    /// directory is named `profiles`. Used to decide whether a hermes
    /// invocation needs an explicit `HERMES_HOME` scope.
    public static func isProfileHome(_ home: String) -> Bool {
        let comps = trimmedBase(home).split(separator: "/", omittingEmptySubsequences: true)
        guard comps.count >= 2 else { return false }
        return comps[comps.count - 2] == "profiles"
    }

    /// The root (default-profile) home for any home: strips a trailing
    /// `/profiles/<name>` when present, else returns the home unchanged.
    /// Mirrors `hermes_constants.get_default_hermes_root`. Used for
    /// root-only concepts like the `active_profile` file, which always
    /// lives at the root even when a named profile is selected.
    public static func rootHome(forHome home: String) -> String {
        let trimmed = trimmedBase(home)
        guard isProfileHome(trimmed),
              let nameSlash = trimmed.lastIndex(of: "/") else { return trimmed }
        let withoutName = trimmed[..<nameSlash]                 // "<root>/profiles"
        guard let profilesSlash = withoutName.lastIndex(of: "/") else { return trimmed }
        let root = String(trimmed[..<profilesSlash])            // "<root>"
        return root.isEmpty ? "/" : root
    }

    /// The named profile encoded in `home`, or `nil` for a root/default
    /// home. The inverse of `resolveHome`: a `<root>/profiles/<name>` home
    /// yields `"<name>"` (re-validated through `normalize`, so a malformed
    /// trailing component fails safe to `nil`); any root home yields `nil`.
    /// Mirrors `isProfileHome` / `rootHome`.
    ///
    /// Use this to derive a per-profile discriminator from an already-scoped
    /// `HermesPathSet.home` — e.g. the skills-snapshot baseline key, which
    /// must distinguish each profile's `HERMES_HOME/skills` set so switching
    /// profiles doesn't diff one profile's skills against another's baseline.
    public static func profileName(forHome home: String) -> String? {
        let trimmed = trimmedBase(home)
        guard isProfileHome(trimmed),
              let nameSlash = trimmed.lastIndex(of: "/") else { return nil }
        return normalize(String(trimmed[trimmed.index(after: nameSlash)...]))
    }

    /// A shell `HERMES_HOME=... ` assignment (note the trailing space) that
    /// scopes a `hermes` invocation to a named profile, or `""` for a
    /// default/root home — leaving legacy `active_profile` resolution
    /// untouched (and avoiding any behavior change for users who don't use
    /// profiles). This is Hermes' own per-invocation home mechanism; for a
    /// `<root>/profiles/<name>` value the CLI trusts it and never consults
    /// `active_profile` (verified against Hermes 0.16, hermes_cli/main.py).
    ///
    /// The home is quoted for the remote shell exactly like
    /// `RemoteSQLiteBackend.quoteForRemoteShell`: a leading `~` becomes a
    /// `$HOME` prefix so the shell expands it, with the remainder escaped so
    /// `$HOME` still expands but nothing else does; any other (absolute)
    /// path is single-quoted and fully inert. Profile names are already
    /// regex-validated, so the only free-form interpolated value is the
    /// user's own configured home — but we escape it regardless.
    public static func hermesHomeShellAssignment(forHome home: String) -> String {
        guard isProfileHome(home) else { return "" }
        return "HERMES_HOME=\(shellQuotePath(home)) "
    }

    /// Quote a remote path for safe interpolation into a shell command.
    /// A leading `~`/`~/` becomes a live `$HOME` so the shell expands it,
    /// with the remainder escaped so `$HOME` still expands but injected
    /// `$()`/backtick/quote are inert; any other (absolute) path is
    /// single-quoted and fully inert. Single source of truth for both the
    /// `HERMES_HOME=` assignment above and the iOS `cd <project>` prefix in
    /// `ACPClient+iOS` — the iOS counterpart to Mac's `SSHTransport.remotePathArg`.
    public static func shellQuotePath(_ path: String) -> String {
        if path == "~" {
            return "\"$HOME\""
        }
        if path.hasPrefix("~/") {
            // Escape backslash FIRST, then the rest, so `$HOME` still
            // expands but injected `$()`/backtick/quote are inert.
            let rest = String(path.dropFirst(2))
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "`", with: "\\`")
            return "\"$HOME/\(rest)\""
        }
        // Absolute (or other) path → single-quote; no expansion at all.
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Trim trailing slashes from a base home, preserving a lone `"/"`.
    private static func trimmedBase(_ s: String) -> String {
        var base = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.count > 1 && base.hasSuffix("/") {
            base.removeLast()
        }
        return base
    }
}
