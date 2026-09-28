# S13-kanban-bots-peers-profiles — verdict: WORKS-WITH-ISSUES

Hermes reference: `~/.hermes/hermes-agent-v0215` @ `v2026.9.24` (0.21.5). Installed binary confirmed:
`hermes --version` → `Hermes Agent v0.21.5 (2026.9.24)`.

Profiles, peers, bots and the kanban write verbs are sound: every argv matches the tagged argparse, and the
exit-0 paths are handled. The defects are all on the Kanban read and onboarding side: two JSON decode mismatches,
completion copy that invites a refusal, and a toolset check aimed at the wrong platform.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Profiles: list and parse table, active badge (local and remote) | WORKS | — |
| 2 | Profiles: create / clone / `--no-skills` | WORKS | — |
| 3 | Profiles: switch (`use`) plus relaunch; resolver `active_profile` | WORKS | — |
| 4 | Profiles: delete (`-y`, settlement-pending exit 1) / rename / show | WORKS | F7 (bot rename of default only) |
| 5 | Profiles: export (local and remote stream-down) / import | WORKS | F6 (local `.tgz` name only) |
| 6 | Profile routes: read, rank, write `profile_routes` | DEGRADED | F5 |
| 7 | Kanban: list / create / assign / block / unblock / promote / schedule / archive / purge / dispatch | WORKS | — |
| 8 | Kanban: task inspector (show → comments/events, runs, log, diagnostics) | BROKEN (comments) | F1 |
| 9 | Kanban: glance stats (board toolbar, project widget, ScarfGo) | BROKEN when any task is assigned | F2 |
| 10 | Kanban: drag or action to Done (complete) | DEGRADED | F3 |
| 11 | Kanban: toolset detect / enable (board banner and chat onboarding) | DEGRADED | F4 |
| 12 | Bots: roster scan (per-file and batched), identity write to `profile.yaml`, avatar | WORKS | — |
| 13 | Bots: create / rename / delete (`hermes profile …`) | WORKS | F7 |
| 14 | Bots: agent config (model pin, `tools enable/disable`, MCP enabled, SOUL.md) | WORKS | — |
| 15 | Bots: conversation (ACP-born vs CLI `chat --in ~ -c "Bot Chat" --create-if-missing -Q --query-file`) | WORKS | — |
| 16 | Bots: routines (`cron create … --deliver bot-chat:<bot>`) | WORKS (cron internals are S08) | — |
| 17 | Peers: list (`bot_peers` YAML), `peer dm` / `run` / `status` / `stop` | WORKS | — |
| 18 | ScarfGo: profiles picker; kanban detail sheet | WORKS / BROKEN (comments, same as F1) | F1 |

## Findings

### S13-F1 · P1 · SOURCE · NEW
- **Claim:** Kanban task comments never render. Every `kanban show --json` comment fails to decode, and the error is swallowed, so the Comments tab always reads "No comments yet." This includes right after the user posts one.
- **Scarf:**
  - `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesKanbanComment.swift:37` has `self.id = try c.decode(Int.self, forKey: .id)`, so `id` is required.
  - `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesKanbanTaskDetail.swift` (`init(from:)`) runs `self.comments = (try? container.decodeIfPresent([HermesKanbanComment].self, …)) ?? []`, which turns the failure into `[]`.
  - The empty list is rendered at `scarf/scarf/Features/Kanban/Views/KanbanInspectorPane.swift:537-546` and `scarf/Scarf iOS/Kanban/ScarfGoKanbanDetailSheet.swift:175-182`.
