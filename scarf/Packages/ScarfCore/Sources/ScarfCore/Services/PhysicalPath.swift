import Foundation

/// Canonical on-disk spellings of a local path.
///
/// **Why this is a type and not four free functions in whichever file
/// needed them.** Two independent containment guards had grown their own
/// copy of the same four-step dance — standardize, resolve, resolve the
/// deepest EXISTING ancestor and re-attach the missing tail, `lstat`-style
/// existence: `ProjectTemplateUninstaller.PathGuard` (app target) and, as
/// of the mini-app base anchor, `MiniAppAssetResolver` (ScarfCore). A
/// containment check is only as good as its notion of "where does this
/// path really point", so two notions is one too many; `PathGuard` now
/// delegates here.
///
/// **Local only.** Every function below asks this Mac's filesystem. A
/// remote path resolved here would answer a question about the wrong
/// machine, which is worse than not answering — callers that may hold a
/// remote path must establish locality first (see
/// `MiniAppAssetResolver.readContainedFile(…isLocal:)`).
public enum PhysicalPath: Sendable {

    /// Lexical normalization: `.`/`..` collapsed, no trailing slash. No
    /// filesystem access, so it says nothing about symlinks.
    public nonisolated static func standardized(_ path: String) -> String {
        var out = URL(fileURLWithPath: path).standardizedFileURL.path
        while out.count > 1, out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// `standardized` plus `resolvingSymlinksInPath`. Note that Foundation
    /// gives up entirely when the LEAF doesn't exist (it returns the input
    /// unresolved), which is exactly why `physical` exists.
    public nonisolated static func resolved(_ path: String) -> String {
        var out = URL(fileURLWithPath: path)
            .standardizedFileURL.resolvingSymlinksInPath().path
        while out.count > 1, out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// Canonical spelling, tolerant of a path that doesn't exist (yet /
    /// any more): resolve the deepest existing ancestor and re-attach the
    /// missing tail verbatim.
    ///
    /// Without this, a comparison of two resolved paths would silently
    /// depend on whether a file happened to be there at the moment of the
    /// check — an attacker-controllable input in every directory these
    /// guards are pointed at.
    public nonisolated static func physical(_ path: String) -> String {
        let std = standardized(path)
        var components = std.split(separator: "/").map(String.init)
        var tail: [String] = []
        while !components.isEmpty {
            let candidate = "/" + components.joined(separator: "/")
            if exists(candidate) {
                return ([resolved(candidate)] + tail).joined(separator: "/")
            }
            tail.insert(components.removeLast(), at: 0)
        }
        return std
    }

    /// `lstat`-flavored existence: true for a dangling symlink too, where
    /// `FileManager.fileExists` (which follows) says false.
    public nonisolated static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    /// Is `path` itself a symbolic link?
    public nonisolated static func isSymlink(_ path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return false
        }
        return (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
