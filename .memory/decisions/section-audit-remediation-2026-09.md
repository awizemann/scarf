---
title: Section-audit remediation 2026-09
type: note
permalink: scarf/decisions/section-audit-remediation-2026-09
tags: [security, miniapps, widgets, audit, decision]
source_paths: [scarf/scarf/Features/Projects/Views/Widgets/WidgetPathResolver.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppAssetResolver.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppGrantStore.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/MiniAppManifest.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/MiniAppPermission.swift, scarf/scarf/Core/Utilities/MarkdownContentView.swift, scarf/scarf/Features/Projects/MiniApp/MiniAppAgentSession.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectHermesShadowDetector.swift, scarf/Packages/ScarfDesign/Sources/ScarfDesign/ScarfLinkPolicy.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/Backends/SQLValueInliner.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesMCPAdd.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesWebhookList.swift, scarf/scarf/Features/Webhooks/ViewModels/WebhooksViewModel.swift, scarf/scarf/Features/Plugins/ViewModels/PluginsViewModel.swift, scarf/Scarf iOS/Projects/Widgets/WebviewWidgetView.swift]
source_paths_inferred: false
source_sha: 4c7799352af3c5e9e48c420e6726aa23360f9278
created: 2026-09-02
updated: 2026-09-02
---

Shared log for the 2026-09 section-audit remediation cycle (Memophant task t-fee68403). Fix package F1 covered the Projects-surface security blockers plus the mini-app agent-session companion; commit 4c77993 on main. Later packages in the same cycle append here.

Verification note: every F1 finding was confirmed against the code before fixing — none were refuted. The one place the audit's prescription was NOT followed literally is the widget path fix (see below): routing widget paths through `MiniAppAssetResolver.containedFilePath` wholesale would have broken remote/SSH projects and turned "file missing" into "escapes the project root", so only the resolve-both-sides half was reused.

## Observations

- [decision] WidgetPathResolver adopts the symlink-containment convention by calling the new `MiniAppAssetResolver.isSymlinkContained` (extracted from `containedFilePath`), NOT `containedFilePath` itself — widget paths are read through ServerContext's transport and may be REMOTE, and the file may legitimately not exist yet, so the existence/non-directory half is wrong there; the check is gated on the project root existing locally. #security
- [gotcha] `NSString.standardizingPath` does not follow symlinks, so a lexical `hasPrefix` containment check is textual only — the old WidgetPathResolver comment claimed the opposite and made the hole look covered. Any new untrusted-path boundary must resolve BOTH sides with `resolvingSymlinksInPath`. #security
- [decision] Mini-app TOFU grants are keyed on `(projectId, miniAppId, MiniAppManifest.securityFingerprint)` — SHA-256 over permissions + entry + minBridgeVersion — not on identity alone; a self-rewritten miniapp.json forces re-review seeded with the prior grant. Full-file/whole-app hashing was rejected: agent-built apps change constantly, and re-prompting on cosmetic churn trains the user to click through the sheet. #miniapps
- [convention] The markdown link-scheme allowlist (http/https/mailto) is applied as `.environment(\.openURL)`, scoped to a markdown CONTAINER rather than a screen root, so it can never reach the app's own trusted hardcoded links. ⚠️ **F9 correction:** F1 applied it only to `MarkdownContentView` and claimed that was "the single container every rendered-markdown link in the app passes through". **It was not.** `TemplateMarkdown` (template READMEs / field descriptions, both sheets) and the whole iOS widget stack render markdown through their own containers and were never covered — the claim made the gap look closed. There is no single chokepoint. The policy now lives in `ScarfDesign/ScarfLinkPolicy.swift` as `.scarfSafeLinks()`, and **every** container rendering markdown Scarf did not author must apply it explicitly. #security
- [decision] `MiniAppPermission.fileRead` is now `isSensitive`, so whole-project read is never pre-ticked for agent-generated mini-apps; and the Dashboard shadow-consolidation one-liner never clobbers the user's ~/.hermes/auth.json, with the `.help` copy reworded to match. ⚠️ **F9 correction:** F1 implemented this as `cp -n`, which BROKE the command on macOS hosts — BSD `cp -n` exits 1 when it skips, aborting the `&&` chain so the `chmod` and the `mv` never ran, on exactly the case `-n` was added to protect. Now `{ [ -e dest ] || cp src dest; }`. See F9 below. #security

- [gotcha] `RemoteSQLiteBackend` ships SQL inside `<<'__SCARF_SQL__'`; QUOTING the delimiter stops expansion but NOT a value that closes the document, so any `.text` param with a newline was a remote shell-exec vector. `SQLValueInliner.encodeText` now splits newlines into `char(10)`/`char(13)` concatenation — ENCODE, never reject: a pasted multi-line search query is a legitimate param, and rejecting would have broken search. #security
- [convention] `--` end-of-options goes AFTER every flag and immediately before the positionals, never next to the verb: argparse reads every token following the first `--` as a positional, so a flag behind it is rejected as an unrecognized extra argument. This forced `kanban swarm`'s goal and `cron edit`'s job_id to move from position 1 to the end. #cli
- [gotcha] Kanban free-text reasons must be ONE argv element, not space-split — the CLI does `" ".join(args.reason)`, so splitting only destroyed runs of whitespace and handed argparse dash-leading words to claim as flags. #cli
- [decision] Substring-matching CLI prose is not a protocol: both `"no matching tasks"` sentinels are deleted. Both argv paths always pass `--json`, and `_cmd_list` returns `json.dumps([])` before that line can print — so the check was dead code that a task TITLED "no matching tasks" could still trip, wiping a populated board. #security
- [gotcha] `SSHTransport.writeFile` chmods the TMP file 0600 in the same command as, and BEFORE, the `mv` — a chmod after the rename leaves the real path world-readable for a window, and scp creates the upload with the remote umask. The private-mode basename list is shared with LocalTransport via `TransportPrivateMode`; remote `.env` had been landing world-readable while the local side enforced 0600. #security

## Relations

- relates_to [[Path containment for untrusted dirs must resolve symlinks, not just normalize lexically]]
- relates_to [[macOS Accessibility Label Conventions]]

## F2 — data/transport security (t-e96cc0ad, commit d8fabde)

All F2 findings confirmed in code except two, refuted with evidence and documented at the call site rather than "fixed":

