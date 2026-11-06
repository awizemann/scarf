import Testing
import Foundation
@testable import ScarfCore

/// `plugins update` with no name / `--yes` / `--force` (v0.22.3+) and
/// `plugins auto-update` (v0.23.0+). Strings follow the tagged emitters:
/// `hermes_cli/plugins_cmd_update_all.py:111-160`, `plugins_cmd.py:213-224`,
/// `tools/plugin_guard.py:406-418`, `plugins_cmd.py:1096-1107` @ v0.23.0.
@Suite struct HermesPluginsUpdateAllV0230Tests {

    static func caps(_ line: String) -> HermesCapabilities { HermesCapabilities.parseLine(line) }

    // MARK: argv + gating

    @Test func argvShapes() {
        #expect(HermesPluginsUpdateAllVerdict.previewArgv == ["plugins", "update"])
        #expect(HermesPluginsUpdateAllVerdict.applyArgv == ["plugins", "update", "--yes"])
        #expect(HermesPluginsUpdateAllVerdict.forceArgv(name: "weather")
                == ["plugins", "update", "--force", "--", "weather"])
        #expect(HermesPluginsAutoUpdateVerdict.showArgv == ["plugins", "auto-update"])
        #expect(HermesPluginsAutoUpdateVerdict.setArgv(true) == ["plugins", "auto-update", "on"])
        #expect(HermesPluginsAutoUpdateVerdict.setArgv(false) == ["plugins", "auto-update", "off"])
        // The preview never carries --yes or --force.
        #expect(!HermesPluginsUpdateAllVerdict.previewArgv.contains("--yes"))
        #expect(!HermesPluginsUpdateAllVerdict.applyArgv.contains("--force"))
    }

    @Test func floors() {
        let v0222 = Self.caps("Hermes Agent v0.22.2 (2026.9.24)")
        let v0223 = Self.caps("Hermes Agent v0.22.3 (2026.9.24)")
        let v0227 = Self.caps("Hermes Agent v0.22.7 (2026.9.24)")
        let v0230 = Self.caps("Hermes Agent v0.23.0 (2026.9.24)")
        let v0221 = Self.caps("Hermes Agent v0.22.1 (2026.9.24)")
        #expect(!v0221.hasPluginsUpdateAll)
        #expect(!v0222.hasPluginsUpdateAll)
        #expect(v0223.hasPluginsUpdateAll)
        #expect(v0230.hasPluginsUpdateAll)
        #expect(!v0227.hasPluginsAutoUpdateVerb)
        #expect(v0230.hasPluginsAutoUpdateVerb)
    }

    // MARK: preview

    @Test func previewNothingToUpdate() {
        let out = "Checking installed plugins for updates...\n  skipped foo (pip): pip distribution; Hermes does not upgrade it\n✓ No plugin updates to apply.\n"
        #expect(HermesPluginsUpdateAllVerdict.judgePreview(output: out, exitCode: 0) == .nothingToUpdate)
    }

    static let previewOut = """
    Checking installed plugins for updates...

                      Plugin updates available
    ┏━━━┳━━━━━━━━━┳━━━━━━━━━━┳━━━━━━━━━━┳━━━━━━━━━━━━━━━━┓
    ┃ # ┃ Plugin  ┃ Current  ┃ Latest   ┃ Update         ┃
    ┡━━━╇━━━━━━━━━╇━━━━━━━━━━╇━━━━━━━━━━╇━━━━━━━━━━━━━━━━┩
    │ 1 │ weather │ abc12345 │ def67890 │ git pull       │
    │ 2 │ notes   │ 11112222 │ 33334444 │ catalog re-pin │
    └───┴─────────┴──────────┴──────────┴────────────────┘
      skipped old (pip): pip distribution; Hermes does not upgrade it
    Not updating: no terminal to confirm. Re-run with --yes to update these 2
    plugin(s).
    """

    @Test func previewPendingParsesWrappedCount() {
        guard case let .pending(count, listing) = HermesPluginsUpdateAllVerdict.judgePreview(
            output: Self.previewOut, exitCode: 1) else {
            Issue.record("expected pending"); return
        }
        #expect(count == 2)
        #expect(listing.contains("weather"))
        #expect(listing.contains("skipped old"))
        #expect(!listing.contains("Checking installed plugins"))
        #expect(!listing.contains("Not updating"))
    }

    @Test func previewUnknownOutputIsFailureNotNothing() {
        // An unknown-verb / old-host shape: exit 0 with nothing recognised.
        let r = HermesPluginsUpdateAllVerdict.judgePreview(output: "usage: hermes ...\n", exitCode: 0)
        guard case .failed = r else { Issue.record("expected failed"); return }
        let r2 = HermesPluginsUpdateAllVerdict.judgePreview(
            output: "Error: something broke\n", exitCode: 1)
        #expect(r2 == .failed("Error: something broke"))
    }

    // MARK: apply

    static let applyOut = """
    Checking installed plugins for updates...
    (table)

    ── weather
    Updating weather...
    ✓ Plugin weather updated.
    Fast-forward

    ── notes
    = Plugin notes is already at catalog pin 33334444.

    ── risky
    Updating risky...
    Error: Security scan blocked plugin install: Requires confirmation (caution
    verdict, 2 findings)

    Scan report: risky — verdict caution
      [medium] network: requests.get in tool.py:12

    Review the findings above. Install only plugins from sources you trust.
    (Scanning can be configured via plugins.scan_on_install in config.yaml.)

    ── evil
    Error: Security scan blocked plugin install: Blocked (dangerous verdict, 1
    critical). --force does not override a dangerous verdict.

    Summary
      ✓ updated  weather  abc12345..def67890
      = already current  notes
      ✗ failed  risky  Security scan blocked plugin install: Requires confirmation (caution verdict, 2 findings)
      ✗ failed  evil  Security scan blocked plugin install: Blocked (dangerous verdict, 1 critical). --force does not override a dangerous verdict.
    """

    @Test func applyClassifiesEveryRow() {
        guard case let .ran(rows) = HermesPluginsUpdateAllVerdict.judgeApply(
            output: Self.applyOut, exitCode: 1) else {
            Issue.record("expected ran"); return
        }
        #expect(rows.map(\.name) == ["weather", "notes", "risky", "evil"])
        #expect(rows.map(\.status) == [.updated, .current, .failed, .failed])
        #expect(rows[0].detail == "abc12345..def67890")
        #expect(rows[0].cautionHold == nil)
        // Caution: forceable, with Hermes's own findings.
        let hold = rows[2].cautionHold
        #expect(hold?.name == "risky")
        #expect(hold?.findings.contains("requests.get in tool.py:12") == true)
        // Dangerous: never offered a force.
        #expect(rows[3].cautionHold == nil)
    }

    @Test func applyNothingToUpdate() {
        #expect(HermesPluginsUpdateAllVerdict.judgeApply(
            output: "✓ No plugin updates to apply.\n", exitCode: 0) == .nothingToUpdate)
    }

    @Test func applyWithoutSummaryIsFailure() {
        let r = HermesPluginsUpdateAllVerdict.judgeApply(output: "Traceback...\nKeyError: x\n", exitCode: 1)
        guard case .failed = r else { Issue.record("expected failed"); return }
        let r2 = HermesPluginsUpdateAllVerdict.judgeApply(output: "", exitCode: 0)
        guard case .failed = r2 else { Issue.record("expected failed"); return }
    }

    // MARK: single named update held for caution

    @Test func namedUpdateCautionHold() {
        // `cmd_update` non-TTY: interactive_scan_decision prints the report,
        // declines, then `_fail`s with `Blocked: …` (plugins_cmd_update.py:162).
        let out = """
        Updating weather...

        ⚠ Security scan flagged this plugin:
        Scan report: weather — verdict caution
        Blocked: Security scan blocked plugin install: Requires confirmation (caution verdict, 1 findings)
        """
        let hold = HermesPluginsUpdateAllVerdict.cautionHold(name: "weather", output: out)
        #expect(hold?.name == "weather")
        #expect(HermesPluginsUpdateVerdict.judge(output: out, exitCode: 1).succeeded == false)
        let dangerous = "Blocked: Security scan blocked plugin install: Blocked (dangerous verdict, x). --force does not override a dangerous verdict."
        #expect(HermesPluginsUpdateAllVerdict.cautionHold(name: "weather", output: dangerous) == nil)
        #expect(HermesPluginsUpdateAllVerdict.cautionHold(name: "weather", output: "Error: not found") == nil)
    }

    // MARK: auto-update

    @Test func autoUpdateState() {
        #expect(HermesPluginsAutoUpdateVerdict.parseState(
            output: "Plugin auto-update: on (checked every 24h by the gateway; updates load in new sessions)\n",
            exitCode: 0) == true)
        #expect(HermesPluginsAutoUpdateVerdict.parseState(
            output: "Plugin auto-update: off (the gateway's check is off: plugins.auto_update_check_hours is 0; updates load in new sessions)\n",
            exitCode: 0) == false)
        #expect(HermesPluginsAutoUpdateVerdict.parseState(
            output: "Error: This Hermes install's configuration is managed by a package manager; set plugins.auto_apply there.\n",
            exitCode: 1) == nil)
        // Unknown output (e.g. an unknown verb routed elsewhere) is not "off".
        #expect(HermesPluginsAutoUpdateVerdict.parseState(output: "Hello! How can I help?\n", exitCode: 0) == nil)
    }

    // MARK: list --json v0.23 shape

    @Test func listJSONV0230ShapeDecodes() throws {
        let json = """
        [
          {"name": "weather", "status": "enabled", "version": "1.2", "description": "d",
           "source": "catalog:verified@abcd1234", "removed": null},
          {"name": "gone", "status": "disabled", "version": "0.1", "description": "",
           "source": "git", "removed": "withdrawn by maintainer", "future_key": {"x": 1}}
        ]
        """
        let entries = try #require(HermesPluginList.parseJSON(json))
        try #require(entries.count == 2)
        #expect(entries[0].removed == nil)
        #expect(entries[0].source == "catalog:verified@abcd1234")
        #expect(entries[1].removed == "withdrawn by maintainer")
        #expect(entries[1].status == .disabled)
        // Pre-v0.21.6 shape (no `removed`) still decodes.
        let old = #"[{"name": "a", "status": "not enabled", "version": "1", "description": "", "source": "user"}]"#
        #expect(HermesPluginList.parseJSON(old)?.first?.removed == nil)
    }
}
