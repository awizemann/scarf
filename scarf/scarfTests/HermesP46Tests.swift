import Foundation
import Testing
import ScarfCore
@testable import scarf

/// P46 — the app-target half of the round-5 remediation.
enum P46Repo {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // scarfTests
            .deletingLastPathComponent()   // scarf
            .deletingLastPathComponent()   // repo root
    }
    static func source(_ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}

// MARK: - Finding 4: the bot editor judged three writes by exit code

/// `perform` discarded the verdict `isBenignUnset` had just computed —
/// `results.first(where: { $0.exitCode != 0 })` — so a managed host's exit-0
/// refusal reported "saved" over an untouched pin. The two row toggles had
/// the same hole in their own spelling.
@Suite("P46 · bot editor write verdicts")
@MainActor
struct BotAgentVerdictP46Tests {

    private typealias Mock = BotAgentViewModelTests.MockBackend

    private static func viewModel(_ backend: Mock) -> BotAgentViewModel {
        BotAgentViewModel(
            profileName: "research",
            capabilities: HermesCapabilities(
                versionLine: "hermes 0.21.1",
                semver: .init(major: 0, minor: 21, patch: 1),
                dateVersion: nil
            ),
            backend: backend
        )
    }

    private static func settle(
        _ condition: @MainActor () -> Bool, _ comment: Comment = "timed out"
    ) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record(comment)
    }

    static let managedRefusal =
        "Cannot save configuration: /etc/hermes/config.yaml is managed by your administrator and cannot be changed."

    @Test func aModelPinRefusedAtExitZeroIsReported() async {
        let backend = Mock()
        backend.pinExitZeroRefusal = Self.managedRefusal
        let vm = Self.viewModel(backend)
        vm.load(force: true)
        await Self.settle({ vm.config != nil }, "config never loaded")
        vm.setModelPin(model: "claude-opus-4.6", provider: "anthropic")
        await Self.settle({ vm.errorMessage != nil },
                          "the exit-0 refusal was reported as a successful pin")
        #expect(vm.errorMessage?.contains("managed by your administrator") == true)
    }

    @Test func aToolsetToggleRefusedAtExitZeroIsReportedAndReverted() async {
        let backend = Mock(toolsets: ["web": false])
        backend.toolsetExitZeroRefusal = Self.managedRefusal
        let vm = Self.viewModel(backend)
        vm.load(force: true)
        await Self.settle({ vm.toolsets.contains { $0.name == "web" } }, "toolsets never loaded")
        vm.setToolset(HermesToolset(name: "web", description: "", icon: "", enabled: false),
                      enabled: true)
        await Self.settle({ vm.rowErrors["web"] != nil },
                          "the exit-0 refusal was reported as a successful toggle")
        #expect(vm.rowErrors["web"]?.contains("managed by your administrator") == true)
    }

    @Test func anMCPToggleRefusedAtExitZeroIsReported() async {
        let backend = Mock(mcp: [(name: "github", enabled: nil)])
        backend.mcpExitZeroRefusal = Self.managedRefusal
        let vm = Self.viewModel(backend)
        vm.load(force: true)
        await Self.settle({ !vm.mcpServers.isEmpty }, "mcp servers never loaded")
        vm.setMCPServer(BotMCPServerState(name: "github", explicitlyEnabled: true), enabled: false)
        await Self.settle({ vm.rowErrors["github"] != nil },
                          "the exit-0 refusal was reported as a successful toggle")
        #expect(vm.rowErrors["github"]?.contains("managed by your administrator") == true)
    }

    /// A clean write still succeeds — the verdict must not fail-closed.
    @Test func aCleanPinStillSucceeds() async {
        let backend = Mock()
        let vm = Self.viewModel(backend)
        vm.load(force: true)
        await Self.settle({ vm.config != nil }, "config never loaded")
        vm.setModelPin(model: "claude-opus-4.6", provider: "anthropic")
        await Self.settle({ !vm.isPinBusy }, "the pin never finished")
        #expect(vm.errorMessage == nil)
    }

    /// The root Tools screen is the same verb through another door.
    @Test func theRootToolsScreenJudgesTheSameWay() throws {
        let source = try P46Repo.source("scarf/scarf/Features/Tools/ViewModels/ToolsViewModel.swift")
        #expect(source.contains("HermesToolsToggle.judge("),
                "the root Tools toggle still judges `tools enable|disable` by exit code")
        #expect(source.contains("HermesToolsToggle.argv("))
    }

    /// And `perform` takes a verdict rather than reading the exit code.
    @Test func performTakesAVerdict() throws {
        let source = try P46Repo.source("scarf/scarf/Features/Bots/ViewModels/BotAgentViewModel.swift")
        #expect(!source.contains("results.first(where: { $0.exitCode != 0 })"),
                "`perform` is still exit-code-judged")
        #expect(source.contains("verdict: Self.configSetVerdict"))
        #expect(source.contains("verdict: Self.configUnsetVerdict"))
    }
}

