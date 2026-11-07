# Hermes v0.22.5 → v0.23.0 — audit findings and upgrade plan

Date: 2026-11-06 · Target tag: `v0.23.0` (2bd378ed1b, released 2026-11-05) · Scarf main targets v0.22.5.
Source of truth: `git -C ~/.hermes/hermes-agent show v0.23.0:<path>` (C2). Locally installed Hermes is **v0.13.0** — a v0.23.0 install is needed for Phase 4.

## 0. Framing

- Scope is **v0.22.5 → v0.23.0**, which also swallows the two un-audited patch tags **v0.22.6** (~776 PRs, 4,316 files) and **v0.22.7** (~174 PRs). Their notes deferred everything to the 0.23 notes. Diff v0.22.5..v0.23.0: 5,411 files, +313k/−107k.
- **"One gateway owns every conversation" isn't new in 0.23.** Hermes moved to it in v0.22.0, and Scarf adopted it last cycle (`hasGatewayBackedACP`, `hasGatewayLiveSessionGuard`, `hasGatewayRestartDetach`, `hasGatewayRewindCommands`). The 0.23 notes say this cycle "fixed what that broke". For Scarf that means re-verifying our existing gateway-backed paths, not adopting a new architecture.

## 1. Verified findings so far (cited against the tag)

| # | Finding | Evidence @ v0.23.0 | Impact on Scarf |
|---|---|---|---|
| F1 | state.db unchanged: `SCHEMA_VERSION = 32` on both tags, no new CREATE/ALTER/column definitions in `hermes_state*.py` (27 files changed, logic only) | `hermes_state_common.py:289` | Probably no schema work. Still rerun C4 probes against a real v0.23 db |
| F2 | **GitHub Copilot left core** for the `github-copilot` Labs plugin. `check-hermes-tables.py --tag v0.23.0` fails 4 lanes: aliases (`copilot`, `github`, `github-copilot-acp`), overlay-only (`copilot-acp`), provider env vars (`COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`), routable providers (8 copilot/github ids) | `hermes_cli/copilot_auth.py` deleted; script output | **Breaking.** On 0.23, the picker would offer providers that can't chat. Gate them on version + plugin presence (C1), and keep them for old hosts |
| F3 | **Camofox is no longer a core browser provider.** `plugins/browser/` has only browser_use/browserbase/firecrawl, and an unregistered `browser.cloud_provider` **raises ValueError** | `tools/browser_session_cloud.py:180-196`; `config_migrations_browser.py:86` | **Breaking.** The BrowserTab "Camofox" row (`SettingsViewModel.swift:~91`) would break browsing on 0.23 hosts that lack the plugin |
| F4 | Config migration 51→52 removes `browser.backend` and `browser.extension_control`, and moves `AGENT_BROWSER_*` env vars to `browser.{executable_path,user_data_dir,chromium_args,headed,engine}` | `config_migrations_browser.py:1-20` | Scarf already stopped writing `browser.backend` (≤2.18.1). New `browser.*` keys could be surfaced later (optional) |
| F5 | ACP now advertises `config_options` (model, reasoning effort, service tier, edit mode) on new/load, accepts `set_session_config_option` for them, and pushes `config_option_update` | `acp_adapter/gateway_server.py` (+116), `gateway_session_meta.py` (+64) | Not breaking: `ACPMessages.swift` falls through to `.unknown`. **Opportunity:** native reasoning-effort and fast-tier pickers over ACP |
| F6 | ACP `setup` now ensures `chromium`, not `agent-browser` | `acp_adapter/entry.py` | None unless Scarf shells `hermes acp --setup-browser` (check) |
| F7 | New CLI verbs present in argparse: `sessions refresh-prompts`, `curator lock`, `webapp`, `plugins update` (bulk) / `auto-update`, `cron cancel` + `--catch-up`. `mcp serve` → `mcp-serve` plugin | grep counts at tag; exact argv TBD | Candidate surfaces. **Each needs its exact argparse verified before use (C5)** |

## 2. Plan

Same audited dev cycle as v0.22: branch `feat/hermes-v0230-parity`, one worktree per slice, fresh-eyes audit per slice, cherry-pick. Memophant tasks to be created per slice.

### Phase 0: Verification sweep (no code; the gate for everything below)
Run these as parallel read-only audits against the tag, each producing file:line citations into this doc:
1. **Argv audit (C5).** Enumerate every `hermes …` argv Scarf builds (HermesCLI* / *Argv helpers, ScarfCore + app). Diff each subparser between v0.22.5 and v0.23.0 for removed verbs, renamed flags and changed defaults. Watch `mcp serve`, `import-agent`, `sessions` (failures now exit 1), `gateway stop/restart` refusal text, `plugins update` semantics, `cron` and `backup`.
2. **Output-parser audit.** Diff the source that prints what Scarf parses: `status.py`, `doctor`, `gateway status/list` (132 changed lines in status/gateway*), `cron list` (Dispatch rows), `plugins list` (new disabled-by-update state, Verified tier), `tools`, `sessions`, `pairing`. Also check `HermesCLIMarkers` strings (e.g. managed-install refusal, plugin disable).
3. **ACP wire audit.** Full diff of `acp_adapter/` plus the gateway RPCs it uses: new_session/load_session response shape, permission option kinds, the edit-approval/cost prompt (MCP price tags add text to approval prompts), clarify multi-question forms, `/model reset`, and whether `/undo`, `/retry` and `/rewind` changed.
4. **Provider and catalog tables.** Get `check-hermes-tables.py` to `lanes=8/8` (F2). Reconcile ModelCatalogService overlays, aliases, demoted providers and image-gen models (Krea 3 default, GLM-5.3 silent default, new models), the platform roster (Signal, Weixin, BlueBubbles, QQ, Yuanbao and WhatsApp Cloud became bundled plugins; X Chat added), the web/search roster, and the browser provider roster (F3).
5. **Config keys.** Diff `config_defaults.py` (244 lines) and `config_migrations*` for every key Scarf reads or writes: renamed, removed, and new defaults (`compression.prepare_ahead`, `agent.stream_max_lifetime`, `plugins.auto_apply`, `vault.key_storage`, `webapp.enabled`, `display.cli_layout`, `delegation.backend`). Check the strict YAML loader against Scarf's writer.
6. **Schema probe.** Confirm F1 against a real v0.23 `state.db`: PRAGMA every table and column Scarf reads, including Bot Mode / group-room tables (rooms now have purpose and notes; check where those live).
7. **Version parsing.** Make sure `+canary.<ts>` tags and `rc.N-v0.23.0` names parse correctly in `HermesCapabilities`.

