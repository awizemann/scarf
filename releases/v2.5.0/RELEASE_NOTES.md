## What's New in 2.5.0

The big one for 2.5: **ScarfGo, the iPhone companion**, ships in public TestFlight. Same Hermes server you've been running on your Mac — now reachable from your phone over SSH. Dashboard, chat, memory, cron, skills, settings (read), all of it. On the Mac side, the global Sessions list grows up alongside the iOS work — project filter, project badges on each row. **Plus**: full Hermes v2026.4.23 chat parity (`/steer`, per-turn stopwatch, numbered approvals, git branch chip), portable project-scoped slash commands that ship with `.scarftemplate` bundles, in-app Spotify OAuth, and design-md prereq checks.

### ScarfGo iOS companion (public TestFlight)

ScarfGo is a fully native iOS app — not a web view, not a remote desktop. It speaks SSH (Citadel under the hood), reads your Hermes state directly from your Mac (or wherever Hermes is running), and lets you tap a session to resume it from where you left off. Per-project chat works end-to-end: pick a project on your phone, the agent gets the same Scarf-managed `AGENTS.md` context block the Mac writes, and the resulting session shows up correctly attributed in the Dashboard's Sessions tab.

What's in the first public TestFlight build:

- **Multi-server.** Configure as many Hermes hosts as you want, switch between them from a single sidebar-adaptable tab root. Soft disconnect keeps your credentials; "Forget" wipes a server end-to-end (Keychain + UserDefaults).
- **Dashboard.** Stats + the 25 most recent sessions; an Overview tab and a Sessions tab with a project filter Menu.
- **Chat.** Full ACP (Agent Client Protocol) over SSH — streamed responses, tool-call disclosure groups, code blocks with horizontal scroll, "Connecting…" → "Ready" lifecycle, error banner with copy-to-clipboard for non-retryable failures.
- **Project-scoped chat.** "+ In project…" sheet picks from your project registry over SFTP. Writes the Scarf-managed `AGENTS.md` block before spawning `hermes acp` so the agent boots with project context. Records the resulting session ID in the attribution sidecar so the Mac picks it up.
- **Session resume.** Tap any session on the Dashboard → opens Chat with `loadSession`. Older CLI-started sessions hydrate from `state.db`; newer ACP sessions show an empty-state explaining the agent has the context but the local transcript isn't cached.
- **Memory editor.** Read + edit `MEMORY.md` and `USER.md`, with a "Saved" pill that survives keyboard dismissal and a Revert button.
- **Cron list.** Read-only for now, but with **human-readable schedules** ("Every 6 hours", "Weekdays at 09:00") instead of raw `0 */6 * * *`. Mac gets the same formatter.
- **Skills + Settings.** Read-only. Skills shows category structure; Settings shows your `config.yaml` for inspection (no editor in 2.5).
- **iOS 18+.** Dynamic Type clamp at the scene root, sidebar-adaptable TabView, scoped sheet detents, scroll anchoring, content-aware empty states throughout.

