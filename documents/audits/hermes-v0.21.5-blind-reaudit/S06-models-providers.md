# S06-models-providers — verdict: WORKS-WITH-ISSUES

Ground truth: `~/.hermes/hermes-agent-v0215` @ `v2026.9.24` (installed `hermes` = 0.21.5).
`./scripts/check-hermes-tables.py --tag v2026.9.24` → `OK aliases=87 aggregators=8 overlays=25 env-vars=54 mcp-catalog=65 lanes=7/7` (WARNs only: dormant overlays arcee/lmstudio/tencent-tokenhub, kimi-coding plugin not statically readable). Lanes 1–7 are counted as coverage for providerAliases, aggregatorProviders, overlayOnlyProviders, plugin-provider reachability, capabilityProviderOverrides, providerEnvVars and the optional-MCP catalog.

Argv checks were done two ways: against `hermes_cli/subcommands/auth.py` source, and by building Hermes's own `auth` argparse subparser in its venv and calling `parse_args` on Scarf's exact argv shapes (pure parsing, nothing executed). Every shape parsed as intended, including the `--` forms.

## Journeys

| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Pick a remote model/provider in the picker → `model.provider`/`model.default` (+ scrub of local keys) | DEGRADED | S06-F1 |
| 2 | Model preflight / mismatch / llama.cpp base_url banner | WORKS (does not catch F1) | — (F1 affects its "configured" verdict) |
| 3 | Model presets CRUD + project binding → `session/set_model` (Mac + iOS applier) | WORKS | — |
| 4 | Local models: enumerate (Ollama `/api/tags`, OpenAI `/v1/models` via curl on the Hermes host) + config plan | WORKS | — |
| 5 | Credential pools: list (auth.json + root fallback), add api-key, remove, reset, priority, refresh, strategy | WORKS | — |
| 6 | Generic OAuth (`auth add <p> --type oauth --no-browser`), CLI-routing gate, post-OAuth provider swap | WORKS | S06-F3 (cosmetic) |
| 7 | Nous sign-in (device code), subscription state, keepalive nudge, Nous `/models` catalog | WORKS (the keepalive nudge never shows) | S06-F2 |
| 8 | OAuth provider logout (`auth logout -- <p>`) | WORKS | — |
| 9 | Hermes proxy (`proxy start/providers`) | WORKS | — |
| 10 | Catalog tables not covered by the checker: modelAliases, demotedProviders, imageGenModels, display names | WORKS (one stale alias) | S06-F4 |

## Findings

### S06-F1 · P1 · SOURCE (plus an in-process call of Hermes's own resolver) · NEW
- **Claim:** The Remote model picker lists every provider in `models_dev_cache.json` (223 on this Mac) and saves the models.dev id verbatim as `model.provider`. Hermes 0.21.5 can't route 186 of those ids, including mainstream ones: `mistral`, `groq`, `cerebras`, `togetherai`, `perplexity`, `cohere`, `moonshotai`, `zhipuai`, `venice`, `siliconflow`, `chutes`. So the save "succeeds", preflight says configured, and chat then fails with `Unknown provider '<id>'` or silently runs on another provider.
- **Scarf:**
  - `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift:132-190`: `loadProviders` adds every catalog key with no routability filter.
  - `scarf/scarf/Features/Settings/Views/Components/ModelPickerSheet.swift:1402-1419`: saves `selectedProviderID` raw. `validateModel` returns `.valid` because the model is in the catalog.
  - `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelPreflight.swift:41-64`: reports `.configured`.
- **Hermes @v2026.9.24:**
  - `hermes_cli/runtime_provider.py:975-1005,1040-1048`: the ladder calls `resolve_provider(requested_provider)` after the named-custom and local-bypass rungs.
  - `hermes_cli/auth.py:1500-1509`: anything that is not `openrouter`/`custom` and not in the registry raises `AuthError("Unknown provider '…'")`. The registry includes plugin providers via `hermes_cli/auth_plugin_providers.py:140-147`.
  - `hermes_cli/runtime_provider_custom.py:467-481`: only `_DIRECT_API_BASE_URLS` names such as `openai` are expanded to `custom` first.
  - `acp_adapter/session.py:500-537`: the ACP session swallows the resolve error, builds `AIAgent` without a provider, and re-raises only if that build fails. So the chat either errors, or runs on whatever fallback provider or key exists.
  - `hermes_cli/models_catalog_static.py`: `CANONICAL_PROVIDERS` has 53 ids and contains none of the ones above.
