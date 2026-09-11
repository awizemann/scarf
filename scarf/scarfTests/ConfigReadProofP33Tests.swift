import Testing
import Foundation
import os
import ScarfCore
@testable import scarf

/// Phase P33 of the round-3 whole-surface audit.
///
/// P22 detached the 15 platform setup forms and proved the `.env` half of
/// their load (`HermesEnvService.loadProven`). The config.yaml half stayed
/// tolerant — `loadConfig()` returns `.empty` for an unreadable file exactly
/// as it does for an absent one — so the hole P22 closed on `.env` was still
/// wide open on the other file: a blipped config.yaml read rendered a blank
/// form over live values, and a Save from there writes those blanks back.
///
/// `whatsapp_cloud` is the worst case because it is CONFIG-ONLY: the access
/// token, app secret and verify token all live in config.yaml, so one failed
/// read plus one Save issues `config set platforms.whatsapp_cloud.extra
/// .access_token ""` and `enabled false`. Signal and Email are the same shape
/// with the credentials split across both files.
///
/// The distinction that must survive: ABSENT is not a refusal. A fresh host
/// with no config.yaml has genuinely nothing set, the empty form is the
/// truth, and Save has to work or first-run setup is impossible.
///
/// Every test below fails when its fix is reverted:
///
/// * the three refusal tests fail if `loadForm` goes back to `loadConfig()` /
///   `readText(…) ?? ""`, or if `commitSave` stops consulting `loadRefusal`;
/// * `aFormOnAnAbsentConfigYamlStillSaves` fails if the proof is built on
///   `loadConfigResult()`, whose `.failure` cannot tell absent from damaged;
/// * the two Settings tests fail if `saveDirectYAML` leaves `writeChain`.
@Suite("P33 — proven config.yaml reads, direct-YAML saves on the write chain")
@MainActor
struct ConfigReadProofP33Tests {

    private typealias CLILog = MainActorBlockingWritesP11Tests.CLILog

