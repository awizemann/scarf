# S06-models-providers — verdict: WORKS-WITH-ISSUES

Everything primary works against v2026.9.24. One P3: the Proxy help card tells users to run a deprecated command that also has the wrong syntax. `./scripts/check-hermes-tables.py --tag v2026.9.24` passes all 8/8 lanes (aliases=87, aggregators=8, overlays=25, env-vars=54, routable=194). The only warnings are for the deliberate dormant overlays and for the kimi-coding plugin, which the script cannot read statically.

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Main model picker (Settings → General): remote/catalog selection writes model.provider/model.default via `config set --` and clears local keys on a provider switch (LocalModelConfigPlan) | WORKS | — |
| 2 | Local-model picker (Ollama/LM Studio/vLLM/llama.cpp/custom): enumerate over curl, then write base_url/api_key/api_mode/default with provider written last | WORKS | — |
| 3 | Delegation picker writes delegation.model/provider (Hermes tools/delegate_tool_config.py:351-380 resolves them through resolve_runtime_provider) | WORKS | — |
| 4 | Chat model preflight: missing, unroutable and mismatched provider (ModelPreflight). Routable/aggregator tables match the tag (script lanes) | WORKS | — |
| 5 | Model presets + project binding: preset applied via ACP `session/set_model` with `provider:model` (acp_adapter/server.py:1015, parse_model_input at :330) | WORKS | — |
| 6 | Credential pools: list (auth.json + root fallback), then add api-key / remove / reset / priority / refresh / logout | WORKS | — |
| 7 | OAuth add (Anthropic PKCE paste-code, OpenRouter, others via `auth add <p> --type oauth --no-browser`) | WORKS | — |
| 8 | Nous sign-in (device code, `auth add nous --no-browser`), subscription-required parse, auth.json confirmation | WORKS | — |
| 9 | Nous model catalog (inference `/v1/models`, agent_key bearer, cache) | WORKS | — |
| 10 | Hermes Proxy: `proxy providers` list, `proxy start --provider --host --port` (local only), exit status | DEGRADED | S06-F1 (help text only) |

## Findings
### S06-models-providers-F1 · P3 · LIVE · NEW
- Claim: The Proxy view's help card tells users to sign in with `hermes login <provider>`. At the tag that verb is deprecated and prints only a notice. It takes no positional argument, so `hermes login nous` fails with an argparse error.
- Scarf: scarf/scarf/Features/Proxy/Views/HermesProxyView.swift:190
- Hermes @v2026.9.24: hermes_cli/subcommands/login.py:8-44 ("Deprecated…", handler only prints a notice, `--provider` flag only). The real hints are at hermes_cli/proxy/cli.py:34 (`hermes auth add {name}`) and hermes_cli/proxy/adapters/xai.py:26 (`hermes auth add xai-oauth --type oauth`).
- Failure scenario: `proxy start` fails with "Not logged into …". The user follows the card, runs `hermes login nous` and gets an argparse error ("unrecognized arguments") or a deprecation notice. Sign-in never happens. Hermes's own stderr line in the Scarf log does show the correct command.
- Evidence: `hermes login --help` → "Deprecated. Use `hermes auth` to manage credentials…"; the usage line shows no positional.
- Suggested fix: change the text to `hermes auth add nous` (or `hermes auth add xai-oauth --type oauth` for xai), or point to Scarf's own Nous sign-in / Credential Pools.

