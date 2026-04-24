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

        let providers = svc.loadProviders()
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
        // Missing file → empty arrays, no crash.
        let svc = ModelCatalogService(path: "/tmp/scarf-nonexistent-\(UUID().uuidString).json")
        #expect(svc.loadProviders().isEmpty)
        #expect(svc.loadModels(for: "anthropic").isEmpty)
        #expect(svc.provider(for: "anything") == nil)

        // Malformed JSON → empty arrays, no crash, logger.error path exercised.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-bad-\(UUID().uuidString).json")
        try? "not json".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bad = ModelCatalogService(path: tmp.path)
        #expect(bad.loadProviders().isEmpty)
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

    @Test func projectDashboardServiceReturnsEmptyRegistryOnMissingFile() async {
        // When `projectsRegistry` path doesn't exist, loadRegistry returns
        // an empty ProjectRegistry rather than crashing.
        //
        // We use the real .local context — its registry path is
        // `$HOME/.hermes/scarf/projects.json`. On CI this probably doesn't
        // exist (no Hermes install under $HOME/.hermes), so we get the
        // empty-on-missing path for free. If it DOES exist (e.g., a dev
        // machine), we skip the assertion to avoid flakiness.
        let svc = ProjectDashboardService(context: .local)
        let registryPath = ServerContext.local.paths.projectsRegistry
        if !FileManager.default.fileExists(atPath: registryPath) {
            let reg = svc.loadRegistry()
            #expect(reg.projects.isEmpty)
        }
    }
}
