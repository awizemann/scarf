# Hermes v0.21.6 → v0.22.5 audit and plan (2026-10-24)

Scarf target today: Hermes v0.21.5 (`v2026.9.24`). Latest Hermes: **v0.22.5** (2026-10-22). Seven releases in between (v0.21.6, v0.21.7, v0.22.0–v0.22.5), about 16,000 commits.

Method: `hermes-release-audit` skill. Eight read-only surface audits (schema, ACP, CLI argv ×2, config, providers, gateway, MCP/skills/cron/web). The high-impact findings were spot-checked against the tagged source and against a real v0.22.5 binary built in an isolated venv (`~/.hermes/hermes-agent-v0.22.5-audit/.venv/bin/hermes`; the `hermes` on PATH is still v0.21.5).

## Verdict

- **state.db columns Scarf reads: unchanged.** But from v0.22.3 the *meaning* of `sessions.source` changed (see A3).
- **ACP: the protocol is unchanged, but the server behind it was replaced.** From v0.22.3 `hermes acp` is a thin viewer of the gateway daemon (`acp_adapter/server.py:245-249@v0.22.5`). Queue, cancel, resume, mode/model switching and "clarify" questions now behave differently. This is the bulk of the work.
- **Not a light cycle.** It is a parity push with three safety-critical bugs that would hit users the day they upgrade.

## Things to know before gating anything

1. **Tag scheme changed.** Tags are now `vX.Y.Z` (no more `vYYYY.M.D`). `pyproject.toml` says `0.0.0`; the version comes from git tags or an install stamp (`hermes_cli/version_info.py@v0.22.5`).
2. **The date in `hermes --version` is frozen at `2026.9.24`.** Real output: `Hermes Agent v0.22.5 (2026.9.24) · stable · local bf0203a794a0`. Scarf's parser reads the semver correctly and nothing in Scarf uses the date, so detection still works. Never gate on the date again.
3. **v0.22.1 → v0.22.2 was a revert.** v0.22.1 shipped the gateway-backed ACP, runtime tables, `gateway ensure`, etc.; v0.22.2 removed them; v0.22.3 brought them back. True floor for all of those: **v0.22.3**, with v0.22.1 as an odd one-release window (treat 0.22.1 as "gateway-backed but degraded").
4. **"Left core" pattern.** Hermes moved several bundled features into installable catalog plugins: Home Assistant, Honcho/mem0/openviking/supermemory/holographic/hindsight memory providers, Spotify, Singularity terminal, Tirith scanner. Config keys mostly stay the same, but the feature only works once the plugin is installed. One shared Scarf affordance ("needs the X plugin — Install") should cover all of them.

## A. Safety-critical — the upgrade breaks these (fix first)

| # | Problem | Hermes | Scarf | Floor |
|---|---|---|---|---|
| A1 | **Stop Gateway kills a gateway Hermes refused to stop.** v0.22.3+ refuses `gateway stop/restart` while sessions are live (exit 1, `✗ Refusing to stop the gateway: N live session(s)…`). Scarf reads that as failure and falls back to `kill -TERM`, interrupting exactly the work Hermes protected. Scarf chats are now gateway sessions, so an open Scarf turn counts. | `hermes_cli/gateway_lifecycle_guards.py:97-129`, flags `subcommands/gateway.py:144,151` | `scarf/Core/Services/HermesFileService.swift:3221-3260`, `:1587`; `HermesCLIOutcome.swift:1154,1796` | 0.22.3 |
| A2 | **Health status panel goes empty and the s6 restart guard stops working.** Plain `hermes status` now prints a one-screen summary with no `◆` sections. `--all` already parses on old hosts and means "full" on new ones — no gate needed. | `hermes_cli/status.py:391-424` | `HealthViewModel.swift:226,700`; `HermesGatewayRestartGuard.swift:208` | 0.21.6 |
| A3 | **Chat resume silently starts a new chat; session badges say "local".** v0.22.3+ stores CLI/TUI/Desktop/ACP sessions as `source='local'` with the real surface in `created_source`. Scarf only loads `source == "acp"`, so resume skips the load. Also: a failed `session/load` is now a JSON-RPC error, not "not restorable", so the fallback shows an error. | `gateway/session_policy.py:85-89`, `acp_adapter/gateway_server.py:282,327-387` | `ACP/SessionResume.swift:64-77`; `HermesDataService.swift:266-301`; `HermesSession.swift:365`; `SessionsViewModel.swift:1335` | 0.22.3 (column from 0.21.6) |
| A4 | **A duplicate key in config.yaml now stops Hermes from starting.** Loader switched PyYAML → ruamel. Scarf's parser models last-wins and the text writers can't detect duplicates. Also `y`/`n` are now booleans. | `hermes_yaml.py:1-38`, `hermes_cli/config.py:440-468` | `HermesYAML.swift:481-495,1124`; `GatewayConfigWriter.swift`; `HermesBotProfileYAML.swift` | 0.21.6 |