- **`hermes auth add` keeps `--api-key` in argv.** The proposed stdin switch does not work: with the flag absent, `auth_commands.py` calls `masked_secret_prompt`, which for a non-tty stdin falls through to `getpass.getpass` — and getpass reads **`/dev/tty`**, not stdin, whenever a controlling terminal exists. Scarf launched from a terminal inherits one, so a piped key is ignored and the command blocks on the tty until timeout. A wedged credential dialog is certain; the /proc read needs an already-present local attacker. Revisit only if the CLI grows `--api-key-stdin`.
- **whatsapp_cloud creds must stay in argv.** `gateway/platforms/whatsapp_cloud.py` reads nothing from the environment and `setup_whatsapp_cloud.py` only prompts interactively (verified v2026.8.31) — there is no env path to move them to. Fix belongs upstream (WHATSAPP_CLOUD_ACCESS_TOKEN / _APP_SECRET fallbacks), after which it becomes the same one-line move ntfy just took.

Bulk `kanban promote` remains wrong (CLI takes ONE `task_id` positional + `--ids`, so ids[1…] land in the audit reason). Verified, left alone — it is F5's item; the `--` reordering does not change that positional sequence either way.


## F3 — CLI-contract rewrites (Plugins / Webhooks / Profiles / MCP add), 2026-09-02

All shapes below re-verified directly against Hermes tag `v2026.8.31` (v0.21.0) source, not against the audit report.

### Hermes CLI facts (verified)
- [fact] Plugin activation lives in **config.yaml `plugins.enabled` / `plugins.disabled`** (`plugins_cmd.py::_plugin_status`, `_save_disabled_set`). There is **no `.disabled` marker file** anywhere in Hermes — Scarf's reader had invented one, so every plugin always rendered enabled.
- [fact] `_plugin_status` returns **three** states: `enabled` / `disabled` / `not enabled`. "not enabled" (installed, in neither list) is inert at runtime — collapsing it into "enabled" is a lie.
- [fact] `hermes plugins list --json` emits a top-level array of `{name, status, version, description, source}`, all strings. **Version floor v0.16.0** — absent at v2026.5.29.2 (0.15.2), present at v2026.6.5 (0.16.0). Pre-0.16 hosts fail the whole command at argparse time.
- [fact] `plugins install --enable / --no-enable` is a mutually exclusive group present since **≥ v0.12.0** (v2026.4.30) — no gate needed. Omitting both makes the CLI prompt on stdin and answer *no* on a non-tty, which is why Scarf's installs left plugins inert while reporting "Installed".
- [fact] `--allow-tool-override` / `--no-allow-tool-override` live on **`plugins enable`**, not on `plugins install`. **Version floor v0.18.0** (absent v2026.6.19 / 0.17.0, present v2026.7.1 / 0.18.0) — *later* than Scarf's existing `hasPluginToolOverride` (0.14), which describes the manifest field, not the CLI flags. Two distinct capabilities.
- [fact] `hermes webhook list` prints **every** line indented, records keyed on `  ◆ <name>`, followed by an optional bare description line (no `Description:` label) and `URL:` / `Events:` / `Deliver:` / `Script:` labels. `Events: (all)` is a no-filter placeholder. `webhook list` has no `--json`.
- [fact] `profiles.py::export_profile` does `base = output.removesuffix(".tar.gz").removesuffix(".tgz")` then `make_targz(base, …)` which re-appends `.tar.gz`. Passing a `.zip` path therefore writes **`foo.zip.tar.gz`** and leaves the requested path missing — while still exiting 0. Hermes has no zip path at any version.
- [fact] `profile delete -y` exists since **≥ v0.12.0** — no gate needed. Without it the confirmation read hits EOF on a piped stdin, the CLI declines, and exits **0**.
- [fact] `mcp_config.py::cmd_mcp_add` **never exits nonzero** — every failure path is a bare `return`. Exit code carries no information; the outcome must be read from stdout (`✓ Saved '<name>' … (X/Y tools enabled)` / `Saved '<name>' to config (disabled)` / `Failed to connect:` / `was NOT saved` / `Cancelled`).
- [fact] For a `--url` server without `--auth oauth`, `cmd_mcp_add` asks "Does this server require authentication? [Y/n]" (**default yes**) and then reads the bearer token as a *value* via `masked_secret_prompt` → `getpass` → stdin when there is no controlling tty. Scarf's blanket `"y\ny\ny\n"` therefore wrote the literal string `y` into `~/.hermes/.env` as `MCP_<NAME>_API_KEY` and stamped `Authorization: Bearer ${…}` into config.yaml.
- [fact] `mcp add` has **no** `--yes` / `--non-interactive` / `--skip-probe` flag at any shipped version. The honest fix for stdio servers landing disabled is to pass `--args` (and `--env`) **at add time** so the discovery probe launches the real server; Scarf had deliberately withheld the args, guaranteeing a probe failure and an `enabled: false` entry.

### Rules adopted
- [rule] Feed `hermes` stdin **per prompt-branch**, never a blanket `y` stream. Blank lines (accept-default) are the safe answer everywhere in `mcp add` *except* the auth question, whose default is yes — that one needs an explicit `n`. Never send a bare `y` where the CLI reads a value.
- [rule] 🚨 **`--` does NOT work after an `argparse.REMAINDER` option.** Verified on CPython 3.14: argparse consumes the first `--` as its own separator before REMAINDER sees it, and the remainder then fails as `unrecognized arguments`. So `mcp add … --args -y <pkg>` is correct and `--args -- -y <pkg>` is broken — even though `cmd_mcp_add` contains a `if cmd_args[0] == "--"` strip that reads like an invitation (dead code on modern hosts). `--` before an ordinary positional (`profile delete -y -- name`) is unaffected and still correct.
- [rule] A CLI-output parser returns `nil` (not `[]`) when it cannot understand the payload, so callers can distinguish "genuinely empty" from "unparsed" and fall back rather than rendering emptiness as fact.
- [rule] Catalog install must carry **both** halves of the manifest: `tools.default_excluded` → `tools.exclude` *and* `tools.default_enabled` → `tools.include` (mutually exclusive). Scarf carried only the exclude half, so allow-list entries (n8n, databricks, comfy, kiwi) installed with every tool live.
- [rule] Any sheet-scoped view model constructed from a context-bearing parent must be passed that context explicitly — `MCPServerEditorViewModel(server:)` defaulting to `.local` had the editor writing this Mac's config.yaml while the user browsed a remote host.
- [rule] Form state derived from a picked catalog entry must be cleared when the user retargets the form. Guard the clear with an identity snapshot taken at apply time, or the `onChange` handlers fire on the applying writes and erase what was just set.

### Where it lives
- Parsers (all pure, fixture-tested): `ScarfCore/Parsing/HermesPluginList.swift`, `HermesWebhookList.swift`, `HermesMCPAdd.swift`, `HermesProfileArchive.swift`. Tests: `ScarfCoreTests/SectionAuditF3CLIContractTests.swift`.
- Capability flags added: `hasPluginsListJSON` (0.16), `hasPluginEnableToolOverrideFlag` (0.18).

