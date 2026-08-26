# Hermes v0.20.5 (v2026.8.19) — Scarf release audit

Audited 2026-08-26 against tag v2026.8.19 (commit fcbd1076a9, semver 0.20.5), diff range v2026.8.18..v2026.8.19 (~804 commits, ~323 PRs). Eight parallel surface audits, source-verified. Installed local binary was v0.20.0, so two findings are source-inferred (flagged below); everything else is cited to the tagged worktree.

## Verdict

- **state.db schema changed? NO.** SCHEMA_VERSION stays 26; `hermes_state_common.py` byte-identical; zero DDL changes across the whole diff. Only query/mutation-layer logic changed (pinned-session prune protection — CLI-side, Scarf is read-only).
- **Anything new reaching the ACP client unhandled? NO.** The entire `acp_adapter/` delta is model-picker catalog construction (Ollama native catalogs, custom-provider ids, empty-catalog suppression). `_ADVERTISED_COMMANDS`, session_update discriminators, set_mode, request_permission, prompt blocks: all unchanged. Bot Mode threads / foldable summaries / PDF attachments / multi-question clarify are desktop-renderer, gateway, or degrade-to-existing-shape — none cross the wire.

**⇒ Light additive cycle, not a parity push.** But it is not zero-work: one hard CLI break plus provider-table drift.

## Forced by the upgrade

1. **[BREAKING] `hermes version` subcommand removed.** Dropped from `_BUILTIN_SUBCOMMANDS` (`hermes_cli/main.py:11648`); `hermes_cli/subcommands/version.py` deleted; bare `hermes version` now falls through to plugin discovery → chat prompt (burns an agent turn). `--version` (`main.py:13955`) now carries the full output including the `commits behind` line. Scarf call sites: `HealthViewModel.swift:164` and `:346` (greps `commits behind` at `:176`). **Fix is capability-aware**: on <0.20.5 hosts `--version` prints the short form (verified live on v0.20.0) and `version` gives update status — so gate the argv on the host version (`isV0205OrLater ? ["--version"] : ["version"]`). Source-inferred (installed binary predates removal); confidence high on removal, medium-high on chat-prompt fallback.
2. **[ADD] `opencode-free` provider (zero-auth OpenCode tier, aggregator, keyless).** `check-hermes-tables.py` FAILs ×3. Needed: `overlayOnlyProviders` entry (base `https://opencode.ai/zen/v1`), `providerAliases` `free`/`opencode_free`, `ModelPreflight.aggregatorProviders` `opencode-free`, display name "OpenCode Free" (`hermes_cli/providers.py:160,343-344,441`; `models.py:1416-1417`). Also: Hermes overlays gained `keyless: Bool` — Scarf's `HermesProviderOverlay` (`ModelCatalogService.swift:1078`) doesn't model it, so the provider UI would show a pointless API-key row; add the flag + a "no key needed" state. `hermes_cli/auth.py:487-497` confirms deliberately empty `api_key_env_vars`.
3. **[CHANGE] `agent.max_turns` default flipped 500 → unlimited** (`config_defaults.py:46-50`, `TURN_LIMIT_UNLIMITED`, accepts `none/unlimited/inf/0/-1`). Scarf displays 500 as the v0.20+ host default (`HermesConfig.swift:1199-1201`, `AgentTab.swift:12-15`, iOS `SettingEditorSheet.swift:184-188` range 1...500) and cannot express unlimited. Capability-gate the displayed default and add an "unlimited" write path.
4. **[CHANGE] `stt.provider` no longer seeded** (`config_defaults.py:1715-1720`): unset now means autodetect ladder, not "local". Scarf defaults the picker to "local" (`HermesConfig+YAML.swift:113`), inviting the user to pin a provider and disable autodetect. Add an "Auto (unset)" option wired to `unsetSetting`.
5. **[VERIFY→FIX] `profile list` now renders `name (display_name)`** via `format_profile_label` (`hermes_cli/profiles.py`). Scarf's `parseProfileList` (`ProfilesViewModel.swift:221`) would carry the suffix into `profile use/show` argv. Confidence medium — verify against a real v0.20.5 binary, then strip a trailing ` (…)`. (`profile show` reformat is cosmetic-only; Scarf displays it verbatim.)
6. **[GATE] New capability group** `// MARK: v0.20.5 (v2026.8.19) flags`: `isV0205OrLater` + at least `hasVersionFlagFullOutput` (finding 1), `hasCronReasoningEffort` (`cron create/edit --reasoning-effort`, `hermes_cli/subcommands/cron.py:108,244` — argparse rejects unknown args on older hosts), and flags for any adopted settings below. Skill note: per convention gate on the patch only because these are patch-introduced surfaces (same as the v0.20.4 `isV0204OrLater` group).

## Behavior changes, no code forced

