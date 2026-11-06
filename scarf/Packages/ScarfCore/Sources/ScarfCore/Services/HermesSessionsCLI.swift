import Foundation

/// Shared failure detection for `hermes sessions …`.
///
/// `_not_found` prints `No session '<id>'. Run: hermes sessions list to find
/// the id.` (`hermes_cli/sessions_cmd.py:49-51` @ v0.22.5, `:73-75` @
/// v0.22.6 and v0.23.0). Scarf's older `not found.` marker matched the
/// pre-v0.22 sentence (`Session '<id>' not found.`) and never this one, so the
/// prefix below is matched on every host — a correctness fix, not a gated
/// surface (an old host that prints the old sentence still matches
/// `not found.`).
public enum HermesSessionsCLI {

    /// Line prefix of `_not_found`'s refusal. The quote keeps
    /// `No session database at …` and `No sessions found.` out.
    public static let noSessionPrefix = "No session '"

    /// `No session matches '<target>'.` — the `--session` resolver refusal of
    /// `refresh-prompts` and `discard` (`sessions_cmd.py:1321`, `:1207` @
    /// v0.23.0).
    public static let noSessionMatchesPrefix = "No session matches "

    /// True when any line of `output` is one of Hermes's "no such session"
    /// refusals.
    public static func isNoSession(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix(noSessionPrefix) || line.hasPrefix(noSessionMatchesPrefix)
        }
    }

    /// Whether a `hermes sessions …` run failed, judged without a success
    /// marker: a "no such session" line always means failure; a non-zero
    /// exit means failure only on hosts where `sessions` failures exit
    /// non-zero (`hasSessionsNonZeroExit`, `_confirm_or_exit_code` and
    /// `_not_found` → 1 at `sessions_cmd.py:54-75` @ v0.22.6/v0.23.0). On an
    /// older host the exit code is left to the caller's existing handling,
    /// so its verdict is unchanged (charter C1).
    public static func isFailure(output: String, exitCode: Int32, nonZeroExitIsFailure: Bool) -> Bool {
        if isNoSession(output) { return true }
        return nonZeroExitIsFailure && exitCode != 0
    }
}

/// `hermes sessions refresh-prompts [--session ID] --json`
/// (`_add_refresh_prompts`, `hermes_cli/subcommands/sessions.py:33-43` @
/// v0.23.0; handler `_cmd_refresh_prompts`, `sessions_cmd.py:1309-1338`).
/// Gated by the caller on `HermesCapabilities.hasSessionsRefreshPrompts`.
public enum HermesSessionsRefreshPrompts {

    /// `--session` takes a value (`metavar="SESSION_ID"`), so it is passed
    /// as one `--session=<id>` token: an id beginning with a dash can never
    /// be read as another option.
    public static func argv(sessionId: String? = nil) -> [String] {
        var args = ["sessions", "refresh-prompts"]
        if let sessionId, !sessionId.isEmpty { args.append("--session=\(sessionId)") }
        args.append("--json")
        return args
    }

    public struct Result: Sendable, Equatable {
        public let succeeded: Bool
        /// `sessions` from the JSON payload — how many sessions have a
        /// stored prompt that will be rebuilt.
        public let sessionCount: Int?
        /// The refused/unrecognized output's last line, on failure.
        public let detail: String?
    }

    /// Success is ONLY an exit-0 run whose stdout carries the handler's JSON
    /// object `{"epoch": …, "session_id": …, "sessions": N}`
    /// (`sessions_cmd.py:1331` @ v0.23.0, `:1331` @ v0.22.6). Anything else —
    /// a `No session matches` refusal (exit 1, `:1321-1322`), the store-open
    /// failure (exit 1, `:1432-1435`), or an exit-0 run with no payload — is a
    /// failure (charter C5).
    public static func judge(stdout: String, stderr: String, exitCode: Int32) -> Result {
        let combined = stdout + "\n" + stderr
        let lastLine = HermesCLIVerdict.significantLines(combined).last
        guard exitCode == 0, !HermesSessionsCLI.isNoSession(combined) else {
            return Result(succeeded: false, sessionCount: nil, detail: lastLine)
        }
        for raw in stdout.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("{"),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["epoch"] != nil,
                  let count = obj["sessions"] as? NSNumber,
                  CFGetTypeID(count) != CFBooleanGetTypeID()
            else { continue }
            return Result(succeeded: true, sessionCount: count.intValue, detail: nil)
        }
        return Result(succeeded: false, sessionCount: nil, detail: lastLine)
    }

    /// One-line banner text for a result.
    public static func message(for result: Result, sessionId: String?) -> String {
        if result.succeeded {
            let n = result.sessionCount ?? 0
            if sessionId != nil {
                return n > 0
                    ? "System prompt will rebuild on this session's next turn."
                    : "Refresh requested; this session has no stored prompt yet."
            }
            return "Requested a prompt refresh for \(n) session\(n == 1 ? "" : "s"); each rebuilds on its next turn."
        }
        return result.detail.map { "Prompt refresh failed: \($0)" } ?? "Prompt refresh failed."
    }
}

/// `hermes curator lock|unlock <skill>` (`hermes_cli/curator.py:682-684`,
/// handler `_set_lock` `:243-266` @ v0.23.0; same at v0.22.6). Gated by the
/// caller on `HermesCapabilities.hasCuratorLock`.
public enum HermesCuratorLock {

    /// `skill` is the shared plain `_SKILL` positional (`curator.py:649`),
    /// so `--` before the name is safe and keeps a dash-led name positional —
    /// the same shape as `curator pin`.
    public static func argv(skill: String, locked: Bool) -> [String] {
        ["curator", locked ? "lock" : "unlock", "--", skill]
    }

    /// Success: exit 0 and `curator: locked '<key>'.` / `curator: unlocked
    /// '<key>'.` (`:260`, `:265`). Failure: exit 1 with `curator: no skill
    /// named` (`:252`) or `curator: could not record` (`:257`). Exit 0 with
    /// neither line is never a success (C5).
    public static func judge(output: String, exitCode: Int32, locked: Bool) -> HermesCLIOutcome {
        HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: [locked ? "curator: locked '" : "curator: unlocked '"],
            failureMarkers: ["curator: no skill named", "curator: could not record"],
            successAnchored: true
        )
    }

    /// Skill names carrying `"locked": true` in `skills/.usage.json`.
    /// `set_locked` stores `bool(locked)` on the skill's record keyed by its
    /// directory name (`tools/skill_usage.py:580-585`, key chosen at
    /// `hermes_cli/curator.py:255`); `locked_skill_names` reads the same field
    /// (`skill_usage.py:600-602`). Only a literal JSON `true` counts;
    /// non-object records are dropped the way `load_usage` drops them.
    public static func parseLockedSkillNames(_ data: Data) -> Set<String> {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        var locked: Set<String> = []
        for (name, value) in obj {
            guard let record = value as? [String: Any],
                  let flag = record["locked"] as? NSNumber,
                  CFGetTypeID(flag) == CFBooleanGetTypeID(),
                  flag.boolValue
            else { continue }
            locked.insert(name)
        }
        return locked
    }
}
