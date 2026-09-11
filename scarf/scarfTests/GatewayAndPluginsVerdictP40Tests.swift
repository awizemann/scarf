import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P40 — the call sites that used to read `exitCode == 0` for
/// `gateway start|stop|restart`, `mcp remove` and `plugins update`.
@Suite("GatewayAndPluginsVerdictP40")
struct GatewayAndPluginsVerdictP40Tests {

    private static func scratchContext() -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p40-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return .local(home: home)
    }

    @MainActor private static func until(
        timeout: TimeInterval, _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A `hermes` fake that answers the mutation with `output`/`exitCode` and
    /// every read with empty text, so `load()` cannot fail the assertion.
    @MainActor private static func gatewayViewModel(
        mutation output: String, exitCode: Int32
    ) -> MessagingGatewayViewModel {
        MessagingGatewayViewModel(
            context: scratchContext(),
            capabilities: .empty,
            cliRunner: { args, _ in
                args.first == "gateway" && args.count > 1 && args[1] != "status" && args[1] != "list"
                    ? (output, exitCode)
                    : ("", 0)
            }
        )
    }

    // MARK: - gateway

    /// The finding: `_cmd_stop` prints `✗ No gateway running for this profile`
    /// and returns at exit 0 (`hermes_cli/gateway.py:5998` @ v2026.9.7). Under
    /// round-4 decision 2 that is a SUCCESS, and the banner says what actually
    /// happened rather than "Gateway stop requested".
    @MainActor @Test func aStopWithNothingRunningReportsTheNeutralNote() async {
        let vm = Self.gatewayViewModel(
            mutation: "✗ No gateway running for this profile", exitCode: 0
        )
        vm.stopGateway()
        await Self.until(timeout: 10) { vm.actionMessage != nil }
        let message = try? #require(vm.actionMessage)
        #expect(vm.actionFailed == false)
        #expect(message?.contains("Gateway stopped") == true)
        #expect(message?.contains("Nothing was running") == true)
    }

    /// The regression the phase exists for: exit 0 with nothing the backend
    /// printed is a FAILURE now, and the banner is sticky rather than clearing
    /// on a settle timer. Pre-fix this reported "Gateway start requested".
    @MainActor @Test func aSilentExitZeroStartIsReportedAsAFailure() async {
        let vm = Self.gatewayViewModel(
            mutation: "Service start is not applicable inside a Docker container.", exitCode: 0
        )
        vm.startGateway()
        await Self.until(timeout: 10) { vm.actionMessage != nil }
        #expect(vm.actionFailed == true)
        #expect(vm.actionMessage?.contains("Gateway start failed") == true)
    }

    @MainActor @Test func aRealStartClaimsTheState() async {
        let vm = Self.gatewayViewModel(mutation: "✓ Service started", exitCode: 0)
        vm.startGateway()
        await Self.until(timeout: 10) { vm.actionMessage != nil }
        #expect(vm.actionFailed == false)
        #expect(vm.actionMessage == "Gateway started")
    }

    // MARK: - plugins update (round-4 decision 3)

    @MainActor private static func pluginsViewModel(
        returning output: String, exitCode: Int32
    ) -> PluginsViewModel {
        PluginsViewModel(
            context: scratchContext(),
            cliRunner: { _, _ in (output, exitCode) }
        )
    }

    private static func plugin(_ name: String) -> HermesPlugin {
        HermesPlugin(
            name: name, source: name, activation: .enabled,
            description: "", version: "", path: "", toolOverride: false
        )
    }

    @MainActor private static func awaitMessage(on vm: PluginsViewModel) async -> String? {
        for _ in 0..<400 {
            if let message = vm.message { return message }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return vm.message
    }

    /// `_rescan_after_update` disables the plugin (`plugins_cmd.py:845-851`)
    /// and `cmd_update` prints `✓ Plugin <name> updated.` anyway (`:828`),
    /// both at exit 0. Pre-fix the banner said a flat "Updated".
    @MainActor @Test func aSecurityDisabledUpdateSaysSoAndQuotesTheReason() async {
        let vm = Self.pluginsViewModel(returning: """
        Updating weather...

        ⚠ Security scan flagged the updated plugin: dangerous: subprocess with shell=True
        Plugin 'weather' has been disabled. Review the findings, then re-enable with `hermes plugins enable weather` if you trust them.
        ✓ Plugin weather updated.
        """, exitCode: 0)
        vm.update(Self.plugin("weather"))
        let message = await Self.awaitMessage(on: vm)
        #expect(vm.messageIsFailure == false)
        #expect(message?.contains("disabled by the security scan") == true)
        #expect(message?.contains("subprocess with shell=True") == true)
        #expect(message != "Updated")
    }

    @MainActor @Test func aPlainUpdateStillSaysUpdated() async {
        let vm = Self.pluginsViewModel(returning: "✓ Plugin weather updated.", exitCode: 0)
        vm.update(Self.plugin("weather"))
        let message = await Self.awaitMessage(on: vm)
        #expect(vm.messageIsFailure == false)
        #expect(message == "Updated")
    }

    // MARK: - the Migrate button is gone (round-4 decision 4)

    /// `_cmd_config_migrate` runs `migrate_config(interactive=True)`, which
    /// reaches a bare `input()` with no `EOFError` guard
    /// (`hermes_cli/config.py:3653`, `:1289-1297`;
    /// `hermes_cli/cli_output.py:29-37` @ v2026.9.7). Scarf gives it no stdin,
    /// so the run can die after applying migrations and before stamping
    /// `_config_version` (`:1374-1378`). Decision 4 hides the button and
    /// points at a terminal on the host; this pins that no code path still
    /// shells the verb.
    @Test func nothingInScarfShellsConfigMigrate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        for dir in ["scarf", "ScarfGo", "Packages/ScarfCore/Sources"] {
            let base = root.appendingPathComponent(dir)
            guard let walk = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where line.contains("\"config\", \"migrate\"") {
                    offenders.append("\(url.lastPathComponent):\(n + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "\n")))
    }
}
