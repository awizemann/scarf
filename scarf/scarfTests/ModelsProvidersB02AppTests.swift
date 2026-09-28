import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Blind re-audit B02 (app half): S06-F1 picker restore, S06-F2 Nous
/// keepalive date, S06-F3 Anthropic double browser tab.
@Suite("ModelsProvidersB02App")
@MainActor
struct ModelsProvidersB02AppTests {

    // MARK: - S06-F1: an unroutable saved provider is not restored

    private static func provider(_ id: String) -> HermesProviderInfo {
        HermesProviderInfo(providerID: id, providerName: id, envVars: [], docURL: nil, modelCount: 1)
    }

    /// A config saved by an older picker names `mistral`, which a v0.21.5
    /// roster no longer lists. Restoring it as the selection would let Save
    /// write it straight back. Only an undetected host keeps the old
    /// "leave it unchanged" behaviour.
    @Test func unroutableSavedProviderIsNotRestored() {
        let providers = [Self.provider("anthropic"), Self.provider("openai")]
        let v0215 = HermesCapabilities.parse("Hermes Agent v0.21.5 (2026.9.24)")
        let v0213 = HermesCapabilities.parse("Hermes Agent v0.21.3 (2026.9.14)")
        #expect(ModelPickerSheet.resolveInitialProviderID("mistral", in: providers, capabilities: v0215) == "")
        // Older hosts had the same bug and are judged by their own band.
        #expect(ModelPickerSheet.resolveInitialProviderID("mistral", in: providers, capabilities: v0213) == "")
        #expect(ModelPickerSheet.resolveInitialProviderID("mistral", in: providers, capabilities: .empty) == "mistral")
        // A routable provider with a row still restores.
        #expect(ModelPickerSheet.resolveInitialProviderID("anthropic", in: providers, capabilities: v0215) == "anthropic")
    }

    // MARK: - S06-F2: auth.json updated_at as Hermes writes it

    private static func state(updatedAt: String) throws -> NousSubscriptionState {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b02-nous-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("auth.json").path
        let json = #"{"providers": {"nous": {"access_token": "t"}}, "updated_at": "\#(updatedAt)"}"#
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        return NousSubscriptionService(path: path).loadState()
    }

    /// `datetime.now(timezone.utc).isoformat()` (`hermes_cli/auth.py:723`)
    /// carries microseconds and `+00:00`; the default formatter returned nil
    /// for it, so the keepalive warning could never appear.
    @Test func hermesTimestampWithMicrosecondsParses() throws {
        let stale = Date().addingTimeInterval(-20 * 86_400)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Build the exact Python shape: six fractional digits, `+00:00`.
        let millis = formatter.string(from: stale)                // …T12:34:56.123Z
        let pythonShape = millis.replacingOccurrences(of: "Z", with: "456+00:00")
        let state = try Self.state(updatedAt: pythonShape)
        #expect(state.updatedAt != nil, "\(pythonShape) did not parse")
        #expect((state.daysSinceLastRefresh() ?? 0) >= 19)
        #expect(state.hasStaleRefresh)

        // Whole-second and `Z` spellings still parse.
        #expect(try Self.state(updatedAt: "2026-09-01T00:00:00Z").updatedAt != nil)
        // Garbage stays unknown — no nudge on missing data.
        let bad = try Self.state(updatedAt: "yesterday")
        #expect(bad.updatedAt == nil)
        #expect(!bad.hasStaleRefresh)
    }

    // MARK: - S06-F3: one browser tab for Anthropic OAuth

    @Test func autoOpenDecisionTable() {
        let url = "  https://claude.ai/oauth/authorize?x=1\n"
        // Not deferred (other providers, or a remote host): open at once.
        #expect(OAuthFlowController.autoOpenDecision(output: url, deferUntilPrompt: false) == true)
        // Deferred: wait for Hermes's own attempt…
        #expect(OAuthFlowController.autoOpenDecision(output: url, deferUntilPrompt: true) == nil)
        // …Hermes opened it: don't open a second tab.
        let opened = url + "  (Browser opened automatically)\n\nAuthorization code: "
        #expect(OAuthFlowController.autoOpenDecision(output: opened, deferUntilPrompt: true) == false)
        // …Hermes couldn't (no GUI browser): the prompt arrives without the marker.
        #expect(OAuthFlowController.autoOpenDecision(output: url + "Authorization code: ",
                                                     deferUntilPrompt: true) == true)
    }

    private static func sh(_ script: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        return p
    }

    private static func run(provider: String, script: String) async -> [URL] {
        var opened: [URL] = []
        let proc = sh(script)
        let controller = OAuthFlowController(
            context: .local, makeAuthProcess: { _ in proc }, openURL: { opened.append($0) })
        controller.start(provider: provider, label: "")
        let deadline = Date().addingTimeInterval(30)
        while controller.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return opened
    }

    /// Hermes's Anthropic login output, in order (`agent/anthropic_credentials.py:763-779`).
    private static let anthropicURL = "https://claude.ai/oauth/authorize?code=true&state=s"

    @Test func localAnthropicLoginThatOpenedTheBrowserIsNotOpenedAgain() async {
        let opened = await Self.run(provider: "anthropic", script: """
        printf '\\n  \(Self.anthropicURL)\\n\\n'; sleep 0.2
        printf '  (Browser opened automatically)\\n'
        printf '\\nAfter authorizing, you will see a code. Paste it below.\\n\\nAuthorization code: '
        exit 0
        """)
        #expect(opened.isEmpty, "opened \(opened)")
    }

    @Test func localAnthropicLoginWithoutABrowserIsOpenedByScarf() async {
        let opened = await Self.run(provider: "claude", script: """
        printf '\\n  \(Self.anthropicURL)\\n\\n'; sleep 0.2
        printf '\\nAfter authorizing, you will see a code. Paste it below.\\n\\nAuthorization code: '
        exit 0
        """)
        #expect(opened.map(\.absoluteString) == [Self.anthropicURL])
    }

    /// Other providers honour `--no-browser`: unchanged, opened once, at once.
    @Test func otherProvidersStillOpenOnce() async {
        let url = "https://openrouter.ai/auth?code_challenge=abc&code_challenge_method=S256"
        let opened = await Self.run(provider: "openrouter", script: """
        printf 'Open this URL to authorize Hermes with OpenRouter:\\n  \(url)\\n'
        printf 'Waiting for the OpenRouter callback...\\n'
        exit 0
        """)
        #expect(opened.map(\.absoluteString) == [url])
    }
}
