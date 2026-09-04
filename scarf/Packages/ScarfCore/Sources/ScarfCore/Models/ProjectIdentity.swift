import CryptoKit
import Foundation

/// The stable-id rules shared by every path that has to name a project
/// before its canonical `.scarf/project.json` exists.
///
/// **Why a derived id rather than a fresh mint.** `ProjectStore.derive(from:)`
/// is a pure read — it must not write (persisting there would resurrect
/// just-deleted projects past `save`'s `projectRootMissing` guard, and would
/// put file writes on the render-only chat-start path). But it used to fall
/// back to `UUID()`, so two callers deriving the same unpersisted project —
/// `list()`, `ProjectAgentContextService.refresh`, the cockpit load — each saw
/// a *different* id for it. Anything keyed on `project.id` in that window
/// (`[proj:<uuid>]` cron tags, mini-app grants, fleet grouping) was keyed on
/// noise.
///
/// A **deterministic** id fixes that with no writes at all: every caller,
/// process and launch derives the same value, and the first path that *does*
/// persist (scaffolder, installer, `derive()`, the cockpit) simply freezes the
/// id the readers were already using. It also makes the id recoverable — a
/// registry row that loses its `uuid` (a bad agent write, a salvaged decode)
/// re-derives the id it had instead of detaching from its own record.
public enum ProjectIdentity {
    /// **FROZEN FOREVER.** The namespace constant, the normalization rules in
    /// `normalize`, and the digest construction below are a wire format, not
    /// an implementation detail: an id derived by one Scarf version is
    /// persisted by another (the cockpit / `derive()` freeze whatever the
    /// readers saw), and lands in `[proj:<uuid>]` cron tags, mini-app grants
    /// and fleet records. Changing ANY of them silently re-identifies every
    /// project whose id was derived rather than minted — a repeat of the
    /// detachment bug this fixes, at scale. A future change needs a migration,
    /// not an edit.
    private static let namespace = UUID(uuidString: "8B0B1E9A-0F1B-4C63-9C2E-2D8E7A0F6C41")!

    /// The project's stable id, derived from its root path.
    ///
    /// A UUIDv8 (RFC 9562 custom form) over SHA-256 of the namespace plus the
    /// normalized absolute path — the one identifying fact a project has
    /// before anything about it is written down.
    ///
    /// Consequences, all deliberate:
    ///
    /// - Moving a project directory *before* its id is ever persisted
    ///   re-derives a different id. Afterwards the id travels in
    ///   `project.json` and the registry row, so a move keeps it.
    /// - Two different hosts NEVER derive the same id, because `hostKey`
    ///   salts the digest. Without that salt they routinely would: every SSH
    ///   host defaults to the same unexpanded `~/projects` root
    ///   (`ServerContext.defaultProjectsRoot`), so same-named projects on two
    ///   hosts have byte-identical registry paths. Once the eager `derive()`
    ///   migration persisted such an id, `FleetService` would accept it as
    ///   asserted and group two unrelated projects — letting a fleet apply
    ///   write presets, tenants and CRON JOBS to the wrong host. Genuine
    ///   cross-host grouping is unaffected: it comes from the record
    ///   travelling in `project.json`, never from this derivation.
    /// - A path REUSED over time on one host (delete the project, register a
    ///   different one at the same path) derives the id the old one had, so
    ///   the new project adopts the old one's orphaned `[proj:<uuid>]` cron
    ///   jobs and any surviving mini-app grants. Accepted: it needs a project
    ///   that never persisted an id — the scaffolder and the installer both
    ///   mint a random one at creation — so it is reachable only for a
    ///   hand-added registry row at a recycled path. The bug it replaces
    ///   (every project's id changing between two reads) fired constantly,
    ///   for everyone.
    ///
    /// An id that was MINTED (random, asserted by the scaffolder/installer or
    /// frozen into `project.json`) always wins: `derive(from:)` only falls
    /// back here when the registry row has no `uuid`, and every reader
    /// prefers the canonical record over a derive.
    public static func deterministicID(forProjectPath path: String, hostKey: String = "") -> UUID {
        var hasher = SHA256()
        hasher.update(data: bytes(of: namespace))
        hasher.update(data: Data(hostKey.utf8))
        hasher.update(data: [0x00])  // unambiguous separator
        hasher.update(data: Data(normalize(path).utf8))
        var b = Array(hasher.finalize().prefix(16))
        b[6] = (b[6] & 0x0F) | 0x80  // version 8
        b[8] = (b[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        ))
    }

