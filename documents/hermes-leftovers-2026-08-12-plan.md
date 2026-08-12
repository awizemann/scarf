# Hermes leftovers run — 2026-08-12 orchestration plan

Owner: Claude (orchestrator, Fable 5). Approved by Alan: land straight to main, STT/TTS included, import-agent + sync deferred (stay in t-1cc0a505).

## Ground rules (every phase agent)
- Target Hermes v0.20.0 = local clone `~/.hermes/hermes-agent` at tag v2026.8.3 (HEAD). Source-verify every key/value against it — never trust the task text alone. Do NOT use origin/main (unreleased).
- Gate new UI on `HermesCapabilities` (isV020OrLater unless archaeology says otherwise); parsers stay version-agnostic. See memory: architecture/Hermes Capability Gating Pattern.
- Never commit managed tiers (.memory/, documents/, tasks/, TASKS.md, wiki/ …).
- Definition of done per phase: implement → `swift test` green (full ScarfCore) → macOS + iOS build succeed → self fresh-eyes audit (adversarial, incl. tests) → clean commit(s) to main with conventional message → report.
- Phases run SEQUENTIALLY (shared files: HermesConfig.swift, HermesConfig+YAML.swift, SettingsViewModel.swift).

## Phases
| # | Task | Scope | Model |
|---|------|-------|-------|
| P1 | t-72900077 | Browser settings fix: Scarf uses `browser.backend` + [browseruse, firecrawl, local]; v0.20 truth is `browser.cloud_provider` + browser-use/browserbase/firecrawl/local/camofox (tools_config.py:3602,4062,4715). Verify key history for gating; fix reader/writer/picker; tests. | Opus |
| P2 | t-bfd15aef | Reliable connect-time Hermes version read: persist + single cached probe per server connection (enabler for floors/nudges). | Opus |
| P3a | t-2e72ce08 | auxiliary.title_generation block + per-task reasoning_effort + approvals.smart_policy. | Sonnet |
| P3b | t-5d23ef3f | secrets.bitwarden.encrypted_cache + secrets.command.* + telemetry.shared_metrics + database.* knobs. | Sonnet |
| P3c | t-02eae1a0 | STT/TTS knob expansion (stt.language/openai/groq/local VAD; tts.speed/xai/deepinfra). | Sonnet |
| P3d | t-934fdf81 | gateway.profile_routes list editor (GatewayConfigWriter pattern; biggest UI lift). | Opus |
| P4 | — | Orchestrator audit vs plan, then independent fresh-eyes audit of the full landed diff; memory + task closeout. | Fable (me) + audit agent |

## Deferred (stay in t-1cc0a505)
import-agent onboarding flow; hermes sync surface; parked audit items (HERMES_ACP_SKIP_CONFIGURED_MCP, cron blueprints mirror, sanitizeFTSQuery cap, google_chat iOS probe).
