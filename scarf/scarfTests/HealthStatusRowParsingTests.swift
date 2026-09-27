import Testing
import Foundation
import ScarfCore
@testable import scarf

/// S14-F4: the Health "Status" tab against `hermes status` as Hermes 0.21.5
/// actually prints it. The fixtures below were captured from the tagged CLI
/// (`hermes status` / `hermes doctor` from `hermes-agent` v2026.9.24, piped,
/// against scratch `HERMES_HOME`s), trimmed to a few rows per section, with
/// local paths replaced. Row shapes: `hermes_cli/status.py:35-52`.
@Suite struct HealthStatusRowParsingTests {

    /// Scratch home with no `.env`, no providers, gateway stopped (the
    /// `Status:` line is the stopped arm of `_kv_flag` at status.py:231).
    static let statusFresh = """

    ┌─────────────────────────────────────────────────────────┐
    │                 ☤ Hermes Agent Status                  │
    └─────────────────────────────────────────────────────────┘

    ◆ Environment
      Project:      /opt/hermes-agent
      Python:       3.11.15
      .env file:    ✗ not found
      Model:        (not set)
      Provider:     Auto

    ◆ API Keys
      OpenRouter    ✗ (not set)
      Google / Gemini  ✗ (not set)
      Anthropic     ✗ (not set)

    ◆ Auth Providers
      Nous Portal   ✗ not logged in (run: hermes portal)
      OpenAI Codex  ✗ not logged in (run: hermes model)
        Auth file:  /home/u/.hermes/auth.json
        Error:      No Codex credentials stored. Run `hermes auth add openai-codex --type oauth` to authenticate.
      xAI OAuth     ✗ not logged in (run: hermes auth add xai-oauth)

    ◆ API-Key Providers
      Z.AI / GLM       ✗ not configured (run: hermes model)
      StepFun Step Plan ✗ not configured (run: hermes model)

    ◆ Terminal Backend
      Backend:      local
      Sudo:         ✗ disabled

    ◆ Messaging Platforms
      Telegram      ✗ not configured
      WeCom Callback  ✗ not configured
      A2A           ✓ configured (plugin)

    ◆ Gateway Service
      Status:       ✗ stopped
      Manager:      launchd

    ◆ Scheduled Jobs
      Jobs:         0

    ◆ Sessions
      Active:       0

    ────────────────────────────────────────────────────────────
      Run 'hermes doctor' for detailed diagnostics
      Run 'hermes setup' to configure
    """

    /// The same host with a `.env` holding a (fake) OpenRouter key and
    /// `SUDO_PASSWORD`, and a running gateway.
    static let statusConfigured = """
    ◆ Environment
      .env file:    ✓ exists
      Model:        anthropic/claude-sonnet-4
      Provider:     OpenRouter

    ◆ API Keys
      OpenRouter    ✓ sk-o...0000
      OpenAI        ✗ (not set)

    ◆ Terminal Backend
      Backend:      local
      Sudo:         ✓ enabled

    ◆ Gateway Service
      Status:       ✓ running
      Manager:      launchd
      PID(s):       8548, 8550
    """

    static func section(_ sections: [HealthSection], _ title: String) throws -> HealthSection {
        try #require(sections.first { $0.title == title }, "no section \(title)")
    }

    static func check(_ section: HealthSection, _ label: String) throws -> HealthCheck {
        try #require(section.checks.first { $0.label == label }, "no check \(label) in \(section.title)")
    }

    @Test("a ✗ value is never a passing check")
    func crossedValuesAreNotPassing() throws {
        let sections = HealthViewModel.parseOutputStatic(Self.statusFresh)
        let env = try Self.check(Self.section(sections, "Environment"), ".env file")
        #expect(env.status == .off)
        #expect(env.detail == "not found")
        let gateway = try Self.check(Self.section(sections, "Gateway Service"), "Status")
        #expect(gateway.status == .off)
        #expect(gateway.detail == "stopped")
        let sudo = try Self.check(Self.section(sections, "Terminal Backend"), "Sudo")
        #expect(sudo.status == .off)
        // Plain `Key: value` rows are still informational passes.
        #expect(try Self.check(Self.section(sections, "Environment"), "Python").status == .ok)
    }

