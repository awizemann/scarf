import Testing
import Foundation
import WebKit
@testable import scarf

/// GW-F5 / SEC F7 — guard artifacts are not mini-app assets.
///
/// The mini-app root is a directory Scarf's guarded writers touch, so it
/// accumulates `<name>.bak` and `<name>.corrupt-<stamp>` copies. Those are
/// bookkeeping, not content: serving them would hand a page the PREVIOUS
/// version of a file through a channel that only ever meant to serve the
/// current one.
@Suite struct GwF5MiniAppArtifactDenyTests {

    @Test("both guard-artifact shapes are recognised, and nothing else is")
    func artifactShapes() {
        #expect(MiniAppSchemeHandler.isGuardArtifact("state.json.bak"))
        #expect(MiniAppSchemeHandler.isGuardArtifact("state.json.corrupt-20260907T101112Z"))
        #expect(MiniAppSchemeHandler.isGuardArtifact("state.json.corrupt-20260907T101112Z-a1b2c3d4"))
        #expect(MiniAppSchemeHandler.isGuardArtifact("index.html.bak.corrupt-20260907T101112Z"))
        #expect(!MiniAppSchemeHandler.isGuardArtifact("index.html"))
        #expect(!MiniAppSchemeHandler.isGuardArtifact("backup.js"))
        #expect(!MiniAppSchemeHandler.isGuardArtifact("corrupt-report.css"))
    }

    /// End to end through the scheme handler: the artifact is 404-ed and its
    /// bytes never reach the page, while the real file beside it still
    /// serves. Both files exist on disk, so this is the deny rule and not
    /// the file simply being absent.
    @MainActor
    @Test("a .bak or .corrupt- asset is refused even though the file exists")
    func artifactRequestsAreRefused() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-f5-miniapp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("current".utf8).write(to: base.appendingPathComponent("state.json"))
        try Data("previous".utf8).write(to: base.appendingPathComponent("state.json.bak"))
        try Data("broken".utf8).write(
            to: base.appendingPathComponent("state.json.corrupt-20260907T101112Z")
        )

        let handler = MiniAppSchemeHandler(baseDirectory: base.path)
        let webView = WKWebView()

        for name in ["state.json.bak", "state.json.corrupt-20260907T101112Z"] {
            let task = RecordingSchemeTask(path: "/" + name)
            handler.webView(webView, start: task)
            #expect(task.status == 404, "\(name) was served with status \(String(describing: task.status))")
            #expect(task.body == Data("Not found".utf8))
        }

        // Positive control: the file the artifacts were copied FROM is not
        // touched by the rule — it goes down the normal read path (io queue
        // out, main queue back), so the assertions wait for that hop.
        let ok = RecordingSchemeTask(path: "/state.json")
        handler.webView(webView, start: ok)
        let deadline = Date().addingTimeInterval(5)
        while ok.status == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(ok.status == 200, "healthy asset answered \(String(describing: ok.status))")
        #expect(ok.body == Data("current".utf8))
    }
}

/// A `WKURLSchemeTask` double: records what the handler answered instead of
/// driving a real web view.
private final class RecordingSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var status: Int?
    private(set) var body = Data()

    init(path: String) {
        self.request = URLRequest(url: URL(string: "scarf-miniapp://app\(path)")!)
    }

    func didReceive(_ response: URLResponse) {
        status = (response as? HTTPURLResponse)?.statusCode
    }
    func didReceive(_ data: Data) { body.append(data) }
    func didFinish() {}
    func didFailWithError(_ error: any Error) { status = -1 }
}
