import Testing
import Foundation
@testable import ScarfCore

/// Round-2 whole-surface audit P26 — the two behavioural items folded into an
/// otherwise comment-only citation sweep.
///
/// Everything else in P26 edits doc comments, which the compiler gates. These
/// two were real divergences hiding behind a wrong comment:
///
/// 1. `ModelCatalogService.overlayMetadata(for:)` was the ONE provider
///    resolution path doing a raw-only dictionary hit, so an alias spelling
///    Hermes accepts (`grok-oauth`) returned nil where `providerByID` and
///    `validateModel` both resolve it through `canonicalProviderID`.
/// 2. `PlatformsViewModel.computeConfiguredPlatforms` split top-level lines
///    at `firstIndex(of: ":")` while its own comment claimed it split at the
///    `key: value` separator. `HermesYAML.plainKeySeparatorIndex` is that
///    rule, and is now public so there is one of it. (The VM lives in the Mac
///    target; its end-to-end test is in `scarfTests`. This suite pins the
///    helper's contract, which is what the VM now depends on.)
@Suite struct HermesP26CitationSweepTests {

    // MARK: - overlayMetadata alias fallback

    /// `grok-oauth` is `providerAliases["grok-oauth"] == "xai-oauth"`, and
    /// `xai-oauth` is an `overlayOnlyProviders` key. Before the fix this
    /// returned nil, so `CredentialPoolsOAuthGate` saw no `authType` and
    /// `CredentialPoolsView.keyless` read false for a provider that is in
    /// fact OAuth-only.
    @Test func overlayMetadataResolvesAnAliasSpelling() {
        let svc = ModelCatalogService(path: "/nonexistent-p26-catalog.json")
        // Precondition: the alias and the overlay key are what the test
        // assumes, so a table edit fails here rather than silently passing.
        #expect(ModelCatalogService.providerAliases["grok-oauth"] == "xai-oauth")
        #expect(ModelCatalogService.overlayOnlyProviders["xai-oauth"] != nil)

        let viaAlias = svc.overlayMetadata(for: "grok-oauth")
        let viaCanonical = svc.overlayMetadata(for: "xai-oauth")
        #expect(viaAlias != nil, "an alias spelling must find the canonical overlay")
        #expect(viaAlias?.displayName == viaCanonical?.displayName)
        #expect(viaAlias?.authType == viaCanonical?.authType)
    }

    /// The raw id still wins when it is itself an overlay key — the fallback
    /// must not reroute a provider that resolves directly. `openai-api` is
    /// both an overlay key and an alias-adjacent spelling, and
    /// `canonicalProviderID("openai")` is `openrouter` (which has no
    /// overlay), so a canonical-first lookup would answer differently.
    @Test func overlayMetadataPrefersTheRawID() {
        let svc = ModelCatalogService(path: "/nonexistent-p26-catalog.json")
        let raw = ModelCatalogService.overlayOnlyProviders["openai-api"]
        #expect(raw != nil)
        #expect(svc.overlayMetadata(for: "openai-api")?.displayName == raw?.displayName)
    }

    /// A provider in neither table stays nil — the fallback must not invent
    /// an overlay.
    @Test func overlayMetadataStaysNilForAnUnknownProvider() {
        let svc = ModelCatalogService(path: "/nonexistent-p26-catalog.json")
        #expect(svc.overlayMetadata(for: "not-a-provider-p26") == nil)
    }

    // MARK: - plainKeySeparatorIndex is the one separator rule

    /// The separator is the first colon followed by a SPACE or
    /// end-of-line (P42c narrowed "whitespace" to "space": PyYAML's scanner
    /// refuses a tab after the value indicator), so a colon INSIDE the key
    /// does not truncate it. This is
    /// exactly where `firstIndex(of: ":")` disagrees: it would report the
    /// key as `slack`, inventing a platform the file never configured.
    @Test func plainKeySeparatorSkipsColonsInsideTheKey() throws {
        func key(_ line: String) -> String? {
            guard let i = HermesYAML.plainKeySeparatorIndex(in: line) else { return nil }
            return String(line[line.startIndex..<i])
        }
        #expect(key("slack: {}") == "slack")
        #expect(key("slack:") == "slack")
        #expect(key("slack:  # work") == "slack")
        #expect(key("slack:dev: {}") == "slack:dev")
        #expect(key("llama3:8b: high") == "llama3:8b")
        // No `: ` anywhere: not a `key: value` row at all.
        #expect(key("slack:dev") == nil)
        #expect(key("- slack") == nil)
    }
}
