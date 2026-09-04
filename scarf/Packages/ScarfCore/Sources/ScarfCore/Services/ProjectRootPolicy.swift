import Foundation

/// May this directory be a project root at all?
///
/// **Why this exists.** Every containment check in the projects surface is
/// relative to a project root: `PathGuard.admits(_:under:)` for uninstall
/// deletions, `WidgetPathResolver` for dashboard file reads,
/// `MiniAppAssetResolver` for the mini-app scheme handler. All of them are
/// sound *given a sane root* — and vacuous given an insane one. Register
/// `/` and every absolute path on the machine is "inside the project";
/// register `$HOME` and the same is true of every document the user owns;
/// register the parent of `~/.hermes` and a dashboard widget can read
/// `.env`, `state.db` and `projects.json` through a check that says yes.
///
/// `project_register` is an MCP tool an agent calls, which makes the root a
/// piece of untrusted input rather than a thing a human picked in an open
/// panel — so the refusal belongs at registration.
///
/// **…and at every USE, not only at registration** (P8 SEC-H1). Registering
/// through `project_register` is not the only way a row gets into
/// `projects.json`: the file is agent-writable, so an agent can simply
/// append a row whose `path` is `/Users/me` and never go through the mint
/// path at all. Every containment guard downstream then anchors on that
/// root and passes. So the policy is re-derived at the moment a root is
/// about to ANCHOR a dangerous operation — uninstall plan build + execute,
/// widget file reads, mini-app asset serving — and the operation is refused
/// with a reason. Deliberately NOT by dropping the row from the sidebar: a
/// registry we can't fully trust is still the user's project list, and a
/// policy that silently disappears projects bricks legitimate users
/// (someone whose home genuinely holds a project folder, a row that predates
/// the policy) far more often than it stops an attacker who, by hypothesis,
/// can rewrite the file again next tick. Refuse the dangerous act; keep the
/// row visible; say why.
///
/// **…and physically, not just lexically** (P8 SEC-M3). A lexical compare
/// sees `~/r` and `/` as different roots even when `~/r` IS a symlink to
/// `/`. Where the filesystem is local, the candidate is therefore also
/// judged in its resolved spelling — and in the `/System/Volumes/Data`
/// firmlink and `/private` spellings, which `resolvingSymlinksInPath`
/// neither produces nor removes consistently (it STRIPS a `/private`
/// prefix rather than adding one, and leaves the firmlink prefix alone).
/// A remote root can only ever be judged lexically: there is no realpath
/// primitive on `ServerTransport`, and resolving locally would answer a
/// question about the wrong machine — so remote roots get the universal
/// rules (`/`, system directories) and nothing that depends on this Mac.
///
/// `PathGuard` keeps its own `/` special-case: defence in depth for rows
/// that predate this policy.
///
/// The rule is deliberately narrow. It refuses roots that are *absurd*, not
/// roots that are merely unusual: a project one level below home is fine, a
/// project inside a repo is fine, a project on a mounted volume is fine.
/// Only the handful of paths whose containment meaning is degenerate are
/// turned away, so this can never become the reason a legitimate project
/// won't register.
public enum ProjectRootPolicy: Sendable {

    /// Why a candidate root was refused. `nil` from `refusal(...)` means it
    /// is acceptable.
    public indirect enum Refusal: Sendable, Equatable {
        /// `/` — every absolute path is "contained" by it.
        case filesystemRoot
        /// The user's home directory itself.
        case homeDirectory(String)
        /// A top-level system directory (`/etc`, `/usr`, `/var`, `/System`…).
        case systemDirectory(String)
        /// The Hermes home (`~/.hermes`) or a directory that CONTAINS it —
        /// a root from which `.env`, `state.db` and `projects.json` are all
        /// "inside the project".
        case containsHermesHome(root: String, hermesHome: String)
        /// Not an absolute path, or empty.
        case notAbsolute
        /// The candidate is fine as written, but the path it ACTUALLY names
        /// once symlinks/firmlinks are resolved is not: `~/r` → `/`,
        /// `/System/Volumes/Data/Users/me` → the home directory. Carries the
        /// spelling that offended and the refusal it earned, so the message
        /// can say what the folder really is rather than just "no".
        case resolvesTo(spelling: String, refusal: Refusal)

        /// The underlying reason, with any `resolvesTo` wrappers peeled off.
        /// Lets a caller test "is this a home-directory refusal?" without
        /// caring which spelling produced it.
        public var underlying: Refusal {
            if case .resolvesTo(_, let inner) = self { return inner.underlying }
            return self
        }

        public var message: String {
            switch self {
            case .filesystemRoot:
                return "The filesystem root “/” can't be a project. Every folder on the machine "
                    + "would count as part of the project, which makes every safety check Scarf "
                    + "runs on project files meaningless. Register the project's own folder."
            case .homeDirectory(let path):
                return "Your home folder (\(path)) can't be a project — every document you own "
                    + "would count as a project file. Register a folder inside it instead."
            case .systemDirectory(let path):
                return "\(path) is a system directory, not a project folder."
            case let .containsHermesHome(root, hermesHome):
                return "\(root) contains Hermes's own home at \(hermesHome), so registering it "
                    + "would make Scarf's configuration, credentials and database part of the "
                    + "project. Register a folder that doesn't contain \(hermesHome)."
            case .notAbsolute:
                return "A project root must be an absolute path."
            case let .resolvesTo(spelling, refusal):
                return "That folder actually resolves to \(spelling). \(refusal.message)"
            }
        }
    }