## F4 — Monitor data integrity (t-4ec88dae, commit d0c6504)

Every F4 finding was confirmed in code before fixing — none refuted. Dashboard/Insights/Sessions/Activity + the ScarfCore query layer they share.

- [gotcha] `HermesDataService.statsSQL` had **no WHERE clause at all** while `DashboardView` headed the cards "Last 7 days", and it counted every row in `sessions` while the list under it showed only `sessionListPredicate` rows. Two different lies in one 6-line query. Both fixed together: `statsSQL(since:)` + `FROM sessionListFrom WHERE sessionListPredicate`. The per-session counters it SUMs are LIFETIME counters, so a long session started inside the window contributes all of itself — same semantics `fetchSessionsInPeriod` already had, deliberately kept.
- [rule] **A period label is a contract with the query.** `DashboardViewModel.statsWindowStart()` exists so the "Last 7 days" heading and the `since` bound move together; changing one without the other is the bug this replaced.
- [rule] **Every aggregate on a page must run the SAME population predicate as the list on that page.** Insights ran a hand-rolled `parent_session_id IS NULL` in `insightsSnapshot` and `sessionListPredicate` in `fetchSessionsInPeriod` — the two disagree in BOTH directions (the hand-rolled one drops branch/reset children and keeps hidden rows), so the tool histogram and the session table described different session sets on one screen.
- [decision] `sessionListSnapshot(includeUnreadActivity:)` — the `last_active` correlated `MAX(messages.timestamp)` subquery rides ONLY where the unread dot is read. Grep-verified: `HermesSession.isUnread` has exactly one consumer, `ChatSessionListPane` (50 rows). The Sessions tab renders no unread indicator and asks for 500 rows per watcher tick, so it was paying 500 correlated subqueries for a column nothing on that screen reads. Chat keeps the default `true`.
- [decision] `SessionPreviewSQL.firstEligibleUserRowSQL(sessionIdCount:)` is a THIRD narrow entry point over the same builders (alongside the list and `sessionScoped:` forms) — never a re-fork. Added because Activity's filter labels and Insights' Notable Sessions both need previews for a **known id set**, and the list form answers a different question ("the newest N conversations"), so most Activity labels were raw UUIDs and Notable Sessions bought 500 previews to use four.
- [gotcha] The Dashboard's recent-tool-calls slot was the ONLY message query still on the heavy `messageColumns` (full `reasoning_content`) and the only tool-call query with no `active = 1` — so it shipped 20+ KB blobs per row on every watcher tick and kept re-surfacing rewound tool calls.
- [decision] **Preview/title precedence lives in one place**: `HermesSession.displayLabel(preview:)` — title, then first-user-message preview, then id. Chat/Sessions/Insights each spelled it out and agreed; the Dashboard did `preview ?? displayTitle` and preferred the preview, so a session renamed in Sessions kept its old opening line on the Dashboard.
- [decision] Load-race guards are NOT one pattern. `DashboardViewModel`'s in-flight-task coalescing is correct only for a load that **takes no parameters** — joining an in-flight pass then gives the caller what it asked for. `InsightsViewModel.load()` is parameterised by `period`, so it uses a **generation counter** instead (newest request wins, stale passes drop their results): coalescing there would have answered the wrong period, and the period picker is exactly what races the watcher. Sessions/Activity are unparameterised and use the coalescing form.
- [gotcha] `InsightsViewModel.load()` called `dataService.close()` at the end of every load — the gh#102 shape, forcing the next `refresh()` to reopen a possibly multi-hundred-MB state.db with an uncheckpointed WAL on every watcher tick. Nothing in ScarfCore should close the handle per load; backend `deinit` releases it.
- [rule] An empty result set and a failed query look **identical on screen** — a fresh Hermes install and a dropped SSH channel are the same pixels. `DashboardSnapshot.queryError` carries the humanized reason, and the Dashboard surfaces it on LOCAL contexts too (unlike the config/gateway/pgrep misses, which stay remote-only).
- [gotcha] Sessions' Model column read a `private extension HermesSession { var lastModel: String? { nil } }` — a hardcoded nil whose doc comment claimed the session has no model field, while `sessions.model` was in `sessionColumns` and on the struct being rendered. The Updated column showed `startedAt` under an "Updated" heading. The Starred pill was `return 0` plus a filter that returned its input unchanged, though `HermesSession.pinned` (v0.20) was right there.
- [convention] Session-detail REASONING now lazy-loads through `fetchReasoningContent(for:)` on first disclosure-open — the same seam `RichMessageBubble` uses (t-aud21), passed in as a closure so the view stays free of a data service. Bulk fetches use `messageColumnsLight`, which NULLs the blob, so any NEW surface rendering `message.reasoning` directly will be blank for v0.16+ thinking models.

Tests: `ScarfCoreTests/SectionAuditF4MonitorTests.swift` — 11 tests against a real seeded SQLite fixture (not the mock backend: every finding here is about what the SQL selects, and a mock echoing canned rows passes the pre-fix code too). The fixture holds six sessions of which three are listable, so any query that quietly counts all of them fails. Plus `scarfTests/SessionDeletedSignalTests.failedDeleteSurfacesAnError`.

Not in scope, left alone: the new `deleteError` banner string is a plain `String` like the neighbouring `exportMessage`/`renameError` — the app-wide view-model-banner localization class is F7's.

## F5 — Interact/Manage/Config correctness (t-1c11e831, commits 6b2cb47 09cbfab 4a95428 f08cdf0 b963af9 0ede1c9)

Largest package of the cycle. Four findings REFUTED at fix time — recorded below with evidence rather than "fixed".

### Refutations (do not re-open)

- **slack `require_mention` is NOT a silent no-op.** `require_mention` is in `load_gateway_config`'s hardcoded shared-key bridge list (`gateway/config.py:1719-1720`), applied by `extra.update(bridged)` at `:1810` — so the TOP-LEVEL `platforms.slack.require_mention` Scarf writes lands in `config.extra` and the adapter reads it. The audit's prescription (switch the writer to `extra.`) would have been a no-op at best. The reader gained `platforms.slack.extra.require_mention` only as a FALLBACK, with precedence mirroring Hermes exactly: the bridge is `extra.update(bridged)`, so a top-level value OVERWRITES an `extra:` one — hence top-level first.
- **`skip_attachments` IS dead at top level** — same file, opposite answer, and the difference is the whole lesson: the bridge list is an explicit hardcoded enumeration, not a rule. `skip_attachments` is absent from it, and `plugins/platforms/email/adapter.py:565` reads `extra.get("skip_attachments", False)`. The adapter's own docstring shows a TOP-LEVEL YAML example — it is wrong. **Never infer a key's shape from a neighbouring key, an adapter comment, or the audit's word: grep the bridge list.**
- **Mini-app settle handshake / `promptInFlight`** was already fixed in F1 (4c77993) — busy slot claimed before the `ensureSession()` suspension and cleared unconditionally, settling an exact `eventsProcessed >= eventsEmitted` count handshake.
- **`DashboardWidget`/`DashboardSection` identity is already value-derived** (`ProjectDashboard.swift:148/167` — `title`, `type + ":" + title`), not index- or per-body-UUID-based. Residual risk is COLLISION, not instability: two `log_tail` "Logs" widgets on different paths, or two sections sharing a title, produce duplicate ForEach ids. Left alone; revisit only if a real duplicate appears.
- **`GatewayBehaviorViewModel.isSaving`** already exists (line 42) and is already wired to the save button's `.disabled`. No change.

