import Testing
import Foundation
@testable import scarf
import ScarfCore

/// P7d — Settings/catalog audit fixes (t-3beb5ec1): the model picker's
/// alias-provider blank-open bug, MCP Servers reloading on a capability
/// re-detect, and the MCP test-result glyph's missing VoiceOver label.
///
/// The WhatsApp decline-message key and `compression.threshold_tokens`
/// parsing fixes have their own behavioural tests in ScarfCore
/// (`HermesP20ConfigDefaultsTests`), where `HermesConfig` lives; this suite
/// covers the app-target (`scarf`) half of the audit.
@Suite("P7d settings/catalog audit fixes")
struct HermesP7dSettingsCatalogTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/scarfTests
            .deletingLastPathComponent()   // …/scarf
            .deletingLastPathComponent()   // repo root
    }

    // MARK: - ModelPickerSheet opens blank for alias providers

    private static func provider(_ id: String) -> HermesProviderInfo {
        HermesProviderInfo(providerID: id, providerName: id, envVars: [], docURL: nil, modelCount: 1)
    }

    /// The bug: a saved `model.provider: chatgpt` (an alias, resolved by
    /// Hermes ≥0.21.4 to `openai-codex` —
    /// `HermesCapabilities.hasChatGPTCodexAliases`) is not itself a
    /// `providers` row, so a literal match against the loaded catalog found
    /// nothing and the sheet opened with no provider highlighted and an
    /// empty model column. `canonicalProviderID` recovers the row it should
    /// have matched.
    @Test("an alias spelling with no live row canonicalizes")
    func aliasProviderResolves() {
        let providers = [Self.provider("openai-codex"), Self.provider("anthropic")]
        let caps = HermesCapabilities.parse("Hermes Agent v0.21.4 (2026.1.1)")
        #expect(ModelPickerSheet.resolveInitialProviderID("chatgpt", in: providers, capabilities: caps) == "openai-codex")
    }

    /// `kimi` / `moonshot` are unconditional aliases onto `kimi-for-coding`
    /// (no floor), so the same resolution must work with `.empty`
    /// capabilities too — the sheet does not always have a detected host by
    /// the time `.task` runs.
    @Test("an unconditional alias resolves even with undetected capabilities")
    func unconditionalAliasResolvesWithEmptyCapabilities() {
        let providers = [Self.provider("kimi-for-coding")]
        #expect(ModelPickerSheet.resolveInitialProviderID("kimi", in: providers, capabilities: .empty) == "kimi-for-coding")
        #expect(ModelPickerSheet.resolveInitialProviderID("moonshot", in: providers, capabilities: .empty) == "kimi-for-coding")
    }

    /// A literal match always wins — canonicalization must never redirect a
    /// provider ID that already has its own row.
    @Test("an exact literal match is never redirected")
    func exactMatchWins() {
        let providers = [Self.provider("openai-codex"), Self.provider("chatgpt")]
        let caps = HermesCapabilities.parse("Hermes Agent v0.21.4 (2026.1.1)")
        #expect(ModelPickerSheet.resolveInitialProviderID("chatgpt", in: providers, capabilities: caps) == "chatgpt")
    }

    /// A floor-gated alias (`chatgpt` → `openai-codex`, ≥0.21.4 only) must
    /// NOT resolve below its floor — a pre-0.21.4 host doesn't accept the
    /// alias either, so redirecting the sheet there would highlight a
    /// provider row the on-disk config wouldn't actually mean.
    @Test("a floor-gated alias does not resolve below its floor")
    func floorGatedAliasStaysUnresolvedBelowFloor() {
        let providers = [Self.provider("openai-codex")]
        let caps = HermesCapabilities.parse("Hermes Agent v0.21.3 (2026.1.1)")
        #expect(ModelPickerSheet.resolveInitialProviderID("chatgpt", in: providers, capabilities: caps) == "chatgpt")
    }

    /// An empty `initialProvider` (fresh preflight, no model block yet)
    /// still falls back to the first provider — canonicalization must not
    /// change that path.
    @Test("an empty initial provider still falls back to the first row")
    func emptyInitialProviderFallsBackToFirst() {
        let providers = [Self.provider("anthropic"), Self.provider("openai-codex")]
        #expect(ModelPickerSheet.resolveInitialProviderID("", in: providers, capabilities: .empty) == "anthropic")
    }

    // MARK: - MCPServersView reloads on a capability re-detect

    /// Source-scan pin (view-model unit tests can't drive a live
    /// `@Environment` change): `MCPServersView` must react to
    /// `capabilitiesStore?.capabilities` changing after the initial
    /// `onAppear` — first connect (async version probe landing late) or a
    /// host upgrade re-detected mid-session — by reloading with `force:
    /// true` and the FRESH capabilities, mirroring the
    /// `HealthView`/`SkillsView` precedent. Without this, every boolish MCP
    /// field (`enabled`, `tools.resources`, `supports_parallel_tool_calls`,
    /// `lazy`) stays parsed against whatever capabilities were in effect
    /// the moment the pane first loaded.
    @Test("MCPServersView reloads when capabilities change after appear")
    func mcpServersViewReloadsOnCapabilityChange() throws {
        let url = Self.repoRoot.appendingPathComponent(
            "scarf/scarf/Features/MCPServers/Views/MCPServersView.swift"
        )
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("onChange(of: capabilitiesStore?.capabilities)"))
        // The reload must be forced (a plain `load()` no-ops once
        // `hasLoaded` has latched — see `MCPServersViewModel.load`'s doc
        // comment) and must pass the NEW capabilities through, not stale
        // ones or `.empty`.
        let onChangeRange = try #require(source.range(of: "onChange(of: capabilitiesStore?.capabilities)"))
        let tail = source[onChangeRange.upperBound...].prefix(300)
        #expect(tail.contains("viewModel.load(force: true, capabilities: newValue ?? .empty)"))
    }

    // MARK: - MCP test-result icon accessibility label

    /// The glyph carries `.help` (a hover tooltip) but VoiceOver does not
    /// read tooltips — without an explicit `.accessibilityLabel` the icon
    /// announces its raw SF Symbol name ("checkmark circle fill") instead
    /// of what the test result means.
    @Test("the MCP test-result glyph has an accessibility label")
    func testResultGlyphHasAccessibilityLabel() throws {
        let url = Self.repoRoot.appendingPathComponent(
            "scarf/scarf/Features/MCPServers/Views/MCPServersView.swift"
        )
        let source = try String(contentsOf: url, encoding: .utf8)
        let glyphRange = try #require(source.range(of: "Image(systemName: Self.rowGlyph(for: result.confidence))"))
        let tail = source[glyphRange.upperBound...].prefix(600)
        #expect(tail.contains(".accessibilityLabel(Self.rowHelp(for: result))"))
    }

    // MARK: - Excluded Providers help text no longer claims Scarf filters

    /// The audit finding: the help text claimed Scarf's own model picker
    /// hides excluded providers. It doesn't — `excluded_providers` is read
    /// only by Hermes's own resolution (`hermes_cli/inventory.py:54`,
    /// `main_provider_setup.py:883-889` @ v2026.9.24); `ModelCatalogService`
    /// never references the key. Pin that the corrected text no longer
    /// makes that claim (and that nothing re-adds it) rather than asserting
    /// exact prose, so a future copy edit doesn't spuriously fail this.
    @Test("the excluded-providers help text does not claim Scarf's picker hides them")
    func excludedProvidersHelpTextIsAccurate() throws {
        let url = Self.repoRoot.appendingPathComponent(
            "scarf/scarf/Features/Settings/Views/Tabs/GeneralTab.swift"
        )
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(!source.contains("hidden from model pickers"))
        #expect(source.contains("Scarf's model picker still lists them"))
    }
}
