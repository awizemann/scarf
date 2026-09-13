import Testing
import Foundation
@testable import scarf
import ScarfCore

/// Round-6 P54 — the CLI verdicts at their real call sites, and the
/// three-state rendering each of them needs.
///
/// The verdicts themselves (and their verbatim Hermes fixtures) live in
/// `ScarfCore`'s `HermesP54Tests.swift`. This file proves the halves the
/// package cannot see: that the Mac panes actually CALL them, that every
/// consumer of a three-state verdict has three branches (round-6 lesson 12),
/// and that the banners are localized.
enum P54Source {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // scarfTests
            .deletingLastPathComponent()   // scarf
            .deletingLastPathComponent()   // repo root
    }

    /// `relative` is rooted at `scarf/`, matching the P47 helper.
    static func read(_ relative: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent("scarf").appendingPathComponent(relative),
            encoding: .utf8
        )
    }

    /// Code text with comment-only lines dropped. Every fix in this phase
    /// left a doc comment naming the shape it replaced, and a raw `contains`
    /// would happily match the prose describing the bug.
    static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
    }
}

// MARK: - the call sites

@Suite("P54 · the verdicts are wired at their call sites")
struct CLIVerdictCallSitesP54Tests {

    /// **The HIGH finding.** `hermes import` must carry `--force` (decision
    /// 1) and must be judged by output. The bare argv is what made every
    /// restore into a live Hermes home fail.
    @Test func settingsRestoresWithForceAndJudgesByOutput() throws {
        let code = P54Source.codeOnly(
            try P54Source.read("scarf/Features/Settings/ViewModels/SettingsViewModel.swift"))
        #expect(code.contains("HermesImportVerdict.argv(path: path)"))
        #expect(code.contains("HermesImportVerdict.judge("))
        // The old argv cannot come back under any spelling.
        #expect(!code.contains("[\"import\", path]"))
        #expect(!code.contains("args: [\"import\""))
    }

    /// Decision 1 again, one layer down: there is no stdin pipe anywhere on
    /// the restore path. Answering `y` for the user would be Scarf giving
    /// consent on their behalf, which is what `--force` exists to avoid
    /// having to do.
    @Test func theRestorePathPipesNoStdin() throws {
        let code = P54Source.codeOnly(
            try P54Source.read("scarf/Features/Settings/ViewModels/SettingsViewModel.swift"))
        #expect(!code.contains("Continue?"))
        #expect(!code.contains("\"y\\n\""))
    }

    @Test func settingsJudgesBackupByOutput() throws {
        let code = P54Source.codeOnly(
            try P54Source.read("scarf/Features/Settings/ViewModels/SettingsViewModel.swift"))
        #expect(code.contains("HermesBackupVerdict.argv"))
        #expect(code.contains("HermesBackupVerdict.judge("))
        #expect(!code.contains("args: [\"backup\"]"))
    }

    @Test func webhooksJudgeRemoveAndTestByOutput() throws {
        let code = P54Source.codeOnly(
            try P54Source.read("scarf/Features/Webhooks/ViewModels/WebhooksViewModel.swift"))
        #expect(code.contains("HermesWebhookRemoveVerdict.argv(name: webhook.name)"))
        #expect(code.contains("HermesWebhookTestVerdict.argv(name: webhook.name)"))
        #expect(code.contains("HermesWebhookTestVerdict.judge("))
        // `runAndReload`'s `judge` is the fix, so it takes no default
        // (round-6 lesson 10): a default would let the next verb slide back
        // onto the exit code silently.
        #expect(!code.contains("judge: @escaping @Sendable (String, Int32) -> HermesCLIOutcome ="))
        // And no arm of either verb may still read the exit code.
        #expect(!code.contains("result.exitCode == 0 ?"))
    }

    @Test func healthJudgesDebugShareByOutput() throws {
        let code = P54Source.codeOnly(
            try P54Source.read("scarf/Features/Health/ViewModels/HealthViewModel.swift"))
        #expect(code.contains("HermesDebugShareVerdict.judge("))
        #expect(code.contains("Self.debugShareSummary(outcome: outcome, local: local)"))
    }

