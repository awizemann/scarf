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
        #expect(code.contains("HermesBackupVerdict.argv(capabilities: capabilities)"))
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
    /// already had it. `rename` is the fourth (P54b): TWO plain positionals,
    /// `old_name` (`:77`) and `new_name` (`:79`), with no list-valued option
    /// behind them, so P47's rule applies to it too and P54 edited the line
    /// without adding the separator.
    @Test func everyProfilePositionalCarriesTheSeparator() throws {
        let code = P54Source.codeOnly(
            try P54Source.read("scarf/Features/Profiles/ViewModels/ProfilesViewModel.swift"))
        for fragment in [
            "[\"profile\", \"show\", \"--\", profile.name]",
            "[\"profile\", \"use\", \"--\", profile.name]",
            "[\"profile\", \"import\", \"--\", path]",
            "[\"profile\", \"rename\", \"--\", profile.name, newName]",
        ] {
            #expect(code.contains(fragment), "missing separator: \(fragment)")
        }
        // The unseparated spellings are gone.
        #expect(!code.contains("[\"profile\", \"show\", profile.name]"))
        #expect(!code.contains("[\"profile\", \"use\", profile.name]"))
        #expect(!code.contains("[\"profile\", \"import\", path]"))
        #expect(!code.contains("[\"profile\", \"rename\", profile.name, newName]"))
    }

    /// Every `runAndReload` success word in the Profiles pane reaches the
    /// banner through `String(localized:)`. Extraction is a compile-time
    /// scan of the LITERAL, so a bare `"Renamed"` could never be extracted
    /// at all, no matter what the parameter's type said.
    ///
    /// **The wrap is necessary and NOT sufficient** (P54b): a wrapped key
    /// with no row in `Localizable.xcstrings` still renders its English
    /// source on every locale — which is what all twenty-two of P54's new
    /// keys did until `everyP54BannerKeyHasACatalogueRow` was written. This
    /// test proves the call site; that one proves the catalogue.
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
        // P54b: the seal is three-state now, so the paint is one helper
        // keyed on `confidence` rather than a two-way read of `succeeded`.
        #expect(code.contains("self.applyConfidence(outcome.confidence)"))
        #expect(code.contains("messageIsError = confidence == .failed"))
        #expect(code.contains("messageIsUnconfirmed = confidence == .unconfirmed"))
        #expect(!code.contains("messageIsError = !outcome.succeeded"))
        for bare in ["= \"Test fired", "= \"Test failed\"", "? success : \"Failed\""] {
            #expect(!code.contains(bare), "unlocalized/exit-code banner survives: \(bare)")
        }
    }
}

// MARK: - P54b — the catalogue, the iOS COLUMNS prefix and the third seal

/// Every user-facing key P54 wrapped in `String(localized:)` must have a row
/// in `Localizable.xcstrings` with all six shipping locales translated.
///
/// P54 wrapped thirty-four keys and added rows for none of them: the wrap is
/// what makes a literal EXTRACTABLE, but the catalogue is what makes it
/// translated, and Xcode's extraction only runs when someone opens the
/// catalogue in the app target. Thirteen of the thirty-four happened to
/// collide with rows other phases had already added; the other twenty-two
/// shipped English on de/es/fr/ja/pt-BR/zh-Hans.
///
/// The keys are the CATALOGUE spellings, i.e. with the interpolations
/// resolved to their format specifiers (`\(detail)` → `%@`), because that is
/// what `String(localized:)` looks up at run time.
@Suite("P54b · every P54 banner key has a catalogue row")
struct BannerCatalogueP54bTests {

    /// The six locales Scarf ships besides the `en` source.
    static let locales = ["de", "es", "fr", "ja", "pt-BR", "zh-Hans"]

