import Foundation
import os

/// Resolves Hermes's active profile (v0.11+) for local installations.
///
/// Hermes v0.11 introduced `hermes profile`: each profile is an independent
/// `HERMES_HOME` directory. The "default" profile is `~/.hermes` itself;
/// named profiles live at `~/.hermes/profiles/<name>/` and have their own
/// `state.db`, `sessions/`, `config.yaml`, `.env`, `memories/`, `cron/`,
/// `gateway_state.json`, etc.
///
/// The active profile is recorded in `~/.hermes/active_profile` (a single
/// line text file containing the profile name, or absent / empty when the
/// default profile is active). The Hermes CLI consults this file to set
/// `HERMES_HOME` for each invocation.
///
/// Pre-v0.11 Scarf hardcoded `~/.hermes` and ignored `active_profile`,
/// which meant `hermes profile use <name>` left Scarf reading the wrong
/// state.db (issue #50). This resolver is the single seam: it reads
/// `active_profile` and returns the effective home directory; everything
/// else in `HermesPathSet` derives from `home`, so once the seam is
/// correct every read path follows automatically.
///
/// **Caching.** The resolver is called from `HermesPathSet.defaultLocalHome`,
/// which is in turn called whenever a `HermesPathSet` is constructed via
/// the default helper. To avoid filesystem hits on hot paths we cache the
/// resolved name for `cacheTTL` seconds (default 5s). That's tight enough
/// that `hermes profile use other` followed by a Scarf operation picks up
/// the change within seconds, and loose enough that no realistic UI loop
/// causes more than a handful of file reads per minute.
public enum HermesProfileResolver {

    /// Cache lifetime for resolved profile state. Tunable for tests.
    public static var cacheTTL: TimeInterval = 5

    private static let lock = OSAllocatedUnfairLock(initialState: CacheState())
    private static let logger = Logger(subsystem: "com.scarf.app", category: "HermesProfileResolver")

