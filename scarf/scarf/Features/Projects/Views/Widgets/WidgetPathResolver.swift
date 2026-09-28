import SwiftUI
import ScarfCore

/// Project root the dashboard widgets resolve relative `path` fields against.
/// Set by `ProjectsView` from the currently-selected project; nil when no
/// project is active. v2.7+ file-reading widgets (markdown_file, log_tail,
/// image-local) read this via the environment.
private struct SelectedProjectRootKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

/// The host's absolute homes, for judging a root the local disk can't:
/// a remote root. Set by the cockpit from the probed `$HOME`
/// (`ServerContext.resolvedUserHome()`); `nil` for a local project, or
/// while it is still unknown.
struct WidgetHostHomes: Equatable, Sendable {
    /// The user's home on the host (`$HOME`).
    let userHome: String
    /// The Hermes home on the host, `~` already expanded.
    let hermesHome: String
}

private struct SelectedProjectHostHomesKey: EnvironmentKey {
    static let defaultValue: WidgetHostHomes? = nil
}

extension EnvironmentValues {
    var selectedProjectRoot: String? {
        get { self[SelectedProjectRootKey.self] }
        set { self[SelectedProjectRootKey.self] = newValue }
    }
    var selectedProjectHostHomes: WidgetHostHomes? {
        get { self[SelectedProjectHostHomesKey.self] }
        set { self[SelectedProjectHostHomesKey.self] = newValue }
    }
}

/// Resolves a widget's `path` field against the project root. Rejects
/// absolute paths, empty / nil inputs, paths that escape the project
/// boundary via `..` segments, and — for local projects — paths that escape
/// it through a **symlink**. The returned path is suitable to hand to
/// `transport.readFile`.
///
/// Returns nil + the reason if the path is invalid; widgets surface that
/// reason via `WidgetErrorCard`.
enum WidgetPathResolver {
    enum ResolveError: Error, Equatable {
        case noProject
        case missingPath
        case absolutePath
        case escapesProject
        /// The project ROOT itself may not anchor a containment check —
        /// `/`, the user's home, a system directory, or something that
        /// resolves to one. Carries the policy's own message.
        case inadmissibleRoot(String)
        /// The root is still `~`-rooted: its host's home couldn't be
        /// resolved, so nothing can be proved inside it — and expanding it
        /// with this Mac's home would read the wrong machine's files.
        case unresolvedHome
    }

    /// Is this root allowed to anchor a widget's file read AT ALL?
    ///
    /// Containment below is relative to `projectRoot`, and the root comes
    /// from a registry row — `projects.json` is agent-writable (P8 SEC-H1),
    /// so a row rewritten to `/Users/me` turns "inside the project" into
    /// "anywhere in the user's home" and a `markdown_file` widget reads any
    /// document the user owns. `project_register` checks this policy once at
    /// mint time; that check is not a fact about a row that never went
    /// through it, so it is re-derived here, at the moment of use.
    ///
    /// A root that exists locally is judged in full (home, Hermes home, and
    /// the physical/firmlink spellings — all questions about THIS machine).
    /// A root that doesn't is presumed remote and gets only the universal
    /// rules — `/` and the POSIX system directories, which are absurd on any
    /// host — because the local home and the local filesystem describe a
    /// different computer. That mirrors the existing gate on the symlink
    /// layer a few lines down, and for the same reason.
    ///
    /// Refusal fails the READ, not the project: the row stays in the
    /// sidebar and the widget shows why. Silently dropping projects that
    /// fail a newly-tightened policy would break legitimate users far more
    /// often than it stops an agent that can rewrite the file again anyway.
    ///
    /// With `hostHomes` (a remote whose `$HOME` was probed) the remote root
    /// is also refused when it IS the host's home or contains its Hermes
    /// home — the rules a local root gets from this Mac's disk.
    private static func rootRefusal(
        _ projectRoot: String, hostHomes: WidgetHostHomes?
    ) -> ProjectRootPolicy.Refusal? {
        if hostHomes == nil,
           FileManager.default.fileExists(atPath: (projectRoot as NSString).standardizingPath) {
            return ProjectRootPolicy.refusalAtUse(for: projectRoot, context: .local)
        }
        return ProjectRootPolicy.refusal(
            for: projectRoot,
            hermesHome: hostHomes?.hermesHome ?? "",
            userHome: hostHomes?.userHome,
            resolveSymlinks: false
        )
    }

    /// - Parameter hostHomes: the remote host's probed homes. The cockpit
    ///   expands a `~`-rooted registry path with them before it gets here;
    ///   a root that still starts with `~` is refused (`unresolvedHome`),
    ///   never expanded against this Mac's home.
    /// A registry root as the widgets use it, plus the host's homes.
    struct ResolvedRoot: Equatable, Sendable {
        /// The registry spelling this was resolved from.
        let source: String
        /// The root widgets resolve against: `~` expanded with the HOST's
        /// home, or left as `~…` when that home couldn't be found (which
        /// `resolve` then refuses).
        let root: String
        let hostHomes: WidgetHostHomes?
    }

