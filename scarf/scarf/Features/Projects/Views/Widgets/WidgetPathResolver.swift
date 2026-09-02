import SwiftUI
import ScarfCore

/// Project root the dashboard widgets resolve relative `path` fields against.
/// Set by `ProjectsView` from the currently-selected project; nil when no
/// project is active. v2.7+ file-reading widgets (markdown_file, log_tail,
/// image-local) read this via the environment.
private struct SelectedProjectRootKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var selectedProjectRoot: String? {
        get { self[SelectedProjectRootKey.self] }
        set { self[SelectedProjectRootKey.self] = newValue }
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
    }

    static func resolve(_ relativePath: String?, projectRoot: String?) -> Result<String, ResolveError> {
        guard let projectRoot, !projectRoot.isEmpty else { return .failure(.noProject) }
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
        if FileManager.default.fileExists(atPath: rootStd),
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
        }
    }
}
