---
title: Chat credential hint mirrors Hermes _has_any_provider_configured (54-var table, scoped tokens, local base_url)
type: note
permalink: scarf/architecture/chat-credential-hint-mirrors-hermes-has-any-provider
tags: [chat, credentials, providers, hermes-release-audit]
source_paths: [scarf/scarf/Core/Services/HermesFileService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesProviderCredentials.swift, scripts/check-hermes-tables.py]
source_paths_inferred: false
source_sha: d6533b8fc52976a84b6ca58711e874e03fce50fc
created: 2026-09-26
updated: 2026-09-27
---

`HermesFileService.hasAnyAICredential` (the chat's "No AI provider credentials detected" hint) is built on `HermesProviderCredentials` in ScarfCore since R08 (S15-F4). The auth.json part (incl. the named-profile root fallback) is R03's and unchanged.

## Observations
- [fact] Hermes' own check is `_has_any_provider_configured` (`hermes_cli/main.py:1052` @ v2026.9.24): {OPENROUTER_API_KEY, OPENAI_API_KEY, ANTHROPIC_API_KEY, ANTHROPIC_TOKEN, OPENAI_BASE_URL} + every `api_key_env_vars` of every `api_key` row in PROVIDER_REGISTRY incl. mirrored plugins = 54 vars at 0.21.5 (`HermesProviderCredentials.providerEnvVars`) #providers
- [todo] On each Hermes bump, re-derive the table by importing `hermes_cli.auth.PROVIDER_REGISTRY` from the tagged worktree's .venv (snippet in the Swift doc comment); `tableIsHermesProviderEnvVars` pins the count at 54, and lane 6 of scripts/check-hermes-tables.py (`parse_provider_env_vars`, static AST of main.py + auth.py `_REGISTRY_ROWS` + plugin mirror rules) FAILs on drift both ways #release-audit
- [decision] GITHUB_TOKEN/GH_TOKEN/HF_TOKEN count only when `model.provider` is copilot/huggingface: they are everyday tokens and Hermes never auto-selects copilot (`_NO_AUTO_DETECT_PROVIDERS`, `auth.py:1453`). The provider is resolved the way Hermes does first (strip/lower + the `_PROVIDER_ALIASES` rows landing on copilot/huggingface/bedrock/lmstudio/copilot-acp/custom, `auth.py:1300-1335,1500-1501` @ v2026.9.24 — `HermesProviderCredentials.canonicalProvider`, R16c), so `github`/`github-models`/`hf` count and `aws`/`lm-studio`/`ollama` hit the keyless rule #scoped
- [decision] A public `model.base_url` alone does NOT count as keyless — Hermes setup writes one for nearly every provider (`model_setup_flows.py:75,581`). Keyless = bedrock/vertex/copilot-acp/lmstudio, `custom:*`, `custom`+base_url, or a loopback/private/.local base_url #keyless
- [convention] `.env` parse follows `_dotenv_has_provider_key` (`main.py:1012-1030`); the login-shell env harvest (`shellEnvKeys`) forwards the same table to Scarf-spawned hermes #env

## Relations
- relates_to [[Named-profile auth.json falls back to the root per provider — read it the way Hermes does]]
