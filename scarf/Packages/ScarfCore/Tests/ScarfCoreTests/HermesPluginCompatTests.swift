import Testing
@testable import ScarfCore

/// Coverage for `HermesPluginCompatReport` — the `hermes plugins compat
/// --json` payload (v0.21.1+) that tells a user which installed plugins
/// stop loading after the Sep 2026 decomposition's removal date.
@Suite("HermesPluginCompatReport")
struct HermesPluginCompatTests {

    /// Emitted by Hermes's own serializer line at v2026.9.7
    /// (`hermes_cli/plugins_cmd.py::cmd_compat`):
    ///
    /// ```python
    /// json.dumps({"removal_date": COMPAT_REMOVAL, "in_effect": removal_in_effect(),
    ///             "plugins": {k: [h.__dict__ for h in v] for k, v in report.items()}}, indent=2)
    /// ```
    ///
    /// with `COMPAT_REMOVAL = date(2026, 9, 14).isoformat()` and `Hit`'s
    /// four fields in declaration order.
    private static let fixture = """
    {
      "removal_date": "2026-09-14",
      "in_effect": false,
      "plugins": {
        "acme-notes": [
          {
            "file": "plugin.py",
            "line": 12,
            "old": "hermes_state.open_state",
            "new": "hermes_state_common.open_state"
          },
          {
            "file": "tools/sync.py",
            "line": 88,
            "old": "agent.redact.redact_sensitive_text",
            "new": "agent_redact.redact_sensitive_text"
          }
        ],
        "zeta": [
          {
            "file": "__init__.py",
            "line": 3,
            "old": "hermes_cli.gateway.Platform",
            "new": "gateway.config.Platform (removed; no replacement \u{2014} vendor a copy)"
          }
        ]
      }
    }
    """

    @Test func parsesAffectedPlugins() throws {
        let report = HermesPluginCompatReport.parse(Self.fixture)
        #expect(report?.removalDate == "2026-09-14")
        #expect(report?.inEffect == false)
        #expect(report?.isAffected == true)
        #expect(report?.affectedNames == ["acme-notes", "zeta"])
        let hits = report?.hits(for: "acme-notes") ?? []
        try #require(hits.count == 2)
        #expect(hits[0].file == "plugin.py")
        #expect(hits[0].line == 12)
        #expect(hits[0].old == "hermes_state.open_state")
        #expect(hits[0].new == "hermes_state_common.open_state")
        // Hits are ordered by (file, line) so the banner reads in source order.
        #expect(hits[1].file == "tools/sync.py")
        // The "no replacement" sentence is Hermes's copy, rendered verbatim.
        #expect(report?.hits(for: "zeta").first?.new.contains("vendor a copy") == true)
    }

    /// A clean host prints `"plugins": {}` and exits 0. That is a real
    /// answer — nothing is affected — and must decode, not fail.
    @Test func parsesCleanReport() {
        let report = HermesPluginCompatReport.parse("""
        {
          "removal_date": "2026-09-14",
          "in_effect": false,
          "plugins": {}
        }
        """)
        #expect(report != nil)
        #expect(report?.isAffected == false)
        #expect(report?.affectedNames.isEmpty == true)
    }

    /// `in_effect: true` means the plugins are ALREADY not loading — a
    /// different, worse message than "will break on <date>".
    @Test func readsInEffect() {
        let report = HermesPluginCompatReport.parse("""
        {"removal_date": "2026-09-14", "in_effect": true, "plugins": {"a": []}}
        """)
        #expect(report?.inEffect == true)
        // A plugin key with no readable hits is still affected.
        #expect(report?.isAffected == true)
        #expect(report?.hits(for: "a").isEmpty == true)
    }

    /// Nil, not an empty report: "the command never answered" must never
    /// render as "your plugins are fine". This is the whole reason the
    /// parse returns an optional.
    @Test func returnsNilWithoutAPayload() {
        #expect(HermesPluginCompatReport.parse("") == nil)
        #expect(HermesPluginCompatReport.parse("usage: hermes plugins [-h] ...") == nil)
        // Right-shaped JSON, wrong payload (no `plugins` key).
        #expect(HermesPluginCompatReport.parse("{\"removal_date\": \"2026-09-14\"}") == nil)
    }

    /// The exit code is 1 whenever anything is affected — that's the
    /// FINDING path. Callers parse stdout regardless, so a payload that
    /// arrived alongside a warning line still decodes.
    @Test func parsesPayloadAfterLeadingNoise() {
        let noisy = "WARNING: plugin index rebuilt\n" + Self.fixture
        #expect(HermesPluginCompatReport.parse(noisy)?.affectedNames == ["acme-notes", "zeta"])
    }
}