    private static let profileNameRegex: NSRegularExpression = {
        // Mirrors Hermes's own validation in hermes_cli/profiles.py.
        try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]{0,63}$")
    }()

    private struct CacheState {
        var resolvedName: String = "default"
        var resolvedHome: String = HermesProfileResolver.defaultRootHome()
        var resolvedAt: Date = .distantPast
    }

    /// Effective Hermes home directory for the active profile.
    /// Returns the default `~/.hermes` when no profile is active OR when
    /// the configured profile is invalid (logged) — so the worst-case
    /// failure mode is "Scarf shows what it always showed before."
    ///
    /// **Test override.** Setting `SCARF_HERMES_HOME` in the environment
    /// pins this resolver to the supplied absolute path and bypasses both
    /// the cache and the `active_profile` lookup. Used by the E2E test
    /// harness (`TemplateE2ETests`, `TemplateInstallUITests`) to drive
    /// Scarf against an isolated tmpdir Hermes home so the user's real
    /// `~/.hermes` is never touched. Read on every call (cheap; a single
    /// `ProcessInfo` lookup) so tests can flip it across test methods
    /// without stale-cache surprises.
    public static func resolveLocalHome() -> String {
        if let override = scarfHermesHomeOverride() {
            return override
        }
        return refreshIfNeeded().home
    }

    /// Name of the active profile — `"default"` or the profile id.
    /// Surfaced in UI chrome so users can see which profile Scarf is
    /// reading from (issue #50 follow-up: prevents the next variant
    /// of "where's my data — wrong profile" by making it visible).
    public static func activeProfileName() -> String {
        if scarfHermesHomeOverride() != nil {
            return "test-override"
        }
        return refreshIfNeeded().name
    }

    /// Sentinel filename that the override path MUST contain for the
    /// override to be honored. Without it, production code refuses to
    /// pivot off the user's real `~/.hermes` even if the env var is
    /// set. This is the "even if a test leaks the env var, even if
    /// some non-test process inherits it, the user's data is safe"
    /// belt-and-braces guard. Tests create this marker before
    /// `setenv("SCARF_HERMES_HOME", ...)`.
    public static let testHomeMarkerFilename = ".scarf-test-home-marker"

    /// Read `SCARF_HERMES_HOME` from the environment. Returns `nil` when
    /// unset or empty so production callers fall through to the profile
    /// resolver. The override must:
    ///   1. Be an absolute path — relative paths are rejected (they'd
    ///      land relative to the cwd of whatever process happened to
    ///      invoke the resolver, which is not what tests want).
    ///   2. Contain the sentinel marker file
    ///      `<path>/<testHomeMarkerFilename>`. Without the marker we
    ///      treat the env var as untrusted and ignore it. This protects
    ///      the user's real `~/.hermes/` from any code path that
    ///      accidentally exports `SCARF_HERMES_HOME` to the wrong value
    ///      (e.g. a test crashed mid-teardown, an env var inherited
    ///      from a parent shell, a misconfigured launchctl plist).
    /// Both checks are cheap — `FileManager.fileExists` against a
    /// known path is microseconds. The override is hot but not
    /// hot-hot, so an extra stat per call is negligible.
    private static func scarfHermesHomeOverride() -> String? {
        guard let raw = ProcessInfo.processInfo.environment["SCARF_HERMES_HOME"] else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("/") else {
            logger.warning("SCARF_HERMES_HOME=\(trimmed, privacy: .public) is not absolute; ignoring.")
            return nil
        }
        let markerPath = trimmed + "/" + testHomeMarkerFilename
        guard FileManager.default.fileExists(atPath: markerPath) else {
            logger.warning("SCARF_HERMES_HOME=\(trimmed, privacy: .public) lacks sentinel marker (\(testHomeMarkerFilename, privacy: .public)); ignoring to protect real ~/.hermes.")
            return nil
        }
        return trimmed
    }

    /// Force a re-read on the next call, regardless of TTL. Test helper.
    public static func invalidateCache() {
        lock.withLock { $0.resolvedAt = .distantPast }
    }

    // MARK: - Internals

    private static func refreshIfNeeded() -> (name: String, home: String) {
        let now = Date()
        let snapshot = lock.withLock { state -> CacheState? in
            if now.timeIntervalSince(state.resolvedAt) < cacheTTL {
                return state
            }
            return nil
        }
        if let snapshot {
            return (snapshot.resolvedName, snapshot.resolvedHome)
        }

        let (name, home) = readActiveProfileFromDisk()
        lock.withLock { state in
            state.resolvedName = name
            state.resolvedHome = home
            state.resolvedAt = now
        }
        return (name, home)
    }

    private static func readActiveProfileFromDisk() -> (name: String, home: String) {
        let defaultHome = defaultRootHome()
        let activeFile = defaultHome + "/active_profile"

        // Absent file → default profile. Common case for users who
        // haven't run `hermes profile use ...`. We still log at
        // `.info` (key=value, not warning) so support requests can
        // pull `log show … | grep ProfileResolver` and confirm the
        // resolver IS running and IS resolving to the default —
        // distinguishing "feature didn't fire" from "feature fired
        // and chose default" (issue #70).
        guard FileManager.default.fileExists(atPath: activeFile) else {
            logger.info("Resolved active Hermes profile: name=default, home=\(defaultHome, privacy: .public), source=default-no-file")
            return ("default", defaultHome)
        }

        guard let raw = try? String(contentsOfFile: activeFile, encoding: .utf8) else {
            logger.warning("Found active_profile but could not read it; falling back to default. home=\(defaultHome, privacy: .public)")
            return ("default", defaultHome)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty file or explicit "default" → default profile.
        if trimmed.isEmpty || trimmed == "default" {
            logger.info("Resolved active Hermes profile: name=default, home=\(defaultHome, privacy: .public), source=file-default")
            return ("default", defaultHome)
        }

        // Validate format. Hermes itself rejects malformed names, so this
        // would only fire if the file is corrupted or hand-edited.
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard profileNameRegex.firstMatch(in: trimmed, range: range) != nil else {
            logger.warning("active_profile contains invalid name \(trimmed, privacy: .public); falling back to default profile.")
            return ("default", defaultHome)
        }

        let profileHome = defaultHome + "/profiles/" + trimmed
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: profileHome, isDirectory: &isDir), isDir.boolValue else {
            logger.warning("active_profile points to \(trimmed, privacy: .public) but \(profileHome, privacy: .public) does not exist; falling back to default profile.")
            return ("default", defaultHome)
        }

        logger.info("Resolved active Hermes profile: name=\(trimmed, privacy: .public), home=\(profileHome, privacy: .public), source=file")
        return (trimmed, profileHome)
    }

    /// Pre-profile default hermes home (`~/.hermes`). The reference point
    /// for both the active_profile lookup and the fallback case.
    fileprivate static func defaultRootHome() -> String {
        let user = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return user + "/.hermes"
    }
}
