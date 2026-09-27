# S06-models-providers — verdict: WORKS-WITH-ISSUES

Hermes reference: `~/.hermes/hermes-agent-v0215` @ v2026.9.24 (0.21.5). `./scripts/check-hermes-tables.py --tag v2026.9.24` → `OK aliases=87 aggregators=7 overlays=25 lanes=5/5` (3 WARN overlay-only-now-in-models.dev = documented dormant fallbacks; 1 WARN plugin kimi-coding skipped, non-literal). The aggregator lane passing is the root of F1: the table mirrors `providers.py is_aggregator`, but that is the wrong source of truth for "does this provider natively use vendor/model ids".

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Pick a cloud model/provider (picker → `LocalModelConfigPlan` remote plan → `hermes config set model.provider/default` + clears) | WORKS | — |
| 2 | Model preflight + model/provider mismatch banner in chat | DEGRADED | F1 |
| 3 | Model presets + project preset binding (`model_presets.json`, manifest `modelPresetID`, ACP `session/set_model provider:model`) | WORKS | — |
| 4 | Local models (Ollama / LM Studio / vLLM / llama.cpp / custom): enumerate via curl, write base_url/api_key/api_mode then provider last | DEGRADED (llama.cpp only) | F2 |
| 5 | Credential pools: list (auth.json), add api-key, remove, reset (all / one), priority, refresh, strategy, OAuth logout | WORKS (default profile); DEGRADED under named profile | F3 |
| 6 | OAuth PKCE add (`OAuthFlowController`, `auth add <p> --type oauth --no-browser`) | WORKS (anthropic); DEGRADED (openrouter URL not detected) | F6 |
| 7 | Nous sign-in (`NousAuthFlow`, device code), subscription state, Nous model catalog | WORKS (sign-in); DEGRADED (subscription-required affordance, fallback catalog) | F4, F5 |
| 8 | Proxy service (`hermes proxy start/providers`) | WORKS | — |

## Findings