// MARK: - Finding 8: the direct-YAML writers had no managed bounce

@Suite("P46 · direct config.yaml writes bounce on a managed host")
struct DirectYAMLManagedBounceP46Tests {

    /// `saveDirectYAML` edits config.yaml through `GuardedTextFile`, so
    /// Hermes never sees the write and there is nothing downstream to refuse
    /// it. The pre-emptive bounce `enqueueConfigWrite` does is the only
    /// guard available.
    @Test func theBounceRunsBeforeTheWriteChainHop() throws {
        let source = try P46Repo.source(
            "scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift")
        let decl = try #require(source.range(of: "private func saveDirectYAML("))
        let body = source[decl.upperBound...].prefix(2400)
        let bounce = try #require(body.range(of: "if let refusal = managedBannerText {"),
                                  "saveDirectYAML has no managed-host bounce")
        let chain = try #require(body.range(of: "let previous = writeChain"))
        #expect(bounce.lowerBound < chain.lowerBound,
                "the bounce runs after the write is already queued")
        #expect(body[bounce.upperBound...].prefix(120).contains("showSaveFailure(refusal)"))
    }

    /// Both config.yaml write doors now carry it.
    @Test func bothWriteDoorsCarryTheBounce() throws {
        let source = try P46Repo.source(
            "scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift")
        let occurrences = source.components(separatedBy: "if let refusal = managedBannerText {").count - 1
        #expect(occurrences >= 2, "only \(occurrences) of the two write doors bounce")
    }
}

// MARK: - Finding 12: every `config set` goes through HermesConfigSet

/// P39 routed the `config set` argv and verdict through one type. The iOS
/// chat preflight hand-rolled its own shell string — no `--`, judged by exit
/// code — and the branch missed it. This is the floor that keeps the next one
/// from being missed: a source scan over BOTH targets plus iOS.
@Suite("P46 · one config set argv")
struct ConfigSetArgvSweepP46Tests {

    /// Directories to walk. `ScarfCore` owns `HermesConfigSet` itself, so its
    /// own definition is excluded by file, not by directory.
    static let roots = [
        "scarf/scarf",
        "scarf/Scarf iOS",
        "scarf/Packages/ScarfCore/Sources/ScarfCore",
    ]

    /// The one file allowed to spell the argv literally: the type that
    /// defines it.
    static let definitionFile = "HermesCLIOutcome.swift"

    static func swiftFiles(under relative: String) -> [URL] {
        let root = P46Repo.root.appendingPathComponent(relative)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        while let url = walker.nextObject() as? URL {
            if url.pathExtension == "swift" { out.append(url) }
        }
        return out
    }

