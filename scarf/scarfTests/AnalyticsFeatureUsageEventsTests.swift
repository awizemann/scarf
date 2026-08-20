import Foundation
import Testing
import Stats
import StatsTesting
import ScarfCore
@testable import scarf

/// Phase 5 (feature usage & lifecycle) instrumentation. Unlike Phases 3/4,
/// none of these emission sites go through `ScarfCore`'s recorder seam —
/// they're all app-side calls straight into `Analytics.record`, which is a
/// no-op under XCTest (`isSyntheticHost`). So rather than reading a sink,
/// this suite asserts on the pure decision logic and dedupe state the way
/// `AnalyticsChatEventsTests`/`AnalyticsConnectionEventsTests` already do
/// for `analyticsPermissionDecision` / `analyticsErrorKind` — testing the
/// classification, not the delivery.
///
/// Nested inside Phase 3's suite for the same reason Phase 4's is: real
/// `StatsClient`s share one app-id-keyed `UserDefaults` enabled flag, and
/// `.serialized` only covers a suite and its subgroups, not siblings.
extension AnalyticsConnectionEventsTests {

@Suite("Analytics feature usage events", .serialized)
struct AnalyticsFeatureUsageEventsTests {

    // MARK: - section_viewed dedupe

    /// `Analytics.record` is a no-op under XCTest, so these assert on the
    /// process-wide `recordOnce` key set — which is real — rather than on a
    /// sink that never receives anything.
    private static func sectionKeys() -> Set<String> {
        Set(Analytics.recordedOnceKeysForTesting.filter { $0.hasPrefix("section_viewed:") })
    }

