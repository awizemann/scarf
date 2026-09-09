import Testing
import Foundation
@testable import ScarfCore

/// Issue #79 regression. `searchHub()` with `hubSource == "all"` must
/// filter the cached browse list client-side (instead of shelling out
/// to `hermes skills search`, which routes through Hermes's
/// centralized index and can miss skills that browse aggregates from
/// non-indexed registries — `honcho` was the user-reported example).
///
/// Source-specific searches keep the CLI path; that's not exercised
/// here because it requires a live `hermes` binary — the existing
/// HermesSkillsHubParser tests cover the parser side.
@Suite("SkillsViewModel hub filter")
@MainActor
struct SkillsViewModelHubFilterTests {

    private func makeViewModel() -> SkillsViewModel {
        SkillsViewModel(context: .local)
    }

    private let stubBrowse: [HermesHubSkill] = [
        HermesHubSkill(
            identifier: "honcho",
            name: "honcho",
            description: "Memory provider for chat-scoped facts.",
            source: "github"
        ),
        HermesHubSkill(
            identifier: "1password",
            name: "1password",
            description: "Set up and use 1Password integration.",
            source: "official"
        ),
        HermesHubSkill(
            identifier: "spotify",
            name: "spotify",
            description: "Spotify skill — playback control via OAuth.",
            source: "official"
        ),
    ]

    @Test func allSourcesFilterMatchesByName() {
        let vm = makeViewModel()
        vm.lastBrowseResults = stubBrowse
        vm.hubSource = "all"
        vm.hubQuery = "honcho"
        vm.searchHub()
        #expect(vm.hubResults.count == 1)
        #expect(vm.hubResults.first?.identifier == "honcho")
        #expect(vm.isHubLoading == false)
        #expect(vm.hubMessage == nil)
    }

    @Test func allSourcesFilterMatchesByDescription() {
        let vm = makeViewModel()
        vm.lastBrowseResults = stubBrowse
        vm.hubSource = "all"
        vm.hubQuery = "OAuth"
        vm.searchHub()
        #expect(vm.hubResults.count == 1)
        #expect(vm.hubResults.first?.identifier == "spotify")
    }

    @Test func allSourcesFilterIsCaseInsensitive() {
        let vm = makeViewModel()
        vm.lastBrowseResults = stubBrowse
        vm.hubSource = "all"
        vm.hubQuery = "HONCHO"
        vm.searchHub()
        #expect(vm.hubResults.count == 1)
        #expect(vm.hubResults.first?.identifier == "honcho")
    }

    @Test func allSourcesFilterEmptyMatchSetsMessage() {
        let vm = makeViewModel()
        vm.lastBrowseResults = stubBrowse
        vm.hubSource = "all"
        vm.hubQuery = "ringtone"
        vm.searchHub()
        #expect(vm.hubResults.isEmpty)
        #expect(vm.hubMessage == "No matches")
    }

    /// Empty query should fall through to `browseHub()`, which on
    /// `.local` with no Hermes installed will set isHubLoading=true
    /// and not block the test. We just assert the early-return guard
    /// kicked in by checking the cache was untouched.
    @Test func emptyQueryFallsThroughToBrowse() {
        let vm = makeViewModel()
        vm.lastBrowseResults = stubBrowse
        vm.hubSource = "all"
        vm.hubQuery = ""
        let cacheBefore = vm.lastBrowseResults
        vm.searchHub()
        #expect(vm.lastBrowseResults == cacheBefore)
    }

    // MARK: - hubSources gating (B3)

    /// `--source` is an argparse `choices=` list: an unknown value is an
    /// exit-2 usage error, not a degraded search. So the picker's roster is
    /// gated at the floor each choice actually entered Hermes, and an
    /// undetected host gets only the choices that have always existed.
    @Test func hubSourcesGatedByHostFloor() {
        let vm = makeViewModel()
        let base = ["all", "official", "skills-sh", "well-known", "github", "clawhub", "lobehub"]

        // Undetected host: exactly what Scarf always offered — no more.
        vm.capabilities = .empty
        #expect(vm.hubSources == base)

        // v0.14: still no `browse-sh`.
        vm.capabilities = HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.5.16)")
        #expect(vm.hubSources == base)

        // v0.15 adds `browse-sh` and nothing else.
        vm.capabilities = HermesCapabilities.parseLine("Hermes Agent v0.15.0 (2026.5.28)")
        #expect(vm.hubSources == base + ["browse-sh"])

        // v0.18 adds the seven provider filters as one block.
        vm.capabilities = HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)")
        #expect(vm.hubSources == base + ["browse-sh", "nvidia", "openai", "anthropic",
                                         "huggingface", "voltagent", "gstack", "minimax"])

        // The target host offers all fifteen — the exact `_SOURCE_CHOICES`
        // list at `hermes_cli/subcommands/skills.py:16-18`, v2026.9.7.
        vm.capabilities = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        #expect(vm.hubSources.count == 15)
        #expect(Set(vm.hubSources) == Set([
            "all", "official", "skills-sh", "well-known", "github", "clawhub", "lobehub",
            "browse-sh", "nvidia", "openai", "anthropic", "huggingface", "voltagent",
            "gstack", "minimax"]))
    }
}