    /// Whether `line` INVOKES `hermes config set` rather than merely naming
    /// it.
    ///
    /// Two shapes are invocations: an argv literal (`"config", "set"`) and a
    /// shell command string (`\(hermes) config set …`). A DIAGNOSTIC that
    /// quotes the verb is not — every `logger.warning("hermes config set \(key)
    /// failed: …")` on the tree names the command it is reporting on, and a
    /// sweep that cannot tell the two apart is a sweep somebody disables.
    /// Calibrated by ``theMatcherIsCalibrated``.
    static func invokesConfigSet(_ line: String) -> Bool {
        let bare = line.trimmingCharacters(in: .whitespaces)
        guard !bare.hasPrefix("//"), !bare.hasPrefix("*") else { return false }
        if bare.range(of: #""config"\s*,\s*"set""#, options: .regularExpression) != nil { return true }
        guard bare.contains("\"") else { return false }
        // A shell string. `logger`/`message:`/`Issue.record` lines report on
        // a run that already happened.
        if bare.contains("logger.") || bare.contains("message:") || bare.contains("Issue.record") {
            return false
        }
        return bare.range(of: #"config set ['"\\]"#, options: .regularExpression) != nil
    }

    @Test func theMatcherIsCalibrated() {
        // Invocations.
        #expect(Self.invokesConfigSet(#"let argv = ["config", "set", key, value]"#))
        #expect(Self.invokesConfigSet(##"let script = "\(hermes) config set 'model.provider' '\(v)'""##))
        #expect(Self.invokesConfigSet(##"let script = "\(hermes) config set \(key) \(value)""##))
        // Not invocations.
        #expect(!Self.invokesConfigSet(##"logger.warning("hermes config set \(key) failed: \(out)")"##))
        #expect(!Self.invokesConfigSet(##"message: outcome.detail ?? "hermes config set \(key) did not confirm""##))
        #expect(!Self.invokesConfigSet("/// `hermes config set 'a' 'b'` is judged by output"))
        #expect(!Self.invokesConfigSet("let x = HermesConfigSet.argv(key: key, value: value)"))
    }

    @Test func noSurfaceHandRollsAConfigSetArgv() throws {
        var offenders: [String] = []
        var scanned = 0
        for root in Self.roots {
            for url in Self.swiftFiles(under: root) {
                guard url.lastPathComponent != Self.definitionFile else { continue }
                guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                for (i, line) in src.components(separatedBy: "\n").enumerated()
                where Self.invokesConfigSet(line) {
                    offenders.append("\(url.lastPathComponent):\(i + 1) — "
                                     + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        #expect(scanned > 300, Comment(rawValue: "the sweep scanned only \(scanned) files — its roots have moved"))
        #expect(offenders.isEmpty, Comment(rawValue: """
            A `hermes config set` argv is spelled by hand instead of coming \
            from `HermesConfigSet.argv` — which is where the `--` end-of-options \
            separator and the exit-0 refusal verdict live: \
            \(offenders.joined(separator: "; "))
            """))
    }

    /// The iOS preflight specifically: argv AND verdict.
    @Test func theIOSPreflightUsesBothHalves() throws {
        let source = try P46Repo.source("scarf/Scarf iOS/Chat/ChatView.swift")
        #expect(source.contains("HermesConfigSet.argv(key: key, value: value)"))
        #expect(source.contains("HermesConfigSet.judge(output: combined, exitCode: result.exitCode)"))
        #expect(!source.contains("config set 'model.provider'"),
                "the hand-rolled shell string is still there")
    }

    /// And the doc that named it the last caller of `setModelAndProvider` is
    /// corrected — it never came through there at all.
    @Test func theLegacyHelperNoLongerClaimsACaller() throws {
        let source = try P46Repo.source("scarf/scarf/Core/Services/HermesFileService.swift")
        #expect(!source.contains("iOS `ChatView`'s preflight is the only remaining caller"))
    }
}

// MARK: - Finding 13: stdout and stderr were welded together

@Suite("P46 · runHermesCLI output joining")
struct RunHermesCLIJoinP46Tests {

    /// Every anchored refusal marker asks whether a LINE starts with it
    /// (`HermesCLIVerdict.judge`'s `anchoredFailureMarkers`), and the exit-0
    /// refusal families print the refusal on stderr while stdout carries a
    /// success line. A stdout with no trailing newline welded the two, and
    /// the refusal stopped starting its line.
    @Test func aStdoutWithNoTrailingNewlineIsSeparated() throws {
        let source = try P46Repo.source("scarf/scarf/Core/Services/HermesFileService.swift")
        #expect(!source.contains("let combined = result.stdoutString + result.stderrString"),
                "stdout and stderr are still concatenated with no separator")
        #expect(source.contains("""
            let separator = (stdout.isEmpty || stdout.hasSuffix("\\n")) ? "" : "\\n"
            """))
    }

    /// The behaviour the separator buys, over the verdict that reads it.
    @Test func aWeldedRefusalIsInvisibleToAnAnchoredMarker() throws {
        let stdout = "✓ Set terminal.env = tmux in /Users/a/.hermes/config.yaml"  // no newline
        let stderr = "Cannot set TERMINAL_ENV: it is managed by your administrator (/etc/hermes/.env) and cannot be changed."
        let welded = HermesConfigSet.judge(output: stdout + stderr, exitCode: 0)
        let separated = HermesConfigSet.judge(output: stdout + "\n" + stderr, exitCode: 0)
        #expect(welded.warning == nil, "the welded form was never going to see the refusal")
        let warning = try #require(separated.warning,
                                   "the separated form must surface the partial write")
        #expect(warning.contains("Cannot set TERMINAL_ENV"))
    }
}
