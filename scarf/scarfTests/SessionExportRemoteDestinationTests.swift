import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Coverage for session export writing to the user's Mac.
///
/// Pre-fix, `exportSession`/`exportAll` passed the `NSSavePanel` path
/// straight to `hermes sessions export`. On a remote context that CLI runs
/// on the far host over SSH, so it received a path that host doesn't have:
/// the export failed, or landed on the remote box where the user would
/// never find it. `runHermes` is `@discardableResult` and the result was
/// dropped, so the user saw nothing at all — no file, no error.
///
/// Post-fix the CLI is asked for the payload on **stdout** (`sessions
/// export -`) and Scarf writes those bytes to the chosen path on this Mac.
/// One code path for local and remote, and every failure is reported.
///
/// The CLI is scripted through the `sessionExportRunner` seam — no
/// subprocess, no SSH round-trip. `beginExport` gates on a real
/// `NSSavePanel`, so these drive `performExport`, which is everything after
/// the panel hands over a URL.
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

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-export-test-\(UUID().uuidString).jsonl")
    }

    /// `performExport` hands the CLI call to a detached task, so poll the
    /// main-actor state rather than assuming it has landed.
    private static func settle(until condition: @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Export asks the CLI for stdout rather than handing it a local path")
    func exportRequestsStdout() async {
        let recorder = ArgvRecorder()
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = SessionsViewModel(context: Self.remoteContext())
        vm.sessionExportRunner = { _, args in
            recorder.record(args)
            return (Data(#"{"id":"abc123"}"#.utf8), "", 0)
        }

        vm.performExport(to: url, sessionId: "abc123")
        await Self.settle(until: { vm.exportMessage != nil })

        // The whole bug: the CLI must never be handed a path that only
        // exists on this Mac. `-` means "write jsonl to stdout".
        #expect(recorder.recorded == [[
            "sessions", "export", "-", "--session-id", "abc123",
        ]])
    }

    @Test("The piped bytes are written verbatim to the chosen file on this Mac")
    func pipedBytesLandOnDisk() async {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = "{\"id\":\"a\"}\n{\"id\":\"b\"}\n"

        let vm = SessionsViewModel(context: Self.remoteContext())
        vm.sessionExportRunner = { _, _ in (Data(payload.utf8), "", 0) }

        vm.performExport(to: url, sessionId: "abc123")
        await Self.settle(until: { vm.exportMessage != nil })

        #expect(FileManager.default.fileExists(atPath: url.path))
        let written = try? String(contentsOf: url, encoding: .utf8)
        #expect(written == payload)
        // Naming the size proves the file isn't the empty one a broken
        // pipe would leave behind.
        #expect(vm.exportMessage?.contains("Exported") == true)
        #expect(vm.exportMessage?.contains(url.path) == true)
    }

    @Test("Export-all omits --session-id so the CLI dumps every session")
    func exportAllOmitsSessionFilter() async {
        let recorder = ArgvRecorder()
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = SessionsViewModel(context: Self.remoteContext())
        vm.sessionExportRunner = { _, args in
            recorder.record(args)
            return (Data("{}".utf8), "", 0)
        }

        vm.performExport(to: url, sessionId: nil)
        await Self.settle(until: { vm.exportMessage != nil })

        #expect(recorder.recorded == [["sessions", "export", "-"]])
    }

    /// Hermes is Python: a crash arrives as a traceback whose *last* line
    /// is the actual error. Reporting the first line just shows the user
    /// "Traceback (most recent call last):" and stack frames.
    @Test("A Python traceback is reduced to its final, meaningful line")
    func tracebackReportsLastLine() async {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let traceback = """
        Traceback (most recent call last):
          File "/home/hermes/.hermes/hermes-agent/venv/bin/hermes", line 10, in <module>
            sys.exit(main())
                     ^^^^^^
        FileNotFoundError: [Errno 2] No such file or directory: '/home/hermes/exports/a.jsonl'
        """

        let vm = SessionsViewModel(context: Self.remoteContext())
        vm.sessionExportRunner = { _, _ in (Data(), traceback, 1) }

        vm.performExport(to: url, sessionId: "abc123")
        await Self.settle(until: { vm.exportMessage != nil })

        #expect(vm.exportMessage == "Export failed: FileNotFoundError: [Errno 2] No such file or directory: '/home/hermes/exports/a.jsonl'")
        // A failed export must not leave a truncated/empty file behind.
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// A transport failure (or a missing local binary) returns exit -1 with
    /// no output at all — the exact shape that made this bug invisible.
    @Test("A silent transport failure still reports the exit code")
    func silentFailureStillReports() async {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = SessionsViewModel(context: Self.remoteContext())
        vm.sessionExportRunner = { _, _ in (Data(), "", -1) }

        vm.performExport(to: url, sessionId: "abc123")
        await Self.settle(until: { vm.exportMessage != nil })

        #expect(vm.exportMessage == "Export failed (exit -1).")
    }

    @Test("An unwritable destination is reported rather than swallowed")
    func unwritableDestinationReports() async {
        let url = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/a.jsonl")

        let vm = SessionsViewModel(context: Self.remoteContext())
        vm.sessionExportRunner = { _, _ in (Data("{}".utf8), "", 0) }

        vm.performExport(to: url, sessionId: "abc123")
        await Self.settle(until: { vm.exportMessage != nil })

        #expect(vm.exportMessage?.hasPrefix("Export failed writing a.jsonl:") == true)
    }
}
