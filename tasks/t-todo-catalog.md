---
id: t-todo-catalog
title: **[todo/misc]** CatalogService: add a drift check between the in-code model list and `templates/`: `CatalogService.swift:67`.
status: todo
added: 2026-06-13, source: t-aud16
---

## Description

CatalogService.swift:67 (and CatalogServiceTests.swift:162) reference tools/check-catalog-fallback-sync.py which does NOT exist (tools/ has build-/validate-catalog.py only). Either write the checker or fold the drift check into validate-catalog.py, then drop both TODOs.

## Plan



## Artifacts