## B. Broken or wrong, but not dangerous

| # | Problem | Scarf | Floor |
|---|---|---|---|
| B1 | Plugin enable/disable always shows a failure banner (success line changed to `✓ Plugin X enabled.`). | `HermesCLIOutcome.swift:737-766` | 0.22.3 |
| B2 | Spotify sign-in: `hermes auth spotify` removed → `hermes spotify login` after installing the plugin. | `SpotifyAuthFlow.swift:498-501,594` | 0.21.7 |
| B3 | Tirith Sandbox settings write keys a migration deletes; nothing reads them. Hide on ≥0.21.6 (upper bound). | `SecurityTab.swift:41-46`, iOS `SettingsView.swift:596` | <0.21.6 only |
| B4 | `hasCompressionThresholdTokensDefault256K` must become a window: the default went back to `None` at 0.21.6. | `HermesCapabilities.swift:2487` | 0.21.4–0.21.5 only |
| B5 | `plugins compat` removed — wasted call on every Plugins load. Add upper bound to `hasPluginsCompat`. | `PluginsViewModel.swift:189`, `HermesCapabilities.swift:2106` | 0.21.1–0.21.5 |
| B6 | `plugins install --enable` installs but leaves disabled when deps need consent; Scarf says "Installed". Add consent → `--yes-deps`. | `PluginsViewModel.swift:266`, `HermesPluginList.swift:275` | 0.21.6 |
| B7 | Partial `import` now exits 1; Scarf loses the "partially restored" message. Mirror the backup handling. | `HermesCLIOutcome.swift:~2797` | 0.21.6 |
| B8 | `gateway status` new arm "running but cannot serve this Hermes (incompatible)" — exactly the state right after upgrading. Scarf shows "running". | `GatewayViewModel.swift:382-386` | 0.22.3 |
| B9 | `sessions delete` new refusals show only "exited 1". | `SessionsViewModel.swift:133,741` | 0.21.6 / 0.22.3 |
| B10 | Duplicating a cron job drops the new `interpreter` field. | `HermesCronJob.swift:567-569,657-663` | 0.21.6 |
| B11 | Skills `_org` mirror removed; Scarf still hides `_org/`. Window below 0.21.6. | `SkillsScanner.swift:62-135` | <0.21.6 |
| B12 | Memory providers / Home Assistant / Singularity left core — add the shared "needs plugin" affordance. | `SettingsViewModel.swift:39,183`, `MemoryTab.swift`, `HomeAssistantSetupViewModel.swift` | 0.21.6 / 0.21.7 / 0.22.5 |
| B13 | Restart with no installed service runs the gateway in Scarf's own child process (pre-existing). `gateway restart --detach` fixes it. | `HermesCLIOutcome.swift:1796,1046` | 0.22.3 |

## C. ACP on the gateway daemon (one flag: `hasGatewayBackedACP`, ≥0.22.3, plus 0.22.1)

1. `/queue` — the running turn's prompt now returns before the queued one runs; Scarf clears the queue and sets "not working" too early. `RichChatViewModel.swift:3194-3203`.
2. Cancel no longer carries the stopped prompt into the next one → `hasACPStoppedPromptCarriedForward` gets an upper bound; Live Voice's supersede logic depends on it (`VoiceConversationEngine.swift:92-118`).
3. Live Voice context notes now get saved into the transcript (`ACPContextNote.swift` contract broken) — verify live.
4. No more mid-chat compression announcement → Scarf must re-derive the lineage from state.db after compression (`ChatViewModel.swift:2658`, `RichChatViewModel.swift:2752`).
5. Closing Scarf no longer stops a running turn; reconnect can stream a turn Scarf didn't start. Audit every "process gone = turn gone" assumption.
6. `set_mode` errors while a turn runs; unknown mode is now an error (`ACPClient.swift:713-722`).
7. `set_model` can ask for confirmation (permission card `model-confirm-*`), defer, or be cancelled (`ACPClient.swift:751-761`).
8. The `clarify` tool arrives as a permission card: wrong title ("Tool Approval Required") and **`skip` is treated as allow** (`RichChatViewModel.swift:554-557`). Minimum fix: title + `reject_once` handling. Better (deferred): advertise elicitation and handle `elicitation/create`.
9. New `current_mode_update` notification → mode chip goes stale (low).
10. Hermes notices now arrive as ordinary agent text and may merge into replies — verify live.
11. Daemon auto-starts on `session/new`; new failures `acp_policy_unavailable` (old daemon still running) and `profile_mismatch` need readable messages. Test local, SSH and `-p <profile>`.
12. Slash commands advertised grew 9 → 14, and `/new` `/clear` now work over ACP; the "not ACP" notes in `HermesCapabilities.swift:500-535` are stale from 0.22.3.