    /// Every key the P54 commits introduced at a `String(localized:)` call
    /// site, in its catalogue spelling.
    static let keys: [String] = [
        "Active profile set to %@ — restart Scarf to refresh.",
        "Backup complete",
        "Backup failed",
        "Backup failed: %@",
        "Backup saved",
        "Backup saved on %@: %@",
        "Collection failed",
        "Deleted %@",
        "Exported",
        "Failed",
        "Failed: %@",
        "Hermes found retired xAI models but wrote no changes. The config still names them — check it by hand.",
        "Imported",
        "Migrated to %@. You may need to restart the gateway.",
        "No retired xAI model to migrate.",
        "Profile '%@' created",
        "Removed",
        "Renamed",
        "Report collected",
        "Restore complete — restart Scarf",
        "Restore failed",
        "Restore failed: %@",
        "Test failed",
        "Test failed: %@",
        "Test fired — %@",
        "Test fired — check logs",
        "Upload complete",
        "Upload failed",
        "Upload partly complete. %@",
        "%@ printed no result. Check the host.",
        "hermes backup printed no result. Check the host.",
        "hermes debug share printed no result. Check the host.",
        "hermes import printed no result. Check the host.",
        "hermes webhook test printed no result. Check the host.",
    ]

    /// `strings` out of the catalogue, decoded once.
    static func catalogue() throws -> [String: Any] {
        let text = try P54Source.read("scarf/Localizable.xcstrings")
        let data = try #require(text.data(using: .utf8))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let unwrapped = try #require(root)
        return try #require(unwrapped["strings"] as? [String: Any])
    }

    @Test func everyP54BannerKeyHasACatalogueRow() throws {
        let strings = try Self.catalogue()
        for key in Self.keys {
            #expect(strings[key] != nil, "no catalogue row for: \(key)")
        }
    }

    @Test func everyP54BannerKeyIsTranslatedInAllSixLocales() throws {
        let strings = try Self.catalogue()
        for key in Self.keys {
            guard let row = strings[key] as? [String: Any] else { continue }
            let localizations = row["localizations"] as? [String: Any] ?? [:]
            for locale in Self.locales {
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String
                let present = (value?.isEmpty == false)
                #expect(present, "\(key) is untranslated in \(locale)")
            }
        }
    }

    /// The calibration floor: if the key list is emptied (or the catalogue
    /// path stops resolving) the two tests above would pass over nothing.
    @Test func theKeyListAndTheCatalogueAreBothNonTrivial() throws {
        #expect(Self.keys.count >= 34, "the P54 key list shrank: \(Self.keys.count)")
        #expect(Set(Self.keys).count == Self.keys.count, "duplicate key in the list")
        let strings = try Self.catalogue()
        #expect(strings.count > 2000, "catalogue looks truncated: \(strings.count) rows")
    }

    /// A planted needle: a key that is NOT in the catalogue must be seen as
    /// missing, so the membership test is really testing membership.
    @Test func aKeyThatIsNotInTheCatalogueIsSeenAsMissing() throws {
        let strings = try Self.catalogue()
        #expect(strings["P54b planted needle — never a real key"] == nil)
    }

    // MARK: - P59 — the list is a list, so scan the file instead

    /// The files whose EVERY `String(localized:)` key must be in the
    /// catalogue, read out of the source rather than retyped here.
    ///
    /// Round-6 P59's finding: `OutcomeMessageBar.spoken(_:)` is the VoiceOver
    /// label for all three seals, and P54b added the third arm —
    /// `String(localized: "No result: \(text)")` — beside the two that
    /// already had rows. `Failed: %@` and `Succeeded: %@` are translated in
    /// six locales; `No result: %@` had no row at all, so the one seal that
    /// exists to say "we do not know" announced itself in English to every
    /// non-English VoiceOver user. A hand-maintained key list cannot catch
    /// that — the key was never added to it — so this reads the file.
    ///
    /// P60 widened the roots to `HermesCLIOutcome.swift`, which is where the
    /// verdict formatters live and where the same gap had opened again:
    /// `HermesMemoryResetVerdict.failureSummary`'s two sentences — added by
    /// P59 when it collapsed the Mac and iOS twins into one formatter — had
    /// no catalogue rows at all, beside four siblings in the same file that
    /// are translated in six locales. Same shape, same cause, one file away.
    static let scannedFiles = [
        "scarf/Features/Common/OutcomeMessageBar.swift",
        "Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift",
    ]

