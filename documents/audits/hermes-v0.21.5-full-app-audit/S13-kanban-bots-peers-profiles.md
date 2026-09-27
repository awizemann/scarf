# S13-kanban-bots-peers-profiles — verdict: WORKS-WITH-ISSUES

Hermes reference: `~/.hermes/hermes-agent-v0215` @ `v2026.9.24` (0.21.5). Scarf paths are relative to `/Users/awizemann/Developer/Scarf/scarf/`.

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Profiles, local: list, show, create/clone, rename, use, Switch & Relaunch, delete (incl. v0.21.4 settlement-pending), export, import | WORKS | F6 (P3: a failed list shows as empty) |
| 2 | Profiles, remote (SSH) Mac window: list, "View this profile", "Set as server's active profile", export streams to the Mac, import from a host path | DEGRADED | F3, F1 |
| 3 | HERMES_HOME resolution: local `active_profile` resolver, remote per-window scope, `pinnedToProfile` | DEGRADED (remote default view) | F1 |
| 4 | Bots: roster scan, create/rename/delete bot, identity (`profile.yaml`) edit, promote/demote | WORKS | — |
| 5 | Bot agent config: model pin, clear pin, toolset toggle, MCP toggle, SOUL.md | WORKS | — |
| 6 | Bot conversation: locate Bot Chat, ACP resume, CLI-transport create/send | BROKEN for the `default` bot | F2 |
| 7 | Bot routines: filtered cron list, create routine with `bot-chat:<name>` delivery and delegation prompt | WORKS | — |
| 8 | Peers: registry read from `bot_peers`, `peer dm`, `peer run`/`status`/`stop` | WORKS | — |
| 9 | Kanban board: list, show, runs, log, stats, assignees, create, assign, comment, complete, block, unblock, schedule, promote, reopen-review, archive, purge, dispatch, drag-move plans | WORKS | — |
| 10 | Kanban toolset detect and enable (banner "Enable now") | DEGRADED | F5 |
| 11 | Profile routes (Settings > Agent): read `profile_routes` and multiplex, write routes | WORKS | — |
| 12 | iOS (ScarfGo) profile picker | DEGRADED | F4 |

## Findings

### S13-F1 · P1 · SOURCE · NEW
- Claim: In a remote Mac window (and in ScarfGo) viewing the **default** profile, Scarf reads files from the root `~/.hermes`, but every hermes subprocess (ACP chat, cron, `config set`, kanban, and so on) runs in whatever named profile the host's sticky `active_profile` names. So when the host's active profile is not `default`, reads and writes go to two different profiles.
- Scarf: `Packages/ScarfCore/Sources/ScarfCore/Models/HermesProfileScope.swift:161-164` (`hermesHomeShellAssignment` returns `""` for a root home); `Packages/ScarfCore/Sources/ScarfCore/Transport/SSHTransport.swift:658-668` (`composedRemoteCommand`); `Packages/ScarfIOS/Sources/ScarfIOS/CitadelServerTransport.swift:814`; `Packages/ScarfCore/Sources/ScarfCore/Models/ServerContext.swift:298-310` (`scoped(toProfile:)` sends nil/default to the root home); `scarf/Features/Profiles/WindowProfileScope.swift` (the selection defaults to nil, which means default).
- Hermes @v2026.9.24: `hermes_cli/main.py:593-621`. With no `-p` flag and no profile-shaped `HERMES_HOME`, `_apply_profile_override` reads `<root>/active_profile` and re-homes the process to that profile. `hermes_cli/profiles.py:2366-2369` shows `-p default` resolves to the root and overrides the sticky file.
- Failure scenario: the host runs `hermes profile use coder`, or the user clicks Scarf's own "Set as server's active profile" on `coder` while the window is still viewing default. The Sessions, Cron and Memory panes show `~/.hermes` data. A new chat (`hermes acp`), a cron create or a `config set` from that window lands in `~/.hermes/profiles/coder/`. The new chat never shows up in the window's Sessions list, and Settings edits apply to a profile the window isn't showing.
- Evidence: the transport comment says "It's empty for a default/root home, so legacy active_profile behavior is preserved". The memory decision `decision-scarfgo-profile-switching-via-per-connection.md:21` names "`-p default` defeats a non-default host active_profile for the default case", but no code path emits it.
- Suggested fix: for a root-home remote context, pin the process layer as well, either with `HERMES_HOME=<root>` (Hermes ignores that for a root path, `main.py:604`) or with `-p default` on hermes argv.
- Overlap: the transport itself belongs to S15. It's reported here because the Profiles journey creates this state directly.