- **Failure scenario:** The user opens Settings → Model, picks "Mistral" and `mistral-large-latest`, and sees it saved. `config.yaml` now has `model.provider: mistral`. The next chat fails with "Unknown provider 'mistral'. Check 'hermes model'…" (or answers from a different provider if another key is configured). Setting `MISTRAL_API_KEY` doesn't help, because resolution fails before any key lookup.
- **Evidence:** Ran Hermes's `auth.resolve_provider` in its venv (pure call, no side effects):
  - `mistral`, `groq`, `cerebras`, `togetherai`, `moonshotai`, `zhipuai`, `perplexity`, `cohere`, `venice`, `siliconflow`, `chutes` → `X Unknown provider`.
  - `google`→`gemini`, `amazon-bedrock`→`bedrock`, `azure`→`azure-foundry`, `fireworks-ai`→`fireworks` resolve fine.
  - `auth.is_runtime_provider_routable` fails for 186 of 223 cached keys. Some of those (for example `openai`, which `expand_direct_api_alias` rescues) do work at runtime, so 186 is an upper bound.
- **Ledger:** nothing in TASKS.md, tasks/ or `.memory/decisions/` covers this. The v0.16 note "`mistral` stays un-demoted" assumed Mistral is usable.
- **Suggested fix:** Limit the Remote roster, or visibly mark rows as not supported by Hermes, to ids that resolve through the canonical providers, aliases and plugin providers. Alternatively, write a `providers.<id>` entry for models.dev-only providers. Also teach preflight to flag an unroutable `model.provider`.

### S06-F2 · P3 · SOURCE (+ swift parse probe) · NEW
- **Claim:** The Nous "last refreshed N days ago — enable keepalive" nudge can never appear. `NousSubscriptionService` parses auth.json's root `updated_at` with a default `ISO8601DateFormatter`, which rejects fractional seconds, and Hermes always writes microseconds.
- **Scarf:**
  - `scarf/scarf/Core/Services/NousSubscriptionService.swift:126-129`: `ISO8601DateFormatter().date(from: raw)`.
  - Consumers `:43-59` (`daysSinceLastRefresh`, `hasStaleRefresh`) and `scarf/scarf/Features/CredentialPools/Views/CredentialPoolsView.swift:200,219` get nil and never render the warning.
- **Hermes @v2026.9.24:** `hermes_cli/auth.py:723`: `auth_store["updated_at"] = datetime.now(timezone.utc).isoformat()`, for example `2026-09-27T12:34:56.123456+00:00`.
- **Failure scenario:** A user who hasn't run Hermes for more than 14 days, with keepalive off, never sees the orange staleness warning the section promises.
- **Evidence:** A swift probe of `ISO8601DateFormatter().date(from: "2026-09-27T12:34:56.123456+00:00")` returned `nil`. The same string with `.withFractionalSeconds` parses. `NousModelCatalogService.parseISODate` (`NousModelCatalogService.swift:291-301`) already handles this shape.
- **Suggested fix:** Reuse `NousModelCatalogService.parseISODate`, or add `.withFractionalSeconds` with a plain fallback.

### S06-F3 · P3 · SOURCE · NEW
- **Claim:** Anthropic OAuth in Credential Pools opens two identical browser tabs on a local Mac. Scarf passes `--no-browser` and opens the URL itself, but Hermes's Anthropic PKCE login ignores `--no-browser` and calls `webbrowser.open` whenever a graphical browser is available.
- **Scarf:** `scarf/scarf/Features/CredentialPools/ViewModels/OAuthFlowController.swift:119-121` (argv carries `--no-browser`) and `:389-396` (auto `NSWorkspace.shared.open` on first URL detection).
- **Hermes @v2026.9.24:**
  - `hermes_cli/auth_commands.py:201-205`: `_anthropic_oauth_login` never looks at `args`.
  - `agent/anthropic_credentials.py:772-778`: `if _can_open_gui(): webbrowser.open(auth_url)`.
  - `hermes_cli/auth_device_flow.py:68-88`: that check returns True on macOS.
- **Failure scenario:** Local "Add credential → anthropic → OAuth" opens the claude.ai authorize page twice. Harmless, but it looks like a glitch.
- **Suggested fix:** Skip Scarf's auto-open for providers whose login ignores `--no-browser` (anthropic), or open only when Hermes didn't print "(Browser opened automatically)".