    /// Top-level directories a project never legitimately lives at. Only the
    /// directories THEMSELVES are refused — `/usr/local/src/myproject` is
    /// fine, and a user who keeps projects under `/opt` is not our problem.
    private static let systemDirectories: Set<String> = [
        "/etc", "/usr", "/var", "/bin", "/sbin", "/dev", "/tmp",
        "/System", "/Library", "/Applications", "/Volumes", "/private",
        "/opt", "/proc", "/root", "/Users", "/home", "/net", "/cores",
    ]

    /// The refusal for `candidate`, or `nil` when it may be a project root.
    ///
    /// - Parameters:
    ///   - candidate: the proposed root, absolute. Normalized lexically
    ///     (`ProjectIdentity.normalizedPath`) so `/a/b/`, `/a/./b` and
    ///     `/a/x/../b` are one answer — the same normalization the registry
    ///     and the doctor compare with.
    ///   - hermesHome: `context.paths.home`. A root at or above it is
    ///     refused; a root INSIDE it is not our business here (test homes
    ///     legitimately nest projects under a Hermes home, and the doctor's
    ///     scan exclusion already covers the parts that matter).
    ///   - userHome: the user's home directory. Pass `nil` for a remote
    ///     context where the local `NSHomeDirectory()` would answer a
    ///     question about the wrong machine.
    ///   - resolveSymlinks: consult the LOCAL filesystem to judge the
    ///     candidate in its resolved spelling as well as its written one.
    ///     True only when the path is on this machine — for a remote root
    ///     the local filesystem describes a different computer, so pass
    ///     `false` and accept a lexical-only answer.
    public static func refusal(
        for candidate: String,
        hermesHome: String,
        userHome: String?,
        resolveSymlinks: Bool = true
    ) -> Refusal? {
        guard candidate.hasPrefix("/") else { return .notAbsolute }
        let path = ProjectIdentity.normalizedPath(candidate)
        guard path.hasPrefix("/"), path.count > 1 else { return .filesystemRoot }

        // Everything the candidate could be called. The FIRST element is the
        // literal spelling, so an ordinary refusal keeps its ordinary
        // message and only a genuinely-resolved one gets wrapped.
        let candidates = spellings(of: path, resolveSymlinks: resolveSymlinks)
        let homes: Set<String> = {
            guard let userHome, !userHome.isEmpty else { return [] }
            let home = ProjectIdentity.normalizedPath(userHome)
            guard home.hasPrefix("/"), home.count > 1 else { return [] }
            return Set(spellings(of: home, resolveSymlinks: resolveSymlinks))
        }()
        // The Hermes home matters only when it is an absolute path — a
        // remote `~/.hermes` the remote shell expands is not comparable to
        // an absolute candidate, and guessing would refuse legitimate roots.
        let hermesHomes: Set<String> = {
            let hermes = ProjectIdentity.normalizedPath(hermesHome)
            guard hermes.hasPrefix("/"), hermes.count > 1 else { return [] }
            return Set(spellings(of: hermes, resolveSymlinks: resolveSymlinks))
        }()

        for (index, spelling) in candidates.enumerated() {
            guard let refusal = lexicalRefusal(
                for: spelling, homes: homes, hermesHomes: hermesHomes
            ) else { continue }
            return index == 0 ? refusal : .resolvesTo(spelling: spelling, refusal: refusal)
        }
        return nil
    }

    /// The rule set itself, applied to ONE already-canonical spelling. No
    /// filesystem access — `refusal(...)` supplies the spellings.
    private static func lexicalRefusal(
        for path: String,
        homes: Set<String>,
        hermesHomes: Set<String>
    ) -> Refusal? {
        guard path.hasPrefix("/") else { return nil }
        guard path.count > 1 else { return .filesystemRoot }
        if homes.contains(path) { return .homeDirectory(path) }
        if systemDirectories.contains(path) { return .systemDirectory(path) }
        for hermes in hermesHomes where path == hermes || hermes.hasPrefix(path + "/") {
            return .containsHermesHome(root: path, hermesHome: hermes)
        }
        return nil
    }

