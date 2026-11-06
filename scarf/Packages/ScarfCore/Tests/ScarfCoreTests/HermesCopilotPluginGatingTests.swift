import Testing
import Foundation
@testable import ScarfCore

/// GitHub Copilot left Hermes core at v0.22.6 (`hasCopilotLeftCore`) for the
/// `github-copilot` plugin. v0.22.5 must behave exactly as before; v0.22.6+
/// offers Copilot only when `$HERMES_HOME/plugins/github-copilot` exists.
@Suite struct HermesCopilotPluginGatingTests {

    static let v0225 = HermesCapabilities.parse("Hermes Agent v0.22.5 (2026.9.24)")
    static let v0226 = HermesCapabilities.parse("Hermes Agent v0.22.6 (2026.9.24)")
    static let v0230 = HermesCapabilities.parse("Hermes Agent v0.23.0 (2026.9.24)")

    @Test func flagFloor() {
        #expect(!Self.v0225.hasCopilotLeftCore)
        #expect(Self.v0226.hasCopilotLeftCore)
        #expect(Self.v0230.hasCopilotLeftCore)
    }

    @Test(arguments: Array(HermesCopilotPlugin.providerIDs))
    func routableTableGating(id: String) {
        // v0.22.5: unchanged whatever the plugin flag says.
        #expect(HermesRoutableProviders.isRoutable(id, capabilities: Self.v0225) == true)
        #expect(HermesRoutableProviders.isRoutable(id, capabilities: Self.v0225, copilotPluginInstalled: true) == true)
        // v0.23.0: only with the plugin.
        #expect(HermesRoutableProviders.isRoutable(id, capabilities: Self.v0230) == false)
        #expect(HermesRoutableProviders.isRoutable(id, capabilities: Self.v0230, copilotPluginInstalled: true) == true)
    }

    @Test func nonCopilotProvidersUnaffected() {
        #expect(HermesRoutableProviders.isRoutable("anthropic", capabilities: Self.v0230) == true)
        #expect(HermesRoutableProviders.isRoutable("anthropic", capabilities: Self.v0225) == true)
    }

    @Test func preflightAndPluginNote() {
        #expect(!ModelPreflight.isUnroutable("copilot", customProviders: .none, capabilities: Self.v0225))
        #expect(ModelPreflight.isUnroutable("copilot", customProviders: .none, capabilities: Self.v0230))
        #expect(!ModelPreflight.isUnroutable("copilot", customProviders: .none, capabilities: Self.v0230,
                                             copilotPluginInstalled: true))
        #expect(HermesCopilotPlugin.needsPlugin("github", capabilities: Self.v0230, pluginInstalled: false))
        #expect(!HermesCopilotPlugin.needsPlugin("github", capabilities: Self.v0230, pluginInstalled: true))
        #expect(!HermesCopilotPlugin.needsPlugin("github", capabilities: Self.v0225, pluginInstalled: false))
        #expect(!HermesCopilotPlugin.needsPlugin("anthropic", capabilities: Self.v0230, pluginInstalled: false))
    }

    @Test func credentialsGating() {
        let env = ["GITHUB_TOKEN": "x"]
        #expect(HermesProviderCredentials.environmentHasProviderKey(env, provider: "copilot"))
        #expect(!HermesProviderCredentials.environmentHasProviderKey(env, provider: "copilot", copilotOffered: false))
        #expect(HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "copilot-acp", baseURL: ""))
        #expect(!HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "copilot-acp", baseURL: "",
                                                                    copilotOffered: false))
    }

    @Test func acpOAuthHintGating() {
        let msg = "401 Unauthorized from copilot"
        #expect(ACPErrorHint.classify(errorMessage: msg, stderrTail: "")?.oauthProvider == "copilot")
        #expect(ACPErrorHint.classify(errorMessage: msg, stderrTail: "", copilotOffered: false)?.oauthProvider != "copilot")
    }

    /// The roster: models.dev `github-copilot` and the `copilot-acp` overlay,
    /// gated on the plugin directory next to the cache.
    @Test(arguments: [("v0.22.5", false, true), ("v0.22.5", true, true),
                      ("v0.23.0", false, false), ("v0.23.0", true, true)])
    func rosterGating(tag: String, pluginPresent: Bool, expectCopilot: Bool) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-copilot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("models_dev_cache.json")
        try Data(#"{"github-copilot":{"id":"github-copilot","name":"GitHub Copilot","models":{}},"anthropic":{"id":"anthropic","name":"Anthropic","models":{}}}"#.utf8)
            .write(to: cache)
        if pluginPresent {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent("plugins/github-copilot"), withIntermediateDirectories: true)
        }
        let caps = tag == "v0.22.5" ? Self.v0225 : Self.v0230
        let ids = Set(ModelCatalogService(path: cache.path).loadProviders(capabilities: caps).map(\.providerID))
        #expect(ids.contains("anthropic"))
        #expect(ids.contains("github-copilot") == expectCopilot)
        #expect(ids.contains("copilot-acp") == expectCopilot)
    }

    /// The hint callers (RichChatViewModel, CronViewModel) read the last probe
    /// without I/O: older hosts always offer Copilot; a left-core host only
    /// after a probe found the plugin.
    @Test func knownOfferedReusesLastProbe() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-copilot-known-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let ctx = ServerContext.local(home: home)
        #expect(HermesCopilotPlugin.knownOffered(context: ctx, capabilities: Self.v0225))
        #expect(!HermesCopilotPlugin.knownOffered(context: ctx, capabilities: Self.v0230))   // unprobed
        #expect(!HermesCopilotPlugin.isInstalled(context: ctx, capabilities: Self.v0230))
        #expect(!HermesCopilotPlugin.knownOffered(context: ctx, capabilities: Self.v0230))
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("plugins/github-copilot"), withIntermediateDirectories: true)
        #expect(HermesCopilotPlugin.isInstalled(context: ctx, capabilities: Self.v0230))
        #expect(HermesCopilotPlugin.knownOffered(context: ctx, capabilities: Self.v0230))
        let msg = "401 Unauthorized from copilot"
        let offered = HermesCopilotPlugin.knownOffered(context: ctx, capabilities: Self.v0230)
        #expect(ACPErrorHint.classify(errorMessage: msg, stderrTail: "", copilotOffered: offered)?.oauthProvider == "copilot")
    }
}
