# S13b-bots-peers-profiles — verdict: WORKS

No new source-proven defects on primary paths against Hermes v2026.9.24 (0.21.5). Every argv in the section was
checked with `--help` probes against the installed 0.21.5 binary, and the relevant handlers were read at the tag.

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Profiles list: `hermes profile list` → parse table (incl. `Display Name (id)`, `◆` marker); remote active profile from `<root>/active_profile` | WORKS | — |
| 2 | Create profile (`--clone` / `--clone-all` / `--no-skills` / `--` name) | WORKS | — |
| 3 | Switch: `profile use` (+ relaunch locally; remote = the server's active profile only) | WORKS | — |
| 4 | Rename / Delete (`-y`, exit-1 "settlement pending" treated as a completed delete) | WORKS | — |
| 5 | Export local (`--output` normalised to .tar.gz) / remote (scratch in /tmp, then stream to the Mac, then rm) | WORKS | — |
| 6 | Import local (NSOpenPanel) / remote (path on the host) | WORKS | — |
| 7 | HERMES_HOME resolution local (active_profile resolver) + remote (`HERMES_HOME=` for named profiles, `-p default` pin for the root) | WORKS | — |
| 8 | Bots roster (profiles/ scan + profile.yaml `ui_meta.hermes-bots`, avatars) + identity save (guarded merge) | WORKS | — |
| 9 | Bot lifecycle create/delete/rename via `hermes profile …` | WORKS | — |
| 10 | Bot agent config: `-p <bot> config set/unset`, `tools enable/disable --platform`, `tools list` | WORKS | — |
| 11 | Bot Chat CLI transport `-p <bot> chat --in ~ -c "Bot Chat" --create-if-missing -Q --query-file` + Stop (pkill INT→TERM→KILL) | WORKS | — |
| 12 | Bot routines (cron create with `deliver bot-chat:<bot>`) | WORKS (cron internals belong to the cron section) | — |
| 13 | Peers: registry from config.yaml `bot_peers`; `peer dm/run/status/stop --json` + parse | WORKS | — |
| 14 | Profile routes (config.yaml `profile_routes`, top-level or under `gateway:`) read/write | WORKS | — |
| 15 | iOS profile picker (`profile list` + root `active_profile`) | WORKS | — |

## Findings
None.

Checked and disproved:
- `hermes tools enable/disable` returns exit 0 for an unknown toolset or platform (`hermes_cli/tools_config_mcp.py:249-252,264-266`). Scarf does not rely on the exit code here: it judges the result with `toolsToggleVerdict` (`scarf/scarf/Features/Bots/ViewModels/BotAgentViewModel.swift:434,522`), so this is not a finding.
- `export_profile` strips `.tar.gz`/`.tgz` and then appends `.tar.gz` (`hermes_cli/profiles.py:2119-2140`). Scarf normalises the output path first (`HermesProfileArchive.normalizedOutputPath`), and the remote scratch path ends in `.tar.gz`, so the file Scarf reads is the file Hermes writes.
- `profile delete` without `-y` exits 0 when it hits EOF (`profiles.py:1692-1701`). Scarf always passes `-y`/`--yes` before `--`.
- When the identity purge is still pending, `profile delete` exits 1 even though the delete finished. Scarf matches Hermes' message (`profiles.py:1677-1679`) and reports a completed delete with a follow-up step.
- `profile_routes` gained `bot_profile` and `user_id` (`gateway/profile_routing.py:64-65,158-167`). Scarf keeps unmodelled keys verbatim in `extraLines` and also reads both of them.

## File coverage
| File | Hermes touchpoints? | Status |
|---|---|---|
| ScarfCore/Models/BotAgentConfig.swift | yes (config keys model.*, skills.disabled, platform_toolsets.*, mcp_servers.*) | OK |
| ScarfCore/Models/BotAvatarCache.swift | no (cache only) | NO-TOUCHPOINT |
| ScarfCore/Models/BotAvatarGenerator.swift | no | NO-TOUCHPOINT |
| ScarfCore/Models/BotAvatarView.swift | no | NO-TOUCHPOINT |
| ScarfCore/Models/BotChatSession.swift | yes (canonical title "Bot Chat") | OK |
| ScarfCore/Models/BotPresence.swift | no | NO-TOUCHPOINT |
| ScarfCore/Models/BotRoutinePrefix.swift | no (job-name prefix) | NO-TOUCHPOINT |
| ScarfCore/Models/HermesBotIdentity.swift | yes (profile.yaml fields) | OK |
| ScarfCore/Models/HermesBotPeer.swift | yes (bot_peers entry shape) | OK |
| ScarfCore/Models/HermesProfileList.swift | yes (`profile list` table) | OK |
| ScarfCore/Models/HermesProfileRoutes.swift | yes (profile_routes rule) | OK |
| ScarfCore/Models/HermesProfileScope.swift | yes (-p, HERMES_HOME, root derivation) | OK |
| ScarfCore/Models/IOSProfileSelection.swift | no (UserDefaults store) | NO-TOUCHPOINT |
| ScarfCore/Parsing/HermesBotPeersYAML.swift | yes (config.yaml bot_peers) | OK |
| ScarfCore/Parsing/HermesBotProfileYAML.swift | yes (profile.yaml display_name/description/description_auto/ui_meta.hermes-bots) | OK |
| ScarfCore/Parsing/HermesPeerCLI.swift | yes (peer dm/run/status/stop argv + JSON) | OK |
| ScarfCore/Parsing/HermesProfileArchive.swift | yes (archive extension rules) | OK |
| ScarfCore/Parsing/ProfileRoutesYAML.swift | yes (profile_routes YAML) | OK |
| ScarfCore/Services/BotAgentConfigService.swift | yes (config set/unset, tools enable/disable, SOUL.md) | OK |
| ScarfCore/Services/BotsRosterScan.swift | yes (batched remote scan of profiles/*/profile.yaml + assets) | OK |
| ScarfCore/Services/BotsService.swift | yes (profile create/delete/rename, profile.yaml write) | OK |
| ScarfCore/Services/HermesProfileDeleteVerdict.swift | yes (settlement-pending message) | OK |
| ScarfCore/Services/HermesProfileResolver.swift | yes (~/.hermes/active_profile) | OK |
| ScarfCore/Services/ProfileRoutesWriter.swift | yes (config.yaml profile_routes write) | OK |
| Scarf iOS/Profiles/ProfilesView.swift | yes (profile list, active_profile) | OK |
| Bots/ViewModels/BotAgentViewModel.swift | yes (tools list, verdicts) | OK |
| Bots/ViewModels/BotAvatarImport.swift | no | NO-TOUCHPOINT |
| Bots/ViewModels/BotConversationViewModel.swift | yes (chat -Q argv, pkill Stop, ACP path) | OK |
| Bots/ViewModels/BotRoutinesViewModel.swift | yes (cron create via CronViewModel, bot-chat:<bot>) | OK |
| Bots/ViewModels/BotsViewModel.swift | yes (lifecycle exit judging) | OK |
| Bots/Views/BotAgentView.swift | UI only | NO-TOUCHPOINT |
| Bots/Views/BotConversationView.swift | UI only | NO-TOUCHPOINT |
| Bots/Views/BotDetailView.swift | UI only | NO-TOUCHPOINT |
| Bots/Views/BotEditorSheet.swift | UI only | NO-TOUCHPOINT |
| Bots/Views/BotRoutinesView.swift | UI only | NO-TOUCHPOINT |
| Bots/Views/BotsView.swift | UI only (delete confirm copy) | NO-TOUCHPOINT |
| Bots/Views/RemoteBotDetailView.swift | UI only | NO-TOUCHPOINT |
| Peers/ViewModels/PeersViewModel.swift | yes (peer argv, timeouts 720/600/60) | OK |
| Peers/Views/PeersView.swift | UI only | NO-TOUCHPOINT |
| Profiles/RemoteProfileExport.swift | yes (profile export --output remote tmp) | OK |
| Profiles/ViewModels/ProfilesViewModel.swift | yes (profile list/show/use/create/rename/delete/export/import) | OK |
| Profiles/Views/ProfilesView.swift | UI (remote import path sheet) | OK |
| Profiles/WindowProfileScope.swift | no (selection store) | NO-TOUCHPOINT |
| Settings/Views/Components/ProfileRoutesSection.swift | yes via writer | OK |

## Touchpoint inventory
| Touchpoint | Kind | Scarf | Hermes @v2026.9.24 | Status |
|---|---|---|---|---|
| `profile list` | argv/parse | ProfilesViewModel.swift:56; HermesProfileList.swift:67 | hermes_cli/profile_cmd.py:108-127; profiles.py:906-910 | OK |
| `profile show -- <n>` | argv | ProfilesViewModel.swift:92 | profile_cmd.py:369 | OK |
| `profile use -- <n>` | argv | ProfilesViewModel.swift:110,143 | profile_cmd.py:151-158; profiles.py:1918-1931 | OK |
| `profile create [--clone|--clone-all] [--clone-from] [--no-skills] [--description] -- <n>` | argv | ProfilesViewModel.swift:189-199; BotsService.swift:352-365 | profile_cmd.py:188-210 (LIVE help) | OK |
| `profile rename -- a b` | argv | ProfilesViewModel.swift:209; BotsService.swift:376 | profile_cmd.py:433-441 | OK |
| `profile delete -y/--yes -- <n>` + pending-settlement exit 1 | argv/verdict | ProfilesViewModel.swift:231; BotsService.swift:372; HermesProfileDeleteVerdict.swift:38 | profiles.py:1682-1782 | OK |
| `profile export --output <p> -- <n>` | argv/path | ProfilesViewModel.swift:259; RemoteProfileExport.swift:44 | profile_cmd.py:474-482; profiles.py:2114-2140 | OK |
| `profile import -- <path>` | argv | ProfilesViewModel.swift:304 | profile_cmd.py:485-497 | OK |
| `<root>/active_profile` | file | HermesProfileResolver.swift:155; ProfilesViewModel.swift:411; iOS ProfilesView.swift:166 | profiles.py:187,1918-1931 | OK |
| `-p <name>` / `-p default` pin, `HERMES_HOME=<root>/profiles/<n>` | env/argv | HermesProfileScope.swift:172,220,298 | hermes_constants.py:217-234 | OK |
| profile.yaml identity + `ui_meta.hermes-bots` | file | HermesBotProfileYAML.swift; BotsService.swift:151 | profiles.py:811-860,564 | OK |
| `-p <bot> chat --in ~ -c "Bot Chat" --create-if-missing -Q --query-file` | argv | BotConversationViewModel.swift:687-697 | tools/bot_relay.py:87,518; cli_single_query.py:145-177 | OK |
| Stop: `pkill -INT/-TERM/-KILL -f` on the query-file path | process | BotConversationViewModel.swift:460-516 | cli_single_query.py:365-416 | OK |
| `-p <bot> config set/unset -- key` | argv | BotAgentConfigService.swift:287-317 | `hermes config --help` (LIVE) | OK |
| `-p <bot> tools enable/disable <ts> --platform <p>`, `tools list --platform` | argv/verdict | BotAgentConfigService.swift:341; BotAgentViewModel.swift:42,434 | tools_config_mcp.py:241-290 | OK |
| cron `deliver bot-chat:<bot>` | value | BotRoutinesViewModel.swift:186 | cron/scheduler_delivery.py:1009-1010 | OK |
| config.yaml `bot_peers` | config key | HermesBotPeersYAML.swift:33 | subcommands/peer.py:36-41 | OK |
| `peer dm --json -- t m`, `peer run [--idempotency-key] --json -- t m`, `peer status/stop t id --json` | argv/JSON | HermesPeerCLI.swift:67-108,360-420 | subcommands/peer.py:205-222,280-409,441-474 | OK |
| config.yaml `profile_routes` (top level / `gateway:`) | config key | ProfileRoutesYAML.swift; ProfileRoutesWriter.swift | gateway/profile_routing.py:132-170; gateway/config_loader.py:93 | OK |

## Not audited / couldn't verify
- Cron job creation mechanics (CronViewModel), ACP Bot Chat path internals, and HermesFileService.runHermesCLI transport are owned by other sections. They were only followed here as far as the argv hand-off.
- The large SwiftUI view files were checked for Hermes touchpoints with targeted grep plus reading their action wiring. Their layout and copy were not reviewed line by line.
- Nothing was confirmed live beyond `--help` probes. No mutating commands were run.
