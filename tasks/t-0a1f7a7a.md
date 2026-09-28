---
id: t-0a1f7a7a
title: B10 i18n pass + full test gate (blind remediation)
status: done
added: 2026-09-27
---

## Description

Localize every new string from B01–B09; full serial scarfTests, ScarfCore + ScarfIOS swift test, iOS build, check-hermes-tables, validate-catalog, Smoke UI (orchestrator only).

## Plan



## Artifacts

i18n merged (ddac4640): 123 keys × 6 languages, validate-catalog 0 errors. Gate on integration: full scarfTests 1896/1896 pass (after two B05 test fixes 64e1b48d); ScarfCore 4198/4199 (ProcessDrainP43 temp-dir flake, passes alone); ScarfIOS 119 pass; iOS build OK; tables lanes=8/8; script tests OK. Smoke UI to run after B11 fixes.

