import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P28 of the round-2 whole-surface audit — the cross-phase review's own
/// findings, i.e. the bugs the earlier phases introduced or left behind.
///
/// Every test here fails when its fix is reverted; the comment on each says
/// how.
@Suite("P28 — cross-phase review remediation")
@MainActor
struct HermesP28CrossPhaseRemediationTests {

    // MARK: - H1 · the widen-for-current hatch has to be REACHABLE

    /// Render the dotted `hermes config set` keys a setup form produced back
    /// into the nested YAML block Hermes writes for them, so the detection
    /// test is fed the shape the form actually causes rather than a shape the
    /// test author chose.
    private static func nestedYAML(from pairs: [(key: String, value: String)]) -> String {
        // tree[path] = children; leaves carry a value.
        final class Node { var children: [String: Node] = [:]; var value: String? }
        let root = Node()
        for (key, value) in pairs {
            var node = root
            for segment in key.split(separator: ".").map(String.init) {
                if node.children[segment] == nil { node.children[segment] = Node() }
                node = node.children[segment]!
            }
            node.value = value
        }
        func render(_ node: Node, indent: Int) -> String {
            var out = ""
            for name in node.children.keys.sorted() {
                let child = node.children[name]!
                let pad = String(repeating: " ", count: indent)
                if let value = child.value {
                    out += "\(pad)\(name): \(value.isEmpty ? "''" : value)\n"
                } else {
                    out += "\(pad)\(name):\n" + render(child, indent: indent + 2)
                }
            }
            return out
        }
        return render(root, indent: 0)
    }

