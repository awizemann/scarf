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
        #expect(caps.hasACPSteerOnIdle)
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
        #expect(caps.hasACPSetSessionModel)
    }

    @Test func v012FlagsAllOn() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")
        // v0.12 surfaces on.
        #expect(caps.hasCurator)
        #expect(caps.hasFallbackCommand)
        #expect(caps.hasKanban)
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
        #expect(!caps.hasACPSetSessionModel)
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
        #expect(caps.hasACPSetSessionModel)
        #expect(!caps.hasFlushMemoriesAux)
        // v0.14 slash commands.
        #expect(caps.hasSubgoal)
        #expect(caps.hasYOLOSlashCommand)
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
        #expect(!caps.hasYOLOSlashCommand)
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
        #expect(caps.hasACPSetSessionModel)
        #expect(caps.hasSubgoal)
        #expect(caps.hasYOLOSlashCommand)
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
        #expect(caps.hasSessionsRename)
        #expect(caps.hasSessionsOptimize)
        #expect(caps.hasKanbanGoalMode)
        #expect(caps.hasInsightsCommand)
        #expect(caps.hasDashboardCommand)
        #expect(caps.isV016OrLater)
    }

    @Test func v015HostHidesV016Flags() {
        // Every v0.16 flag must stay off on a pristine v0.15 host.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.15.2 (2026.5.29)")
        #expect(!caps.hasSessionsRename)
        #expect(!caps.hasSessionsOptimize)
        #expect(!caps.hasKanbanGoalMode)
        #expect(!caps.hasInsightsCommand)
        #expect(!caps.hasDashboardCommand)
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
        #expect(caps.hasSessionsRename)
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
        #expect(caps.hasCompressCommand)
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

    @Test func v019HostHidesV020Flags() {
        // Every v0.20 flag must stay off on a pristine v0.19 host so the UI
        // degrades silently; v0.18 flags themselves remain on.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.19.2 (2026.7.20)")
        #expect(!caps.hasCompressCommand)
        #expect(!caps.hasCuratorAdopt)
        #expect(!caps.hasApprovalsSuggest)
        #expect(!caps.hasCronRuns)
        #expect(!caps.hasSessionsExportFormats)
        #expect(!caps.hasApprovalSmartPolicy)
        #expect(!caps.hasBitwardenEncryptedCache)
        #expect(!caps.hasCommandSecretSource)
        #expect(!caps.hasSharedMetricsTelemetry)
        #expect(!caps.hasDatabaseJournalSettings)
        #expect(!caps.hasSTTUnifiedLanguage)
        #expect(!caps.hasSTTLocalVADTuning)
        #expect(!caps.isV020OrLater)
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
        #expect(caps.hasCompressCommand)
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
        #expect(caps.isV0204OrLater)
    }

    @Test func v020HostHidesV0204Flags() {
        // A pristine v0.20.0 host must not see any v0.20.4 flag — a plain
        // minor check (isV020OrLater) would wrongly light these up.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)")
        #expect(!caps.hasCronPauseMarkerGate)
        #expect(!caps.hasBuiltinPersonalitiesInCode)
        #expect(!caps.hasCuratorLedger)
        #expect(!caps.hasCuratorPurge)
        #expect(!caps.hasCuratorEntryRollback)
        #expect(!caps.hasSkillsProjectTrust)
        #expect(!caps.hasSkillsUpdateForce)
        #expect(!caps.hasMCPIdentityHeader)
        #expect(!caps.isV0204OrLater)
        // v0.20 surfaces stay alive on a v0.20.0 host.
        #expect(caps.hasCompressCommand)
        #expect(caps.isV020OrLater)
    }

    @Test func v0203HostHidesV0204Flags() {
        // Degradation must hold through the last pre-0.20.4 patch too.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.3 (2026.8.15)")
        #expect(!caps.hasCronPauseMarkerGate)
        #expect(!caps.hasBuiltinPersonalitiesInCode)
        #expect(!caps.hasCuratorLedger)
        #expect(!caps.hasCuratorPurge)
        #expect(!caps.hasCuratorEntryRollback)
        #expect(!caps.hasSkillsProjectTrust)
        #expect(!caps.hasSkillsUpdateForce)
        #expect(!caps.hasMCPIdentityHeader)
        #expect(!caps.isV0204OrLater)
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
        #expect(caps.isV0205OrLater)
    }

    @Test func v0204HostHidesV0205Flags() {
        // A v0.20.4 host must not see any v0.20.5 flag — it still has the
        // `version` subcommand and rejects `cron --reasoning-effort`.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.4 (2026.8.18)")
        #expect(!caps.hasVersionFlagFullOutput)
        #expect(!caps.hasCronReasoningEffort)
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
        #expect(caps.isV0205OrLater)
    }

    @Test func v021FlagsStillEnableV0205Flags() {
        // A future minor release must not regress the v0.20.5 surface.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.9.1)")
        #expect(caps.hasVersionFlagFullOutput)
        #expect(caps.hasCronReasoningEffort)
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
        #expect(!caps.hasConfigDottedKeyEscape)
        #expect(!caps.hasCronIncidents)
        #expect(!caps.hasCronResumeRunNow)
        #expect(!caps.hasCronBotChatDelivery)
        #expect(!caps.hasBrowserCloseProfile)
        #expect(!caps.isV021OrLater)
        #expect(!caps.isV0206OrLater)
        // The v0.20.5 surface stays alive on a v0.20.5 host.
        #expect(caps.hasCronReasoningEffort)
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
        #expect(!caps.hasConfigDottedKeyEscape)
    }

    @Test func v0_21_1_patchReleaseStillEnablesAllV021Flags() {
        // A later patch should still enable every v0.21 flag — patches
        // don't roll back capability gates.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        #expect(caps.hasPeerRunCommands)
        #expect(caps.hasCronDoctor)
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
}