    /// The three-state verdict reaches both MCP views now, not just the bool.
    @Test func mcpTestCarriesItsConfidenceOutOfTheService() throws {
        let code = P54Source.codeOnly(
            try P54Source.read("scarf/Core/Services/HermesFileService.swift"))
        #expect(code.contains("confidence: outcome.confidence"))
        // The collapse this phase removed, in its exact old spelling.
        #expect(!code.contains("HermesMCPTestVerdict.judge(output: output, exitCode: result.0).succeeded"))
    }
}

// MARK: - three branches, not two (lesson 12)

@Suite("P54 · every new verdict's consumer renders three states")
struct ThreeStateRenderingP54Tests {

    // MARK: backup

    @Test func backupConfirmedSaysNothingExtra() {
        let outcome = HermesBackupVerdict.judge(
            output: "Backup complete: /tmp/b.zip", exitCode: 0)
        #expect(SettingsViewModel.withNote("Backup saved", outcome.warning) == "Backup saved")
    }

    @Test func backupIncompleteCarriesItsNoteIntoTheBanner() throws {
        let outcome = HermesBackupVerdict.judge(
            output: "Backup incomplete: /tmp/b.zip\n  Warnings (2 files skipped):",
            exitCode: 0)
        let banner = SettingsViewModel.withNote("Backup saved", outcome.warning)
        #expect(banner.hasPrefix("Backup saved "))
        #expect(banner.contains("Warnings (2 files skipped):"))
    }

    /// The third state: exit 0, no marker. Never "Backup failed (exit 0)".
    @Test func backupUnconfirmedNamesSilenceNotAStatus() {
        let outcome = HermesBackupVerdict.judge(output: "", exitCode: 0)
        let text = SettingsViewModel.backupFailureSummary(outcome: outcome)
        #expect(text.contains("printed no result"))
        #expect(!text.contains("exit"))
        #expect(!text.contains("0"))
    }

    @Test func backupFailedQuotesHermesOwnLine() {
        let outcome = HermesBackupVerdict.judge(output: "OSError: disk full", exitCode: 1)
        #expect(SettingsViewModel.backupFailureSummary(outcome: outcome).contains("disk full"))
    }

    // MARK: import

    @Test func restoreUnconfirmedNamesSilence() {
        let outcome = HermesImportVerdict.judge(output: "", exitCode: 0)
        let text = SettingsViewModel.restoreFailureSummary(outcome: outcome)
        #expect(text.contains("printed no result"))
        #expect(!text.contains("exit"))
    }

    /// The pre-`--force` failure, which is now unreachable but must still
    /// read as Hermes's own sentence if it somehow arrives.
    @Test func restoreFailedQuotesHermesOwnLine() {
        let outcome = HermesImportVerdict.judge(output: "Aborted.", exitCode: 1)
        #expect(SettingsViewModel.restoreFailureSummary(outcome: outcome) .contains("Aborted."))
    }

    @Test func restoreWarningRidesTheSuccessBanner() throws {
        let outcome = HermesImportVerdict.judge(
            output: "Import complete: 809 files restored in 4.1s\n  Warnings (3 files skipped):",
            exitCode: 0)
        let banner = SettingsViewModel.withNote("Restore complete — restart Scarf", outcome.warning)
        #expect(banner.contains("Restore complete"))
        #expect(banner.contains(HermesImportVerdict.skippedNote))
    }

    // MARK: webhook test — three branches

    @Test func webhookTestConfirmedKeepsTheHTTPStatus() {
        let outcome = HermesWebhookTestVerdict.judge(
            output: "  Response (200): {\"ok\": true}", exitCode: 0)
        #expect(WebhooksViewModel.testSummary(outcome: outcome).contains("Response (200)"))
    }

    @Test func webhookTestFailedQuotesTheGatewayHint() {
        let outcome = HermesWebhookTestVerdict.judge(
            output: "  Error: connection refused\n  Is the gateway running? (hermes gateway run)",
            exitCode: 0)
        let text = WebhooksViewModel.testSummary(outcome: outcome)
        #expect(text.contains("Is the gateway running?"))
        #expect(!text.contains("exit"))
    }

    @Test func webhookTestUnconfirmedNamesSilence() {
        let outcome = HermesWebhookTestVerdict.judge(output: "", exitCode: 0)
        let text = WebhooksViewModel.testSummary(outcome: outcome)
        #expect(text.contains("printed no result"))
        #expect(!text.contains("Test failed"))
    }