## D. Models and providers

- **Fix for every host (pre-existing bug):** vLLM / llama.cpp / `local` configs show a false "stale provider prefix" banner because Scarf maps them to `local` and the preflight only skips `custom`. Map `vllm, llamacpp, llama.cpp, llama-cpp, local → custom` (`ModelCatalogService.swift:1399-1406`) and add `local → custom` to `HermesProviderCredentials.swift:78-87`. Hermes routed these to `custom` at every tag, so this is a correction, not a new surface — I recommend no version window (Alan's 2026-09-27 rule: byte-identical protects new affordances, not bugs).
- Add `solstice`, `solstice-oauth` to routable providers (band ≥0.21.6) — `HermesRoutableProviders.swift`.
- Add image model `krea-3` (≥0.22.3) and MCP catalog entry `rentahuman` (≥0.22.3).
- **`scripts/check-hermes-tables.py` is now partly blind:** three new plugins register inline (`register_provider(XProfile(...))`), which lanes 4/6/8 skip. Teach it to read inline calls; then lane 8 will correctly FAIL on solstice until the table is fixed. Bump `HERMES_TARGET_TAG` to `v0.22.5`.
- Comment-only: `commandcode` is now in `HERMES_OVERLAYS` (`ModelCatalogService.swift:1201`); `LocalModelProviders.swift:23-28` doc is wrong.

## E. Pre-existing bugs found along the way

- Prompt token usage is double-counted per turn (`RichChatViewModel.swift:3178-3181`) — Hermes sends running totals.
- `usage_update` and `plan` ACP notifications have always been ignored (`ACPMessages.swift:632`).
- Kanban diagnostic `running_with_open_parents` missing from the enum (renders "unknown").
- Last-active SQL lacks Hermes's bad-timestamp guard (`HermesDataService.swift:322-330`).
- `peer status|stop` argv lacks `--` before the target (`HermesPeerCLI.swift:104,108`).
- Dead code: `HermesMCPInstallVerdict` "install failed:" marker, `HermesUpdaterCommandBuilder.updateArgv`.

## F. Opt-in new features (not required for parity — Alan picks)

`gateway ensure --json` as a start probe; `gateway.on_all_adapters_down` toggle; `auxiliary.voice_chat` row; cron `last_failure` ("failed at X — recovered since"); MCP cost keys; SKILL.md `deps`; kanban `stale_running`; `plugins update --force` retry; 18 UI locales; new config keys (`sessions.auto_prune` default flipped to off, `delegation.backend`, etc.); full elicitation support.

## Verified unchanged (don't re-litigate)

FTS tables and views; every column Scarf reads; `jobs.json` path and cron runs/incidents/doctor output; kanban JSON; log format and files; curator state; skills hub columns; web and TTS backend rosters (Tavily window still holds); `gateway list` and status markers; pairing; all 126 gateway env vars except `HASS_*`; allowlist mapping; `backup --keep 0`; `hermes acp` argv; acp library pin (0.9.0); cron create/edit flags; profile, peer, kanban argparse.

## Plan

Branch `feat/hermes-v0225-parity`. Each phase: build → tests → real run → fresh-eyes audit → commit.

- **P0 Foundations.** Predicates `isV0216OrLater`, `isV0217OrLater`, `isV0223OrLater`, `isV0225OrLater` and a gateway-backed-ACP predicate that covers 0.22.1 and ≥0.22.3. Bump `HERMES_TARGET_TAG`. Fix the table checker's inline-registration blind spot. Point the PATH `hermes` at the v0.22.5 venv for live testing (keep the v0.21.5 install for the old-host pass).
- **P1 Safety (A1–A4, B1, B2, B4).** Small, shippable on its own as a patch release if needed.
- **P2 ACP on the gateway daemon (C1–C12).** The largest phase; needs live testing on local, SSH and a named profile.
- **P3 Sessions source/created_source (A3 display half).**
- **P4 Providers (D).**
- **P5 Left-core plugins (B2, B3, B12) with one shared "needs plugin" affordance.**
- **P6 Remaining B items + chosen F items.**
- **P7 Pre-existing bugs (E).**
- **P8 Gate.** `HermesCapabilitiesTests` cluster for every new floor/window; Smoke + Live UI plans against a v0.22.5 host and a v0.21.5 host; adversarial audit; memory notes (`decisions/hermes-v0-22-compatibility-decisions`, `integration/hermes-v0-22-wire-verification`), wiki compatibility page; hand off to `scarf-release-prep`.
