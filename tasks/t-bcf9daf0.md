---
id: t-bcf9daf0
title: R13 i18n pass + full test gate + Smoke UI
status: done
added: 2026-09-26
---

## Description

Localize every new string from R01–R12; full serial scarfTests, ScarfCore + ScarfIOS swift test, iOS build, Smoke UI plan (orchestrator only, serialized).

## Plan



## Artifacts

Merged as 13ef1786 (93617417): +72 keys (71 × 6 locales + 1 English fallback), −14 stale keys (shadow banner ×7, quick-command chip, old YOLO/personality/webhook copy), 5 iOS error strings made localizable. validate-catalog.py OK. R16/R17 strings need a follow-up pass (tracked in R17/R15).