- `sessions delete` now excludes pinned sessions by default and may print a pinned warning; Scarf checks exit code only (`ChatViewModel.swift:470`) — safe, but deleting a pinned session can silently no-op. Consider surfacing pinned state in the delete flow.
- `sessions rename` rejects empty/newline titles; Scarf already trims, newline unguarded (low risk).
- `sessions import/delete/prune` now return non-zero on real failures (previously exit 0). No Scarf call site relies on the old laxness.
- `doctor` gained additive rows (capability ok-rows, Relay migration); row format unchanged.
- `gateway start/stop/status` internals rewritten to `launchctl print` PID discovery (`hermes_cli/gateway.py` +325); printed output unchanged — **smoke-test gateway controls after the target bump**.
- Cron jobs now run with persistent memory (`skip_memory=False`, memory toolset no longer force-disabled) — scheduler-side, nothing to parse; no Scarf copy asserts the old behavior.
- `jobs.json` gains optional `reasoning_effort` (conditionally persisted); Scarf round-trips it losslessly via the extras sweep (`HermesCronJob.swift:157,271`). If surfaced in the editor, validate `none|minimal|low|medium|high|xhigh|max|ultra`.

## Optional adoption candidates

- **Web keyless tier** (web-search, not providers): `web.keyless_fallback` (bool, default true), `web.keyless_rescue` (bool, default true), `web.provider_tier.<vendor>: free|paid` (exa/parallel/tavily/firecrawl/**keenable** — keenable is a new backend, `KEENABLE_API_KEY`). Settings fields next to the web backend picker.
- `agent.run_budget_seconds` (wall-clock budget, wrap-up at 80%) — natural neighbor of Max Turns. Also `agent.stall_guards` (bool), `agent.execution_guidance` (auto|bool|list), `model.reasoning_echo` (advanced).
- Cron per-job reasoning-effort field in the editor (gated).
- Update receipts: `<HERMES_HOME>/logs/update_receipts/latest.json` (+ rotated last 20) — machine-readable update diagnosis for the Health panel. `hermes update` also gained `--plan`/`--keep-stash` (Scarf has no update affordance today).
- `hermes worktree list/prune` — net-new verb, future surface.
- `skills uninstall --yes` now exists (`subcommands/skills.py:185-191`) — only relevant if Scarf ever wires that verb (hangs without `-y` on ≥0.20.5, rejects `-y` on ≤0.20.4).
- New MCP OAuth per-server keys (`oauth: client_metadata_url/cimd/user_agent`); Scarf's line patcher round-trips them safely — future editor surface.
- `tool_budget.mcp_result_size_chars` (default 50000) + 2 MB hard cap with truncation markers — no Scarf consumer.
- `_config_version` 37 → 38 (migration v38 strips a legacy Relay plugin; Scarf doesn't write `plugins.enabled`).

## Pre-existing issues found in passing

- `ModelPreflight.aggregatorProviders` contains bare `"opencode"` but canonical aggregator ids are `opencode-zen`/`opencode-go`/(now)`opencode-free` (`models.py:1296`) — confirm against `canonicalProviderID`; `opencode-zen` may never have been covered.
- `gateway_restart_notification` default mismatch: Hermes true (`gateway/config.py:657`), Scarf models false (`GatewayPlatformSettings.swift:57`) — confirm against the parser before treating as a bug.

## Watch / verify-further

- **Compaction semantics**: `agent/context_compressor.py` is a NEW file in this window (native_compaction.py +264, conversation_loop.py +204). Scarf's v2.20.0 compaction-summary styling mirrors `ContextCompressor.classify_summary_content` — verify the classifier didn't move/change before assuming our marker classification still matches.
- Relay exclusivity: with `GATEWAY_RELAY_URL` set, all messaging platforms except local/api_server/webhook are force-disabled even if enabled in config (`gateway/config.py:2764-2808`; escape hatch `GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS=true`). Scarf-written platform config would silently never come up — candidate for a Health/setup banner.
- Image-gen selection key `image_gen.use_gateway` (bool) → `image_gen.provider: <vendor>|nous` (old key read-legacy, never written). Scarf's `AuxiliaryTab.swift:11` copy still describes `use_gateway`; `HermesConfig+YAML.swift:526` parses only `image_gen.model`. New `provider: openrouter` exposes a 40+ model live catalog.
- Release-note lie check: nothing contradicted outright this cycle; "keyless web tier" is web-search (not model providers), and TUI items (fuzzy /model, Ctrl+P) confirmed unreachable from non-TTY spawns.

## Explicit NO-OPs (don't re-litigate)

state.db DDL; ACP wire; MCP catalog/`mcp add`/curator/skills-hub tables/bundled-skill roster; gateway platform roster + allowlist location + `gateway list` shape; FTS/search builders; managed scope (only GATEWAY_RELAY_* routing vars allowlisted); xai_retirement.py unchanged; demoted providers unchanged; `_PROVIDER_MODELS` churn (Scarf reads live catalog, no remaps shipped); security commits (Electron auth-header, memory store perms, Docker bootstrap, tombstone fix) all server/desktop-side; `pairing`, `status`, `tools list`, `mcp`, `config`, `plugins install` argv all verified unchanged.

## Suggested phasing (pending Alan's scope call)

- **Phase 1 (fixes)**: version→`--version` gated argv; opencode-free tables + keyless flag (check-hermes-tables → exit 0); profile-list parser hardening (after live verify); max_turns unlimited display/write; stt.provider "Auto"; `isV0205OrLater` group + capability tests (parse version line, all-flags-on, v0.20.4-host degradation, patch-still-on).
- **Phase 2 (adopt)**: web keyless settings, run_budget_seconds, cron reasoning-effort editor, update receipts in Health.
- **Verify**: compaction classifier drift; gateway smoke test; pinned-delete UX.

Branch: `feat/hermes-v0205-parity`. Hand off to `scarf-release-prep` after implementation.