    /// The reviewer's H1: `PlatformsView` asks `configuredPlatforms.contains`,
    /// and P23's eight newly-gated rows could never be in that set — the
    /// detector looked only for a TOP-LEVEL `<name>:` section or an
    /// `identifyingEnvVar` arm, while the ntfy form writes
    /// `platforms.ntfy.extra.*` and `NTFY_TOPIC` and has no arm. So
    /// `isVisible`'s whole purpose was defeated and a failed probe (`.empty`)
    /// removed a channel the user had set up in Scarf's own form.
    ///
    /// This drives the REAL form and then the REAL detector. It fails without
    /// the nested-prefix check (the set comes back without `ntfy`, and the
    /// row vanishes from the roster on a sub-floor host).
    @Test func theNtfyFormsOwnConfigMakesTheRowVisibleBelowItsFloor() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }

        // Record what the form hands `hermes config set`.
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var pairs: [(key: String, value: String)] = []
            var recorded: [(key: String, value: String)] {
                lock.lock(); defer { lock.unlock() }; return pairs
            }
            func runner() -> HermesCLIRunner {
                { [self] args, _ in
                    // P39: `config set -- <key> <value>`.
                    if args.count >= 5, args[0] == "config", args[1] == "set", args[2] == "--" {
                        lock.lock(); pairs.append((args[3], args[4])); lock.unlock()
                    }
                    // P39: the form is now OUTPUT-judged, so an empty stdout
                    // is a refusal. Echo the emitter's own success line
                    // (`hermes_cli/config.py:3521`).
                    let key = args.count >= 4 ? args[3] : "?"
                    return (output: "✓ Set \(key) = x in /tmp/config.yaml", exitCode: 0)
                }
            }
        }
        let recorder = Recorder()

        let vm = NtfySetupViewModel(context: home.context, cliRunner: recorder.runner())
        vm.topic = "hermes-alerts"
        vm.save()
        // `commitSave` hops off the main actor and back; wait for the outcome.
        let deadline = Date().addingTimeInterval(120)
        while vm.isSaving, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(vm.isSaving == false, "the ntfy save never completed")

        let pairs = recorder.recorded
        #expect(!pairs.isEmpty, "the ntfy form wrote no config keys at all")
        // The premise of H1: NOTHING the form writes is a top-level section.
        #expect(
            pairs.allSatisfy { $0.key.hasPrefix("platforms.ntfy.") },
            "the ntfy form's config keys moved: \(pairs.map(\.key))"
        )

        try Self.nestedYAML(from: pairs)
            .write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)

        let configured = PlatformsViewModel.computeConfiguredPlatforms(context: home.context)
        #expect(configured.contains("ntfy"), "the config the ntfy form itself wrote reads as unconfigured")

        // …and that is what keeps the row on screen when the probe failed or
        // the host is below ntfy's v0.15 floor — the end-to-end assertion
        // `HermesP23RosterAndGateTests` could only make with a literal `true`.
        let roster = KnownPlatforms.visible(on: .empty) { configured.contains($0) }
        #expect(roster.contains { $0.name == "ntfy" }, "a configured ntfy row was hidden by a failed probe")
        let v014 = HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.5.16)")
        #expect(KnownPlatforms.visible(on: v014) { configured.contains($0) }.contains { $0.name == "ntfy" })
        // An UNCONFIGURED sub-floor row is still hidden — the gate still works.
        #expect(!KnownPlatforms.visible(on: v014) { _ in false }.contains { $0.name == "ntfy" })
    }

    /// The `.env`-only half of the same finding: `SimpleXSetupViewModel`
    /// writes no config.yaml key at all (`configKV: [:]`), so the nested
    /// check cannot see it and the `identifyingEnvVar` arm is the only
    /// signal. Fails without the `simplex` arm.
    @Test func theSimpleXFormsOwnEnvMakesTheRowConfigured() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        #expect(HermesEnvService(context: home.context).setMany(["SIMPLEX_WS_URL": "ws://127.0.0.1:5225"]))
        let configured = PlatformsViewModel.computeConfiguredPlatforms(context: home.context)
        #expect(configured.contains("simplex"), "the env var the SimpleX form writes reads as unconfigured")
    }

    /// Guard rail on the other side: a nested block for a platform nobody
    /// configured must not appear, and `platforms:` alone is not a platform.
    @Test func nestedDetectionDoesNotInventPlatforms() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let yaml = """
        platforms:
          ntfy:
            extra:
              topic: alerts
        gateway:
          platforms:
            line:
              enabled: true
        """
        try yaml.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        let configured = PlatformsViewModel.computeConfiguredPlatforms(context: home.context)
        #expect(configured.contains("ntfy"))
        #expect(configured.contains("line"), "`gateway.platforms.line` is a configured line block")
        #expect(!configured.contains("teams"))
        #expect(!configured.contains("buzz"))
        #expect(!configured.contains("cli"), "`cli` is never in the set; `hasConfigBlock` answers it directly")
    }

    // MARK: - L6 · "not looked yet" is not "not configured"

    /// Before the detached load lands, `configuredPlatforms` is empty because
    /// nothing has been READ. Answering the roster filter `false` there hid a
    /// configured sub-floor row for the first paint and popped it in; the
    /// `hasLoadedConfiguredPlatforms` flag is what lets the view tell the two
    /// states apart. Fails if the flag starts `true` or is never set.
    @Test func theConfiguredSetReportsWhetherItHasBeenRead() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try "platforms:\n  ntfy:\n    extra:\n      topic: a\n"
            .write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)

        let vm = PlatformsViewModel(context: home.context)
        #expect(vm.hasLoadedConfiguredPlatforms == false, "the VM claimed a read it had not done")
        #expect(vm.configuredPlatforms.isEmpty)

        vm.load(force: true)
        let deadline = Date().addingTimeInterval(120)
        while !vm.hasLoadedConfiguredPlatforms, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(vm.hasLoadedConfiguredPlatforms, "the load never reported landing")
        #expect(vm.configuredPlatforms.contains("ntfy"))
    }

    // MARK: - H3 · the Tools tab's roster goes through the same gate

    /// P23 gated the Platforms list and left `ToolsViewModel` handing
    /// `KnownPlatforms.all` to the picker, which shells
    /// `hermes tools enable … --platform <name>` — so a 0.14 host hid `ntfy`
    /// in one surface while the other offered to configure an adapter it does
    /// not have (charter C5). Both surfaces now answer through
    /// `KnownPlatforms.visible(on:isConfigured:)`; this pins the seam's
    /// behaviour for the Tools surface's two inputs.
    @Test func theSharedSeamGatesUnconfiguredRowsAndSparesConfiguredOnes() {
        // `.empty` is the failed/undetected probe — the case that hides every
        // floored row at once, and the one P23's hatch exists for. (The eight
        // rows' own floors span 0.12…0.17, so no single real version is below
        // all of them; `HermesP23RosterAndGateTests` pins each floor.)
        let unknown = HermesCapabilities.empty
        let gated = ["ntfy", "simplex", "line", "teams", "yuanbao", "google_chat", "whatsapp_cloud", "buzz"]

        let hidden = KnownPlatforms.visible(on: unknown) { _ in false }.map(\.name)
        for name in gated {
            #expect(!hidden.contains(name), "\(name) was offered on a host with no adapter for it")
        }
        #expect(hidden.contains("cli"))
        #expect(hidden.contains("telegram"))

        // Configured rows survive, one row at a time (so this cannot pass by
        // the filter degenerating to "show everything").
        for name in gated {
            let shown = KnownPlatforms.visible(on: unknown) { $0 == name }.map(\.name)
            #expect(shown.contains(name), "a configured \(name) was hidden")
            for other in gated where other != name {
                #expect(!shown.contains(other), "\(other) leaked in while only \(name) was configured")
            }
        }
    }

    /// The Tools tab used to run its OWN `hasSuffix(":")` section scan. With
    /// the roster now gated on that answer, a weaker second detector would
    /// hide a configured row in one surface and show it in the other, so both
    /// read the same function. Fails if `loadPlatforms` goes back to a
    /// private parser: the nested-only config below reads as unconfigured and
    /// the row's status flips to `.notConfigured`.
    @Test func toolsAndPlatformsAgreeOnWhatIsConfigured() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        // Only shapes the old scan missed: a nested block and a flow-empty
        // section.
        try "platforms:\n  ntfy:\n    extra:\n      topic: a\nslack: {}\n"
            .write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)

        let tools = ToolsViewModel(context: home.context)
        await tools.load()
        #expect(tools.hasLoadedPlatforms)
        #expect(tools.configuredPlatformNames.contains("ntfy"))
        #expect(tools.configuredPlatformNames.contains("slack"))
        #expect(tools.connectivity["ntfy"] == .configured)
        #expect(tools.connectivity["slack"] == .configured)
        #expect(tools.connectivity["buzz"] == .notConfigured)
        // Same file, same answer as the Platforms list.
        #expect(
            tools.configuredPlatformNames
                == PlatformsViewModel.computeConfiguredPlatforms(context: home.context)
        )
    }

    // MARK: - M1/M2 · a retired run must not outlive its own stop

    /// P22 moved `proc.run()` into a detached task, so `self.process` /
    /// `self.stdoutPipe` are published only AFTER the spawn resumes. A
    /// `start()` landing in that window finds `process == nil`, so `stop()`
    /// can retire neither the previous run's process nor its
    /// `readabilityHandler` — and the reader's `append`/`markEOF` carry no
    /// generation check (they run on the pipe's queue), so a live stale reader
    /// writes into, and can `markEOF`, the replacement run's buffer. That is
    /// P21's success-reported-as-failure bug: a verdict judged on the previous
    /// run's text, or before this run's output has drained.
    ///
    /// The spawn's generation-mismatch branch is the only place that window
    /// can be closed, and it now unhooks the reader there (plus each run gets
    /// its OWN `OutputInbox`, so even an unhooked-too-late reader writes
    /// somewhere nothing drains). `readabilityHandler` is readable, so the
    /// assertion is on the invariant itself rather than on a timing-dependent
    /// symptom. Fails without the fix: the retired run's handler is still
    /// installed.
    @Test func aRetiredRunsReaderIsUnhookedWhenItsSpawnResumes() async {
        func sh(_ script: String) -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            return p
        }
        // A blocks, so it cannot reach EOF on its own and unhook itself.
        let runA = sh("exec sleep 30")
        let runB = sh("sleep 1.2; printf '  \u{2713} Authenticated with b - 3 tool(s) available\n'; exit 0")

        final class Handout { var count = 0 }
        let handout = Handout()
        let controller = MCPLoginController(context: .local, makeLoginProcess: { _ in
            handout.count += 1
            return handout.count == 1 ? runA : runB
        })
        controller.start(server: "a", flow: nil)
        // No `await` between the two starts: B lands before A's spawn
        // continuation can have resumed, which IS the window — `start()`'s
        // `stop()` sees a nil `stdoutPipe` and unhooks nothing.
        controller.start(server: "b", flow: nil)

        let pipeA = runA.standardOutput as? Pipe
        #expect(pipeA != nil, "the controller did not wire a stdout pipe for run A")
        let deadline = Date().addingTimeInterval(60)
        while pipeA?.fileHandleForReading.readabilityHandler != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(pipeA?.fileHandleForReading.readabilityHandler == nil,
                "the retired run's reader is still installed and feeding the live run")
        #expect(runA.isRunning == false, "the retired run was not terminated")

        // …and run B is still judged on its own output, by its own success line.
        while controller.succeeded == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.succeeded == true, "run B: \(controller.errorMessage ?? "nil")")
        #expect(controller.output.contains("Authenticated with b"))
        controller.stop()
    }

    // MARK: - M3/L5 · the trace export's redaction default

    /// P25 gave `trace` an inverted flag (ON emits nothing, OFF emits
    /// `--no-redact`) but left the toggle defaulting to OFF for every format,
    /// so on a v0.21.1 host Scarf's DEFAULT trace export actively opted out of
    /// redaction — less than every prior Scarf release and every pre-0.21.1
    /// host, for the one format that exists to leave the machine
    /// (`_export_trace`: "Redaction is ON by default (traces leave the machine
    /// with --upload); --no-redact opts out", `hermes_cli/sessions_cmd.py:382-383`,
    /// applied at `:395` @ v2026.9.7).
    ///
    /// Fails without the per-format default: selecting `trace` leaves the
    /// toggle OFF and the argv carries `--no-redact`.
    @Test func selectingTraceDefaultsToRedactedAndEmitsNoOptOut() {
        let vm = SessionsViewModel(context: .local)
        #expect(vm.exportRedact == false, "jsonl's default is Hermes's: no --redact unless asked")

        vm.exportFormatChanged(from: .jsonl, to: .trace)
        #expect(vm.exportRedact, "the default trace export opted OUT of redaction")
        #expect(
            !SessionsViewModel.exportArguments(
                output: "-", sessionId: "abc", format: .trace,
                redact: vm.exportRedact, traceNoRedactAvailable: true
            ).contains("--no-redact")
        )
        // Turning it OFF is still how a user opts out (round-2 decision 3).
        vm.exportRedact = false
        #expect(
            SessionsViewModel.exportArguments(
                output: "-", sessionId: "abc", format: .trace,
                redact: false, traceNoRedactAvailable: true
            ).contains("--no-redact")
        )
    }

    /// L5: switching AWAY from `trace` used to force the toggle OFF, throwing
    /// away an ON choice the user had made for a streamed format. It restores
    /// what they had instead. Fails on the old `exportRedact = false` branch
    /// for the ON case.
    @Test func switchingAwayFromTraceRestoresTheUsersOwnChoice() {
        let vm = SessionsViewModel(context: .local)
        for userChoice in [true, false] {
            vm.exportRedact = userChoice
            vm.exportFormatChanged(from: .jsonl, to: .trace)
            #expect(vm.exportRedact, "trace is redacted by default regardless")
            vm.exportFormatChanged(from: .trace, to: .jsonl)
            #expect(vm.exportRedact == userChoice, "the user's own \(userChoice) choice was discarded")
        }
        // A switch between two non-trace formats changes nothing, and a no-op
        // switch does not clobber the remembered value.
        vm.exportRedact = true
        vm.exportFormatChanged(from: .jsonl, to: .markdown)
        #expect(vm.exportRedact)
        vm.exportFormatChanged(from: .trace, to: .trace)
        #expect(vm.exportRedact)
    }

    // MARK: - M4/L3 · the last literal boolish readers

    /// Hermes reads `skip_attachments` as plain Python truthiness over the
    /// PyYAML-TYPED value (`extra.get("skip_attachments", False)`,
    /// `plugins/platforms/email/adapter.py:354` @ v2026.9.7), so a YAML bool
    /// written `yes` / `on` / `1` is ON on the host. The literal
    /// `stripYAMLQuotes(raw) == "true"` read every one of them as OFF — the
    /// class P18 declared closed by giving Scarf ONE helper, in a line P22
    /// then moved without routing it through that helper.
    ///
    /// Fails on the literal compare: the toggle reads OFF for `yes`/`on`/`1`/
    /// `True`, and a Save from that form writes the user's live setting away.
    @Test func theEmailFormReadsEveryYAMLBoolSpellingForSkipAttachments() async throws {
        let spellings = [("true", true), ("yes", true), ("on", true), ("1", true),
                         ("True", true), ("false", false), ("no", false),
                         ("off", false), ("0", false)]
        // The rule itself, with no I/O in the way.
        for (scalar, expected) in spellings {
            #expect(HermesYAML.boolishValue(scalar) == expected, "boolishValue(\(scalar))")
        }
        // …and the form's own read of a config.yaml carrying each spelling.
        for (scalar, expected) in spellings {
            let home = try TempHermesHome()
            defer { home.cleanup() }
            let yaml = "platforms:\n  email:\n    extra:\n      skip_attachments: \(scalar)\n"
            try yaml.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)

            let vm = EmailSetupViewModel(context: home.context)
            vm.load()
            let deadline = Date().addingTimeInterval(120)
            while vm.isLoading, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            // Separate "the load did not finish" from "the load read the wrong
            // value": under heavy parallel contention this form's load has been
            // observed taking minutes, and a timed-out read leaves
            // `skipAttachments` at its unset default — which reads as a
            // boolish bug and is not one.
            guard !vm.isLoading else {
                Issue.record("skip_attachments: \(scalar) — the form's load never completed")
                continue
            }
            // The parsed raw value is reported on failure: a read that came
            // back nil is a file/fixture problem, a read that came back with
            // the scalar is a boolish problem, and the two want different
            // fixes.
            let raw = HermesFileService.parseNestedYAML(
                home.context.readText(home.context.paths.configYAML) ?? ""
            ).values["platforms.email.extra.skip_attachments"]
            #expect(vm.skipAttachments == expected,
                    "skip_attachments: \(scalar) (parsed raw: \(raw ?? "<nil>"))")
        }
    }
}
