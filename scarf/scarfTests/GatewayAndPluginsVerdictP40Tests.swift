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
    @MainActor @Test func aStopWithNothingRunningReportsTheNeutralNote() async throws {
        let vm = Self.gatewayViewModel(
            mutation: "✗ No gateway running for this profile", exitCode: 0
        )
        vm.stopGateway()
        await Self.until(timeout: 10) { vm.actionMessage != nil }
        let message = try #require(vm.actionMessage)
        #expect(vm.actionFailed == false)
        #expect(message.contains("Gateway stopped"))
        #expect(message.contains("Nothing was running"))
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

    /// The two `gateway restart` call sites the finding did not name —
    /// `PlatformsViewModel.restartGateway` and `MCPServersViewModel`'s
    /// restart banner — reach it through `HermesFileService.restartGateway`,
    /// which returns the verdict now. Found by walking the verb's callers
    /// after the return type changed, which is the point of changing it.
    @Test func noCallSiteStillReadsAGatewayVerbsExitCode() throws {
        // Both the literal pair and the `["gateway", verb]` variable form:
        // any line that mentions the argv head and one of the three verbs is
        // building the argv by hand. `HermesGatewayServiceVerdict.argv(_:)`
        // is the only sanctioned speller, and it lives in ScarfCore's own
        // file, which spells the verbs as enum cases rather than as quoted
        // strings next to `"gateway"`.
        let verbs = ["\"start\"", "\"stop\"", "\"restart\"", "verb"]
        let lines = try Self.strippedSourceLines()
        let offenders = lines
            .filter { entry in
                // The sanctioned speller itself lives here, and it is the one
                // line in the app that is SUPPOSED to say `["gateway", verb…]`.
                guard !entry.where.contains("/HermesCLIOutcome.swift:") else { return false }
                guard entry.line.contains("\"gateway\",") else { return false }
                return verbs.contains { entry.line.contains($0) }
            }
            .map(\.where)
        // …and the sanctioned speller is still there, so the exemption above
        // is an exemption and not a hole.
        #expect(lines.contains {
            $0.where.contains("HermesCLIOutcome.swift")
                && $0.line.contains("[\"gateway\",verb.rawValue]")
        }, "HermesGatewayServiceVerdict.argv no longer spells the argv — re-point this sweep")
        #expect(offenders.isEmpty, Comment(rawValue:
            "these build the argv by hand instead of going through HermesGatewayServiceVerdict:\n"
            + offenders.joined(separator: "\n")))
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
        let offenders = try Self.strippedSourceLines()
            .filter { $0.line.contains("\"config\",\"migrate\"") }
            .map(\.where)
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "\n")))
    }

    // MARK: - source sweeps

    /// The three source roots every Scarf-authored `.swift` file lives under.
    /// Spelled exactly as they sit on disk: the iOS target is `Scarf iOS`,
    /// NOT `ScarfGo` — P40 swept a directory that has not existed for
    /// several releases and the enumerator silently returned nothing.
    static let sourceRoots = ["scarf", "Scarf iOS", "Packages/ScarfCore/Sources"]

    /// `…/scarf` — the parent of `scarfTests`, which is where `sourceRoots`
    /// resolve from.
    static var repoScarfRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every source line in ``sourceRoots``, whitespace REMOVED, paired with
    /// its `file:line`. Stripping whitespace is what stops a matcher from
    /// being dodged by a reformat: `["gateway", "start"]` and
    /// `["gateway","start"]` are the same argv and must be the same match.
    ///
    /// Throws when a listed root is missing, so the sweep can never pass by
    /// reading nothing.
    static func strippedSourceLines() throws -> [(where: String, line: String)] {
        var out: [(where: String, line: String)] = []
        for dir in sourceRoots {
            let base = repoScarfRoot.appendingPathComponent(dir)
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir)
                    && isDir.boolValue,
                    Comment(rawValue: "source root missing — the sweep would read nothing: \(base.path)"))
            let walk = try #require(
                FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil),
                Comment(rawValue: "could not enumerate \(base.path)")
            )
            for case let url as URL in walk where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    out.append((
                        where: "\(dir)/\(url.lastPathComponent):\(n + 1)",
                        line: line.filter { !$0.isWhitespace }
                    ))
                }
            }
        }
        #expect(out.count > 10_000, "premise: the sweep actually read the sources")
        return out
    }
}
