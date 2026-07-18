<p align="center">
  <img src="icon-v2.5.png" width="128" height="128" alt="Scarf app icon">
</p>

<h1 align="center">Scarf</h1>

<p align="center">
  A native macOS companion app for the <a href="https://github.com/hermes-ai/hermes-agent">Hermes AI agent</a>.<br>
  Full visibility into what Hermes is doing, when, and what it creates.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.6+%20Sonoma-blue" alt="macOS">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
  <br>
  <em>Available in English, 简体中文, Deutsch, Français, Español, 日本語, and Português (Brasil).</em>
  <br><br>
  <a href="https://www.buymeacoffee.com/awizemann"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" height="28"></a>
</p>

## What's New in 2.17.1

**"Export…" now always means "save to my Mac."** Session and profile exports land on your Mac whichever host Hermes runs on — no more silent no-ops or typing remote paths by hand. Every fix in this release came from community-filed issues.

- **Session export works against remote servers** — it used to do nothing at all (no file, no error): the save panel's Mac path was handed to a CLI running on the far host. Scarf now pipes the export back over stdout and writes it where you chose. Fixed by [@JonLaliberte](https://github.com/JonLaliberte) ([#129](https://github.com/awizemann/scarf/issues/129), [PR #130](https://github.com/awizemann/scarf/pull/130)) — their second merged contribution. 🎉 Also fixes the detail-sheet export button and the panel rewriting `.jsonl` to `.json`.
- **Profile export streams down to your Mac** ([#132](https://github.com/awizemann/scarf/issues/132)) — no more remote-path text field, no more knowing the host's directories by heart; a ~300 MB profile streams down without passing through memory, with progress. That also retires the "Verify" that green-lit paths whose parent directory didn't exist ([#131](https://github.com/awizemann/scarf/issues/131)).
- **Failures are readable** — CLI errors now surface the traceback's last line (the actual error), and successful exports name the byte count.

See the full [v2.17.1 release notes](https://github.com/awizemann/scarf/releases/tag/v2.17.1). A ScarfGo TestFlight build follows, carrying the Docker config-diagnosis work from [#112](https://github.com/awizemann/scarf/issues/112).

## What's New in 2.17.0

**Local models.** Scarf now runs against Ollama, LM Studio, vLLM, llama.cpp, or any OpenAI-compatible endpoint — plus a chat-reliability overhaul and a settings fix. Fully compatible with your current Hermes; no version bump required.

- **Run a model on your own hardware** — a new **Remote | Local** filter in the model picker. Scarf discovers what's actually installed on the daemon (local *or* a remote server's, over SSH), shows each model's size and quantization, and **blocks models under Hermes's 64K context minimum** in the picker with a plain explanation — so you find out before you pick, not via a cryptic chat-time error. Attach an image to a model that can't see images and Scarf warns you in the composer.
- **Chats that don't silently stall** — four long-standing session bugs fixed: phantom sessions that swallowed your next message, a "deaf transcript" that ran a reply invisibly, a spinner that could wedge the UI restart-only, and mid-turn cleanup that orphaned the process on session switch/delete.
- **Dropdowns that remember your choice** — Web Tools backends and some Advanced controls saved but reloaded blank; a drifted duplicate config parser was the cause. Deleted it (one parser everywhere) and added a CI gate so it can't recur.
- **"Choose model…" on the mismatch banner** — a one-click path to the full picker whenever your model and provider don't line up.

Local-model note: on Hermes before 0.18, auxiliary features (auto titles, compression, vision routing) don't yet recognize local providers and degrade — your main chat works; the upstream fix is filed. See the full [v2.17.0 release notes](https://github.com/awizemann/scarf/releases/tag/v2.17.0). No new ScarfGo build needed.

## What's New in 2.16.2

Remote windows can now view any Hermes profile — and it's Scarf's first merged community contribution, from [@JonLaliberte](https://github.com/JonLaliberte). 🎉

- **View any profile on a remote server** — "View this profile" re-points a remote window at that profile's data (Sessions, Memory, Cron, and Chat all reload) *without* changing the server's `active_profile` — what the agent, cron, and terminal keep using. A `viewing:` sidebar chip shows the window's scope, and the host-mutating switch is relabeled "Set as server's active profile" so the two can't be confused. ([#126](https://github.com/awizemann/scarf/issues/126), [PR #127](https://github.com/awizemann/scarf/pull/127))
- **Actions follow the viewing profile too** — every remote `hermes` invocation (chat, cron runs, config edits, backups) now carries the viewed profile's `HERMES_HOME`, matching what the window shows; with no viewing profile selected, commands are byte-identical to 2.16.1.

See the full [v2.16.2 release notes](https://github.com/awizemann/scarf/releases/tag/v2.16.2). No new ScarfGo build needed — iOS behavior is unchanged.

## What's New in 2.16.1

A focused connection-reliability patch.

- **Remotes heal themselves** — a remote that "stopped working after a while" was a dead SSH ControlMaster holding its socket: every subsequent ssh hung on the corpse, and only removing and re-adding the server reset it. Scarf now probes the master on chat failures, before reconnect attempts, and on wake from sleep — resetting only provably dead connections, so a plain retry just works. ([#123](https://github.com/awizemann/scarf/issues/123))
- **Hermes-in-Docker configs are readable** — when `~/.hermes` lives inside a container, config reads now fall back through the Hermes CLI wrapper (`config path`, then a `config show` probe), so the chat preflight stops demanding a model that's already configured and Settings explains the bind-mount fix instead of "not found". Ships to ScarfGo with the next TestFlight build. ([#112](https://github.com/awizemann/scarf/issues/112))

See the full [v2.16.1 release notes](https://github.com/awizemann/scarf/releases/tag/v2.16.1).

## What's New in 2.16.0

Scarf now targets the **Hermes v0.18 line** — audited against v0.18.0 (v2026.7.1) and re-audited against the v0.18.1/v0.18.2 patches — and the audits fixed long-standing bugs along the way.

- **Search stays in lockstep with v0.18 in-place compaction** — Hermes v0.18 can compact a session in place, soft-archiving the summarized messages while keeping them searchable. Scarf detects the new `messages.compacted` column and widens search to match Hermes exactly; `/undo`-rewound rows stay hidden, and the chat transcript still shows only the live conversation.
- **The Web Tools tab actually works now** — it had been writing `web_tools.*` config keys Hermes never reads (the real block is `web.*`), so every backend choice was a silent no-op. Both the write and read sides now use the real keys; if you'd set backends before, re-pick them once.
- **Cron jobs round-trip losslessly** — editing a job in ScarfGo used to rebuild it from an incomplete model, silently stripping repeat counts, per-job tool restrictions, provider routing, and (new in v0.18.2) the scheduler's `run_claim` double-execution guard. Scarf now preserves every key it doesn't model, so future Hermes job fields can never be stripped again — and the pre-run script + cron expression now use the keys Hermes actually reads (`script`, `expr`).
- **No false mismatch banner on custom endpoints** — `custom`/`custom:*` providers serve their own model namespace, so a slash in the model ID no longer triggers the "model/provider mismatch" banner (same class as 2.15.1's aggregator fix, [#121](https://github.com/awizemann/scarf/issues/121)).
- **New providers:** MoA (Mixture of Agents — Hermes's multi-advisor virtual provider, no credentials needed) joins the picker; Google Vertex AI replaces the retired Gemini CLI OAuth provider.
- **Under the hood:** full eight-surface audit against the tagged v0.18.0 source, repeated against the v0.18.2 rollup (~712 commits) — ACP wire, CLI verbs, config keys, state.db columns, and gateway platforms all verified stable; provider tables pass the mechanical sync gate against both tags; 18 new tests, 799/799 green.

See the full [v2.16.0 release notes](https://github.com/awizemann/scarf/releases/tag/v2.16.0).

## What's New in 2.15.1

A focused patch for anyone running Hermes on an **aggregator provider** (OpenRouter, OpenCode, KiloCode, Hugging Face, NovitaAI).

- **No more false "Model/provider mismatch" banner on aggregator configs** — OpenRouter model IDs like `xiaomi/mimo-v2.5` are `org/model` namespaced, and Scarf's preflight misread the slash as a stale provider prefix; both of the banner's one-click "fixes" would have broken a working `config.yaml`. The check now skips aggregators (including Hermes's bare-`openai` → OpenRouter alias). ([#121](https://github.com/awizemann/scarf/issues/121))
- **The banner's fix buttons are validated** — alias-equivalent prefixes (`claude/…` vs `anthropic`, `x-ai/…` vs `xai`) no longer read as mismatches, and a prefix that isn't any provider Hermes knows can no longer be written into `config.yaml`; the genuine stale-prefix protection is unchanged.
- **Under the hood:** Scarf's hand-mirrored Hermes provider tables are now gated by a mechanical sync check (`scripts/check-hermes-tables.py`), verified against the exact Hermes v0.16.0 tag.

See the full [v2.15.1 release notes](https://github.com/awizemann/scarf/releases/tag/v2.15.1).

## What's New in 2.15.0

**Projects grow up** — the biggest Projects update since v2.3. A project becomes a first-class object with its own mission-control pane, and gains three new powers. (Skips 2.14; this is a feature release, not a Hermes-compat one.)

- **Mini-apps** — sandboxed web panels (plain HTML/CSS/JS) that live inside a project and can drive your agent. They run in a locked-down `WKWebView` (no network, scoped assets, symlink-contained file reads) with **default-deny permissions you review on first open**. A mini-app's `scarf.prompt(...)` gets its own isolated, rate-limited `hermes acp` session — it can't reach your chats. Build one with the `scarf-miniapp-author` skill, or have **Upgrade Project** generate a starter. (v1 wires the read + prompt surfaces; `kanban:write` / `file:write` / `net` are declared but not yet enabled.)
- **Fleet & Portfolio** — run the same repo on more than one machine and Scarf groups them as **one logical project**, flags config **drift** across hosts, and lets you **Apply to Fleet** to push a host's model preset, board, and cron jobs to the others (per-host, non-fatal, version-gated).
- **One-click Upgrade Project** — bring an existing repo up to the full experience: a fast idempotent structural pass (stable id, board, AGENTS.md block, dashboard) then an agent hand-off that tailors a dashboard, slash commands, cron, and a starter mini-app.
- **The cockpit** — selecting a project opens one unified pane with everything about it: Dashboard, Sessions, Board, Site, Context, Cron, Memory, Secrets, Templates, Slash, Mini-apps, and Fleet.
- **Project chats load your AGENTS.md** — opening a chat in a project now spawns Hermes with the project as its cwd, so the agent gets the project's `AGENTS.md` / `CLAUDE.md` / `.cursorrules` automatically (new, resumed, and reconnected chats). Treat a project's context files like its code — only open chats in projects you trust.
- **Hardening:** remote SSH paths escaped against command injection; window size/position persists again.

See the full [v2.15.0 release notes](https://github.com/awizemann/scarf/releases/tag/v2.15.0).

## What's New in 2.13.0

ScarfGo — the iOS companion — gets **Hermes profile switching**, plus a remote-chat/Settings reliability fix that anyone running ScarfGo over SSH will feel. The shared-core pieces ride into the Mac app too.

- **Switch Hermes profiles from ScarfGo** — pick a profile and ScarfGo points its chat, memory, cron, sessions, gateway, and every `hermes` call at that profile for the selected server. It uses per-connection scoping and **never runs `hermes profile use`**, so it doesn't touch the host's `active_profile` — your Mac, terminal, cron, and running gateway keep their own profile. (Create / rename / delete / import / export stay Mac-only.) ([#120](https://github.com/awizemann/scarf/issues/120))
- **Reliable remote chat & Settings on iOS** — fixes "Couldn't save model.provider … Transport refused" and empty Settings on a valid host. ScarfGo was opening a new SSH connection per read / CLI call; under a Settings-load or chat-init burst the handshake itself failed. It now pools one connection per server and coalesces concurrent opens (verified against a live sshd: a 24-way burst went from 20/24 connection failures to 0). ([#112](https://github.com/awizemann/scarf/issues/112))
- **Skills "What's New" tracks per profile** — the pill no longer shows bogus "new / changed" counts after a profile switch; the baseline is now keyed per (server, profile).

See the full [v2.13.0 release notes](https://github.com/awizemann/scarf/releases/tag/v2.13.0).

## What's New in 2.12.0

A coordinated catch-up to **Hermes v0.17.0 (2026.6.19)** — the largest Hermes release yet, though Scarf needed only a focused slice — plus a remote-chat performance fix everyone on SSH will feel. Every new v0.17 surface is capability-gated, so pre-v0.17 hosts render byte-identical to v2.11.0; all flag/config/wire shapes were verified against the live v0.17 source.

- **Remote chat is responsive again** — typing into a session on a remote (SSH) host no longer lags or spikes CPU. Watcher-driven reads (credential preflight, sessions list, platforms, projects) that were doing synchronous SSH round-trips on the main thread per message now run off-main with cancel-prior + recency guards. ([#119](https://github.com/awizemann/scarf/issues/119))
- **Four broken Health/Settings actions fixed** — surfaced by the v0.17 audit: "Run supply-chain audit" (`hermes audit` → `security audit`), xAI model migration (was dry-run only — now `--apply`), browser-tools setup (`--assume-yes` → `--yes`), and the no-op WhatsApp recipient allowlist (removed). Failed config saves now show the real reason.
- **Curator "Prune" → "Archive idle skills"** — the old action claimed to delete archived skills from disk, but the real verb *archives idle active skills* (reversibly) and Scarf was invoking it wrong (it would hang). Rebuilt to match: a day-threshold picker, an idle-skill preview, and a correctly reversible confirm.
- **New gateway platforms** — WhatsApp Business **Cloud** API (Meta-hosted, distinct from the QR web bridge) gets a full credential form, and **SimpleX** finally gets a setup form (it had no UI since v0.14).
- **More v0.17 surfaces** — Telegram rich messages (Bot API 10.1) + online/offline status toggles; a curator-consolidation toggle (v0.17 made the LLM merge pass opt-in); and a max-concurrent-sessions cap.
- **Under the hood:** v0.17 required **zero** mandatory compatibility changes (schema, ACP, CLI, config, catalog all stable — verified against source), so this is a feature catch-up plus pre-existing-bug fixes; new capability flags + `isV017OrLater`; an adversarial fresh-eyes audit of the branch caught a real bug pre-release; 642 ScarfCore tests.

See the full [v2.12.0 release notes](https://github.com/awizemann/scarf/releases/tag/v2.12.0).

## What's New in 2.11.0

A coordinated catch-up to **Hermes v0.16.0 (2026.6.5)**, headlined by a correctness fix for the first `state.db` schema change since v0.11. Every new surface is capability-gated or schema-detected, so pre-v0.16 hosts render byte-identical to v2.10.3.

- **Rewound messages are hidden (the schema change)** — v0.16 soft-deletes messages when you `/undo` a conversation (a new `messages.active` column). Scarf now filters them out on every read path, schema-gated so older hosts don't error, so a rewound chat shows you what the agent actually sees instead of discarded messages.
- **Live session titles** — Scarf updates a session's name in the Mac sidebar in place when Hermes (re)generates it, via the new ACP `session_info_update` notification.
- **"Rewound ×N" badge** — sessions schema-detect the new `sessions.rewind_count` column and flag heavily-edited sessions in the sidebar, the Sessions table, and the dashboard.
- **Spotify sign-in moved to Plugins** — Spotify became a built-in tool/plugin in v0.16, so its sign-in affordance now lives in the Plugins view on v0.16 hosts (kept in Skills for older ones).
- **Two gateway-config bugs fixed** — platform allowlists were written to the wrong YAML location and silently never applied (now top-level `slack.allowed_channels` etc., DingTalk corrected to `allowed_chats`); and the cross-profile gateway digest, which assumed a non-existent `--json` flag, now parses the text output and shows up again.
- **v0.16 quick wins** — an "Optimize sessions database" Health action (`hermes sessions optimize`), a Kanban "Goal · N" pill, and capability-gated session rename.
- **Under the hood:** config-shape corrections verified against the live v0.16 source (OpenRouter response-cache scalar so a *disable* takes effect, MCP SSE add path, dead Kanban `verify` verb removed, ACP `/goal`/`/subgoal` de-advertised as gateway-only); AWS Bedrock registered + new providers/models flow automatically; new v0.16 capability flags + `isV016OrLater`; 628 ScarfCore tests.

See the full [v2.11.0 release notes](https://github.com/awizemann/scarf/releases/tag/v2.11.0).

## What's New in 2.10.3

A reliability and polish release on top of v2.10.1/v2.10.2, headlined by a fix for the **100% single-core CPU spin** on large `state.db` files, plus a broad performance + correctness sweep from a full code audit.

- **100% CPU fix (gh#102)** — the Dashboard no longer closes + reopens the SQLite handle on every file-change tick; on a large `state.db` + uncheckpointed WAL that close+reopen was the whole cost. The read-only handle now stays open and sees Hermes's writes transparently.
- **Menu-bar stopped flashing every 10s (gh#105)** — `ServerLiveStatus` only republishes `@Observable` state when the value actually changes, so unchanging healthy polls no longer re-render the status chrome.
- **Reasoning visible again on resumed thinking-model chats** — the REASONING disclosure reappears on resume (including the newest models that store only `reasoning_content`) and lazy-loads the chain-of-thought on open, keeping the fast two-phase loader's speed.
- **Snappier sidebar navigation** — switching sections no longer re-runs each feature's remote `load()` over SSH; panes keep their data + state across switches and refresh only on real file changes or Reload.
- **Self-diagnostic Docker config errors (gh#112)** — a failed `hermes config set` now surfaces the wrapper's real exit code + stderr instead of a generic "Couldn't save."
- Plus loading overlays on more panes, standard menu commands (⌘, Settings, Help menu, ⌘F search), a backgrounded-poll throttle, cron-corruption warnings, and chat-streaming polish.
- **Under the hood:** zero compiler warnings across the macOS app, iOS app, and ScarfCore package (full Swift 6 strict-concurrency cleanup); a parallel-safe 613-test suite that no longer touches your real `~/.hermes`; and a Sparkle release-key safeguard.

This release also carries v2.10.2's ACP permission-prompt fix ("Allow Once" / "Allow For Session" now reach Hermes correctly). See the full [v2.10.3 release notes](https://github.com/awizemann/scarf/releases/tag/v2.10.3).

## What's New in 2.10.1

A "projects fundamentals" maintenance release on top of v2.10.0. Six interlocking fixes from user feedback:

- **Global `/scarf-*` slash commands** — six bundled commands (`scarf-new`, `scarf-help`, `scarf-dashboard`, `scarf-widget`, `scarf-cron`, `scarf-export`) available in every chat, not just per-project. Loaded from `~/.hermes/scarf/slash-commands/` and bootstrapped on launch with the same version-gated upgrade pattern as bundled skills.
- **Skills sidebar finally shows `scarf-template-author`** — `SkillBootstrapService` installs into `~/.hermes/skills/scarf/` (matching `SkillsScanner`'s `<category>/<skill>/SKILL.md` layout) and auto-migrates the old flat install. One-time migration runs at first launch.
- **Pre-session slash menu** — typing `/` before opening a chat now shows the full agent-command set greyed-out (`"Available once a chat is open"`) instead of collapsing to just `/new`.
- **New-project wizard hand-off** — kickoff prompt rewritten with `SKILL:` / `PROJECT_PATH:` anchors that agents reliably treat as invocation markers (vs. the polite "use the skill" sentence agents routinely ignored). Skill-presence preflight in `commit()` guarantees the bundled skill is on disk before `session/new`.
- **AGENTS.md `scarf-project` block: Scarf platform reference** — the managed block now describes Scarf's dashboard widget vocabulary, project slash commands, Kanban tenant, model presets, typed config, cron `--workdir`, skill loading, and template export. Idempotent + secret-safe + capped to ~30 lines. Now refreshed on template install too (previously chat-start only).
- **Health: capabilities diagnostic panel** — raw `hermes --version` line, parsed semver/date, per-release flag list, and a Re-detect button. Capabilities auto-refresh on `NSApplication.didBecomeActive` so `hermes update` outside Scarf is picked up without a relaunch.

See the full [v2.10.1 release notes](https://github.com/awizemann/scarf/releases/tag/v2.10.1).

## What's New in 2.10

A coordinated catch-up to **Hermes v0.15.0** ("The Velocity Release"). v2.10 surfaces the Scarf-relevant slice of the largest Hermes release yet — OpenAI as a first-class provider, the 104-PR **Kanban maturation wave**, **Bitwarden Secrets Manager**, **MCP mTLS**, **skill bundles**, **per-session edit-approval modes**, plus ntfy, xAI Web Search, and the xAI model-retirement migration. New v0.15 capability flags gate every surface; pre-v0.15 hosts render byte-identical to v2.9.x. (All flag/config/wire shapes were verified against the `v2026.5.28` Hermes source before implementation.)

### Providers & models

- **OpenAI as a first-class provider** — wire ID `openai-api`, distinct from the OpenAI Codex runtime, in the Models picker. (Bare `openai` stays a Hermes alias to OpenRouter, so it isn't registered separately.)
- **Krea image generation** — `krea-2-medium` / `krea-2-large` join the image-gen model list.
- **xAI May-15 model retirement** — retired Grok IDs (`grok-4-0709`, `grok-4-fast-*`, `grok-3`, `grok-code-fast-1`, …) resolve forward to `grok-4.3` so a stored retired model still works, and the Health view warns + offers one-click `hermes migrate xai`.
- **Vercel removed** — Vercel AI Gateway (provider) and Vercel Sandbox (terminal backend) were deleted upstream in v0.15 and are dropped from Scarf's pickers.

### Kanban — the v0.15 maturation wave

- Server-side **sort** (priority / created / status / assignee / title / updated) from the board header.
- **Promote**, **Schedule / Park**, and **Delete-permanently** (`archive --rm`) card actions; new **Scheduled** and **Review** columns (collapse when empty).
- Per-task worktree **`--branch`** on create + a read-only **model-override** line in the inspector; `--board` multi-board plumbing in the service layer.
- **Precise chat-scoped board** — the chat-header Kanban chip and the board it opens now filter by the originating ACP `session_id` (stamped automatically by Hermes), replacing the old tenant + time-window approximation, with a "This chat ⇄ All tasks" scope toggle.

### Bitwarden Secrets Manager

- New **Settings → Secrets** tab for the `secrets.bitwarden.*` block — one bootstrap token (`BWS_ACCESS_TOKEN` in `~/.hermes/.env`) replaces per-provider API keys. EU Cloud / self-hosted server URLs supported.

### MCP mTLS + catalog

- **mTLS client certificates** (`client_cert` / `client_key` / `ssl_verify`) for HTTP + SSE MCP servers, in the server editor.
- A read-only **`hermes mcp catalog`** browse sheet for the Nous-approved MCP catalog.

### Skill bundles

- A read-only **Bundles** tab listing the named skill groups in `~/.hermes/skill-bundles/*.yaml` — each loadable in Hermes via one `/<name>` slash command — with each bundle's member skills and instruction.

### Per-session edit-approval modes

- A chat-header chip toggles a live session between **Default** (ask before edits), **Accept Edits** (auto-allow workspace + `/tmp`), and **Don't Ask** via ACP `session/set_mode`. Distinct from the global `approvals.mode` / YOLO surface; sensitive paths always still prompt.

### ntfy, xAI Web Search + more

- **ntfy** as the **23rd gateway platform** (push notifications via a topic URL, no account), plus new per-platform toggles (Telegram `disable_topic_auto_rename` / `ignore_root_dm`, Discord `allow_any_attachment`, Signal group-only `require_mention`).
- **xAI Web Search** as a `web_tools.search.backend` option (reuses your Grok OAuth / `XAI_API_KEY`), and an opt-in **xAI TTS `auto_speech_tags`** toggle.
- **Supply-chain audit** — a "Run supply-chain audit" button on the Health view runs `hermes audit` (OSV.dev) and shows the result inline.

See the full [v2.10.0 release notes](https://github.com/awizemann/scarf/releases/tag/v2.10.0) for the complete list, including the pre-release review fixes and the v2.9 highlights (Hermes v0.14 catch-up: `/subgoal` + `/yolo` + `/sessions` + `/codex-runtime` slash commands, xAI Grok OAuth + NovitaAI providers, LINE + SimpleX Chat platforms, Brave Search + DuckDuckGo backends, the Hermes Proxy local server) which are all still in play.

**Previous releases:** see the [Release Notes Index](https://github.com/awizemann/scarf/wiki/Release-Notes-Index) on the wiki for v2.7, v2.6, v2.5, v2.3, v2.2, v2.0, v1.6, and earlier.

## ScarfGo — the iPhone companion

Same Hermes server you've been running on your Mac — reachable from your phone over SSH. Multi-server, project-scoped chat, session resume, memory editor, cron list, skills tree, settings (read), all native iOS. Pure-Swift SSH (Citadel under the hood — no `ssh` binary needed on iOS). Per-project chat writes the same Scarf-managed `AGENTS.md` block the Mac app does, so the agent boots with the same project context regardless of which client opened the session.

**[Join the public TestFlight](https://testflight.apple.com/join/qCrRpcTz)** — the link is live now but only accepts new beta testers once Apple's Beta Review approves the first build. If you hit a "not accepting testers" splash, bookmark it and try again in 24–48h.

<p align="center">
  <a href="assets/screenshots/scarfgo-servers.png"><img src="assets/screenshots/scarfgo-servers.png" alt="ScarfGo — Servers list" width="140"></a>
  <a href="assets/screenshots/scarfgo-chat.png"><img src="assets/screenshots/scarfgo-chat.png" alt="ScarfGo — Chat with Hermes" width="140"></a>
  <a href="assets/screenshots/scarfgo-project-dashboard.png"><img src="assets/screenshots/scarfgo-project-dashboard.png" alt="ScarfGo — Project dashboard" width="140"></a>
  <a href="assets/screenshots/scarfgo-skills.png"><img src="assets/screenshots/scarfgo-skills.png" alt="ScarfGo — Skills browser" width="140"></a>
  <a href="assets/screenshots/scarfgo-system.png"><img src="assets/screenshots/scarfgo-system.png" alt="ScarfGo — System tab" width="140"></a>
</p>

<p align="center"><sub><em>Tap any thumbnail to view full size. Servers list · Chat · Project dashboard (Site Status Checker template) · Skills browser · System tab.</em></sub></p>

See the [ScarfGo wiki page](https://github.com/awizemann/scarf/wiki/ScarfGo) for the full feature tour, [ScarfGo Onboarding](https://github.com/awizemann/scarf/wiki/ScarfGo-Onboarding) for the SSH-key setup walkthrough, and [Platform Differences](https://github.com/awizemann/scarf/wiki/Platform-Differences) for what is and isn't shared between Mac and iOS.

## Connect ScarfGo to your Hermes server

ScarfGo speaks SSH directly — no companion service, no developer-controlled server in between. Onboarding takes about a minute:

1. **Install via TestFlight.** Open the [public TestFlight link](https://testflight.apple.com/join/qCrRpcTz) on your phone, accept the invite, install ScarfGo from TestFlight (just like any other beta).
2. **Tap Add Server.** Enter the host (IP or DNS), SSH user, port (default 22), and an optional nickname. Same details you'd type into `ssh user@host`.
3. **Generate Key.** ScarfGo creates a fresh Ed25519 keypair on the device. The private half lives in the iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and is excluded from iCloud sync — it never leaves the phone.
4. **Add the public key to your Hermes host.** Tap **Copy public key**, then on the host run:
   ```bash
   cat >> ~/.ssh/authorized_keys <<'EOF'
   <paste the line ScarfGo showed you>
   EOF
   chmod 600 ~/.ssh/authorized_keys
   ```
   This is its own line per device — the convention any second SSH client uses. Mac (Scarf) keeps using your existing ssh-agent / `~/.ssh/config` and is unaffected.
5. **Tap Test connection.** ScarfGo opens an SSH session, probes for the `hermes` binary, and saves the server on success. If it can't find `hermes`, see the [troubleshooting section](https://github.com/awizemann/scarf/wiki/ScarfGo-Onboarding#troubleshooting) — it's almost always a `PATH` quirk on non-interactive SSH.

Done. Open the Dashboard tab and tap any session to resume it; tap the **+** in Chat to start a new project-scoped session.

## Multi-server, one window per server

Scarf 2.0 is a multi-window app. Each window is bound to exactly one Hermes server — your local `~/.hermes/` is synthesized automatically, and you can add remotes via **File → Open Server…** → **Add Server** (host, user, port, optional identity file). Open a second window for a different server and the two run side-by-side with independent state.

Remote Hermes is reached over system SSH — the same `~/.ssh/config`, ssh-agent, ProxyJump, and ControlMaster pooling your terminal uses. File I/O flows through `scp`/`sftp`; SQLite is served from atomic `sqlite3 .backup` snapshots cached under `~/Library/Caches/scarf/snapshots/<server-id>/`; chat (ACP) tunnels as `ssh -T host -- hermes acp` with JSON-RPC over stdio end-to-end. Everything in the feature list below works against remote identically to local.

### Remote setup requirements

The remote host must have:

1. **SSH access** — key-based auth via your local ssh-agent. Scarf never prompts for passphrases; run `ssh-add` once in Terminal before connecting.
2. **`sqlite3`** on the remote `$PATH` — needed for the atomic DB snapshots. Install on the remote with `apt install sqlite3` (Ubuntu/Debian), `yum install sqlite` (RHEL/Fedora), or `apk add sqlite` (Alpine).
3. **`pgrep`** on the remote `$PATH` — used by the Dashboard "is Hermes running" check. Standard on every distro; install `procps` if missing.
4. **`~/.hermes/` readable by the SSH user**. When Hermes runs as a separate user (systemd service, Docker container), the SSH user needs read access to `config.yaml` and `state.db`. Either (a) SSH as the Hermes user, (b) `chmod` Hermes's home to be group-readable and add your SSH user to that group, or (c) set the **Hermes data directory** field when adding the server to point at the right location (e.g. `/var/lib/hermes/.hermes`).

### Troubleshooting remote connections

If the connection pill is green but the Dashboard shows "Stopped", "unknown", or empty values, the SSH user can't read the Hermes state files. Open **Manage Servers → 🩺 Run Diagnostics** (or click the yellow "Can't read Hermes state" pill in the toolbar). The diagnostics sheet runs fourteen checks in one SSH session — connectivity, `sqlite3` presence, read access to `config.yaml` and `state.db`, the effective non-login `$PATH` — and tells you exactly which one fails and why, with remediation hints for each. Use the **Copy Full Report** button to paste the full output into a bug report.

For the common "Hermes isn't at the default path" case (systemd services, Docker), **Test Connection** in the Add Server sheet now probes `/var/lib/hermes/.hermes`, `/opt/hermes/.hermes`, `/home/hermes/.hermes`, and `/root/.hermes` when it can't find `state.db` at `~/.hermes/`, and offers a one-click fill if it finds any of them.

## Features

Scarf mirrors Hermes's surface area through a sidebar-based UI. Sections below map 1:1 to the app's sidebar.

### Monitor

- **Dashboard** — System health, token usage, cost tracking, recent sessions with live refresh
- **Insights** — Usage analytics with token breakdown (including reasoning tokens), cost tracking, model/platform stats, top tools bar chart, activity heatmaps, notable sessions, and time period filtering (7/30/90 days or all time)
- **Sessions Browser** — Full conversation history with message rendering, model reasoning/thinking display, tool call inspection, full-text search, rename, delete, and JSONL export. Subagent sessions are filtered from the main list and accessible via parent session drill-down
- **Activity Feed** — Recent tool execution log with filtering by kind and session, detail inspector with pretty-printed arguments and tool output display

### Interact

- **Live Chat** — Two modes: **Rich Chat** streams responses in real-time via the Agent Client Protocol (ACP) with iMessage-style bubbles, markdown rendering, tool call visualization, thinking/reasoning display, permission request dialogs, and a one-click `/compress` focus sheet (when Hermes advertises the command); **Terminal** runs `hermes chat` with full ANSI color and Rich formatting via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). Both modes support session persistence, resume/continue previous sessions, auto-reconnection with session recovery, and voice mode controls
- **Memory Viewer/Editor** — View and edit Hermes's MEMORY.md and USER.md with live file-watcher refresh, external memory provider awareness (Honcho, Supermemory, etc.), and profile-scoped memory support with profile picker
- **Skills Browser** — Browse installed skills by category with file content viewer and required config warnings. **New in 1.6:** Browse the Skills Hub, search by registry (official, skills.sh, well-known, GitHub, ClawHub, LobeHub), install, check for updates, and uninstall — all from the app

### Configure *(new in 1.6)*

- **Platforms** — Native GUI setup for all 13 messaging platforms (Telegram, Discord, Slack, WhatsApp, Signal, Email, Matrix, Mattermost, Feishu, iMessage, Home Assistant, Webhook, CLI). Per-platform forms write credentials to `~/.hermes/.env` and behavior toggles to `~/.hermes/config.yaml`. WhatsApp and Signal pairing use an inline SwiftTerm terminal for QR scan and signal-cli daemon management
- **Personalities** — List defined personalities, pick the active one, and edit `SOUL.md` inline with markdown preview
- **Quick Commands** — Editor for custom `/command_name` shell shortcuts with dangerous-pattern detection (`rm -rf`, `mkfs`, etc.)
- **Credential Pools** — Per-provider credential rotation with a fixed OAuth flow (URL extraction + browser open + code paste) and proper `--type api-key` handling. API keys never stored in UI state — only last-4 preview. Strategy picker (fill_first / round_robin / least_used / random)
- **Plugins** — Install via Git URL or `owner/repo`, update, remove, enable/disable. Reads `~/.hermes/plugins/` directly for reliable state
- **Webhooks** — Create, list, test-fire, and remove webhook subscriptions. Detects the "platform not enabled" state and links to gateway setup
- **Profiles** — Switch between multiple isolated Hermes instances. Create, rename, delete, export (zip), import. Safe-switch warning reminds users to restart Scarf after activating a different profile
- **Hermes Proxy** *(new in 2.9, Hermes v0.14+)* — Launch the OpenAI-compatible local proxy that forwards requests to your OAuth-authenticated upstream provider (Nous Portal in v0.14; more adapters as Hermes adds them). Status card with running/stopped badge, endpoint URL with copy button (`http://127.0.0.1:8645/v1`), provider picker, live log tail, and a usage-help card. Point Codex CLI / Aider / Cline / VS Code Continue at the endpoint and any bearer token works — the proxy attaches your real credential

### Manage

- **Tools** — Enable/disable toolsets per platform with a connectivity-aware platform menu (green/orange/grey/red dots for connected/configured/offline/error). **Fixed in 1.6:** all 13 platforms now appear (was previously stuck on CLI)
- **MCP Servers** — Manage Model Context Protocol servers Hermes connects to. Add via curated presets (GitHub, Linear, Notion, Sentry, Stripe, and more) or fully custom (stdio command + args, or HTTP URL with optional bearer auth). Per-server detail view with enable/disable toggle, environment variable + header editor, tool-include/exclude filters, resources/prompts toggles, request and connect timeouts, OAuth token detection + clearing, and one-click "Test Connection" that runs `hermes mcp test` and surfaces the discovered tool list. Gateway-restart banner appears after config changes that require a reload
- **Gateway Control** — Start/stop/restart the messaging gateway, view platform connection status, manage user pairing (approve/revoke)
- **Cron Manager** — View scheduled jobs with pre-run scripts, delivery failure tracking, timeout info, and `[SILENT]` job indicators. **New in 1.6:** full write support — create, edit, pause, resume, run-now, and delete jobs from the app
- **Health** — Component-level status and diagnostics. **New in 1.6:** inline "Run Dump" and "Share Debug Report" buttons (the latter with an upload-confirmation dialog before sending to Nous support)
- **Log Viewer** — Real-time log tailing for agent.log, errors.log, and gateway.log with level filtering, component filter (Gateway / Agent / Tools / CLI / Cron), clickable session-ID pills that filter to a single session, and text search
- **Settings** — **Restructured in 1.6** into a 10-tab layout: General, Display, Agent, Terminal, Browser, Voice, Memory, Aux Models, Security, Advanced. Exposes ~60 previously hidden config fields including all 8 auxiliary model tasks, container limits, full TTS/STT provider settings, human-delay simulation, compression thresholds, logging rotation, checkpoints, website blocklist, Tirith sandbox, and delegation. One-click **Backup & Restore** via `hermes backup` / `hermes import`. Model picker replaces the old free-text model field, backed by the models.dev cache (111 providers, all major models) with a "Custom…" escape hatch

### Project Dashboards

Custom, agent-generated dashboards for any project. Define stat boxes, charts, tables, progress bars, checklists, rich text, and embedded web views in a simple JSON file — Scarf renders them with live refresh. Let your Hermes agent build and maintain project-specific visualizations automatically. See [Project Dashboards](#project-dashboards-1) below for the full schema.

### System

- **Hermes Process Control** — Start, stop, and restart the Hermes agent directly from Scarf
- **Menu Bar** — Status icon showing Hermes running state with quick actions

## Requirements

- macOS 14.6+ (Sonoma) for Scarf
- iOS 18.0+ for [ScarfGo](https://github.com/awizemann/scarf/wiki/ScarfGo) (the iPhone companion, public TestFlight from v2.5)
- Xcode 16.0+ to build from source
- [Hermes agent](https://github.com/hermes-ai/hermes-agent) v0.6.0+ installed at `~/.hermes/` on each target host (v0.17.0+ recommended for the full v2.12 surface — WhatsApp Business Cloud API + SimpleX setup forms, Telegram rich-messages / online-offline status toggles, an opt-in curator-consolidation toggle, and a max-concurrent-sessions cap, on top of the v0.16 soft-delete/rewind correctness fixes and the broader v0.13–v0.15 feature set. Older hosts down to v0.6.0 work — every release-gated surface is capability-gated and simply hidden on hosts that don't support it.)
- For remote servers: SSH access (key-based), `sqlite3` on the remote (for atomic DB snapshots), and the `hermes` CLI resolvable from the remote user's `PATH` or at a path you specify per server. ScarfGo requires the same on every Hermes host it connects to.

### Compatibility

Scarf reads Hermes's SQLite database and parses CLI output from `hermes status`, `hermes doctor`, `hermes tools`, `hermes sessions`, `hermes gateway`, and `hermes pairing`. Automatic schema detection provides backward compatibility with older databases while supporting new features in newer Hermes versions.

| Hermes Version | Status |
|----------------|--------|
| v0.6.0 (2026-03-30) | Verified |
| v0.7.0 (2026-04-03) | Verified |
| v0.8.0 (2026-04-08) | Verified |
| v0.9.0 (2026-04-13) | Verified |
| v0.10.0 (2026-04-16) | Verified (Tool Gateway introduced) |
| v0.11.0 (2026-04-23) | Verified |
| v0.12.0 (2026-04-30) | Verified |
| v0.13.0 (2026-05-07) | Verified |
| v0.14.0 (2026-05-16) | Verified |
| v0.15.0 (2026-05-28) | Verified |
| v0.15.1 (2026-05-29) | Verified — hotfix wave (dashboard, Docker, MCP, Kanban worker, skills.sh, `/yolo`, `/model`) |
| v0.15.2 (2026-05-29) | Verified |
| v0.16.0 (2026-06-05) | Verified (first `state.db` schema change since v0.11 — soft-delete filter + rewind badge, schema-gated; live session titles; gateway allowlist/config fixes; `hermes sessions optimize`) |
| v0.17.0 (2026-06-19) | **Verified — current target (recommended for full v2.12 feature support)** |

Scarf 2.12 targets Hermes **v0.17.0**. The upstream surfaces Scarf reads — `state.db` schema, ACP wire protocol, CLI verbs, config keys, model catalog — were verified entirely stable, so v0.17 needed no forced compatibility changes; Scarf adds WhatsApp Business Cloud API + SimpleX setup forms, Telegram rich-messages / online-offline status toggles, an opt-in curator-consolidation toggle, and a max-concurrent-sessions cap, plus a batch of pre-existing-bug fixes the audit exposed (four broken Health/Settings CLI actions, and the Curator "Prune" rebuilt as the correctly-reversible "Archive idle skills"). **v0.16.0** added the first `state.db` schema change since v0.11 — the `messages.active` soft-delete filter applied on `/undo` (schema-gated), live session titles via the ACP `session_info_update` notification, the rewind-count badge, and two gateway-config fixes. Scarf 2.10's **v0.15.0** baseline still applies: OpenAI as a first-class provider (`openai-api`, distinct from OpenAI Codex), Krea image-generation models, the xAI May-15 model-retirement aliases + `hermes migrate xai` action (Vercel AI Gateway + Sandbox removed), the xAI Web Search backend, ntfy as the 23rd gateway platform + per-platform flags (Telegram `disable_topic_auto_rename` / `ignore_root_dm`, Discord `allow_any_attachment`, Signal `require_mention`), the xAI TTS `auto_speech_tags` toggle, the Kanban v0.15 maturation wave (server-side `--sort`, Promote / Schedule / Delete-permanently actions, Scheduled + Review columns, worktree `--branch` + read-only `model_override`, the session-scoped board via ACP `session_id`, and `--board` plumbing), Bitwarden Secrets Manager, MCP mTLS client certificates + `hermes mcp catalog` browse, the skill Bundles tab, per-session edit-approval modes (`session/set_mode`), and the Health supply-chain audit (`hermes audit`). Every v0.15 surface is **capability-gated** — Scarf detects the host's Hermes version once per server connection (`hermes --version` → semver + `YYYY.M.D` parse) and hides v0.15-only UI on older hosts. v0.14.0 hosts keep the full v2.9 surface (`/subgoal` + `/yolo` + `/sessions` + `/codex-runtime`, xAI Grok OAuth + NovitaAI, LINE + SimpleX Chat, Brave Search + DuckDuckGo, Hermes Proxy, ACP `--setup-browser`, the YOLO warning, the Qwen Cloud rename). v0.13.0 hosts keep the full v2.8 surface (Persistent Goals, ACP `/queue`, Kanban v0.13 diagnostics, Curator archive/prune, Google Chat, MCP SSE transport, per-capability Web Tools backends). Earlier Hermes versions remain supported for monitoring, sessions, file-based features, and ACP chat; new behavior degrades gracefully on older agents.

If a Hermes update changes the database schema or CLI output format, Scarf may need to be updated. Check the [Health](#features) view for compatibility warnings.

## Install

### Pre-built Binary (no Xcode required)

Download the latest build from [Releases](https://github.com/awizemann/scarf/releases):

- `Scarf-vX.X.X-Universal.zip` — Apple Silicon + Intel (recommended)
- `Scarf-vX.X.X-ARM64.zip` — Apple Silicon only (smaller download)

1. Unzip and drag **Scarf.app** to Applications
2. Launch normally — builds are Developer ID signed and notarized, so Gatekeeper accepts them on first launch

Scarf checks for updates automatically on launch via [Sparkle](https://sparkle-project.org) and daily thereafter. You can disable automatic checks or trigger a manual check from **Settings → General → Updates** or the menu bar icon.

#### "Scarf.app is damaged" on first launch

If Gatekeeper rejects the app on first launch (occasionally happens on macOS 14+ for zip-distributed apps depending on extraction tool + quarantine state), the bundle itself is fine — every release is verified to pass `codesign --verify --strict --deep` and `spctl --assess --type execute` before it ships. The fix is to **only remove the quarantine attribute**, never strip all xattrs or re-sign:

```bash
# Recommended — non-destructive
xattr -d com.apple.quarantine /Applications/Scarf.app

# Or extract with ditto instead of double-clicking the zip:
ditto -xk ~/Downloads/Scarf-vX.X.X-Universal.zip ~/Downloads/
```

**Do not run `xattr -rc /Applications/Scarf.app`** — it strips codesign-related extended attributes and can break the bundle's seal. **Do not run `codesign --force --deep --sign - /Applications/Scarf.app`** — `--deep` ad-hoc re-signing is incompatible with Sparkle.framework's nested XPC services and `Updater.app` sub-bundle, and will corrupt the framework signature even if the outer app appears intact afterward. If a clean re-download + `xattr -d com.apple.quarantine` doesn't resolve the issue, please open an issue with `codesign --verify --verbose=4 --strict /Applications/Scarf.app` output captured **before** any mitigation attempts.

### Build from Source

```bash
git clone https://github.com/awizemann/scarf.git
cd scarf/scarf
open scarf.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Release -arch arm64 -arch x86_64 ONLY_ACTIVE_ARCH=NO build
```

For an unsigned local Debug build without an Apple Developer account (handy for contributors), use [`./scripts/local-build.sh`](scripts/local-build.sh) — see [BUILDING.md](BUILDING.md) for prerequisites.

## Architecture

Scarf follows the **MVVM-Feature** pattern with zero external dependencies beyond SwiftTerm:

```
scarf/
  Core/
    Models/       Plain data structs (HermesSession, HermesMessage, HermesConfig, etc.)
    Services/     Data access (SQLite reader, file I/O, log tailing, file watcher)
  Features/       Self-contained feature modules
    Dashboard/    System overview and stats
    Insights/     Usage analytics and activity patterns
    Sessions/     Conversation browser with rename, delete, export
    Activity/     Tool execution feed with inspector
    Projects/     Agent-generated project dashboards with widget rendering
    Chat/         Rich ACP chat and embedded terminal with voice controls
    Memory/       Memory viewer and editor
    Skills/       Skill browser by category
    Tools/        Toolset management per platform
    MCPServers/   MCP server registry, presets, OAuth, tool filters, test runner
    Gateway/      Messaging gateway control and pairing
    Cron/         Scheduled job viewer
    Logs/         Real-time log viewer
    Settings/     Structured config editor
  Navigation/     AppCoordinator + SidebarView
```

### Data Sources

Scarf reads Hermes data directly from `~/.hermes/`:

| Source | Format | Access |
|--------|--------|--------|
| `state.db` | SQLite (WAL mode) | Read-only |
| `config.yaml` | YAML | Read-only |
| `memories/*.md` | Markdown | Read/Write |
| `cron/jobs.json` | JSON | Read-only |
| `logs/*.log` | Text | Read-only |
| `gateway_state.json` | JSON | Read-only |
| `skills/` | Directory tree | Read-only |
| `hermes acp` | ACP subprocess (JSON-RPC stdio) | Real-time chat |
| `hermes chat` | Terminal subprocess | Interactive |
| `hermes tools` | CLI commands | Enable/Disable |
| `hermes sessions` | CLI commands | Rename/Delete/Export |
| `hermes gateway` | CLI commands | Start/Stop/Restart |
| `hermes pairing` | CLI commands | Approve/Revoke |
| `hermes mcp` | CLI commands | Add/Remove/Test MCP servers |
| `mcp-tokens/*.json` | JSON (per-server OAuth) | Detect/Delete |
| `.scarf/dashboard.json` | JSON (per-project) | Read-only |
| `scarf/projects.json` | JSON (registry) | Read/Write |

The app opens `state.db` in read-only mode to avoid WAL contention with Hermes. Management actions (tool toggles, session rename/delete/export) go through the Hermes CLI.

### Dependencies

| Package | Purpose |
|---------|---------|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Terminal emulator for the Chat feature |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Auto-updates from the GitHub-hosted appcast |

Everything else uses system frameworks: SQLite3 C API, Foundation JSON, AttributedString markdown, SwiftUI Charts, GCD file watching.

## How It Works

Scarf watches `~/.hermes/` for file changes and queries the SQLite database for sessions, messages, and analytics. Views refresh automatically when Hermes writes new data.

The Chat tab has two modes. **Rich Chat** communicates with Hermes via the Agent Client Protocol (ACP) — a JSON-RPC connection over stdio — streaming responses in real-time with automatic reconnection and session recovery on connection loss. **Terminal** mode spawns `hermes chat` in a pseudo-terminal for the full interactive CLI experience with proper ANSI rendering. Sessions persist across navigation in both modes — switch tabs and come back without losing your conversation.

Management actions (renaming sessions, toggling tools, editing memory) call the Hermes CLI or write directly to the appropriate files, keeping Scarf and Hermes in sync.

The app sandbox is disabled because Scarf needs direct access to `~/.hermes/` and the ability to spawn the Hermes binary.

## Project Dashboards

Project Dashboards turn Scarf into a customizable monitoring hub for all your projects. You define a simple JSON file in your project folder describing what to display — stat boxes, charts, tables, progress bars, checklists, rich text, and embedded web views — and Scarf renders it as a live-updating dashboard. Your Hermes agent can generate and maintain these dashboards automatically.

### What You Can Build

- **Development dashboards** — test coverage, build status, open issues, sprint progress
- **Data project trackers** — pipeline metrics, data quality scores, processing throughput
- **Deployment monitors** — deploy history tables, uptime stats, error rate charts
- **Research dashboards** — experiment results, key findings, paper status checklists
- **Agent activity views** — cron job results, content generation stats, task completion rates
- **Embedded web apps** — local dev servers, HTML reports, Grafana dashboards, any web-based tool your agent generates
- **Any project status** — if your agent can measure it, Scarf can display it

### Quick Start

**1. Create the dashboard file**

Create `.scarf/dashboard.json` in any project folder:

```json
{
  "version": 1,
  "title": "My Project",
  "description": "Project status at a glance",
  "sections": [
    {
      "title": "Overview",
      "columns": 3,
      "widgets": [
        {
          "type": "stat",
          "title": "Test Coverage",
          "value": "87%",
          "icon": "checkmark.shield",
          "color": "green",
          "subtitle": "+2.1% this week"
        },
        {
          "type": "progress",
          "title": "Sprint Progress",
          "value": 0.73,
          "label": "73% complete",
          "color": "blue"
        },
        {
          "type": "list",
          "title": "Tasks",
          "items": [
            { "text": "Write unit tests", "status": "done" },
            { "text": "Update API docs", "status": "active" },
            { "text": "Deploy to prod", "status": "pending" }
          ]
        }
      ]
    }
  ]
}
```

**2. Register your project**

Have your agent append a `{name, path}` entry directly to the registry at `~/.hermes/scarf/projects.json` — Scarf watches the file and picks up the change on the next sidebar refresh, no manual UI step needed:

```json
{
  "projects": [
    { "name": "my-project", "path": "/Users/you/Developer/my-project" }
  ]
}
```

(You can also add the folder by hand in Scarf via **Projects → +** if you'd rather click than edit JSON — both paths write to the same file.)

**3. View in Scarf**

Select your project in the Projects sidebar — the dashboard renders immediately. Scarf watches the file for changes and refreshes automatically whenever the JSON is updated.

### Widget Types

| Type | Description | Key Fields |
|------|-------------|------------|
| `stat` | Key metric with large value display | `value`, `icon`, `color`, `subtitle` |
| `progress` | Progress bar with label | `value` (0.0–1.0), `label`, `color` |
| `text` | Rich text block | `content`, `format` ("markdown" or "plain") |
| `table` | Data table with headers | `columns`, `rows` |
| `chart` | Line, bar, or pie chart | `chartType`, `series` (each with `name`, `color`, `data`) |
| `list` | Checklist with status indicators | `items` (each with `text`, `status`: done/active/pending) |
| `webview` | Embedded web browser | `url`, `height` (default 400) |

The `webview` widget embeds a live web browser directly in your dashboard — perfect for displaying local dev servers, HTML reports, or any web-based tool your agent generates.

When a dashboard includes a webview widget, Scarf adds a tabbed interface: **Dashboard** shows your normal widgets, **Site** shows the web content full-canvas with clean margins — using the entire available space in the app. This gives you the best of both worlds: compact metrics at a glance, and a full embedded browser when you need it.

```json
{
  "type": "webview",
  "title": "Project Report",
  "url": "http://localhost:8000/dashboard",
  "height": 500
}
```

- `url`: Any URL — typically a local server (`http://localhost:...`) or file path
- `height`: Height in points when displayed as an inline widget card (default: 400). The Site tab always uses full available space regardless of this setting.

**Colors**: red, orange, yellow, green, blue, purple, pink, teal, indigo, mint, brown, gray

**Icons**: Any [SF Symbol](https://developer.apple.com/sf-symbols/) name (e.g., `checkmark.shield`, `cpu`, `doc.text`, `chart.bar`)

### Agent-Generated Dashboards

The real power is letting your Hermes agent build and update dashboards automatically. Add instructions like this to your agent's context:

> Analyze this project and create a `.scarf/dashboard.json` dashboard with relevant metrics and status. Use stat widgets for key numbers, charts for trends, tables for structured data, lists for task tracking, and a webview widget if the project has a local web server or HTML reports. Register the project by appending a `{name, path}` entry to `~/.hermes/scarf/projects.json` if not already registered — Scarf picks up the change on next sidebar refresh.

Your agent can update the dashboard as part of cron jobs, after builds, or whenever project state changes. Since Scarf watches the file, updates appear in real-time.

### Dashboard Schema Reference

```json
{
  "version": 1,
  "title": "Required — dashboard title",
  "description": "Optional — subtitle text",
  "updatedAt": "Optional — ISO 8601 timestamp",
  "sections": [
    {
      "title": "Section Name",
      "columns": 3,
      "widgets": [{ "type": "...", "title": "..." }]
    }
  ]
}
```

Each section defines a grid with 1–4 columns. Widgets flow left-to-right, wrapping to new rows. See [DASHBOARD_SCHEMA.md](scarf/docs/DASHBOARD_SCHEMA.md) for the full schema reference with examples of every widget type.

## Releases

Scarf ships through GitHub releases — the App Store is not supported because Scarf spawns the user-installed `hermes` binary and reads `~/.hermes/` directly, both of which App Sandbox forbids.

Each release goes through a single local script: [scripts/release.sh](scripts/release.sh). The script archives a universal binary, signs it with the Developer ID Application cert, submits to `notarytool`, staples the ticket, produces the distribution zip, signs an appcast entry with Sparkle's EdDSA key, pushes an updated `appcast.xml` to the `gh-pages` branch, creates the GitHub release, and tags `main`.

The Sparkle appcast is served from [awizemann.github.io/scarf/appcast.xml](https://awizemann.github.io/scarf/appcast.xml).

Signing prerequisites (one-time):

- `Developer ID Application` certificate in the login Keychain
- `scarf-notary` keychain profile registered via `xcrun notarytool store-credentials`
- Sparkle EdDSA private key in Keychain item `https://sparkle-project.org` (back this up — without it, shipped apps can never receive updates)

## Template Catalog

Community-contributed Scarf project templates live under [`templates/`](templates/) in this repo and are browsable at **[awizemann.github.io/scarf/templates/](https://awizemann.github.io/scarf/templates/)** with live dashboard previews and one-click `scarf://install?url=…` links.

- **Install from the web** — click "Install with Scarf" on any template's detail page; the app takes over from there.
- **Install from a local file** — Scarf → Projects → Templates → Install from File…, or double-click any `.scarftemplate` in Finder.
- **Author a template** — see [`templates/CONTRIBUTING.md`](templates/CONTRIBUTING.md) for the full walkthrough. Fork, drop a template under `templates/<your-github-handle>/<your-name>/`, open a PR; CI validates the bundle automatically.

The catalog's site is a static HTML + vanilla JS build generated by [`tools/build-catalog.py`](tools/build-catalog.py) and driven by [`scripts/catalog.sh`](scripts/catalog.sh) (check / build / preview / publish). Appcast and main landing page are independent — updating the catalog never disturbs Sparkle.

## Contributing

Contributions are welcome. Please open an issue to discuss what you'd like to change before submitting a PR.

1. Fork the repo
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -m 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

For template submissions, see [`templates/CONTRIBUTING.md`](templates/CONTRIBUTING.md) — same flow, with a catalog-specific checklist + automated CI validation.

## Support

If you find Scarf useful, consider buying me a coffee.

<a href="https://www.buymeacoffee.com/awizemann"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" height="40"></a>

## FAQ

Quick answers to common questions live on the **[Scarf website FAQ](https://awizemann.github.io/scarf/#faq)** — what Scarf is, the Hermes prerequisite, supported macOS/iOS versions, how ScarfGo connects over SSH, privacy and telemetry, where conversations are stored, how updates work, remote/headless hosts, and Windows/Linux support.

For deeper docs, see the **[Wiki](https://github.com/awizemann/scarf/wiki)** — including [Projects & Profiles](https://github.com/awizemann/scarf/wiki/Projects-&-Profiles), [Mini-Apps](https://github.com/awizemann/scarf/wiki/Mini-Apps), [Fleet & Portfolio](https://github.com/awizemann/scarf/wiki/Fleet-&-Portfolio), and [Chat](https://github.com/awizemann/scarf/wiki/Chat). Something not covered? Open a **[GitHub issue](https://github.com/awizemann/scarf/issues)**.

## License

[MIT](LICENSE)
