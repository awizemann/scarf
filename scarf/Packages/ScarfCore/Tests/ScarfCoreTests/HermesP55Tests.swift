import Foundation
import Testing
@testable import ScarfCore

/// P55 — round-6 capability-floor re-walk.
///
/// Three flags were floored above or below the tag that actually carries
/// their surface. Each gets the house four-test group (parse, all-on at the
/// floor, degradation at the tag before, patch-release-still-on), plus the
/// prose tests that pin the doc claims a doc-only fix ships.
@Suite("Hermes P55 — capability floors r6")
struct HermesP55CapabilityFloorTests {

    private func caps(_ line: String) -> HermesCapabilities {
        HermesCapabilities.parseLine(line)
    }

    // MARK: - hasKanban: 0.12 → 0.13

    /// Parse. `hermes_cli/kanban.py` does not exist at `v2026.4.30`
    /// (pyproject = 0.12.0) and `kanban` appears zero times in
    /// `hermes_cli/commands.py` / `hermes_cli/main.py` there; at `v2026.5.7`
    /// (0.13.0) the module exists and `CommandDef("kanban", …)` is
    /// `commands.py:163`.
    @Test("hasKanban — the v0.13.0 version line parses")
    func kanbanFloorParses() {
        let c = caps("Hermes Agent v0.13.0 (2026.5.7)")
        #expect(c.detected)
        #expect(c.semver == HermesCapabilities.SemVer(major: 0, minor: 13, patch: 0))
    }

    @Test("hasKanban — every kanban surface is on at the floor")
    func kanbanAllOnAtFloor() {
        let c = caps("Hermes Agent v0.13.0 (2026.5.7)")
        #expect(c.hasKanban)
        #expect(c.hasKanbanDiagnostics)
    }

    @Test("hasKanban — a 0.12 host degrades, where it used to light up")
    func kanbanDegradesOnV012() {
        let c = caps("Hermes Agent v0.12.0 (2026.4.30)")
        #expect(!c.hasKanban)
        // The rest of the v0.12 group is untouched by the re-floor.
        #expect(c.hasCurator)
        #expect(c.hasOneShot)
        #expect(c.hasSkillURLInstall)
        // And a 0.12.9 patch is still below the floor.
        #expect(!caps("Hermes Agent v0.12.9 (2026.5.1)").hasKanban)
    }

    @Test("hasKanban — a patch above the floor keeps it on")
    func kanbanPatchStillOn() {
        #expect(caps("Hermes Agent v0.13.1 (2026.5.10)").hasKanban)
        #expect(caps("Hermes Agent v0.21.1 (2026.9.7)").hasKanban)
    }

    // MARK: - hasMCPIdentityHeader: 0.20.4 → 0.20.1

    /// `identity_header` (`tools/mcp_tool.py:40`, `:1335`),
    /// `strict_redirect_headers` (`:3035`) and the stdio `cwd=config.get("cwd")`
    /// (`:2705`) all arrive together at `v2026.8.13` = 0.20.1; all three are
    /// absent from that file at `v2026.8.3` = 0.20.0.
    @Test("hasMCPIdentityHeader — the v0.20.1 version line parses")
    func identityHeaderFloorParses() {
        let c = caps("Hermes Agent v0.20.1 (2026.8.13)")
        #expect(c.detected)
        #expect(c.semver == HermesCapabilities.SemVer(major: 0, minor: 20, patch: 1))
    }

    @Test("hasMCPIdentityHeader — on at the 0.20.1 floor")
    func identityHeaderAllOnAtFloor() {
        let c = caps("Hermes Agent v0.20.1 (2026.8.13)")
        #expect(c.hasMCPIdentityHeader)
        #expect(c.isV0201OrLater)
    }

    @Test("hasMCPIdentityHeader — a 0.20.0 host still hides it")
    func identityHeaderDegradesOnV0200() {
        let c = caps("Hermes Agent v0.20.0 (2026.8.3)")
        #expect(!c.hasMCPIdentityHeader)
        #expect(c.isV020OrLater)
    }

