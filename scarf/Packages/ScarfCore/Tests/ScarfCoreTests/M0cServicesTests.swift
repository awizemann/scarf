import Testing
import Foundation
@testable import ScarfCore

/// Exercises the portable Services moved in M0c:
/// `HermesLogService`, `ModelCatalogService`, `ProjectDashboardService`.
///
/// `HermesDataService` is intentionally skipped on Linux — it's gated on
/// `#if canImport(SQLite3)` (the SQLite3 system module doesn't exist on
/// swift-corelibs-foundation). Apple-target CI covers it.
@Suite struct M0cServicesTests {

    // MARK: - HermesLogService

    @Test func logEntryMemberwise() {
        let entry = LogEntry(
            id: 42,
            timestamp: "2026-04-22 12:00:00,000",
            level: .error,
            sessionId: "s1",
            logger: "hermes.agent",
            message: "boom",
            raw: "2026-04-22 12:00:00,000 ERROR [s1] hermes.agent: boom"
        )
        #expect(entry.id == 42)
        #expect(entry.level == .error)
        #expect(entry.sessionId == "s1")
    }

    @Test func logLevelColorsAreStable() {
        // The UI depends on these strings matching SwiftUI colour names.
        #expect(LogEntry.LogLevel.debug.color == "secondary")
        #expect(LogEntry.LogLevel.info.color == "primary")
        #expect(LogEntry.LogLevel.warning.color == "orange")
        #expect(LogEntry.LogLevel.error.color == "red")
        #expect(LogEntry.LogLevel.critical.color == "red")
        #expect(LogEntry.LogLevel.allCases.count == 5)
    }

    @Test func logServiceParsesHermesLogFormat() async throws {
        // Write three lines — one v0.9.0+ format with session tag, one
        // older format without, and one garbage line — into a tmp file
        // and verify readLastLines parses them.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-log-\(UUID().uuidString).log")
        let text = """
        2026-04-22 12:00:00,123 INFO [session_abc] hermes.agent: starting up
        2026-04-22 12:00:01,456 WARNING hermes.gateway: low disk space
        random garbage line with no structure
        """
        try text.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = HermesLogService(context: .local)
        await service.openLog(path: tmp.path)
        defer { Task { await service.closeLog() } }
        let entries = await service.readLastLines(count: 10)
        #expect(entries.count == 3)

        // v0.9.0+ line with session tag
        let tagged = entries[0]
        #expect(tagged.level == .info)
        #expect(tagged.sessionId == "session_abc")
        #expect(tagged.logger == "hermes.agent")
        #expect(tagged.message == "starting up")

        // Older line without session tag — sessionId must be nil, not empty
        let untagged = entries[1]
        #expect(untagged.level == .warning)
        #expect(untagged.sessionId == nil)
        #expect(untagged.logger == "hermes.gateway")

        // Garbage line falls back gracefully — raw == whole line, message == whole line
        let bad = entries[2]
        #expect(bad.timestamp == "")
        #expect(bad.raw == "random garbage line with no structure")
    }

    // MARK: - ModelCatalogService

    @Test func modelInfoDisplayFormatting() {
        let full = HermesModelInfo(
            providerID: "anthropic",
            providerName: "Anthropic",
            modelID: "claude-4.7-opus",
            modelName: "Claude Opus 4.7",
            contextWindow: 1_048_576,
            maxOutput: 32_768,
            costInput: 5.0,
            costOutput: 15.0,
            reasoning: true,
            toolCall: true,
            releaseDate: "2026-04-01"
        )
        #expect(full.id == "anthropic:claude-4.7-opus")
        #expect(full.contextDisplay == "1M")
        #expect(full.costDisplay != nil)

        let big = HermesModelInfo(
            providerID: "p", providerName: "P", modelID: "m", modelName: "M",
            contextWindow: 200_000, maxOutput: nil,
            costInput: nil, costOutput: nil,
            reasoning: false, toolCall: false, releaseDate: nil
        )
        #expect(big.contextDisplay == "200K")
        #expect(big.costDisplay == nil)

        let tiny = HermesModelInfo(
            providerID: "p", providerName: "P", modelID: "m", modelName: "M",
            contextWindow: 500, maxOutput: nil,
            costInput: nil, costOutput: nil,
            reasoning: false, toolCall: false, releaseDate: nil
        )
        #expect(tiny.contextDisplay == "500")

        let unknown = HermesModelInfo(
            providerID: "p", providerName: "P", modelID: "m", modelName: "M",
            contextWindow: nil, maxOutput: nil,
            costInput: nil, costOutput: nil,
            reasoning: false, toolCall: false, releaseDate: nil
        )
        #expect(unknown.contextDisplay == nil)
    }

