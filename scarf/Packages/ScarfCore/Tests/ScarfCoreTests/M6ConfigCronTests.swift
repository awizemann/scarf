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
            deliver: "discord:general"
        )
        #expect(job.enabled)
        let toggled = job.withEnabled(false)
        #expect(toggled.enabled == false)
        // Every other field round-trips.
        #expect(toggled.id == job.id)
        #expect(toggled.name == job.name)
        #expect(toggled.prompt == job.prompt)
        #expect(toggled.skills == job.skills)
        #expect(toggled.deliver == job.deliver)
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
