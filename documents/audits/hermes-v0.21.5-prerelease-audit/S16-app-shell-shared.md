# S16-app-shell-shared — verdict: WORKS
## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | App launch: env enrichment, bundled skill/slash-command/env-mirror/MCP bootstrap (scarfApp.swift:71-160), all detached off main actor, skipped on synthetic hosts | WORKS | none (bootstrap services themselves owned by other sections) |
| 2 | Per-server window binding + profile scope (scarfApp.swift:229, :462-501) + capability re-detect on activate | WORKS | none |
| 3 | Menu bar status poll (pgrep + gateway_state.json, detached, backoff) and Start/Stop/Restart (scarfApp.swift:604-805) | WORKS | none — start uses HermesGatewayServiceVerdict judge (owned by gateway section); UI state comes from the re-poll, so it stays honest on failure |
| 4 | Sidebar capability-gated navigation (SidebarView.swift:41-97) | WORKS | none |
| 5 | Logs tail local + remote (HermesLogService.swift) | WORKS | line regex matches `_LOG_FORMAT` hermes_logging.py:47 (`%(asctime)s %(levelname)s%(session_tag)s %(name)s: %(message)s`, session_tag " [sid]" :130); rotation handled via inode check |
| 6 | service_tier value mapping (HermesServiceTier.swift) | WORKS | aliases match hermes_cli/cli_config_load.py:72, agent/fast_mode.py:18 |
| 7 | Web backend roster (WebToolsBackendRoster.swift) | WORKS | names match tools/web_tools.py:184-196 + plugins/web/openai_native |

## Findings
None.

## File coverage
| File | Hermes touchpoints? | Status |
|---|---|---|
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesServiceTier.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesTool.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProcessTimeout.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GuardedSidecarStore.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesLogService.swift | yes | OK |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/LegacyKeychainRefMigrator.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/PhysicalPath.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProcessOutputInbox.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/TestModeFlags.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Services/WebToolsBackendRoster.swift | yes | OK |
| scarf/Packages/ScarfDesign/Package.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfDesign/Sources/ScarfDesign/ScarfChatView.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfDesign/Sources/ScarfDesign/ScarfComponents.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfDesign/Sources/ScarfDesign/ScarfLinkPolicy.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfDesign/Sources/ScarfDesign/ScarfPreview.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfDesign/Sources/ScarfDesign/ScarfTheme.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfDesign/Sources/ScarfDesign/ScarfTypography.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Core/Models/CatalogEntry.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Core/Services/Analytics.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Core/Services/AppRelauncher.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Core/Services/StatsScarfMonBackend.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Core/Services/UsageTracking.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Core/Utilities/MarkdownRenderer.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Common/LoadingOverlay.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Common/OutcomeMessage.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Common/OutcomeMessageBar.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Features/Common/StateReadErrorBanner.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Navigation/AppCoordinator.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Navigation/SidebarSectionCollapseStore.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Navigation/SidebarView.swift | yes | OK |
| scarf/scarf/Navigation/SplitViewAutosave.swift | no | NO-TOUCHPOINT |
| scarf/scarf/scarfApp.swift | yes | OK |
| scarf/Packages/ScarfCore/Package.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Diagnostics/ScarfAnalytics.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Diagnostics/ScarfMon.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Diagnostics/ScarfMonBoot.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Diagnostics/ScarfMonLoggerBackend.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Diagnostics/ScarfMonRingBuffer.swift | no | NO-TOUCHPOINT |
| scarf/Packages/ScarfCore/Sources/ScarfCore/Diagnostics/ScarfMonSignpostBackend.swift | no | NO-TOUCHPOINT |
| scarf/scarf/ContentView.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Core/SwiftUI/ResizableColumn.swift | no | NO-TOUCHPOINT |
| scarf/scarf/Core/SwiftUI/WindowFrameAutosave.swift | no | NO-TOUCHPOINT |

## Touchpoint inventory
| Touchpoint | Kind | Scarf | Hermes | Status |
|---|---|---|---|---|
| logs/agent.log line format | file parse | HermesLogService.swift:308 | hermes_logging.py:47,130 | OK |
| log rotation by rename | file | HermesLogService.swift:236-251 | hermes_logging.py:21-35,295 | OK |
| remote `tail -n N` / `tail -n 0 -F` (30s timeout on one-shot) | SSH argv (coreutils) | HermesLogService.swift:98,156 | n/a | OK |
| model.service_tier values | config value | HermesServiceTier.swift:40-64 | hermes_cli/cli_config_load.py:72; agent/fast_mode.py:18 | OK |
| web.backend/search_backend/extract_backend values | config value | WebToolsBackendRoster.swift:48-132 | tools/web_tools.py:159-196; plugins/web/openai_native/provider.py | OK |
| platform names for icons | display only | HermesTool.swift:248-284 | — | OK (cosmetic) |
| gateway start/stop/restart, pgrep, gateway_state.json | argv/file | scarfApp.swift:676-790 | delegated (HermesGatewayServiceVerdict / HermesFileService, gateway section) | OK (owned elsewhere) |
| ~/.hermes skills/slash-commands/.env/MCP bootstrap | files/config | scarfApp.swift:97-160 | delegated services | OK (owned elsewhere) |

## Not audited / couldn't verify
- Internals of SkillBootstrapService, SlashCommandBootstrapService, KeychainEnvMirror, ProjectsMCPRegistrar, HermesGatewayServiceVerdict, HermesFileService (other sections).
- iOS remote log streaming is a known stub (tracked t-78ced4d2 per HermesLogService.swift:94).
- Design package / diagnostics / analytics / window-autosave files read for Hermes contact only (none).
