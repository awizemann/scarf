import Testing
import Foundation
import ScarfCore
@testable import scarf

/// R07 (Hermes v0.21.5 audit) — the WhatsApp Cloud and Webhook setup forms.
///
/// S07-F3: `hermes whatsapp-cloud` (Hermes's own wizard) keeps every
/// WhatsApp Cloud credential and the allowlist in `.env`
/// (`hermes_cli/setup_whatsapp_cloud.py:144-150,269-285` @ v2026.9.24) and the
/// gateway reads them from there (`gateway/config_env.py:523-533`). The form
/// read config.yaml only, so such a setup opened blank, and a Save wrote
/// `platforms.whatsapp_cloud.enabled: false` — which beats env credentials
/// (`gateway/config_env.py:182-207`) — plus an empty config `allow_from`,
/// which beats the env allowlist by key presence
/// (`gateway/platforms/whatsapp_common.py:113-124`).
///
/// S07-F4: every `hermes webhook` verb checks only config.yaml's
/// `platforms.webhook.enabled` (`hermes_cli/webhook.py:54-55,105-107`), and
/// the Webhook form wrote only `WEBHOOK_ENABLED` to `.env`.
@Suite("R07 — WhatsApp Cloud + Webhook setup forms")
@MainActor
struct PlatformSetupR07Tests {

    private typealias CLILog = MainActorBlockingWritesP11Tests.CLILog

