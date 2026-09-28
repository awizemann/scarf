---
title: Memory-and-Skills
type: note
permalink: scarf-wiki/memory-and-skills
created: 2026-05-29
updated: 2026-05-29
---

# Memory & Skills

Two adjacent sidebar items both deal with what Hermes knows. **Memory** is the per-conversation and per-user notes Hermes keeps about you. **Skills** are reusable capabilities you've installed.

## Memory

Live editor for Hermes's two memory files:

- `~/.hermes/memories/MEMORY.md` — project / topic memory.
- `~/.hermes/memories/USER.md` — user memory (preferences, role, recurring context).

**What you get:**

- Side-by-side edit + render with markdown preview (Mac); single-pane editor with a "Saved" pill that survives keyboard dismissal + a Revert button (iOS).
- **Live refresh** — when Hermes (or you) updates the file from outside, the view reloads via `HermesFileWatcher`.
- **Profile awareness** — if you have multiple Hermes profiles, the picker switches between their memory files.
- **External provider awareness** — when `memory_provider` in `config.yaml` is set to a service like Honcho or Supermemory, the view tells you so and links to the provider's docs.
- **Reset memory** _(v2.5+)_ — toolbar button on Mac + iOS Memory views that runs `hermes memory reset --yes` and refreshes the on-screen content. Destructive-confirmation dialog before the call lands. Surfaces stderr in an alert on failure.

Edits are written through `ServerContext.writeText` — local: atomic temp + swap; remote (Mac): `scp` + remote `mv`; remote (iOS): SFTP write via Citadel. See [Transport Layer](Transport-Layer).

## Skills

Browse and manage Hermes skills:

- **Installed** — every skill under `~/.hermes/skills/`, found the way Hermes finds them (any folder holding a `SKILL.md`, at any depth, following symlinks), grouped by the folder path between `skills/` and the skill — flat hub installs appear under **Uncategorized** — with a file content viewer and required-config warnings (skill says it needs `OPENAI_API_KEY` in `.env`? It tells you).
- **Hub** — search the registry catalog (official, skills.sh, well-known, GitHub, ClawHub, LobeHub). Install, check for updates, uninstall. On Hermes v0.21.4+ an **All Sources** search runs `hermes skills search --source all`, which falls back to the registries when Hermes's index has no match (`tools/skills_hub_search.py:234-257` @ v2026.9.24). Older hosts keep the [#79](https://github.com/awizemann/scarf/issues/79) behaviour: filter the first browse page (40 rows) client-side, because their all-source search missed skills only browse surfaced.

Operations are wrappers around the `hermes skills` CLI invoked via `context.runHermes(...)`, so they work identically against local and remote servers.

### v2.10.0 additions _(Hermes v0.15+)_

- **Skill bundles (read-only Bundles tab).** Hermes v0.15 introduces *skill bundles* — named groups of skills declared in `~/.hermes/skill-bundles/*.yaml`, each loadable in a single turn via one `/<bundle-name>` slash command. SkillsView gains a read-only **Bundles** tab listing each bundle's name, its instruction text, and its member skills. Gated on `HermesCapabilities.hasSkillBundles` so a pre-v0.15 host doesn't see the tab. Read-only in v2.10.0 — authoring / editing bundles from the UI is a follow-up.

### v2.6 additions _(Hermes v0.12+)_

All four are gated on `HermesCapabilities.hasCurator` / `hasSkillURLInstall` so a v0.11 host sees the v2.5 surface unchanged.