    @Test("hasMCPIdentityHeader — every patch above the floor keeps it on")
    func identityHeaderPatchStillOn() {
        // The three releases the re-floor actually changes.
        #expect(caps("Hermes Agent v0.20.2 (2026.8.16)").hasMCPIdentityHeader)
        #expect(caps("Hermes Agent v0.20.3 (2026.8.16.2)").hasMCPIdentityHeader)
        #expect(caps("Hermes Agent v0.20.4 (2026.8.18)").hasMCPIdentityHeader)
        #expect(caps("Hermes Agent v0.21.1 (2026.9.7)").hasMCPIdentityHeader)
    }

    // MARK: - hasBotChatCreationCLI: 0.21 → 0.20.5

    /// `--query-file` is `hermes_cli/_parser.py:307` (its `add_argument(`
    /// line, inside the chat parser's mutually-exclusive query group at
    /// `:303-316`, beside `-q`/`--query` at `:304`) at `v2026.8.19` = 0.20.5
    /// and absent from that file at `v2026.8.18` = 0.20.4. Every other flag
    /// of the create argv is present at 0.20.5: `--in` `:401`, `-c` `:412`,
    /// `--create-if-missing` `:421`, `-Q` `:379`. `-p`/`--profile` is not a
    /// parser argument — it is stripped before argparse, and `:20-23` is the
    /// `PRE_ARGPARSE_INHERITED_FLAGS` relaunch table, not an argument.
    @Test("hasBotChatCreationCLI — the v0.20.5 version line parses")
    func botChatFloorParses() {
        let c = caps("Hermes Agent v0.20.5 (2026.8.19)")
        #expect(c.detected)
        #expect(c.semver == HermesCapabilities.SemVer(major: 0, minor: 20, patch: 5))
    }

    @Test("hasBotChatCreationCLI — on at the 0.20.5 floor, with Bot Mode")
    func botChatAllOnAtFloor() {
        let c = caps("Hermes Agent v0.20.5 (2026.8.19)")
        #expect(c.hasBotChatCreationCLI)
        #expect(c.hasBotMode)
        #expect(c.isV0205OrLater)
    }

    @Test("hasBotChatCreationCLI — a 0.20.4 host keeps the honest refusal")
    func botChatDegradesOnV0204() {
        let c = caps("Hermes Agent v0.20.4 (2026.8.18)")
        #expect(!c.hasBotChatCreationCLI)
        // Reading/messaging an existing Bot Chat is ACP and stays available.
        #expect(c.hasBotMode)
    }

    @Test("hasBotChatCreationCLI — patches and minors above the floor keep it on")
    func botChatPatchStillOn() {
        #expect(caps("Hermes Agent v0.20.6 (2026.8.27)").hasBotChatCreationCLI)
        #expect(caps("Hermes Agent v0.21.0 (2026.8.31)").hasBotChatCreationCLI)
        #expect(caps("Hermes Agent v0.21.1 (2026.9.7)").hasBotChatCreationCLI)
    }

    // MARK: - Undetected hosts

    @Test("an undetected host hides all three re-floored surfaces")
    func emptyHidesEverything() {
        let c = HermesCapabilities.empty
        #expect(!c.hasKanban)
        #expect(!c.hasMCPIdentityHeader)
        #expect(!c.hasBotChatCreationCLI)
    }
}