- **Hermes @v2026.9.24:** `hermes_cli/kanban.py:492-498` (`_cmd_show` JSON) emits `"comments": [_obj_dict(c, ("author", "body", "created_at")) …]` and `"events": [_obj_dict(e, ("kind", "payload", "created_at", "run_id")) …]`. Neither carries an `id`, although `Comment` and `Event` have one (`hermes_cli/kanban_db.py:811-816`, `:849-855`).
- **Failure scenario:** A worker or the user comments on a task (`kanban comment` exits 0, Scarf clears the draft). The inspector re-fetches `show --json`. The comments array fails to decode as a whole, and the pane shows "No comments yet." on both Mac and ScarfGo. Collaboration comments, including the BLOCKED/UNBLOCK notes Hermes appends, are invisible everywhere in Scarf.
- **Secondary effect:** `HermesKanbanEvent` defaults a missing `id` to 0 (`HermesKanbanEvent.swift` `init(from:)`). Every event therefore shares id 0, and the events tab runs `ForEach(events)` with duplicate identities (`KanbanInspectorPane.swift:599`, `ScarfGoKanbanDetailSheet.swift:211`), which is undefined SwiftUI identity behaviour.
- **Evidence:** No test fixture contains a non-empty `comments` array (`KanbanModelsTests.swift:588` and `HermesP18RemediationTests.swift:203` use `"comments": []`).
- **Suggested fix:** Make `id` optional or synthesize it from index plus `created_at` for comments and events, and stop `try?`-swallowing the array.

### S13-F2 · P2 · SOURCE · NEW
- **Claim:** `kanban stats --json` fails to decode whenever any non-archived task has an assignee. The glance string ("3 todo · 1 running …") therefore disappears or goes stale on the board toolbar, the project Kanban widget and ScarfGo.
- **Scarf:**
  - `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesKanbanStats.swift:8`, `:38` decode `byAssignee` as `[String: Int]`.
  - Every caller uses `try?`: `KanbanBoardViewModel.swift:227` (keeps the stale value), `Features/Projects/Views/Widgets/KanbanSummaryWidgetView.swift:185` (`.empty`), `Scarf iOS/Kanban/ScarfGoKanbanView.swift:223` (`.empty`).
- **Hermes @v2026.9.24:**
  - `hermes_cli/kanban_db.py:4217-4222` returns `"by_assignee": by_assignee`, built by `_counts_by_assignee` (`:4225-4234`) as `dict[str, dict[str, int]]` (`{assignee: {status: n}}`).
  - `hermes_cli/kanban.py:1136-1140` dumps it as-is.
- **Failure scenario:** Normal kanban use assigns tasks to profiles. From the first assigned task onward, `stats()` throws `KanbanError.decoding`. The widget and ScarfGo show no glance at all, and the Mac toolbar keeps whatever it last decoded.
- **Suggested fix:** Decode `by_assignee` as `[String: [String: Int]]`, or skip it with `decodeIfPresent` inside a `try?` per key.

### S13-F3 · P2 · SOURCE · NEW
- **Claim:** The Complete sheet tells the user the result is optional ("Leave blank for a quiet completion"). Hermes 0.21.5 refuses an evidence-less completion from any non-review status, so the common drag to Done fails with an error banner.
- **Scarf:**
  - `scarf/scarf/Features/Kanban/Views/KanbanCompleteResultSheet.swift:30` (field labelled "Result summary (optional)") and `:33` ("Leave blank for a quiet completion.").
  - `KanbanService.plan` marks every complete step `resultRequired: false` (`KanbanService.swift`, the `(.upNext, .done)` / `(.running, .done)` / `(.blocked, .done)` / `(.scheduled, .done)` arms).
  - `KanbanBoardViewModel.swift:683-692` passes `result: nil`.
- **Hermes @v2026.9.24:**
  - `hermes_cli/kanban_db.py:2860-2891` (`_gate_empty_completion`) raises `EmptyCompletionError` unless the status is `review` or there is a substantive result, summary or stored result.
  - `hermes_cli/kanban.py:932-935` turns that into "cannot complete X: completion blocked … Pass --result/--summary …" and exit 1 through `_bulk_apply`.
- **Failure scenario:** The user drags a Running or Up Next card to Done and leaves the field blank as the sheet suggests. The card snaps back and an error appears. For Blocked or Scheduled → Done the plan is `[.unblock, .complete]`, so the unblock lands and the task is left in ready/todo. That is a partial move to a column the user did not choose.
- **Suggested fix:** Make the result required (`resultRequired: true`) for non-review sources and update the copy. Review → Done stays exempt.