    private static func scratchContext(env: String? = nil, config: String? = nil) -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-r07-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let ctx = ServerContext.local(home: home)
        if let env { try? env.write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8) }
        if let config { try? config.write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8) }
        return ctx
    }

    private static func until(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func envText(_ ctx: ServerContext) -> String {
        (try? String(contentsOfFile: ctx.paths.envFile, encoding: .utf8)) ?? ""
    }

    private static func configKeys(_ log: CLILog) -> [String] {
        log.calls.filter { $0.count >= 4 && $0[0] == "config" && $0[1] == "set" }.map { $0[3] }
    }

    /// What `hermes whatsapp-cloud` leaves in `.env` (the names it passes to
    /// `save_env_value`; the values are dummies).
    static let wizardEnv = """
    WHATSAPP_CLOUD_PHONE_NUMBER_ID=1098765432
    WHATSAPP_CLOUD_ACCESS_TOKEN=EAAG-wizard-token
    WHATSAPP_CLOUD_APP_SECRET=wizard-app-secret
    WHATSAPP_CLOUD_APP_ID=555
    WHATSAPP_CLOUD_VERIFY_TOKEN=wizard-verify
    WHATSAPP_CLOUD_ALLOWED_USERS=15551234567,15557654321

    """

    // MARK: - S07-F3 WhatsApp Cloud

    /// THE finding: a wizard-made setup opens filled in, and a Save that
    /// changes nothing neither disables the adapter nor overrides the
    /// allowlist.
    @Test func aWizardSetupLoadsFromEnvAndSavesWithoutDisablingIt() async {
        let ctx = Self.scratchContext(env: Self.wizardEnv)
        let log = CLILog()
        let vm = WhatsAppCloudSetupViewModel(context: ctx, cliRunner: log.runner())
        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }

        #expect(vm.phoneNumberID == "1098765432")
        #expect(vm.accessToken == "EAAG-wizard-token")
        #expect(vm.appSecret == "wizard-app-secret")
        #expect(vm.verifyToken == "wizard-verify")
        #expect(vm.allowFrom == "15551234567,15557654321")
        // No dm_policy anywhere + an allowlist = the adapter's own default.
        #expect(vm.dmPolicy == "allowlist")

        vm.save()
        await Self.until(timeout: 10) { vm.message != nil }
        let keys = Self.configKeys(log)
        #expect(keys == ["platforms.whatsapp_cloud.enabled"])
        #expect(log.calls.first?.last == "true")
        #expect(!keys.contains("platforms.whatsapp_cloud.extra.allow_from"),
                "an empty or copied config allow_from would take over from the env allowlist")
        #expect(!keys.contains("platforms.whatsapp_cloud.extra.dm_policy"))
        // No secret crossed argv.
        #expect(!log.calls.joined().contains("EAAG-wizard-token"))
        let env = Self.envText(ctx)
        #expect(env.contains("WHATSAPP_CLOUD_ACCESS_TOKEN=EAAG-wizard-token"))
        #expect(env.contains("WHATSAPP_CLOUD_ALLOWED_USERS=15551234567,15557654321"))
    }

    /// A half-filled form never writes an explicit disable.
    @Test func aBlankTokenNeverWritesEnabledFalse() async {
        let ctx = Self.scratchContext()
        let log = CLILog()
        let vm = WhatsAppCloudSetupViewModel(context: ctx, cliRunner: log.runner())
        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }
        vm.phoneNumberID = "1098765432"
        vm.save()
        await Self.until(timeout: 10) { vm.message != nil }
        #expect(!log.calls.contains { $0.contains("platforms.whatsapp_cloud.enabled") })
        #expect(Self.envText(ctx).contains("WHATSAPP_CLOUD_PHONE_NUMBER_ID=1098765432"))
    }

    /// An older Scarf put the credentials in config.yaml. They stay there:
    /// moving some of them to `.env` without the pair would strand them
    /// (the env copies apply only when BOTH required ones are in `.env`).
    @Test func legacyConfigCredentialsStayInConfig() async {
        let ctx = Self.scratchContext(config: """
        platforms:
          whatsapp_cloud:
            enabled: true
            extra:
              phone_number_id: "1234567890"
              access_token: "CONFIG-TOKEN"
              dm_policy: open
              allow_from: "15550000000"
        """)
        let log = CLILog()
        let vm = WhatsAppCloudSetupViewModel(context: ctx, cliRunner: log.runner())
        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }
        #expect(vm.credentialsInConfig)
        #expect(vm.accessToken == "CONFIG-TOKEN")
        #expect(vm.allowlistEnvKey == nil)
        #expect(vm.allowFrom == "15550000000")

        let plan = vm.savePlan()
        #expect(plan.config["platforms.whatsapp_cloud.extra.access_token"] == "CONFIG-TOKEN")
        #expect(plan.config["platforms.whatsapp_cloud.extra.allow_from"] == "15550000000")
        // dm_policy is in config already, so it is re-written as shown.
        #expect(plan.config["platforms.whatsapp_cloud.extra.dm_policy"] == "open")
        #expect(plan.env["WHATSAPP_CLOUD_ACCESS_TOKEN"] == nil)
    }

    /// Presence, not truthiness: an EMPTY config `allow_from` is still the
    /// list Hermes uses, so the form shows and writes that one.
    @Test func aPresentButEmptyConfigAllowlistIsTheOneShown() async {
        let ctx = Self.scratchContext(
            env: Self.wizardEnv,
            config: "platforms:\n  whatsapp_cloud:\n    extra:\n      allow_from: \"\"\n")
        let vm = WhatsAppCloudSetupViewModel(context: ctx, cliRunner: CLILog().runner())
        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }
        #expect(vm.allowlistEnvKey == nil)
        #expect(vm.allowFrom.isEmpty)
        #expect(vm.dmPolicy == "open")
        let plan = vm.savePlan()
        #expect(plan.config["platforms.whatsapp_cloud.extra.allow_from"] == "")
        #expect(plan.env["WHATSAPP_CLOUD_ALLOWED_USERS"] == nil)
    }

    /// A policy the user changed IS written; one they left alone is not.
    @Test func aChangedDMPolicyIsWritten() async {
        let ctx = Self.scratchContext(env: Self.wizardEnv)
        let vm = WhatsAppCloudSetupViewModel(context: ctx, cliRunner: CLILog().runner())
        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }
        #expect(vm.savePlan().config["platforms.whatsapp_cloud.extra.dm_policy"] == nil)
        vm.dmPolicy = "open"
        #expect(vm.savePlan().config["platforms.whatsapp_cloud.extra.dm_policy"] == "open")
    }

    /// `hermes config set` refuses a plain string over an existing list
    /// (`hermes_cli/config.py:3316-3335` @ v2026.9.24 — checked against the
    /// real CLI), so a list-form allowlist goes back as a list literal.
    @Test func aListFormAllowlistIsWrittenBackAsAList() async {
        let ctx = Self.scratchContext(config: """
        platforms:
          whatsapp_cloud:
            extra:
              allow_from:
                - "15551111111"
                - '15552222222'
        """)
        let vm = WhatsAppCloudSetupViewModel(context: ctx, cliRunner: CLILog().runner())
        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }
        #expect(vm.allowFrom == "15551111111,15552222222")
        #expect(vm.savePlan().config["platforms.whatsapp_cloud.extra.allow_from"]
                == #"["15551111111", "15552222222"]"#)
        vm.allowFrom = ""
        #expect(vm.savePlan().config["platforms.whatsapp_cloud.extra.allow_from"] == "[]")
    }

    @Test func aFlowStyleEmptyListStaysAList() async {
        let ctx = Self.scratchContext(
            config: "platforms:\n  whatsapp_cloud:\n    extra:\n      allow_from: []\n")
        let vm = WhatsAppCloudSetupViewModel(context: ctx, cliRunner: CLILog().runner())
        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }
        #expect(vm.allowFrom.isEmpty)
        vm.allowFrom = "15553333333"
        #expect(vm.savePlan().config["platforms.whatsapp_cloud.extra.allow_from"] == #"["15553333333"]"#)
    }

    /// Clearing both required fields turns off a switch a previous save
    /// turned on — otherwise the gateway starts a credential-less adapter.
    @Test func clearingBothRequiredFieldsTurnsAnExistingSwitchOff() async {
        let ctx = Self.scratchContext(
            env: "WHATSAPP_CLOUD_PHONE_NUMBER_ID=1\nWHATSAPP_CLOUD_ACCESS_TOKEN=t\n",
            config: "platforms:\n  whatsapp_cloud:\n    enabled: true\n")
        let vm = WhatsAppCloudSetupViewModel(context: ctx, cliRunner: CLILog().runner())
        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }
        vm.phoneNumberID = ""
        vm.accessToken = ""
        let plan = vm.savePlan()
        #expect(plan.config["platforms.whatsapp_cloud.enabled"] == "false")
        #expect(plan.env["WHATSAPP_CLOUD_ACCESS_TOKEN"] == "")
        // Clearing only one of them is a half-filled form: no disable.
        vm.phoneNumberID = "1"
        #expect(vm.savePlan().config["platforms.whatsapp_cloud.enabled"] == nil)
    }

    /// With no policy named anywhere, the picker follows the allowlist the
    /// way the adapter's default does, until the user picks one.
    @Test func anUntouchedPolicyFollowsTheAllowlist() async {
        let ctx = Self.scratchContext()
        let vm = WhatsAppCloudSetupViewModel(context: ctx, cliRunner: CLILog().runner())
        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }
        #expect(vm.dmPolicy == "open")
        vm.allowFrom = "15551234567"
        #expect(vm.dmPolicy == "allowlist")
        #expect(vm.savePlan().config["platforms.whatsapp_cloud.extra.dm_policy"] == nil)
        vm.dmPolicy = "open"
        vm.allowFrom = "15551234567,15557654321"
        #expect(vm.dmPolicy == "open", "a policy the user picked was overridden")
        #expect(vm.savePlan().config["platforms.whatsapp_cloud.extra.dm_policy"] == "open")
    }

    /// A save whose `.env` write fails stops there: no `config set` runs, so
    /// `enabled: true` never lands next to credentials that did not.
    @Test func aFailedEnvWriteRunsNoConfigSet() {
        let ctx = Self.scratchContext(env: "WHATSAPP_CLOUD_PHONE_NUMBER_ID=1\n")
        try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: ctx.paths.envFile)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ctx.paths.envFile) }
        let log = CLILog()
        let outcome = PlatformSetupHelpers.saveForm(
            context: ctx,
            envPairs: ["WHATSAPP_CLOUD_ACCESS_TOKEN": "t"],
            configKV: ["platforms.whatsapp_cloud.enabled": "true"],
            runner: log.runner())
        #expect(outcome.isFailure)
        #expect(log.calls.isEmpty, "config.yaml was changed after the .env write failed")
    }

    // MARK: - S07-F4 Webhook

    @Test func enablingWebhooksWritesTheConfigKeyTheCLIChecks() async {
        let ctx = Self.scratchContext()
        let log = CLILog()
        let vm = WebhookSetupViewModel(context: ctx, cliRunner: log.runner())
        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }
        #expect(!vm.enabled)
        vm.enabled = true
        vm.save()
        await Self.until(timeout: 10) { vm.message != nil }
        #expect(log.calls == [["config", "set", "--", "platforms.webhook.enabled", "true"]])
        #expect(Self.envText(ctx).contains("WEBHOOK_ENABLED=true"))
    }

    @Test func aConfigOnlyEnableLoadsAsEnabled() async {
        let ctx = Self.scratchContext(config: "platforms:\n  webhook:\n    enabled: true\n")
        let vm = WebhookSetupViewModel(context: ctx, cliRunner: CLILog().runner())
        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }
        #expect(vm.enabled)
        // Turning it off writes `false` over the key that is there.
        vm.enabled = false
        #expect(vm.savePlan().config == ["platforms.webhook.enabled": "false"])
    }

    @Test func aFormThatWasNeverEnabledCreatesNoExplicitDisable() async {
        let ctx = Self.scratchContext(env: "WEBHOOK_PORT=8644\n")
        let vm = WebhookSetupViewModel(context: ctx, cliRunner: CLILog().runner())
        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }
        #expect(vm.savePlan().config.isEmpty)
    }
}