## File coverage
| File | Hermes touchpoints? | Status |
|---|---|---|
| Packages/ScarfCore/.../Models/ModelPreset.swift | no | NO-TOUCHPOINT |
| .../Services/HermesAuthFallback.swift | yes (auth.json root fallback) | OK |
| .../Services/HermesProviderCredentials.swift | yes (provider env vars) | OK (env-vars lane passes) |
| .../Services/HermesRoutableProviders.swift | yes (routable ids) | OK (routable lane passes) |
| .../Services/LocalModelConfigPlan.swift | yes (config set model.*) | OK |
| .../Services/LocalModelEnumerator.swift | no Hermes; local server HTTP (/api/tags, /v1/models) | OK |
| .../Services/LocalModelProviders.swift | yes (local provider ids/aliases) | OK (auth.py:1331-1336, providers.py:134-135) |
| .../Services/ModelCatalogService.swift | yes (models.dev cache, aliases, overlays) | OK (aliases/overlays lanes pass) |
| .../Services/ModelPreflight.swift | yes (config model/provider, aggregators) | OK |
| .../Services/ModelPresetService.swift | no (Scarf-owned model_presets.json) | NO-TOUCHPOINT |
| .../Services/NousModelCatalogService.swift | yes (auth.json providers.nous, inference /v1/models) | OK |
| .../Services/ProjectModelPresetApplier.swift | yes (ACP session/set_model) | OK |
| .../Services/ProjectModelPresetReader.swift | no (Scarf manifest) | NO-TOUCHPOINT |
| scarf/Core/Services/HermesProxyService.swift | yes (proxy start/providers) | OK |
| scarf/Core/Services/NousAuthFlow.swift | yes (auth add nous --no-browser) | OK |
| scarf/Core/Services/NousSubscriptionService.swift | yes (auth.json providers.nous, updated_at) | OK |
| scarf/Core/Services/ProjectModelPresetBinding.swift | no (Scarf manifest) | NO-TOUCHPOINT |
| Features/CredentialPools/ViewModels/CredentialPoolsOAuthGate.swift | yes (overlay auth types) | OK |
| Features/CredentialPools/ViewModels/CredentialPoolsViewModel.swift | yes (auth add/remove/reset/priority/refresh/logout; auth.json; config credential_pool_strategies) | OK |
| Features/CredentialPools/ViewModels/OAuthFlowController.swift | yes (auth add <p> --type oauth) | OK |
| Features/CredentialPools/Views/CredentialPoolsView.swift | via VM only | OK |
| Features/Models/ViewModels/ModelPresetsViewModel.swift | reads config custom providers | OK |
| Features/Models/Views/ModelPresetEditSheet.swift | UI only | NO-TOUCHPOINT |
| Features/Models/Views/ModelPresetsView.swift | UI only | NO-TOUCHPOINT |
| Features/Proxy/ViewModels/HermesProxyViewModel.swift | via service | OK |
| Features/Proxy/Views/HermesProxyView.swift | help text naming a CLI verb | FINDING-F1 |
| Features/Settings/Views/Components/ModelPickerRow.swift | via host callbacks | OK |
| Features/Settings/Views/Components/ModelPickerSheet.swift | catalog, Nous catalog, local enumerator, auth.json read | OK |
| Features/Settings/Views/Components/NousSignInSheet.swift | via NousAuthFlow | OK |

## Touchpoint inventory
| Touchpoint | Kind | Scarf | Hermes | Status |
|---|---|---|---|---|
| `auth add <p> --type api-key --api-key K [--label L]` | argv | CredentialPoolsViewModel.swift:390 | auth_commands.py:357-374,377 (SystemExit on failure) | OK (LIVE --help) |
| `auth add <p> --type oauth --no-browser [--label]` | argv | OAuthFlowController.swift:157 | auth_commands.py:414-433; anthropic_credentials.py:752-800 | OK |
| `auth add nous --no-browser` (+PYTHONUNBUFFERED) | argv | NousAuthFlow.swift:123,128 | auth_commands.py:305-344; auth_device_flow.py:299-300; auth_nous.py:1386-1394 | OK |
| `auth remove -- <p> <target>` | argv | CredentialPoolsViewModel.swift:671 | auth_commands.py:562-573 | OK |
| `auth reset -- <p> [target]` | argv | :541, :665 | auth_commands.py:591-605 | OK |
| `auth priority -- <p> <target> <n>` | argv | :648 | auth_commands.py:483-493 | OK |
| `auth refresh -- <p> <target>` | argv | :656 | auth_commands.py:608-660 | OK |
| `auth logout <p>` (HermesAuthLogoutVerdict) | argv | CredentialPoolsViewModel.swift:~470 | `hermes auth logout` exists (--help) | OK |
| `proxy start --provider --host --port` | argv | HermesProxyService.swift:90 | proxy/cli.py:22-52; main.py:1891-1898 (rc→SystemExit) | OK |
| `proxy providers` + parse | argv/parse | HermesProxyService.swift:266 | proxy/cli.py:73-79 | OK |
| config set model.provider/default/base_url/api_key/api_mode/context_length | config | LocalModelConfigPlan.swift:121-228 | runtime_provider.py; auth.py:1331-1336 | OK |
| delegation.model/provider/base_url | config | SettingsViewModel.swift:1431-1433 (caller) | tools/delegate_tool_config.py:327-380 | OK |
| ACP session/set_model `provider:model` | ACP | ProjectModelPresetApplier.swift; ACPClient.swift:750-783 | acp_adapter/server.py:1015,318-334 | OK |
| auth.json credential_pool.* / providers.* / updated_at | file | CredentialPoolsViewModel.swift:120-200; NousSubscriptionService.swift | agent/credential_pool.py:229-235; auth_nous.py:810-827 | OK |
| root auth.json fallback for profiles | file | HermesAuthFallback.swift | auth.py read_credential_pool / _load_provider_state | OK |
| Nous `/v1/models` with agent_key | HTTP | NousModelCatalogService.swift:63,257 | auth_nous.py (agent key) | OK |
| Proxy help text `hermes login <p>` | doc/argv | HermesProxyView.swift:190 | subcommands/login.py:8-44 | FINDING-F1 |

## Not audited / couldn't verify
- Bot model picker (BotAgentView) and ChatModelPreflightSheet host code are outside this manifest. I only checked that they call the same ModelPickerSheet.
- LocalModelEnumerator's HTTP response shapes come from third-party servers (Ollama/LM Studio), not Hermes, so they were not checked live.
- Not checked: `hermes auth remove` on an inherited root pool from a named profile (write-location semantics). This is an edge case.