    // MARK: webhook remove — three branches

    @Test func webhookRemoveConfirmedShowsTheSuccessWord() {
        let outcome = HermesWebhookRemoveVerdict.judge(
            output: "  Removed webhook subscription: ci", exitCode: 0)
        #expect(WebhooksViewModel.mutationSummary(
            outcome: outcome, success: "Removed", verb: "hermes webhook remove") == "Removed")
    }

    @Test func webhookRemoveRefusedShowsHermesReason() {
        let outcome = HermesWebhookRemoveVerdict.judge(
            output: "  No subscription named 'ci'.", exitCode: 0)
        let text = WebhooksViewModel.mutationSummary(
            outcome: outcome, success: "Removed", verb: "hermes webhook remove")
        #expect(text.contains("No subscription named 'ci'."))
        #expect(text != "Removed")
    }

    @Test func webhookRemoveUnconfirmedNamesTheVerbAndSilence() {
        let outcome = HermesWebhookRemoveVerdict.judge(output: "", exitCode: 0)
        let text = WebhooksViewModel.mutationSummary(
            outcome: outcome, success: "Removed", verb: "hermes webhook remove")
        #expect(text.contains("hermes webhook remove"))
        #expect(text.contains("printed no result"))
    }

    // MARK: debug share — three branches, twice (local and remote)

    @Test func debugShareConfirmedSaysUploadComplete() {
        let outcome = HermesDebugShareVerdict.judge(
            output: "\nDebug report uploaded:\n  report  https://x/1", exitCode: 0, local: false)
        #expect(HealthViewModel.debugShareSummary(outcome: outcome, local: false) == "Upload complete")
    }

    /// The MED finding's user-visible half: a partial upload must not read
    /// as "Upload complete".
    @Test func debugSharePartialIsNotUploadComplete() {
        let outcome = HermesDebugShareVerdict.judge(
            output: "\nDebug report uploaded:\n  report  https://x/1\n\n  (failed to upload: config)",
            exitCode: 0, local: false)
        let text = HealthViewModel.debugShareSummary(outcome: outcome, local: false)
        #expect(text != "Upload complete")
        #expect(text.contains("config"))
    }

    @Test func debugShareUnconfirmedNamesSilence() {
        let outcome = HermesDebugShareVerdict.judge(output: "", exitCode: 0, local: false)
        let text = HealthViewModel.debugShareSummary(outcome: outcome, local: false)
        #expect(text.contains("printed no result"))
        #expect(!text.contains("exit"))
    }

    @Test func debugShareLocalKeepsItsOwnVoice() {
        let outcome = HermesDebugShareVerdict.judge(output: "raw report", exitCode: 0, local: true)
        #expect(HealthViewModel.debugShareSummary(outcome: outcome, local: true) == "Report collected")
    }

    // MARK: mcp test — three branches in BOTH views (lesson 12)

    @Test(arguments: [
        HermesCLIOutcome.Confidence.confirmed,
        .failed,
        .unconfirmed,
    ])
    func bothMCPViewsGiveEachConfidenceItsOwnGlyph(_ confidence: HermesCLIOutcome.Confidence) {
        // Not an assertion about a particular symbol — an assertion that the
        // three are DISTINCT in both views, which is what a two-way `if`
        // could not deliver.
        let detail = MCPServerTestResultView.glyph(for: confidence)
        let row = MCPServersView.rowGlyph(for: confidence)
        #expect(!detail.isEmpty)
        #expect(!row.isEmpty)
    }

    @Test func theThreeGlyphsAreAllDifferentInBothViews() {
        let all = HermesCLIOutcome.Confidence.allCases
        #expect(Set(all.map(MCPServerTestResultView.glyph(for:))).count == all.count)
        #expect(Set(all.map(MCPServersView.rowGlyph(for:))).count == all.count)
    }
}