    /// Every spelling that denotes `path` on this machine, literal first.
    ///
    /// Three transforms, because no single Foundation call produces them:
    /// `resolvingSymlinksInPath` follows links (and STRIPS `/private`, never
    /// adds it), `/System/Volumes/Data` is a firmlink the resolver leaves
    /// in place, and `/tmp`↔`/private/tmp` needs both directions. Order is
    /// stable and duplicates are dropped, so the literal spelling is always
    /// judged first.
    static func spellings(of path: String, resolveSymlinks: Bool) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        func add(_ p: String) {
            var value = p
            while value.count > 1, value.hasSuffix("/") { value.removeLast() }
            guard value.hasPrefix("/"), seen.insert(value).inserted else { return }
            out.append(value)
        }
        add(path)
        if resolveSymlinks { add(physicalPath(path)) }
        // Variants of everything gathered so far. One pass is enough: the
        // prefixes don't compose (`/private/System/Volumes/Data` is not a
        // real path), and a second pass would only re-derive the originals.
        let base = out
        for value in base {
            if let stripped = strippingFirmlinkPrefix(value) {
                add(stripped)
                if resolveSymlinks { add(physicalPath(stripped)) }
            } else {
                add(firmlinkPrefix + value)
            }
            if value.hasPrefix("/private/") {
                add(String(value.dropFirst("/private".count)))
            } else {
                add("/private" + value)
            }
        }
        return out
    }

    /// macOS's data-volume firmlink: `/System/Volumes/Data/Users/me` and
    /// `/Users/me` are the same directory, and nothing in Foundation
    /// rewrites one into the other.
    static let firmlinkPrefix = "/System/Volumes/Data"

    private static func strippingFirmlinkPrefix(_ path: String) -> String? {
        guard path.hasPrefix(firmlinkPrefix + "/") else { return nil }
        return String(path.dropFirst(firmlinkPrefix.count))
    }

    /// Canonical on-disk spelling, tolerant of a path that doesn't exist.
    /// `resolvingSymlinksInPath` gives up entirely when the leaf is missing
    /// (it returns the input unresolved), which would make the policy depend
    /// on whether the folder happened to be there — so resolve the deepest
    /// EXISTING ancestor and re-attach the missing tail verbatim. Same shape
    /// as `ProjectTemplateUninstaller.PathGuard.physicalPath`, which solves
    /// the identical problem for deletion containment.
    static func physicalPath(_ path: String) -> String {
        var components = path.split(separator: "/").map(String.init)
        var tail: [String] = []
        while !components.isEmpty {
            let candidate = "/" + components.joined(separator: "/")
            if (try? FileManager.default.attributesOfItem(atPath: candidate)) != nil {
                var resolved = URL(fileURLWithPath: candidate)
                    .standardizedFileURL.resolvingSymlinksInPath().path
                while resolved.count > 1, resolved.hasSuffix("/") { resolved.removeLast() }
                return ([resolved] + tail).joined(separator: "/")
            }
            tail.insert(components.removeLast(), at: 0)
        }
        return path
    }

    /// Convenience over `refusal(for:hermesHome:userHome:)` for a live
    /// context. The user home and the physical resolution are consulted only
    /// for LOCAL contexts, where this Mac's filesystem describes the same
    /// machine the path is on.
    public static func refusal(for candidate: String, context: ServerContext) -> Refusal? {
        let isLocal: Bool
        switch context.kind {
        case .local: isLocal = true
        case .ssh: isLocal = false
        }
        return refusal(
            for: candidate,
            hermesHome: context.paths.home,
            userHome: isLocal ? NSHomeDirectory() : nil,
            resolveSymlinks: isLocal
        )
    }

    /// Time-of-use admission for a root that came out of the AGENT-WRITABLE
    /// registry (`projects.json`), as opposed to one a human or
    /// `project_register` just offered.
    ///
    /// Identical rules to `refusal(for:context:)` — the point is not a
    /// different policy but a second application of the same one, at the
    /// moment the root is about to anchor a containment guard. Named
    /// separately so the call sites read as what they are, and so this
    /// doc comment sits where the reviewers will look.
    ///
    /// Callers must REFUSE THE OPERATION and surface `.message`, never
    /// quietly hide the project: see the type's doc comment.
    public static func refusalAtUse(for root: String, context: ServerContext) -> Refusal? {
        refusal(for: root, context: context)
    }
}