    /// The minimum number of keys each scanned file must yield, so a file
    /// that stopped matching cannot pass over nothing (the P52 lesson about
    /// a sweep that reads zero files). Well under each file's real count.
    static let scannedFileFloor: [String: Int] = [
        "scarf/Features/Common/OutcomeMessageBar.swift": 3,
        "Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift": 5,
    ]

    /// The catalogue spellings a scanned key could have.
    ///
    /// ``localizedKeys(in:)`` writes `%@` for EVERY interpolation, because a
    /// source scan cannot know the interpolated type — but Swift's extractor
    /// can, and it writes `%d` for an `Int32` and `%lld` for an `Int`.
    /// `hermes memory reset exited with status \(exitCode)` is
    /// `…status %d.` in the catalogue, and a scan that insisted on `%@` would
    /// report a row that is right there. So each `%@` is tried as `%@`, `%d`
    /// and `%lld`, and a key matches if ANY spelling has a row. This is a
    /// relaxation of the KEY, never of the requirement: a key with no row
    /// under any spelling still fails, in every one of the six locales.
    static func catalogueSpellings(of key: String) -> [String] {
        let parts = key.components(separatedBy: "%@")
        guard parts.count > 1 else { return [key] }
        // Bounded: three specifiers per slot would be 3^n, so a key with
        // more than three interpolations is only tried as written.
        guard parts.count <= 4 else { return [key] }
        var out = [parts[0]]
        for part in parts.dropFirst() {
            out = out.flatMap { prefix in
                ["%@", "%d", "%lld"].map { prefix + $0 + part }
            }
        }
        return out
    }

    /// Every `String(localized: "…")` literal in `source`, in its CATALOGUE
    /// spelling: `\(foo)` resolved to `%@`, which is what the lookup uses at
    /// run time. Only single-line, single-literal calls are matched — the
    /// shape this file uses — and ``theScanIsCalibrated`` proves the matcher
    /// still finds them.
    static func localizedKeys(in source: String) -> [String] {
        var keys: [String] = []
        var rest = source[source.startIndex...]
        while let open = rest.range(of: "String(localized: \"") {
            var i = open.upperBound
            var key = ""
            var escaped = false
            var closed = false
            while i < rest.endIndex {
                let c = rest[i]
                if escaped {
                    // `\(` opens an interpolation; anything else is a plain
                    // escape and the character itself is the key's.
                    if c == "(" {
                        var depth = 1
                        i = rest.index(after: i)
                        while i < rest.endIndex, depth > 0 {
                            if rest[i] == "(" { depth += 1 }
                            if rest[i] == ")" { depth -= 1 }
                            i = rest.index(after: i)
                        }
                        key += "%@"
                        escaped = false
                        continue
                    }
                    key.append(c)
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    closed = true
                    i = rest.index(after: i)
                    break
                } else if c == "\n" {
                    break
                } else {
                    key.append(c)
                }
                i = rest.index(after: i)
            }
            if closed, !key.isEmpty { keys.append(key) }
            rest = rest[i...]
        }
        return keys
    }

