import Testing
import Foundation
@testable import ScarfCore

/// M6: YAML parser port + HermesConfig loader. Pure functions — no
/// `ServerContext.sshTransportFactory` races, so this suite can run
/// in parallel with everything else.
///
/// The write-path tests for Cron editing + Settings-from-yaml live
/// in `M5FeatureVMTests` (the serialized suite that already owns
/// the factory-install pattern) to avoid cross-suite parallel
/// collisions on the shared factory static.
@Suite struct M6ConfigCronTests {

    // MARK: - YAML parser

    @Test func parsesScalarKeyValues() {
        let yaml = """
        model:
          default: gpt-4o
          provider: openai
        """
        let p = HermesYAML.parseNestedYAML(yaml)
        #expect(p.values["model.default"] == "gpt-4o")
        #expect(p.values["model.provider"] == "openai")
    }

    @Test func parsesBulletLists() {
        let yaml = """
        permanent_allowlist:
          - ls
          - pwd
          - 'cat /etc/hostname'
        """
        let p = HermesYAML.parseNestedYAML(yaml)
        #expect(p.lists["permanent_allowlist"] == ["ls", "pwd", "cat /etc/hostname"])
    }

    @Test func parsesNestedMaps() {
        let yaml = """
        terminal:
          docker_env:
            PATH: /usr/local/bin
            HOME: /home/hermes
        """
        let p = HermesYAML.parseNestedYAML(yaml)
        #expect(p.maps["terminal.docker_env"]?["PATH"] == "/usr/local/bin")
        #expect(p.maps["terminal.docker_env"]?["HOME"] == "/home/hermes")
        #expect(p.values["terminal.docker_env.PATH"] == "/usr/local/bin")
    }

    @Test func ignoresCommentsAndBlankLines() {
        let yaml = """
        # Top-level comment
        model:
          # inline comment
          default: gpt-4o

          provider: openai
        """
        let p = HermesYAML.parseNestedYAML(yaml)
        #expect(p.values["model.default"] == "gpt-4o")
        #expect(p.values["model.provider"] == "openai")
    }

    @Test func stripsQuotes() {
        #expect(HermesYAML.stripYAMLQuotes("'quoted'") == "quoted")
        #expect(HermesYAML.stripYAMLQuotes("\"quoted\"") == "quoted")
        #expect(HermesYAML.stripYAMLQuotes("plain") == "plain")
        #expect(HermesYAML.stripYAMLQuotes("'unbalanced") == "'unbalanced")
        #expect(HermesYAML.stripYAMLQuotes("") == "")
    }

    @Test func handlesInlineLiterals() {
        let yaml = """
        empty_map: {}
        empty_list: []
        """
        let p = HermesYAML.parseNestedYAML(yaml)
        #expect(p.maps["empty_map"] != nil)
        #expect(p.lists["empty_list"] != nil)
    }

    // MARK: - HermesConfig from YAML

    @Test func emptyYAMLProducesDefaults() {
        let c = HermesConfig(yaml: "")
        #expect(c.model == "unknown")
        #expect(c.provider == "unknown")
        #expect(c.display.skin == "default")
        #expect(c.streaming == true)
        #expect(c.security.redactSecrets == true)
        #expect(c.compression.enabled == true)
        #expect(c.voice.ttsProvider == "edge")
        // v0.13 additions default to empty / off when the YAML omits
        // them — pre-v0.13 hosts produce this exact shape.
        #expect(c.imageGenModel == "")
        #expect(c.openrouterResponseCacheEnabled == false)
    }

    @Test func parsesImageGenAndOpenRouterCache() {
        // WS-6 / v0.16: round-trip the two new top-level keys. Hermes
        // v0.16 reads `openrouter.response_cache` as a SCALAR bool
        // directly under `openrouter:`. This test pins the parser line +
        // setter key + UI binding to that single shape.
        let yaml = """
        image_gen:
          model: openai/gpt-image-1
        openrouter:
          response_cache: true
        """
        let c = HermesConfig(yaml: yaml)
        #expect(c.imageGenModel == "openai/gpt-image-1")
        #expect(c.openrouterResponseCacheEnabled == true)
    }

    @Test func openRouterResponseCacheScalarFalseDecodes() {
        // The scalar `false` round-trips honestly (the v0.16 bug was that
        // a disable wrote a nested dict that Hermes read as truthy).
        let c = HermesConfig(yaml: """
        openrouter:
          response_cache: false
        """)
        #expect(c.openrouterResponseCacheEnabled == false)
    }