/// The doc-only halves of P55 (round-6 decisions 4 and 5, plus the
/// `hasHermesAudit` verb name). A prose deliverable is asserted BOTH ways —
/// the wrong text absent, the cited text present — because a test that only
/// checks the new sentence passes on the pre-fix tree (P49b's lesson).
@Suite("Hermes P55 — doc claims")
struct HermesP55DocTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/ScarfCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/ScarfCore
            .deletingLastPathComponent()   // …/Packages
            .deletingLastPathComponent()   // …/scarf
            .deletingLastPathComponent()   // repo root
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private static let capabilitiesPath =
        "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift"

    @Test("hasHermesAudit's doc names `hermes security audit`, never a bare `hermes audit`")
    func hermesAuditDocNamesTheRealVerb() throws {
        let src = try Self.source(Self.capabilitiesPath)
        #expect(src.contains("/// `hermes security audit` — on-demand OSV.dev"))
        #expect(!src.contains("/// `hermes audit` — on-demand OSV.dev"))
        // The floor is unchanged and the walk that proves it is recorded.
        #expect(src.contains("`v2026.5.28` (= **0.15.0**)"))
    }

    @Test("hasGatewayAllowlists' doc carries the 0.12 tag walk, not a bare floor")
    func gatewayAllowlistDocCarriesTheWalk() throws {
        let src = try Self.source(Self.capabilitiesPath)
        #expect(src.contains("**`v2026.4.30`** (= 0.12.0) reads exactly ONE allowlist"))
        #expect(src.contains("Discord's `allowed_channels` (`:770-771`)"))
        #expect(src.contains("`group_allowed_chats`"))
    }

    @Test("the v0.20.4 MARK group no longer claims a genuine v0.20.4 member")
    func markGroupStopsClaimingAGenuineFloor() throws {
        let src = try Self.source(Self.capabilitiesPath)
        #expect(!src.contains("Only\n    // `hasMCPIdentityHeader` is still a genuine v0.20.4 floor."))
        #expect(!src.contains("is still a genuine v0.20.4 floor"))
        #expect(src.contains("no member of this group still has a"))
    }

    @Test("disableAliases' doc names the quoted-vs-bare `off` gap with its tags")
    func disableAliasesDocNamesTheQuotedGap() throws {
        let src = try Self.source(
            "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/PowerSettingsWriter.swift"
        )
        #expect(src.contains("The quoted-vs-bare gap, accepted"))
        #expect(src.contains("`v2026.7.7` (`hermes_constants.py:816`)"))
        #expect(src.contains("`v2026.9.7` (`:885`)"))
        // The decision is to KEEP the alias, so the list must be intact.
        #expect(src.contains(#"public static let disableAliases = ["disabled", "false", "off"]"#))
    }
}

/// Round-6 decision 3: the `/goal` and `/subgoal` optimistic mirrors are
/// gone, and the names take the ordinary-prompt notice on every host.
///
/// The ACP adapter has never dispatched either name at any tag —
/// `_SLASH_COMMANDS` (`acp_adapter/server.py:163-173` @ `v2026.5.7`) and
/// `SlashCommandsMixin._COMMANDS` (`acp_adapter/commands.py:44-66` @
/// `v2026.9.7`) carry nine names each (the rosters are not identical —
/// v2026.5.7 has `compact` where v2026.9.7 has `compress` — but neither
/// has ever carried `goal` or `subgoal`), so an unknown name falls through
/// to the model (`commands.py:94-95`) and the text is a plain prompt.
@Suite("Hermes P55 — /goal and /subgoal are not ACP commands")
struct HermesP55GoalMirrorTests {

    @Test("the notice fires for /goal and /subgoal")
    func noticeFiresForBothNames() throws {
        let goal = try #require(RichChatViewModel.acpUnhandledSlashNotice(name: "goal"))
        let subgoal = try #require(RichChatViewModel.acpUnhandledSlashNotice(name: "subgoal"))
        #expect(goal.contains("/goal"))
        #expect(subgoal.contains("/subgoal"))
        #expect(goal.contains("ordinary prompt"))
        #expect(goal != subgoal)
    }

