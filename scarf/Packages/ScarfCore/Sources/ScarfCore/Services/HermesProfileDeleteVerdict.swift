import Foundation

// MARK: - profile delete — hermes_cli/profiles.py

/// `hermes profile delete -y`, judged by exit code AND — on a non-zero exit —
/// by the one partial-success line v0.21.4 added.
///
/// `delete_profile` (`hermes_cli/profiles.py:1681-1779` @ v2026.9.24) removes
/// the wrapper, the gateway service and the profile DIRECTORY, prints
/// `✓ Removed {dir}` and `Profile '{name}' deleted.`, and only THEN raises
/// `ProfileIdentitySettlementPending` when the durable session/routing
/// identity purge did not settle (`:1777-1779`; class at `:1663-1678`, first
/// shipped at v2026.9.21 `:1496`). The CLI's `_profile_delete` catches it as
/// a `RuntimeError` and `_die`s with `Error: {e}` at exit **1**
/// (`hermes_cli/profile_cmd.py:290-295`, `:15-17`):
///
/// `Error: Profile '{name}' was deleted, but its session/routing identity
/// settlement is still pending — run: hermes profile purge-identity {name}`
///
/// Reporting that as "delete failed" is false — the directory is gone and a
/// retry would fail at `_existing_profile_dir`. It is a completed delete with
/// a follow-up, and the retry command in Hermes's sentence is the follow-up
/// (`purge-identity` is a real verb at the floor,
/// `hermes_cli/subcommands/profile.py:94` @ v2026.9.21).
///
/// No flag: the sentence exists only from v2026.9.21, so on an older host
/// this can never match and every exit keeps its exit-code meaning.
public enum HermesProfileDeleteVerdict {
    /// The distinctive middle of the `ProfileIdentitySettlementPending`
    /// message (`profiles.py:1676-1678` @ v2026.9.24).
    static let settlementPendingMarker =
        "was deleted, but its session/routing identity settlement is still pending"

    /// Hermes's own settlement-pending sentence (the `Error: ` prefix
    /// dropped), when a non-zero `profile delete` is really a completed delete
    /// with pending identity settlement. `nil` for a zero exit and for every
    /// real failure.
    public static func settlementPendingWarning(output: String, exitCode: Int32) -> String? {
        guard exitCode != 0 else { return nil }
        guard let line = HermesCLIVerdict.significantLines(output)
            .first(where: { $0.contains(settlementPendingMarker) }) else { return nil }
        return line.hasPrefix("Error: ") ? String(line.dropFirst("Error: ".count)) : line
    }
}