    @Test func openRouterResponseCacheLegacyNestedDecodesToFalse() {
        // Defensive read: a legacy nested value flattens to a different
        // dotted key, so the scalar lookup misses and we fall to the
        // `false` default. The next save writes the scalar, healing it.
        let c = HermesConfig(yaml: """
        openrouter:
          response_cache:
            enabled: true
        """)
        #expect(c.openrouterResponseCacheEnabled == false)
    }

    @Test func parsesBitwardenSecretsBlock() {
        // WS-F (v0.15): round-trip the `secrets.bitwarden.*` block. Pins
        // the parser line + setter key shapes to a single source of truth.
        let yaml = """
        secrets:
          bitwarden:
            enabled: true
            access_token_env: MY_BWS_TOKEN
            project_id: proj-123
            override_existing: true
            server_url: https://vault.bitwarden.eu
            cache_ttl_seconds: 600
            auto_install: false
        """
        let c = HermesConfig(yaml: yaml)
        #expect(c.bitwarden.enabled == true)
        #expect(c.bitwarden.accessTokenEnv == "MY_BWS_TOKEN")
        #expect(c.bitwarden.projectID == "proj-123")
        #expect(c.bitwarden.overrideExisting == true)
        #expect(c.bitwarden.serverURL == "https://vault.bitwarden.eu")
        #expect(c.bitwarden.cacheTTLSeconds == 600)
        #expect(c.bitwarden.autoInstall == false)
    }

    @Test func bitwardenAbsentYieldsDefaults() {
        // An absent block must produce the v0.15 server-side defaults so a
        // pre-v0.15 host looks identical to a freshly-installed one.
        let c = HermesConfig(yaml: "")
        #expect(c.bitwarden.enabled == false)
        #expect(c.bitwarden.accessTokenEnv == "BWS_ACCESS_TOKEN")
        #expect(c.bitwarden.projectID == "")
        #expect(c.bitwarden.overrideExisting == false)
        #expect(c.bitwarden.serverURL == "")
        #expect(c.bitwarden.cacheTTLSeconds == 300)
        #expect(c.bitwarden.autoInstall == true)
    }

    @Test func parsesTopLevelModel() {
        let yaml = """
        model:
          default: claude-4-opus
          provider: anthropic
        agent:
          reasoning_effort: high
          service_tier: pro
          max_turns: 50
        """
        let c = HermesConfig(yaml: yaml)
        #expect(c.model == "claude-4-opus")
        #expect(c.provider == "anthropic")
        #expect(c.reasoningEffort == "high")
        #expect(c.serviceTier == "pro")
        #expect(c.maxTurns == 50)
    }

    @Test func parsesLocalEndpointModelKeys() {
        // model.base_url / api_key / api_mode — the local/custom trio the
        // model picker's Local tab round-trips. Absent keys must decode
        // to "" (same as an explicitly cleared empty string).
        let yaml = """
        model:
          default: llama3:8b
          provider: ollama
          base_url: http://127.0.0.1:11434/v1
          api_key: sk-local
          api_mode: chat_completions
        """
        let c = HermesConfig(yaml: yaml)
        #expect(c.modelBaseURL == "http://127.0.0.1:11434/v1")
        #expect(c.modelAPIKey == "sk-local")
        #expect(c.modelAPIMode == "chat_completions")
        let absent = HermesConfig(yaml: "model:\n  default: m\n")
        #expect(absent.modelBaseURL == "")
        #expect(absent.modelAPIKey == "")
        #expect(absent.modelAPIMode == "")
    }

    @Test func parsesDisplaySection() {
        let yaml = """
        display:
          skin: dark
          compact: true
          streaming: false
          show_reasoning: true
          show_cost: true
          personality: professional
        """
        let c = HermesConfig(yaml: yaml)
        #expect(c.display.skin == "dark")
        #expect(c.display.compact == true)
        #expect(c.streaming == false)
        #expect(c.showReasoning == true)
        #expect(c.showCost == true)
        #expect(c.personality == "professional")
    }

    @Test func parsesSecuritySection() {
        let yaml = """
        security:
          redact_secrets: false
          tirith_enabled: false
          tirith_timeout: 15
          website_blocklist:
            enabled: true
            domains:
              - example.com
              - evil.org
        """
        let c = HermesConfig(yaml: yaml)
        #expect(c.security.redactSecrets == false)
        #expect(c.security.tirithEnabled == false)
        #expect(c.security.tirithTimeout == 15)
        #expect(c.security.blocklistEnabled == true)
        #expect(c.security.blocklistDomains == ["example.com", "evil.org"])
    }