### S06-F4 · P3 · SOURCE · NEW
- **Claim:** `modelAliases` sends the retired `deepseek/deepseek-chat` and `deepseek/deepseek-reasoner` to `deepseek-v4-flash`. At the tag, Hermes sends them to `deepseek-flash`, and the comment claiming otherwise is wrong. The picker and validation therefore show a stored `deepseek-chat` as a different model (with that model's metadata) than the one Hermes actually calls.
- **Scarf:** `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift:758-763`.
- **Hermes @v2026.9.24:** `hermes_cli/model_normalize.py` `_DEEPSEEK_RETIRED_ALIASES = {"deepseek-chat": "deepseek-flash", "deepseek-reasoner": "deepseek-flash"}`. Both `deepseek-flash` and `deepseek-v4-flash` exist in the local models.dev cache, so nothing is rejected; the information shown is just wrong.
- **Suggested fix:** Retarget both entries to `deepseek-flash`.

## Touchpoint inventory

| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `hermes config set model.provider/model.default` (picker, swap) | config key | ModelPickerSheet.swift:1402-1419; CredentialPoolsView.swift:1234-1247 | runtime_provider.py:478-487,975+ | FINDING-S06-F1 (unroutable ids) / OK for canonical ids |
| `model.base_url`/`api_key`/`api_mode` set/clear (`""`), `model.context_length` clear (`"0"`) | config key | LocalModelConfigPlan.swift (`operations`) | runtime_provider_custom.py:523-576; agent/agent_init.py:1797-1807; agent/model_metadata.py:2225 | OK |
| Local provider ids ollama/vllm/llamacpp→custom, lmstudio, custom | config value | LocalModelProviders.swift:260-327, :158-163 | auth.py:1331-1336; providers.py:134-135; runtime_provider_custom.py:537-544 | OK |
| Empty-model loopback auto-detect gate | config semantics | ModelPreflight.swift:52-57; LocalModelProviders.swift:227-232 | runtime_provider.py:433-476 (hostname in localhost/127.0.0.1) | OK (comment line refs stale) |
| llamacpp ignores base_url banner | config semantics | ModelPreflight.swift:202-218 | runtime_provider_custom.py:537-540 | OK |
| aggregator / copilot / codex / nvidia prefix sets | table | ModelPreflight.swift:133-166 | model_normalize.py:30-83 | OK (lane 2) |
| `curl <host>/api/tags`, `/api/show`, `<base>/v1/models` on the Hermes host | transport argv | LocalModelEnumerator.swift:189-240,311-331,393-405,554-577 | (server APIs, not Hermes) | OK |
| `auth.json` `credential_pool.<p>[]` fields id/label/auth_type/source/access_token/last_status/request_count/expires_at(_ms)/agent_key_obtained_at | file shape | CredentialPoolsViewModel.swift:691-739 | agent/credential_pool.py:209-285 | OK |
| `auth.json` `providers.<p>` access/refresh/expires_at/obtained_at/portal_base_url | file shape | CredentialPoolsViewModel.swift:171-216 | auth_nous.py:1373-1381 | OK |
| Root auth.json per-provider fallback under a named profile | file semantics | HermesAuthFallback.swift:34-126 | auth.py:748-766,870-893 | OK |
| `credential_pool_strategies.<p>` | config key | CredentialPoolsViewModel.swift:326-353 | agent/credential_pool.py:599-606 | OK |
| `auth add <p> --type api-key --api-key K [--label L]` | argv | CredentialPoolsViewModel.swift:382-405 | subcommands/auth.py:12-38; auth_commands.py:359-374,377-406 (SystemExit→1) | OK |
| `auth remove -- <p> <target>` | argv | CredentialPoolsViewModel.swift:442-460,670-673 | subcommands/auth.py:41-44; auth_commands.py:562-573 | OK |
| `auth reset -- <p> [target]` | argv | CredentialPoolsViewModel.swift:536-553,606-619,662-667 | subcommands/auth.py:45-50; auth_commands.py:591-605 | OK |
| `auth priority -- <p> <target> <n>` | argv | CredentialPoolsViewModel.swift:574-585,644-650 | subcommands/auth.py:51-55; auth_commands.py:483-493 | OK |
| `auth refresh -- <p> <target>` | argv | CredentialPoolsViewModel.swift:592-601,655-658 | subcommands/auth.py:56-61; auth_commands.py:608-661 | OK |
| `auth logout -- <p>` + output verdict | argv/output | CredentialPoolsViewModel.swift:478-534; HermesCLIOutcome.swift:2233-2273 | auth_commands.py:693-699; auth.py:2309-2337 | OK (the free-tier guest arm only exists behind the pre-GA `HERMES_GUEST_ONBOARDING=1` gate; out of scope) |
| `auth add <p> --type oauth --no-browser [--label]` + URL/prompt/failure markers | argv/output | OAuthFlowController.swift:110-154,386-528 | auth_commands.py:201-205,244-296,413-441; anthropic_credentials.py:752-803 | OK / FINDING-S06-F3 |
| OAuth-style gate (device/external/process → CLI) | table | CredentialPoolsOAuthGate.swift:47-61 | providers.py:28-53 (auth_type) | OK |
| `auth add nous --no-browser` device-code parse + subscription-required parse | argv/output | NousAuthFlow.swift:99-133,265-304 | auth_device_flow.py:299-300; auth_nous.py:1386-1394; auth_commands.py:305-345 | OK |
| auth.json `providers.nous.access_token` (signed-in) | file | NousSubscriptionService.swift:121-124 | auth_nous.py:810-827 | OK |
| auth.json root `updated_at` | file | NousSubscriptionService.swift:126-129 | auth.py:723 | FINDING-S06-F2 |
| Nous `GET <inference_base_url>/models` with agent_key, "hermes" filter, fallback ids | network/table | NousModelCatalogService.swift:77-106,242-282,345-377 | auth_nous.py:702-729; models_catalog_static.py (fallback ids all present) | OK |
| `~/.hermes/scarf/nous_models_cache.json`, `model_presets.json` | Scarf-owned file | HermesPathSet.swift:116,127 | — | OK (not a Hermes touchpoint) |
| `.scarf/manifest.json` `modelPresetID` | Scarf-owned file | ProjectModelPresetReader.swift:23-42; ProjectModelPresetBinding.swift:40-116 | — | OK |
| ACP `session/set_model` `<provider>:<model>` | ACP | ProjectModelPresetApplier.swift:40-80 | acp_adapter/server.py:315-359,1015-1051 | OK |
| `proxy start --provider P --host H --port N`; `proxy providers` parse | argv/output | HermesProxyService.swift:88-90,263-283 | proxy/cli.py:22-54,76-82; main.py:1891-1898 | OK (live `--help` confirms flags) |
| `models_dev_cache.json` roster | file | ModelCatalogService.swift:116-190 | agent/models_dev.py | FINDING-S06-F1 |
| providerAliases / capability overrides / overlays / env vars | table | ModelCatalogService.swift:559-1440; HermesProviderCredentials.swift | providers.py, models_dev.py, auth.py | OK (checker lanes 1–6) |
| modelAliases (xAI retirements) | table | ModelCatalogService.swift:752-783 | xai_retirement.py:16-25 | OK |
| modelAliases (DeepSeek) | table | ModelCatalogService.swift:758-763 | model_normalize.py `_DEEPSEEK_RETIRED_ALIASES` | FINDING-S06-F4 |
| demotedProviders (empty) | table | ModelCatalogService.swift:817 | (no deprioritized list at tag) | OK |
| imageGenModels | table | ModelCatalogService.swift:844-936 | tools/image_generation_catalog.py; plugins/image_gen/* | OK (per-cited catalogs) |
| providerDisplayNameOverrides | table | ModelCatalogService.swift:1440-1443 | providers.py:140-148 | OK (cosmetic; not a mirror) |

## Not audited / couldn't verify
- No OAuth, sign-in or proxy flow was run live (not allowed). OAuth and device-code output formats were checked against source only.
- Remote OpenRouter PKCE OAuth (its loopback callback lands on the Mac's localhost, not the remote host's) and a Scarf launched from a terminal (a Nous "Import shared credentials?" prompt could read the inherited tty) are unusual setups and were not pursued.
- The ModelPickerSheet UI internals (S05 territory) were read only far enough to confirm what F1 writes.
- In F1, the exact runtime result when a *fallback* provider exists (error vs silently using another provider) depends on the user's keys. Both outcomes are wrong; which one a given user gets isn't determined.