### S13-F4 · P2 · SOURCE · NEW
- **Claim:** The Kanban toolset check and "Enable now" act on `platform_toolsets.cli`, but Scarf's chat runs over ACP, and Hermes resolves ACP toolsets from `platform_toolsets.acp` (else `hermes-acp`, which excludes kanban).
- **Scarf:**
  - `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/KanbanToolsetDetector.swift:70-71` says the default `cli` is "the platform Hermes uses for ACP chats", and `:76` is `detect(platform: String = "cli")`.
  - `KanbanToolsetEnabler.swift:76` is `enable(platform: String = "cli")`.
  - Callers: `scarf/scarf/Features/Kanban/Views/KanbanBoardView.swift:589-599` (banner: "Agents in chat can't create Kanban tasks") and `:620-640`, plus `scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift:3391`, `:3409`.
- **Hermes @v2026.9.24:**
  - `acp_adapter/session.py:480-489` computes `_get_platform_tools(config, "acp")` and runs with `"platform": "acp"`.
  - `hermes_cli/tools_config.py:576-586`: no `platform_toolsets.acp` → `_platform_default_toolset("acp")` = `hermes-acp`.
  - `toolsets.py:202-205` defines `hermes-acp` = `_CODING_TOOLS`, which is `_core_without(..., kanban=False)` at `:70`, so it has no `kanban_*` tools.
  - Schema selection is scoped per enabled toolset list (`model_tools.py:505-513`), and `tools/kanban_tools.py:37-61` does not borrow another platform's opt-in ("Never borrow another platform's opt-in during schema assembly").
- **Failure scenario:** The user clicks "Enable now". Scarf writes `kanban` under `platform_toolsets.cli` and toasts "Kanban tools enabled. Start a new chat to pick this up." The new Scarf (ACP) chat still has zero kanban tools. The detector also reports `.enabled` for a config with only `cli: [kanban]` or top-level `toolsets: [kanban]`, so the banner hides while the ACP chat still lacks the tools.
- **Suggested fix:** Detect and enable against `acp` for the chat surfaces (optionally also `cli`), and fix the doc comment.

### S13-F5 · P3 · SOURCE · NEW
- **Claim:** The Profile Routing editor's ranking and explainer omit Hermes' `user_id` (+16) discriminator and `bot_profile` scoping. Any rule carrying them is shown at the wrong rank, with a misleading scope and acceptance state.
- **Scarf:**
  - `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesProfileRoutes.swift:86-92` (`specificity`: guild 2, chat 4, thread 8 only), `:100-103` (`isAcceptedByHermes`) and the `effectiveOrder` property.
  - Explainer copy at `scarf/scarf/Features/Settings/Views/Components/ProfileRoutesSection.swift:181` ("thread + 8, channel + 4, server + 2").
  - `user_id` and `bot_profile` survive only as `extraLines`.