### S13-F2 · P1 · SOURCE · NEW
- Claim: The `default` profile's bot can never start a conversation or send over the CLI transport. `createCanonicalBotChat` validates the name with `HermesProfileScope.normalize`, which returns nil for `"default"`, so it returns the error "“default” isn’t a valid Hermes profile name." Separately, the ACP path launches the default bot unpinned (`acpArguments` emits no `-p` for default), so it follows the sticky `active_profile` instead of the root home its reads are pinned to.
- Scarf: `scarf/Features/Bots/ViewModels/BotConversationViewModel.swift:495-500` (normalize guard), `:537-547` (argv); `:417-418` and `:423-447` (the first send goes through `createThenConnect` to `creator`); `deliverViaCLI` (~`:290`) uses the same creator for every send on a CLI-born Bot Chat; `scarf/Core/Services/ACPClient+Mac.swift:56-62` (the comment claims "`-p default` is a no-op", which is false). The default bot is reachable: `BotsViewModel.swift:1018` `promote` via "Make a Bot" on the default row (`BotsView.swift:497`), then `openConversation` (`BotsViewModel.swift:636`) accepts `default` via `isAddressableProfile`.
- Hermes @v2026.9.24: `tools/bot_mode_dm.py:168-176` maps `hermes` to the `default` folder id, and `:282` spawns `[hermes, "-p", resolved, …BOT_CHAT_TURN_ARGS]`, so Hermes itself uses `-p default`. `hermes_cli/profiles.py:2368` shows `-p default` resolves to the root. `hermes_cli/main.py:615-621` shows that without `-p`, the sticky profile is used.
- Failure scenario: the user promotes the default profile to a bot (or Hermes Desktop already manages it as the "hermes" bot), opens it and types a message. The conversation goes straight to `.failed("“default” isn’t a valid Hermes profile name.")`. On a Bot Chat that already exists and was not born over ACP, every send fails the same way. If the Bot Chat was born over ACP and the local or host active profile is not default, `hermes acp` runs as the other profile and `session/load` misses.
- Suggested fix: in `createCanonicalBotChat` and `acpArguments`, send `default` as `-p default` rather than dropping it. `BotAgentConfigService.profileFlag` already does this.

### S13-F3 · P2 · SOURCE · NEW
- Claim: In a remote Mac window viewing a named profile, the Profiles list marks the **viewed** profile as "active", not the server's real active profile. The context-menu item "Set as server's active profile" is therefore disabled for exactly the profile being viewed, and the real server-active profile shows no badge.
- Scarf: `scarf/Features/Profiles/ViewModels/ProfilesViewModel.swift:42-55` and `:380-386` (`isActive` comes from the `◆` marker); `scarf/Features/Profiles/Views/ProfilesView.swift:212-216` (`.disabled(profile.isActive)`) and `:324-333` (subtitle). The view model runs on the window's scoped context (`ProfilesView.swift:28`, `scarfApp.swift:448`), so `SSHTransport` prefixes `HERMES_HOME=<root>/profiles/<viewed>`.
- Hermes @v2026.9.24: `hermes_cli/profile_cmd.py:110-118` puts the marker on `_is_active(p, get_active_profile_name())`. `hermes_cli/profiles.py:1941-1955` derives `get_active_profile_name` from `HERMES_HOME`, not from the sticky `active_profile` file, and `main.py:603-605` keeps a profile-shaped `HERMES_HOME`.
- Failure scenario: the server's active profile is `default` and the window is viewing `work`. `work` is listed as active and its "Set as server's active profile" is greyed out. `default`'s subtitle reads "Not viewing" rather than "Server's active profile". The user can't promote the viewed profile from this menu and sees the wrong server state. ScarfGo avoids this by reading `active_profile` directly (`Scarf iOS/Profiles/ProfilesView.swift:167`).
- Suggested fix: on remote, work out `isActive` from `<root>/active_profile` the way iOS does, or run `profile list` with `HERMES_HOME=<root>`.

