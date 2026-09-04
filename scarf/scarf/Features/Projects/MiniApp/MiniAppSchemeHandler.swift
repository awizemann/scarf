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

    private let baseDirectory: String

    init(baseDirectory: String) {
        self.baseDirectory = baseDirectory
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

        // `containedFilePath` adds the symlink-resolved containment +
        // existence/non-dir check on top of the lexical resolve, so a
        // symlink planted inside the mini-app dir can't be read through to
        // escape the directory.
        guard let filePath = MiniAppAssetResolver.containedFilePath(
            requestPath: url.path,
            baseDirectory: baseDirectory
        ) else {
            Self.logger.warning("blocked out-of-bounds / escaping mini-app request: \(url.path, privacy: .public)")
            respond(urlSchemeTask, url: url, status: 404, mime: "text/plain; charset=utf-8", body: Data("Not found".utf8))
            return
        }

        // SIZE CAP. `FileManager.contents(atPath:)` reads the whole file into
        // memory, and a mini-app's asset directory is AGENT-GENERATED — a
        // stray multi-gigabyte artefact dropped next to index.html would have
        // been loaded in full to serve one `<img>`. Stat first and refuse
        // anything over the ceiling with a real HTTP status, so the page's own
        // error handling fires instead of the app quietly ballooning.
        let attributes = try? FileManager.default.attributesOfItem(atPath: filePath)
        let byteSize = (attributes?[.size] as? NSNumber)?.intValue
        if let byteSize, byteSize > Self.maxAssetBytes {
            Self.logger.warning(
                "mini-app asset over the \(Self.maxAssetBytes, privacy: .public)-byte cap refused: \(url.path, privacy: .public) (\(byteSize, privacy: .public) bytes)"
            )
            respond(
                urlSchemeTask, url: url, status: 413,
                mime: "text/plain; charset=utf-8",
                body: Data("Asset exceeds the \(Self.maxAssetBytes / (1024 * 1024)) MB mini-app limit.".utf8)
            )
            return
        }

        let mime = MiniAppAssetResolver.mimeType(forPath: filePath)
        Self.ioQueue.async { [weak self] in
            let data = FileManager.default.contents(atPath: filePath)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data else {
                    self.respond(
                        urlSchemeTask, url: url, status: 404,
                        mime: "text/plain; charset=utf-8", body: Data("Not found".utf8)
                    )
                    return
                }
                self.respond(urlSchemeTask, url: url, status: 200, mime: mime, body: data)
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
