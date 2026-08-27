---
id: t-baaaf89a
title: Analytics P2: closed UsageEvent enum as the typed privacy contract
status: done
added: 2026-08-26
---

## Description

Introduce a closed UsageEvent enum (ShabuBox pattern) covering all ~33 existing snake_case events, with bucketed/enum-typed associated values and enum-derived error kinds; Analytics facade gains record(_: UsageEvent); migrate all call sites (app target + ScarfCore seam stays string-free of Stats). Names stay Scarf's (keep section_viewed; no error_shown) — deliberate deviation. Depends on P1 landing.

## Plan



## Artifacts