    /// Resolve a registry root for `context`, off the main actor (the remote
    /// home is an SSH probe, cached per server). Local: this Mac's home
    /// expands a (rare) `~` row and the local disk judges the root. Remote:
    /// the probed `$HOME` expands it and supplies the policy's homes; a
    /// failed probe leaves the `~` in place.
    nonisolated static func resolveRoot(_ projectRoot: String, context: ServerContext) async -> ResolvedRoot {
        let home = await context.resolvedUserHome()
        guard home.hasPrefix("/") else {
            return ResolvedRoot(source: projectRoot, root: projectRoot, hostHomes: nil)
        }
        let homes = context.isRemote
            ? WidgetHostHomes(
                userHome: home,
                hermesHome: ServerContext.expandingTilde(context.paths.home, home: home))
            : nil
        return ResolvedRoot(
            source: projectRoot,
            root: ServerContext.expandingTilde(projectRoot, home: home),
            hostHomes: homes
        )
    }

    static func resolve(
        _ relativePath: String?, projectRoot: String?, hostHomes: WidgetHostHomes? = nil
    ) -> Result<String, ResolveError> {
        guard let projectRoot, !projectRoot.isEmpty else { return .failure(.noProject) }
        if projectRoot.hasPrefix("~") { return .failure(.unresolvedHome) }
        if let refusal = rootRefusal(projectRoot, hostHomes: hostHomes) {
            return .failure(.inadmissibleRoot(refusal.message))
        }
        guard let relativePath, !relativePath.isEmpty else { return .failure(.missingPath) }
        if relativePath.hasPrefix("/") { return .failure(.absolutePath) }
        // Strip a single leading "./" — common in template-authored paths.
        let trimmed = relativePath.hasPrefix("./") ? String(relativePath.dropFirst(2)) : relativePath
        // Walk the segments and reject any "..": the project root is the
        // trust boundary, anything reaching outside it is rejected. We do
        // this BEFORE join+standardize so symlink games can't smuggle a
        // ".." through path canonicalization.
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        for s in segments where s == ".." { return .failure(.escapesProject) }
        let joined = (projectRoot as NSString).appendingPathComponent(trimmed)
        let standardized = (joined as NSString).standardizingPath
        // Lexical containment. `standardizingPath` resolves "." / ".." / "~"
        // but does NOT resolve symlinks — so this prefix check alone is a
        // purely textual guarantee (the previous comment here claimed the
        // opposite, which is what made the symlink hole look covered).
        let rootStd = (projectRoot as NSString).standardizingPath
        guard standardized == rootStd || standardized.hasPrefix(rootStd + "/") else {
            return .failure(.escapesProject)
        }
        // Symlink layer. A dashboard widget's `path` comes from
        // `.scarf/dashboard.json` — agent-writable — and the project tree it
        // points into is agent-writable too, so `reports/weekly.md` can be a
        // symlink to `~/.hermes/auth.json` and the lexical check above waves
        // it through; `transport.readFile` then reads THROUGH the link.
        // Apply the convention's resolve-BOTH-sides rule via the tested
        // ScarfCore helper (see
        // `.memory/conventions/path-containment-for-untrusted-dirs-…`).
        //
        // Gated on the root existing locally, and deliberately NOT routed
        // through `MiniAppAssetResolver.containedFilePath`: that helper also
        // demands the file exist as a local non-directory, which is wrong
        // here on two counts — these paths are read through `ServerContext`'s
        // transport and may live on a REMOTE host (nothing local to stat, and
        // no way to detect a remote symlink from here), and a missing local
        // file should surface as the widget's read error, not as
        // "escapes the project root".
        if hostHomes == nil, FileManager.default.fileExists(atPath: rootStd),
           !MiniAppAssetResolver.isSymlinkContained(path: standardized, baseDirectory: rootStd) {
            return .failure(.escapesProject)
        }
        return .success(standardized)
    }
}

extension WidgetPathResolver.ResolveError {
    /// Rendered straight into `WidgetErrorCard` (via its `verbatimReason:`
    /// init), so it must arrive already localized — a plain literal here was
    /// a permanently-English error message on a user-facing card.
    var userMessage: String {
        switch self {
        case .noProject:       return String(localized: "No project selected.")
        case .missingPath:     return String(localized: "Missing required `path` field.")
        case .absolutePath:    return String(localized: "Path must be relative to the project root, not absolute.")
        case .escapesProject:  return String(localized: "Path escapes the project root (`..` segments and symlinks that lead outside are not allowed).")
        case .inadmissibleRoot(let reason):
            // Already localized by `ProjectRootPolicy.Refusal.message`.
            return reason
        case .unresolvedHome:
            return String(localized: "Scarf couldn't find the home folder on this server, so it can't check that this file is inside the project. Check the connection, then try again in a minute.")
        }
    }
}