### Phase 1: Capability flags (S1)
- Add a `MARK: v0.23.0 flags` cluster, plus v0.22.6/v0.22.7 clusters if Phase 0 finds patch-gated behaviour. Candidates: `hasCopilotInCore` (true below 0.23), `hasCamofoxCoreBrowser` (true below 0.23), `hasACPConfigOptions`, `hasSessionsRefreshPrompts`, `hasCuratorLock`, `hasCronCancel`, `hasCronCatchUp`, `hasPluginsBulkUpdate`, `hasPluginsAutoApply`, `hasModelReset`, `hasMCPServePlugin`.
- Add `HermesCapabilitiesTests` cases in the usual pattern: parse, all-on, degradation, patch-still-on.

### Phase 2: Compatibility fixes (S2–S3, must-ship)
- **S2 Providers (F2):** gate the Copilot ids on `hasCopilotInCore`, or on plugin presence (`plugins list` shows `github-copilot`). Tables pass 8/8. Credentials UI hides Copilot env vars on 0.23 unless the plugin is installed.
- **S3 Browser (F3/F4):** on 0.23, show the Camofox row only when the `camofox` plugin is installed. Otherwise keep a stored `camofox` visible with a "plugin required" hint and a `hermes plugins install camofox` Terminal hint, following the memory-provider precedent of no laundered installs. Re-verify the `local` and empty-value semantics.
- Fix every argv, parser or marker break that Phase 0 turns up (each one cited).

### Phase 3: New surfaces (S4–S7, prioritized; each gated, byte-identical on old hosts)
Recommended order, and each slice needs its own go-ahead:
1. **S4 ACP config options:** reasoning-effort and fast-tier pickers in the chat toolbar driven by `config_options` / `config_option_update`, plus `/model reset` in the model badge. Highest value; reuses the existing model-badge surface.
2. **S5 Cron:** Stop button (`cron cancel`) on running jobs, plus a per-job catch-up toggle.
3. **S6 Plugins:** "Update all" (`plugins update --yes`, only after explicit confirm), an auto-update toggle (`plugins.auto_apply`), a "disabled by update" state, and the Verified tier badge. Caution-scan findings must be shown before `--force` (no laundered consent).
4. **S7 Sessions & Skills:** a "Refresh prompts" action (`sessions refresh-prompts`) after editing SOUL.md or skills in Scarf, and a skill lock toggle (`curator lock`).
- **Deliberately out of scope (charter non-goals):** the Webapp, multi-gateway Desktop, group-chat lead routing and the delegation backend UI. At most, read-only status for `webapp.enabled` in Health. Bot Mode room purpose/notes only if Phase 0 shows they're stored where Scarf already reads.

### Phase 4: Real-host testing
- Alan installs Hermes **v0.23.0** locally (current local is v0.13.0). Also needed: one SSH remote on v0.23.0 and one held at v0.22.5, plus an old host (≤v0.21) for the byte-identical check.
- ScarfCore + app test suites, then `./scripts/build-detached.sh`.
- Live journeys in the scarf-ui Tart VM (unit tests alone missed three rewind bugs last cycle): chat start/resume/stop, `/undo` + `/retry`, permission prompts including the new MCP cost text, clarify forms, model switch and reset, reasoning/tier pickers, Browser settings with and without camofox, Copilot profile with and without the plugin, cron cancel, plugins update, gateway stop/restart refusal with a live session, and ScarfGo iOS chat over the gateway.
- Run `check-hermes-tables.py --tag v0.23.0` until it reports `lanes=8/8` and exits 0.

### Phase 5: Audit and record
- Fresh-eyes adversarial audit of the whole branch diff.
- Memory: `decisions/hermes-v0-23-compatibility-decisions`, `architecture/hermes-v0-23-wire-verification`, and update `project/hermes-version-targeting-strategy` (target → v0.23.0, local checkout note).
- Clean conventional commits on the branch. No push without Alan's say-so (C8); managed tiers stay uncommitted (C7).

## 3. Open questions for Alan
1. Install Hermes v0.23.0 locally now, so Phase 0 can probe a real `state.db` and real CLI output?
2. Which Phase 3 slices are in scope for this release: all four, or only S4 and the must-ship fixes?