    @Test("visiting the same section twice only records once")
    @MainActor
    func sameSectionDedupes() {
        Analytics.resetRecordedOnceForTesting()
        defer { Analytics.resetRecordedOnceForTesting() }

        let coordinator = AppCoordinator()
        // The initializer itself counts as the first visit (every window
        // starts on .dashboard, and a property initializer's default value
        // never runs `didSet`).
        #expect(Self.sectionKeys() == ["section_viewed:dashboard"])

        coordinator.selectedSection = .chat
        #expect(Self.sectionKeys() == ["section_viewed:dashboard", "section_viewed:chat"])

        // Revisit .chat, then re-select .dashboard: neither is a NEW
        // section, so the set must not grow.
        coordinator.selectedSection = .settings
        coordinator.selectedSection = .chat
        coordinator.selectedSection = .dashboard
        #expect(Self.sectionKeys() == [
            "section_viewed:dashboard", "section_viewed:chat", "section_viewed:settings",
        ])
    }

    @Test("visiting two different sections records both")
    @MainActor
    func differentSectionsBothRecord() {
        Analytics.resetRecordedOnceForTesting()
        defer { Analytics.resetRecordedOnceForTesting() }

        let coordinator = AppCoordinator()
        coordinator.selectedSection = .insights
        coordinator.selectedSection = .kanban
        #expect(Self.sectionKeys() == [
            "section_viewed:dashboard", "section_viewed:insights", "section_viewed:kanban",
        ])
    }

    /// The regression the audit caught: the dedupe used to be an instance
    /// property, but `AppCoordinator` is per-window and is rebuilt on every
    /// server/profile switch, and each new one re-reports `.dashboard` from
    /// `init`. A second coordinator must add nothing it has already seen.
    @Test("a second coordinator (new window or server switch) re-reports nothing")
    @MainActor
    func dedupeIsProcessWideAcrossCoordinators() {
        Analytics.resetRecordedOnceForTesting()
        defer { Analytics.resetRecordedOnceForTesting() }

        let first = AppCoordinator()
        first.selectedSection = .logs
        #expect(Self.sectionKeys() == ["section_viewed:dashboard", "section_viewed:logs"])

        // A brand-new window / post-switch coordinator: its `init` re-selects
        // .dashboard and the user walks back to Logs. Both are already-seen
        // facts, so the process-wide set is unchanged.
        let second = AppCoordinator()
        second.selectedSection = .logs
        #expect(Self.sectionKeys() == ["section_viewed:dashboard", "section_viewed:logs"])

        // A genuinely new section still records, from either coordinator.
        second.selectedSection = .cron
        #expect(Self.sectionKeys() == [
            "section_viewed:dashboard", "section_viewed:logs", "section_viewed:cron",
        ])
    }

    @Test("recordOnce reports the first call for a key and nothing after")
    func recordOnceIsOncePerKey() {
        Analytics.resetRecordedOnceForTesting()
        defer { Analytics.resetRecordedOnceForTesting() }

        #expect(Analytics.recordOnce("section_viewed", key: "k", props: ["section": "chat"]) == true)
        #expect(Analytics.recordOnce("section_viewed", key: "k", props: ["section": "chat"]) == false)
        #expect(Analytics.recordOnce("section_viewed", key: "k2") == true)
    }

    // MARK: - section tokens

    @Test("section tokens are stable snake_case, not display copy")
    func sectionTokensAreStableSnakeCase() {
        // The point of the mapping: renaming the sidebar item must not
        // rename the metric.
        #expect(SidebarSection.quickCommands.analyticsToken == "quick_commands")
        #expect(SidebarSection.mcpServers.analyticsToken == "mcp_servers")
        #expect(SidebarSection.credentialPools.analyticsToken == "credential_pools")
        // `.proxy` displays as "Hermes Proxy" and `.gateway` as "Messaging
        // Gateway" — the token follows neither.
        #expect(SidebarSection.proxy.analyticsToken == "proxy")
        #expect(SidebarSection.gateway.analyticsToken == "gateway")

        var seen: Set<String> = []
        for section in SidebarSection.allCases {
            let token = section.analyticsToken
            #expect(token.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil)
            #expect(seen.insert(token).inserted)
        }
    }

    // MARK: - setting_changed key sanitization

    @Test("setting keys pass through as bounded dotted identifiers")
    func settingKeysPassThroughVerbatim() {
        // Every real call site in SettingsViewModel already passes a
        // short, bounded-cardinality dotted path (literal strings, or —
        // for `setAuxiliary` — segments drawn from AuxiliaryTab's fixed
        // task/field pickers, never a text field). The sanitizer's job for
        // these is a no-op.
        #expect(SettingsViewModel.analyticsSettingKey("display.streaming") == "display.streaming")
        #expect(SettingsViewModel.analyticsSettingKey("model.default") == "model.default")
        #expect(SettingsViewModel.analyticsSettingKey("auxiliary.summarization.provider") == "auxiliary.summarization.provider")
    }

    @Test("setting keys never carry a value, and a hypothetical free-typed segment is neutered")
    func settingKeysAreNeverValuesAndCollapseFreeText() {
        // `analyticsSettingKey` takes only the key — there is no parameter
        // through which a value could ride along, so "never the value" is
        // enforced by the function's signature, not just its behavior.
        // This test instead covers the defense-in-depth half: a
        // hypothetical future dynamic segment (a hostname-, path-, or
        // secret-shaped fragment) is neither reproduced verbatim nor
        // allowed to extend the key past three segments.
        let noisy = "auxiliary./Users/someone/secret.txt.hunter2 password!.extra.segment"
        let key = SettingsViewModel.analyticsSettingKey(noisy)
        for fragment in ["/Users", "someone", "secret.txt", "hunter2", "password", "!"] {
            #expect(!key.contains(fragment))
        }
        // At most 3 dot-segments survive, regardless of how many the input had.
        #expect(key.split(separator: ".", omittingEmptySubsequences: false).count <= 3)
    }

    // MARK: - first_run / warm

    @Test("first launch ever reports not warm, and marks itself launched")
    func firstLaunchIsNotWarm() {
        let suiteName = "scarf-analytics-featureusage-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let warm = Analytics.FirstRunMarker.consumeAndMarkLaunched(defaults: defaults)
        #expect(warm == false)
    }

    @Test("a subsequent launch reports warm, not a repeat first_run")
    func subsequentLaunchIsWarm() {
        let suiteName = "scarf-analytics-featureusage-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstWarm = Analytics.FirstRunMarker.consumeAndMarkLaunched(defaults: defaults)
        #expect(firstWarm == false)

        let secondWarm = Analytics.FirstRunMarker.consumeAndMarkLaunched(defaults: defaults)
        #expect(secondWarm == true)
    }

    // MARK: - Buckets

    /// `skills_bootstrapped` replaced a per-skill `skill_installed
    /// {source:"bundled"}` that fired from the unattended launch bootstrap
    /// and drowned the user-driven installs on that same event name.
    @Test("skills_bootstrapped count_bucket covers the taxonomy's three buckets")
    func bootstrapCountBuckets() {
        #expect(SkillBootstrapService.bootstrapCountBucket(1) == "1")
        #expect(SkillBootstrapService.bootstrapCountBucket(2) == "2_5")
        #expect(SkillBootstrapService.bootstrapCountBucket(5) == "2_5")
        #expect(SkillBootstrapService.bootstrapCountBucket(6) == "gt_5")
        #expect(SkillBootstrapService.bootstrapCountBucket(999) == "gt_5")
        // Never called with these, but no input may produce a fourth token.
        #expect(SkillBootstrapService.bootstrapCountBucket(0) == "1")
        #expect(SkillBootstrapService.bootstrapCountBucket(-3) == "1")
    }

    /// The nothing-written case — the steady state on every launch after
    /// the first. A silent run is the whole point of the change, so the
    /// decision is a pure function the test can read directly (
    /// `Analytics.record` is a no-op under XCTest, so a sink can't be).
    @Test("a bootstrap run that wrote nothing emits no event")
    func bootstrapWithNothingWrittenIsSilent() {
        #expect(SkillBootstrapService.bootstrapEventProps(written: 0) == nil)
        #expect(SkillBootstrapService.bootstrapEventProps(written: 1) == ["count_bucket": "1"])
        #expect(SkillBootstrapService.bootstrapEventProps(written: 4) == ["count_bucket": "2_5"])
        #expect(SkillBootstrapService.bootstrapEventProps(written: 9) == ["count_bucket": "gt_5"])
    }

    // MARK: - template_installed / skill_installed source attribution

    /// Locate a shipped `.scarftemplate` to drive the installer VM with.
    nonisolated private static func locateExample(author: String, name: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("templates/\(author)/\(name)/\(name).scarftemplate")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            dir = dir.deletingLastPathComponent()
        }
        throw ProjectTemplateError.requiredFileMissing("templates/\(author)/\(name)/\(name).scarftemplate")
    }

    @MainActor
    private static func awaitPendingSource(_ vm: TemplateInstallerViewModel) async -> String? {
        for _ in 0..<200 {
            if let source = vm.pendingInstallSourceForTesting { return source }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    /// The regression: `installSource` used to be one shared VM property
    /// written at entry and read back at `confirmInstall()`, so a second
    /// entry point landing while the first install was still in flight
    /// re-attributed the first install to the second's source. The token
    /// now rides the pending-install state, published in the same step as
    /// the inspection it describes.
    @Test("each install keeps its own source when a second entry interleaves")
    @MainActor
    func perInstallSourceSurvivesInterleavedEntry() async throws {
        let bundle = try Self.locateExample(author: "awizemann", name: "hackernews-digest")
        let vm = TemplateInstallerViewModel(context: .local)
        defer { vm.cancel() }

        // Entry A: a catalog pick.
        vm.openLocalFile(bundle, source: "hub")
        #expect(await Self.awaitPendingSource(vm) == "hub")

        // Entry B lands while A is still awaiting confirmation: A's pending
        // state (source included) is dropped wholesale rather than leaving
        // a stale token behind for B — or B's token in front of A's bundle.
        vm.openLocalFile(bundle, source: "url")
        #expect(vm.pendingInstallSourceForTesting == nil)
        #expect(await Self.awaitPendingSource(vm) == "url")
    }

    @Test("server_count_bucket covers the taxonomy's four buckets")
    func serverCountBuckets() {
        #expect(Analytics.serverCountBucket(-1) == "0")
        #expect(Analytics.serverCountBucket(0) == "0")
        #expect(Analytics.serverCountBucket(1) == "1")
        #expect(Analytics.serverCountBucket(2) == "2_5")
        #expect(Analytics.serverCountBucket(5) == "2_5")
        #expect(Analytics.serverCountBucket(6) == "gt_5")
        #expect(Analytics.serverCountBucket(999) == "gt_5")
    }
}

}