    @Test func parsesSlackWithLegacyAndNewerPaths() {
        // Newer path wins when both present.
        let newerWins = HermesConfig(yaml: """
        platforms:
          slack:
            reply_to_mode: all
        slack:
          reply_to_mode: first
        """)
        #expect(newerWins.slack.replyToMode == "all")

        // Legacy-only path used when newer is absent.
        let legacyFallback = HermesConfig(yaml: """
        slack:
          reply_to_mode: first
        """)
        #expect(legacyFallback.slack.replyToMode == "first")

        // Default when neither present.
        let defaulted = HermesConfig(yaml: "")
        #expect(defaulted.slack.replyToMode == "first")
    }

    @Test func parsesAuxiliarySection() {
        let yaml = """
        auxiliary:
          vision:
            provider: openai
            model: gpt-4-vision
            timeout: 60
          compression:
            provider: anthropic
            model: claude-3-haiku
        """
        let c = HermesConfig(yaml: yaml)
        #expect(c.auxiliary.vision.provider == "openai")
        #expect(c.auxiliary.vision.model == "gpt-4-vision")
        #expect(c.auxiliary.vision.timeout == 60)
        #expect(c.auxiliary.compression.provider == "anthropic")
        // Not-configured aux blocks default to "auto" / empty.
        #expect(c.auxiliary.sessionSearch.provider == "auto")
        #expect(c.auxiliary.mcp.provider == "auto")
    }

    @Test func parsesPermanentAllowlist() {
        let yaml = """
        permanent_allowlist:
          - ls
          - pwd
          - stat
        """
        let c = HermesConfig(yaml: yaml)
        #expect(c.commandAllowlist == ["ls", "pwd", "stat"])
    }

    @Test func parsesCommandAllowlistLegacyName() {
        // Fall back to `command_allowlist` when `permanent_allowlist` absent.
        let yaml = """
        command_allowlist:
          - whoami
          - id
        """
        let c = HermesConfig(yaml: yaml)
        #expect(c.commandAllowlist == ["whoami", "id"])
    }

    @Test func preservesQuotedStrings() {
        let yaml = """
        model:
          default: "gpt-4o with spaces"
        timezone: 'America/New_York'
        """
        let c = HermesConfig(yaml: yaml)
        #expect(c.model == "gpt-4o with spaces")
        #expect(c.timezone == "America/New_York")
    }

    // MARK: - v0.16 top-level <platform>.allowed_* allowlists

    @Test func gatewayPlatformsEmptyByDefault() {
        let c = HermesConfig(yaml: "")
        #expect(c.gatewayPlatforms.isEmpty)
    }

    @Test func parsesGatewayAllowlistsForSlack() {
        // v0.16: allowlists live at top-level `slack.allowed_*`.
        let yaml = """
        slack:
          allowed_channels:
            - C01
            - C02
          busy_ack_enabled: false
          gateway_restart_notification: true
          slash_command_notice_ttl_seconds: 120
        """
        let cfg = HermesConfig(yaml: yaml)
        let block = cfg.gatewayPlatforms["slack"]
        #expect(block?.allowedChannels == ["C01", "C02"])
        #expect(block?.busyAckEnabled == false)
        #expect(block?.gatewayRestartNotification == true)
        #expect(block?.slashCommandNoticeTTLSeconds == 120)
    }

    @Test func parsesGatewayAllowlistsForTelegramAndMatrix() {
        let yaml = """
        telegram:
          allowed_chats:
            - '@alice'
            - '12345'
        matrix:
          allowed_rooms:
            - '!room:matrix.org'
        """
        let cfg = HermesConfig(yaml: yaml)
        #expect(cfg.gatewayPlatforms["telegram"]?.allowedChats == ["@alice", "12345"])
        #expect(cfg.gatewayPlatforms["matrix"]?.allowedRooms == ["!room:matrix.org"])
    }

    @Test func parsesGatewayAllowlistForDingtalkAsChats() {
        // v0.16: Hermes reads `dingtalk.allowed_chats` (NOT allowed_rooms).
        let yaml = """
        dingtalk:
          allowed_chats:
            - cidABC123
        """
        let cfg = HermesConfig(yaml: yaml)
        #expect(cfg.gatewayPlatforms["dingtalk"]?.allowedChats == ["cidABC123"])
    }