### Memory editor — the data-loss blocker

- [decision] The Memory editor now mirrors `BotAgentViewModel`'s SOUL.md discipline. Dirty state is measured against a tracked `baseline`, **never against the live `memoryContent`** — once the watcher refreshes content under a dirty draft the two differ, so comparing to the live copy calls an edited buffer clean. Watcher content is adopted only when the buffer is CLEAN (this keeps the ordinary refresh path working — a guard that also froze reload just trades one bug for another); a dirty buffer raises a conflict only when the disk copy actually moved off the baseline, so an idle tick is not a conflict.
- [gotcha] A conflict-aware `save()` must NOT publish the new text into the observed property itself. Doing so runs the view's `onChange` observer while the draft still carries the OLD baseline, and the write reads as a conflict **against itself**. The caller commits, after advancing the baseline. This bit at review time, not at write time.
- [gotcha] Two adjacent losses hid behind the headline one: switching between MEMORY.md and USER.md dropped the draft (now stashed per target), and switching memory PROFILE would have saved the draft into a different profile's file (picker disabled while any draft is dirty). A per-file editor needs per-file draft state, not one buffer.

### Hermes CLI facts (verified against v2026.8.31, several by running the real argparse)

- [fact] `kanban promote` = ONE `task_id` positional + `reason` (`nargs="*"`) + `--ids` (`nargs="+"`) (`hermes_cli/kanban.py:744-754`; `_cmd_promote` at :2622 does `" ".join(args.reason)` then `[args.task_id, *args.ids]`). Passing ids positionally makes `promote --json A B C` parse as `task_id=A, reason="B C"` — **reproduced live**. `schedule` takes the identical shape and had the same latent bug.
- [rule] `--ids` must sit LAST among the flags: it is `nargs="+"` and greedy, and the `--` that follows is what terminates its consumption so the trailing positionals stay positional. Verified live: `promote --json --ids B C -- A "reason"` → `task_id=A, ids=[B,C], reason="reason"`.
- [fact] Hermes has **no `runat` cron kind**; `cron/jobs.py::parse_schedule` returns `{"kind": "once", "run_at": <iso>, "display": "once at …"}`. `git grep runat` at the tag returns nothing. `parse_schedule` has no branch that reads the `display` string back, so a one-shot edit that resubmits the display text raises. `run_at` is the only round-trippable value — hence `CronSchedule.editValue`.
- [fact] `hermes config set` handles arbitrary-depth dotted keys and creates intermediate dicts on demand (`hermes_cli/config.py::_set_nested`, :1137), so `platforms.email.extra.skip_attachments` is a valid write path — the end-to-end round trip is Hermes's writer → nested YAML → Scarf's `parseNestedYAML` → the adapter's `extra.get`.
- [fact] Skill install shapes are `_VALID_NAME_RE = ^[a-z][a-z0-9_-]*$` and `_VALID_CATEGORY_RE = ^[a-z][a-z0-9_/-]*$` (`hermes_cli/skills_hub.py`): lowercase, letter-initial, **no dots**; `/` is legal in a category (nested buckets) but not in a name. Reserved names: `skill`, `readme`, `index`, `unnamed-skill`.
- [security] 🚨 Hermes applies `_VALID_CATEGORY_RE` **only to the value it prompts for interactively** — a `--category` passed as a FLAG is never validated and goes straight into `skills/{category}/{name}/`. A `..` typed into Scarf's InstallFromURLSheet installed outside the skills root. **Scarf is the only check on that path**; `SkillInstallValidator` is a security control, not a UX nicety.

### Rules adopted

- [rule] **Substring-matching CLI prose is not a protocol** (second instance this cycle, opposite direction from the kanban sentinel). `hasFailureMarker` matched prose that a SUCCESSFUL `mcp` probe prints inside per-tool DESCRIPTIONS — a filesystem server documenting "Error: ENOENT / No such file or directory" read as failed. Every real failure goes through `mcp_config.py::_error`'s `✗`; only that marker survives.
- [rule] A status badge must read a LIVE probe, not a state file nothing rewrites on crash. `gateway_state.json` kept a green "running" badge forever after the gateway died; the badge now reads `hermes gateway status`, falling back to stored state only for the service-managed branches.
- [rule] The number the user APPROVES must be the number the executor acts on. Fleet-apply previewed `cronJobIds` (which also indexes legacy `[tmpl:]` jobs) while the executor copied only `[proj:<uuid>]`; both now derive from one `copyableCronJobs` set. Same class as F4's "a period label is a contract with the query".
- [gotcha] `renameProject` rebuilt `ProjectEntry` WITHOUT its `uuid`, so the next `ProjectStore` pass minted a fresh one — detaching the project from its record, its `[proj:<uuid>]` cron jobs and its fleet siblings. The audit called this a re-derived slug; it was identity loss.
- [gotcha] A results `.sheet` attached inside an `if let` branch is torn out from under itself when the success handler reloads the data that branch tests. Present result sheets from the container root.
- [gotcha] `#"\u{001B}"#` in a Swift RAW string is not an escape — ICU receives the literal characters, and ICU's `\u` takes four BARE hex digits with no braces, so the pattern silently never matches. Use `\x1B`. A regex that compiles is not a regex that matches.

### Where it lives / tests

`SectionAuditF5KanbanTests` (20), `SectionAuditF5FleetTests` (12), `SectionAuditF5ManageTests` (10), `SectionAuditF5InteractTests` (16), `SectionAuditF5PlatformExtraKeyTests` (8) in ScarfCoreTests; `MemoryEditorConflictTests` (6) and `SectionAuditF5ManageAppTests` (6) in scarfTests. ScarfCore 1787 tests / 110 suites green; app target 603 / 77 green. `KanbanService` argv construction moved into `nonisolated static` pure builders so the shipped argv and the asserted argv are the same code.

