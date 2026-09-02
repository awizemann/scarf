import Foundation

/// Pure, WebKit-free core of the `scarf-miniapp://` asset server: resolve a
/// requested path to a file **inside** one mini-app's directory, reject any
/// escape, and decide the response's MIME type + CSP.
///
/// Kept out of the WebKit layer precisely so the security-critical
/// containment check is unit-testable without a `WKWebView`. The Mac-target
/// `MiniAppSchemeHandler` is a thin shell over this.
///
/// **Why a custom scheme + this resolver, not `file://`.** Serving the
/// mini-app over a directory-scoped custom scheme means web content gets a
/// stable origin (`scarf-miniapp://…`) with no path-traversal into the rest
/// of the filesystem — `file://` would let `../../` walk out. Every request
/// is resolved here and bounded to the mini-app's own directory.
public enum MiniAppAssetResolver {

    /// The custom URL scheme mini-apps are served over.
    public static let scheme = "scarf-miniapp"

    /// Fixed authority component of mini-app URLs (`scarf-miniapp://app/…`).
    /// Arbitrary + ignored during resolution — only the path matters.
    public static let host = "app"

    /// Strict default Content-Security-Policy for the served document.
    ///
    /// `connect-src 'none'` blocks all network (no exfiltration) until the
    /// `net` permission ships an allowlist; `default-src 'none'` denies
    /// everything not explicitly re-allowed; `'unsafe-inline'` for
    /// script/style is the deliberate v1 concession so build-step-free
    /// mini-apps run their own bundled code — the trust boundary is the
    /// blocked network + the directory-scoped scheme, not script provenance.
    public static let contentSecurityPolicy =
        "default-src 'none'; "
        + "script-src 'self' 'unsafe-inline'; "
        + "style-src 'self' 'unsafe-inline'; "
        + "img-src 'self' data:; "
        + "font-src 'self' data:; "
        + "media-src 'self'; "
        + "connect-src 'none'; "
        + "base-uri 'none'; "
        + "form-action 'none'; "
        + "frame-ancestors 'none'"

    /// Resolve a request path (`url.path`, already percent-decoded) to an
    /// absolute file path **lexically** inside `baseDirectory`. Returns
    /// `nil` when the path is empty, names the directory itself, or escapes
    /// the base via `..`. A leading-`/` "absolute" request and a literal
    /// `~` are treated as relative to base (so they stay contained — they
    /// name would-be subdirectories, they don't re-root). The returned path
    /// is normalized but NOT symlink- or existence-checked.
    ///
    /// **This is the lexical layer only.** It cannot see symlinks (it does
    /// no filesystem I/O, for testability). Callers that actually open the
    /// file MUST use `containedFilePath` instead, which adds the
    /// symlink-resolved containment + existence check.
    public static func resolvedPath(requestPath: String, baseDirectory: String) -> String? {
        let base = (baseDirectory as NSString).standardizingPath
        guard !base.isEmpty else { return nil }

        var rel = requestPath
        while rel.hasPrefix("/") { rel.removeFirst() }
        rel = rel.trimmingCharacters(in: .whitespaces)
        guard !rel.isEmpty else { return nil }
        // Reject control characters / NUL outright.
        guard !rel.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }

        let joined = base + "/" + rel
        let normalized = (joined as NSString).standardizingPath

        // Containment: the resolved path must sit strictly below base/.
        // (Equal-to-base means they asked for the directory, not a file.)
        guard normalized.hasPrefix(base + "/") else { return nil }
        return normalized
    }

    /// Resolve a request to an absolute file path that is provably an
    /// existing, non-directory file **inside** `baseDirectory` even after
    /// symlinks are followed — the path the scheme handler may safely read.
    /// Returns `nil` for any escape, miss, or directory.
    ///
    /// This closes the gap `resolvedPath` can't: a symlink planted inside
    /// the (agent-writable / template-delivered) mini-app dir could point
    /// at `~/.hermes/auth.json`, pass the lexical check, and be read
    /// through. Here both the base and the candidate are run through
    /// `resolvingSymlinksInPath` and re-checked, so a link that escapes the
    /// real base is refused. Resolving BOTH sides also keeps legitimate
    /// serves working when the base itself lives under a symlinked prefix
    /// (e.g. macOS `/tmp` → `/private/tmp`).
    public static func containedFilePath(requestPath: String, baseDirectory: String) -> String? {
        guard let lexical = resolvedPath(requestPath: requestPath, baseDirectory: baseDirectory) else {
            return nil
        }
        guard isSymlinkContained(path: lexical, baseDirectory: baseDirectory) else { return nil }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: lexical, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return lexical
    }

    /// Symlink-resolved containment: is `path` still inside `baseDirectory`
    /// once BOTH sides are run through `resolvingSymlinksInPath`?
    ///
    /// The reusable half of `containedFilePath` — split out so callers that
    /// must NOT require local existence (a widget path that may be read over
    /// SSH, or a file that doesn't exist yet) can apply the same
    /// resolve-both-sides rule without inheriting the exists-and-is-a-file
    /// check. Resolving both sides is what keeps legitimate cases working
    /// when the base itself lives under a symlinked prefix (macOS `/tmp` →
    /// `/private/tmp`, test dirs under `/var` → `/private/var`).
    ///
    /// A path that does not exist resolves as far as its existing prefix,
    /// so a not-yet-created file inside the base still passes.
    public static func isSymlinkContained(path: String, baseDirectory: String) -> Bool {
        let baseReal = URL(fileURLWithPath: (baseDirectory as NSString).standardizingPath)
            .resolvingSymlinksInPath().path
        let fileReal = URL(fileURLWithPath: (path as NSString).standardizingPath)
            .resolvingSymlinksInPath().path
        return fileReal == baseReal || fileReal.hasPrefix(baseReal + "/")
    }

    /// MIME type for a file path, by extension. Unknown → octet-stream.
    public static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "wasm": return "application/wasm"
        case "txt", "md": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    /// Build the entry URL string for a mini-app's entry document.
    public static func entryURLString(entry: String) -> String {
        var e = entry
        while e.hasPrefix("/") { e.removeFirst() }
        if e.isEmpty { e = "index.html" }
        return "\(scheme)://\(host)/\(e)"
    }
}