    @Test func modelCatalogLoadsSyntheticJSON() throws {
        // Write a minimal models_dev_cache.json lookalike and verify
        // loadProviders / loadModels / provider(for:) / model(providerID:modelID:).
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-models-\(UUID().uuidString).json")
        let json = """
        {
          "anthropic": {
            "id": "anthropic",
            "name": "Anthropic",
            "env": ["ANTHROPIC_API_KEY"],
            "doc": "https://anthropic.com",
            "models": {
              "claude-4.7-opus": {
                "name": "Claude Opus 4.7",
                "reasoning": true,
                "tool_call": true,
                "release_date": "2026-04-01",
                "cost": { "input": 5.0, "output": 15.0 },
                "limit": { "context": 1000000, "output": 32768 }
              }
            }
          },
          "openai": {
            "id": "openai",
            "name": "OpenAI",
            "env": ["OPENAI_API_KEY"],
            "doc": null,
            "models": {
              "gpt-5": {
                "name": "GPT-5",
                "reasoning": false,
                "tool_call": true,
                "release_date": null,
                "cost": null,
                "limit": { "context": 200000, "output": null }
              }
            }
          }
        }
        """
        try json.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let svc = ModelCatalogService(path: tmp.path)

        // `loadProviders()` returns the merged result of the parsed catalog
        // + the hardcoded overlay providers (Nous Portal, Codex, …). Filter
        // to the catalog half here so the assertion is independent of the
        // overlay table evolving.
        let providers = svc.loadProviders().filter { !$0.isOverlay }
        #expect(providers.count == 2)
        // Alphabetical by display name → Anthropic, OpenAI.
        #expect(providers[0].providerID == "anthropic")
        #expect(providers[0].modelCount == 1)
        #expect(providers[1].providerID == "openai")

        let anthropicModels = svc.loadModels(for: "anthropic")
        #expect(anthropicModels.count == 1)
        #expect(anthropicModels[0].modelName == "Claude Opus 4.7")
        #expect(anthropicModels[0].reasoning == true)

        // provider(for:) does a full scan.
        #expect(svc.provider(for: "claude-4.7-opus")?.providerID == "anthropic")
        // Slash-prefixed fallback path.
        #expect(svc.provider(for: "openai/gpt-5")?.providerID == "openai")
        // Unknown model → nil.
        #expect(svc.provider(for: "nobody/knows") == nil)

        // model(providerID:modelID:)
        let m = svc.model(providerID: "anthropic", modelID: "claude-4.7-opus")
        #expect(m?.costInput == 5.0)
        #expect(m?.contextWindow == 1_000_000)
        #expect(svc.model(providerID: "anthropic", modelID: "does-not-exist") == nil)
    }

    @Test func modelCatalogHandlesMissingAndMalformedFiles() {
        // Missing or malformed catalog → no crash, no models.dev entries,
        // but the hardcoded overlay providers (Nous Portal, Codex, Qwen,
        // Gemini CLI, Copilot ACP, Arcee) still surface so the picker
        // doesn't go dark when the cache is missing. Assert on the overlay
        // shape rather than `.isEmpty` (which was correct before v2.3
        // baked the overlays into `loadProviders()`).
        let svc = ModelCatalogService(path: "/tmp/scarf-nonexistent-\(UUID().uuidString).json")
        let missing = svc.loadProviders()
        #expect(!missing.isEmpty)
        #expect(missing.allSatisfy { $0.isOverlay })
        #expect(missing.contains { $0.providerID == "nous" && $0.subscriptionGated })
        #expect(svc.loadModels(for: "anthropic").isEmpty)
        #expect(svc.provider(for: "anything") == nil)

        // Malformed JSON → same overlay-only result, no crash, logger.error
        // path exercised.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-bad-\(UUID().uuidString).json")
        try? "not json".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bad = ModelCatalogService(path: tmp.path)
        let badProviders = bad.loadProviders()
        #expect(!badProviders.isEmpty)
        #expect(badProviders.allSatisfy { $0.isOverlay })
    }