**TestFlight invite:** see the [ScarfGo wiki page](https://github.com/awizemann/scarf/wiki/ScarfGo) for the public link + onboarding walkthrough.

### Portable project-scoped slash commands

A net-new Scarf primitive (Hermes has no project-scoped slash command concept — Scarf invents the format and intercepts the chat menu client-side). Author reusable prompt templates as Markdown files at `<project>/.scarf/slash-commands/<name>.md` with YAML frontmatter (name, description, argumentHint, optional model override, tags). Invoke as `/<name> [args]` from chat — Scarf substitutes `{{argument}}` (and `{{argument | default: "..."}}`) in the body and sends the expanded prompt to Hermes; the agent never sees the slash. Works uniformly on Mac + iOS, local + remote SSH, against any Hermes version.

- **Mac authoring tab.** Per-project view gains a Slash Commands tab alongside Dashboard / Site / Sessions. List, add, edit, duplicate, delete; live preview pane shows the expanded prompt with a sample-argument field so authors see exactly what Hermes will receive.
- **iOS read-only browser.** ScarfGo's chat project context bar grows a `<N> slash` chip when the project has slash commands; tap to browse them in a sheet. Multi-line markdown editing is a phone keyboard's nightmare, so v2.5 keeps Mac as the canonical editor; iOS catches up in v2.6+.
- **AGENTS.md block extension.** The Scarf-managed project context block now lists available commands so the agent can answer "what slash commands does this project have?" and recognise the `<!-- scarf-slash:<name> -->` marker prepended to expanded prompts.
- **`.scarftemplate` format extension** (schemaVersion 3). Templates ship slash commands by including `slash-commands/<name>.md` files at the bundle root and listing them in `manifest.contents.slashCommands`. The installer copies them to the project's `.scarf/slash-commands/` dir; the lock file tracks them for clean uninstall (user-authored commands in the same dir survive uninstall).
- **Catalog validator** (`tools/build-catalog.py`) mirrors the Swift verifier. Schema version bumps to 3 only when the bundle ships slash commands; v1/v2 templates stay byte-compatible.

### Hermes v2026.4.23 chat parity

Scarf 2.5 mirrors the chat-surface features Hermes's TUI rewrite shipped this week:

- **`/steer <prompt>`** — non-interruptive mid-run guidance. Surfaces in the slash menu as a special command; sending it doesn't flip the "Agent working…" indicator (the agent's still on its current turn) and shows a transient toast above the composer: "Guidance queued — applies after the next tool call."
- **Per-turn stopwatch** — wall-clock duration of each completed assistant turn renders as a compact pill (`4.2s` / `1m 12s`) on the bubble's metadata footer (Mac) or below the bubble (iOS). Resumed sessions loaded from `state.db` show no pill (timing is captured live only).
- **Numbered keyboard shortcuts on permission sheet** — Mac approval sheet binds 1–9 to the option buttons (visible "1. " / "2. " prefixes). Power users approve / deny without reaching for the mouse. iOS shows the same numbered hints as a hierarchy cue without the keyboard binding.
- **Git branch indicator** — the chat header shows the project's current git branch as a tinted chip alongside the project name (e.g. `📂 myproject · main`). One SSH `git rev-parse --abbrev-ref HEAD` call per session start; nil-out gracefully on non-git dirs / missing git / SSH errors.

### Spotify + design-md skill onboarding

Hermes v2026.4.23 added two new skills. Scarf surfaces them properly:

- **Spotify (`spotify`)** — needs OAuth via `hermes auth spotify`. Mac ships a dedicated Sign-in sheet (mirroring the v2.3 Nous Portal pattern): runs the subprocess, regex-detects the `accounts.spotify.com/authorize?...` URL, auto-opens it in your browser, polls `~/.hermes/auth.json` after subprocess exit to confirm the token landed. Five-state machine (starting → waiting → verifying → success / failure) with retry. iOS surfaces a documentation row noting OAuth needs to happen from Mac or a shell — phone OAuth flows are their own UX problem.
- **design-md (`design-md`)** — requires `npx` (Node.js 18+) on the host. New `SkillPrereqService.probe(binary:)` runs `which npx` over the transport on skill detail appear; on miss, both Mac and iOS render a yellow banner with an install hint (per-OS).

### SKILL.md frontmatter chips

Hermes v2026.4.23 SKILL.md files carry richer YAML frontmatter (`allowed_tools`, `related_skills`, `dependencies`). Scarf parses it on both platforms (Mac via `HermesFileService.parseSkillFrontmatter`, iOS via `IOSSkillsViewModel.parseFrontmatter`) and renders chip rows in the skill detail view. Old skills without these fields stay nil and the rows hide themselves.

### "What's New" pill on Skills tab

Per-server snapshot of `[skillId: signature]` (file count + sorted file names). When the snapshot changes between visits, both Skills views render a tinted pill at the top: "2 new, 4 updated since you last looked." Tap "Mark as seen" to update the snapshot. First-time loads silently prime so users don't see "everything is new!" noise on a fresh install. Persisted to `~/Library/Application Support/com.scarf/skill-snapshots/<serverID>.json` (Mac) / `UserDefaults` (iOS).

### state.db deltas (Hermes v0.11)

- `messages.reasoning_content` — newer richer reasoning channel some providers emit alongside the legacy `reasoning` blob. UI prefers the new column when both are populated (`HermesMessage.preferredReasoning`).
- `sessions.api_call_count` — distinct from `tool_call_count`; counts per-turn API round-trips. Surfaced as the "API" label on Mac SessionDetailView and as a network-icon chip on Mac/iOS Dashboard session rows.

`HermesDataService.hasV011Schema` only flips true when both columns are present (partial migrations stay on the v0.7 path to avoid runtime errors). Older Hermes hosts keep working unchanged.

### `hermes memory reset` toolbar action

New toolbar button on Mac MemoryView — "Reset memory…" with destructive confirmation dialog. Routes through `hermes memory reset --yes`; refreshes the on-screen content on success, surfaces stderr in an alert on failure. Other v0.11 CLIs (`plugins`, `profile`, `webhook`, `insights`, `logs`) are documented in `CLAUDE.md` for future v2.6 adoption — Scarf still reads the underlying files directly today, which keeps working.

