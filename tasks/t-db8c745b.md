---
id: t-db8c745b
title: Projects follow-up: cross-process registry write lock (all writers)
status: todo
added: 2026-09-03
---

## Description

P4/P5 deferral, deliberately not landed piecemeal: with the scarf-projects MCP server, projects.json now has two writing processes (app + helper) plus ~6 in-app writers. A lock helps only if EVERY writer takes it across the whole read-modify-write; locking just the helper would read as safety while the app-side race stayed open. Design one shared advisory-lock (or single-writer funnel) covering ProjectDashboardService.saveRegistry callers in both processes. See the Phase-4 doctor note's deferral edit for reasoning.

## Plan



## Artifacts