    @Test("_row lines (no colon, mark mid-line) become checks with the mark's status")
    func rowLinesAreParsed() throws {
        let sections = HealthViewModel.parseOutputStatic(Self.statusFresh)
        let keys = try Self.section(sections, "API Keys")
        #expect(keys.checks.map(\.label) == ["OpenRouter", "Google / Gemini", "Anthropic"])
        #expect(keys.checks.allSatisfy { $0.status == .off })

        let auth = try Self.section(sections, "Auth Providers")
        #expect(auth.checks.map(\.label) == ["Nous Portal", "OpenAI Codex", "xAI OAuth"])
        let codex = try Self.check(auth, "OpenAI Codex")
        #expect(codex.detail?.hasPrefix("not logged in (run: hermes model)") == true)
        // Its `_detail` lines ride along instead of becoming checks.
        #expect(codex.detail?.contains("Auth file:") == true)
        #expect(codex.detail?.contains("No Codex credentials stored") == true)

        let apiKeyProviders = try Self.section(sections, "API-Key Providers")
        #expect(apiKeyProviders.checks.map(\.label) == ["Z.AI / GLM", "StepFun Step Plan"])

        let platforms = try Self.section(sections, "Messaging Platforms")
        #expect(platforms.checks.map(\.label) == ["Telegram", "WeCom Callback", "A2A"])
        #expect(try Self.check(platforms, "A2A").status == .ok)
        #expect(try Self.check(platforms, "Telegram").status == .off)
    }

    @Test("a ✓ value is passing")
    func tickedValuesPass() throws {
        let sections = HealthViewModel.parseOutputStatic(Self.statusConfigured)
        #expect(try Self.check(Self.section(sections, "Environment"), ".env file").status == .ok)
        #expect(try Self.check(Self.section(sections, "Gateway Service"), "Status").detail == "running")
        #expect(try Self.check(Self.section(sections, "Gateway Service"), "Status").status == .ok)
        let key = try Self.check(Self.section(sections, "API Keys"), "OpenRouter")
        #expect(key.status == .ok)
        #expect(key.detail == "sk-o...0000")
        #expect(try Self.check(Self.section(sections, "API Keys"), "OpenAI").status == .off)
    }

    @Test("off rows count as neither passing nor failing")
    func offRowsDoNotInflateCounts() {
        let checks = HealthViewModel.parseOutputStatic(Self.statusFresh).flatMap(\.checks)
        let off = checks.filter { $0.status == .off }.count
        #expect(off == 13)
        #expect(!checks.contains { $0.status == .error })
    }

    /// `hermes doctor` goes through the same parser and must not change: its
    /// marks lead the line, and its `→` hints still fold into the check
    /// above. The connectivity progress line is rewritten in place with
    /// `\r`, which used to hide the first result behind it.
    @Test("doctor output still parses as before, plus the \\r-hidden first result")
    func doctorUnchanged() throws {
        let doctor = """
        ◆ Python Environment
          ✓ Python 3.11.15
          ⚠ SQLite 3.50.4 (WAL-reset bug) (run `hermes update`; fixed versions: 3.51.3+)
            → SQLite source id: 2025-07-30 19:33:53 4d8adfb30e03f9cf27f800a2c1ba…

        ◆ Configuration Files
          ✗ ~/.hermes/.env file missing
            → Run 'hermes setup' to create one

        ◆ External Tools
          ⚠ Playwright Chromium not installed (browser_* tools will be hidden from the agent)
            → Install with: cd /opt/hermes-agent && npx playwright install --with-deps chromium

        ◆ API Connectivity
          Running 42 connectivity checks in parallel…\r                    \r  ✓ IPv6 route (IPv6 path to openrouter.ai reachable)
          ⚠ OpenRouter API (not configured)
        """
        let sections = HealthViewModel.parseOutputStatic(doctor)
        let python = try Self.section(sections, "Python Environment")
        #expect(python.checks.map(\.status) == [.ok, .warning])
        #expect(python.checks[1].detail?.contains("SQLite source id") == true)
        let config = try Self.section(sections, "Configuration Files")
        #expect(config.checks.count == 1)
        #expect(config.checks[0].status == .error)
        #expect(config.checks[0].detail?.contains("Run 'hermes setup'") == true)
        let tools = try Self.section(sections, "External Tools")
        #expect(tools.checks.count == 1)
        #expect(tools.checks[0].detail?.contains("npx playwright install") == true)
        let connectivity = try Self.section(sections, "API Connectivity")
        #expect(connectivity.checks.map(\.status) == [.ok, .warning])
        #expect(connectivity.checks[0].label.hasPrefix("IPv6 route"))
    }

    @Test("a mark later in a plain value doesn't make it a flag row")
    func midValueMarkIsNotAFlag() {
        #expect(HealthViewModel.midLineGlyphRowStatic("Model:        gpt ✓ fast") == nil)
        #expect(HealthViewModel.midLineGlyphRowStatic("✓ leading mark") == nil)
        #expect(HealthViewModel.midLineGlyphRowStatic("Status:       ✓ running")?.label == "Status")
    }
}
