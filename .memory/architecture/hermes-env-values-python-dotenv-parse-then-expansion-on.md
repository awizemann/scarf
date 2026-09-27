---
title: Hermes .env values: python-dotenv parse then ${} expansion on every value, so quoting alone can't keep them literal
type: note
permalink: scarf/architecture/hermes-env-values-python-dotenv-parse-then-expansion-on
tags: [hermes-env, dotenv, secrets, templates]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/SecretsEnvBlock.swift, scarf/Packages/ScarfCore/Tests/ScarfCoreTests/SecretsEnvBlockTests.swift]
source_paths_inferred: false
source_sha: d6533b8fc52976a84b6ca58711e874e03fce50fc
created: 2026-09-26
updated: 2026-09-26
---

Found in R12 (S12-F5) while fixing the template-secrets block Scarf mirrors into `~/.hermes/.env`. Verified by loading a scratch file with the reference worktree's own loader (`hermes_cli.env_loader._load_dotenv_with_fallback`, v2026.9.24 `.venv`, python-dotenv 1.2.2) under an empty environment; the golden pairs live in `SecretsEnvBlockTests.escapedValuesRoundTripThroughHermesDotenvLoader`.

## Observations
- [fact] Hermes loads .env as `DotEnv(..., interpolate=False).parse()` then runs dotenv's `parse_variables` over EVERY value whatever its quoting (hermes_cli/env_loader.py:265-310 @ v2026.9.24), so `${NAME}` / `${NAME:-d}` expands even inside single quotes; a bare `$` not followed by `{` stays literal #hermes-env
- [gotcha] Shell-style `'foo'\''bar'` is a python-dotenv parse error and dotenv DROPS the whole line (the variable is simply missing); inside quotes dotenv only knows `\'` / `\"` / `\\` escapes, and a value ENDING in a backslash can't be written as `\\` before the closing quote (the regex reads `\"` as an escaped quote) #dotenv
- [convention] Scarf writes quoted values the way Hermes's own `_quote_env_value` does (double quotes, `\\` and `\"` escaped; hermes_cli/config.py:2557-2565) plus `\n`/`\r` for line breaks, `${` as `${:-$}{` (the empty-name variable, never set, defaulting to `$`) and each trailing backslash as `${:-\}` #secrets
- [gotcha] Hermes's own `_quote_env_value` still has the trailing-backslash and `${` problems — a value Hermes itself saves can come back changed; not Scarf's to fix #hermes-env

## Relations
- relates_to [[Project Templates (.scarftemplate)]]
