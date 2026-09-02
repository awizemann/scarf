import Testing
import ScarfCore
@testable import scarf

/// The name→profile-id slug behind the create sheet's auto-derivation
/// (a required id field could sit above the fold, leaving Create silently
/// disabled — the derivation makes the common path work without ever
/// seeing the field).
@Suite struct BotEditorSheetDerivationTests {

    @Test func slugsSpacedTitleCase() {
        #expect(BotEditorSheet.derivedProfileId(from: "SEO Research Bot") == "seo-research-bot")
    }

    @Test func preservesDashesAndUnderscores() {
        #expect(BotEditorSheet.derivedProfileId(from: "deploy_bot-v2") == "deploy_bot-v2")
    }

    @Test func collapsesPunctuationRunsToOneDash() {
        #expect(BotEditorSheet.derivedProfileId(from: "Ops!!! & Infra") == "ops-infra")
    }

    @Test func trimsLeadingAndTrailingSeparators() {
        #expect(BotEditorSheet.derivedProfileId(from: "  (Research)  ") == "research")
        #expect(BotEditorSheet.derivedProfileId(from: "!!!") == "")
    }

    @Test func emptyTitleDerivesEmptyId() {
        #expect(BotEditorSheet.derivedProfileId(from: "") == "")
    }

    @Test func capsAtHermesLimit() {
        let long = String(repeating: "a", count: 200)
        let slug = BotEditorSheet.derivedProfileId(from: long)
        #expect(slug.count == 64)
    }

    @Test func derivedIdsAreAddressableProfiles() {
        for title in ["SEO Research Bot", "Ops!!! & Infra", "deploy_bot-v2", "Ünïcode Bot"] {
            let slug = BotEditorSheet.derivedProfileId(from: title)
            if !slug.isEmpty {
                #expect(BotsService.isAddressableProfile(slug), "\(title) → \(slug)")
            }
        }
    }
}