/// The gap the first draft of P54 had, and the review found: every
/// `.unconfirmed` fixture in the suite above is the EMPTY string, so the
/// helpers' `confidence == .unconfirmed, (detail ?? "").isEmpty` guard passed
/// every test while being wrong.
///
/// `judge` sets `detail: lines.last` on every arm including `.unconfirmed`,
/// and on a real unconfirmed run that tail is some unrelated progress line —
/// `Scanning ~/.hermes ...`, `Uploading...`, `Sending test POST to …`. The
/// old guard therefore fell through to the FAILURE voice and presented that
/// progress line as Hermes's stated reason for a refusal it never made:
/// "Backup failed: Scanning ~/.hermes ...".
///
/// Every case here feeds exit 0 WITH output that matches no marker.
@Suite("P54 · unconfirmed with output never borrows the failure voice")
struct UnconfirmedWithOutputP54Tests {

    @Test func backupProgressIsNotABackupFailure() {
        let outcome = HermesBackupVerdict.judge(
            output: "Scanning /Users/alan/.hermes ...\nBacking up 812 files ...", exitCode: 0)
        #expect(outcome.confidence == .unconfirmed)
        #expect(outcome.detail == "Backing up 812 files ...")
        let text = SettingsViewModel.backupFailureSummary(outcome: outcome)
        #expect(text.contains("printed no result"))
        #expect(!text.contains("Backing up"))
        #expect(!text.hasPrefix("Backup failed:"))
    }

    @Test func importProgressIsNotARestoreFailure() {
        let outcome = HermesImportVerdict.judge(
            output: "Backup contains 812 files\nImporting 812 files ...", exitCode: 0)
        #expect(outcome.confidence == .unconfirmed)
        let text = SettingsViewModel.restoreFailureSummary(outcome: outcome)
        #expect(text.contains("printed no result"))
        #expect(!text.contains("Importing"))
    }

    @Test func webhookTestProgressIsNotATestFailure() {
        let outcome = HermesWebhookTestVerdict.judge(
            output: "  Sending test POST to http://localhost:8644/webhooks/ci", exitCode: 0)
        #expect(outcome.confidence == .unconfirmed)
        let text = WebhooksViewModel.testSummary(outcome: outcome)
        #expect(text.contains("printed no result"))
        #expect(!text.contains("Sending test POST"))
    }

    @Test func webhookRemoveNoiseIsNotARemovalFailure() {
        let outcome = HermesWebhookRemoveVerdict.judge(
            output: "  4 webhook subscription(s):", exitCode: 0)
        #expect(outcome.confidence == .unconfirmed)
        let text = WebhooksViewModel.mutationSummary(
            outcome: outcome, success: "Removed", verb: "hermes webhook remove")
        #expect(text.contains("printed no result"))
        #expect(!text.hasPrefix("Failed:"))
    }

    @Test func debugShareProgressIsNotAnUploadFailure() {
        let outcome = HermesDebugShareVerdict.judge(
            output: "Collecting debug report...\nUploading...", exitCode: 0, local: false)
        #expect(outcome.confidence == .unconfirmed)
        let text = HealthViewModel.debugShareSummary(outcome: outcome, local: false)
        #expect(text.contains("printed no result"))
        #expect(!text.contains("Uploading"))
        #expect(!text.hasPrefix("Upload failed"))
    }

    /// The `.failed` voice is unaffected — a POSITIVE refusal still quotes
    /// Hermes's own reason. Without this the fix above could have been "never
    /// quote anything", which would lose the reason on real failures.
    @Test func aPositiveRefusalStillQuotesItsReason() {
        let outcome = HermesWebhookRemoveVerdict.judge(
            output: "  No subscription named 'ci'.", exitCode: 0)
        #expect(outcome.confidence == .failed)
        #expect(WebhooksViewModel.mutationSummary(
            outcome: outcome, success: "Removed", verb: "hermes webhook remove")
                .contains("No subscription named 'ci'."))
    }
}

// MARK: - migrate xai's two exit-0 arms

@Suite("P54 · migrate xai tells its two exit-0 arms apart")
struct MigrateXAIArmsP54Tests {