### S13-F4 · P2 · SOURCE · NEW
- Claim: ScarfGo's profile-list parser takes the first whitespace token of each row. Since 0.20.5, Hermes renders a profile with a display name as `Display Name (id)`, so those profiles are dropped (uppercase first word) or listed under a wrong id (lowercase first word). Every bot Scarf saves gets a display name.
- Scarf: `Scarf iOS/Profiles/ProfilesView.swift:204-232` (`parse`: "first whitespace-delimited token is the name"). Display names are written by `scarf/Features/Bots/ViewModels/BotsViewModel.swift:258` (`identity.displayName = trimmedTitle`) through `HermesBotProfileYAML.write`. The Mac parser handles this correctly (`ProfilesViewModel.swift:359-404`).
- Hermes @v2026.9.24: `hermes_cli/profile_cmd.py:119,124` (`format_profile_label`); `hermes_cli/profiles.py:906-910` (`f"{dn} ({name})"`).
- Failure scenario: a bot created in Scarf titled "Research Bot" (id `research`) never appears in ScarfGo's picker. One titled "helper" with id `research` appears as `helper`, and selecting it points ScarfGo at the nonexistent `profiles/helper`. Also, a non-zero `profile list` (for example `hermes: not found`) is parsed as an empty list with no error (`:145-160`, `:170-180`), which shows the "No named profiles yet" footer.
- Suggested fix: reuse the Mac `parseProfileList` (move it to ScarfCore), and check the exit code.

### S13-F5 · P2 · SOURCE · NEW
- Claim: Kanban "Enable now" refuses on any config with no `platform_toolsets.cli` list. That covers a fresh `hermes profile create` profile (including bots Scarf creates without cloning) and any install that never ran the tools or setup wizard. Hermes's own `hermes tools enable kanban --platform cli` handles that shape. The refusal text also always names `~/.hermes/config.yaml`, even for a named profile. Secondarily, the detector reports "enabled" from a legacy top-level `toolsets: [kanban]` even when an explicit `platform_toolsets.cli` list exists, but Hermes honours the top-level entry only when there is no explicit list.
- Scarf: `Packages/ScarfCore/Sources/ScarfCore/Services/KanbanToolsetEnabler.swift` `planEnable` (refuses with "`platform_toolsets:` section not found" or "key not found"); `KanbanToolsetDetector.swift` `detect` (top-level short-circuit); callers `scarf/Features/Kanban/Views/KanbanBoardView.swift:627-641`, `scarf/Features/Chat/ViewModels/ChatViewModel.swift:2996`.
- Hermes @v2026.9.24: `hermes_cli/tools_config.py:97` (`kanban` is default-off); `:580-584` (an absent list falls back to the platform default composite); `:619-620` (top-level `toolsets` kanban only when `not explicitly_configured`); `hermes_cli/tools_config_mcp.py:241-300` (`tools enable` builds or saves the list); `hermes_cli/tools_config.py:710,725` (the save path creates `platform_toolsets`).
- Failure scenario: the user opens Kanban on a freshly created profile and clicks "Enable now". The notice reads "Couldn't enable: `platform_toolsets:` section not found … Open ~/.hermes/config.yaml …". The failure is honest but blocks the user, and it points at the wrong file for a named profile.
- Suggested fix: when the list is absent, fall back to `hermes tools enable kanban --platform cli` (already judged by `HermesToolsToggle`), and name `context.paths.configYAML` in the message.