### S06-models-providers-F1 · P1 · SOURCE · NEW (contradicts premise of `.memory/decisions/aggregator-providers-must-skip-the-model-provider-mismatch.md` "[kept]" bullet)
- Claim: Every Nous Portal user whose `model.default` is a Nous model id (`anthropic/…`, `openai/…`, `moonshotai/…`) gets a false "Chats will fail at first prompt" mismatch banner, whose primary "Use anthropic" button rewrites `model.provider` away from Nous.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelPreflight.swift:116-119` (aggregator set excludes `nous`), `:164` (only aggregator/custom skip), `:171-187` (any slash → mismatch); caller `scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift:671-692`; banner/actions `scarf/scarf/Features/Chat/Views/ChatView.swift:290-318` (`Use <prefix>` → `alignProviderToModelPrefix` ChatViewModel.swift:715). Test pins the wrong behaviour: `Packages/ScarfCore/Tests/ScarfCoreTests/ModelPreflightTests.swift:142-157` (`anthropic/claude-sonnet-4.6` + `nous` ⇒ mismatch).
- Hermes @v2026.9.24: `hermes_cli/model_normalize.py:30-32` — `_AGGREGATOR_PROVIDERS = {"openrouter","nous","ai-gateway","kilocode"}` "Providers whose APIs consume vendor/model slugs"; Nous's own curated catalog `website/static/api/model-catalog.json` providers.nous.models = `anthropic/claude-fable-5.1`, `anthropic/claude-opus-5.5`, `openai/gpt-6-astra`, …; static fallback `hermes_cli/models_catalog_static.py:164` (`"nous": [mid for mid, _ in OPENROUTER_MODELS …]`); runtime evals resolve `requested="nous", target_model="anthropic/claude-fable-5.1"` (`evals/postmortem/live_ab/cache_prefix_live.py:28`). `providers.py:31` gives `nous` an overlay without `is_aggregator`, which is why Scarf's table-check passes.
- Failure scenario: user signs in to Nous in Scarf, picks `anthropic/claude-opus-5.5` from the Nous list (or `hermes model` writes it) → `model.provider: nous`, `model.default: anthropic/claude-opus-5.5`, a valid working config → chat shows "`model.default` is `anthropic/…` but `model.provider` is `nous`. Chats will fail…" with a prominent "Use anthropic" button; clicking it sets `model.provider: anthropic` (via `LocalModelConfigPlan` remote plan), breaking chats for a user with no Anthropic key. "Strip prefix" is harmless (Hermes re-prefixes for nous) but unnecessary.
- Evidence: `_AGGREGATOR_PROVIDERS` quote above; `ModelPreflight.aggregatorProviders = ["openrouter","opencode","opencode-go","kilo","huggingface","novita","vercel"]`.
- Suggested fix: add `nous` (and check `ai-gateway`/`kilocode` canonicalisation) to the skip set, sourced from `model_normalize._AGGREGATOR_PROVIDERS` rather than only `is_aggregator`; update the pinned test and the decision note.

### S06-models-providers-F2 · P2 · SOURCE · NEW
- Claim: Selecting the llama.cpp local provider writes `model.provider: llamacpp` + `model.base_url: <user URL>`, but at the tag Hermes' llamacpp rung ignores `model.base_url` and only uses its managed server or a probe of `127.0.0.1:8080`.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/LocalModelProviders.swift:149-160` (llamacpp descriptor, base_url required, placeholder 8080); plan writes it `LocalModelConfigPlan.swift:56-112` (provider = `descriptor.providerID` = `llamacpp`).
- Hermes @v2026.9.24: `hermes_cli/runtime_provider_custom.py:537-540` (`if requested_norm in _LLAMACPP_ALIASES and not explicit_base_url:` → `_resolve_llamacpp_runtime`), `:427-452` (managed state endpoint, else `detect_server`, else ValueError "The local model server is turned off…"); `hermes_cli/local_runtime/endpoint.py:77-104`; `hermes_cli/local_runtime/detect.py:16,40-43` (`DEFAULT_PROBE_PORTS = (8080,)`, root `http://127.0.0.1:{port}`). ACP passes no explicit base_url: `acp_adapter/session.py:502-503`; resolve errors are re-raised `:535-536`. `_raise_if_local_alias_missing_endpoint` explicitly exempts llamacpp (`runtime_provider.py:882`).
- Failure scenario: user runs `llama-server --port 8081` (or on another LAN host), picks llama.cpp in Scarf with that URL → config saved, preflight says configured → first prompt fails with "The local model server is turned off. Turn it back on in Settings → Providers → Local models" (a Hermes-desktop UI Scarf doesn't have). Works only when the server happens to be on 127.0.0.1:8080. (Memory note `local-provider-config-keys-hermes-reader-verified-v0-17-0.md` says llamacpp follows the ollama/custom path — true at 0.17, no longer at this tag.)
- Suggested fix: write `model.provider: custom` (or `vllm`, which still resolves to custom and honours base_url) for the llama.cpp row, keeping the display label.

### S06-models-providers-F3 · P2 · SOURCE · NEW
- Claim: Under a named profile, Credential Pools / Nous subscription / Nous catalog read only the profile's `auth.json`, but Hermes falls back per-provider to the root `~/.hermes/auth.json`, so credentials Hermes actually uses are shown as absent.
- Scarf: `scarf/scarf/Features/CredentialPools/ViewModels/CredentialPoolsViewModel.swift:114` (`ctx.paths.authJSON` = `<profile home>/auth.json`, `HermesPathSet.swift:64`); `scarf/scarf/Core/Services/NousSubscriptionService.swift:69,84-99`; `NousModelCatalogService.swift:151-170` (bearer from same file).
- Hermes @v2026.9.24: `hermes_cli/auth.py:870-893` (`read_credential_pool`: "In profile mode the global-root auth.json is a read-only fallback applied per provider ONLY when the profile has zero entries"), `:762-766` `_load_provider_state` (same fallback for `providers.<name>`, e.g. nous), `:494-503` `_global_auth_file_path`.
- Failure scenario: user signed in to Nous / added an OpenRouter key on the default profile, switches Scarf to profile `work` → Credential Pools shows the empty state, Nous picker says "Sign in to Nous Portal…", keepalive section shows no Nous — while chats in that profile run on the root credentials. Misleading, and invites a redundant sign-in that then shadows the root entry.
- Suggested fix: when home ≠ root, also read root `auth.json` and render inherited pools/providers per Hermes' rule (profile wins if it has any entry), badged "inherited".

### S06-models-providers-F4 · P3 · SOURCE · NEW
- Claim: Nous "subscription required" is never recognised, so the Subscribe button never appears; the sheet shows the raw tail instead.
- Scarf: `scarf/scarf/Core/Services/NousAuthFlow.swift:173-179, 237-248` (requires text "Your Nous Portal account does not have an active subscription").
- Hermes @v2026.9.24: `hermes_cli/auth_nous.py:1387-1393` prints `format_auth_error(exc)` then `  Subscribe here: {portal}/billing`, exit 1; message text comes from `auth.py:448` ("No active paid subscription found…") or `nous_account.py:234/277/281` ("…does not currently have paid service access…", "…has no active subscription or usable credits…"). None contains Scarf's phrase.
- Failure scenario: unsubscribed account → failure state with last 8 lines (URL visible as text) but no "Subscribe" affordance. Keying on `Subscribe here:` alone would fix it.

### S06-models-providers-F5 · P3 · SOURCE · NEW
- Claim: Nous model catalog fallback (shown when the fetch fails) lists only Hermes-3 models that Hermes itself filters out, and the live fetch doesn't apply Hermes' filter.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/NousModelCatalogService.swift:42-47` (fallback = 4 `Hermes-3-…` ids), `:173-195` (no filter; bearer = `providers.nous.access_token`).
- Hermes @v2026.9.24: `hermes_cli/auth_nous.py:725-727` ("Hermes models aren't reliable for agentic tool-calling" → excluded); curated list `website/static/api/model-catalog.json` providers.nous; Hermes fetches `/models` with runtime credentials (`hermes_cli/models.py:1363-1368`, `resolve_nous_runtime_credentials` → agent key), not the portal access token (whether the inference API accepts the portal access_token is UNVERIFIABLE without a live call).
- Failure scenario: offline / expired token → picker offers only `Hermes-3-Llama-3.1-405B` etc.; picking one writes a model Hermes considers unsuitable (and may not be served).

### S06-models-providers-F6 · P3 · SOURCE · NEW
- Claim: OpenRouter OAuth (offered because the gate returns `.ok`) never gets its authorization URL detected, so no auto-open / "Open in browser" button.
- Scarf: `scarf/scarf/Features/CredentialPools/ViewModels/OAuthFlowController.swift:506-519` (URL must contain `client_id=`, `/authorize` or `/oauth/`); gate `CredentialPoolsOAuthGate.swift:47-61`.
- Hermes @v2026.9.24: `hermes_cli/auth_constants.py:116` `OPENROUTER_AUTH_URL = "https://openrouter.ai/auth"`; printed at `hermes_cli/auth_openrouter.py:79-82` (`…/auth?callback_url=…`) and headless `:60-64`.
- Failure scenario: user adds OpenRouter with type OAuth → sheet stays on "Waiting for authorization URL…"; URL only visible in the raw output log (loopback still completes if the user copies it). Flow still judged correctly by exit code.

### S06-models-providers-F7 · P3 · SOURCE · NEW
- Claim: `imageGenModels` allowlist is stale vs the tag: missing `fal-ai/kling-image/v3/text-to-image` and `meta/muse-image/text-to-image`, and has no entries for the xai / meta-ai / openrouter image_gen plugins.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift:842-884` (comment says mirror @ v2026.9.7).
- Hermes @v2026.9.24: `tools/image_generation_catalog.py:355,368`; `plugins/image_gen/xai/__init__.py:25-39`, `plugins/image_gen/meta-ai/__init__.py:40-48`, `plugins/image_gen/openrouter/__init__.py:31,88`.
- Failure scenario: picker lacks those options; the custom-ID field still works, so impact is cosmetic.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `auth add <p> --type api-key --api-key K [--label L]` | argv | CredentialPoolsViewModel.swift:362-366 | subcommands/auth.py:12-23; auth_commands.py:359-374,377-410 (failures = SystemExit→exit 1) | OK (LIVE help) |
| `auth remove -- <p> <id\|idx>` | argv | CredentialPoolsViewModel.swift:642-645 | subcommands/auth.py:41-44; auth_commands.py:562-573 | OK (LIVE help) |
| `auth reset -- <p> [target]` | argv | :513, :634-639 | subcommands/auth.py:45-50; auth_commands.py:591-605 | OK |
| `auth priority -- <p> <target> <n>` | argv | :616-622 | subcommands/auth.py:51-55; auth_commands.py:483-493 | OK |
| `auth refresh -- <p> <target>` | argv | :627-630 | subcommands/auth.py:56-61; auth_commands.py:608-661 | OK |
| `auth logout -- <p>` + verdict strings | argv/output | :450-460; HermesCLIOutcome.swift:2151-2161 | auth.py:2309-2339 (new guest-tier arm `:2319-2324` → falls to "unconfirmed", benign) | OK |
| `config set credential_pool_strategies.<p> <s>` | config | :298-325 | credential_pool.py:602; strategies :119-127 | OK |
| `auth.json` `credential_pool.<p>[]` fields id/label/auth_type/source/access_token/last_status/request_count/expires_at(_ms)/agent_key_obtained_at | file shape | :663-711 | credential_pool.py:209-285 | OK |
| `auth.json` `providers.<p>` access/refresh/expires_at/obtained_at/portal_base_url | file shape | :143-188 | auth.py:786-804; auth_nous.py:1375-1382 | OK |
| Profile → root auth.json fallback | file path | :114; NousSubscriptionService.swift:69 | auth.py:494-503, 762-766, 870-893 | FINDING-F3 |
| `auth add <p> --type oauth --no-browser [--label]` + "Authorization code:" prompt, failure markers | argv/output | OAuthFlowController.swift:121-125, 401, 453-478 | anthropic_credentials.py:781-802; auth_commands.py:205,406 | OK |
| OAuth URL detection | output parse | OAuthFlowController.swift:506-519 | auth_constants.py:116; auth_openrouter.py:60-82 | FINDING-F6 |
| OAuth gate (useCLI for device-code/external) | UI routing | CredentialPoolsOAuthGate.swift:47-61 | auth_commands.py:244-296 | OK |
| `auth add nous --no-browser` device-code lines `1. Open:` / `2. If prompted, enter code:` | argv/output | NousAuthFlow.swift:88-96, 224-235 | auth_device_flow.py:299-300; auth_commands.py:305-344 | OK |
| Nous success = providers.nous.access_token + `active_provider == nous` | file | NousSubscriptionService.swift:93-99; NousAuthFlow.swift:180-205 | auth.py:786-804 (`set_active=True`); auth_nous.py:810-827 | OK |
| Nous subscription-required text | output parse | NousAuthFlow.swift:237-248 | auth_nous.py:1387-1393; auth.py:448 | FINDING-F4 |
| Nous stale-refresh from root `updated_at` | file | NousSubscriptionService.swift:101-104 | auth.py:720-722 (`isoformat()` w/ microseconds → default ISO8601DateFormatter returns nil, so staleness never shows; low impact) | OK (note) |
| Nous `/v1/models` fetch + fallback list | HTTP/catalog | NousModelCatalogService.swift:38-47, 151-195 | auth_nous.py:702-729; models.py:1363-1368 | FINDING-F5 |
| `~/.hermes/scarf/nous_models_cache.json` | Scarf file | NousModelCatalogService.swift:58,124-143 | — (Scarf-owned) | OK |
| `config set model.provider/model.default` (+ clears base_url/api_key/api_mode/context_length) | config | LocalModelConfigPlan.swift:117-187; HermesFileService.swift:2887-2903 | config.py:3479-3581 (provider switch also `drop_stale_model_route`, route_identity.py:86-103 — compatible) | OK |
| Local plan (ollama/lmstudio/vllm/custom) base_url→api_key→api_mode→default→provider | config | LocalModelConfigPlan.swift:56-112; LocalModelProviders.swift:109-174 | providers.py:134-135; auth.py:1331-1336; runtime_provider.py:65-70, 870-891; runtime_provider_backends.py:138; route_identity.py:47-83 (custom/local own the route) | OK |
| Local plan llamacpp | config | LocalModelProviders.swift:149-160 | runtime_provider_custom.py:427-452, 537-540; local_runtime/detect.py:16 | FINDING-F2 |
| `model.context_length` clear value `0`, other clears `""` | config | LocalModelConfigPlan.swift:46-48 | config.py:3248-3264 | OK |
| Empty `model.default` + loopback base_url = configured | preflight | ModelPreflight.swift:44-57 | runtime_provider.py:433-475 | OK |
| Mismatch detector aggregator set | preflight | ModelPreflight.swift:116-187 | model_normalize.py:30-32; model-catalog.json nous | FINDING-F1 |
| Local model enumeration `curl -sSf --max-time 3 <base>/api/tags|/v1/models`, `/api/show` batch | HTTP via transport | LocalModelEnumerator.swift:189-240, 311-331, 554-576 | — (talks to the model server, not Hermes) | OK |
| Model presets `~/.hermes/scarf/model_presets.json` | Scarf file | ModelPresetService.swift:77-127 | — | OK |
| Project binding `.scarf/manifest.json` `modelPresetID` | Scarf file | ProjectModelPresetBinding.swift:16-82; ProjectModelPresetReader.swift | — | OK |
| ACP `session/set_model` `modelId="<provider>:<model>"` | ACP | ChatViewModel.swift:1706-1758; ACPClient.swift:716-748 | acp_adapter/server.py:1015-1051, 315-359; models.py:763-791 | OK |
| `proxy start --provider P --host H --port N` | argv | HermesProxyService.swift:47 | proxy/cli.py:22-54; main.py:1891-1898 (rc→SystemExit) | OK (LIVE help) |
| `proxy providers` output parse | argv/output | HermesProxyService.swift:179-199 | proxy/cli.py:76-82 | OK |
| `models_dev_cache.json` + provider aliases / aggregators / overlays | file/tables | ModelCatalogService.swift:103-190, 894-1200 | checker lanes 5/5 | OK (script) |
| `modelAliases` (grok-4.20-beta, xAI retirements, deepseek-chat/reasoner) | table | ModelCatalogService.swift:752-804 | xai_retirement.py:16-25; model_normalize.py:94-95 (target now `deepseek-flash`; Scarf's `deepseek-v4-flash` still exists in models.dev, used only for validation lookup) | OK |
| `demotedProviders` (empty) | table | ModelCatalogService.swift:817 | — | OK |
| `imageGenModels` | table | ModelCatalogService.swift:842-884 | image_generation_catalog.py:40-380; plugins/image_gen/* | FINDING-F7 |
| Provider display names | table | ModelCatalogService.swift:136,154 | providers.py:142-148 | OK (cosmetic only) |
| ModelPresetsView | UI | Features/Models/Views/ModelPresetsView.swift | — (no Hermes touchpoints) | OK |

## Not audited / couldn't verify
- Whether `inference-api.nousresearch.com/v1/models` accepts the portal `access_token` (vs the agent-key JWT Hermes uses) — needs a live request.
- ACP main-agent handling of an empty `model.default` on a loopback custom endpoint: `acp_adapter/session.py:476,491` passes the raw config default, not `_get_model_config()`'s auto-detected one; did not trace AIAgent construction further.
- `ModelPickerSheet` / `SettingsViewModel` / `HermesFileService` model write helpers belong to other sections; only traced as far as the journeys here needed.
- OAuthKeepaliveCronService (cron section).
- iOS: only `Scarf iOS/Projects/ProjectDetailView.swift:215` reads the preset binding (read-only, same reader) — OK.
