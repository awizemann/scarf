import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P37 finding 4 — every `unsetSetting` row shells `hermes config unset`,
/// which does not exist below v0.19.0 (`hasConfigUnset`). P35 gated the
/// approvals row and left the other six ungated, so a v0.18 host was asked
/// to run a verb it lacks (charter C5) for `browser.cloud_provider`,
/// `stt.provider`, two `auxiliary.*.max_concurrency` and two `database.*`.
///
/// The gate now lives INSIDE `unsetSetting(_:capabilities:)`, so the
/// compiler makes a seventh row pass capabilities too.
@Suite("P37 — the config unset floor, at every call site")
@MainActor
struct HermesP37ConfigUnsetFloorTests {

    private typealias CLILog = HermesP35ApprovalsHostDefaultTests.CLILog

    private static func scratchContext() -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p37-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return .local(home: home)
    }

    private static func viewModel(_ log: CLILog) -> SettingsViewModel {
        SettingsViewModel(context: scratchContext(), cliRunner: log.runner())
    }

    /// Wait on the OBSERVABLE, not the clock. `SettingsViewModel.writeChain`
    /// is the `Task` every settings write is serialised through, and its
    /// last act is `commitConfigWrite` — the banner these tests assert on —
    /// so awaiting it is precisely "the write finished and said so". This
    /// used to poll for a call and then nap a flat 300 ms (P45 finding 12).
    ///
    /// `expectingACall: false` is the "nothing must run" shape: there is no
    /// observable to wait FOR, so it polls to a short deadline, breaking out
    /// early if a call does appear — the caller's `#expect(log.calls.isEmpty)`
    /// is what then fails.
    private static func settle(
        _ vm: SettingsViewModel, _ log: CLILog, expectingACall: Bool = true
    ) async {
        if !expectingACall {
            let deadline = Date().addingTimeInterval(0.3)
            while Date() < deadline, log.calls.isEmpty, vm.writeChain == nil {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await vm.writeChain?.value
    }

    private var v0211: HermesCapabilities {
        HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
    }
    /// A v0.18.2 host: the last release before `config unset` exists
    /// (`hermes_cli/subcommands/config.py` gains `unset` at v2026.7.20).
    private var v018: HermesCapabilities {
        HermesCapabilities.parseLine("Hermes Agent v0.18.2 (2026.7.7.2)")
    }

    /// Each clear row's real setter, plus a `config` in which that row's key
    /// IS stored — P38 made `unsetSetting` a no-op when there is nothing to
    /// clear, so a row driven from `HermesConfig.empty` correctly runs
    /// nothing and would pass this suite vacuously.
    static let clearRows: [(
        key: String,
        stored: @MainActor (SettingsViewModel) -> Void,
        act: @MainActor (SettingsViewModel, HermesCapabilities) -> Void
    )] = [
        ("browser.cloud_provider",
         { $0.config.browserCloudProvider = "browserbase" },
         { $0.setBrowserCloudProvider("", capabilities: $1) }),
        ("stt.provider",
         { $0.config.voice.sttProvider = "openai" },
         { $0.setSTTProvider("", capabilities: $1) }),
        ("auxiliary.compression.max_concurrency",
         { _ in },
         { $0.setAuxiliaryMaxConcurrency("compression", value: nil, stored: 2, capabilities: $1) }),
        ("auxiliary.title_generation.max_concurrency",
         { $0.config.auxiliary.titleGeneration.maxConcurrency = 2 },
         { $0.setTitleGenerationMaxConcurrency(nil, capabilities: $1) }),
        ("database.wal_autocheckpoint",
         { $0.config.database.walAutocheckpoint = 500 },
         { $0.setDatabaseWalAutocheckpoint(nil, capabilities: $1) }),
        ("database.journal_size_limit",
         { $0.config.database.journalSizeLimit = 1 << 20 },
         { $0.setDatabaseJournalSizeLimit(nil, capabilities: $1) }),
    ]

    /// Every row that clears a key, driven through its real setter. Fails
    /// before the fix: all six shelled `config unset` on a v0.18 host.
    @Test func noClearRowShellsConfigUnsetBelowTheFloor() async {
        let cases = Self.clearRows

        for (key, stored, act) in cases {
            let belowFloor = CLILog()
            let vmBelow = Self.viewModel(belowFloor)
            stored(vmBelow)
            act(vmBelow, v018)
            await Self.settle(vmBelow, belowFloor, expectingACall: false)
            #expect(belowFloor.calls.isEmpty,
                    "\(key): a v0.18 host was asked to run `config unset`")
            #expect(vmBelow.messageIsFailure, "\(key): the inert row said nothing")
            #expect(vmBelow.message?.contains("config unset") == true,
                    "\(key): the hint does not name the missing verb")

            // …and above the floor the same row still clears the key.
            let atFloor = CLILog()
            let vmAt = Self.viewModel(atFloor)
            stored(vmAt)
            act(vmAt, v0211)
            await Self.settle(vmAt, atFloor)
            #expect(atFloor.calls == [["config", "unset", "--", key]], "\(key): did not clear")
        }
    }

    /// A concrete value still goes through `config set` on either host — the
    /// gate is on the CLEAR gesture, not on the row.
    @Test func aConcreteValueIsUnaffectedByTheFloor() async {
        let log = CLILog(output: "")
        let vm = Self.viewModel(log)
        vm.setDatabaseWalAutocheckpoint(500, capabilities: v018)
        await Self.settle(vm, log)
        #expect(log.calls == [["config", "set", "--", "database.wal_autocheckpoint", "500"]])

        let log2 = CLILog(output: "")
        let vm2 = Self.viewModel(log2)
        vm2.setBrowserCloudProvider("browserbase", capabilities: v018)
        await Self.settle(vm2, log2)
        #expect(log2.calls == [["config", "set", "--", "browser.cloud_provider", "browserbase"]])
    }

    /// The gate is inside the shared helper, so it cannot be reached around.
    @Test func theSharedHelperIsTheGate() async {
        let log = CLILog()
        let vm = Self.viewModel(log)
        vm.unsetSetting("anything.at.all", capabilities: v018, isStored: true)
        await Self.settle(vm, log, expectingACall: false)
        #expect(log.calls.isEmpty)
        #expect(vm.messageIsFailure)
    }
}

