import Foundation
import WebKit
import ScarfCore
import os

/// Serves a single mini-app's assets over `scarf-miniapp://`, scoped to
/// that mini-app's directory. The path-containment + MIME + CSP logic
/// lives in `ScarfCore.MiniAppAssetResolver` (pure + unit-tested); this is
/// the thin WebKit shell that reads the resolved file and hands it back.
///
/// **Read-only + directory-scoped.** Every request resolves through the
/// resolver, which rejects any path that escapes `baseDirectory`. The
/// response carries a strict CSP (no network) and `nosniff`. There is no
/// directory listing and no write path.
///
/// **Asynchronous, with a live-task ledger.** Reading the asset happens on
/// a background queue and the response is delivered back on the main
/// queue. The reason it used to be synchronous — "then the task can't be
/// `stop`-ed mid-serve", which is the "message a stopped
/// `WKURLSchemeTask`" crash class — is bought back by the ledger below
/// rather than by blocking: a task is entered in `live` when it starts,
/// removed when it is stopped or finished, and every delivery checks it is
/// still there first. Both ends of that run on the main queue, so there is
/// no window between the check and the call.
///
/// What blocking cost instead: up to `maxAssetBytes` (64 MB) read into
/// memory on the MAIN THREAD, per request, from an agent-generated
/// directory — charter C10, and visible as a beachball on any mini-app
/// serving something big.
final class MiniAppSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Tasks WebKit has started and not stopped. Main-queue only.
    private var live: Set<ObjectIdentifier> = []
    /// Reads happen here, one at a time — a mini-app's page pulls a handful
    /// of assets and serialising them keeps peak memory to one asset.
    private static let ioQueue = DispatchQueue(
        label: "com.scarf.miniapp.assets", qos: .userInitiated
    )
    private static let logger = Logger(subsystem: "com.scarf", category: "MiniAppSchemeHandler")

    /// The base directory, RESOLVED AND PROVEN once, at mount — or the
    /// refusal that says why it can't be served out of at all.
    ///
    /// This carries two guarantees that used to be separate, and one that
    /// did not exist:
    ///
    /// - the registry row this directory was derived from names a root a
    ///   containment check can mean something relative to (`ProjectRootPolicy`);
    /// - no component of `<root>/.scarf/miniapps/<id>` — the id segment
    ///   included — is a symlink, so the anchor names the place it reaches;
    /// - and the resolved spelling is FROZEN, so the per-request checks
    ///   below (including the `F_GETPATH` re-check on the open descriptor)
    ///   compare against the base as proven here rather than against
    ///   whatever the base resolves to at the moment of the read. The
    ///   mini-app directory is agent-writable, so those are different
    ///   questions: symlinking the BASE to `/Users/me` used to relocate
    ///   containment wholesale and every downstream check agreed.
    ///
    /// Computed once because it must be: an anchor re-derived per request
    /// is not an anchor. Refusing here does NOT hide the project from the
    /// sidebar — the row stays, the mini-app doesn't run.
    private let anchor: Result<MiniAppAssetResolver.BaseAnchor, MiniAppAssetResolver.AnchorRefusal>

    init(baseDirectory: String) {
        // A mini-app is unpacked by the local installer and served to a
        // local `WKWebView`; `baseDirectory` is a path on this Mac, which is
        // why `.local` is the right context to judge it in (and why the read
        // below may use `open(2)` at all).
        self.anchor = MiniAppAssetResolver.anchor(baseDirectory: baseDirectory, context: .local)
    }

    /// Per-asset ceiling. Generous for anything a mini-app legitimately
    /// serves (a page, a script, an image, a short clip) while bounding the
    /// pathological case. Refusals are logged AND returned as 413, never
    /// silently truncated — a half-served asset is worse than a failed one.
    static let maxAssetBytes = 64 * 1024 * 1024

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        live.insert(ObjectIdentifier(urlSchemeTask))

        // Mount-time anchor check (see `anchor`). 403 rather than 404: the
        // file may well exist, we are declining to serve out of this
        // directory at all, and the page's own error handling should see
        // the difference.
        let base: MiniAppAssetResolver.BaseAnchor
        switch anchor {
        case .success(let resolved):
            base = resolved
        case .failure(let refusal):
            Self.logger.error(
                "refusing to serve mini-app assets: \(refusal.message, privacy: .public)"
            )
            respond(
                urlSchemeTask, url: url, status: 403,
                mime: "text/plain; charset=utf-8",
                body: Data(refusal.message.utf8)
            )
            return
        }

        // MIME is decided from the REQUESTED path, before any I/O — it is a
        // function of the extension the page asked for, and deriving it here
        // keeps the read below the only thing that touches the filesystem.
        let mime = MiniAppAssetResolver.mimeType(forPath: url.path)
        let requestPath = url.path

        // ONE open, on the io queue, doing everything: containment,
        // `O_NOFOLLOW`, fd validation (regular file, `F_GETPATH` still
        // inside the base), the size cap, and the read.
        //
        // The previous shape checked containment on the main queue, stat-ed
        // the path for the size cap, then re-opened the same path on the io
        // queue — three separate resolutions of an attacker-writable path,
        // with an async hop in the middle. `MiniAppAssetResolver.readContainedFile`
        // collapses them into a single descriptor that is checked and read.
        //
        // Locality: this handler has always read with `FileManager`, i.e. it
        // has only ever been able to serve LOCAL files — a mini-app is
        // unpacked by the local installer and served to a local `WKWebView`,
        // and `baseDirectory` is a local filesystem path by construction.
        // Passing `isLocal: true` records that assumption at the call site
        // rather than leaving it implicit.
        Self.ioQueue.async { [weak self] in
            let result = MiniAppAssetResolver.readContainedFile(
                requestPath: requestPath,
                anchor: base,
                maxBytes: Self.maxAssetBytes
            )
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let asset):
                    self.respond(urlSchemeTask, url: url, status: 200, mime: mime, body: asset.data)
                case .failure(.tooLarge(let bytes)):
                    Self.logger.warning(
                        "mini-app asset over the \(Self.maxAssetBytes, privacy: .public)-byte cap refused: \(requestPath, privacy: .public) (\(bytes, privacy: .public) bytes)"
                    )
                    self.respond(
                        urlSchemeTask, url: url, status: 413,
                        mime: "text/plain; charset=utf-8",
                        body: Data("Asset exceeds the \(Self.maxAssetBytes / (1024 * 1024)) MB mini-app limit.".utf8)
                    )
                case .failure(let refusal):
                    if refusal != .notFound {
                        Self.logger.warning(
                            "blocked mini-app request \(requestPath, privacy: .public): \(String(describing: refusal), privacy: .public)"
                        )
                    }
                    self.respond(
                        urlSchemeTask, url: url, status: 404,
                        mime: "text/plain; charset=utf-8", body: Data("Not found".utf8)
                    )
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // The read may still be in flight. Dropping the task from the
        // ledger is what makes the delivery a no-op instead of a message to
        // a stopped task.
        live.remove(ObjectIdentifier(urlSchemeTask))
    }

    /// Deliver a response, unless WebKit stopped the task while we were
    /// reading. MAIN QUEUE ONLY — `live` is unsynchronised, and the whole
    /// point is that the check and the delivery share a turn.
    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, mime: String, body: Data) {
        guard live.remove(ObjectIdentifier(task)) != nil else { return }
        let headers = [
            "Content-Type": mime,
            "Content-Length": String(body.count),
            "Content-Security-Policy": MiniAppAssetResolver.contentSecurityPolicy,
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "no-store",
        ]
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        ) else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}