Known follow-up, out of F5's scope: `scarf/Scarf iOS/Cron/CronListView.swift:201-203` has the same seed-from-display one-shot bug and should adopt `CronSchedule.editValue`.


## F6 — main-actor + performance sweep (t-8b824981, commits 442080d b5bd3d9 b60d6e0 461a9c9 3110ab6 6e97ed7 b6dd14e)

Two systemic patterns plus itemized perf work. One finding REFUTED, one replaced by a different real defect found in its place.

### Refutations (do not re-open)

- **iOS `CronListView` does NOT have F5's seed-from-display bug.** F5's report flagged `Scarf iOS/Cron/CronListView.swift:201-203` as the same defect. It is not: F5 fixed a Mac editor that collapsed a schedule into ONE free-text field seeded from `schedule.display` and posted it to `hermes cron edit --schedule`, where `parse_schedule` cannot read `"once at 2026-02-03 14:00"` back. The iOS editor has SEPARATE `run_at` / `expr` fields — already exactly what `CronSchedule.editValue` selects — and iOS persists by rewriting `jobs.json` directly (`IOSCronViewModel.saveJobs`), so `parse_schedule` is never invoked and `display` round-trips as the label it is. `editValue` would be a literal no-op there. **The real defect found in its place:** `buildJob`'s `sameKind` guard covered `minutes` and `extra` but not `run_at` / `display` / `expr`, whose `@State` keeps the old value after the form hides them — so switching a job from "once" to "cron" saved the new expression alongside a dead one-shot timestamp and a `display` reading "once at …".
- **F4 already dropped the unread correlated subquery** from the Sessions tab (`sessionListSnapshot(includeUnreadActivity: false)`). Verified before touching it; no change.
- **`GatewayBehaviorViewModel.isSaving` existed** (F5 noted this) but was DEAD: set, `defer`-cleared, never yielding, so it could never render. Existence is not the same as being observable.

### Rules adopted

- [rule] 🚨 **A busy flag set and cleared inside one synchronous run can never render.** `isSaving = true; defer { isSaving = false }` around blocking I/O is not a loading state — it is a no-op that reads like one. Found in `GatewayBehaviorViewModel.save`, `NewProjectViewModel.commit` (whose sheet already drew a `ProgressView` for it) and `MemoryViewModel.save`. The flag has to survive an `await`.
- [rule] **A comment claiming work is detached is not a detach.** `GatewayBehaviorViewModel.save`'s step-1 comment said "Detached so the SCP round-trip on remote hosts doesn't block MainActor" above a fully synchronous write. Grep for the `Task.detached` before trusting the prose.
- [rule] **Detaching a mutation creates a reordering hazard against loads the UI depends on.** A load that started BEFORE the mutation can commit pre-mutation state on top of the post-mutation reload. `MessagingGatewayViewModel` gained a `loadGeneration` token that every mutation bumps as it begins, so any in-flight load drops its result. This is a THIRD load-race shape alongside F4's two: coalescing (unparameterised, no interleaved writes), generation-newest-wins (parameterised), and **invalidate-on-mutation** (unparameterised but racing a writer).
- [rule] **A cap must degrade visibly.** Every bound added here announces itself: Logs banners "Showing the most recent 5,000 entries", the Kanban log tab banners its 256 KB tail, the mini-app scheme handler returns a real **413** (not a truncated body) and logs it. A silently truncated view is indistinguishable from a short one.
- [rule] **A computed property whose inputs change rarely and whose body is expensive belongs in a `didSet`-driven memo.** The tell is an ICU call in a filter predicate: `localizedCaseInsensitiveContains` and `range(of:options:[.caseInsensitive, .diacriticInsensitive])` are collation searches, not byte compares, and both sat inside per-body filters over 500–5,000 rows while a 2-second poll (Logs) or a text field (Bots, Sessions) invalidated that body continuously. Memoized: `SessionsViewModel.filteredSessions`/`visibleSessions`/`quickFilterCounts`, `LogsViewModel.filteredEntries`, and the five `BotsViewModel` roster projections (where `visibleRows` re-ran three filters and `searchFoundNothing` re-ran `visibleRows`).
- [rule] **`.task(id:)` cancellation does not stop a suspended `await` from resuming**, and a `Task.detached` inside it inherits no cancellation at all. Every widget reload now checks `Task.isCancelled` immediately before committing, or a slow earlier watcher tick overwrites a newer one's content.
- [rule] **Poll loops need three things, not one:** a scenePhase pause, failure backoff, and a bounded read. The Kanban surfaces had none — an open board plus inspector spawned five `hermes kanban` invocations every 2–5s, forever, at full rate, against a backgrounded window on a dead host. `KanbanPollBackoff` holds the shared cadence.
- [rule] **Concurrency across hosts is safe where concurrency across keys is not.** `FleetApplyExecutor` fans out over targets (one per server, each writing its own manifest) — but `QuickCommandsViewModel.addOrUpdate`'s two `hermes config set` calls stay SEQUENTIAL inside their detached body, because Hermes's config writer is read-modify-write and overlapping them loses a key.

### Gotchas

- [gotcha] `HermesLogService.readLastLines` used `FileManager.contents(atPath:)` on the LOCAL branch — the whole `agent.log` (routinely hundreds of MB) into memory to take 500 lines — while the REMOTE branch had always used a bounded `tail -n`. The degraded path was the fast one. `readLocalTail` walks back from EOF in 64 KiB chunks under a 4 MiB ceiling and drops the partial first line.
- [gotcha] `NSRegularExpression` compiled per call is invisible until you find where it is called: `HermesLogService.parseLine` rebuilt its pattern 500 times per log-window load and once per line per 2s tick. `AnsiStripper.strip` carried a comment calling its per-call compile negligible "because log windows are small" — it runs over a whole window per watcher tick on the project dashboard. Hoisted as `nonisolated(unsafe) static let` (the type is documented thread-safe once constructed).
- [gotcha] `ScarfGoKanbanView.resolvedTenant` (iOS) was a COMPUTED property doing two synchronous transport calls (`fileExists` + `readFile`) on the MainActor — re-run on every 5-second poll for a manifest field that cannot change under a running board.
- [gotcha] `ProjectsSidebar`'s `canConfigureProject` / `isTemplateInstalled` closures did a blocking `transport.fileExists` inside a `@ViewBuilder` context-menu body: two SSH stats per menu evaluation, on the actor drawing the menu. `ProjectMenuProbeCache` probes off-main per registry reload — **but a pure cache regressed `TemplateInstallUITests`**, because the async refresh leaves a window right after an install where the menu answers "no template". The cache falls back to a live probe on LOCAL contexts only: a local `stat` was never the cost being removed, and remote misses answer `false` and self-correct.
- [gotcha] `PersonalitiesViewModel.load` read `config.yaml` TWICE — `loadConfig()` parsed it, then the personalities block was re-read from disk through `ctx.readText`. Two SFTP round-trips over identical bytes.
- [gotcha] Renaming a local to `path` can trip a source-scanning test: `AllConfigWritersParityTests.nonLiteralKeySiteCountsMatchTheManifest` matches `writeText(path, …)` as a direct-YAML config splice. `saveSOUL`'s SOUL.md write is not a config write; the local is named `soulPath` deliberately.
- [gotcha] `SessionsViewModel.computeStats(dbSize: nil)` did a blocking SSH `stat` on the main actor from `confirmDelete`. Its comment justified this as "one-shot, user-initiated" — but it landed immediately after a delete, i.e. exactly when the window had to repaint. It reuses the size `load()` measured, which is also the more honest number: deleting rows does not shrink a SQLite file until a VACUUM.
- [gotcha] Progress callbacks from a `TaskGroup` hop to the MainActor in ARBITRARY order — `FleetApplyViewModel.applyProgress` clamps monotonic, and its denominator comes from `plan.targets`, not `plan.effectiveTargets` (the executor walks every target, including all-no-op ones, so the smaller set let the counter run past its own total).
- [gotcha] `MCPServersViewModel.testAll` never touched `testingNames`, so a "Test All" showed no busy state anywhere — results simply appeared one at a time out of nowhere. It was also fully serial and had no cancellation at all: starting it committed the user to every remaining probe's timeout.

