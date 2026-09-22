import Foundation
import SwiftUI
import Testing
@testable import scarf

/// The Dashboard's per-model breakdown must not claim a window it does not
/// have.
///
/// `HermesDataService.modelUsageSQL` is a bare `GROUP BY model` over the
/// whole of `session_model_usage`, issued with `[]` — no `statsSince` bound
/// and no `sessionListPredicate` (the clause every session listing uses to
/// drop sub-agent, hidden and non-branch child rows). The section sits
/// immediately under the "Last 7 days" stats section, so a bare "By model"
/// read as part of that window while reporting all-time totals.
/// `ScarfCoreTests.HermesV020SchemaTests.modelUsageIgnoresTheStatsWindow`
/// pins the query half; this pins the copy that describes it.
@MainActor
@Suite("Dashboard — the per-model heading names its window")
struct DashboardModelUsageHeadingTests {

    @Test func modelUsageHeadingSaysAllTime() {
        #expect(DashboardView.modelUsageHeading == LocalizedStringKey("By model · all time"))
        #expect(DashboardView.modelUsageHeading != LocalizedStringKey("By model"))
    }

    /// The heading is a catalog key, so the six shipped locales must carry
    /// it — a renamed key with no translations silently ships English.
    @Test func everyShippedLocaleTranslatesTheHeading() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scarf/Localizable.xcstrings")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as! [String: Any]
        let strings = root["strings"] as! [String: Any]
        #expect(strings["By model"] == nil, "the un-windowed key must be gone, not shadowed")
        let entry = try #require(strings["By model · all time"] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        for locale in ["de", "es", "fr", "ja", "pt-BR", "zh-Hans"] {
            let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
            let value = unit?["value"] as? String
            #expect(value?.isEmpty == false, "no \(locale) translation for the per-model heading")
        }
    }
}