    @Test("the notice fires for no other name")
    func noticeIsSilentElsewhere() {
        #expect(RichChatViewModel.acpUnhandledSlashNotice(name: nil) == nil)
        #expect(RichChatViewModel.acpUnhandledSlashNotice(name: "steer") == nil)
        #expect(RichChatViewModel.acpUnhandledSlashNotice(name: "queue") == nil)
        #expect(RichChatViewModel.acpUnhandledSlashNotice(name: "compress") == nil)
        #expect(RichChatViewModel.acpUnhandledSlashNotice(name: "new") == nil)
        #expect(RichChatViewModel.acpUnhandledSlashNotice(name: "") == nil)
    }

    /// Capability-free on purpose: there is no host version on which the
    /// adapter answers these names, so the notice must not vary with one.
    @Test("the answer is the same on every host generation")
    func noticeIsCapabilityFree() {
        #expect(RichChatViewModel.acpUnhandledSlashNames == ["goal", "subgoal"])
        // And neither name is in the dispatched non-interruptive roster, on
        // any host — that roster is `steer` + `queue` and nothing else.
        #expect(RichChatViewModel.nonInterruptiveCommands.map(\.name).sorted() == ["queue", "steer"])
        for line in [
            "Hermes Agent v0.12.0 (2026.4.30)",
            "Hermes Agent v0.13.0 (2026.5.7)",
            "Hermes Agent v0.14.0 (2026.5.16)",
            "Hermes Agent v0.21.1 (2026.9.7)"
        ] {
            let caps = HermesCapabilities.parseLine(line)
            #expect(RichChatViewModel.subFloorSlashNotice(name: "goal", capabilities: caps) == nil)
            #expect(RichChatViewModel.subFloorSlashNotice(name: "subgoal", capabilities: caps) == nil)
        }
    }

    /// A typed `/goal` must not be treated as non-interruptive: it burns a
    /// real turn, so the working indicator has to stay on.
    @MainActor
    @Test("/goal and /subgoal are interruptive turns")
    func goalIsAnOrdinaryTurn() {
        let vm = RichChatViewModel(context: .local)
        #expect(!vm.isNonInterruptiveSlash("/goal ship v2.9"))
        #expect(!vm.isNonInterruptiveSlash("/subgoal no regressions"))
        #expect(!vm.isDispatchedNonInterruptiveSlash("/goal ship v2.9"))
        #expect(!vm.isDispatchedNonInterruptiveSlash("/subgoal no regressions"))
    }

