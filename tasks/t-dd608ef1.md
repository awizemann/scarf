---
id: t-dd608ef1
title: Hermes upstream — auxiliary resolver missing local provider aliases
status: done
added: 2026-07-13
---

## Description

CLOSED 2026-07-14 — all upstream actions taken per the clean-submission contract: (1) alias gap NOT re-filed (duplicate-in-flight: issue #54405, PR #56448 + parity PR #62239); (2) sliver review comment posted on PR #56448 (four vllm/llamacpp spellings missed due to #62239 ordering) with a live-testing offer; (3) NEW issue #64144 + PR #64146 filed for the untracked misleading "payment / credit error" labeling (reason+level threading through _mark_provider_unhealthy, 8 call sites, 305 tests green, composes with TTL PRs #59985/#60357). WATCH: re-test aux routing on a local model when #56448/#62239 merge + release; monitor #64146 for review feedback (reviewer may prefer INFO over DEBUG — one-word change; trivial ttl conflict if #59985 merges first).

## Plan



## Artifacts

Issue draft: /private/tmp/claude-501/-Users-awizemann-Developer-Scarf/ec22c438-3cde-42a7-9ee9-8b6c1a63433b/scratchpad/hermes-aux-alias-issue.md ; live re-test log: scratchpad/aux_retest_run.log ; memory: aux-alias-gap 0.18.2 verification appended to scarf/architecture/local-provider-config-keys-hermes-reader-verified-v0-17-0