    /// The host half of the seed: empty for the user's own Mac, and the
    /// stable SSH coordinates for a remote. Deliberately NOT `context.id`,
    /// which is a per-registration random UUID — two Macs managing the same
    /// host would then disagree, and re-adding a server would re-identify its
    /// unpersisted projects.
    ///
    /// **FROZEN CONTRACT — canonical form `<user>@<host>:<port>`.** Same
    /// standing as the namespace and the path normalization: a key change
    /// re-identifies every project whose id was derived rather than minted.
    /// The canonicalization below is the LAST word on it, settled before
    /// release precisely because it cannot be settled after one.
    ///
    /// The governing asymmetry, which decides every rule below: **a
    /// COLLISION is catastrophic and a DIVERGENCE is cheap.** Two hosts
    /// seeded identically derive one id for two unrelated projects —
    /// `FleetService` then groups them and a fleet apply writes presets,
    /// tenants and cron jobs to the wrong machine. Two spellings of one host
    /// seeded differently merely cost a second derived id: visible to the
    /// doctor, harmless, and moot the moment an id is persisted, since a
    /// minted or recorded id always beats a derived one. So this normalizes
    /// ONLY what cannot possibly denote a different machine.
    ///
    /// - **host and user are trimmed** of surrounding whitespace. That is a
    ///   text-field artefact, never part of an identity.
    /// - **port omitted means 22**, SSH's own default, so `host` and
    ///   `host:22` are genuinely one host.
    /// - **NOTHING is case-folded — not the user, not the host.** Unix
    ///   accounts are case-sensitive. And `SSHConfig.host` is not
    ///   necessarily a DNS name: it is just as often an `~/.ssh/config`
    ///   ALIAS, whose `Host` patterns OpenSSH matches case-sensitively, so
    ///   `Prod` and `prod` may legally be two different machines. Lowercase
    ///   folding — the obvious "hostnames are case-insensitive" move —
    ///   would trade the cheap failure for the catastrophic one on exactly
    ///   the input we cannot tell apart. Same reasoning retires trailing-dot
    ///   stripping (`example.com.`): a valid FQDN spelling of one host, but
    ///   also a legal, distinct alias pattern.
    /// - **user omitted stays empty** (`@host:22`). It is NOT resolved
    ///   against `~/.ssh/config` or the local username: resolving means I/O
    ///   in a pure function, and the answer would differ per Mac.
    ///
    /// KNOWN RESIDUALS, accepted, all of them the cheap failure: an alias
    /// and the hostname it resolves to are different keys; so are two
    /// case-spellings of one host, and a host registered once with an
    /// explicit user and once without. Each costs one extra derived id.
    public static func hostKey(for context: ServerContext) -> String {
        switch context.kind {
        case .local:
            return ""
        case .ssh(let config):
            let user = config.user?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let host = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(user)@\(host):\(config.port ?? 22)"
        }
    }

    /// Collapses `//`, `.` and `..` textually, and trims trailing separators.
    /// Purely lexical on purpose — `URL.standardizedFileURL` would resolve a
    /// remote `~/projects` against the local process's CWD. Deliberately NOT
    /// done, and part of the frozen contract:
    /// - **No symlink/`..` resolution** — deriving must stay pure. Resolving
    ///   means transport I/O, a different answer on a host we cannot stat,
    ///   and an id that changes when a symlink is repointed.
    /// - **No case folding** — the registry stores one spelling per project,
    ///   so a second spelling of a case-insensitive path is a different
    ///   registry row's problem, not this function's. Folding would also make
    ///   ids differ between the case-sensitive and case-insensitive volumes
    ///   Scarf talks to.
    /// The lexical normalization `deterministicID` seeds on, exposed so
    /// callers that compare paths for *identity* (the doctor's duplicate-path
    /// and orphan-scan set arithmetic) agree with the id derivation instead of
    /// re-implementing the rules. Same frozen contract as `deterministicID`.
    public static func normalizedPath(_ path: String) -> String { normalize(path) }

    private static func normalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var segments: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                // Only pop a segment we can actually pop: a leading `..` in a
                // relative path (a remote `~`-rooted one) has to survive.
                if let last = segments.last, last != ".." {
                    segments.removeLast()
                } else if !isAbsolute {
                    segments.append("..")
                }
            default:
                segments.append(String(segment))
            }
        }
        let joined = segments.joined(separator: "/")
        return isAbsolute ? "/" + joined : joined
    }

    private static func bytes(of uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }
}