    @Test func gatewayAllowlistCoexistsWithLegacyPlatformKeys() {
        // Regression: the legacy `slack.reply_to_mode` /
        // `matrix.require_mention` keys live in the SAME top-level section as
        // the v0.16 allowlist keys — both must keep parsing, no collisions.
        let yaml = """
        slack:
          reply_to_mode: all
          allowed_channels:
            - C01
        matrix:
          require_mention: false
          allowed_rooms:
            - '!room:matrix.org'
        """
        let cfg = HermesConfig(yaml: yaml)
        #expect(cfg.slack.replyToMode == "all")
        #expect(cfg.matrix.requireMention == false)
        #expect(cfg.gatewayPlatforms["slack"]?.allowedChannels == ["C01"])
        #expect(cfg.gatewayPlatforms["matrix"]?.allowedRooms == ["!room:matrix.org"])
    }

    @Test func gatewayPlatformsSkipsPlatformsWithoutGatewayKeys() {
        // Only Slack carries a gateway key — platforms without one must NOT
        // appear in `gatewayPlatforms`.
        let yaml = """
        slack:
          busy_ack_enabled: true
        """
        let cfg = HermesConfig(yaml: yaml)
        #expect(cfg.gatewayPlatforms["slack"] != nil)
        #expect(cfg.gatewayPlatforms["mattermost"] == nil)
        #expect(cfg.gatewayPlatforms["telegram"] == nil)
    }

    @Test func cronScheduleMemberwise() {
        let s = CronSchedule(
            kind: "cron",
            runAt: nil,
            display: "9am weekdays",
            expression: "0 9 * * 1-5"
        )
        #expect(s.kind == "cron")
        #expect(s.display == "9am weekdays")
    }

    @Test func hermesCronJobMemberwiseAndWithEnabled() {
        let job = HermesCronJob(
            id: "j1",
            name: "Brief",
            prompt: "summarize",
            skills: ["cal"],
            schedule: CronSchedule(kind: "cron"),
            enabled: true,
            state: "scheduled",
            deliver: "discord:general",
            workdir: "/tmp/project",
            contextFrom: ["other-job"],
            noAgent: true,
            attachToSession: true,
            extra: ["enabled_toolsets": .array([.string("files")])]
        )
        #expect(job.enabled)
        let toggled = job.withEnabled(false)
        #expect(toggled.enabled == false)
        // Every other field round-trips — withEnabled() silently dropped
        // workdir/contextFrom/noAgent until the v0.18 audit, permanently
        // stripping them from jobs.json on an iOS enable-toggle.
        #expect(toggled.id == job.id)
        #expect(toggled.name == job.name)
        #expect(toggled.prompt == job.prompt)
        #expect(toggled.skills == job.skills)
        #expect(toggled.deliver == job.deliver)
        #expect(toggled.workdir == job.workdir)
        #expect(toggled.contextFrom == job.contextFrom)
        #expect(toggled.noAgent == job.noAgent)
        #expect(toggled.attachToSession == job.attachToSession)
        #expect(toggled.extra == job.extra)
    }

    @Test func hermesCronJobAttachToSessionRoundTrip() throws {
        // v0.18 `attach_to_session` — Hermes only persists the key when
        // explicitly set, so nil must encode to an ABSENT key (writing
        // false would change job behavior on save).
        let json = Data("""
        {"id":"j2","name":"N","prompt":"p","schedule":{"kind":"cron"},
         "enabled":true,"state":"scheduled","attach_to_session":true}
        """.utf8)
        let job = try JSONDecoder().decode(HermesCronJob.self, from: json)
        #expect(job.attachToSession == true)
        let reencoded = try JSONDecoder().decode(
            HermesCronJob.self, from: JSONEncoder().encode(job))
        #expect(reencoded.attachToSession == true)

        let unset = HermesCronJob(
            id: "j3", name: "N", prompt: "p",
            schedule: CronSchedule(kind: "cron"),
            enabled: true, state: "scheduled"
        )
        let encoded = String(decoding: try JSONEncoder().encode(unset), as: UTF8.self)
        #expect(!encoded.contains("attach_to_session"))
    }

    /// Strip null-valued keys recursively. Known optional fields decode
    /// explicit nulls to nil and re-encode them as absent keys (Hermes
    /// reads via .get(), so null == absent); comparison must not count
    /// that as a diff. Unknown keys keep their nulls via `extra`.
    private func stripNulls(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict where !(v is NSNull) {
                out[k] = stripNulls(v)
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map(stripNulls)
        }
        return value
    }