    /// An isolated Hermes home so every read/write lands in a temp dir and
    /// never the developer's real `~/.hermes`.
    private static func scratchContext() -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p33-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return .local(home: home)
    }

    /// Write a config.yaml with live credentials in it, then make it
    /// unreadable — the "it's there and two reads of it failed" case
    /// `GuardedTextFile` proves, which is what an SSH blip or a permissions
    /// mistake looks like from Scarf's side.
    ///
    /// Returns the context. The file is left `chmod 000`; the temp dir is
    /// disposable, and a `000` file is still removable by its owner.
    private static func contextWithUnreadableConfig() -> ServerContext {
        let ctx = scratchContext()
        try? """
        platforms:
          whatsapp_cloud:
            enabled: true
            extra:
              phone_number_id: "1234567890"
              access_token: "LIVE-ACCESS-TOKEN"
              app_secret: "LIVE-APP-SECRET"
              verify_token: "LIVE-VERIFY-TOKEN"
          signal:
            require_mention: true
          email:
            extra:
              skip_attachments: true
        """.write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: ctx.paths.configYAML)
        return ctx
    }

    /// Poll until `condition` holds or `timeout` elapses.
    private static func until(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - 1. The three named worst cases

    /// WhatsApp Cloud keeps EVERY credential in config.yaml, so an unproven
    /// read plus a Save is a ten-key wipe including `extra.access_token`.
    @Test func whatsAppCloudRefusesToSaveAfterAnUnprovenConfigRead() async {
        let ctx = Self.contextWithUnreadableConfig()
        let log = CLILog()
        let vm = WhatsAppCloudSetupViewModel(context: ctx, cliRunner: log.runner())

        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }

        #expect(vm.messageIsFailure, "an unreadable config.yaml was not surfaced")
        #expect(vm.message?.contains("Couldn't read") == true)
        // The fields were NOT filled from an `.empty` config, and were not
        // silently blanked either — nothing was proven, so nothing changed.
        #expect(vm.accessToken.isEmpty)

        vm.save()
        // Give a save that was going to happen every chance to happen.
        await Self.until(timeout: 2) { !log.calls.isEmpty }
        #expect(log.calls.isEmpty, "Save wrote blanks over a config.yaml it never read")
        #expect(!log.calls.contains { $0.count > 2 && $0[2].hasSuffix("extra.access_token") })
        #expect(vm.messageIsFailure, "the refused save said nothing")
    }

    /// Signal reads both files; the config half carries `require_mention`.
    @Test func signalRefusesToSaveAfterAnUnprovenConfigRead() async {
        let ctx = Self.contextWithUnreadableConfig()
        let log = CLILog()
        let vm = SignalSetupViewModel(context: ctx, cliRunner: log.runner())

        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }
        #expect(vm.messageIsFailure)

        vm.save()
        await Self.until(timeout: 2) { !log.calls.isEmpty }
        #expect(log.calls.isEmpty, "Save wrote blanks over a config.yaml it never read")
    }

    /// Email is the `rawConfigText` shape — the one form that parses the YAML
    /// text itself because `HermesConfig` does not model its key. Its
    /// `?? ""` collapsed unreadable into empty exactly like `loadConfig()`.
    @Test func emailRefusesToSaveAfterAnUnprovenConfigRead() async {
        let ctx = Self.contextWithUnreadableConfig()
        let log = CLILog()
        let vm = EmailSetupViewModel(context: ctx, cliRunner: log.runner())
        vm.skipAttachments = true

        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }
        #expect(vm.messageIsFailure)
        // The toggle kept what it had rather than flipping to the default
        // over a live `true` it could not read.
        #expect(vm.skipAttachments)

        vm.save()
        await Self.until(timeout: 2) { !log.calls.isEmpty }
        #expect(log.calls.isEmpty, "Save wrote blanks over a config.yaml it never read")
    }

    // MARK: - 2. Absent is not a refusal

    /// A fresh host: no `.env`, no config.yaml. The empty form is the truth
    /// and Save must work, or nobody can ever set a platform up. This is the
    /// reason the proof is built on `GuardedTextFile.load` rather than on
    /// `loadConfigResult()`, whose `.failure` covers both cases.
    @Test func aFormOnAnAbsentConfigYamlStillSaves() async {
        let ctx = Self.scratchContext()
        #expect(!FileManager.default.fileExists(atPath: ctx.paths.configYAML))
        let log = CLILog()
        let vm = WhatsAppCloudSetupViewModel(context: ctx, cliRunner: log.runner())

        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }
        #expect(vm.message == nil, "an absent config.yaml was reported as damage")
        #expect(vm.loadRefusal == nil)

        vm.phoneNumberID = "1234567890"
        vm.accessToken = "fresh-token"
        vm.save()
        await Self.until(timeout: 10) { vm.message != nil }
        #expect(log.count(of: "config") == 10)
        #expect(log.calls.contains {
            $0 == ["config", "set", "--", "platforms.whatsapp_cloud.extra.access_token", "fresh-token"]
        })
    }

    // MARK: - 3. `saveDirectYAML` on the write chain

    private static var v020Capabilities: HermesCapabilities {
        HermesCapabilities(
            versionLine: "hermes 0.20.3",
            semver: .init(major: 0, minor: 20, patch: 3),
            dateVersion: nil
        )
    }

    private static func contextWithConfig(_ yaml: String) -> ServerContext {
        let ctx = scratchContext()
        try? yaml.write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        return ctx
    }

    /// A direct-YAML save enqueued behind a toggle must WAIT for it. The
    /// signal is load-independent: the toggle's fake CLI sleeps, so if the
    /// direct save returns while that span is still open (or before it even
    /// started) the two are running concurrently.
    @Test func aDirectYAMLSaveWaitsForAnEnqueuedToggle() async {
        let ctx = Self.contextWithConfig("display:\n  streaming: true\n")
        let log = CLILog()
        let vm = SettingsViewModel(context: ctx, cliRunner: log.runner(delay: 0.4))

        vm.setSetting("display.streaming", value: "true")
        await vm.saveExcludedProviders(["ollama"], capabilities: Self.v020Capabilities)

        let spans = log.spans
        // `guard`, not a bare subscript: indexing after a failed count
        // expectation traps and takes the WHOLE test host down with it.
        guard spans.count == 1 else {
            Issue.record("expected the toggle's single config write, saw \(spans.count) spans")
            return
        }
        #expect(spans[0].1 > spans[0].0,
                "the direct-YAML save returned while `config set` was still running")
    }

    /// The direction the audit names: a toggle issued DURING a direct-YAML
    /// save must land after it. Proven from inside the fake runner — it reads
    /// config.yaml at the moment `hermes config set` would have spawned, so
    /// the assertion is about what was on disk then, not about timing.
    @Test func aToggleIssuedDuringADirectYAMLSaveLandsAfterIt() async {
        let ctx = Self.contextWithConfig("display:\n  streaming: true\n")
        let path = ctx.paths.configYAML
        let seen = OSAllocatedUnfairLock(initialState: "")
        let runner: HermesCLIRunner = { _, _ in
            seen.withLock { $0 = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
            return ("", 0)
        }
        let vm = SettingsViewModel(context: ctx, cliRunner: runner)

        let direct = Task { await vm.saveExcludedProviders(["ollama"], capabilities: Self.v020Capabilities) }
        // `saveDirectYAML` claims the chain synchronously before its first
        // await, so one yield is enough to be sure the toggle enqueues
        // BEHIND it rather than in front of it.
        await Task.yield()
        vm.setSetting("display.markdown", value: "false")
        await direct.value
        await Self.until(timeout: 10) { !seen.withLock({ $0 }).isEmpty }

        #expect(seen.withLock { $0 }.contains("ollama"),
                "the toggle's write ran before the direct-YAML save published")
    }
}