- **Hermes @v2026.9.24:**
  - `gateway/profile_routing.py:65-70` (specificity includes `16 * bool(user_id)`).
  - `:86-88` (the route applies only to the bot of its `bot_profile`, default = the default profile's bot).
  - `:140-143` (a rule with null or empty `user_id` is skipped).
- **Failure scenario:** A hand-authored `user_id` route (documented in `website/docs/user-guide/multi-profile-gateways.md:779-796`) is ranked below location rules it actually outranks. It is summarised as "any server/channel" and shown as accepted even with an empty `user_id` that Hermes drops. Scarf's own writes are unaffected: `extraLines` round-trip verbatim.

### S13-F6 · P3 · SOURCE · NEW
- **Claim:** A local profile export to a path the user names `*.tgz` reports "Exported", but the file lands at `*.tar.gz`.
- **Scarf:** `scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesProfileArchive.swift:36-48` (`isRecognized` accepts `.tgz` and returns it unchanged). `scarf/scarf/Features/Profiles/ViewModels/ProfilesViewModel.swift:255-257` then shows the bare "Exported".
- **Hermes @v2026.9.24:** `hermes_cli/profiles.py:2120` strips `.tar.gz` and `.tgz` from the output path; `hermes_cli/archive_safe.py:35` always writes `f"{base}.tar.gz"`.
- **Failure scenario:** The user saves as `work.tgz`, Scarf says "Exported", and `work.tgz` does not exist (`work.tar.gz` does). The remote export is unaffected because its scratch path is always `.tar.gz`. The default suggested name (`-profile.tar.gz`) avoids this.
- **Suggested fix:** Normalise `.tgz` to `.tar.gz` too, or echo the path Hermes printed.

### S13-F7 · P3 · SOURCE · NEW
- **Claim:** Renaming the default profile's bot validates the new value as a profile id and then selects a profile named after it. For `default`, `hermes profile rename` only sets a display name, so the selection points at a profile that does not exist.
- **Scarf:** `scarf/scarf/Features/Bots/ViewModels/BotsViewModel.swift:1145-1152` (`isValidName(target)` guard) and `:1185` (`self.selectedProfileName = target`). The sheet copy at `Views/BotsView.swift:795-797` acknowledges the display-name semantics.
- **Hermes @v2026.9.24:** `hermes_cli/profiles.py:2255-2260` shows that `old == "default"` → `set_profile_display_name`, the id stays `default`, and display names are free text up to 64 characters.
- **Failure scenario:** On the default bot, the user types `Assistant Prime` and it is refused as an invalid id. With `assistant`, it succeeds and the toast reads "Renamed to assistant". The detail pane then loses its selection (`assistant` is not a profile), and the default bot's cached agent and routines view models are dropped.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `profile list` + table parse / `◆` | argv+parse | ProfilesViewModel.swift:56,364; HermesProfileList.swift:67 | profile_cmd.py:108-127 | OK |
| `<root>/active_profile` read (remote `cat`) | file | ProfilesViewModel.swift:403-415 | profiles.py:1909-1915 | OK |
| `HermesProfileResolver` `~/.hermes/active_profile` → `profiles/<name>` | file | HermesProfileResolver.swift:155-201 | profiles.py:187,1918-1930 | OK |
| `profile show -- <n>` | argv | ProfilesViewModel.swift:92 | subcommands/profile.py:76; profile_cmd.py:369-399 | OK |
| `profile use -- <n>` | argv | ProfilesViewModel.swift:110,143 | profile.py:15; profile_cmd.py:151-158 (exit 1 on error) | OK |
| `profile create [--clone\|--clone-all] [--no-skills] -- <n>` | argv | ProfilesViewModel.swift:188-200 | profile.py:18-50; profile_cmd.py:188-211 | OK |
| `profile rename -- old new` | argv | ProfilesViewModel.swift:209; BotsService.swift Lifecycle | profile.py:86-91; profiles.py:2251 | OK (F7 bots/default) |
| `profile delete -y -- <n>` + settlement verdict | argv | ProfilesViewModel.swift:231; HermesProfileDeleteVerdict.swift:38 | profiles.py:1663-1781; profile_cmd.py:290-295 | OK |
| `profile export --output <p> -- <n>` (local) | argv | ProfilesViewModel.swift:257 | profile.py:115-120; profiles.py:2114-2139 | OK (F6) |
| remote export scratch + stream + rm | argv/file | RemoteProfileExport.swift:44-91 | same | OK |
| `profile import -- <path>` | argv | ProfilesViewModel.swift:296 | profile.py:122-126; profiles.py:2142 | OK |
| iOS `profile list` + `active_profile` | argv/file | Scarf iOS/Profiles/ProfilesView.swift:163-192 | as above | OK |
| `profile_routes` (top-level vs `gateway.`) read/write | YAML | ProfileRoutesYAML.swift; ProfileRoutesWriter.swift:30-97 | gateway/config_loader.py:93,108-112; config.py:792 | OK |
| route fields name/platform/guild_id/chat_id/thread_id/profile/enabled | YAML | ProfileRoutesWriter.swift:99-138 | profile_routing.py:114-154 | OK |
| route `user_id` / `bot_profile` | YAML | HermesProfileRoutes.swift:86-103 | profile_routing.py:65-88,140 | FINDING-F5 |
| `multiplex_profiles`, `gateway.standalone` | YAML | HermesProfileRoutes.swift (model) | config_loader.py:89; profiles.py:979 | OK |
| `kanban [--board=s] list --json [filters]` | argv+JSON | KanbanService.swift:131,138; KanbanFilters.swift:51 | kanban_parser.py:217-230; kanban.py:418-431 | OK |
| task dict decode | JSON | HermesKanbanTask.swift:188-259 | kanban_output.py:18-23,85-88 | OK |
| `kanban show <id> --json` task | JSON | KanbanService.swift:196; HermesKanbanTaskDetail.swift | kanban.py:492-498 | OK |
| show → comments | JSON | HermesKanbanComment.swift:37 | kanban.py:495 | FINDING-F1 |
| show → events | JSON | HermesKanbanEvent.swift (id default 0) | kanban.py:496 | FINDING-F1 (P3 part) |
| `kanban runs <id> --json` | JSON | KanbanService.swift:209; HermesKanbanRun.swift | kanban.py:1217-1225; kanban_output.py:29-32 | OK |
| `kanban stats --json` | JSON | KanbanService.swift:229; HermesKanbanStats.swift:38 | kanban_db.py:4217-4234 | FINDING-F2 |
| `kanban log [--tail=N] <id>` | argv | KanbanService.swift:247-266 | kanban.py:1207-1214 (exit 1 "no log") | OK |
| `kanban assignees --json` | JSON | KanbanService.swift:283-307; HermesKanbanAssignee.swift | kanban.py:319-331; kanban_db.py:4380-4388 | OK |
| `kanban diagnostics --json [--task=]` | JSON | KanbanService.swift:158-190 | kanban_parser.py (diagnostics) | TRACKED (t-b884cfbd, done) |
| `kanban create [--flags=…] --json -- <title>` | argv+JSON | KanbanCreateRequest.swift argv() ; KanbanService.swift:311 | kanban_parser.py:134-201; kanban.py:334-391 | OK |
| `kanban assign <id> <profile\|none>` | argv | KanbanService.swift:333 | kanban.py:572-577 (`_ok_or_err`) | OK |
| `kanban comment [--author=] -- <id> <text>` | argv | KanbanService.swift:340-352 | kanban_parser.py (comment); kanban.py:749-761 | OK |
| `kanban complete [--result=…] -- <ids>` | argv | KanbanService.swift:358-400 | kanban.py:894-943; kanban_db.py:2860-2891 | FINDING-F3 (UI copy/plan) |
| `kanban block -- <id> [reason]` | argv | KanbanService.swift:402-414 | kanban.py:981-1005 (`_bulk_apply` exit 1) | OK |
| `kanban unblock -- <ids>` | argv | KanbanService.swift:416-426 | kanban.py:1019-1031 | OK |
| `kanban reopen-review [--reason=] -- <ids>` | argv | KanbanService.swift:445-462 | kanban_parser.py (reopen-review); kanban.py:1069 | OK |
| `kanban archive -- <ids>` / `archive --rm <ids>` | argv | KanbanService.swift:466-476, 579-585 | kanban.py:1121-1133 | OK |
| `kanban dispatch --json [--max=]` | JSON | KanbanService.swift:478-497; KanbanFilters.swift:80-130 | kanban_ops.py:60-117 | OK |
| `kanban promote … --json [--ids …] -- id [reason]` | argv | KanbanService.swift:61-94 | kanban_parser.py (promote); kanban.py:1090-1118 | OK |
| `kanban schedule [--ids …] -- id [reason]` | argv | KanbanService.swift:98-115 | kanban.py:1008-1016 | OK |
| kanban DB location (root-shared) | path | KanbanService (implicit) | kanban_db.py:399-407 | OK |
| `platform_toolsets.<p>` / top-level `toolsets` kanban detect & write | YAML | KanbanToolsetDetector.swift:76-97; KanbanToolsetEnabler.swift:76-125 | acp_adapter/session.py:480-489; tools/kanban_tools.py:37-61 | FINDING-F4 |
| `profile.yaml` identity (`display_name`, `description`, `description_auto`, `ui_meta.hermes-bots.*`) | YAML | HermesBotProfileYAML.swift; BotsService.swift saveIdentity | profiles.py:811-891; tools/bot_mode_probe.py:111-118 | OK |
| roster scan (`profiles/*`, `assets/avatar.*`) per-file + batched script | file | BotsService.swift scan; BotsRosterScan.swift script | profiles.py:349-380 | OK |
| bot lifecycle `profile create [--clone-from s] [--description d] -- n` / `delete --yes -- n` / `rename -- a b` | argv | BotsService.swift Lifecycle.argv | profile.py:18-91 | OK (`--description` as separate token: TRACKED t-038695a3) |
| bot agent `-p <bot> config set/unset` (model.default/provider, mcp_servers.X.enabled) | argv | BotAgentConfigService.swift:257-298,355-373,494-561 | config set/unset (S05) | OK (verdicts judged by output) |
| bot agent `-p <bot> tools enable\|disable <ts> --platform cli` | argv | BotAgentConfigService.swift:318-338; BotAgentViewModel.swift:433-436 | subcommands/tools.py; tools_config_mcp.py:241-285 (exit 0 on refusal) | OK (output-judged) |
| bot `SOUL.md` read/write | file | BotAgentConfigService.swift:405-470 | agent/prompt_builder.py (SOUL at HERMES_HOME) | OK |
| bot chat `-p <bot> chat --in ~ -c "Bot Chat" --create-if-missing -Q --query-file <f>` | argv | BotConversationViewModel.swift:525-537 | `hermes chat --help` (LIVE); main.py:1540-1556 | OK |
| bot chat title lookup in bot `state.db` | SQL | HermesDataService.swift:2173 (S04) | — | UNVERIFIABLE (S04-owned) |
| bot routine `cron create --name "[bot:x] …" … --deliver bot-chat:<bot>` | argv | BotRoutinesViewModel.swift:180-215 | cron/scheduler_delivery.py:1009-1010 | OK (cron argv = S08) |
| `bot_peers.<name>.{url,note}` read | YAML | HermesBotPeersYAML.swift; PeersViewModel.swift:96-115 | subcommands/peer.py:36-49,225-236 | OK |
| `peer dm --json -- target msg` + queued / still-running | argv+JSON | HermesPeerCLI.swift dmArgs/parseDM | peer.py:345-389,423-476 | OK |
| `peer run [--idempotency-key k] --json -- target msg` | argv+JSON | HermesPeerCLI.swift runArgs/parseRun | peer.py:312-342 | OK |
| `peer status\|stop target runID --json` | argv+JSON | HermesPeerCLI.swift statusArgs/stopArgs | peer.py:276-298 | OK |
| `-p <name>` / `-p default` pin; remote `HERMES_HOME=` | argv/env | HermesProfileScope.swift:172-174, 220-306 | profiles.py:2345-2375 | OK |

## Not audited / couldn't verify
- **Not raised:** `profile rename` exits 0 with a stderr warning when a live multiplexer cannot migrate session identity (`hermes_cli/profile_identity.py:210-215`). Both Profiles and Bots show a plain "Renamed", which hides the `migrate-identity` retry hint. This is rare and Hermes itself calls the rename done, so it is not raised as a finding.
- **Not raised:** Profile Routing edits the viewed profile's config.yaml. Under multiplexing, routes are an owner (default-profile) key (`hermes_cli/profile_channels.py:57`). I did not trace whether a named profile's routes are ever read by the host gateway; the Settings scope question belongs to S05.
- **Not checked end to end:** Bot conversation success verdict for `hermes chat -Q` exit-0 failure paths (provider errors and similar); this is chat-transport territory (S01/S03). `HermesDataService` Bot Chat SQL is S04.
- **Only the handoff checked:** cron argv and verdicts used by Bot Routines (`CronViewModel`) are S08. I only checked the `bot-chat:<name>` deliver target exists.
- **Owned elsewhere:** SSH transport quoting and `HERMES_HOME` pinning internals are S15. I only spot-checked `remotePathArg` for `~`.
- **Not read line by line:** UI-only view files (BotsView, BotDetailView, BotEditorSheet, BotAgentView, BotRoutinesView, RemoteBotDetailView, KanbanBoardView, KanbanCreateSheet, PeersView, ProfilesView). I scanned them for Hermes touchpoints and found none beyond those listed.
