# P8 Remediation Close-Out

Date: 2026-09-04 · Branch: main, feebb3c → b338c87c (13 commits this run). Companion to reports/2026-09-04-projects-post-remediation-audit.md (the P8 audit this round fixed) and reports/2026-09-03-projects-full-surface-audit.md (P7).

## Commits landed (none pushed, per C8)

P7 remediation: 926452a S1 · ad9d4e9 D3 · 1d6a6ec AX · 7bc27c9 D1+lock · 78cccf7 set_config MCP · 25420ab S2/D2 · 73b775e PF.
P8 remediation: 8f307917 W1 (destroy-shaped writers) · 242a604f T1 (trust-at-use roots, SHA-256 keychain binding, O_NOFOLLOW) · ebe1e790 A2 + Release isolation fix (t-bb02177b) · 2c964c98 L2+P2 + the orchestrator's EEXIST-vs-errno lock fix · 7378599b G2 (payload v2, signer refusal, quarantine parity, beacon consent) · b338c87c F1 (frozen mini-app anchor, legacy re-mint, signed consent, off-main consent flow).

## Final targeted re-audit (2 specialists over the round's own machinery)

Everything from the P8 report verified fixed and holding under attack. The re-audit's own findings (1 HIGH security: movable mini-app base anchor; 2 HIGH perf: main-actor consent holds against the new 60s lock wait; 2 MEDIUM: unbounded legacy-FNV window, poisonable consent store; 1 MEDIUM a11y; 6 LOW) were all fixed in F1 and verified: ScarfCore 2149/2149, scarf scheme 713 green, iOS building, Release config building.

Notable invariants that survived direct attack across both re-audits: v1→v2 grant forgery/replay/downgrade; statAll marker spoofing; lock ownership races and symlink wedges; the unlockable-errno path; .bak/quarantine ordering and privacy inheritance; AGENTS.md.bak vs uninstall; refusal-path DoS on grants; writeBlock refusal degrading rather than bricking.

## Open follow-ups (tasks on the board)

- t-9c40eb26 openat/O_NOFOLLOW transport primitive (general TOCTOU; the mini-app surface is now fd-anchored, the rest of the transports are not)
- t-6f770a34 exporter schema export-review UI
- t-6ee07a0e real project move flow
- t-682b7f47 session-map pruning follow-up
- t-e65b80bf remaining ^…$ ICU-anchor validators (SkillInstallValidator mirrors Hermes — verify against tagged source before diverging)
- t-05a6bb8b MiniAppAgentSessionTests parallel-load flake
- t-18d1fedf stale template skill copy — HUMAN sync (managed tier): cp scarf/scarf/Resources/BuiltinSkills.bundle/scarf-template-author/SKILL.md templates/awizemann/template-author/staging/skills/scarf-template-author/SKILL.md
- t-a30b421f release note: mini-app grants re-prompt once (unsigned/v1 rows invalidate)
- Remaining P8 perf MEDIUM not taken: per-widget stats not batched through statAll (the dominant per-tick term with a populated dashboard is W) — worth a small PF follow-up.

## Accepted residuals (documented in code + memory)

Consent is host-level and path-keyed (uuid not cheaply available in the widget environment); .env.bak places a second 0600 copy of secrets beside the original; lock release has a microsecond read-then-remove TOCTOU that degrades to pre-fix behavior; two Macs on one remote ~/.hermes are not serialized (expecting: is the cross-machine guard); per-machine grant/consent keys mean re-asks on other machines by design.