### Mac global Sessions: project filter + badges

The per-project Sessions tab shipped in 2.3, but the global Sessions feature still rendered every session as a flat list with no project context. 2.5 closes the gap:

- **Filter Menu** above the list: All projects / Unattributed / one entry per registered project. An xmark button clears the filter; the right side shows "X of Y shown".
- **Project badge** on each row — small tinted folder chip with the project name. Same visual language ScarfGo uses on its Dashboard.
- Logic comes from the same `SessionAttributionService` + `ProjectDashboardService` ScarfGo consumes, both in ScarfCore. Single source of truth across platforms.

### Human-readable cron schedules everywhere

Pre-2.5, both Mac and iOS rendered cron jobs as `0 */6 * * *` raw. The new `CronScheduleFormatter` in ScarfCore translates the common shapes to plain English (every-N-minutes, every-N-hours, daily-at-H, weekdays-at-H, the `@hourly`/`@daily`/`@weekly`/`@monthly` macros) and falls back to the raw expression for anything custom. Both apps consume it.

### Under the hood

- **Shared services.** `SessionAttributionService`, `ProjectContextBlock`, and `CronScheduleFormatter` moved into ScarfCore; both apps consume them via their respective transports (`SSHTransport` on Mac, `CitadelServerTransport` on iOS).
- **`RichChatViewModel`** carries the ACP error triplet (`acpError`, `acpErrorHint`, `acpErrorDetails`) for both platforms — Mac's `ChatViewModel` now delegates instead of duplicating.
- **Test reliability.** Cross-suite races on `ServerContext.sshTransportFactory` resolved by consolidating every factory-touching test into a single `.serialized` suite. 163 tests across 12 suites, three consecutive green runs.
- **Surface silent failures.** Several `try?` swallows in iOS lifecycle code now surface to the user — Keychain unlock errors no longer dump people back into onboarding, partial Forget operations report what failed, project-context-block writes that fail surface a banner instead of silently degrading agent context.
- **iOS exec channel hardening.** `CitadelServerTransport.runProcess` was wrapping Citadel's `executeCommand`, which throws `CommandFailed` on non-zero exit and discards the captured stdout buffer in the throw path. `hermes skills browse` happens to print its full table and *then* exit non-zero on some hosts, so iOS got nothing while Mac (Foundation `Process`) got the full output with `exitCode=1`. v2.5 drives `executeCommandStream` directly, drains stdout + stderr regardless of outcome, and recovers the actual exit code from the `CommandFailed` catch. Same channel now also inline-prepends `PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"` on every invocation — Citadel's raw exec channel doesn't source the user's shell rc files, so non-interactive sessions land with a stripped `PATH` (`/usr/bin:/bin`) and pipx's default install dir is invisible. Mac's OpenSSH sshd handles this transparently; we now match.
- **fd-leak cleanup.** `LocalTransport` / `SSHTransport` / `ProcessACPChannel` all close the parent's copy of every pipe write end after spawn so EOF reaches the reader once the child exits, plus close read ends after draining. Was leaking one fd per `runProcess` / `streamLines` / ACP turn under load.
- **Status-poll backoff.** `ServerLiveStatus` now uses 10s → 30s → 60s → 120s → 300s exponential backoff on consecutive probe failures, resetting on the first full success. Previously a registered remote going unreachable hammered `pgrep` + `gateway_state.json` every 10s indefinitely; offline servers now settle to a 5-minute cadence while live ones stay snappy.
- **Logger conversion.** Remaining `print("[Scarf] …")` debug statements in `HermesDataService`, `HermesLogService`, and `ProjectDashboardService` swap to `os.Logger` calls (subsystem `com.scarf`), matching the global rule that production code uses `Logger` and `print()` is reserved for previews + test helpers.

### Notes for users running 2.3

No data migrations needed. Server configs, Keychain entries, project registries, session attribution sidecar — all forward-compatible. The only invariant change is iOS-only: `ScarfGo.servers.v1` UserDefaults key migrates to `com.scarf.ios.servers.v2` on first launch, and Keychain accounts move from `"primary"` to `"server-key:<UUID>"`. One-shot, idempotent — re-running 2.3 after 2.5 ran would just see the v2 data.

Push notifications stay disabled in this build. The skeleton (NotificationRouter, category registration, action handlers) is in place behind `apnsEnabled = false` for when Hermes ships a push sender + we get an APNs cert.
