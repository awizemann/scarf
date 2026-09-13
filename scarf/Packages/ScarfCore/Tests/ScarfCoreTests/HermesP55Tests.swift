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

    /// `--query-file` is `hermes_cli/_parser.py:308` (in the chat parser's
    /// mutually-exclusive query group at `:302-314`) at `v2026.8.19` = 0.20.5
    /// and absent from that file at `v2026.8.18` = 0.20.4. Every other flag
    /// of the create argv is present at 0.20.5: `-p` `:22`, `--in` `:401`,
    /// `-c` `:412`, `--create-if-missing` `:421`, `-Q` `:379`.
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
