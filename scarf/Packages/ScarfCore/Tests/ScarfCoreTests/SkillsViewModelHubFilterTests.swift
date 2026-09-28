import Testing
import Foundation
@testable import ScarfCore

/// Issue #79 regression, for hosts before v0.21.4. `searchHub()` with
/// `hubSource == "all"` must
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

    /// A v0.21.1 host: the #79 filter is the pre-v0.21.4 behaviour (S10-F2
    /// moved v0.21.4+ onto Hermes's own search; see the tests at the end).
    private func makeViewModel() -> SkillsViewModel {
        let vm = SkillsViewModel(context: .local)
        vm.capabilities = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        return vm
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

    // MARK: - S10-F2: v0.21.4+ searches "All Sources" with Hermes

    /// From v0.21.4 Hermes's search falls back to the registries on an index
    /// miss, so "All Sources" runs `skills search --source all` instead of
    /// filtering the 40 browse rows it happened to have cached.
    @Test func allSourcesUsesTheCLIFromV0214() async throws {
        let json = #"[{"name":"pdf-tools","description":"Work with PDFs","source":"skills-sh","identifier":"skills-sh:acme/pdf-tools","trust_level":"community"}]"#
        let transport = SplitStreamTransport(stdout: json, stderr: "", exitCode: 0)
        let vm = SkillsViewModel(context: .local, transport: transport)
        vm.capabilities = HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)")
        vm.lastBrowseResults = stubBrowse   // holds no "pdf" skill
        vm.hubSource = "all"
        vm.hubQuery = "pdf"
        vm.searchHub()
        for _ in 0..<200 where vm.isHubLoading { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(Array(transport.lastArgs.prefix(2)) == ["skills", "search"])
        #expect(transport.lastArgs.contains("all"))
        #expect(Array(transport.lastArgs.suffix(2)) == ["--", "pdf"])
        #expect(vm.hubResults.map(\.identifier) == ["skills-sh:acme/pdf-tools"])
    }

    /// v0.21.1 (below the floor) with the same cache keeps the client filter
    /// and never shells out.
    @Test func allSourcesKeepsTheFilterBelowV0214() {
        let transport = SplitStreamTransport(stdout: "[]", stderr: "", exitCode: 0)
        let vm = SkillsViewModel(context: .local, transport: transport)
        vm.capabilities = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        vm.lastBrowseResults = stubBrowse
        vm.hubSource = "all"
        vm.hubQuery = "honcho"
        vm.searchHub()
        #expect(vm.hubResults.map(\.identifier) == ["honcho"])
        #expect(transport.lastArgs.isEmpty)
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