### Test-seam note

Detaching a mutation breaks every test that asserted synchronously after calling it. `SessionsViewModel` exposes `inFlightDelete` / `inFlightRename` so a test can `await` the mutation it triggered; the injected `sessionDeleteRunner` seam is otherwise unchanged. `FleetApplyExecutor.execute` became `async` and its tests with it.

Counts: ScarfCore 1794 tests / 111 suites green (new: `SectionAuditF6BoundedReadTests`, 7); app target 603 / 77 green; `scarfUITests/TemplateInstallUITests` green. Mac and iOS (`scarf mobile`) targets both build.


## F7 — localization systemic fix (t-5ca5463b, commits 6b629f1 e623c29 b17271c 6a62bf3)

Cross-cutting theme 1. Every finding confirmed in code — none refuted — plus one
additional defect found while checking the enumerated list (below).

### Rules adopted

- [rule] 🚨 **A `String`-typed display parameter binds `Text`'s VERBATIM overload.** This is
  not a missing translation, it is an UNREACHABLE one: the key never enters
  Localizable.xcstrings at all, and several keys sat in the catalog already translated in six
  languages with no live call site producing them (`Overview`, `Top Tools`,
  `Unknown widget type: "%@"`, `0 9 * * *  or  30m  or  every 2h`, `Edit %@`). The ScarfDesign
  precedent (be4f27d, v2.24) now applies app-wide: take `LocalizedStringKey`, add an explicit
  `verbatim:` / `verbatimLabel:` / `verbatimReason:` init for genuinely runtime text.
- [rule] **ScarfCore has no string catalog, so NOTHING it returns is extractable.** Any
  user-facing vocabulary on a ScarfCore enum has to be localized app-side, one whole sentence
  per case. `BotPresence.label`/`.accessibilityDescription` and `MiniAppPermission.summary`
  keep their English tokens (logs/tests) and carry a ⚠️ doc comment; the views map the CASE.
- [rule] **Never interpolate an English noun into a localized frame.**
  `Text("Allowed \(kind.pluralNoun)")` extracts as `"Allowed %@"` — unusable in any language
  that inflects the adjective, and the noun is English regardless. `GatewayAllowlistKind` keeps
  `noun`/`pluralNoun` for YAML and gains `allowedHeading`/`noRestrictionsNote`/`addEntryLabel`/
  `countSummary(_:)` app-side (duplicated on iOS, which cannot see the Mac extension).
- [rule] **A verbatim escape hatch REORDERS the argument list on purpose.**
  `WidgetErrorCard(verbatimReason:title:hint:)` puts the escaped param first so a call site
  cannot drift back onto the localized init by accident.
- [decision] Plural hacks move to **automatic grammar agreement** (`^[\(n) incident](inflect: true)`),
  not String Catalog plural variations: the catalog had ZERO `variations` entries, the whole
  tools/translations pipeline is flat key→string, and `validate-catalog.py` assumes `stringUnit`.
  Inflection keeps that schema intact. Markup is kept for de/es/fr/pt-BR and DROPPED for
  ja/zh-Hans (no plural agreement — the bare noun is already correct). 18 hack keys → 11.
- [rule] **A retired plural-hack key must be DELETED from the catalog, not left unused** — a
  stale key reads as translated while the live call site renders the new one. Seven removed.
- [convention] A closure that returns display text (`PickerRow.optionLabel`, `StepperRow.valueLabel`)
  keeps returning `String` and is rendered `Text(verbatim:)`; the LITERALS inside it become
  `String(localized:)` at the call site ("Unlimited", "Default"). Converting the closure's return
  type would have forced every caller through `Text`.

### Gotchas

- [gotcha] `formatDuration` hardcoded `"\(hours)h \(minutes)m"` — English unit names AND Latin
  digits. `Duration.UnitsFormatStyle` fixes both. `formatTokens` had THREE implementations
  disagreeing (ScarfCore `%.1fM`, iOS Dashboard's copy of it, and Chat's already-correct
  `.number.notation(.compactName)`); all three now use the compact-name style.
- [gotcha] Found while checking the list, not on it: `ActivityView.groupedByDay` built
  `"Today"`/`"Yesterday"` as plain `String`s used as both the label AND the group `id`, beside
  two branches that were already locale-formatted dates. Localized; the id stays unique per day.
- [gotcha] `.stringsdata` lives under the DerivedData dir for THIS project path — resolve it with
  `xcodebuild -showBuildSettings | grep OBJROOT`. A neighbouring worktree's DerivedData contains
  identically-named files whose `source` points somewhere else entirely, and diffing those
  silently reports "0 missing".
- [gotcha] `merge-translations.py` only writes keys that ALREADY exist in the catalog. New keys
  must be inserted into Localizable.xcstrings first, then merged — otherwise every new
  translation lands in `unknown-keys-skipped` and the script exits 1.

### Scope held

The full ~40-view-model banner sweep stays OUT (app-wide policy follow-up, as F4 already noted
for `deleteError`). F7 did the four high-visibility ones: the mini-app consent sheet, widget
path errors, fleet field results, Health banners.

### Counts

