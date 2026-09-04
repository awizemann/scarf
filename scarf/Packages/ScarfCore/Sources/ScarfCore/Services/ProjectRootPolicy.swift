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
/// panel — so the refusal belongs at registration, once, instead of being
/// re-derived (and forgotten) at each of the containment sites downstream.
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
    public enum Refusal: Sendable, Equatable {
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
    public static func refusal(
        for candidate: String,
        hermesHome: String,
        userHome: String?
    ) -> Refusal? {
        guard candidate.hasPrefix("/") else { return .notAbsolute }
        let path = ProjectIdentity.normalizedPath(candidate)
        guard path.hasPrefix("/"), path.count > 1 else { return .filesystemRoot }

        if let userHome, !userHome.isEmpty {
            let home = ProjectIdentity.normalizedPath(userHome)
            if home.hasPrefix("/"), path == home { return .homeDirectory(path) }
        }
        if systemDirectories.contains(path) { return .systemDirectory(path) }

        // At-or-above the Hermes home. Only meaningful when the Hermes home
        // is an absolute path — a remote `~/.hermes` that the remote shell
        // expands is not comparable to an absolute candidate, and guessing
        // would refuse legitimate remote roots.
        let hermes = ProjectIdentity.normalizedPath(hermesHome)
        if hermes.hasPrefix("/"), hermes.count > 1 {
            if path == hermes || hermes.hasPrefix(path + "/") {
                return .containsHermesHome(root: path, hermesHome: hermes)
            }
        }
        return nil
    }

    /// Convenience over `refusal(for:hermesHome:userHome:)` for a live
    /// context. The user home is consulted only for LOCAL contexts, where
    /// `NSHomeDirectory()` describes the same machine the path is on.
    public static func refusal(for candidate: String, context: ServerContext) -> Refusal? {
        let userHome: String?
        switch context.kind {
        case .local: userHome = NSHomeDirectory()
        case .ssh: userHome = nil
        }
        return refusal(for: candidate, hermesHome: context.paths.home, userHome: userHome)
    }
}