    @Test func v014OverlayProvidersAppearInLoadProviders() {
        // No models.dev cache — only overlay providers should surface.
        // xai-oauth + novita are the v0.14 additions and must be present
        // (with the correct subscription-gated flags) so the picker can
        // reach them without a network round-trip.
        let svc = ModelCatalogService(path: "/tmp/scarf-nonexistent-\(UUID().uuidString).json")
        let providers = svc.loadProviders()
        let grok = providers.first { $0.providerID == "xai-oauth" }
        #expect(grok != nil)
        #expect(grok?.providerName == "xAI (SuperGrok)")
        #expect(grok?.subscriptionGated == true)
        #expect(grok?.isOverlay == true)

        let novita = providers.first { $0.providerID == "novita" }
        #expect(novita != nil)
        #expect(novita?.providerName == "NovitaAI")
        #expect(novita?.subscriptionGated == false)
        #expect(novita?.isOverlay == true)
    }

    @Test func providerDisplayNameOverridesRenamesAlibaba() throws {
        // Hermes v0.14 renamed Alibaba Cloud → Qwen Cloud in the picker
        // without changing the wire ID. Scarf mirrors the rename via
        // `providerDisplayNameOverrides` so `loadProviders()` returns
        // "Qwen Cloud" even when the cached models.dev JSON still says
        // "Alibaba".
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let json = #"""
        {
          "alibaba": {
            "id": "alibaba",
            "name": "Alibaba",
            "models": {
              "qwen-turbo": {"name": "Qwen Turbo"}
            }
          }
        }
        """#
        try json.write(to: tmp, atomically: true, encoding: .utf8)
        let svc = ModelCatalogService(path: tmp.path)

        // Provider list reflects the rename.
        let alibaba = svc.loadProviders().first { $0.providerID == "alibaba" }
        #expect(alibaba?.providerName == "Qwen Cloud")

        // Model rows under the renamed provider also see the rename, so
        // any "Provider · Model" label in the picker is consistent.
        let models = svc.loadModels(for: "alibaba")
        #expect(models.count == 1)
        #expect(models.first?.providerName == "Qwen Cloud")

        // Wire ID stays `alibaba` — Hermes still accepts it.
        #expect(svc.provider(for: "qwen-turbo")?.providerID == "alibaba")
    }

    @Test func validateModelAcceptsCatalogHit() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let json = #"""
        {
          "deepseek": {
            "id": "deepseek",
            "name": "DeepSeek",
            "models": {
              "deepseek-v4-flash": {"name": "DeepSeek v4 Flash"},
              "deepseek-v4-pro": {"name": "DeepSeek v4 Pro"}
            }
          }
        }
        """#
        try json.write(to: tmp, atomically: true, encoding: .utf8)
        let svc = ModelCatalogService(path: tmp.path)
        #expect(svc.validateModel("deepseek-v4-flash", for: "deepseek") == .valid)
    }

    @Test func validateModelRejectsMissingModelWithSuggestions() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let json = #"""
        {
          "deepseek": {
            "id": "deepseek",
            "name": "DeepSeek",
            "models": {
              "deepseek-v4-flash": {"name": "DeepSeek v4 Flash"},
              "deepseek-v4-pro": {"name": "DeepSeek v4 Pro"}
            }
          }
        }
        """#
        try json.write(to: tmp, atomically: true, encoding: .utf8)
        let svc = ModelCatalogService(path: tmp.path)
        // The exact bug from pass-1: Anthropic-style model ID under
        // deepseek provider.
        let result = svc.validateModel("claude-haiku-4-5-20251001", for: "deepseek")
        guard case let .invalid(providerName, suggestions) = result else {
            Issue.record("Expected .invalid, got \(result)")
            return
        }
        #expect(providerName == "DeepSeek")
        // No prefix match on "cla" so we fall through to the first-5
        // suggestion fallback; both entries are present.
        #expect(suggestions.count == 2)
    }

    @Test func validateModelReportsUnknownProviderWhenNoCatalogEntry() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Empty catalog — provider "openai" won't be found + isn't
        // overlay-only, so should return .unknownProvider.
        try "{}".write(to: tmp, atomically: true, encoding: .utf8)
        let svc = ModelCatalogService(path: tmp.path)
        let result = svc.validateModel("gpt-5", for: "openai")
        if case .unknownProvider(let pid) = result {
            #expect(pid == "openai")
        } else {
            Issue.record("Expected .unknownProvider, got \(result)")
        }
    }

    @Test func validateModelAcceptsOverlayProvidersWithoutCatalog() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "{}".write(to: tmp, atomically: true, encoding: .utf8)
        let svc = ModelCatalogService(path: tmp.path)
        // Nous is an overlay-only provider — any non-empty string is
        // accepted because the overlay has no local catalog mirror.
        #expect(svc.validateModel("deepseek/deepseek-v4-flash", for: "nous") == .valid)
    }

    @Test func validateModelRejectsEmptyInput() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "{}".write(to: tmp, atomically: true, encoding: .utf8)
        let svc = ModelCatalogService(path: tmp.path)
        let result = svc.validateModel("", for: "nous")
        if case .invalid = result {
            // expected
        } else {
            Issue.record("Expected .invalid for empty input, got \(result)")
        }
    }

    // MARK: - ModelCatalogService — WS-6 (v0.13)

    @Test func vercelNoLongerDemotedSortsAlphabetically() throws {
        // v0.15 removed Vercel AI Gateway from Hermes entirely, so Scarf's
        // `demotedProviders` set is empty and nothing is special-cased to
        // the tail. With a now-empty demote set, providers sort purely
        // alphabetically — vercel lands in the middle, not last.
        let json = """
        {
          "anthropic": { "name": "Anthropic", "models": {} },
          "vercel":    { "name": "Vercel AI Gateway", "models": {} },
          "zonk":      { "name": "Zonk Provider", "models": {} }
        }
        """
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-models-\(UUID().uuidString).json")
        try json.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = ModelCatalogService(path: tmp.path)
        let providers = svc.loadProviders().filter { !$0.isOverlay }
        let names = providers.map(\.providerName)
        let vercelIdx = names.firstIndex(of: "Vercel AI Gateway") ?? -1
        let zonkIdx = names.firstIndex(of: "Zonk Provider") ?? -1
        // Not demoted to the tail anymore: vercel sorts before zonk.
        #expect(names.last != "Vercel AI Gateway")
        #expect(vercelIdx < zonkIdx)
    }

    @Test func grok420BetaAliasResolvesToGrok420() {
        let svc = ModelCatalogService(path: "/tmp/scarf-nonexistent-\(UUID().uuidString).json")
        // OpenRouter's old `-beta` ID resolves to the GA name.
        #expect(svc.resolveModelAlias(providerID: "openrouter", modelID: "x-ai/grok-4.20-beta")
                == "x-ai/grok-4.20")
        // xAI direct provider keeps the same shape minus prefix.
        #expect(svc.resolveModelAlias(providerID: "xai", modelID: "grok-4.20-beta")
                == "grok-4.20")
        // Non-aliased ID passes through unchanged.
        #expect(svc.resolveModelAlias(providerID: "anthropic", modelID: "claude-4.7-opus")
                == "claude-4.7-opus")
        // Cross-provider isolation: same modelID on a different
        // provider isn't aliased — composite key in `modelAliases`
        // disambiguates by providerID.
        #expect(svc.resolveModelAlias(providerID: "fictional", modelID: "x-ai/grok-4.20-beta")
                == "x-ai/grok-4.20-beta")
    }

    @Test func imageGenModelAllowlistShape() {
        // Lock the curated list size + a few sentinel entries so
        // unintentional edits get caught in review. Free-form-typing
        // bypasses the allowlist, so additions/removals here are
        // purely UX (which models surface as picker rows).
        let models = ModelCatalogService.imageGenModels
        #expect(models.count >= 5)
        #expect(models.contains(where: { $0.modelID == "openai/gpt-image-1" }))
        #expect(models.contains(where: { $0.modelID == "google/imagen-4" }))
        // v0.15: Krea image models.
        #expect(models.contains(where: { $0.modelID == "krea-2-medium" }))
        #expect(models.contains(where: { $0.modelID == "krea-2-large" }))
        // Every entry has a non-empty display + a non-empty modelID.
        for m in models {
            #expect(!m.modelID.isEmpty)
            #expect(!m.display.isEmpty)
        }
    }

    @Test func demotedProvidersEmptyAfterVercelRemoval() {
        // v0.15 removed Vercel AI Gateway from Hermes, so the demoted set
        // (whose only prior entry was vercel) is now empty. Kept as a hook
        // for future demotions. Mirrors providers.py.
        #expect(ModelCatalogService.demotedProviders.isEmpty)
        #expect(!ModelCatalogService.demotedProviders.contains("vercel"))
    }

    @Test func openAIAPIOverlayPresent() {
        // v0.15: OpenAI API as a first-class overlay provider, distinct
        // from `openai-codex`. Wire id is `openai-api` (NOT bare `openai`,
        // which Hermes aliases to openrouter).
        let overlay = ModelCatalogService.overlayOnlyProviders["openai-api"]
        #expect(overlay != nil)
        #expect(overlay?.baseURL == "https://api.openai.com/v1")
        #expect(overlay?.authType == .apiKey)
        #expect(overlay?.subscriptionGated == false)
        // Bare `openai` must NOT be registered as an overlay.
        #expect(ModelCatalogService.overlayOnlyProviders["openai"] == nil)
    }

    @Test func openCodeFreeOverlayIsKeylessAggregator() {
        // v0.20.5 (Hermes v2026.8.19): zero-auth OpenCode tier.
        // providers.py:160 — base_url_override https://opencode.ai/zen/v1,
        // is_aggregator, keyless; providers.py:441 label "OpenCode Free".
        let overlay = ModelCatalogService.overlayOnlyProviders["opencode-free"]
        #expect(overlay != nil)
        #expect(overlay?.displayName == "OpenCode Free")
        #expect(overlay?.baseURL == "https://opencode.ai/zen/v1")
        #expect(overlay?.authType == .apiKey)
        #expect(overlay?.subscriptionGated == false)
        #expect(overlay?.keyless == true)
        // Every other overlay is credentialed — keyless defaults false.
        for (id, other) in ModelCatalogService.overlayOnlyProviders where id != "opencode-free" {
            #expect(other.keyless == false, "\(id) should not be keyless")
        }
    }

    @Test func openCodeAliasesResolveToCanonicalTiers() {
        // providers.py:334-344 ALIASES. Zen's canonical id is bare
        // `opencode` (opencode-zen/zen alias INTO it); go and free are
        // canonical in their own right.
        #expect(ModelCatalogService.canonicalProviderID("free") == "opencode-free")
        #expect(ModelCatalogService.canonicalProviderID("opencode_free") == "opencode-free")
        #expect(ModelCatalogService.canonicalProviderID("OPENCODE_FREE") == "opencode-free")
        #expect(ModelCatalogService.canonicalProviderID("opencode-free") == "opencode-free")
        #expect(ModelCatalogService.canonicalProviderID("opencode-zen") == "opencode")
        #expect(ModelCatalogService.canonicalProviderID("zen") == "opencode")
        #expect(ModelCatalogService.canonicalProviderID("go") == "opencode-go")
    }

    @Test func xaiRetiredModelAliasesResolveToGrok43() {
        let svc = ModelCatalogService(path: "/tmp/scarf-nonexistent-\(UUID().uuidString).json")
        // v0.15 May-15 retirement map → grok-4.3 (xai + xai-oauth prefixes).
        #expect(svc.resolveModelAlias(providerID: "xai", modelID: "grok-3") == "grok-4.3")
        #expect(svc.resolveModelAlias(providerID: "xai", modelID: "grok-code-fast-1") == "grok-4.3")
        #expect(svc.resolveModelAlias(providerID: "xai-oauth", modelID: "grok-4-0709") == "grok-4.3")
        #expect(svc.resolveModelAlias(providerID: "xai", modelID: "grok-imagine-image-pro")
                == "grok-imagine-image-quality")
    }

    // MARK: - ProjectDashboardService

    @Test func projectDashboardServiceRegistryRoundTrip() throws {
        // Use the Files transport via a fake home — write under a tmpdir
        // and point ServerContext at it. ProjectDashboardService uses
        // `context.paths.projectsRegistry` which is `home/scarf/projects.json`.
        let fakeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-home-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: fakeHome) }

        // Inject a ServerContext pointing at the fake home directly — we do
        // this by using a remote-style config whose `remoteHome` is actually
        // a local dir, then reading via LocalTransport directly through the
        // service (ProjectDashboardService only uses the transport's
        // file-I/O primitives, which LocalTransport already implements
        // cross-platform).
        //
        // Simpler: construct the service, then massage the registry in/out
        // via the transport for a local path.
        let fakeRegistry = fakeHome + "/scarf/projects.json"

        let svc = ProjectDashboardService(context: .local)
        let localTransport = LocalTransport()

        // Ensure the dir exists, then save.
        try localTransport.createDirectory(fakeHome + "/scarf")
        let registry = ProjectRegistry(projects: [
            ProjectEntry(name: "alpha", path: "/tmp/alpha"),
            ProjectEntry(name: "beta",  path: "/tmp/beta")
        ])
        let encoded = try JSONEncoder().encode(registry)
        try localTransport.writeFile(fakeRegistry, data: encoded)

        // Read it back via decoder (the service's loadRegistry pattern,
        // verified independently of the service since the service reads
        // from `context.paths.projectsRegistry` not a custom path).
        let readBack = try JSONDecoder().decode(ProjectRegistry.self, from: localTransport.readFile(fakeRegistry))
        #expect(readBack.projects.map(\.name) == ["alpha", "beta"])

        // Exercise dashboardExists / modificationDate against a real project
        // dashboard file we write.
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-proj-\(UUID().uuidString)").path
        try localTransport.createDirectory(projectDir + "/.scarf")
        defer { try? FileManager.default.removeItem(atPath: projectDir) }

        let dashJSON = """
        {
          "version": 1,
          "title": "Demo",
          "description": null,
          "updatedAt": null,
          "theme": null,
          "sections": []
        }
        """
        try localTransport.writeFile(projectDir + "/.scarf/dashboard.json", data: Data(dashJSON.utf8))

        let entry = ProjectEntry(name: "demo", path: projectDir)
        #expect(svc.dashboardExists(for: entry) == true)
        #expect(svc.dashboardModificationDate(for: entry) != nil)
        let dash = svc.loadDashboard(for: entry)
        #expect(dash?.title == "Demo")
        #expect(dash?.version == 1)
    }

    @Test func projectDashboardServiceReturnsEmptyRegistryOnMissingFile() async throws {
        // When `projectsRegistry` doesn't exist, loadRegistry returns an
        // empty ProjectRegistry rather than crashing. t-aud25: inject a temp
        // home so the registry is genuinely absent and the assertion runs
        // unconditionally — this used to skip on dev machines that have a
        // real `~/.hermes/scarf/projects.json`.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-registry-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let ctx = ServerContext.local(home: home)
        let svc = ProjectDashboardService(context: ctx)
        #expect(!FileManager.default.fileExists(atPath: ctx.paths.projectsRegistry))
        let reg = svc.loadRegistry()
        #expect(reg.projects.isEmpty)
    }
}
