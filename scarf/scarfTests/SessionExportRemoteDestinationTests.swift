import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Coverage for the remote session-export destination contract.
///
/// Pre-fix, `exportSession`/`exportAll` opened an `NSSavePanel`
/// unconditionally and fed the chosen path straight to `hermes sessions
/// export`. On a remote context that CLI runs on the far host over SSH,
/// so the panel — which browses *this Mac* — handed it a path that host
/// doesn't have. The export failed (or wrote to a Mac-shaped path on the
/// remote box), and because `runHermes` is `@discardableResult` and the
/// result was dropped, the user saw nothing at all: no file, no error.
///
/// Post-fix, a remote context routes through `pendingRemoteExport` so the
/// view can ask for a path *on the remote host*, and every export reports
/// its outcome through `exportMessage`.
///
/// The CLI is scripted through the `sessionExportRunner` seam — no
/// subprocess, no SSH round-trip. Local exports still gate on an
/// `NSSavePanel`, so they're covered at the `performExport` level (the
/// panel's only job is producing the path it takes).
@MainActor
@Suite struct SessionExportRemoteDestinationTests {

    /// Thread-safe recorder for the argv the export seam is handed.
    final class ArgvRecorder: @unchecked Sendable {
        private var calls: [[String]] = []
        private let lock = NSLock()
        func record(_ args: [String]) {
            lock.lock(); defer { lock.unlock() }
            calls.append(args)
        }
        var recorded: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return calls
        }
    }

    private static func remoteContext() -> ServerContext {
        ServerContext(
            id: ServerID(),
            displayName: "build-box",
            kind: .ssh(SSHConfig(host: "build-box", user: "jon"))
        )
    }

    /// Only `id` matters here — it's what the export argv and the
    /// suggested filename are built from.
    private static func session(id: String) -> HermesSession {
        HermesSession(
            id: id,
            source: "claude",
            userId: nil,
            model: nil,
            title: "A session",
            parentSessionId: nil,
            startedAt: nil,
            endedAt: nil,
            endReason: nil,
            messageCount: 3,
            toolCallCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            estimatedCostUSD: nil,
            reasoningTokens: 0,
            actualCostUSD: nil,
            costStatus: nil,
            billingProvider: nil
        )
    }

    @Test("Remote single-session export defers to a remote-path sheet instead of running the CLI")
    func remoteExportDefersToSheet() {
        let recorder = ArgvRecorder()
        let vm = SessionsViewModel(context: Self.remoteContext())
        vm.sessionExportRunner = { _, args in
            recorder.record(args)
            return ("", 0)
        }

        vm.exportSession(Self.session(id: "abc123"))

        // The whole bug: nothing may reach the CLI until we know a path
        // on the REMOTE host. No NSSavePanel is opened either — this test
        // would hang on a modal if one were.
        #expect(recorder.recorded.isEmpty)
        #expect(vm.pendingRemoteExport?.sessionId == "abc123")
        #expect(vm.pendingRemoteExport?.suggestedName == "abc123.jsonl")
    }

    @Test("Remote export-all defers with a nil session id (meaning: every session)")
    func remoteExportAllDefersToSheet() {
        let recorder = ArgvRecorder()
        let vm = SessionsViewModel(context: Self.remoteContext())
        vm.sessionExportRunner = { _, args in
            recorder.record(args)
            return ("", 0)
        }

        vm.exportAll()

        #expect(recorder.recorded.isEmpty)
        #expect(vm.pendingRemoteExport != nil)
        #expect(vm.pendingRemoteExport?.sessionId == nil)
        #expect(vm.pendingRemoteExport?.suggestedName == "hermes-sessions.jsonl")
    }

    @Test("Confirming a remote path runs the export against that path, on the remote host")
    func confirmedRemotePathReachesCLI() async {
        let recorder = ArgvRecorder()
        let vm = SessionsViewModel(context: Self.remoteContext())
        vm.sessionExportRunner = { _, args in
            recorder.record(args)
            return ("", 0)
        }

        vm.performExport(to: "~/exports/abc123.jsonl", sessionId: "abc123")
        await Self.settle(until: { !recorder.recorded.isEmpty })

        #expect(recorder.recorded == [[
            "sessions", "export", "~/exports/abc123.jsonl",
            "--session-id", "abc123",
        ]])
        // The banner must name the host, so a file written on the remote
        // box isn't mistaken for one on the user's Mac.
        #expect(vm.exportMessage == "Exported to ~/exports/abc123.jsonl on build-box")
    }

    @Test("Export-all omits --session-id so the CLI dumps every session")
    func exportAllOmitsSessionFilter() async {
        let recorder = ArgvRecorder()
        let vm = SessionsViewModel(context: Self.remoteContext())
        vm.sessionExportRunner = { _, args in
            recorder.record(args)
            return ("", 0)
        }

        vm.performExport(to: "~/all.jsonl", sessionId: nil)
        await Self.settle(until: { !recorder.recorded.isEmpty })

        #expect(recorder.recorded == [["sessions", "export", "~/all.jsonl"]])
    }

    @Test("A failing export surfaces the CLI's stderr instead of failing silently")
    func failedExportSurfacesError() async {
        let vm = SessionsViewModel(context: Self.remoteContext())
        vm.sessionExportRunner = { _, _ in
            ("No such file or directory: /Users/jon/Desktop\n", 1)
        }

        vm.performExport(to: "/Users/jon/Desktop/abc.jsonl", sessionId: "abc123")
        await Self.settle(until: { vm.exportMessage != nil })

        #expect(vm.exportMessage == "Export failed: No such file or directory: /Users/jon/Desktop")
    }

    /// A transport failure (or a missing local binary) returns exit -1 with
    /// no output at all — the exact shape that made this bug invisible.
    /// It must still produce a banner.
    @Test("A silent transport failure still reports the exit code")
    func silentFailureStillReports() async {
        let vm = SessionsViewModel(context: Self.remoteContext())
        vm.sessionExportRunner = { _, _ in ("", -1) }

        vm.performExport(to: "~/abc.jsonl", sessionId: "abc123")
        await Self.settle(until: { vm.exportMessage != nil })

        #expect(vm.exportMessage == "Export failed (exit -1).")
    }

    /// `performExport` hands the CLI call to a detached task, so poll the
    /// main-actor state rather than assuming it has landed.
    private static func settle(until condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