/// P37 finding 5 — a refused `.env` read still blanked the form's credential
/// fields.
///
/// `loadSnapshot` set `loadRefusal` and then called `apply(snapshot)`
/// unconditionally. On an `envFailure` the snapshot's `env` is `[:]`, so
/// every `env["TELEGRAM_BOT_TOKEN"] ?? ""` in the form's `apply` overwrote a
/// live value with a blank. The latched refusal blocked the Save, so nothing
/// reached disk — but the user watched their token vanish from the screen
/// and had no way to know it was still on the host.
@Suite("P37 — a refused read leaves the form alone")
@MainActor
struct HermesP37RefusedReadTests {

    private typealias CLILog = MainActorBlockingWritesP11Tests.CLILog

    /// A Hermes home whose `.env` EXISTS and cannot be read — an SSH blip or
    /// a permissions mistake, which is what `GuardedTextFile` proves apart
    /// from an absent file. Left `chmod 000`; the temp dir is disposable and
    /// a `000` file is still removable by its owner.
    private static func contextWithUnreadableEnv() -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p37-env-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let ctx = ServerContext.local(home: home)
        try? "TELEGRAM_BOT_TOKEN=LIVE-BOT-TOKEN\n"
            .write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: ctx.paths.envFile)
        return ctx
    }

    private static func until(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Fails before the fix: `botToken` came back `""`.
    @Test func telegramKeepsAPrimedTokenAfterARefusedEnvRead() async {
        let ctx = Self.contextWithUnreadableEnv()
        let log = CLILog()
        let vm = TelegramSetupViewModel(context: ctx, cliRunner: log.runner())
        // What the last PROVEN load put on screen.
        vm.botToken = "LIVE-BOT-TOKEN"
        vm.allowedUsers = "12345"

        vm.load(capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)"))
        await Self.until(timeout: 10) { !vm.isLoading }

        #expect(vm.loadRefusal != nil, "premise: the `.env` read must be refused")
        #expect(vm.botToken == "LIVE-BOT-TOKEN",
                "a refused read blanked a live credential on screen")
        #expect(vm.allowedUsers == "12345")
        #expect(vm.messageIsFailure, "the refusal was not surfaced")
    }

    /// The config-ONLY worst case, which was already safe and is pinned so
    /// it stays that way: WhatsApp Cloud keeps every credential in
    /// config.yaml, and `FormSnapshot.config` is nil on a refusal, which its
    /// `apply` already reads as "leave the fields alone". This test does NOT
    /// fail against the pre-fix `apply(snapshot)` — the hole was specific to
    /// the `.env` half, whose `env` is `[:]` rather than nil, so every
    /// `env["…"] ?? ""` blanked a field. Kept as the boundary of the bug.
    @Test func whatsAppCloudKeepsPrimedCredentialsAfterARefusedRead() async {
        let ctx = Self.contextWithUnreadableEnv()
        // Make the config half unreadable too — this form reads only config.
        try? "platforms:\n  whatsapp_cloud:\n    enabled: true\n"
            .write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: ctx.paths.configYAML)

        let log = CLILog()
        let vm = WhatsAppCloudSetupViewModel(context: ctx, cliRunner: log.runner())
        vm.accessToken = "LIVE-ACCESS-TOKEN"
        vm.phoneNumberID = "1234567890"

        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }

        #expect(vm.loadRefusal != nil, "premise: the read must be refused")
        #expect(vm.accessToken == "LIVE-ACCESS-TOKEN")
        #expect(vm.phoneNumberID == "1234567890")
    }

    /// The over-correction P37's own fresh-eyes pass caught: the first fix
    /// skipped `apply` on `loadFailure`, which is `envFailure ?? configFailure`
    /// — so a form whose `.env` read was PROVEN and whose config.yaml was not
    /// rendered nothing at all, and a first load showed an empty form over a
    /// credential it had just read successfully. That is finding 5's own
    /// failure mode, reintroduced through the other door.
    ///
    /// The guard belongs on `envFailure` alone, because the halves are not
    /// symmetric: `FormSnapshot.config` / `rawConfigText` are nil on a
    /// refusal and every form's `apply` already opens with `guard let cfg =
    /// snapshot.config?.… else { return }`, while `env` is `[:]`, which is
    /// indistinguishable from "nothing is set yet".
    @Test func aProvenEnvStillRendersWhenOnlyConfigYamlIsRefused() async {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p37-half-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let ctx = ServerContext.local(home: home)
        try? "TELEGRAM_BOT_TOKEN=PROVEN-TOKEN\nTELEGRAM_ALLOWED_USERS=999\n"
            .write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        try? "telegram:\n  require_mention: true\n"
            .write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: ctx.paths.configYAML)

        let log = CLILog()
        let vm = TelegramSetupViewModel(context: ctx, cliRunner: log.runner())
        vm.load(capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)"))
        await Self.until(timeout: 10) { !vm.isLoading }

        #expect(vm.loadRefusal != nil, "premise: the config.yaml read must be refused")
        #expect(vm.botToken == "PROVEN-TOKEN",
                "a refused config.yaml suppressed the PROVEN `.env` half")
        #expect(vm.allowedUsers == "999")
        // …and the save is still latched shut, because one half is unproven.
        vm.save()
        await Self.until(timeout: 2) { !log.calls.isEmpty }
        #expect(log.calls.isEmpty, "a save ran with an unproven config.yaml")
    }

    /// The control: a PROVEN read still applies, blanks included — "the key
    /// is not set" is a real answer and the form must render it.
    @Test func aProvenReadStillApplies() async {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p37-proven-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let ctx = ServerContext.local(home: home)
        try? "TELEGRAM_BOT_TOKEN=FROM-DISK\n"
            .write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)

        let log = CLILog()
        let vm = TelegramSetupViewModel(context: ctx, cliRunner: log.runner())
        vm.botToken = "STALE"
        vm.homeChannel = "STALE-AND-ABSENT-ON-DISK"

        vm.load(capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)"))
        await Self.until(timeout: 10) { !vm.isLoading }

        #expect(vm.loadRefusal == nil)
        #expect(vm.botToken == "FROM-DISK", "a proven read must win over the screen")
        #expect(vm.homeChannel.isEmpty, "a proven ABSENCE must clear the field")
    }
}