    @Test func hermesCronJobLosslessRoundTripV0182() throws {
        // A jobs.json entry shaped exactly like Hermes v0.18.2 persists it
        // (cron/jobs.py create_job dict + the delta's run_claim). The
        // v0.18.2 audit found Scarf's rewrite stripped every key it didn't
        // model — enabled_toolsets, repeat, provider routing, claim guards —
        // and that `pre_run_script`/`expression` were keys Hermes never
        // wrote (real keys: `script`, `expr`, plus interval `minutes`).
        let original = Data("""
        {"id":"job-1","name":"Digest","prompt":"do it","skills":["daily"],
         "skill":"daily","model":"anthropic/claude-sonnet-5","provider":"openrouter",
         "provider_snapshot":{"provider":"openrouter","auth":"api_key"},
         "model_snapshot":"anthropic/claude-sonnet-5","base_url":null,
         "script":"echo pre","no_agent":false,"context_from":null,
         "schedule":{"kind":"interval","minutes":30,"display":"every 30m"},
         "schedule_display":"every 30m","repeat":{"times":5,"completed":2},
         "enabled":true,"state":"scheduled","paused_at":null,"paused_reason":null,
         "created_at":"2026-07-08T09:00:00+00:00","next_run_at":"2026-07-10T09:00:00+00:00",
         "last_run_at":null,"last_status":null,"last_error":null,
         "last_delivery_error":null,"deliver":"origin",
         "origin":{"platform":"slack","chat_id":"C123"},
         "enabled_toolsets":["files","terminal"],"workdir":"/tmp/project",
         "attach_to_session":true,
         "run_claim":{"at":"2026-07-10T09:00:01+00:00","by":"mac-studio"},
         "fire_claim":null}
        """.utf8)

        let job = try JSONDecoder().decode(HermesCronJob.self, from: original)
        // Hermes's real key for the pre-run script is `script`.
        #expect(job.preRunScript == "echo pre")
        #expect(job.schedule.minutes == 30)

        let reencoded = try JSONEncoder().encode(job.withEnabled(false).withEnabled(true))
        let a = stripNulls(try JSONSerialization.jsonObject(with: original)) as! NSDictionary
        let b = stripNulls(try JSONSerialization.jsonObject(with: reencoded)) as! NSDictionary
        #expect(a == b)

        // Explicit nulls on UNKNOWN keys survive byte-for-byte (they live
        // in `extra`; Hermes distinguishes wrote-null from never-wrote for
        // fields like paused_at only cosmetically, but don't churn them).
        let text = String(decoding: reencoded, as: UTF8.self)
        #expect(text.contains("\"paused_at\""))
        #expect(text.contains("\"run_claim\""))
        #expect(!text.contains("pre_run_script"))
    }

    @Test func cronLegacyScarfKeysDecodeButReencodeCanonical() throws {
        // jobs.json files Scarf itself wrote through v2.15 can carry
        // `pre_run_script` and `expression` — keys current Hermes never
        // reads. Decode them as fallbacks, but always re-encode the
        // canonical `script` / `expr` so the scheduler can run the job.
        let json = Data("""
        {"id":"j","name":"N","prompt":"p","enabled":true,"state":"scheduled",
         "pre_run_script":"echo legacy",
         "schedule":{"kind":"cron","expression":"0 9 * * 1-5"}}
        """.utf8)
        let job = try JSONDecoder().decode(HermesCronJob.self, from: json)
        #expect(job.preRunScript == "echo legacy")
        #expect(job.schedule.expression == "0 9 * * 1-5")

        let text = String(decoding: try JSONEncoder().encode(job), as: UTF8.self)
        #expect(text.contains("\"script\":\"echo legacy\""))
        #expect(!text.contains("pre_run_script"))
        #expect(text.contains("\"expr\":\"0 9 * * 1-5\""))
        #expect(!text.contains("\"expression\""))
    }

    @Test func cronJobsFileMemberwise() {
        let jobs = [
            HermesCronJob(
                id: "a", name: "A", prompt: "p",
                schedule: CronSchedule(kind: "cron"),
                enabled: true, state: "scheduled"
            )
        ]
        let file = CronJobsFile(jobs: jobs, updatedAt: "2026-04-23T00:00:00Z")
        #expect(file.jobs.count == 1)
        #expect(file.updatedAt == "2026-04-23T00:00:00Z")
        // Codable round-trip should survive.
        let data = try! JSONEncoder().encode(file)
        let decoded = try! JSONDecoder().decode(CronJobsFile.self, from: data)
        #expect(decoded.jobs.count == 1)
        #expect(decoded.jobs[0].name == "A")
        #expect(decoded.updatedAt == file.updatedAt)
    }
}
