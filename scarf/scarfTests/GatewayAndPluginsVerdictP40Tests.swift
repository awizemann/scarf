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

    /// The regression the phase exists for: exit 0 with a REFUSAL the backend
    /// printed is a failure, and the banner is sticky rather than clearing on
    /// a settle timer. Pre-fix this reported "Gateway start requested".
    ///
    /// P40c: the line below is a refusal — `_no_backend_exit`'s
    /// `("start", "container")` entry (`hermes_cli/gateway.py:5860-5866` @
    /// v2026.9.7) prints it at column 0 and exits 0 — but it was matching no
    /// failure marker, so once the `.unconfirmed` arm reached the banner this
    /// case turned neutral. The marker is what makes it a failure; the
    /// genuinely SILENT exit-0 start is the neutral arm's, and
    /// `GatewayAndPluginsVerdictP40cTests` owns it.
    @MainActor @Test func aContainerRefusalAtExitZeroIsReportedAsAFailure() async {
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
        // Matched against each file's whole whitespace-stripped BLOB, not
        // line by line: an argv split across lines by a formatter —
        //     ["gateway",
        //      "start"]
        // — is the same argv and has to be the same match. The per-line form
        // this sweep used to have let exactly that through.
        let files = try Self.strippedSourceFiles()
        // The sanctioned speller itself lives in ScarfCore's own file, and it
        // is the one place that is SUPPOSED to say `["gateway", verb…]`.
        let exempt = "HermesCLIOutcome.swift"
        let offenders = files
            .filter { !$0.where.hasSuffix(exempt) }
            .filter { file in
                Self.gatewayArgvPatterns.contains { file.blob.range(of: $0, options: .regularExpression) != nil }
            }
            .map(\.where)
        // …and the sanctioned speller is still there, so the exemption above
        // is an exemption and not a hole.
        #expect(files.contains {
            $0.where.hasSuffix(exempt) && $0.blob.contains("[\"gateway\",verb.rawValue]")
        }, "HermesGatewayServiceVerdict.argv no longer spells the argv — re-point this sweep")
        #expect(offenders.isEmpty, Comment(rawValue:
            "these build the argv by hand instead of going through HermesGatewayServiceVerdict:\n"
            + offenders.joined(separator: "\n")))
    }

    /// Every way a `gateway <verb>` argv can be spelled by hand, as regexes
    /// over a whitespace-stripped file blob.
    ///
    /// - the three literal pairs;
    /// - the VARIABLE form, `["gateway", verb]`. The old token for this was
    ///   the bare string `"verb"`, which matched `"gateway",verbose` — and
    ///   anything else beginning `verb` — so the sweep's own matcher was
    ///   looser than its message claimed. It is an identifier boundary now:
    ///   `verb` or a name ending in `Verb`, and nothing longer.
    /// - INTERPOLATION, `"gateway \(verb)"` / `"gateway\(verb.rawValue)"`,
    ///   which is a hand-built argv the two token forms above cannot see at
    ///   all. Lower-case `gateway` immediately followed by `\(` is only ever
    ///   an argv: the user-facing copy says `Gateway`.
    static let gatewayArgvPatterns = [
        #""gateway","(start|stop|restart)""#,
        #""gateway",[A-Za-z_]*[Vv]erb\b"#,
        #""gateway\\\("#,
    ]

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
        // Whole-file blobs and an interpolation matcher, for the same reasons
        // the gateway sweep has them. NB there is no concatenated
        // `"config migrate"` matcher here on purpose: round-4 decision 4
        // replaced the button with copy that TELLS the user to run
        // `hermes config migrate` in a terminal, and that hint reads as
        // `configmigrate` once whitespace is stripped.
        let patterns = [
            #""config","migrate""#,
            #""config",[A-Za-z_]*[Mm]igrate\b"#,
            #""config\\\("#,
        ]
        let offenders = try Self.strippedSourceFiles()
            .filter { file in
                patterns.contains { file.blob.range(of: $0, options: .regularExpression) != nil }
            }
            .map(\.where)
        #expect(offenders.isEmpty, Comment(rawValue:
            "these shell `config migrate`, which decision 4 removed:\n"
            + offenders.joined(separator: "\n")))
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

    /// Every Scarf-authored source FILE under ``sourceRoots``, paired with its
    /// whole contents with all whitespace REMOVED.
    ///
    /// Stripping whitespace is what stops a matcher from being dodged by a
    /// reformat — `["gateway", "start"]` and `["gateway","start"]` are the
    /// same argv and must be the same match — and blobbing the whole file is
    /// what stops it from being dodged by a NEWLINE, which the earlier
    /// per-line version could not see across.
    ///
    /// Fails the calling test when a listed root is missing or cannot be
    /// enumerated, and asserts a line-count floor, so the sweep can never
    /// pass by reading nothing.
    static func strippedSourceFiles() throws -> [(where: String, blob: String)] {
        var out: [(where: String, blob: String)] = []
        var lineCount = 0
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
                lineCount += text.split(separator: "\n", omittingEmptySubsequences: false).count
                out.append((
                    where: "\(dir)/\(url.lastPathComponent)",
                    blob: text.filter { !$0.isWhitespace }
                ))
            }
        }
        #expect(lineCount > 10_000, "premise: the sweep actually read the sources")
        return out
    }
}
