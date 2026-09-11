---
id: t-f3ffabf9
title: Audit P41: yamlScalar onto YAMLScalar, MCP editor control chars, quoted approvals.mode, reader coverage
status: todo
added: 2026-09-10
priority: high
---

## Description

Round-4 whole-surface audit (documents/hermes-v0.21.1-whole-surface-audit-round4.md, Settings/YAML section). Needs round-4 product decisions 9 (MCP entry editor + reasoning-override field: refuse control chars like decision 6, or emitter-only) and 10 (which Scarf-written blocks the shared decoder covers).

- HIGH · PRE · `HermesFileService.yamlScalar` (`:2281-2330`, emitted at `:2109,2208-2211,2257-2259,699/721/751/846/867`) double-quotes escaping only `\\` and `\"`, so any C0/C1 control, DEL, NEL, U+2028/9 in an MCP `env:`/`headers:` value, tool name, cert path or `command` goes out raw; PyYAML's reader refuses the document and Hermes discards the whole config.yaml layer (`gateway/config.py:775-791` @ v2026.9.7). Fuzzed 7k inputs through PyYAML 6.0.3: `quoteIfNeeded` 0 failures, `yamlScalar` 3953. Neither `MCPServerEditorViewModel` nor `patchMCPServerField(expecting:)` guards it. Fix: delete `yamlScalar`'s body and forward to `YAMLScalar.quoteIfNeeded` (reader is already `YAMLScalar.unquote`); add the editor refusal per decision 9.
- MED · PRE · Readers of Scarf-written scalars that bypass `YAMLScalar.unquote`: `agent.reasoning_overrides` keys+values, `model_catalog.excluded_providers`, `gateway.multiplex_profile_allowlist` all go through `HermesYAML.stripYAMLQuotes` (`HermesYAML.swift:151,303,509-519`), which returns a double-quoted body verbatim; written via `quoteIfNeeded` (`PowerSettingsWriter.swift:78,117`, `GatewayConfigWriter.saveList`). The reasoning-override pattern is a free-text field (`AgentTab.swift:259`) with no control refusal, so a pasted ESC round-trips as the literal `a\x1bb`. The `YAMLScalar.swift:262-263` "one decoder" claim is false for these three. Decision 10.
- MED · PRE · `HermesApprovalMode.normalize` (`:71-84`) runs on an already-unquoted scalar (`HermesConfig.swift:1528-1531`, `HermesConfig+YAML.swift:169-171`), so a QUOTED `approvals.mode: "no"`/`"false"` renders "Never ask" while Hermes's `_normalize_approval_mode` (`tools/approval_context.py:198-214`, `_VALID_MODES` `:195`) takes the string arm and returns `manual`. Unsafe direction. Fix: gate the bool arm on `YAMLScalar.resolvesToBool(raw)` before quote-stripping, as `boolishOptional` (`HermesFileService.swift:2372`) does.
- LOW · PRE · `PowerSettingsWriter.setReasoningOverrides` (`:71-73`) trims the key for the emptiness test but writes it untrimmed; sibling `setExcludedProviders` (`:113-115`) trims.
- LOW · PRE · re-open descendant sweep in `parseNestedYAML` still deletes a flat dotted sibling (`gateway:` … `gateway.enabled: true` … `gateway:`), which PyYAML keeps — check whether P38 item 8 closed this; if not, fix here.

## Plan



## Artifacts



