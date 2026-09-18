import Testing
import Foundation
@testable import ScarfCore

/// Pure parser tests for `HermesCapabilities`. The detection store
/// (`HermesCapabilitiesStore`) is exercised separately under integration
/// tests since it spawns `hermes --version`.
@Suite struct HermesCapabilitiesTests {

    // MARK: - Version line parsing

    @Test func parseV013ReleaseLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 13, patch: 0))
        #expect(caps.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 5, day: 7))
        #expect(caps.detected)
    }

    @Test func parseV015ReleaseLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.15.0 (2026.5.28)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 15, patch: 0))
        #expect(caps.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 5, day: 28))
        #expect(caps.detected)
    }

    @Test func parseV012ReleaseLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 12, patch: 0))
        #expect(caps.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 4, day: 30))
        #expect(caps.detected)
    }

    @Test func parseV011ReleaseLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.11.0 (2026.4.23)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 11, patch: 0))
        #expect(caps.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 4, day: 23))
    }

    @Test func parseSemverWithoutDate() {
        // Some older Hermes builds emit only the semver suffix.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.10.5")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 10, patch: 5))
        #expect(caps.dateVersion == nil)
    }

    @Test func parseFullStdoutBlock() {
        // Real `hermes --version` output is multi-line; the version sits on
        // the first line and the rest is metadata.
        let stdout = """
        Hermes Agent v0.12.0 (2026.4.30)
        Project: /Users/alan/.hermes/hermes-agent
        Python: 3.11.15
        OpenAI SDK: 2.31.0
        Up to date
        """
        let caps = HermesCapabilities.parse(stdout)
        #expect(caps.semver?.minor == 12)
        #expect(caps.dateVersion?.year == 2026)
    }

    @Test func parseRejectsUnrelatedOutput() {
        let caps = HermesCapabilities.parse("hermes: command not found")
        #expect(caps.semver == nil)
        #expect(!caps.detected)
    }

    @Test func parseHandlesEmptyString() {
        let caps = HermesCapabilities.parse("")
        #expect(caps == .empty)
    }

    @Test func parseHandlesPartialSemver() {
        // "v0.11" without the patch component shouldn't accidentally match.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.11")
        #expect(caps.semver == nil)
    }

    // MARK: - SemVer ordering

    @Test func semverOrdering() {
        let v0_11_0 = HermesCapabilities.SemVer(major: 0, minor: 11, patch: 0)
        let v0_12_0 = HermesCapabilities.SemVer(major: 0, minor: 12, patch: 0)
        let v0_12_5 = HermesCapabilities.SemVer(major: 0, minor: 12, patch: 5)
        let v1_0_0 = HermesCapabilities.SemVer(major: 1, minor: 0, patch: 0)
        #expect(v0_11_0 < v0_12_0)
        #expect(v0_12_0 < v0_12_5)
        #expect(v0_12_5 < v1_0_0)
    }

    // MARK: - Capability flags

    @Test func v013FlagsAllOn() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)")
        // v0.12 surfaces remain on.
        #expect(caps.hasCurator)
        #expect(caps.hasKanban)
        #expect(caps.hasACPImagePrompts)
        #expect(!caps.hasFlushMemoriesAux)
        // v0.13 surfaces light up.
        #expect(caps.hasGoals)
        #expect(caps.hasACPQueue)
        #expect(caps.hasACPSteer)
        #expect(caps.hasKanbanDiagnostics)
        #expect(caps.hasCuratorArchive)
        #expect(caps.hasGoogleChatPlatform)
        #expect(caps.hasGatewayAllowlists)
        #expect(caps.hasGatewayBusyAckToggle)
        #expect(caps.hasGatewayRestartNotification)
        #expect(caps.hasGatewayList)
        #expect(caps.hasMCPSSETransport)
        #expect(caps.hasCronNoAgent)
        #expect(caps.hasWebToolsBackendSplit)
        #expect(caps.hasProfileNoSkills)
        #expect(caps.hasContextCompressionCount)
        #expect(caps.hasNewWithSessionName)
        #expect(caps.hasUpdateNonInteractive)
        #expect(caps.hasOpenRouterResponseCache)
        #expect(caps.hasImageGenModel)
        #expect(caps.hasDisplayLanguage)
        #expect(caps.hasXAIVoiceCloning)
        #expect(caps.hasVideoAnalyze)
        #expect(caps.hasTransformLLMOutputHook)
    }

    @Test func v012FlagsAllOn() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")
        // v0.12 surfaces on.
        #expect(caps.hasCurator)
        #expect(caps.hasFallbackCommand)
        #expect(caps.hasOneShot)
        #expect(caps.hasSkillURLInstall)
        #expect(caps.hasACPImagePrompts)
        #expect(caps.hasUpdateCheck)
        #expect(caps.hasPiperTTS)
        #expect(caps.hasVercelTerminal)
        #expect(caps.hasCuratorAux)
        #expect(caps.hasTeamsPlatform)
        #expect(caps.hasYuanbaoPlatform)
        #expect(caps.hasCronWorkdir)
        #expect(caps.hasPromptCacheTTL)
        #expect(caps.hasRedactionToggle)
        // flush_memories was REMOVED in v0.12 — flag inverts.
        #expect(!caps.hasFlushMemoriesAux)
        // v0.13 surfaces stay off on a v0.12 host.
        // `hasKanban` is one of them since P55: `hermes_cli/kanban.py` does
        // not exist at v2026.4.30 and `kanban` appears zero times in
        // `commands.py` / `main.py` there.
        #expect(!caps.hasKanban)
        #expect(!caps.hasGoals)
        #expect(!caps.hasACPQueue)
        #expect(!caps.hasKanbanDiagnostics)
        #expect(!caps.hasCuratorArchive)
        #expect(!caps.hasGoogleChatPlatform)
        #expect(!caps.hasGatewayAllowlists)
        #expect(!caps.hasMCPSSETransport)
        #expect(!caps.hasCronNoAgent)
        #expect(!caps.hasWebToolsBackendSplit)
        #expect(!caps.hasProfileNoSkills)
        #expect(!caps.hasContextCompressionCount)
        #expect(!caps.hasOpenRouterResponseCache)
        #expect(!caps.hasImageGenModel)
        #expect(!caps.hasDisplayLanguage)
        #expect(!caps.hasXAIVoiceCloning)
    }

    @Test func v011FlagsAllOff() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.11.0 (2026.4.23)")
        #expect(!caps.hasCurator)
        #expect(!caps.hasFallbackCommand)
        #expect(!caps.hasKanban)
        #expect(!caps.hasOneShot)
        #expect(!caps.hasSkillURLInstall)
        #expect(!caps.hasACPImagePrompts)
        #expect(!caps.hasUpdateCheck)
        #expect(!caps.hasPiperTTS)
        #expect(!caps.hasVercelTerminal)
        #expect(!caps.hasCuratorAux)
        #expect(!caps.hasTeamsPlatform)
        #expect(!caps.hasYuanbaoPlatform)
        #expect(!caps.hasCronWorkdir)
        #expect(!caps.hasPromptCacheTTL)
        #expect(!caps.hasRedactionToggle)
        // flush_memories aux row was still alive on v0.11.
        #expect(caps.hasFlushMemoriesAux)
    }

    @Test func emptyCapabilitiesAllOff() {
        // Undetected installs should hide every gated UI surface.
        let caps = HermesCapabilities.empty
        #expect(!caps.hasCurator)
        #expect(!caps.hasFlushMemoriesAux)   // unknown → hide either way
        #expect(!caps.detected)
    }

    @Test func v014FlagsAllOn() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.5.16)")
        // v0.12 + v0.13 surfaces remain on.
        #expect(caps.hasCurator)
        #expect(caps.hasACPImagePrompts)
        #expect(caps.hasGoals)
        #expect(caps.hasKanbanDiagnostics)
        #expect(caps.hasCuratorArchive)
        #expect(!caps.hasFlushMemoriesAux)
        // v0.14 slash commands.
        #expect(caps.hasSubgoal)
        #expect(caps.hasSessionsSlashCommand)
        #expect(caps.hasCodexRuntimeSlashCommand)
        // v0.14 providers.
        #expect(caps.hasGrokOAuthProvider)
        #expect(caps.hasNovitaProvider)
        // v0.14 platforms.
        #expect(caps.hasLINEPlatform)
        #expect(caps.hasSimpleXPlatform)
        // v0.14 web-tool backends.
        #expect(caps.hasBraveFreeSearchBackend)
        #expect(caps.hasDDGSearchBackend)
        // v0.14 config + plugin additions.
        #expect(caps.hasMCPParallelToolCalls)
        #expect(caps.hasDockerExtraArgs)
        #expect(caps.hasDisplayTimestamps)
        #expect(caps.hasCronDeliverAll)
        #expect(caps.hasDiscordHistoryBackfill)
        #expect(caps.hasOpenRouterParetoCoder)
        #expect(caps.hasCustomProviderAPIMode)
        #expect(caps.hasPluginToolOverride)
        // v0.14 new feature surfaces.
        #expect(caps.hasHermesProxy)
        #expect(caps.hasACPSetupBrowser)
        #expect(caps.hasFileMutationVerifier)
        #expect(caps.hasYOLOWarning)
        #expect(caps.hasQwenCloudDisplayName)
        #expect(caps.hasCrossSessionClaudeCache)
        // Convenience predicate.
        #expect(caps.isV014OrLater)
    }

    @Test func v013HostHidesV014Flags() {
        // Every v0.14 flag must stay off on a pristine v0.13 host so the
        // UI degrades silently.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)")
        #expect(!caps.hasSubgoal)
        #expect(!caps.hasSessionsSlashCommand)
        #expect(!caps.hasCodexRuntimeSlashCommand)
        #expect(!caps.hasGrokOAuthProvider)
        #expect(!caps.hasNovitaProvider)
        #expect(!caps.hasLINEPlatform)
        #expect(!caps.hasSimpleXPlatform)
        #expect(!caps.hasBraveFreeSearchBackend)
        #expect(!caps.hasDDGSearchBackend)
        #expect(!caps.hasMCPParallelToolCalls)
        #expect(!caps.hasDockerExtraArgs)
        #expect(!caps.hasDisplayTimestamps)
        #expect(!caps.hasCronDeliverAll)
        #expect(!caps.hasDiscordHistoryBackfill)
        #expect(!caps.hasOpenRouterParetoCoder)
        #expect(!caps.hasCustomProviderAPIMode)
        #expect(!caps.hasPluginToolOverride)
        #expect(!caps.hasHermesProxy)
        #expect(!caps.hasACPSetupBrowser)
        #expect(!caps.hasFileMutationVerifier)
        #expect(!caps.hasYOLOWarning)
        #expect(!caps.hasQwenCloudDisplayName)
        #expect(!caps.hasCrossSessionClaudeCache)
        #expect(!caps.isV014OrLater)
    }

    /// The cron `--deliver` gate shared by fleet apply-cron and the template
    /// installer: only `all` is version-gated; everything else is baseline.
    /// Covers the `all` sentinel only. The second gated sentinel,
    /// `bot-chat[:profile]` (v0.20.6+), is covered in
    /// `HermesV021CronParityTests.botChatDeliveryIsVersionGated`.
    @Test func supportsCronDeliverGatesOnlyTheAllSentinel() {
        let v14 = HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.5.16)")
        let v13 = HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)")
        let unknown = HermesCapabilities.empty

        // `all` requires v0.14+.
        #expect(v14.supportsCronDeliver("all"))
        #expect(!v13.supportsCronDeliver("all"))
        #expect(!unknown.supportsCronDeliver("all"))

        // nil / empty (no flag) and specific platforms are baseline everywhere.
        for caps in [v14, v13, unknown] {
            #expect(caps.supportsCronDeliver(nil))
            #expect(caps.supportsCronDeliver(""))
            #expect(caps.supportsCronDeliver("discord"))
            #expect(caps.supportsCronDeliver("discord:general:42"))
            #expect(caps.supportsCronDeliver("telegram:chat"))
        }
    }

    @Test func v014PatchReleaseStillEnablesAllFlags() {
        // A v0.14.3 patch release should still enable every v0.14 flag.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.14.3 (2026.6.20)")
        #expect(caps.hasSubgoal)
        #expect(caps.hasGrokOAuthProvider)
        #expect(caps.hasLINEPlatform)
        #expect(caps.hasHermesProxy)
        #expect(caps.isV014OrLater)
    }

    @Test func v0_13_patchReleaseStillEnablesAllFlags() {
        // A v0.13.4 patch release should still enable every v0.13 flag.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.13.4 (2026.5.20)")
        #expect(caps.hasGoals)
        #expect(caps.hasACPQueue)
        #expect(caps.hasKanbanDiagnostics)
        #expect(caps.hasGoogleChatPlatform)
    }

    @Test func v015FlagsAllOn() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.15.0 (2026.5.28)")
        // Earlier-version surfaces stay on.
        #expect(caps.hasCurator)
        #expect(caps.hasACPImagePrompts)
        #expect(caps.hasGoals)
        #expect(caps.hasKanbanDiagnostics)
        #expect(caps.hasSubgoal)
        #expect(caps.hasGrokOAuthProvider)
        #expect(caps.hasHermesProxy)
        #expect(caps.hasCrossSessionClaudeCache)
        // v0.15 Kanban surfaces.
        #expect(caps.hasKanbanSessionFilter)
        #expect(caps.hasKanbanV015)
        // v0.15 web + TTS.
        #expect(caps.hasXAIWebSearchBackend)
        #expect(caps.hasXAITTSAutoSpeechTags)
        // v0.15 platform + auth + secrets.
        #expect(caps.hasNtfyPlatform)
        // A WINDOW, not a floor: v0.15 is where `discord.allow_any_attachment`
        // starts being READ, and v0.18 is where it stops. Do NOT copy this
        // line into the v0.18+ all-on tests — `v018HostHidesTheDiscordAttachmentWindow`
        // below owns the upper end, and the full walk is in
        // `DiscordAllowAnyAttachmentWindowP51Tests` (round-5 P52).
        #expect(caps.hasDiscordAllowAnyAttachment)
        #expect(caps.hasAzureEntraAuth)
        #expect(caps.hasBitwarden)
        // v0.15 verbs.
        #expect(caps.hasHermesAudit)
        #expect(caps.hasXAIModelRetirement)
        // v0.15 MCP + skill surfaces.
        #expect(caps.hasMCPClientCerts)
        #expect(caps.hasMCPCatalog)
        #expect(caps.hasSkillBundles)
        #expect(caps.hasSkillHubFreshness)
        // v0.15 ACP additions.
        #expect(caps.hasSessionEditAutoApproval)
        // Convenience predicate.
        #expect(caps.isV015OrLater)
    }

    @Test func v014HostHidesV015Flags() {
        // Every v0.15 flag must stay off on a pristine v0.14 host so the
        // UI degrades silently. v0.14 flags themselves remain on as a
        // belt-and-braces guard against accidental gate flipping.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.5.16)")
        #expect(!caps.hasKanbanSessionFilter)
        #expect(!caps.hasKanbanV015)
        #expect(!caps.hasXAIWebSearchBackend)
        #expect(!caps.hasNtfyPlatform)
        #expect(!caps.hasXAITTSAutoSpeechTags)
        // The window's LOWER end: no getter exists to read the key at v0.14,
        // so the row is correctly gone there too (round-5 P52).
        #expect(!caps.hasDiscordAllowAnyAttachment)
        #expect(!caps.hasAzureEntraAuth)
        #expect(!caps.hasBitwarden)
        #expect(!caps.hasHermesAudit)
        #expect(!caps.hasXAIModelRetirement)
        #expect(!caps.hasMCPClientCerts)
        #expect(!caps.hasMCPCatalog)
        #expect(!caps.hasSkillBundles)
        #expect(!caps.hasSkillHubFreshness)
        #expect(!caps.hasSessionEditAutoApproval)
        #expect(!caps.isV015OrLater)
        // v0.14 surfaces stay alive on a v0.14 host.
        #expect(caps.hasSubgoal)
        #expect(caps.hasHermesProxy)
        #expect(caps.isV014OrLater)
    }

    /// The upper end of the one window flag in this file, kept beside the
    /// v0.15 pair so a reader of `v015FlagsAllOn` cannot miss that the flag
    /// goes OFF again. `hasDiscordAllowAnyAttachment` is off on a v0.18 host
    /// and on the v0.21.1 target: the Discord adapter stopped calling
    /// `_discord_allow_any_attachment` at v2026.7.1 (0.18.0) and the key is a
    /// documented schema no-op at v2026.9.7
    /// (`hermes_cli/config_defaults.py:1446-1448`). Round-5 P52; the tag walk
    /// is in `DiscordAllowAnyAttachmentWindowP51Tests`.
    @Test func v018HostHidesTheDiscordAttachmentWindow() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)")
            .hasDiscordAllowAnyAttachment)
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
            .hasDiscordAllowAnyAttachment)
        // …while v0.17 still honours it.
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.17.0")
            .hasDiscordAllowAnyAttachment)
    }

    @Test func v0_15_patchReleaseStillEnablesAllFlags() {
        // v0.15.2 (the latest patch as of 2026-06-05) should still enable
        // every v0.15 flag — patches don't roll back capability gates.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.15.2 (2026.5.29)")
        #expect(caps.hasKanbanSessionFilter)
        #expect(caps.hasKanbanV015)
        #expect(caps.hasBitwarden)
        #expect(caps.hasMCPCatalog)
        #expect(caps.hasSessionEditAutoApproval)
        #expect(caps.isV015OrLater)
    }

    // MARK: - isV013OrLater convenience predicate

    @Test func isV013OrLater_v013HostTrue() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)")
        #expect(caps.isV013OrLater)
    }

    @Test func isV013OrLater_v012HostFalse() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")
        #expect(!caps.isV013OrLater)
    }

    @Test func isV013OrLater_emptyFalse() {
        let caps = HermesCapabilities.empty
        #expect(!caps.isV013OrLater)
    }

    @Test func isV013OrLater_v014HostTrue() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.5.16)")
        #expect(caps.isV013OrLater)
    }

    // MARK: - isV014OrLater convenience predicate

    @Test func isV014OrLater_v014HostTrue() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.5.16)")
        #expect(caps.isV014OrLater)
    }

    @Test func isV014OrLater_v013HostFalse() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)")
        #expect(!caps.isV014OrLater)
    }

    @Test func isV014OrLater_emptyFalse() {
        let caps = HermesCapabilities.empty
        #expect(!caps.isV014OrLater)
    }

    // MARK: - isV015OrLater convenience predicate

    @Test func isV015OrLater_v015HostTrue() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.15.0 (2026.5.28)")
        #expect(caps.isV015OrLater)
    }

    @Test func isV015OrLater_v014HostFalse() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.5.16)")
        #expect(!caps.isV015OrLater)
    }

    @Test func isV015OrLater_emptyFalse() {
        let caps = HermesCapabilities.empty
        #expect(!caps.isV015OrLater)
    }

    // MARK: - v0.16 capability flags (backfilled — the v0.16 cycle shipped the
    // flags without this cluster; surfaced by the v0.17 audit)

    @Test func v016FlagsAllOnForV016Host() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.16.0 (2026.6.5)")
        #expect(caps.hasSessionsOptimize)
        #expect(caps.hasKanbanGoalMode)
        #expect(caps.hasDashboardCommand)
        #expect(caps.isV016OrLater)
    }

    @Test func v015HostHidesV016Flags() {
        // Every v0.16 flag must stay off on a pristine v0.15 host.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.15.2 (2026.5.29)")
        #expect(!caps.hasSessionsOptimize)
        #expect(!caps.hasKanbanGoalMode)
        #expect(!caps.isV016OrLater)
        // v0.15 surfaces stay alive on a v0.15 host.
        #expect(caps.hasBitwarden)
        #expect(caps.isV015OrLater)
    }

    // MARK: - v0.17 capability flags

    @Test func v017FlagsAllOnForV017Host() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.17.0 (2026.6.19)")
        // v0.17 config surfaces.
        #expect(caps.hasCuratorConsolidate)
        #expect(caps.hasMaxConcurrentSessions)
        // v0.17 gateway platforms + Telegram.
        #expect(caps.hasPhotonPlatform)
        #expect(caps.hasWhatsAppCloudPlatform)
        #expect(caps.hasTelegramRichMessages)
        // Convenience predicate.
        #expect(caps.isV017OrLater)
    }

    @Test func v016HostHidesV017Flags() {
        // Every v0.17 flag must stay off on a pristine v0.16 host so the UI
        // degrades silently; v0.16 flags themselves remain on.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.16.0 (2026.6.5)")
        #expect(!caps.hasCuratorConsolidate)
        #expect(!caps.hasMaxConcurrentSessions)
        #expect(!caps.hasPhotonPlatform)
        #expect(!caps.hasWhatsAppCloudPlatform)
        #expect(!caps.hasTelegramRichMessages)
        #expect(!caps.isV017OrLater)
        // v0.16 surfaces stay alive on a v0.16 host.
        #expect(caps.hasSessionsOptimize)
        #expect(caps.isV016OrLater)
    }

    @Test func v0_17_patchReleaseStillEnablesAllFlags() {
        // A future v0.17.x patch should still enable every v0.17 flag —
        // patches don't roll back capability gates.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.17.1 (2026.6.26)")
        #expect(caps.hasCuratorConsolidate)
        #expect(caps.hasPhotonPlatform)
        #expect(caps.hasWhatsAppCloudPlatform)
        #expect(caps.isV017OrLater)
    }

    // MARK: - isV016OrLater / isV017OrLater convenience predicates

    @Test func isV016OrLater_v016HostTrue() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.16.0 (2026.6.5)").isV016OrLater)
    }

    @Test func isV016OrLater_v015HostFalse() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.15.2 (2026.5.29)").isV016OrLater)
    }

    @Test func isV017OrLater_v017HostTrue() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.17.0 (2026.6.19)").isV017OrLater)
    }

    @Test func isV017OrLater_v016HostFalse() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.16.0 (2026.6.5)").isV017OrLater)
    }

    @Test func isV017OrLater_emptyFalse() {
        #expect(!HermesCapabilities.empty.isV017OrLater)
    }

    // MARK: - v0.18 capability flags

    @Test func v018FlagsAllOnForV018Host() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)")
        #expect(caps.hasCronAttachToSession)
        #expect(caps.hasMCPReauth)
        #expect(caps.isV018OrLater)
    }

    @Test func v017HostHidesV018Flags() {
        // Every v0.18 flag must stay off on a pristine v0.17 host so the UI
        // degrades silently; v0.17 flags themselves remain on.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.17.0 (2026.6.19)")
        #expect(!caps.hasCronAttachToSession)
        #expect(!caps.hasMCPReauth)
        #expect(!caps.isV018OrLater)
        // v0.17 surfaces stay alive on a v0.17 host.
        #expect(caps.hasCuratorConsolidate)
        #expect(caps.isV017OrLater)
    }

    @Test func v0_18_patchReleaseStillEnablesAllFlags() {
        // A future v0.18.x patch should still enable every v0.18 flag —
        // patches don't roll back capability gates.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.18.1 (2026.7.8)")
        #expect(caps.hasCronAttachToSession)
        #expect(caps.hasMCPReauth)
        #expect(caps.isV018OrLater)
    }

    @Test func v018FlagsIncludeTitleGenerationLanguage() {
        // `auxiliary.title_generation.language` landed at the same v0.18
        // boundary as `hasCronAttachToSession`/`hasMCPReauth`.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)")
        #expect(caps.hasTitleGenerationLanguage)
    }

    @Test func v017HostHidesTitleGenerationLanguage() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.17.0 (2026.6.19)")
        #expect(!caps.hasTitleGenerationLanguage)
    }

    // MARK: - v0.19 capability flags

    @Test func v019FlagsAllOnForV019Host() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)")
        #expect(caps.hasConfigUnset)
        #expect(caps.hasAuxiliaryReasoningEffort)
    }

    @Test func v018HostHidesV019Flags() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)")
        #expect(!caps.hasConfigUnset)
        #expect(!caps.hasAuxiliaryReasoningEffort)
        // v0.18 surfaces stay alive.
        #expect(caps.hasCronAttachToSession)
        #expect(caps.hasMCPReauth)
    }

    @Test func v0_19_patchReleaseStillEnablesAuxiliaryReasoningEffort() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.19.2 (2026.7.30)")
        #expect(caps.hasAuxiliaryReasoningEffort)
    }

    @Test func v019FlagsOnForV019Host_deepInfraTTSAndXAIAdvancedParams() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)")
        #expect(caps.hasDeepInfraTTS)
        #expect(caps.hasXAITTSAdvancedParams)
    }

    @Test func v018HostHidesV019TTSFlags() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)")
        #expect(!caps.hasDeepInfraTTS)
        #expect(!caps.hasXAITTSAdvancedParams)
    }

    @Test func isV018OrLater_v018HostTrue() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)").isV018OrLater)
    }

    @Test func isV018OrLater_v017HostFalse() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.17.0 (2026.6.19)").isV018OrLater)
    }

    @Test func isV018OrLater_emptyFalse() {
        #expect(!HermesCapabilities.empty.isV018OrLater)
    }

    // MARK: - v0.20 capability flags

    @Test func v020FlagsAllOnForV020Host() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)")
        #expect(caps.hasCuratorAdopt)
        #expect(caps.hasApprovalsSuggest)
        #expect(caps.hasCronRuns)
        #expect(caps.hasSessionsExportFormats)
        #expect(caps.hasApprovalSmartPolicy)
        #expect(caps.hasACPCompressSpelling)
        #expect(caps.hasBitwardenEncryptedCache)
        #expect(caps.hasCommandSecretSource)
        #expect(caps.hasSharedMetricsTelemetry)
        #expect(caps.hasDatabaseJournalSettings)
        #expect(caps.hasSTTUnifiedLanguage)
        #expect(caps.hasSTTLocalVADTuning)
        #expect(caps.isV020OrLater)
    }

    @Test func v019HostHidesV020Flags() {
        // Every genuinely-v0.20 flag must stay off on a pristine v0.19 host
        // so the UI degrades silently; v0.18 flags themselves remain on.
        // The seven re-floored surfaces are deliberately NOT in this list —
        // they ship in v2026.7.30 = 0.19.1 and are asserted on below.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.19.2 (2026.7.20)")
        #expect(!caps.isV020OrLater)
        // Re-floored in P23: every one of these landed BELOW v0.20 and a
        // 0.19.2 host genuinely has them. `hasCuratorAdopt` /
        // `hasApprovalsSuggest` → 0.19.1 (v2026.7.30), `hasCronRuns` →
        // 0.19.0 (v2026.7.20), `hasSessionsExportFormats` → 0.18.1
        // (v2026.7.7). `hasCompressCommand` became `hasACPCompressSpelling`,
        // floored at 0.19.1 — the tag where the ACP adapter renamed
        // `/compact` to `/compress` — so a 0.19.2 host has it.
        #expect(caps.hasCuratorAdopt)
        #expect(caps.hasApprovalsSuggest)
        #expect(caps.hasCronRuns)
        #expect(caps.hasSessionsExportFormats)
        // Re-floored to v0.19.1 (v2026.7.30's pyproject.toml says 0.19.1),
        // so a 0.19.2 host keeps them.
        #expect(caps.hasApprovalSmartPolicy)
        #expect(caps.hasBitwardenEncryptedCache)
        #expect(caps.hasCommandSecretSource)
        #expect(caps.hasSharedMetricsTelemetry)
        #expect(caps.hasDatabaseJournalSettings)
        #expect(caps.hasSTTUnifiedLanguage)
        #expect(caps.hasSTTLocalVADTuning)
        // v0.18 surfaces stay alive on a v0.19 host.
        #expect(caps.hasCronAttachToSession)
        #expect(caps.hasMCPReauth)
        #expect(caps.isV018OrLater)
        // v0.19 flags stay alive on a v0.19 host.
        #expect(caps.hasDeepInfraTTS)
        #expect(caps.hasXAITTSAdvancedParams)
    }

    @Test func v0_20_patchReleaseStillEnablesAllFlags() {
        // A future v0.20.x patch should still enable every v0.20 flag —
        // patches don't roll back capability gates.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.1 (2026.8.10)")
        #expect(caps.hasCuratorAdopt)
        #expect(caps.hasApprovalsSuggest)
        #expect(caps.hasCronRuns)
        #expect(caps.hasSessionsExportFormats)
        #expect(caps.hasApprovalSmartPolicy)
        #expect(caps.hasBitwardenEncryptedCache)
        #expect(caps.hasCommandSecretSource)
        #expect(caps.hasSharedMetricsTelemetry)
        #expect(caps.hasDatabaseJournalSettings)
        #expect(caps.hasSTTUnifiedLanguage)
        #expect(caps.hasSTTLocalVADTuning)
        #expect(caps.isV020OrLater)
    }

    @Test func isV020OrLater_v020HostTrue() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)").isV020OrLater)
    }

    @Test func isV020OrLater_v019HostFalse() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.19.2 (2026.7.20)").isV020OrLater)
    }

    @Test func isV020OrLater_emptyFalse() {
        #expect(!HermesCapabilities.empty.isV020OrLater)
    }

    // MARK: - v0.19.1 (v2026.7.30) re-floored capability flags
    //
    // v2026.7.30's `pyproject.toml:5` reads `version = "0.19.1"` — a
    // numbered release, not a pre-release — so seven surfaces the v0.20
    // audit floored at v0.20 belong at v0.19.1. Same four-shape pattern as
    // every other cluster: parse, all-on, prior-host degradation, patch.

    @Test func parseV0191ReleaseLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.19.1 (2026.7.30)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 19, patch: 1))
        #expect(caps.isV0191OrLater)
        #expect(caps.isV019OrLater)
        #expect(!caps.isV020OrLater)
    }

    @Test func v0191FlagsAllOnForV0191Host() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.19.1 (2026.7.30)")
        #expect(caps.hasApprovalSmartPolicy)
        #expect(caps.hasBitwardenEncryptedCache)
        #expect(caps.hasCommandSecretSource)
        #expect(caps.hasSharedMetricsTelemetry)
        #expect(caps.hasDatabaseJournalSettings)
        #expect(caps.hasSTTUnifiedLanguage)
        #expect(caps.hasSTTLocalVADTuning)
    }

    @Test func v0190HostHidesV0191Flags() {
        // v2026.7.20 = 0.19.0 predates every one of the seven, so a 0.19.0
        // host must still degrade silently.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)")
        #expect(!caps.isV0191OrLater)
        #expect(!caps.hasApprovalSmartPolicy)
        #expect(!caps.hasBitwardenEncryptedCache)
        #expect(!caps.hasCommandSecretSource)
        #expect(!caps.hasSharedMetricsTelemetry)
        #expect(!caps.hasDatabaseJournalSettings)
        #expect(!caps.hasSTTUnifiedLanguage)
        #expect(!caps.hasSTTLocalVADTuning)
        // v0.19.0's own surfaces stay on.
        #expect(caps.hasDeepInfraTTS)
        #expect(caps.hasXAITTSAdvancedParams)
        #expect(caps.hasGatewayProfileRoutes)
    }

    @Test func v0_19_1_patchAndMinorReleasesStillEnableAllFlags() {
        for line in ["Hermes Agent v0.19.2 (2026.7.31)",
                     "Hermes Agent v0.20.0 (2026.8.3)",
                     "Hermes Agent v0.21.1 (2026.9.7)"] {
            let caps = HermesCapabilities.parseLine(line)
            #expect(caps.hasApprovalSmartPolicy, "\(line)")
            #expect(caps.hasBitwardenEncryptedCache, "\(line)")
            #expect(caps.hasCommandSecretSource, "\(line)")
            #expect(caps.hasSharedMetricsTelemetry, "\(line)")
            #expect(caps.hasDatabaseJournalSettings, "\(line)")
            #expect(caps.hasSTTUnifiedLanguage, "\(line)")
            #expect(caps.hasSTTLocalVADTuning, "\(line)")
        }
    }

    @Test func isV0191OrLater_emptyFalse() {
        #expect(!HermesCapabilities.empty.isV0191OrLater)
    }

    // MARK: - v0.20.4 capability flags

    @Test func parseV0204ReleaseLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.4 (2026.8.18)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 20, patch: 4))
        #expect(caps.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 8, day: 18))
        #expect(caps.detected)
    }

    @Test func v0204FlagsAllOnForV0204Host() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.4 (2026.8.18)")
        #expect(caps.hasCronPauseMarkerGate)
        #expect(caps.hasBuiltinPersonalitiesInCode)
        #expect(caps.hasCuratorLedger)
        #expect(caps.hasCuratorPurge)
        #expect(caps.hasCuratorEntryRollback)
        #expect(caps.hasSkillsProjectTrust)
        #expect(caps.hasSkillsUpdateForce)
        #expect(caps.hasMCPIdentityHeader)
        #expect(caps.hasKanbanReviewExits)
        #expect(caps.isV0204OrLater)
    }

    @Test func v020HostHidesV0204Flags() {
        // A pristine v0.20.0 host must not see any flag in this group — a
        // plain minor check (isV020OrLater) would wrongly light them up.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)")
        #expect(!caps.hasCronPauseMarkerGate)
        #expect(!caps.hasBuiltinPersonalitiesInCode)
        #expect(!caps.hasCuratorLedger)
        #expect(!caps.hasCuratorPurge)
        #expect(!caps.hasCuratorEntryRollback)
        #expect(!caps.hasSkillsProjectTrust)
        #expect(!caps.hasSkillsUpdateForce)
        #expect(!caps.hasMCPIdentityHeader)
        #expect(!caps.hasKanbanReviewExits)
        #expect(!caps.isV0201OrLater)
        #expect(!caps.isV0203OrLater)
        #expect(!caps.isV0204OrLater)
        // v0.20 surfaces stay alive on a v0.20.0 host.
        #expect(caps.hasCuratorAdopt)
        #expect(caps.isV020OrLater)
    }

    @Test func v0203HostHasEveryFlagInTheV0204Group() {
        // P23 re-floored most of the group to 0.20.1 / 0.20.3, P55 re-floored
        // `hasMCPIdentityHeader` to 0.20.1, and P56 added
        // `hasKanbanReviewExits` at a 0.20.1 floor — so NO member of the
        // v0.20.4 MARK group is a v0.20.4 surface any more and a 0.20.3 host
        // has every one of them.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.3 (2026.8.16.2)")
        #expect(caps.hasMCPIdentityHeader)
        #expect(caps.hasKanbanReviewExits)
        #expect(!caps.isV0204OrLater)
        #expect(caps.hasCronPauseMarkerGate)
        #expect(caps.hasBuiltinPersonalitiesInCode)
        #expect(caps.hasCuratorLedger)
        #expect(caps.hasCuratorPurge)
        #expect(caps.hasCuratorEntryRollback)
        #expect(caps.hasSkillsProjectTrust)
        #expect(caps.hasSkillsUpdateForce)
        #expect(caps.isV0201OrLater)
        #expect(caps.isV0203OrLater)
        #expect(caps.isV020OrLater)
    }

    @Test func v0_20_4_patchReleaseStillEnablesAllFlags() {
        // A future v0.20.5 patch should still enable every v0.20.4 flag —
        // patches don't roll back capability gates.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.5 (2026.8.25)")
        #expect(caps.hasCronPauseMarkerGate)
        #expect(caps.hasBuiltinPersonalitiesInCode)
        #expect(caps.hasCuratorLedger)
        #expect(caps.hasCuratorPurge)
        #expect(caps.hasCuratorEntryRollback)
        #expect(caps.hasSkillsProjectTrust)
        #expect(caps.hasSkillsUpdateForce)
        #expect(caps.hasMCPIdentityHeader)
        #expect(caps.hasKanbanReviewExits)
        #expect(caps.isV0204OrLater)
    }

    @Test func v021FlagsStillEnableV0204Flags() {
        // A future minor release must not regress the v0.20.4 surface.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.9.1)")
        #expect(caps.hasCronPauseMarkerGate)
        #expect(caps.hasBuiltinPersonalitiesInCode)
        #expect(caps.hasCuratorLedger)
        #expect(caps.hasCuratorPurge)
        #expect(caps.hasCuratorEntryRollback)
        #expect(caps.hasSkillsProjectTrust)
        #expect(caps.hasSkillsUpdateForce)
        #expect(caps.hasMCPIdentityHeader)
        #expect(caps.hasKanbanReviewExits)
        #expect(caps.isV0204OrLater)
    }

    @Test func isV0204OrLater_v0204HostTrue() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.4 (2026.8.18)").isV0204OrLater)
    }

    @Test func isV0204OrLater_v0203HostFalse() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.20.3 (2026.8.15)").isV0204OrLater)
    }

    @Test func isV0204OrLater_emptyFalse() {
        #expect(!HermesCapabilities.empty.isV0204OrLater)
    }

    // MARK: - v0.20.5 capability flags

    @Test func parseV0205ReleaseLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.5 (2026.8.19)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 20, patch: 5))
        #expect(caps.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 8, day: 19))
        #expect(caps.detected)
    }

    @Test func v0205FlagsAllOnForV0205Host() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.5 (2026.8.19)")
        #expect(caps.hasVersionFlagFullOutput)
        #expect(caps.hasCronReasoningEffort)
        // P59: `hasBotChatCreationCLI` was declared in the v0.21 MARK group on
        // its v0.20.5 floor and enumerated in NO group test — neither the
        // v0.21 four (where it would have contradicted them) nor these. It is
        // a v0.20.5 flag; this is where a reader goes to learn that.
        #expect(caps.hasBotChatCreationCLI)
        #expect(caps.isV0205OrLater)
    }

    @Test func v0204HostHidesV0205Flags() {
        // A v0.20.4 host must not see any v0.20.5 flag — it still has the
        // `version` subcommand and rejects `cron --reasoning-effort`.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.4 (2026.8.18)")
        #expect(!caps.hasVersionFlagFullOutput)
        #expect(!caps.hasCronReasoningEffort)
        // …and its `chat` parser has no `--query-file`, so the Bot Chat
        // creation argv would die on an unknown flag.
        #expect(!caps.hasBotChatCreationCLI)
        #expect(!caps.isV0205OrLater)
        // The v0.20.4 surface stays alive on a v0.20.4 host.
        #expect(caps.hasCuratorLedger)
        #expect(caps.isV0204OrLater)
    }

    @Test func v0_20_6_patchReleaseStillEnablesAllV0205Flags() {
        // A later patch should still enable every v0.20.5 flag — patches
        // don't roll back capability gates.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.6 (2026.8.30)")
        #expect(caps.hasVersionFlagFullOutput)
        #expect(caps.hasCronReasoningEffort)
        #expect(caps.hasBotChatCreationCLI)
        #expect(caps.isV0205OrLater)
    }

    @Test func v021FlagsStillEnableV0205Flags() {
        // A future minor release must not regress the v0.20.5 surface.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.9.1)")
        #expect(caps.hasVersionFlagFullOutput)
        #expect(caps.hasCronReasoningEffort)
        #expect(caps.hasBotChatCreationCLI)
        #expect(caps.isV0205OrLater)
    }

    @Test func isV0205OrLater_v0205HostTrue() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.5 (2026.8.19)").isV0205OrLater)
    }

    @Test func isV0205OrLater_v0204HostFalse() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.20.4 (2026.8.18)").isV0205OrLater)
    }

    @Test func isV0205OrLater_emptyFalse() {
        #expect(!HermesCapabilities.empty.isV0205OrLater)
    }

    // MARK: - v0.21 capability flags

    @Test func parseV021ReleaseLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 21, patch: 0))
        #expect(caps.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 8, day: 31))
        #expect(caps.detected)
    }

    @Test func v021FlagsAllOnForV021Host() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
        #expect(caps.hasPeerRunCommands)
        #expect(caps.hasCronDoctor)
        #expect(caps.hasCronRecoverableErrorResume)
        #expect(caps.hasConfigDottedKeyEscape)
        #expect(caps.hasCronIncidents)
        #expect(caps.hasCronResumeRunNow)
        #expect(caps.hasCronBotChatDelivery)
        #expect(caps.hasBrowserCloseProfile)
        #expect(caps.isV021OrLater)
        #expect(caps.isV0206OrLater)
    }

    @Test func v0205HostHidesEveryV021Flag() {
        // v0.20.5 predates both the v0.20.6 and the v0.21.0 surface: no
        // `peer run`, no `cron doctor`/`incidents`, no `cron resume
        // --run-now`, no `--deliver bot-chat`, no `browser` subcommand, and
        // no `\.` key escaping (which would corrupt config on this host).
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.5 (2026.8.19)")
        #expect(!caps.hasPeerRunCommands)
        #expect(!caps.hasCronDoctor)
        #expect(!caps.hasCronRecoverableErrorResume)
        #expect(!caps.hasConfigDottedKeyEscape)
        #expect(!caps.hasCronIncidents)
        #expect(!caps.hasCronResumeRunNow)
        #expect(!caps.hasCronBotChatDelivery)
        #expect(!caps.hasBrowserCloseProfile)
        #expect(!caps.isV021OrLater)
        #expect(!caps.isV0206OrLater)
        // The v0.20.5 surface stays alive on a v0.20.5 host — including
        // `hasBotChatCreationCLI`, which was DECLARED in the v0.21 group and
        // is a v0.20.5 flag. P59 moved the declaration into the v0.20.5 group
        // and named it here, because "every v0.21 flag is off at 0.20.5" was
        // read as covering everything that group contained.
        #expect(caps.hasCronReasoningEffort)
        #expect(caps.hasBotChatCreationCLI)
        #expect(caps.isV0205OrLater)
    }

    @Test func v0206HostSeesOnlyTheV0206Subset() {
        // v0.20.6 (v2026.8.27) sits between v0.20.5 and v0.21.0 and already
        // ships `cron incidents`, `cron resume --run-now/--at`, `--deliver
        // bot-chat`, and the `browser` subcommand — but NOT `peer
        // run/status/stop`, `cron doctor`, or dotted-key escaping.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.6 (2026.8.27)")
        #expect(caps.isV0206OrLater)
        #expect(!caps.isV021OrLater)
        #expect(caps.hasCronIncidents)
        #expect(caps.hasCronResumeRunNow)
        #expect(caps.hasCronBotChatDelivery)
        #expect(caps.hasBrowserCloseProfile)
        #expect(!caps.hasPeerRunCommands)
        #expect(!caps.hasCronDoctor)
        #expect(!caps.hasCronRecoverableErrorResume)
        #expect(!caps.hasConfigDottedKeyEscape)
    }

    @Test func v0_21_1_patchReleaseStillEnablesAllV021Flags() {
        // A later patch should still enable every v0.21 flag — patches
        // don't roll back capability gates.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        #expect(caps.hasPeerRunCommands)
        #expect(caps.hasCronDoctor)
        #expect(caps.hasCronRecoverableErrorResume)
        #expect(caps.hasConfigDottedKeyEscape)
        #expect(caps.hasCronIncidents)
        #expect(caps.hasCronResumeRunNow)
        #expect(caps.hasCronBotChatDelivery)
        #expect(caps.hasBrowserCloseProfile)
        #expect(caps.isV021OrLater)
    }

    @Test func isV021OrLater_v021HostTrue() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)").isV021OrLater)
    }

    @Test func isV021OrLater_v0206HostFalse() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.20.6 (2026.8.27)").isV021OrLater)
    }

    @Test func isV021OrLater_emptyFalse() {
        #expect(!HermesCapabilities.empty.isV021OrLater)
    }

    @Test func isV0206OrLater_emptyFalse() {
        #expect(!HermesCapabilities.empty.isV0206OrLater)
    }

    // MARK: Removal flags (inverse semantics — true means "still show it")

    /// `auxiliary.web_extract.*` was deleted from config_defaults.py at
    /// v2026.8.27 (0.20.6), NOT at v0.21 as the release notes imply. The
    /// boundary is what matters: a v0.20.5 host still reads the block.
    @Test func hasWebExtractAux_dropsAtV0206NotV021() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.5 (2026.8.19)").hasWebExtractAux)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.4 (2026.8.16)").hasWebExtractAux)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.19.2 (2026.7.20)").hasWebExtractAux)
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.20.6 (2026.8.27)").hasWebExtractAux)
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)").hasWebExtractAux)
    }

    /// Unknown version hides the sub-editor, matching `hasFlushMemoriesAux`.
    @Test func hasWebExtractAux_unknownVersionHides() {
        #expect(!HermesCapabilities.empty.hasWebExtractAux)
    }

    /// `plugins/web/tavily/` was deleted at v2026.8.31 (0.21.0) and RESTORED
    /// at v2026.9.7 (0.21.1, commit 428e084dcd), so the removal is a window
    /// of exactly one release, not a floor. Verified with `git ls-tree <tag>
    /// plugins/web/` at all four tags below.
    @Test func hasTavilyWebBackend_removalWindowIsExactlyV0210() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.6 (2026.8.27)").hasTavilyWebBackend)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.5 (2026.8.19)").hasTavilyWebBackend)
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)").hasTavilyWebBackend)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasTavilyWebBackend)
        // A future patch keeps it — only 0.21.0 is the hole.
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.20)").hasTavilyWebBackend)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.22.0 (2026.10.1)").hasTavilyWebBackend)
    }

    /// `plugins/web/keenable/` first appears at v2026.8.19 (0.20.5) — NOT
    /// v0.20.6 as the v0.21.1 audit report says. Enumerated with
    /// `git ls-tree <tag> plugins/web/` across every tag in the repo.
    @Test func hasKeenableWebBackend_floorIsV0205() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.20.4 (2026.8.18)").hasKeenableWebBackend)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.5 (2026.8.19)").hasKeenableWebBackend)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasKeenableWebBackend)
        #expect(!HermesCapabilities.empty.hasKeenableWebBackend)
    }

    // MARK: - v0.21.1 capability flags

    @Test func parseV0211ReleaseLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 21, patch: 1))
        #expect(caps.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 9, day: 7))
        #expect(caps.detected)
    }

    @Test func v0211FlagsAllOnForV0211Host() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        #expect(caps.isV0211OrLater)
        #expect(caps.hasPluginsCompat)
        #expect(caps.hasCronCreatePaused)
        #expect(caps.hasCronFailureDeliver)
        #expect(caps.hasCronDispatchDiagnostics)
        #expect(caps.hasKanbanCompletionContract)
        #expect(caps.hasAuthPriority)
        #expect(caps.hasMCPOAuthFlow)
        #expect(caps.hasSessionsExportNoRedact)
        #expect(caps.hasServiceTierBoundedModes)
        #expect(caps.hasSharedMetricsSend)
        #expect(caps.hasPerplexityWebBackend)
    }

    @Test func v0210HostHidesEveryV0211Flag() {
        // Every surface above was verified ABSENT at v2026.8.31 (0.21.0):
        // no `plugins compat` verb, no `--paused`/`--failure-deliver`, no
        // `last_dispatch`, no `--completion-contract`, no `auth priority`,
        // no `mcp login --flow`, no auto/cold service tiers, no
        // `telemetry.shared_metrics.send`, no `plugins/web/perplexity/`.
        //
        // `computer-use doctor --json` and `gateway status`'s multiplexer
        // branch are NOT flags: the doctor payload is cua-driver's, with no
        // stable contract, and the multiplexer verdict is detected in the
        // output Scarf already reads, which is correct on every host.
        //
        // NB `computer-use PERMISSIONS status --json` is NOT in that list:
        // it predates the target by three releases (v0.18) and stays ON
        // here — see `computerUsePermissionsJSONFloorIsV018`.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
        #expect(!caps.isV0211OrLater)
        #expect(!caps.hasPluginsCompat)
        #expect(!caps.hasCronCreatePaused)
        #expect(!caps.hasCronFailureDeliver)
        #expect(!caps.hasCronDispatchDiagnostics)
        #expect(!caps.hasKanbanCompletionContract)
        #expect(!caps.hasAuthPriority)
        #expect(!caps.hasMCPOAuthFlow)
        // `sessions export --no-redact` is NOT a v0.21.1 surface: argparse
        // registers it at `hermes_cli/main.py:13567` @ v2026.7.7 (0.18.1),
        // so it stays ON here — the same floor as `--format trace` itself.
        #expect(caps.hasSessionsExportNoRedact)
        #expect(caps.hasSessionsExportFormats)
        #expect(!caps.hasServiceTierBoundedModes)
        #expect(!caps.hasSharedMetricsSend)
        #expect(!caps.hasPerplexityWebBackend)
        // ...while the v0.20 COLLECTION switch it sits next to stays on.
        #expect(caps.hasSharedMetricsTelemetry)
        // The v0.21.0 surface stays alive on a v0.21.0 host.
        #expect(caps.hasPeerRunCommands)
        #expect(caps.hasCronDoctor)
        #expect(caps.hasCronRecoverableErrorResume)
        #expect(caps.isV021OrLater)
    }

    @Test func v0_21_2_patchReleaseStillEnablesAllV0211Flags() {
        // Patches don't roll back capability gates.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.20)")
        #expect(caps.isV0211OrLater)
        #expect(caps.hasPluginsCompat)
        #expect(caps.hasCronCreatePaused)
        #expect(caps.hasCronFailureDeliver)
        #expect(caps.hasCronDispatchDiagnostics)
        #expect(caps.hasKanbanCompletionContract)
        #expect(caps.hasAuthPriority)
        #expect(caps.hasMCPOAuthFlow)
        #expect(caps.hasSessionsExportNoRedact)
        #expect(caps.hasServiceTierBoundedModes)
        #expect(caps.hasSharedMetricsSend)
        #expect(caps.hasPerplexityWebBackend)
    }

    @Test func isV0211OrLater_emptyFalse() {
        #expect(!HermesCapabilities.empty.isV0211OrLater)
        #expect(!HermesCapabilities.empty.hasPluginsCompat)
        #expect(!HermesCapabilities.empty.hasPerplexityWebBackend)
        #expect(!HermesCapabilities.empty.hasSessionsExportNoRedact)
    }

    /// `sessions export --no-redact` four-way: the floor is v0.18.1, the tag
    /// that registered the option (`hermes_cli/main.py:13567` @ v2026.7.7),
    /// NOT v0.21.1 — and it moves with `--format trace`, since an export
    /// cannot opt out of redacting a format the host does not offer.
    @Test func sessionsExportNoRedactFloorIsV0181() {
        let below = HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)")
        #expect(!below.hasSessionsExportNoRedact)
        #expect(!below.hasSessionsExportFormats)

        let at = HermesCapabilities.parseLine("Hermes Agent v0.18.1 (2026.7.7)")
        #expect(at.hasSessionsExportNoRedact)
        #expect(at.hasSessionsExportFormats)

        // Every release in between keeps it — this is the span the round-2
        // pass force-disabled.
        for line in ["Hermes Agent v0.19.0 (2026.7.20)",
                     "Hermes Agent v0.20.0 (2026.8.3)",
                     "Hermes Agent v0.21.0 (2026.8.31)",
                     "Hermes Agent v0.21.1 (2026.9.7)"] {
            #expect(HermesCapabilities.parseLine(line).hasSessionsExportNoRedact)
        }

        #expect(!HermesCapabilities.empty.hasSessionsExportNoRedact)
    }

    @Test func v0211FlagsStillEnableEveryOlderFlag() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        #expect(caps.hasPeerRunCommands)
        #expect(caps.hasCronDoctor)
        #expect(caps.hasCronRecoverableErrorResume)
        #expect(caps.hasConfigDottedKeyEscape)
        #expect(caps.hasCronIncidents)
        #expect(caps.hasCronResumeRunNow)
        #expect(caps.hasCronBotChatDelivery)
        #expect(caps.hasBrowserCloseProfile)
        #expect(caps.hasCronReasoningEffort)
        #expect(caps.hasVersionFlagFullOutput)
        #expect(caps.isV0205OrLater)
        #expect(caps.isV0206OrLater)
        #expect(caps.isV021OrLater)
    }

    /// Unknown version KEEPS the picker entry — the opposite policy from
    /// `hasWebExtractAux`, and deliberately so: hiding a list entry a
    /// pre-v0.21 user is actively using would strand them on an invisible
    /// selection, whereas the aux row is a whole sub-editor.
    /// `platforms.telegram.extra.ignore_root_dm` lost its READER at v0.21.1.
    /// Walked over every tag and both file locations the reader has had:
    /// `gateway/platforms/telegram.py:4879` from v2026.5.28 (0.15.0), then
    /// `plugins/platforms/telegram/adapter.py` after the v0.18 plugin split
    /// (`:9835` at v2026.8.31 = 0.21.0, its last appearance). A WHOLE-TREE
    /// `git grep ignore_root_dm v2026.9.7` returns only
    /// `scripts/release.py:798` (a contributor-attribution comment) and the
    /// website docs — no reader anywhere in the shipped code.
    ///
    /// This is the assertion that fails if the flag is ever rewritten as a
    /// plain floor (`isV015OrLater`), which would leave the row rendered on
    /// every v0.21.1+ host.
    @Test func hasTelegramIgnoreRootDM_windowIsV015ThroughV0210() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.5.16)").hasTelegramIgnoreRootDM)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.15.0 (2026.5.28)").hasTelegramIgnoreRootDM)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)").hasTelegramIgnoreRootDM)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.6 (2026.8.27)").hasTelegramIgnoreRootDM)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)").hasTelegramIgnoreRootDM)
        // Ceiling: the reader is gone at 0.21.1 and stays gone.
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasTelegramIgnoreRootDM)
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.20)").hasTelegramIgnoreRootDM)
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.22.0 (2026.10.1)").hasTelegramIgnoreRootDM)
    }

    /// Unknown version KEEPS the row (charter C1): before this flag existed
    /// the toggle was unconditional, so a host whose `--version` probe has
    /// not answered must go on rendering it.
    @Test func hasTelegramIgnoreRootDM_unknownVersionKeeps() {
        #expect(HermesCapabilities.empty.hasTelegramIgnoreRootDM)
    }

    /// `display.busy_input_mode: steer` — floor v0.12.0, found by walking the
    /// READER across every tag: `elif _bim == "steer":` first appears at
    /// v2026.4.30 (0.12.0) `cli.py:1946` and is unbroken to v2026.9.7, whose
    /// modularised reader states the member set outright (`cli.py:2592`
    /// `_bim if _bim in ("queue", "steer") else "interrupt"`). v2026.4.23's
    /// `"steer"` hits are the `/steer` slash command, a different surface.
    @Test func hasBusyInputSteerMode_floorIsV012() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.11.0 (2026.4.23)").hasBusyInputSteerMode)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)").hasBusyInputSteerMode)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)").hasBusyInputSteerMode)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasBusyInputSteerMode)
    }

    /// Unknown version HIDES it: `steer` is absent from the picker today, so
    /// an unanswered version probe must keep that rendering.
    @Test func hasBusyInputSteerMode_unknownVersionHides() {
        #expect(!HermesCapabilities.empty.hasBusyInputSteerMode)
    }

    @Test func hasTavilyWebBackend_unknownVersionKeeps() {
        #expect(HermesCapabilities.empty.hasTavilyWebBackend)
    }

    // MARK: - Older floors corrected in the v0.21.1 Phase-4 pass
    //
    // Each of these was reached for by the v0.21.1 audit and turned out to
    // predate the target. Gating them at v0.21.1 would hide a working
    // surface on hosts that have it, so each floor was found by walking
    // EVERY tag's argparse rather than diffing the two endpoint tags.

    /// `computer-use permissions status --json` is on the parser from
    /// v2026.7.1 (0.18.0) — in `hermes_cli/main.py` until v0.21.1 moved the
    /// verb into `hermes_cli/subcommands/computer_use.py`, which is why it
    /// LOOKS new if you only grep the new module.
    @Test func computerUsePermissionsJSONFloorIsV018() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.17.0 (2026.6.19)").hasComputerUsePermissionsJSON)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)").hasComputerUsePermissionsJSON)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)").hasComputerUsePermissionsJSON)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasComputerUsePermissionsJSON)
        #expect(!HermesCapabilities.empty.hasComputerUsePermissionsJSON)
    }

    /// `skills search --json` first appears at v2026.6.19 (0.17.0), with the
    /// same five keys it emits at the target tag.
    @Test func skillsSearchJSONFloorIsV017() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.16.0 (2026.6.5)").hasSkillsSearchJSON)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.17.0 (2026.6.19)").hasSkillsSearchJSON)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasSkillsSearchJSON)
        #expect(!HermesCapabilities.empty.hasSkillsSearchJSON)
    }

    /// `browse-sh` joins `--source` at v2026.5.28 (0.15.0); the seven
    /// PROVIDER filters arrive together at v2026.7.1 (0.18.0). argparse
    /// rejects an unknown `--source`, so the two floors must not be merged.
    @Test func skillsSourceChoiceFloors() {
        let v014 = HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.5.16)")
        #expect(!v014.hasSkillsBrowseSHSource)
        #expect(!v014.hasSkillsProviderSources)

        let v015 = HermesCapabilities.parseLine("Hermes Agent v0.15.0 (2026.5.28)")
        #expect(v015.hasSkillsBrowseSHSource)
        #expect(!v015.hasSkillsProviderSources)

        let v017 = HermesCapabilities.parseLine("Hermes Agent v0.17.0 (2026.6.19)")
        #expect(v017.hasSkillsBrowseSHSource)
        #expect(!v017.hasSkillsProviderSources)

        let v018 = HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)")
        #expect(v018.hasSkillsBrowseSHSource)
        #expect(v018.hasSkillsProviderSources)
    }

    /// `debug share -y/--yes` (and the non-TTY refusal it answers) arrive
    /// together at v2026.7.1 (0.18.0). Below that the upload just proceeds,
    /// and passing the flag would be an argparse error.
    @Test func debugShareYesFloorIsV018() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.17.0 (2026.6.19)").hasDebugShareYes)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)").hasDebugShareYes)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasDebugShareYes)
        #expect(!HermesCapabilities.empty.hasDebugShareYes)
    }

    // MARK: - P23 re-floor walks (round-2 whole-surface audit)
    //
    // One test per re-floored flag, each asserting the floor tag ON and the
    // tag immediately BELOW it OFF, which is what makes the test fail if the
    // floor is reverted: the old v0.20 / v0.20.4 literals all fail the
    // floor-on half.

    /// `hermes cron runs` — `hermes_cli/subcommands/cron.py:159` at v2026.7.20
    /// (0.19.0); the symbol `cron_runs` exists in no file at v2026.7.7.2.
    @Test func cronRunsFloorIsV0190() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.18.2 (2026.7.7.2)").hasCronRuns)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)").hasCronRuns)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasCronRuns)
        #expect(!HermesCapabilities.empty.hasCronRuns)
    }

    /// `curator adopt` / `curator list-unmanaged` — `hermes_cli/curator.py:344`
    /// and `:748` at v2026.7.30 (0.19.1); neither at v2026.7.20 (0.19.0).
    @Test func curatorAdoptFloorIsV0191() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)").hasCuratorAdopt)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.19.1 (2026.7.30)").hasCuratorAdopt)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasCuratorAdopt)
        #expect(!HermesCapabilities.empty.hasCuratorAdopt)
    }

    /// `hermes_cli/approvals_suggest.py` first exists at v2026.7.30 (0.19.1).
    @Test func approvalsSuggestFloorIsV0191() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)").hasApprovalsSuggest)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.19.1 (2026.7.30)").hasApprovalsSuggest)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasApprovalsSuggest)
        #expect(!HermesCapabilities.empty.hasApprovalsSuggest)
    }

    /// `sessions export --format` with the five choices —
    /// `hermes_cli/main.py:13546` at v2026.7.7 (0.18.1); `qmd` occurs nowhere
    /// under `hermes_cli/` at v2026.7.1 (0.18.0).
    @Test func sessionsExportFormatsFloorIsV0181() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)").hasSessionsExportFormats)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.18.1 (2026.7.7)").hasSessionsExportFormats)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasSessionsExportFormats)
        #expect(!HermesCapabilities.empty.hasSessionsExportFormats)
    }

    /// The two reasoning-effort levels have DIFFERENT floors (P35):
    /// `VALID_REASONING_EFFORTS` gains `max` at v2026.7.7 (0.18.1,
    /// `hermes_constants.py:794`) and `ultra` one release later at
    /// v2026.7.20 (0.19.0, `:835-837`). v2026.7.1 (0.18.0) has neither and
    /// v2026.7.7.2 (0.18.2) has only `max`.
    @Test func reasoningEffortMaxAndUltraFloorsAreOneReleaseApart() {
        let v0180 = HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)")
        #expect(!v0180.hasReasoningEffortMax)
        #expect(!v0180.hasReasoningEffortUltra)

        let v0181 = HermesCapabilities.parseLine("Hermes Agent v0.18.1 (2026.7.7)")
        #expect(v0181.hasReasoningEffortMax)
        #expect(!v0181.hasReasoningEffortUltra)

        let v0182 = HermesCapabilities.parseLine("Hermes Agent v0.18.2 (2026.7.7.2)")
        #expect(v0182.hasReasoningEffortMax)
        #expect(!v0182.hasReasoningEffortUltra)

        let v019 = HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)")
        #expect(v019.hasReasoningEffortMax)
        #expect(v019.hasReasoningEffortUltra)

        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasReasoningEffortUltra)
        #expect(!HermesCapabilities.empty.hasReasoningEffortMax)
        #expect(!HermesCapabilities.empty.hasReasoningEffortUltra)
    }

    /// `hermes_cli/personality.py` first exists at v2026.8.13 (0.20.1).
    @Test func builtinPersonalitiesInCodeFloorIsV0201() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)").hasBuiltinPersonalitiesInCode)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.1 (2026.8.13)").hasBuiltinPersonalitiesInCode)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.3 (2026.8.16.2)").hasBuiltinPersonalitiesInCode)
        #expect(!HermesCapabilities.empty.hasBuiltinPersonalitiesInCode)
    }

    /// `cron/jobs.py:482` `_has_pause_marker` at v2026.8.13 (0.20.1); the
    /// symbol is absent from that file at v2026.8.3 (0.20.0).
    @Test func cronPauseMarkerGateFloorIsV0201() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)").hasCronPauseMarkerGate)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.1 (2026.8.13)").hasCronPauseMarkerGate)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasCronPauseMarkerGate)
        #expect(!HermesCapabilities.empty.hasCronPauseMarkerGate)
    }

    /// The five curator/skills verbs land together at v2026.8.16.2 (0.20.3)
    /// and are all absent at v2026.8.16 (0.20.2).
    @Test func curatorAndSkillsVerbFloorsAreV0203() {
        let v0202 = HermesCapabilities.parseLine("Hermes Agent v0.20.2 (2026.8.16)")
        #expect(!v0202.hasCuratorLedger)
        #expect(!v0202.hasCuratorPurge)
        #expect(!v0202.hasCuratorEntryRollback)
        #expect(!v0202.hasSkillsProjectTrust)
        #expect(!v0202.hasSkillsUpdateForce)

        let v0203 = HermesCapabilities.parseLine("Hermes Agent v0.20.3 (2026.8.16.2)")
        #expect(v0203.hasCuratorLedger)
        #expect(v0203.hasCuratorPurge)
        #expect(v0203.hasCuratorEntryRollback)
        #expect(v0203.hasSkillsProjectTrust)
        #expect(v0203.hasSkillsUpdateForce)

        #expect(!HermesCapabilities.empty.hasCuratorLedger)
        #expect(!HermesCapabilities.empty.hasSkillsUpdateForce)
    }

    /// `hasHermesSpeechSynthesis` — four-way. Floor v0.20.1 (v2026.8.13):
    /// `text_to_speech_tool`'s `file_paths` envelope (`tools/tts_tool.py:3669-3670`)
    /// and `.chunkNNN`/`.partNN` naming (`:3612-3613`, `:1691-1692`) first
    /// appear there; v2026.8.3 (0.20.0) has neither, and v2026.7.30 (0.19.1)
    /// has the `provider` kwarg (`:2786`) but not the envelope.
    @Test func hermesSpeechSynthesisFloorIsV0201() {
        // Parse + degradation.
        let v0200 = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)")
        #expect(v0200.detected)
        #expect(!v0200.hasHermesSpeechSynthesis)
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.19.1 (2026.7.30)").hasHermesSpeechSynthesis)
        // At the floor, all-on at the target, and later patches stay on.
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.1 (2026.8.13)").hasHermesSpeechSynthesis)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)").hasHermesSpeechSynthesis)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)").hasHermesSpeechSynthesis)
        // Undetected host behaves as the older one.
        #expect(!HermesCapabilities.empty.hasHermesSpeechSynthesis)
    }

    @Test func isV0201OrLater_boundaries() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)").isV0201OrLater)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.1 (2026.8.13)").isV0201OrLater)
        #expect(!HermesCapabilities.empty.isV0201OrLater)
    }

    // MARK: - P29: the three P23 flags that shipped with no boundary tests

    /// `hasGeminiKittenTTS` — four-way. The floor is v0.11.0, evidenced by the
    /// provider DISPATCH arms `elif provider == "gemini"` / `== "kittentts"`
    /// (`tools/tts_tool.py:1024,1038` @ v2026.4.23), not by
    /// `BUILTIN_TTS_PROVIDERS`, which does not exist until v2026.4.30
    /// (0.12.0). `tools/tts_tool.py` exists at v2026.4.16 (0.10.0) and
    /// contains neither name.
    @Test func geminiKittenTTSFloorIsV011() {
        // Parse + degradation: the release below has no such providers, so
        // offering them would write a `tts.provider` the host cannot dispatch.
        let v010 = HermesCapabilities.parseLine("Hermes Agent v0.10.0 (2026.4.16)")
        #expect(v010.detected)
        #expect(!v010.hasGeminiKittenTTS)

        // At the floor.
        let v011 = HermesCapabilities.parseLine("Hermes Agent v0.11.0 (2026.4.23)")
        #expect(v011.hasGeminiKittenTTS)

        // All-on at the target, and a patch above it does not roll back.
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasGeminiKittenTTS)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.11.1 (2026.4.26)").hasGeminiKittenTTS)

        // Undetected host behaves as the older one.
        #expect(!HermesCapabilities.empty.hasGeminiKittenTTS)
    }

    /// `hasElevenLabsDeepInfraSTT` — four-way. `BUILTIN_STT_PROVIDERS` gains
    /// both names at v2026.7.20 (0.19.0), mirrored by
    /// `agent/transcription_registry.py::_BUILTIN_NAMES:47-48`; v2026.7.7.2
    /// (0.18.2) has neither.
    @Test func elevenLabsDeepInfraSTTFloorIsV019() {
        let v0182 = HermesCapabilities.parseLine("Hermes Agent v0.18.2 (2026.7.7.2)")
        #expect(!v0182.hasElevenLabsDeepInfraSTT)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)").hasElevenLabsDeepInfraSTT)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasElevenLabsDeepInfraSTT)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.19.1 (2026.7.30)").hasElevenLabsDeepInfraSTT)
        #expect(!HermesCapabilities.empty.hasElevenLabsDeepInfraSTT)
        // It shares its tag with the DeepInfra TTS side, so the two must move
        // together.
        #expect(!v0182.hasDeepInfraTTS)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)").hasDeepInfraTTS)
    }

    /// `isV011OrLater` — four-way, through its one consumer. The boundary is a
    /// DEFAULT that changed inside the supported window:
    /// `agent.gateway_notify_interval` is `600` at `hermes_cli/config.py:373`
    /// @ v2026.4.16 (0.10.0) and `180` at `:391` @ v2026.4.23 (0.11.0). An
    /// absent key therefore displays differently per host, which is the only
    /// honest thing to show.
    @Test func isV011OrLaterFloorAndItsNotifyIntervalConsumer() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.10.0 (2026.4.16)").isV011OrLater)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.11.0 (2026.4.23)").isV011OrLater)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").isV011OrLater)
        #expect(!HermesCapabilities.empty.isV011OrLater)

        // The consumer: an ABSENT key resolves to the host's own default…
        let config = HermesConfig(yaml: "agent:\n  model: kimi-k2\n")
        #expect(config.gatewayNotifyInterval == nil)
        #expect(config.displayGatewayNotifyInterval(
            capabilities: HermesCapabilities.parseLine("Hermes Agent v0.10.0 (2026.4.16)")) == 600)
        #expect(config.displayGatewayNotifyInterval(
            capabilities: HermesCapabilities.parseLine("Hermes Agent v0.11.0 (2026.4.23)")) == 180)
        // …an undetected host to the older 600…
        #expect(config.displayGatewayNotifyInterval(capabilities: .empty) == 600)
        // …and a PRESENT key wins on every host (the patch-still-on arm).
        let stored = HermesConfig(yaml: "agent:\n  gateway_notify_interval: 42\n")
        #expect(stored.gatewayNotifyInterval == 42)
        for line in ["Hermes Agent v0.10.0 (2026.4.16)", "Hermes Agent v0.21.1 (2026.9.7)"] {
            #expect(stored.displayGatewayNotifyInterval(
                capabilities: HermesCapabilities.parseLine(line)) == 42)
        }
    }

    // MARK: - P23 gate removals (floor below the supported minimum)

    /// **The consumer pin lives in the Mac target**, because the ungating
    /// lives in a VIEW: see
    /// `scarfTests/HermesP29RoundThreeRemediationTests.theRenameMenuItemIsRenderedUnconditionally`,
    /// which fails if the `ChatSessionListPane` menu item is wrapped in a
    /// capability check again. This test can only say that nothing here claims
    /// a rename floor.
    ///
    /// `sessions rename` exists at EVERY tag — `hermes_cli/main.py:2373` at
    /// v2026.3.12 (0.2.0), below Scarf's v0.6.0 minimum — so there is no
    /// flag to read. The rename context-menu item in `ChatSessionListPane`
    /// is unconditional; this pins the absence of a gate by asserting that
    /// the oldest supported host is not distinguishable from the target on
    /// any sessions-rename-shaped capability. (Compile-time proof that
    /// `hasSessionsRename` is gone lives in the file itself — referencing it
    /// here would not build.)
    @Test func sessionsRenameIsUngated() {
        // The one sessions flag that IS release-gated still gates; nothing
        // alongside it claims a rename floor.
        let v012 = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")
        #expect(!v012.hasSessionsOptimize)
        #expect(v012.detected)
    }

    /// The compress slash command's spelling is ACP-gated at v0.19.1, and
    /// BOTH spellings are pinned on both sides of the floor. The ACP adapter
    /// has no alias either way (`acp_adapter/commands.py:88-95` @ v2026.9.7,
    /// `acp_adapter/server.py:1743-1748` @ v2026.7.20 — unknown commands fall
    /// through to the LLM), so sending the other name is a silently burned
    /// turn, not an error. `_SLASH_COMMANDS` says `compact` at
    /// `acp_adapter/server.py:459` @ v2026.7.20 (0.19.0) and `compress` at
    /// `:574` @ v2026.7.30 (0.19.1).
    @Test func compressSlashCommandSpellingFollowsTheACPFloor() {
        // Below the floor — and an undetected host, which must behave as the
        // older one (C1) — the command is `/compact`.
        let below = [
            HermesCapabilities.empty,
            HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)"),
            HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)"),
            HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)")
        ]
        for caps in below {
            #expect(!caps.hasACPCompressSpelling, "\(caps.versionLine)")
            #expect(RichChatViewModel.compressSlashName(capabilities: caps) == "compact")
            #expect(RichChatViewModel.compressSlashCommand(capabilities: caps) == "/compact")
            #expect(
                RichChatViewModel.compressSlashCommand(capabilities: caps, focus: " auth ")
                    == "/compact auth"
            )
            let names = RichChatViewModel.alwaysAvailableCommands(capabilities: caps)
                .map(\.name)
            #expect(names.contains("compact"), "\(caps.versionLine)")
            #expect(!names.contains("compress"), "\(caps.versionLine)")
        }

        // At and above the floor it is `/compress`.
        let atOrAbove = [
            HermesCapabilities.parseLine("Hermes Agent v0.19.1 (2026.7.30)"),
            HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)"),
            HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        ]
        for caps in atOrAbove {
            #expect(caps.hasACPCompressSpelling, "\(caps.versionLine)")
            #expect(RichChatViewModel.compressSlashName(capabilities: caps) == "compress")
            #expect(RichChatViewModel.compressSlashCommand(capabilities: caps) == "/compress")
            #expect(
                RichChatViewModel.compressSlashCommand(capabilities: caps, focus: " auth ")
                    == "/compress auth"
            )
            let names = RichChatViewModel.alwaysAvailableCommands(capabilities: caps)
                .map(\.name)
            #expect(names.contains("compress"), "\(caps.versionLine)")
            #expect(!names.contains("compact"), "\(caps.versionLine)")
        }
    }

    // MARK: - P23 parser fails closed (Alan's round-2 decision 7)

    /// A DATE-only version line (`v2026.9.7` — what a wrapper or shim on
    /// PATH emits) used to parse as `SemVer(2026, 9, 7)` and light up every
    /// floor in the file, including the write and argv gates. It must now
    /// yield the same `.empty` a failed probe does.
    @Test func parseRejectsDateOnlyVersionLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v2026.9.7")
        #expect(caps.semver == nil)
        #expect(!caps.detected)
        #expect(!caps.hasCronCreatePaused)
        #expect(!caps.hasConfigDottedKeyEscape)
        #expect(!caps.hasCronFailureDeliver)
        // Same through the production entry point, with the date suffix too.
        let viaParse = HermesCapabilities.parse("Hermes Agent v2026.9.7 (2026.9.7)\n")
        #expect(!viaParse.detected)
        #expect(!viaParse.isV021OrLater)
    }

    /// A two-digit major is outside the recognised 0...9 range, so it fails
    /// closed rather than reading as "newer than everything".
    @Test func parseRejectsTwoDigitMajor() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v10.0.0").detected)
        #expect(!HermesCapabilities.parseLine("Hermes Agent v99.1.2 (2027.1.1)").detected)
    }

    /// The legitimate shapes must still parse — the bound is a ceiling on the
    /// MAJOR only, not on minor or patch.
    @Test func parseStillAcceptsLegitimateShapes() {
        let target = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        #expect(target.semver == HermesCapabilities.SemVer(major: 0, minor: 21, patch: 1))
        #expect(target.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 9, day: 7))

        let oldest = HermesCapabilities.parseLine("Hermes Agent v0.6.0 (2026.3.30)")
        #expect(oldest.semver == HermesCapabilities.SemVer(major: 0, minor: 6, patch: 0))

        // Single-digit majors above 0 are plausible future Hermes and stay in.
        #expect(HermesCapabilities.parseLine("Hermes Agent v1.0.0").semver
            == HermesCapabilities.SemVer(major: 1, minor: 0, patch: 0))
        #expect(HermesCapabilities.parseLine("Hermes Agent v9.300.4000").semver
            == HermesCapabilities.SemVer(major: 9, minor: 300, patch: 4000))
        // No date suffix is still fine.
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.3").detected)
    }
}
