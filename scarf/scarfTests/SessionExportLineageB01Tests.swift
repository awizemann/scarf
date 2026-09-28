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

    nonisolated private static func sessionId(in args: [String]) -> String? {
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

    /// Hermes's JSONL export writes live rows only, so a session with
    /// compaction-archived turns gets a note pointing at Markdown; the
    /// probe is asked about every segment of a chain.
    @Test func jsonlOfASessionWithArchivedTurnsSaysMarkdownHasTheFullHistory() async {
        final class Asked: @unchecked Sendable { var ids: [String] = [] }
        let asked = Asked()
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = SessionsViewModel(context: .local)
        vm.exportIncludesArchivedTurns = true
        vm.archivedTurnsProbe = { ids in asked.ids = ids; return true }
        vm.sessionExportRunner = { _, args in (Data("{\"id\":\"\(Self.sessionId(in: args) ?? "")\"}\n".utf8), "", 0) }
        vm.performExport(to: url, sessionId: "tip", format: .jsonl, lineageIds: Self.chain)
        await Self.settle(until: { vm.exportMessage != nil })
        #expect(asked.ids == Self.chain)
        #expect(vm.exportMessage?.hasPrefix("Exported") == true)
        #expect(vm.exportMessage?.contains("Export as Markdown for the full history") == true)
    }

    @Test func remoteJSONLNoteNamesTheHostCommand() async {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let remote = ServerContext(
            id: ServerID(), displayName: "build-box",
            kind: .ssh(SSHConfig(host: "build-box", user: "jon")))
        let vm = SessionsViewModel(context: remote)
        vm.exportIncludesArchivedTurns = true
        vm.archivedTurnsProbe = { _ in true }
        vm.sessionExportRunner = { _, _ in (Data(#"{"id":"solo"}"#.utf8), "", 0) }
        vm.performExport(to: url, sessionId: "solo", format: .jsonl)
        await Self.settle(until: { vm.exportMessage != nil })
        #expect(vm.exportMessage?.contains("hermes sessions export <folder> --format md --session-id solo on the host") == true)

        // A chain's earlier segments need --lineage logical.
        let chainVM = SessionsViewModel(context: remote)
        chainVM.exportIncludesArchivedTurns = true
        chainVM.archivedTurnsProbe = { _ in true }
        chainVM.sessionExportRunner = { _, args in (Data("{\"id\":\"\(Self.sessionId(in: args) ?? "")\"}\n".utf8), "", 0) }
        chainVM.performExport(to: url, sessionId: "tip", format: .jsonl, lineageIds: Self.chain)
        await Self.settle(until: { chainVM.exportMessage != nil })
        #expect(chainVM.exportMessage?.contains("--session-id tip --lineage logical") == true)
    }

    /// Before v0.21.5 no format includes archived turns, so the note names
    /// no remedy — for JSONL and for Markdown alike.
    @Test func olderHostsGetTheNoteWithoutAMarkdownRemedy() async {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = SessionsViewModel(context: .local)
        vm.exportIncludesArchivedTurns = false
        vm.archivedTurnsProbe = { _ in true }
        vm.sessionExportRunner = { _, _ in (Data(#"{"id":"solo"}"#.utf8), "", 0) }
        vm.performExport(to: url, sessionId: "solo", format: .jsonl)
        await Self.settle(until: { vm.exportMessage != nil })
        #expect(vm.exportMessage?.contains("leaves them out of every export format") == true)
        #expect(vm.exportMessage?.contains("Markdown") == false)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b01-md-old-\(UUID().uuidString)", isDirectory: true)
        let md = SessionsViewModel(context: .local)
        md.exportIncludesArchivedTurns = false
        md.archivedTurnsProbe = { _ in true }
        md.sessionExportRunner = { _, _ in (Data("Exported 1 session (3 messages) to \(dir.path)/solo.md\n".utf8), "", 0) }
        md.performPathExport(to: dir, sessionId: "solo", format: .markdown, redact: false)
        await Self.settle(until: { md.exportMessage != nil })
        #expect(md.exportMessage?.contains("leaves them out of every export format") == true)
    }

    /// On v0.21.5 Markdown includes the archived turns: no note.
    @Test func currentMarkdownExportHasNoArchivedNote() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b01-md-new-\(UUID().uuidString)", isDirectory: true)
        let md = SessionsViewModel(context: .local)
        md.exportIncludesArchivedTurns = true
        md.archivedTurnsProbe = { _ in true }
        md.sessionExportRunner = { _, _ in (Data("Exported 1 session (3 messages) to \(dir.path)/solo.md\n".utf8), "", 0) }
        md.performPathExport(to: dir, sessionId: "solo", format: .markdown, redact: false)
        await Self.settle(until: { md.exportMessage != nil })
        #expect(md.exportMessage == "Exported to \(dir.path)")
    }

    @Test func noNoteWithoutArchivedTurnsOrForExportAll() async {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = SessionsViewModel(context: .local)
        vm.archivedTurnsProbe = { _ in false }
        vm.sessionExportRunner = { _, _ in (Data(#"{"id":"solo"}"#.utf8), "", 0) }
        vm.performExport(to: url, sessionId: "solo", format: .jsonl)
        await Self.settle(until: { vm.exportMessage != nil })
        #expect(vm.exportMessage?.contains("compaction") == false)

        let all = SessionsViewModel(context: .local)
        all.archivedTurnsProbe = { _ in true }
        all.sessionExportRunner = { _, _ in (Data(#"{"id":"a"}"#.utf8), "", 0) }
        all.performExport(to: url, sessionId: nil, format: .jsonl)
        await Self.settle(until: { all.exportMessage != nil })
        #expect(all.exportMessage?.contains("compaction") == false)
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
