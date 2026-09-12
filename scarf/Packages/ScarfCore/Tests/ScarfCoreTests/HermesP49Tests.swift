import Testing
import Foundation
@testable import ScarfCore

/// P49 — round-5 decisions 9 and 10: two capability flags retired, and the
/// third (`hasContextCompressionCount`) re-documented against the wire.
///
/// The tag walk behind decision 9, re-opened for this phase
/// (`git -C ~/.hermes/hermes-agent show <tag>:acp_adapter/server.py`):
///
/// - `v2026.3.17` (0.3.0, the EARLIEST tag that has `acp_adapter/`):
///   `async def set_session_model(` at **line 466**.
/// - `v2026.3.30` (**0.6.0**, Scarf's supported floor): **line 482**, with a
///   working body (`state.model = model_id`, agent rebuilt, session saved).
/// - `v2026.9.7` (0.21.1, the target): **line 929**.
///
/// So the flag's v0.13 floor was a fiction: it hid the model chip, the
/// project model binding, the Models sidebar entry and the iOS model badge
/// from 0.6.0–0.12 hosts that all have the RPC. A floor below the supported
/// minimum is no floor at all (the P15/P23 rule), so the surfaces are
/// unfloored like `reset` / `context` / `version`.
///
/// Decision 10's walk: `CommandDef("yolo", …)` is absent from
/// `hermes_cli/commands.py` at `v2026.3.30` and first appears at
/// `v2026.4.3:96` (0.7.0), `:181` @ `v2026.9.7` — and `yolo` appears nowhere
/// in `acp_adapter/server.py` at any of those tags. The floor was right and
/// the flag still had no consumer, so it is deleted.
///
/// These are source sweeps by construction: the thing being asserted is that
/// a SYMBOL is gone from every target, which no runtime value can report.
@Suite("P49 · retired capability flags")
struct RetiredCapabilityFlagsP49Tests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/ScarfCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/ScarfCore
            .deletingLastPathComponent()   // …/Packages
            .deletingLastPathComponent()   // …/scarf
            .deletingLastPathComponent()   // repo root
    }

    /// Every target: the Mac app, the shared package, the iOS app, and all
    /// three test trees. A retired flag that survives in a test is the same
    /// build break as one that survives in a view.
    private static let scanRoots = [
        "scarf/scarf",
        "scarf/Packages/ScarfCore/Sources",
        "scarf/Scarf iOS",
        "scarf/scarfTests",
        "scarf/Scarf iOSTests",
        "scarf/Packages/ScarfCore/Tests/ScarfCoreTests",
    ]

    /// This file names both flags in prose, so it would match itself. Exempt
    /// it by FULL PATH, not by basename: `scarf/scarfTests/HermesP49Tests.swift`
    /// has the same basename, and a basename exemption would silently excuse
    /// that file too (P49b).
    private static let ownFilePath = URL(fileURLWithPath: #filePath).standardizedFileURL.path

    private static func swiftFiles(under relative: String) -> [URL] {
        let root = repoRoot.appendingPathComponent(relative)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [URL] = []
        while let url = walker.nextObject() as? URL {
            if url.pathExtension == "swift" { out.append(url) }
        }
        return out
    }

    private static func isComment(_ line: String) -> Bool {
        let bare = line.trimmingCharacters(in: .whitespaces)
        return bare.hasPrefix("//") || bare.hasPrefix("*")
    }

    /// Blank out double-quoted string literals before matching. A sibling
    /// source-sweep suite spells a retired flag inside a `#expect(...)`
    /// string — that is an assertion ABOUT the flag's absence, not a
    /// consumer of it, and must not trip this sweep (P49b).
    private static func strippingStringLiterals(_ line: String) -> String {
        var out = ""
        var inString = false
        var escaped = false
        for ch in line {
            if escaped { escaped = false; continue }
            if ch == "\\" && inString { escaped = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if !inString { out.append(ch) }
        }
        return out
    }

    /// Non-comment hits for `needle` across every scanned target, as
    /// `path:line` strings. Comment lines are exempt so the retirement NOTEs
    /// left behind in `HermesCapabilities.swift` (which are the record of the
    /// tag walk, and the reason a future phase does not have to redo it) do
    /// not fail their own sweep.
    static func codeHits(for needle: String) -> [String] {
        var hits: [String] = []
        for root in scanRoots {
            for file in swiftFiles(under: root)
            where file.standardizedFileURL.path != ownFilePath {
                guard let source = try? String(contentsOf: file, encoding: .utf8),
                      source.contains(needle) else { continue }
                for (idx, line) in source.components(separatedBy: "\n").enumerated()
                where !isComment(line) && strippingStringLiterals(line).contains(needle) {
                    hits.append("\(file.lastPathComponent):\(idx + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return hits
    }

    @Test("decision 9: no code anywhere still reads hasACPSetSessionModel")
    func setSessionModelFlagIsGone() {
        let hits = Self.codeHits(for: "hasACPSetSessionModel")
        #expect(hits.isEmpty, "still gated on the retired flag: \(hits)")
    }

    @Test("decision 10: no code anywhere still reads hasYOLOSlashCommand")
    func yoloFlagIsGone() {
        let hits = Self.codeHits(for: "hasYOLOSlashCommand")
        #expect(hits.isEmpty, "still references the deleted flag: \(hits)")
    }

    /// The declarations themselves — the sweep above would pass if a flag
    /// were declared but simply unread, which is what `hasYOLOSlashCommand`
    /// already was. Both must be gone from the capability surface.
    @Test("neither flag is declared in HermesCapabilities")
    func neitherFlagIsDeclared() throws {
        let file = Self.repoRoot.appendingPathComponent(
            "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(!source.contains("var hasACPSetSessionModel"))
        #expect(!source.contains("var hasYOLOSlashCommand"))
        // The retirement record survives, so the next phase inherits the walk
        // instead of repeating it.
        #expect(source.contains("v2026.3.30"))
    }

    /// The sibling flags that shared `hasYOLOSlashCommand`'s "kept, no
    /// consumer" rationale must not be left pointing at a deleted symbol —
    /// a dangling ``doc link`` is exactly the stale citation C2 exists to
    /// stop.
    @Test("no doc comment still links the deleted flag")
    func noDocLinksTheDeletedFlag() throws {
        let file = Self.repoRoot.appendingPathComponent(
            "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(!source.contains("``hasYOLOSlashCommand``"))
    }

    /// Behavioural floor check on the flags that stayed: retiring two members
    /// of the v0.13/v0.14 groups must not have moved anyone else.
    @Test("the surviving v0.13 and v0.14 floors are unchanged")
    func survivingFloorsUnchanged() {
        let v012 = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")
        let v013 = HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)")
        let v014 = HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.5.16)")
        #expect(!v012.hasContextCompressionCount)
        #expect(v013.hasContextCompressionCount)
        #expect(!v013.hasSessionsSlashCommand)
        #expect(v014.hasSessionsSlashCommand)
        #expect(v014.hasCodexRuntimeSlashCommand)
    }
}

/// P49 — `hasContextCompressionCount` gates a field Hermes has never sent.
///
/// The `session/prompt` response's `Usage` is built from five keys at every
/// tag, re-opened for this phase:
///
/// - `v2026.3.30` (0.6.0) `acp_adapter/server.py:325-336` — `prompt_tokens`,
///   `completion_tokens`, `total_tokens`, `reasoning_tokens`, `cached_tokens`.
/// - `v2026.5.7` (0.13.0, the flag's claimed floor) `:1050-1059` — same five,
///   with `cache_read_tokens` replacing `cached_tokens`.
/// - `v2026.9.7` (0.21.1) `:917-924` — the same five.
///
/// No compression count on any of them. The plumbing stays (a future
/// gateway/`session/update` path is the landing pad, and the chip's `> 0`
/// test means a never-sent field renders nothing), but the doc comments must
/// state the fact rather than an unresolved question.
@Suite("P49 · the compression count is not on the ACP wire")
struct CompressionCountCitationP49Tests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("the open question in ACPClient is replaced by the cited answer")
    func acpClientTODOIsResolved() throws {
        let source = try Self.source("scarf/Packages/ScarfCore/Sources/ScarfCore/ACP/ACPClient.swift")
        #expect(!source.contains("TODO(WS-8-Q1)"))
        #expect(source.contains("acp_adapter/server.py:325-336"))
        #expect(source.contains(":917-924"))
        // The tolerant decode itself is deliberately NOT removed.
        #expect(source.contains("compressionCount"))
        #expect(source.contains("compression_count"))
    }

    @Test("the flag's doc comment states the absence with its citations")
    func flagDocStatesTheAbsence() throws {
        let source = try Self.source(
            "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift")
        let doc = try #require(source.range(of: "hasContextCompressionCount").map {
            String(source[source.startIndex..<$0.lowerBound].suffix(1400))
        })
        #expect(doc.contains("Never reaches Scarf over ACP"))
        #expect(doc.contains("v2026.5.7"))
        #expect(doc.contains("v2026.9.7"))
    }

    @Test("the view model doc no longer promises a server-side total")
    func viewModelDocStatesTheAbsence() throws {
        let source = try Self.source(
            "scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift")
        #expect(source.contains("Always 0 over ACP today"))
    }
}

/// P49 — the light re-walk of the remaining MARK groups (the follow-on the
/// round-5 report asked for). Two flags were sampled per group and each was
/// opened at its floor tag and the tag before it. Eighteen of twenty were
/// correct; the two that were not both sat in the v0.16 group, and both are
/// consumer-free, so correcting them is a floor/doc change with no rendering
/// consequence on any host.
///
/// - `hermes insights`: `def cmd_insights(args)` is `hermes_cli/main.py:4634`
///   at **v2026.3.30 = 0.6.0**, Scarf's supported minimum (registered `:4627`,
///   verb list `:3291`). A floor below the minimum is no floor at all, so
///   `hasInsightsCommand` is deleted.
/// - `hermes dashboard`: `def cmd_dashboard(args)` is `hermes_cli/main.py:4458`
///   at **v2026.4.13 = 0.9.0** (`:4180`, `:5978` register it) and the string
///   `dashboard` is absent from that file at v2026.4.8 = 0.8.0. So
///   `hasDashboardCommand` re-floors from 0.16 to 0.9.
@Suite("P49 · v0.16 group re-walk")
struct V016GroupRewalkP49Tests {

    @Test("hasDashboardCommand is on for every host from v0.9.0 up")
    func dashboardFloorIsV09() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.9.0 (2026.4.13)").hasDashboardCommand)
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.8.0 (2026.4.8)").hasDashboardCommand)
        // The old v0.16 floor was false for six releases of hosts that have
        // the verb; this is the case that proves the re-floor.
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)").hasDashboardCommand)
        // A failed probe still reports nothing.
        #expect(!HermesCapabilities.empty.hasDashboardCommand)
    }

    @Test("hasInsightsCommand is gone, and nothing reads it")
    func insightsFlagIsGone() {
        let hits = RetiredCapabilityFlagsP49Tests.codeHits(for: "hasInsightsCommand")
        #expect(hits.isEmpty, "still references the deleted flag: \(hits)")
    }

    @Test("the group's other members keep their verified v0.16 floor")
    func siblingsUnmoved() {
        let v015 = HermesCapabilities.parseLine("Hermes Agent v0.15.2 (2026.5.29)")
        let v016 = HermesCapabilities.parseLine("Hermes Agent v0.16.0 (2026.6.5)")
        #expect(!v015.hasSessionsOptimize)
        #expect(!v015.hasKanbanGoalMode)
        #expect(v016.hasSessionsOptimize)
        #expect(v016.hasKanbanGoalMode)
    }
}
