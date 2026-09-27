import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Blind re-audit B01 / S04-sessions-data-F2: "Export…" on a rotated
/// compression chain covers the whole conversation the row shows, not just
/// the tip segment the row is keyed by.
///
/// - `jsonl`: one `--session-id` export per segment, root first, joined
///   into one JSON Lines file (one session object per line — the shape
///   Hermes's own multi-session JSONL export writes). Like Hermes's JSONL
///   export, each segment holds its live rows only.
/// - `md`/`qmd`: one run with `--lineage logical`
///   (hermes_cli/subcommands/sessions.py:95-96 @ v2026.9.24).
/// - `trace`/`html`: the CLI has no lineage form, so the latest segment is
///   exported and the banner says so.
///
/// The CLI is scripted through `sessionExportRunner`; no subprocess.
@MainActor
@Suite struct SessionExportLineageB01Tests {

    final class Recorder: @unchecked Sendable {
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

    private static let chain = ["root", "mid", "tip"]

    private static func tempURL(_ ext: String = "jsonl") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b01-export-\(UUID().uuidString).\(ext)")
    }

    private static func settle(until condition: @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func sessionId(in args: [String]) -> String? {
        args.firstIndex(of: "--session-id").map { args[$0 + 1] }
    }

    @Test func jsonlExportsEverySegmentRootFirst() async throws {
        let recorder = Recorder()
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = SessionsViewModel(context: .local)
        vm.sessionExportRunner = { _, args in
            recorder.record(args)
            let id = Self.sessionId(in: args) ?? "?"
            // `mid` arrives without a trailing newline: the join must
            // still keep one object per line.
            let line = id == "mid" ? #"{"id":"mid"}"# : "{\"id\":\"\(id)\"}\n"
            return (Data(line.utf8), "", 0)
        }

        vm.performExport(to: url, sessionId: "tip", format: .jsonl, lineageIds: Self.chain)
        await Self.settle(until: { vm.exportMessage != nil })

        #expect(recorder.recorded == Self.chain.map { ["sessions", "export", "-", "--session-id", $0] })
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written == "{\"id\":\"root\"}\n{\"id\":\"mid\"}\n{\"id\":\"tip\"}\n")
        // Every line is a session object Hermes's JSONL import would read.
        for line in written.split(separator: "\n") {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) is [String: Any])
        }
        #expect(vm.exportMessage?.hasPrefix("Exported") == true)
    }

    @Test func aFailingSegmentFailsTheWholeExportAndWritesNothing() async {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = SessionsViewModel(context: .local)
        vm.sessionExportRunner = { _, args in
            let id = Self.sessionId(in: args) ?? "?"
            // Hermes prints a refusal to stdout and exits 0
            // (`_not_found`, hermes_cli/sessions_cmd.py).
            if id == "mid" { return (Data("Session 'mid' not found.\n".utf8), "", 0) }
            return (Data("{\"id\":\"\(id)\"}\n".utf8), "", 0)
        }

        vm.performExport(to: url, sessionId: "tip", format: .jsonl, lineageIds: Self.chain)
        await Self.settle(until: { vm.exportMessage != nil })

        #expect(vm.exportMessage?.hasPrefix("Export failed") == true)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func anOrdinarySessionStillExportsOnce() async {
        let recorder = Recorder()
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = SessionsViewModel(context: .local)
        vm.sessionExportRunner = { _, args in
            recorder.record(args)
            return (Data(#"{"id":"solo"}"#.utf8), "", 0)
        }
        vm.performExport(to: url, sessionId: "solo", format: .jsonl, lineageIds: [])
        await Self.settle(until: { vm.exportMessage != nil })
        #expect(recorder.recorded == [["sessions", "export", "-", "--session-id", "solo"]])
    }

    @Test func traceExportsTheTipAndSaysSo() async {
        let recorder = Recorder()
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = SessionsViewModel(context: .local)
        vm.sessionExportRunner = { _, args in
            recorder.record(args)
            return (Data(#"{"type":"user"}"#.utf8), "", 0)
        }
        vm.performExport(to: url, sessionId: "tip", format: .trace, redact: true, lineageIds: Self.chain)
        await Self.settle(until: { vm.exportMessage != nil })
        #expect(recorder.recorded.count == 1)
        #expect(Self.sessionId(in: recorder.recorded.first ?? []) == "tip")
        #expect(vm.exportMessage?.contains("Only the latest of this conversation's 3 compressed segments") == true)
        // Locally Markdown is offered and is the complete-history format
        // (Hermes's JSONL export leaves out in-place-archived turns).
        #expect(vm.exportMessage?.contains("choose Markdown") == true)
    }

    @Test func remoteTraceNoteNamesJSONLBecauseMarkdownIsNotOffered() async {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let remote = ServerContext(
            id: ServerID(), displayName: "build-box",
            kind: .ssh(SSHConfig(host: "build-box", user: "jon")))
        let vm = SessionsViewModel(context: remote)
        #expect(!vm.availableExportFormats.contains(.markdown))
        vm.sessionExportRunner = { _, _ in (Data(#"{"type":"user"}"#.utf8), "", 0) }
        vm.performExport(to: url, sessionId: "tip", format: .trace, redact: true, lineageIds: Self.chain)
        await Self.settle(until: { vm.exportMessage != nil })
        #expect(vm.exportMessage?.contains("choose JSONL to export every segment") == true)
    }

    @Test func searchOpenedInternalSessionsSayWhyTheyAreUnlisted() {
        for source in HermesDataService.internalListingSources {
            let note = SessionsViewModel.listingNote(isArchived: false, isListed: false, source: source)
            #expect(note?.contains("kanban worker, tool integration and one-shot") == true, "\(source)")
        }
        #expect(SessionsViewModel.listingNote(isArchived: false, isListed: false, source: "cli")?.contains("subagent") == true)
        #expect(SessionsViewModel.listingNote(isArchived: false, isListed: true, source: "kanban") == nil)
    }

    @Test func markdownPassesLogicalLineage() async {
        let recorder = Recorder()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b01-md-\(UUID().uuidString)", isDirectory: true)
        let vm = SessionsViewModel(context: .local)
        vm.sessionExportRunner = { _, args in
            recorder.record(args)
            return (Data("Exported 1 session (9 messages) to \(dir.path)/tip.md\n".utf8), "", 0)
        }
        vm.performPathExport(to: dir, sessionId: "tip", format: .markdown, redact: false, lineageIds: Self.chain)
        await Self.settle(until: { vm.exportMessage != nil })
        #expect(recorder.recorded == [[
            "sessions", "export", dir.path, "--format", "md", "--session-id", "tip", "--lineage", "logical",
        ]])
        #expect(vm.exportMessage?.contains("Only the latest") == false)
    }

    @Test func htmlExportsTheTipAndSaysSo() async {
        let recorder = Recorder()
        let url = Self.tempURL("html")
        let vm = SessionsViewModel(context: .local)
        vm.sessionExportRunner = { _, args in
            recorder.record(args)
            return (Data("Exported 1 session to \(url.path) (HTML)\n".utf8), "", 0)
        }
        vm.performPathExport(to: url, sessionId: "tip", format: .html, redact: false, lineageIds: Self.chain)
        await Self.settle(until: { vm.exportMessage != nil })
        #expect(recorder.recorded.first?.contains("--lineage") == false)
        #expect(vm.exportMessage?.contains("Only the latest") == true)
    }

    @Test func lineageFlagOnlyForMarkdownAndQuarto() {
        for format in SessionExportFormat.allCases {
            let args = SessionsViewModel.exportArguments(
                output: "/x", sessionId: "tip", format: format, logicalLineage: true)
            #expect(args.contains("--lineage") == format.isDirectoryOutput, "\(format)")
        }
        // Default stays byte-identical to the pre-B01 argv.
        #expect(!SessionsViewModel.exportArguments(output: "/x", sessionId: "tip", format: .markdown).contains("--lineage"))
    }
}
