import Testing
import Foundation
@testable import ScarfCore

/// Hermes v0.22.5 parity, slice S3 — providers, image models, MCP catalog.
///
/// - Local-server aliases (`local`, `vllm`, `llamacpp`, `llama.cpp`,
///   `llama-cpp`) resolve to `custom`, as Hermes routes them at every tag
///   (`providers.py:141` / `auth.py:1478` @ v0.22.5). Not version-gated.
/// - `solstice` / `solstice-oauth` route from v0.21.6.
/// - `krea-3` is an image-gen row from v0.22.3.
/// - `rentahuman` is an optional MCP from v0.22.3.
@Suite("Hermes v0.22.5 providers & catalog")
struct HermesV0225ProvidersCatalogTests {

    static let v0215 = HermesCapabilities.parse("Hermes Agent v0.21.5 (2026.9.24)")
    static let v0216 = HermesCapabilities.parse("Hermes Agent v0.21.6")
    static let v0222 = HermesCapabilities.parse("Hermes Agent v0.22.2")
    static let v0223 = HermesCapabilities.parse("Hermes Agent v0.22.3")
    static let v0225 = HermesCapabilities.parse("Hermes Agent v0.22.5")
    static let v0213 = HermesCapabilities.parse("Hermes Agent v0.21.3 (2026.9.14)")

    static let localAliases = ["local", "vllm", "llamacpp", "llama.cpp", "llama-cpp", "ollama"]

    // MARK: - Local aliases → custom

    @Test(arguments: [HermesCapabilities.empty, v0213, v0215, v0225])
    func localServerAliasesResolveToCustom(_ caps: HermesCapabilities) {
        for alias in Self.localAliases {
            #expect(ModelCatalogService.canonicalProviderID(alias, capabilities: caps) == "custom", "\(alias)")
        }
    }

    @Test func credentialsAliasTableFoldsLocalToCustom() {
        for alias in Self.localAliases {
            #expect(HermesProviderCredentials.canonicalProvider(alias) == "custom", "\(alias)")
        }
    }

    /// A config Scarf itself writes (`provider: vllm` with a slash-bearing
    /// HF id, LocalModelConfigPlanTests) must not raise the stale-prefix
    /// banner — on any host.
    @Test(arguments: [HermesCapabilities.empty, v0215, v0225])
    func localProviderConfigsAreNotAMismatch(_ caps: HermesCapabilities) {
        var cfg = HermesConfig.empty
        cfg.model = "meta-llama/Llama-3-8B"
        for provider in ["vllm", "local", "llamacpp", "llama.cpp", "llama-cpp"] {
            cfg.provider = provider
            #expect(ModelPreflight.detectMismatch(cfg, capabilities: caps) == nil, "\(provider)")
        }
        // Control: the same id under a direct provider IS a stale prefix.
        cfg.provider = "deepseek"
        #expect(ModelPreflight.detectMismatch(cfg, capabilities: caps) != nil)
    }

    /// The llama.cpp managed-runtime write rule is untouched by the alias fix.
    @Test func llamaCppConfigProviderIDIsUnchanged() throws {
        let llama = try #require(LocalModelProvider.descriptor(for: "llamacpp"))
        #expect(llama.configProviderID(capabilities: .empty) == "llamacpp")
        #expect(llama.configProviderID(capabilities: Self.v0225) == "custom")
        let vllm = try #require(LocalModelProvider.descriptor(for: "vllm"))
        #expect(vllm.configProviderID(capabilities: Self.v0225) == "vllm")
    }

    // MARK: - solstice routable from v0.21.6

    @Test func solsticeRoutesFromV0216() {
        for id in ["solstice", "solstice-oauth"] {
            #expect(HermesRoutableProviders.isRoutable(id, capabilities: Self.v0225) == true, "\(id)")
            #expect(HermesRoutableProviders.isRoutable(id, capabilities: Self.v0216) == true, "\(id)")
            #expect(HermesRoutableProviders.isRoutable(id, capabilities: Self.v0215) == false, "\(id)")
            #expect(HermesRoutableProviders.isRoutable(id, capabilities: .empty) == nil, "\(id)")
        }
    }

    @Test func v0215BandIsUnchangedBySolstice() throws {
        let v0215 = try #require(HermesRoutableProviders.providerIDs(for: .init(major: 0, minor: 21, patch: 5)))
        let v0216 = try #require(HermesRoutableProviders.providerIDs(for: .init(major: 0, minor: 21, patch: 6)))
        #expect(v0216.subtracting(v0215) == ["solstice", "solstice-oauth"])
        #expect(v0215.subtracting(v0216).isEmpty)
    }

    // MARK: - krea-3 from v0.22.3

    @Test func krea3AppearsFromV0223AfterTheKrea2Rows() throws {
        let old = ModelCatalogService.imageGenModels(capabilities: Self.v0222).map(\.modelID)
        #expect(!old.contains("krea-3"))
        let new = ModelCatalogService.imageGenModels(capabilities: Self.v0223)
        let ids = new.map(\.modelID)
        let at = try #require(ids.firstIndex(of: "krea-3"))
        #expect(ids[at - 1] == "krea-2-medium-turbo")
        #expect(new[at].providerHint == "krea")
        // Everything else is the v0.22.2 roster unchanged.
        #expect(ids.filter { $0 != "krea-3" } == old)
        #expect(!ModelCatalogService.imageGenModels(capabilities: .empty).map(\.modelID).contains("krea-3"))
    }

    // MARK: - rentahuman from v0.22.3

    @Test func rentahumanMirrorsItsManifest() throws {
        let entry = try #require(OptionalMCPCatalog.entries.first { $0.name == "rentahuman" })
        #expect(entry.transport == .http)
        #expect(entry.authKind == .oauth)
        #expect(entry.url == "https://rentahuman.ai/api/mcp")
        #expect(entry.defaultEnabledTools == ["search_humans", "browse_taste_humans", "list_bounties", "search_bounties"])
        #expect(entry.defaultExcludedTools.isEmpty)
        #expect(entry.installPrompts.isEmpty)
    }

    @Test func rentahumanIsOfferedFromV0223Only() {
        func names(_ caps: HermesCapabilities) -> [String] {
            OptionalMCPCatalog.entries(for: caps).map(\.name)
        }
        #expect(names(Self.v0223).contains("rentahuman"))
        #expect(names(Self.v0225) == OptionalMCPCatalog.entries.map(\.name))
        for caps in [Self.v0222, Self.v0215, Self.v0213, HermesCapabilities.empty] {
            #expect(!names(caps).contains("rentahuman"))
        }
        // Between v0.21.4 and v0.22.2 the roster is the v0.21.4 one: the
        // current list minus the new entry, asana / n8n-official current.
        #expect(names(Self.v0222) == OptionalMCPCatalog.entries.map(\.name).filter { $0 != "rentahuman" })
        #expect(names(Self.v0222).contains("n8n-official"))
        // Below v0.21.4 the legacy swaps still apply.
        #expect(names(Self.v0213).contains("n8n"))
        #expect(!names(Self.v0213).contains("n8n-official"))
        #expect(OptionalMCPCatalog.preV0214Entries.count == 65)
    }
}
