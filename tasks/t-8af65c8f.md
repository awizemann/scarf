---
id: t-8af65c8f
title: gh-pages: backfill appcast minimum OS + fix privacy page link/colors
status: doing
added: 2026-10-05
priority: urgent
---

## Description

Live appcast.xml declares minimumSystemVersion 14.6 on every item, incl. v2.20.0+ which need macOS 15 — Sonoma users are offered updates that can't launch. Backfill 15.0 for those items. Hand-rendered privacy/index.html still links the awizemann fork and uses #C2563D (and no dark accent). Local commit on gh-pages only; push needs Alan's go-ahead (charter C8). Landing index.html/llms.txt on gh-pages also stay stale until the site is redeployed.

## Plan



## Artifacts