216 new catalog keys, 215 translated ×6 (only "Nous Portal" falls back, +1 to the fallback list:
59→60); catalog 2165→2374 keys; `tools/validate-catalog.py` zero errors. ScarfCore 1794/111
green; app target 607 tests / 78 suites green (new `LocalizationF7RecoveryTests`, 4 tests, pins
the recovered keys by exact spelling). Mac and iOS both build.

## F8 — accessibility pass (t-7de9113d, commits 0b4c01d 7a23286 4cae7ae 8c9349c)

Every F8 finding was confirmed in code before fixing — none refuted. Labels compose per [[macOS Accessibility Label Conventions]]; no `accessibilityIdentifier` was renamed (grep-verified: the only XCUITest-load-bearing identifiers live in Templates / Projects / Bots, none of which this package touched).

- [gotcha] **A `Button` nested inside another `Button`'s label is flattened by AppKit.** `SessionTableRow`'s project chip lived inside the row button: it never took keyboard focus, and VoiceOver activation fired the ROW's action instead of the chip's. The fix is structural, not a label — the chip is now a sibling in the row `HStack`, with the padding/hover background lifted onto that HStack so the row still highlights as one. When there is NO project, the 120pt column is rendered inside the row button instead, so clicking that empty stretch still opens the session (splitting it naively silently shrinks the row's own click target). #accessibility
- [gotcha] `.onTapGesture` on a row is mouse-only: no button trait, no Full-Keyboard-Access activation, nothing for VoiceOver to activate. `ProjectSessionsView`'s session list was the last one in the app doing this. Rows that act must be `Button`. #accessibility
- [convention] A control given `Text("")` / `EmptyView()` as its label and a *sibling* `Text` as its visible name is nameless to VoiceOver AND untargetable by Voice Control. Pass the real label to the control and add `.labelsHidden()` — the layout is unchanged and the name survives. This was the whole shape of `SettingsComponents` (ToggleRow / PickerRow / StepperRow / DoubleStepperRow), `ToolRow`'s switch, Activity's session `Picker`, and Health's Status/Diagnostics `Picker`. #accessibility
- [rule] **`.help()` is not an accessibility label.** It is a mouse-hover tooltip and nothing else. Every glyph-only control fixed in F8 (Curator's 5, MCP detail's Test/Enable/Remove, the restart banner's X, Memory's reset, Kanban's two warning glyphs, the cron dot) had a `.help` and was read as an unnamed button. #accessibility
- [rule] Repeated row actions must be disambiguated by the row's subject — "Open", "Remove", "Pin skill", "Open session" repeated down a list gives Voice Control nothing sayable to target and VoiceOver no way to tell rows apart. Applied to mini-app Open, Plugins enable/update/remove, Webhooks test/remove, Curator pin/unpin/archive, Insights Notable Sessions.
- [decision] **Hot paths get `.combine`, never a composed label.** `.accessibilityLabel(Text(verbatim: expr))` evaluates `expr` on EVERY body evaluation of every row; `.combine` costs nothing until accessibility actually asks. So log rows (F6's 5,000-row cap) use bare `.combine` plus an `.accessibilityActions` custom action for the session-id button that combining absorbs, and `RichMessageBubble` (re-renders per streamed token) uses `.contain` with a STATIC role literal ("You" / "Assistant") — role was previously conveyed only by alignment and bubble colour. Composed labels are reserved for bounded lists.
- [gotcha] `.accessibilityLabel` on a plain container does NOT name a group — it propagates down and OVERWRITES every child's label. Use `.accessibilityElement(children: .contain)` alongside it (Insights charts, the cockpit panel bar, the transcript bubbles).
- [decision] Colour-only state is fixed with a **trait** where the control is selectable (`.isSelected` on Sessions quick-filter pills, Activity `FilterChip`, cockpit panel tabs, focused `ToolCallCard`) and with **`.accessibilityValue`** where it is a status readout (`StatusCard`'s running dot, `CheckRow`, `StatusGridWidgetView` cells, the cron dot). Not interchangeable: a value on a tab does not tell VoiceOver it is the current one.
- [decision] The cron pulsing status dot honours `@Environment(\.accessibilityReduceMotion)` — an `.repeatForever` animation is exactly what that setting exists to suppress — and gains `statusDotLabel(_:)`, which mirrors `statusDotColor(_:)`'s precedence order verbatim so the spoken state and the hue can never disagree.
- [gotcha] Decorative glyphs and emoji must be `.accessibilityHidden(true)` or VoiceOver announces their Unicode name ahead of the real content (`ToolRow`'s `tool.icon` emoji, banner warning triangles, redundant status dots that sit beside text already saying the same thing).
- [gotcha] `ToolsView.statusDescription` returned a plain `String`, so `Text(tooltip)` bound the **verbatim** overload and the copy was never extracted. Now `LocalizedStringResource`. Same class as the note's existing `.accessibilityLabel(someString)` gotcha — any UI copy that reaches `Text` or an accessibility modifier as a `String` variable is invisible to the localizer.
- [fact] KanbanCardView had zero accessibility in 452 lines. Its explicit combined label therefore had to enumerate everything on the card (title, status, both warning glyphs, assignee, workspace, goal badge, skills, auto-block reason, relative time, diagnostics count, priority) — an explicit label REPLACES the combined text, so anything omitted becomes unreachable.

Tests: no new suites — F8 adds no behaviour a unit test can observe (labels and traits are not reachable from XCTest without a UI test host). Regression coverage is the existing 1,794 ScarfCore + 607 app tests, all green after each commit, plus a full Debug build per site.


## F9 — re-audit remediation (commits 3e8b3e9 4cd6508 224bf8d ad3f235 8b7217a 2e25ba4)

The closing package: the F9 re-audit's findings against the fixes F1–F8 shipped. Notably, **three of the ten items were defects introduced or left by earlier packages in this same cycle** — a `cp -n` that broke the command it was meant to make safe, an openURL claim that made an uncovered gap look covered, and a `.public` argv log whose sibling F2 had already fixed. A remediation pass needs its own audit.

One item was **REFUTED by execution** and is recorded below rather than "fixed".

### Refutation (do not re-open)

- 🚨 **`--` before `mcp add`'s `name` positional does NOT parse.** The re-audit asked for it "for consistency with the F2/F3 rule". Ran the real subparser shape: `mcp add -- srv --command npx` fails with `unrecognized arguments: --command npx`, and so do the `--url`, `--env` and leading-dash-name forms. Python's argparse treats **everything** after the first `--` as positional, so a separator only works when the positionals are the LAST thing on the line. `mcp add` puts `name` first and its flags after it, so there is no safe placement at all. A leading-dash server name is rejected upstream by the name validator instead. This is the SECOND way `--` fails on this subcommand (F3 recorded the REMAINDER one) — the F2/F3 rule is narrower than it reads.

### Rules adopted

- [rule] 🚨 **`cp -n` is not portable and is not safe in an `&&` chain.** BSD `cp` (macOS — and the "remote" host in Scarf's shell one-liners is frequently a Mac) exits **1** when `-n` skips an existing file; GNU `cp` exits 0. Any `&&` chain after it dies on precisely the has-existing-file case. Use `[ -e dest ] || cp src dest` — same no-clobber guarantee, exit 0 on the skip path, portable. **Verified live on this Mac.** More generally: before chaining a guarded command, check what it returns on the guarded path, not just the happy one. #cli
- [rule] 🚨 **Swift's `Character` is a grapheme cluster, so CRLF is ONE character equal to neither `"\n"` nor `"\r"`.** Any scanner, escaper or validator over untrusted text must iterate `unicodeScalars`, and so must its `String.contains` fast-path — `contains` compares graphemes too, so a Character-based guard fails *twice*, silently, and the fast path is the half that usually gets missed. This defeated F2's own heredoc encoder (`SQLValueInliner.encodeText`): CRLF passed through with raw newline bytes, reopening the exact remote-shell-exec vector the function was written to close. `"a\r\nb".contains("\n")` is `false` — verified by execution. #security
- [rule] 🚨 **A stdin answer plan for an interactive CLI is a function of HOST STATE, not of the flags alone.** Answers are positional: any prompt that appears conditionally shifts every later line onto the wrong question, and when one of those lines is a bearer token the shift *leaks the secret into a prompt we never meant to answer*. So: enumerate the state-dependent branches from the CLI source, determine each one for real before building the plan, and **refuse with a clear message on any residual uncertainty** — a dialog costs the user a click, a misaligned line costs them a credential. `HermesMCPAdd.HostState` is the shape. #security #cli
- [rule] **A guard that rejects one element must degrade per-element, not per-container.** Decoding `[HermesToolCall]` in one shot turned a per-call-id charset gate into a whole-message guard: one bad id silently dropped every sibling tool call on that turn. Decode element-wise — drop what fails, keep what passes.
- [rule] **A record-boundary token in CLI text output needs three constraints, not one:** the line must START with it (not contain it), sit at the emitter's exact indent, and appear where the emitter actually emits one (here: after a blank line). `webhook list` prints an agent-written `description` raw, so any looser rule lets a description forge an entire subscription record pointing at an endpoint of the forger's choosing. Anything a CLI prints back from user/agent-supplied data is an injection surface for that CLI's own output format. #security
- [rule] **A CLI that exits 0 on failure needs a POSITIVE success sentinel, not the absence of an error.** `webhook subscribe` returns bare on every failure path. The signal is the `Secret:` line every real create prints and no failure path does — cross-checked against the reloaded list. Same class as F3's `mcp add` finding, third instance this cycle.
- [rule] **Withholding a user-supplied secret is correct; withholding it silently is not.** When `mcp add` reuses an existing `.env` key it never prompts, so a token the user typed must not be queued — but they have to be TOLD, or the server keeps authenticating with the old credential and only a manual test reveals it. `Plan.discardedSuppliedToken` carries that up to a notice on the success path (`activeError` is only read on failure — success-path information was being dropped entirely).
- [rule] **A status banner must carry whether it is good news.** Webhooks rendered every message in the success colour, so an honest failure still read as a green tick.

### Gotchas

- [gotcha] The `mcp add` prompt shifts, both verified against `hermes_cli/mcp_config.py` at v2026.8.31: **(1)** `:483-487` an existing server name inserts `Overwrite? [y/N]` **before** the auth stage — and `default=False`, so the confirming `y` is load-bearing; a blank line cancels. **(2)** `:545-548` when `get_env_value(MCP_<NAME>_API_KEY)` hits, the CLI prints "already configured" and never prompts for the key. Scarf can determine both: the server list from config.yaml, and the env key from the process environment the child inherits plus `~/.hermes/.env`, mirroring `get_env_value`'s own order.
- [gotcha] `_env_key_for_server` (`mcp_config.py:153`) runs `re.sub` **per character**, not per run — `a--b` becomes `MCP_A__B_API_KEY`, doubled underscore intact — and `.strip("_")` only trims the ends. Mirrored exactly in `HermesMCPAdd.envKeyForServer`.
- [gotcha] `_cmd_subscribe` **normalizes the name before writing** (lowercased, spaces→hyphens), so any post-create verification must look for the STORED name, not the typed one, or a "Weather Hook" looks absent from its own reload.
- [gotcha] The pre-0.16 Plugins fallback resolved activation with the bare name only, while `_scan_level` recurses one level and keys a nested plugin `<category>/<name>` — `plugins.enabled` may list either form, so anything enabled by registry key rendered `notEnabled` and nested plugins were not listed at all. Its docs also implied CLI parity it never had: **a directory walk sees the USER plugin directory and nothing else.** Bundled plugins live inside the Hermes package (path unresolvable without the CLI) and entry-point plugins are Python packages with no directory whatsoever — no filesystem walk of any kind can find them. The `--json` path is the complete one; the fallback is a documented subset.
- [gotcha] `WKNavigationDelegate` behaves identically on iOS and macOS, so a Mac-only webview policy is a platform gap with no platform reason. The iOS `WebviewWidgetView` twin had neither the https-only URL gate nor a navigation delegate at all. When a fix lands on one of a twinned pair, check the other in the same pass.
- [gotcha] A typed secret in SwiftUI `@State` survives the sheet closing when the form is only reset on the next OPEN — clear it at hand-off (and on cancel), not at reopen.

### Where it lives / tests

`ScarfDesign/ScarfLinkPolicy.swift` (new, shared Mac+iOS). Tests extend the existing suites: `SQLValueInlinerTests` (+8: CRLF, CR-only, CRLF-only, mixed, heredoc breakout, C0/NUL, non-ASCII fast path), `SectionAuditF3CLIContractTests` (+10: MCP host-state shifts, env-key derivation, no-`--` pin, three forged-webhook-record fixtures), `ProjectHermesShadowConsolidationTests` (+2, one of which **executes** the emitted command in a real shell against a pre-existing destination), and a new `ToolCallDecodeDegradationTests` (4). Counts: ScarfCore **1817 tests / 112 suites** green; app target **607 / 78** green. Mac and iOS (`scarf mobile`) both build.

Pre-existing and NOT caused by this package, verified against a clean stash: `scarfUITests` has 2 launch-test failures on baseline, and `M0bTransportTests.serverContextPathsLocalVsRemote` flakes under the parallel full suite (passes 3/3 in isolation) — filed as a follow-up.
