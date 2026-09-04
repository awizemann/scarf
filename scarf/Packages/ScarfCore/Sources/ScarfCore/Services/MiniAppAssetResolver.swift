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
        guard case .success(let anchor) = anchor(baseDirectory: baseDirectory),
              isContained(path: lexical, inRealBase: anchor.real)
        else { return nil }

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
        return isContained(path: path, inRealBase: baseReal)
    }

    /// Containment against an ALREADY-RESOLVED base — the form every
    /// mini-app read uses.
    ///
    /// `isSymlinkContained(path:baseDirectory:)` re-resolves the base every
    /// time it is called, which is fine when the base is trusted and fatal
    /// when it is not: `<root>/.scarf/miniapps/<id>` is agent-writable, so
    /// an agent that replaces the BASE DIRECTORY ITSELF with a symlink to
    /// `/Users/me` moves the anchor, and every check downstream — including
    /// the `F_GETPATH` re-check on the open descriptor — then validates
    /// against the relocated base and passes. The fd was never the weak
    /// part; the thing it was compared to was. So the base is resolved and
    /// verified ONCE (see ``BaseAnchor``) and that frozen answer is what
    /// every subsequent check compares against.
    public static func isContained(path: String, inRealBase baseReal: String) -> Bool {
        let fileReal = URL(fileURLWithPath: (path as NSString).standardizingPath)
            .resolvingSymlinksInPath().path
        return fileReal == baseReal || fileReal.hasPrefix(baseReal + "/")
    }

    // MARK: - The frozen base anchor

    /// A mini-app base directory that has been resolved ONCE and proven to
    /// sit where it claims to. Carries both spellings: `lexical` is what
    /// the caller asked about (paths are joined against it), `real` is the
    /// only thing containment is ever judged against.
    ///
    /// Only ``anchor(baseDirectory:context:)`` can make one, which is the
    /// point — a `BaseAnchor` in hand IS the proof.
    public struct BaseAnchor: Sendable, Equatable {
        public let lexical: String
        public let real: String
    }

    /// Why a base directory may not anchor a containment check.
    public enum AnchorRefusal: Error, Sendable, Equatable {
        /// Empty, or not an absolute path.
        case notAbsolute
        /// The owning project root is one no containment check can be
        /// relative to (`/`, `$HOME`, a root containing `~/.hermes`…).
        case inadmissibleRoot(String)
        /// Some component between the project root and the base — or the
        /// base itself — is a symlink, so the directory the base NAMES and
        /// the directory it REACHES are different places. Carries the
        /// place it actually reaches.
        case relocatedBase(actual: String)
        /// The path is not on this machine, so none of this can be checked.
        case notLocal

        public var message: String {
            switch self {
            case .notAbsolute:
                return "A mini-app directory must be an absolute path."
            case .inadmissibleRoot(let reason):
                return reason
            case .relocatedBase(let actual):
                return "The mini-app directory is a link to \(actual), not a folder inside the "
                    + "project. Refusing to serve files through it."
            case .notLocal:
                return "Mini-app files can only be read for projects on this Mac."
            }
        }
    }

    /// Freeze `baseDirectory` into a ``BaseAnchor``, or say why it cannot
    /// be one.
    ///
    /// Three conditions, all required:
    ///
    /// 1. **Absolute.** A relative base has no fixed meaning at all.
    /// 2. **Admissible root.** The `<root>` the base was derived from is
    ///    re-run through `ProjectRootPolicy` at the moment of use, because
    ///    `projects.json` is agent-writable and a row rewritten to
    ///    `/Users/me` yields a base that looks perfectly contained. (A base
    ///    that isn't `<root>/.scarf/miniapps/<id>`-shaped is judged as its
    ///    own root — which is the bridge's case, where the base IS the
    ///    project root.)
    /// 3. **Unrelocated.** The base's physical resolution must equal the
    ///    resolved root plus the base's own lexical tail. Any symlinked
    ///    component — including the base directory itself — makes those two
    ///    disagree. This is the `PathGuard` parent-chain rule, extended one
    ///    component further to cover the leaf: `PathGuard` may leave a
    ///    symlinked leaf alone because it UNLINKS it, whereas here the leaf
    ///    is the anchor everything else is measured from.
    ///
    /// A root under a symlinked prefix (macOS `/tmp` → `/private/tmp`)
    /// still anchors fine: both sides of the comparison resolve it.
    public static func anchor(
        baseDirectory: String, context: ServerContext = .local
    ) -> Result<BaseAnchor, AnchorRefusal> {
        switch context.kind {
        case .local: break
        case .ssh: return .failure(.notLocal)
        }
        let base = PhysicalPath.standardized(baseDirectory)
        guard base.hasPrefix("/"), base.count > 1 else { return .failure(.notAbsolute) }

        let root = projectRoot(ofMiniAppBase: base) ?? base
        if let refusal = ProjectRootPolicy.refusalAtUse(for: root, context: context) {
            return .failure(.inadmissibleRoot(refusal.message))
        }

        let rootStd = PhysicalPath.standardized(root)
        let rootReal = PhysicalPath.physical(rootStd)
        // The base's lexical tail below the root, re-attached to the
        // RESOLVED root. If walking the real filesystem lands anywhere
        // else, a component on the way was a link.
        let tail = base == rootStd ? "" : String(base.dropFirst(rootStd.count))
        let expected = rootReal + tail
        let actual = PhysicalPath.physical(base)
        guard actual == expected else { return .failure(.relocatedBase(actual: actual)) }
        return .success(BaseAnchor(lexical: base, real: expected))
    }

    // MARK: - Trust at use: the base directory's owning project root

    /// The project root a mini-app base directory was derived from, i.e. the
    /// `<root>` in `MiniAppService.miniAppDir`'s
    /// `<root>/.scarf/miniapps/<id>`. `nil` when `baseDirectory` doesn't
    /// have that shape (nothing to judge, so nothing is claimed).
    ///
    /// **Why this exists.** Containment here is relative to the mini-app
    /// directory, which looks safe in isolation — but that directory is
    /// derived from a registry row's `path`, and `projects.json` is
    /// agent-writable (P8 SEC-H1). A row rewritten to `/Users/me` yields the
    /// perfectly-contained-looking base `/Users/me/.scarf/miniapps/x`, and
    /// the mini-app then serves and reads out of a directory inside the
    /// user's home that the agent also controls. Recovering the root lets a
    /// caller re-run `ProjectRootPolicy` at the moment of use instead of
    /// trusting that registration once said yes.
    public static func projectRoot(ofMiniAppBase baseDirectory: String) -> String? {
        let suffix = "/.scarf/miniapps/"
        let base = (baseDirectory as NSString).standardizingPath
        guard let range = base.range(of: suffix, options: .backwards) else { return nil }
        let root = String(base[base.startIndex..<range.lowerBound])
        // The id segment must be exactly one component — otherwise this is
        // some deeper path that merely contains the marker.
        let tail = String(base[range.upperBound...])
        guard !tail.isEmpty, !tail.contains("/"), !root.isEmpty else { return nil }
        return root
    }

    // MARK: - TOCTOU-safe read

    /// One successfully-read asset: the bytes, and the path the OPEN FILE
    /// DESCRIPTOR reported (`F_GETPATH`) — which is where the read actually
    /// came from, not where the caller asked. A named type rather than a
    /// tuple so `Result` is `Equatable` and tests can compare outcomes
    /// whole.
    public struct Asset: Sendable, Equatable {
        public let path: String
        public let data: Data
        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }
    }

    /// Why a contained read was refused. Distinguishes "no such asset" from
    /// "the asset is there but we won't serve it", so a handler can answer
    /// 404 vs 413 vs 404-with-a-log rather than collapsing everything.
    public enum ReadRefusal: Error, Sendable, Equatable {
        /// Failed the lexical or symlink-resolved containment check, or the
        /// open itself refused a symlink (`O_NOFOLLOW` → `ELOOP`).
        case notContained
        /// No such file, or it vanished between check and open.
        case notFound
        /// Exists but isn't a regular file — a directory, fifo, device, or
        /// socket. Never served.
        case notRegularFile
        /// Larger than the caller's ceiling. Carries the real size so the
        /// handler can say so.
        case tooLarge(bytes: Int)
        /// The path is not on this machine, so there is no fd to validate.
        case notLocal
        /// `read(2)` failed part-way.
        case readFailed
    }

    /// Read a mini-app asset the way it must be read: resolve containment,
    /// then open with `O_NOFOLLOW` and re-validate the OPEN FILE DESCRIPTOR
    /// before a byte is returned.
    ///
    /// **The hole this closes** (P8 SEC-M1). Every previous caller checked
    /// containment on a PATH and then, later — after an async hop, in the
    /// scheme handler's case — opened that same path again. A mini-app
    /// directory is agent-writable and template-delivered, so the attacker
    /// owns both ends of that window: serve a real file for the check, swap
    /// it for a symlink to `~/.hermes/auth.json` before the read, and the
    /// secret lands in a web context. Nothing about the path check can fix
    /// that; the check has to survive to the read, which means the thing
    /// checked has to BE the thing read.
    ///
    /// So: one `open(2)` with `O_NOFOLLOW` (the final component may not be a
    /// symlink — that alone defeats the simple flip), then `fstat` on the
    /// fd (regular file, and the size the cap is applied to is the size of
    /// the object we are actually holding), then `F_GETPATH` on the fd —
    /// which reports where the descriptor really points, catching a swapped
    /// INTERMEDIATE directory that `O_NOFOLLOW` says nothing about — and a
    /// final containment check on that answer. After that the fd is read to
    /// EOF. No path is ever re-opened.
    ///
    /// **Local only, and it says so.** `open(2)` operates on this Mac's
    /// filesystem. A remote project's path would silently name a
    /// LOCAL file of the same name — a different file on a different
    /// machine — so callers must establish locality first and this returns
    /// `.notLocal` for a base directory that isn't on the local filesystem.
    /// Mini-app directories are local today by construction (they are
    /// unpacked by the local installer and served to a local `WKWebView`),
    /// but "today" is not a guarantee, which is why the check is here.
    ///
    /// **Deliberate narrowing.** `O_NOFOLLOW` also refuses a symlink that
    /// points somewhere legitimate INSIDE the mini-app directory, which
    /// `containedFilePath` alone allowed. There is no way to tell that link
    /// apart from the attack at open time, an asset directory is unpacked
    /// from a zip rather than authored in place, and the honest failure is a
    /// 404 on one file — so the trade is taken.
    ///
    /// - Parameter isLocal: the caller's own determination that
    ///   `baseDirectory` is on this machine (e.g. `ServerContext.kind`).
    public static func readContainedFile(
        requestPath: String,
        baseDirectory: String,
        maxBytes: Int,
        isLocal: Bool = true
    ) -> Result<Asset, ReadRefusal> {
        guard isLocal else { return .failure(.notLocal) }
        // ONE anchor for the whole read: resolved here, then handed to the
        // fd check below. Re-deriving it there would reopen the very hole
        // the anchor closes.
        guard case .success(let anchor) = anchor(baseDirectory: baseDirectory) else {
            return .failure(.notContained)
        }
        return readContainedFile(
            requestPath: requestPath, anchor: anchor, maxBytes: maxBytes
        )
    }

    /// ``readContainedFile(requestPath:baseDirectory:maxBytes:isLocal:)``
    /// against a base a caller already froze — the form a long-lived caller
    /// (a scheme handler bound to one webview) should use, so the anchor is
    /// established at MOUNT and cannot be moved out from under a request.
    public static func readContainedFile(
        requestPath: String,
        anchor: BaseAnchor,
        maxBytes: Int
    ) -> Result<Asset, ReadRefusal> {
        guard let lexical = resolvedPath(requestPath: requestPath, baseDirectory: anchor.lexical),
              isContained(path: lexical, inRealBase: anchor.real)
        else { return .failure(.notContained) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: lexical, isDirectory: &isDir) else {
            return .failure(.notFound)
        }
        guard !isDir.boolValue else { return .failure(.notRegularFile) }
        return readValidated(path: lexical, anchor: anchor, maxBytes: maxBytes)
    }

    /// The fd half of `readContainedFile`, on an already-contained path.
    /// Split out so a caller that resolved the path itself (and wants the
    /// path back for MIME/size decisions before reading) can still get the
    /// TOCTOU-safe read, and so the fd validation is unit-testable directly.
    public static func readValidated(
        path: String,
        baseDirectory: String,
        maxBytes: Int
    ) -> Result<Asset, ReadRefusal> {
        guard case .success(let anchor) = anchor(baseDirectory: baseDirectory) else {
            return .failure(.notContained)
        }
        return readValidated(path: path, anchor: anchor, maxBytes: maxBytes)
    }

    /// ``readValidated(path:baseDirectory:maxBytes:)`` against a frozen
    /// anchor. The `F_GETPATH` answer is checked against `anchor.real` —
    /// the base as it was proven at mount — rather than against a base
    /// re-resolved now, which an agent can move between the two moments.
    public static func readValidated(
        path: String,
        anchor: BaseAnchor,
        maxBytes: Int
    ) -> Result<Asset, ReadRefusal> {
        // O_NOFOLLOW: refuse if the FINAL component is a symlink (ELOOP).
        // O_NONBLOCK: a fifo planted in the directory would otherwise block
        // the open forever. O_CLOEXEC: never leak the fd into a subprocess.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ELOOP: return .failure(.notContained)
            case ENOENT: return .failure(.notFound)
            default: return .failure(.notFound)
            }
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failure(.notFound) }
        // Regular files only. A directory, fifo, socket or device node is
        // never a mini-app asset, and reading one has its own hazards.
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .failure(.notRegularFile) }
        let size = Int(info.st_size)
        guard size <= maxBytes else { return .failure(.tooLarge(bytes: size)) }

        // F_GETPATH answers "where does this descriptor actually point?",
        // which is the question `O_NOFOLLOW` can't: it says nothing about a
        // swapped intermediate directory. Re-check containment on THAT.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return .failure(.notContained) }
        let realPath = String(cString: buffer)
        guard isContained(path: realPath, inRealBase: anchor.real) else {
            return .failure(.notContained)
        }

        // Read the fd to EOF — never re-open the path. The size above is a
        // hint (the file can still grow under us), so the cap is enforced
        // again as bytes arrive.
        var data = Data()
        data.reserveCapacity(min(size, maxBytes))
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .failure(.readFailed)
            }
            guard data.count + count <= maxBytes else {
                return .failure(.tooLarge(bytes: data.count + count))
            }
            data.append(contentsOf: chunk[0..<count])
        }
        return .success(Asset(path: realPath, data: data))
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
