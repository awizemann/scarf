---
id: t-eeaebd8d
title: F2: Audit fixes — multiplex allowlist parsing cluster + clamp
status: done
added: 2026-08-20
---

## Description

Fresh-eyes audit S1 cluster (branch feat/hermes-v0204-parity), all in P7's allowlist work. (1) Flow-style list `multiplex_profile_allowlist: ["work","personal"]` parses as malformed → warns on every route (HermesConfig+YAML.swift:573-582 + HermesYAML.swift:130-149); reuse the inline-flow handling ProjectSkillsScanner.parseTrustedProjectDirs already has. (2) Mapping-valued key fails OPEN (nil → serve-all) while Hermes restricts to default-only — make it fail closed to [] and fix the comment at :570-572. (3) Read top-level multiplex_profile_allowlist with precedence over gateway.* (gateway/config.py:1190-1194,1413-1423) — mirror ProfileRoutesYAML.swift:74's top-level-wins pattern; and gate the ProfileRoutesSection warning on multiplexing actually configured (multiplexProfiles non-empty), not just isV0204OrLater. (4) AdvancedTab.swift:95 clamps max_concurrent_children to 1...50; Hermes documents no ceiling — raise/remove the cap. Tests for all three allowlist shapes (flow list, mapping, top-level precedence) + no-warning-when-not-multiplexing.

## Plan



## Artifacts



