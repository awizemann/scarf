---
title: Hermes pairing approve/revoke refuse at exit 0 — judge by the printed marker
type: note
permalink: scarf/architecture/hermes-pairing-approve-revoke-refuse-at-exit-0-judge-by-the
tags: [hermes, cli, gateway, verification]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift, scarf/scarf/Features/Gateway/ViewModels/GatewayViewModel.swift, scarf/scarf/Features/Gateway/Views/GatewayView.swift]
source_paths_inferred: false
source_sha: ced2b61baa97cea93f8376c04d0a263ac75efd99
created: 2026-09-10
updated: 2026-09-10
reviewed: 2026-09-14
reviewed_by: audit:claude-code (background)
---

`hermes pairing approve` and `pairing revoke` are `-> None` handlers reached through a `-> None` `pairing_command`, so Python turns every refusal into exit status 0. Scarf judges both by the emitter's own success line via `HermesPairingVerdict` (`ScarfCore/Services/HermesCLIOutcome.swift`), keeps the row on a refusal, and quotes Hermes's line verbatim into a dismissable sticky banner in `GatewayView`'s pairing section — the lockout arm needs TWO lines, because the countdown is printed separately from the refusal and is the only remediation the operator gets.

## Observations
- [gotcha] Both pairing verbs exit 0 on every refusal — `_cmd_approve` (hermes_cli/pairing.py:56-81) and `_cmd_revoke` (:84-90) are `-> None`, as is `pairing_command` (:3-19) #cli #gateway
- [fact] Success markers, byte-identical at all 32 v2026.* tags: `Approved! User <display> on <platform> can now use the bot~` (:68) and `Revoked access for user <id> on <platform>.` (:88); both indented two spaces, so anchor after a trim #verification
- [fact] The approve refusal gained a prefix at **v2026.7.30**, not v2026.8.3 as this note first said: `Code '<c>' not found…` at `v2026.7.20:95` -> `Pairing request or code '<c>' not found…` at `v2026.7.30:100`, still that spelling at `v2026.9.7:80`. So the stable marker is the shared tail `not found or expired for platform` #verification
- [gotcha] A `git grep` for the lockout marker `is locked out after too many failed approval attempts.` says ABSENT on every tag below v2026.9.7 and that is a FALSE NEGATIVE — until v2026.9.7 the sentence is built from two adjacent f-string literals (`f"\n  Platform '{platform}' is locked out after too many failed "` + `f"approval attempts."`, `v2026.8.31:91-93`), so the source never holds it as one run of bytes while the PRINTED text is byte-identical. Floor-walk a marker by the emitted line, not by grep #verification
- [fact] The rate-limit lockout branch first exists at v2026.5.7; its reason spans two printed lines (`… is locked out after too many failed approval attempts.` :76 plus `Lockout clears in ~N minute(s).` :77), so a one-line quote drops the remediation #gateway
- [convention] A refused pairing action keeps its row and posts to `pairingError` (sticky until dismissed), never to the service row's `actionMessage`/`actionFailed` #ui

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