    @Test func theScanIsCalibrated() {
        let planted = #"""
            case .unconfirmed: String(localized: "No result: \(text)")
            case .failure: String(localized: "Failed: \(text)")
            let plain = String(localized: "Exported")
            let quoted = String(localized: "Said \"yes\" to \(name)")
            """#
        let found = Self.localizedKeys(in: planted)
        #expect(found == ["No result: %@", "Failed: %@", "Exported", #"Said "yes" to %@"#],
                Comment(rawValue: "scan found: \(found)"))
    }

    /// The specifier relaxation, planted (P60). Its job is to find the row an
    /// `Int32` interpolation actually has; its job is NOT to let a key with
    /// no row pass.
    @Test func theSpecifierRelaxationIsCalibrated() throws {
        let strings = try Self.catalogue()
        // The real case: the scan writes `%@`, the catalogue holds `%d`.
        let scanned = "hermes memory reset exited with status %@."
        #expect(strings[scanned] == nil, "the `%@` spelling exists — this fixture is stale")
        let resolved = Self.catalogueSpellings(of: scanned).first { strings[$0] != nil }
        #expect(resolved == "hermes memory reset exited with status %d.")
        // A key with no row under ANY spelling still fails.
        let invented = "scarf p60 invented key %@ that no catalogue holds"
        #expect(Self.catalogueSpellings(of: invented).allSatisfy { strings[$0] == nil })
        // A key with no interpolation is tried as written, once.
        #expect(Self.catalogueSpellings(of: "Exported") == ["Exported"])
        #expect(Self.catalogueSpellings(of: "a %@ b %@ c").count == 9)
    }

    @Test func everyScannedFileSKeysAreInTheCatalogue() throws {
        let strings = try Self.catalogue()
        for relative in Self.scannedFiles {
            let keys = Self.localizedKeys(in: try P54Source.read(relative))
            // Premise floor, PER FILE: a file that stopped matching would
            // pass over nothing (the P52 lesson about a sweep that reads zero
            // files), and a shared floor is cleared by the bigger file alone.
            let floor = Self.scannedFileFloor[relative] ?? 3
            #expect(keys.count >= floor, Comment(rawValue:
                "the scan found \(keys.count) keys in \(relative), below the floor of"
                + " \(floor) — the matcher is broken"))
            for key in keys {
                let spelling = Self.catalogueSpellings(of: key).first { strings[$0] != nil }
                #expect(spelling != nil, Comment(rawValue:
                    "no catalogue row for \(key) (in \(relative))"))
                guard let spelling, let row = strings[spelling] as? [String: Any] else { continue }
                let localizations = row["localizations"] as? [String: Any] ?? [:]
                for locale in Self.locales {
                    let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                    #expect((unit?["value"] as? String)?.isEmpty == false, Comment(rawValue:
                        "\(key) is untranslated in \(locale) (in \(relative))"))
                }
            }
        }
    }
}

/// The iOS memory-reset script sets `COLUMNS` before `PATH`.
///
/// `sh` reads a command line's leading `VAR=value` pairs left to right and
/// stops at the first token that is not an assignment, so the width has to
/// lead — after `PATH=` it is still an assignment and still applies, but the
/// invariant the comment states ("the assignment leads, as it must") is the
/// thing a later edit breaks by inserting the command in between. P54 fixed
/// the ordering and shipped no test for it (P54b).
@Suite("P54b · the iOS memory-reset script keeps its width prefix")
struct IOSColumnsPrefixP54bTests {

    @Test func columnsLeadsThePathAssignment() throws {
        let code = P54Source.codeOnly(try P54Source.read("Scarf iOS/Memory/MemoryListView.swift"))
        let needle = "let script = \"COLUMNS=\\(LocalTransport.wideColumns) \""
        #expect(code.contains(needle), "the script no longer starts with COLUMNS=")
        // …and `PATH=` follows it rather than preceding it.
        let columnsIndex = try #require(code.range(of: needle))
        let pathIndex = try #require(code.range(of: "PATH=\\\"$HOME/.local/bin"))
        #expect(columnsIndex.lowerBound < pathIndex.lowerBound,
                "PATH= now precedes COLUMNS= in the composed script")
        // A planted floor: the transport constant is the source of the
        // width, not a literal number.
        #expect(!code.contains("COLUMNS=400 "), "the width was inlined as a literal")
    }
}

/// The shared message bar's seal is three-state (P54b).
///
/// `SettingsViewModel.runBackup`/`runRestore` routed the `.unconfirmed` arm
/// through `showSaveFailure` / `.failure`, so "hermes backup printed no
/// result" — a sentence whose whole point is that nothing was proven —
/// arrived under the red triangle and was announced as "Failed: …". The text
/// was three-state and the seal was two.
@Suite("P54b · the seal has three states, not two")
struct ThreeStateSealP54bTests {

    @Test func theNeutralArmIsNotAFailure() {
        #expect(OutcomeMessage.unconfirmed("x").kind == .unconfirmed)
        #expect(OutcomeMessage.unconfirmed("x").isFailure == false)
        #expect(OutcomeMessage.failure("x").isFailure)
        #expect(OutcomeMessage.success("x").isFailure == false)
    }

    @Test func theThreeSealsAreAllDifferent() {
        let glyphs = [OutcomeMessage.Kind.success, .unconfirmed, .failure]
            .map(OutcomeMessageBar.glyph(for:))
        #expect(Set(glyphs).count == 3, "two seals share a glyph: \(glyphs)")
        #expect(glyphs[1] == "questionmark.circle.fill")
        let tints = [OutcomeMessage.Kind.success, .unconfirmed, .failure]
            .map(OutcomeMessageBar.tint(for:))
        #expect(tints[0] != tints[1])
        #expect(tints[1] != tints[2], "the neutral arm is painted the failure's colour")
    }

    /// The amber arm is the one `MCPServerTestResultView` already uses for
    /// the same verdict — the citation the fix is modelled on.
    @Test func theNeutralTintMatchesTheMCPPaneItIsModelledOn() {
        #expect(OutcomeMessageBar.glyph(for: .unconfirmed)
                == MCPServerTestResultView.glyph(for: .unconfirmed))
    }

    @Test func settingsRoutesTheUnconfirmedArmToTheNeutralSeal() throws {
        let code = P54Source.codeOnly(
            try P54Source.read("scarf/Features/Settings/ViewModels/SettingsViewModel.swift"))
        #expect(code.contains("self.showUnconfirmed(text)"))
        #expect(code.contains("outcome.confidence == .unconfirmed ? .unconfirmed(text) : .failure(text)"))
        // The two-way spellings P54 shipped are gone.
        #expect(!code.contains("self.showSaveFailure(Self.backupFailureSummary(outcome: outcome))"))
        #expect(!code.contains(".failure(Self.restoreFailureSummary(outcome: outcome))"))
    }

    /// A neutral message must not fade: "we do not know" is a thing the user
    /// has to read and act on, exactly like a refusal.
    @Test @MainActor func theNeutralArmDoesNotAutoClear() {
        let host = SealProbe()
        host.applySaveOutcome(.unconfirmed("printed no result"))
        #expect(host.message == "printed no result")
        #expect(host.messageIsUnconfirmed)
        #expect(host.messageIsFailure == false)
        #expect(host.messageKind == .unconfirmed)
        host.dismissMessage()
        #expect(host.message == nil)
        #expect(host.messageIsUnconfirmed == false)
    }

    /// P55b: `PlatformsViewModel.restartBanner` mapped the `.unconfirmed`
    /// verdict to `.success(...)` — the neutral sentence under the GREEN
    /// checkmark, announced as a completed restart. Same two-state bug as
    /// Settings', in the other direction.
    @Test @MainActor func gatewayRestartUnconfirmedIsNotSealedGreen() {
        let unknown = HermesCLIOutcome(
            succeeded: false, detail: nil, warning: nil, confidence: .unconfirmed)
        let banner = PlatformsViewModel.restartBanner(unknown)
        #expect(banner.kind == .unconfirmed)
        #expect(banner.isFailure == false)
        #expect(banner.text == GatewayActionBanner.unconfirmed(.restart, detail: nil))
        // And the proven arms are untouched.
        #expect(PlatformsViewModel.restartBanner(
            HermesCLIOutcome(succeeded: true, detail: nil, warning: nil, confidence: .confirmed)
        ).kind == .success)
        #expect(PlatformsViewModel.restartBanner(
            HermesCLIOutcome(succeeded: false, detail: "no", warning: nil, confidence: .failed)
        ).kind == .failure)
    }

    /// P55b: the two sites that set `message` + `messageIsFailure` by hand
    /// for an in-progress line left `messageIsUnconfirmed` set. It never
    /// auto-clears, so the amber question mark survived onto the next line.
    @Test @MainActor func anInProgressLineClearsTheUnconfirmedFlagToo() {
        let host = SealProbe()
        host.applySaveOutcome(.unconfirmed("printed no result"))
        #expect(host.messageKind == .unconfirmed)
        // What the in-progress sites do, verbatim.
        host.message = "Restarting gateway…"
        host.messageIsFailure = false
        host.messageIsUnconfirmed = false
        #expect(host.messageKind == .success)
    }

    /// …and the shipped sites actually spell it. A source scan because they
    /// are inside `Task.detached` / `MainActor.run` bodies with no
    /// injectable seam.
    ///
    /// Round-6 P59 added `WebhooksViewModel`'s three. That pane keeps its own
    /// `messageIsError`/`messageIsUnconfirmed` pair (it is not an
    /// `OutcomeMessageHosting` conformer) and routes its CLI verdicts through
    /// `applyConfidence`, which sets both — but three banners written by hand
    /// set only `messageIsError`, so an `.unconfirmed` seal from a previous
    /// webhook action, which by design never auto-clears, survived onto the
    /// next line. The flag name differs per pane, which is why the scan takes
    /// it as a parameter instead of assuming one spelling.
    @Test func everyHandWrittenBannerClearsAllThreeFlags() throws {
        for (path, failureFlag, markers) in [
            ("scarf/Features/Platforms/ViewModels/PlatformsViewModel.swift",
             "messageIsFailure",
             ["message = String(localized: \"Restarting gateway…\")"]),
            ("scarf/Features/Plugins/ViewModels/PluginsViewModel.swift",
             "messageIsFailure",
             ["message = String(localized: \"Installing \\(identifier)…\")"]),
            ("scarf/Features/Webhooks/ViewModels/WebhooksViewModel.swift",
             "messageIsError",
             ["self.message = Self.subscribeFailureMessage(result.output)",
              "self.message = \"Subscribed /\\(storedName)\"",
              "Check `hermes webhook list` on the host.\","])
        ] {
            let code = P54Source.codeOnly(try P54Source.read(path))
            for marker in markers {
                let at = try #require(code.range(of: marker),
                                      Comment(rawValue: "banner line moved in \(path): \(marker)"))
                let window = code[at.upperBound...].prefix(400)
                #expect(window.contains("\(failureFlag) = "), Comment(rawValue:
                    "\(path): \(marker) no longer sets \(failureFlag) — the scan is stale"))
                #expect(window.contains("messageIsUnconfirmed = false"), Comment(rawValue:
                    "\(path): \(marker) leaves `messageIsUnconfirmed` set, so an earlier"
                    + " amber question mark survives onto this banner"))
            }
        }
    }

    @Test @MainActor func theKindRecomposesFromTheTwoStoredFlags() {
        let host = SealProbe()
        host.applySaveOutcome(.failure("no"))
        #expect(host.messageKind == .failure)
        host.applySaveOutcome(.success("yes"))
        #expect(host.messageKind == .success)
        #expect(host.messageIsUnconfirmed == false)
    }
}

/// A minimal conformer, so the protocol's own arithmetic is exercised
/// without standing up a feature view model.
@MainActor
private final class SealProbe: OutcomeMessageHosting {
    var message: String?
    var messageIsFailure = false
    var messageIsUnconfirmed = false
}