### S13-F6 · P3 · SOURCE · NEW
- Claim: Mac `ProfilesViewModel.load()` ignores `profile list`'s exit code. A failed spawn (SSH down, binary missing, exit -1) is parsed as zero profiles and shows "No Profiles — Create a profile…" instead of an error.
- Scarf: `scarf/Features/Profiles/ViewModels/ProfilesViewModel.swift:42-55`; overlay `scarf/Features/Profiles/Views/ProfilesView.swift` ("No Profiles" `ContentUnavailableView`).
- Hermes @v2026.9.24: `hermes_cli/profile_cmd.py:103-127` (a success always prints the header plus at least the default row, so empty output is never a legitimate success).
- Suggested fix: on a non-zero exit, set `message = failureMessage(output)` and keep the previous list.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `profile list` (parse `◆`, display-name label) | argv/output | ProfilesViewModel.swift:46,362-415 | subcommands/profile.py:14; profile_cmd.py:103-127 | OK (local) / FINDING-F3 (remote marker) / FINDING-F6 |
| `profile show -- <n>` | argv | ProfilesViewModel.swift:61 | profile.py:76-77; profile_cmd.py:411-440 | OK |
| `profile use -- <n>` | argv | ProfilesViewModel.swift:79,106 | profile.py:15-16; profile_cmd.py:150-157 (_die rc1) | OK |
| `profile create [--clone|--clone-all] [--no-skills] -- <n>` | argv | ProfilesViewModel.swift:151-164 | profile.py:18-50; profile_cmd.py:185-192 | OK |
| `profile rename -- <old> <new>` | argv | ProfilesViewModel.swift:172; BotsService.swift Lifecycle.rename | profile.py:86-91; profile_cmd.py:471-479 | OK |
| `profile delete -y/--yes -- <n>` + settlement-pending verdict | argv/output | ProfilesViewModel.swift:193-199; BotsService Lifecycle.delete; HermesProfileDeleteVerdict.swift:28-43; BotsViewModel.swift:1224-1250 | profile.py:52-54; profiles.py:1663-1780; profile_cmd.py:318-323 | OK |
| `profile export --output <p> -- <n>` (local + remote /tmp + stream) | argv/file | ProfilesViewModel.swift:217-256; RemoteProfileExport.swift; HermesProfileArchive.swift:47-62 | profile.py:115-120; profiles.py:2114-2139 | OK |
| `profile import -- <path>` | argv | ProfilesViewModel.swift:258-260 | profile.py:122-126; profiles.py:2142- | OK |
| `profile create … --clone-from X --description D -- <n>` (bots) | argv | BotsService.swift Lifecycle.create | profile.py:28-29,46-50 | OK |
| `~/.hermes/active_profile` read (local resolver) | file | HermesProfileResolver.swift:155-201 | profiles.py:1908-1916; main.py:615-621 | OK |
| `<root>/profiles/<name>` layout, name regex | path | HermesProfileScope.swift; BotsService.swift | profiles.py:174-176,306-318; PROFILE_ID_RE | OK |
| Remote `HERMES_HOME=` prefix for named profile | env | HermesProfileScope.swift:161; SSHTransport.swift:658 | main.py:603-605 | OK |
| Remote root/default view, no process pin | env | same | main.py:615-621 | FINDING-F1 |
| iOS `profile list` + `active_profile` read | argv/file | Scarf iOS/Profiles/ProfilesView.swift:128-232 | profile_cmd.py:103-127; profiles.py:906-910 | FINDING-F4 |
| `profile.yaml` display_name/description/description_auto/ui_meta.hermes-bots | file (YAML) | HermesBotProfileYAML.swift; BotsService.saveIdentity | profiles.py:811-880 | OK |
| roster scan `<root>/profiles/*`, `assets/avatar.*` | file | BotsService.swift scan/avatarPath; BotAvatarCache.swift | profiles.py:174 | OK |
| `-p <bot> config set/unset model.default|model.provider|mcp_servers.<s>.enabled` | argv | BotAgentConfigService.swift setModelPin/clearModelPin/setMCPServerEnabled; BotAgentViewModel.swift:420-436 judges | tools/mcp_tool_common.py:144 (`enabled`) | OK |
| `-p <bot> tools enable|disable <ts> --platform <p>` | argv | BotAgentConfigService.setToolsetEnabled; HermesToolsToggle judge | subcommands/tools.py:25-36; tools_config_mcp.py:241-300 (exit-0 failures judged by output) | OK |
| bot `config.yaml` read (model, skills.disabled, platform_toolsets, mcp_servers) | file | BotAgentConfigService.parseAgentConfig | config keys | OK |
| bot `SOUL.md` read/write | file | BotAgentConfigService.readSoul/writeSoul | — | OK |
| `hermes -p <bot> chat --in ~ -c "Bot Chat" --create-if-missing -Q --query-file` | argv | BotConversationViewModel.swift:495-556 | _parser.py:165,170,218,245,260; tools/bot_mode_dm.py:11,282 | OK (named) / FINDING-F2 (default) |
| `hermes [-p <bot>] acp` | argv | ACPClient+Mac.swift:59-62 | main.py:593-621 | FINDING-F2 (default) |
| state.db Bot Chat locate (read-only) | SQL | BotConversationViewModel.swift:170-176 → HermesDataService | — | UNVERIFIABLE here (S04 owns SQL) |
| bot routine cron create, `deliver bot-chat:<name>`, delegation prompt | argv | BotRoutinesViewModel.swift; BotRoutinePrefix.swift:102-142 | cron/scheduler_delivery.py:1009-1040 | OK (cron argv owned by S08) |
| `bot_peers.<name>.{url,note}` read | file (YAML) | HermesBotPeersYAML.swift | subcommands/peer.py:35-48,212-229 | OK |
| `peer dm --json -- <target> <msg>` | argv/JSON | HermesPeerCLI.swift dmArgs/parseDM; PeersViewModel.swift:160-185 | peer.py:342-373,395-417,460-469 | OK (exit 1 still-running path handled) |
| `peer run [--idempotency-key K] --json -- <target> <msg>` | argv/JSON | HermesPeerCLI.runArgs/parseRun | peer.py:311-339 | OK |
| `peer status|stop <target> <run_id> --json` | argv/JSON | HermesPeerCLI.statusArgs/stopArgs/parseRunStatus; PeersViewModel.swift:342-352 | peer.py:282-300 | OK |
| `kanban [--board=B] list --json [--mine --status= --assignee= --tenant= --session= --archived --sort=]` | argv/JSON | KanbanService.list; KanbanFilters.swift:51-75; HermesKanbanTask.swift:188-259 | kanban_parser.py (list); kanban.py:418-446; kanban_output.py:18-24,85-88 | OK |
| `kanban show <id> --json` | argv/JSON | KanbanService.show; HermesKanbanTaskDetail.swift | kanban.py:473-501 | OK |
| `kanban runs <id> --json`, `stats --json`, `diagnostics --json [--task=]` | argv/JSON | KanbanService.runs/stats/diagnostics | kanban_parser.py; kanban.py:628-703,1136-1151,1217-1241 | OK |
| `kanban log [--tail=N] <id>` | argv | KanbanService.log | kanban.py:1207-1214 (rc1 "no log") | OK |
| `kanban assignees --json` → {name,on_disk,counts} | argv/JSON | KanbanService.assignees; HermesKanbanAssignee.swift | kanban.py:319-331; kanban_db.py:4381-4388 | OK |
| `kanban create [--body= --assignee= --parent= --workspace= --tenant= --priority= --triage --idempotency-key= --max-runtime=Ns --max-retries= --completion-contract= --created-by= --skill=] --json -- <title>` | argv/JSON | KanbanCreateRequest.swift argv; KanbanService.create | kanban_parser.py (create); kanban.py:334-391 | OK |
| `kanban assign <id> <profile|none>` | argv | KanbanService.assign | kanban.py:572-577 (rc1 on unknown id) | OK |
| `kanban comment [--author=] -- <id> <text>` | argv | KanbanService.comment | kanban.py:749-761 | OK |
| `kanban complete [--result= --summary= --metadata=] -- <ids>` | argv | KanbanService.completeArgv | kanban.py:894-943; kanban_output.py:61-71 | OK |
| `kanban block -- <id> [reason]` / `unblock -- <ids>` / `schedule [--ids …] -- <id> [reason]` | argv | KanbanService.block/unblock/scheduleArgv | kanban.py:981-1031 | OK |
| `kanban promote --json [--ids …] -- <id> [reason]` (`--force` only on dead path, force always false) | argv | KanbanService.promoteArgv; KanbanBoardViewModel.swift:419 | kanban_parser.py (promote: no --force); kanban.py:1090-1118 | OK |
| `kanban reopen-review [--reason=] -- <ids>` | argv | KanbanService.reopenReviewArgv | kanban.py:1069-1087 | OK |
| `kanban archive -- <ids>` / `archive --rm <ids>` | argv | KanbanService.archiveArgv/purge | kanban.py:1121-1133 | OK |
| `kanban dispatch --json [--dry-run] [--max=]` | argv/JSON | KanbanService.dispatch; KanbanFilters.swift:78-131 (result discarded by callers) | kanban_ops.py:60-110 | OK |
| kanban exit-code honesty (main propagates handler rc) | exit | KanbanService.ensureSuccess | main.py:3614-3617; kanban.py:138-198 | OK |
| `platform_toolsets.<p>` / top-level `toolsets` kanban detect + direct YAML write | config | KanbanToolsetDetector.swift; KanbanToolsetEnabler.swift | tools_config.py:97,578-620,710-725 | FINDING-F5 |
| `profile_routes` (top-level or `gateway.`) read/write, fields name/platform/profile/guild_id/chat_id/thread_id/enabled (+ extras preserved) | config | ProfileRoutesYAML.swift; ProfileRoutesWriter.swift; HermesProfileRoutes.swift; SettingsViewModel.swift:1205-1224 | gateway/config_loader.py:93,108-126; gateway/profile_routing.py:133-173 | OK (UI specificity ignores `user_id`: cosmetic, rare) |
| `multiplex_profiles` / `gateway.standalone` read | config | HermesProfileRoutes.swift; ProfileRoutesSection.swift | gateway/config.py | OK |
| KanbanError, HermesBotPeer, BotChatSession models | model | — | — | OK (no direct Hermes I/O) |

## Not audited / couldn't verify
- The SQL in `HermesDataService.locateCanonicalBotChat` (Bot Chat lookup) and the ACP session/load binding check belong to S04/S01; they were not re-traced here.
- `BotsRosterScan` batched shell script (the remote roster fast path) was not line-audited; the per-file fallback was.
- CronViewModel argv for bot routines is owned by S08; only the routine-specific fields were checked.
- ProfileRoutesYAML's hand parser was not fuzzed. Only the key set and location precedence were checked against Hermes.
- Nothing was run beyond `hermes --version`, `hermes profile delete --help` and `hermes kanban promote --help`, which confirmed the `-y` flag and that `promote` has no `--force`.