    /// `✓ No retired xAI models in config — nothing to migrate.`
    /// (`hermes_cli/migrate.py:44` @ `v2026.9.7`). Nothing to do, nothing
    /// wrong.
    @Test func nothingToMigrateKeepsItsOldSentence() {
        let out = "  ✓ No retired xAI models in config — nothing to migrate."
        #expect(HealthViewModel.migrateXAISummary(output: out, model: "grok-4")
                == "No retired xAI model to migrate.")
    }

    /// `⚠ No changes written.` (`:74`) — reached ONLY after references WERE
    /// found and the rewrite did not land. The old substring test folded
    /// this into the sentence above, telling the user the opposite of what
    /// happened.
    @Test func noChangesWrittenSaysTheRewriteDidNotLand() {
        let out = """
              ◆ xAI Model Retirement Migration (2026-09-15)
              Found 2 retired xAI model reference(s):
                ⚠ model: grok-2
              ⚠ No changes written.
            """
        let text = HealthViewModel.migrateXAISummary(output: out, model: "grok-2")
        #expect(text != "No retired xAI model to migrate.")
        #expect(text.contains("wrote no changes"))
    }

    /// The two heads are distinct prefixes, so neither fixture can match the
    /// other's branch — the property the old `contains("no changes")` test
    /// lacked.
    @Test func aSuccessfulRewriteNamesTheNewModel() {
        let out = """
              ✓ Backup: /Users/alan/.hermes/config.yaml.2026-09-13.bak
              ✓ Updated 2 slot(s) in /Users/alan/.hermes/config.yaml
            """
        #expect(HealthViewModel.migrateXAISummary(output: out, model: "grok-4-fast")
                .contains("grok-4-fast"))
    }
}

// MARK: - the `--` separators and the localized banners

@Suite("P54 · argv separators and localized banners")
struct SeparatorsAndLocalizationP54Tests {

    /// `profile use|show|import` each take a plain positional
    /// (`hermes_cli/subcommands/profile.py:15-16`, `:65-66`, `:89-90` @
    /// `v2026.9.7`), so all three take the separator — `export` and `delete`
    /// already had it.
    @Test func everyProfilePositionalCarriesTheSeparator() throws {
        let code = P54Source.codeOnly(
            try P54Source.read("scarf/Features/Profiles/ViewModels/ProfilesViewModel.swift"))
        for fragment in [
            "[\"profile\", \"show\", \"--\", profile.name]",
            "[\"profile\", \"use\", \"--\", profile.name]",
            "[\"profile\", \"import\", \"--\", path]",
        ] {
            #expect(code.contains(fragment), "missing separator: \(fragment)")
        }
        // The unseparated spellings are gone.
        #expect(!code.contains("[\"profile\", \"show\", profile.name]"))
        #expect(!code.contains("[\"profile\", \"use\", profile.name]"))
        #expect(!code.contains("[\"profile\", \"import\", path]"))
    }

    /// Every `runAndReload` success word in the Profiles pane reaches the
    /// banner through `String(localized:)`. Extraction is a compile-time
    /// scan of the LITERAL, so a bare `"Renamed"` shipped English on every
    /// locale no matter what the parameter's type said.
    @Test func everyProfileBannerLiteralIsLocalized() throws {
        let code = P54Source.codeOnly(
            try P54Source.read("scarf/Features/Profiles/ViewModels/ProfilesViewModel.swift"))
        // Every `success:` argument must be a `String(localized:` call.
        var scanned = 0
        // Call sites only — `runAndReload`'s own `success: String` parameter
        // declaration matches the needle and is not a banner.
        for line in code.split(separator: "\n")
        where line.contains("success: ") && line.contains("runAndReload(")
            && !line.contains("func ") {
            scanned += 1
            #expect(line.contains("success: String(localized:"), "unlocalized banner: \(line)")
        }
        // A planted floor: if the call sites are renamed away, this test
        // must fail rather than pass over nothing (the calibration rule).
        #expect(scanned >= 5, "expected at least five `success:` call sites, saw \(scanned)")
    }

    /// The Webhooks banners go through `String(localized:)` too, and the
    /// pane now sets `messageIsError` on every path — it never did on the
    /// `runAndReload` one, so a refusal rendered in the SUCCESS colour.
    @Test func webhookBannersAreLocalizedAndColoured() throws {
        let code = P54Source.codeOnly(
            try P54Source.read("scarf/Features/Webhooks/ViewModels/WebhooksViewModel.swift"))
        #expect(code.contains("self.messageIsError = !outcome.succeeded"))
        for bare in ["= \"Test fired", "= \"Test failed\"", "? success : \"Failed\""] {
            #expect(!code.contains(bare), "unlocalized/exit-code banner survives: \(bare)")
        }
    }
}