    /// The pill/toast state itself is gone — not merely unset. An API that
    /// still exists is an API a later phase re-wires.
    ///
    /// NOT `@MainActor`, and ONE compiled pattern per run. The first version
    /// was both: seventeen `range(of:options: .regularExpression)` calls per
    /// file (each compiling a pattern and bridging the whole file to UTF-16)
    /// over ~600 files took 26 s alone and 30-97 s in the full parallel run —
    /// all of it on the MAIN thread. Every `@MainActor` test that was
    /// mid-flight at that moment (M1ACPTests' `waitFor`, whose 2 s budget
    /// only covers the green path) could not get the main actor back and
    /// timed out. The hazard is the synchronous main-actor hold, not the
    /// scan itself: a sweep that needs no main-actor state must not ask for
    /// it (see `mirrorSweepNeedsNoMainActor`).
    @Test("no goal or subgoal mirror state survives anywhere in the tree")
    func mirrorStateIsGoneFromEveryTarget() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ownPath = URL(fileURLWithPath: #filePath).standardizedFileURL.path
        let matcher = try Self.retiredSymbolMatcher()
        var scanned = 0
        var hits: [String] = []
        for root in [
            "scarf/scarf", "scarf/Packages/ScarfCore/Sources",
            "scarf/Packages/ScarfIOS/Sources", "scarf/Scarf iOS"
        ] {
            let dir = repoRoot.appendingPathComponent(root)
            let walker = try #require(
                FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
            )
            var filesHere = 0
            while let url = walker.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                guard url.standardizedFileURL.path != ownPath else { continue }
                filesHere += 1
                // Comment lines are stripped before matching: a tombstone
                // naming what was removed is the record this phase leaves
                // behind, not a consumer of it (P49b's lesson, applied to
                // comments rather than string literals).
                let body = try String(contentsOf: url, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                for symbol in Self.survivors(of: matcher, in: body).sorted() {
                    hits.append("\(url.lastPathComponent): \(symbol)")
                }
            }
            // Per-root floor: a root that silently resolved to nothing would
            // otherwise make this test vacuously green.
            #expect(filesHere > 0, "no Swift files under \(root)")
            scanned += filesHere
        }
        #expect(scanned > 300, "scanned only \(scanned) files")
        #expect(hits.isEmpty, "retired goal-mirror API survives: \(hits)")
    }

    // Matched on WORD BOUNDARIES, not by substring: `hasGoal` is a retired
    // iOS strand while `hasGoals` is the live capability flag, and a
    // `contains` sweep cannot tell them apart (P55b).
    static let retiredSymbols = [
        "recordActiveGoal", "recordSubgoalAdded", "recordSubgoalRemoved",
        "recordSubgoalsCleared", "activeGoal", "activeSubgoals", "parseGoalArgument",
        "parseSubgoalArgument", "truncatedToastGoal", "HermesActiveGoal",
        "onClearGoal", "goalTooltip",
        // P55b: the write-up claims these went too, so the sweep says so.
        "truncatedGoal", "goalChip", "supportsActiveGoal", "hasGoal",
        "Goal locked"
    ]

    /// Every retired symbol as ONE word-bounded alternation, compiled once.
    static func retiredSymbolMatcher(_ symbols: [String] = retiredSymbols) throws -> NSRegularExpression {
        let alternation = symbols.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try NSRegularExpression(pattern: "\\b(?:\(alternation))\\b")
    }

    /// The retired symbols `body` still spells, in one pass over it.
    static func survivors(of matcher: NSRegularExpression, in body: String) -> Set<String> {
        let ns = body as NSString
        return Set(matcher.matches(in: body, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) })
    }

    /// Calibration (round-6 lesson 7): the SAME matcher the sweep uses must
    /// FIND a planted needle — every one of them, several to a body — and
    /// must NOT confuse `hasGoal` with the live `hasGoals` flag it is a
    /// prefix of.
    @Test("the sweep's matcher finds every planted needle and no near-miss")
    func mirrorSweepMatcherIsCalibrated() throws {
        let matcher = try Self.retiredSymbolMatcher()
        for symbol in Self.retiredSymbols {
            #expect(Self.survivors(of: matcher, in: "x = \(symbol)(y)") == [symbol], "\(symbol)")
        }
        #expect(Self.survivors(of: matcher, in: "let x = hasGoal ?? false") == ["hasGoal"])
        #expect(Self.survivors(of: matcher, in: "public var hasGoals: Bool { true }").isEmpty)
        #expect(Self.survivors(of: matcher, in: "toast(\"Goal locked: x\")") == ["Goal locked"])
        #expect(Self.survivors(of: matcher, in: "goalChipper").isEmpty)
        #expect(Self.survivors(of: matcher, in: "a.activeGoal; b.goalTooltip; hasGoals")
                == ["activeGoal", "goalTooltip"])
    }

    /// The sweep must not hold the main actor. Its body is synchronous, so
    /// `@MainActor` would pin the MAIN THREAD for the whole scan and starve
    /// every other main-actor test in the parallel run. Pinned in source,
    /// because the symptom lands in whichever unrelated suite was mid-flight.
    @Test("the tree sweep is not a main-actor test")
    func mirrorSweepNeedsNoMainActor() throws {
        let source = try String(contentsOfFile: #filePath, encoding: .utf8)
        let marker = "@Test(\"no goal or subgoal mirror state survives anywhere in the tree\")"
        let head = try #require(source.range(of: marker))
        // The attribute lines directly above the marker, comments skipped.
        let preceding = source[..<head.lowerBound].split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .suffix(2)
        #expect(!preceding.contains { $0.contains("@MainActor") }, "\(preceding)")
    }
}