- **Autonomous Curator (Mac sidebar + iOS panel).** `hermes curator` self-prunes / -consolidates the skill library on a 7-day cycle. Reports land at `~/.hermes/logs/curator/run.json` + `REPORT.md`; the run path is resolved at runtime from the `last_report_path` field on `~/.hermes/skills/.curator_state`. Mac gets a dedicated **Curator** sidebar item under Interact (between Memory and Skills); iOS gets a Curator nav row under System with **Run Now / Pause / Resume** actions and inline pin toggles. Status panel shows enabled/paused/disabled badge, last-run timestamp, last summary, run count, scheduling cadence (interval / stale-after / archive-after). Three leaderboards (least-recently-active / most-active / least-active) with activity / use / view / patch counters. **Restore archived** sheet calls `hermes curator restore <name>`. Last-run REPORT.md renders inline in mono.
- **`auxiliary.curator` aux task.** Curator's review fork can run on a separate model from the main agent. New row in Settings → Auxiliary, gated on `hasCuratorAux`. Hermes removed `auxiliary.flush_memories` entirely in v0.12, so Scarf hides that row on v0.12 hosts (inverse gate via `hasFlushMemoriesAux`). The Tool Gateway health view in HealthView lost the flushMemories-routes-through-Nous row and gained a curator row to match.
- **Skills v0.12 surface.**
  - **Direct-URL install** via `hermes skills install <https-url>` — Mac SkillsView gains an "Install from URL…" toolbar button opening a sheet with URL field plus optional `--category` / `--name` overrides. Hermes only accepts an HTTP(S) URL whose path ends in `.md` (`UrlSource._matches`, `tools/skills_hub_sources.py:172-184` @ v2026.9.24) — there is no tarball adapter, and the sheet no longer suggests one (2026-09-27).
  - **Reload** via `hermes skills audit` — toolbar button next to install on Mac. Equivalent to the `/reload-skills` slash command for non-ACP contexts.
  - **Enabled / disabled state** — `skills.disabled` in config.yaml is read at scan time; disabled skills render strikethrough + an "OFF" pill on Mac and iOS rows. iOS detail view explains the state in plain text. The disable-toggle write path is deferred to v2.7 — Hermes only exposes `hermes skills config` as an interactive verb today, and we'd rather read accurately than risk clobbering a half-tested write.
  - **Curator pin badge.** Pinned skills are protected from auto-archive and rewrites. Pin state is read from the `pinned` field of each skill's record in `~/.hermes/skills/.usage.json` (where `hermes curator pin` writes it; `.curator_state` holds only scheduler keys) and surfaced as a pin glyph on each row across Mac sidebar and iOS list, plus an explanatory chip on iOS detail view.

### v2.5 additions

- **SKILL.md frontmatter chips.** Hermes v0.11 SKILL.md files carry richer YAML frontmatter (`allowed_tools`, `related_skills`, `dependencies`). Scarf parses it on both platforms and renders chip rows in the skill detail view. Old skills without these fields stay nil and the rows hide themselves.
  - **Corrected 2026-09-27 (blind re-audit S10-F3).** `related_skills` is read from `metadata.hermes.related_skills` first, then top level, as Hermes does (`tools/skills_tool.py:613-617` @ v2026.9.24) — every bundled skill uses the nested form. The **required config** count and the **missing config** warning now come from the skill's `metadata.hermes.config` entries (`key` + `description`; `agent/skill_utils.py:666-689`), checked against `skills.config.<key>` in config.yaml, the same "missing or empty" test as `hermes config migrate`. Scarf used to read a `skill.yaml` → `required_config:` list that no Hermes version reads. Hermes reads neither top-level `allowed_tools` nor `dependencies`; those chips show what the author wrote.
- **"What's New" pill.** Per-server snapshot of `[skillId: signature]` (file count + sorted file names). When the snapshot changes between visits, both Skills views render a tinted pill at the top: "2 new, 4 updated since you last looked." Tap **Mark as seen** to update the snapshot. First-time loads silently prime so users don't see "everything is new!" noise on a fresh install. Backed by [`SkillSnapshotService`](Core-Services).
- **`design-md` skill prereq banner.** The `design-md` skill needs `npx` (Node.js 18+) on the host. New `SkillPrereqService.probe(binary:)` runs `which npx` over the transport when you open the skill detail; on miss, both Mac and iOS render a yellow banner with a per-OS install hint.
- **Spotify OAuth sheet.** The `spotify` skill needs OAuth via `hermes auth spotify`. Mac ships a dedicated Sign-in sheet (mirroring the v2.3 Nous Portal pattern): runs the subprocess, regex-detects the `accounts.spotify.com/authorize?...` URL, auto-opens it in your browser, polls `~/.hermes/auth.json` after subprocess exit to confirm the token landed. Five-state machine (starting → waiting → verifying → success / failure) with retry. iOS surfaces a documentation row noting OAuth needs to happen from Mac or a shell — phone OAuth flows are their own UX problem. First-time local sign-in: when neither `.env` (`HERMES_SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_ID`) nor `auth.json` has a Spotify Client ID, the sheet walks through creating a Spotify app and asks for the Client ID, then runs `hermes auth spotify --client-id=…`. Hermes's own wizard would ask on a terminal that Scarf doesn't have. Remote servers: the OAuth callback listens on the host, so the sheet shows (and can open in Terminal) an `ssh -t -L 43827:127.0.0.1:43827 … hermes auth spotify --no-browser` command to run from the Mac instead.

## Related pages

- [Hermes Paths](Hermes-Paths) for the underlying file layout.
- [Personalities](Platforms-Personalities-QuickCommands) for `SOUL.md` editing — closely related to memory but tied to a personality, not a profile.
- [Settings — Memory tab](Gateway-Cron-Health-Logs) for `memory_enabled`, `memory_char_limit`, `memory_provider`.

---
_Last updated: 2026-09-27 — skill config keys, related skills, All Sources search and install-from-URL corrected against Hermes v2026.9.24 (blind re-audit B08)_