/// P37 finding 6 — `AuxiliaryReasoningEffort` was a second, hard-coded copy
/// of the reasoning-effort vocabulary, with a provenance doc still claiming
/// "v0.20.0" for `max`/`ultra` after P35 walked them to 0.18.1 / 0.19.0.
@Suite("P37 — one reasoning-effort vocabulary")
struct HermesP37EffortVocabularyTests {

    /// There is exactly one list. Fails before the fix: the picker built its
    /// options from `AuxiliaryReasoningEffort.allCases`, which no capability
    /// could narrow and nothing tied to `HermesReasoningEffort`.
    @Test func theAuxiliaryPickerOffersTheSharedVocabulary() {
        let v0211 = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        #expect(HermesReasoningEffort.levels(capabilities: v0211)
                == ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"])

        // The surface's own floor is `hasAuxiliaryReasoningEffort` (0.19.0),
        // and BOTH gated levels are at or below it — `max` at v2026.7.7
        // (0.18.1) and `ultra` at v2026.7.20 (0.19.0), the very tag that
        // added `auxiliary.<task>.reasoning_effort`. So on every host that
        // renders this picker the full list is correct, and the gating is
        // moot rather than missing.
        let floor = HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)")
        #expect(floor.hasAuxiliaryReasoningEffort)
        #expect(floor.hasReasoningEffortMax)
        #expect(floor.hasReasoningEffortUltra)
        #expect(HermesReasoningEffort.levels(capabilities: floor)
                == HermesReasoningEffort.levels(capabilities: v0211))

        // …and the last host WITHOUT the surface is also the last one that
        // would have needed a narrower list, which is why one vocabulary is
        // enough here.
        let below = HermesCapabilities.parseLine("Hermes Agent v0.18.2 (2026.7.7.2)")
        #expect(!below.hasAuxiliaryReasoningEffort)
        #expect(!below.hasReasoningEffortUltra)
    }

    /// The `AuxiliaryTab` picker reads the shared source, not a local list.
    @Test func theAuxiliaryTabHasNoSecondVocabulary() throws {
        let tab = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scarf/Features/Settings/Views/Tabs/AuxiliaryTab.swift")
        let src = try String(contentsOf: tab, encoding: .utf8)
        // P44 / round-4 decision 13 wrapped the call across lines to pass
        // `selected:`, so the pin is on the shared TYPE plus the widening
        // argument rather than on one call's formatting.
        #expect(src.contains("HermesReasoningEffort.levels("),
                "the picker does not build its options from the shared vocabulary")
        #expect(src.contains("selected: value"),
                "the picker does not widen to the stored level (decision 13)")
        // No MEMBER access on the retired enum (`hasAuxiliaryReasoningEffort`
        // is the surface's capability flag and stays).
        #expect(!src.contains("AuxiliaryReasoningEffort.allCases"),
                "a second effort vocabulary is still read here")
    }
}
