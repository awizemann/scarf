---
title: Remediation phases fix the audit findings, not adjacent edge cases
type: note
permalink: scarf/conventions/remediation-phases-fix-the-audit-findings-not-adjacent-edge
tags: [process, audit, remediation]
created: 2026-09-27
updated: 2026-09-27
---

Alan (2026-09-27, blind re-audit remediation): a fix phase fixes the audit findings it was given. Don't chase edge cases or adjacent drift a phase agent notices (crashed-PID stale state, sweeps of other forms, older-band features that aren't findings) unless the problem is real and bites users in normal use. Everything else goes in the report as "seen, not fixed" for the orchestrator to triage.

## Observations
- [convention] Orchestrator follow-ups must pass the same bar: a leftover goes back to an agent only if a normal user would hit it; otherwise it is logged for triage, not built #scope
- [decision] This complements the older-host rule in [[Hermes Capability Gating Pattern]]: a finding that is also broken on older Hermes gets fixed there behind a flag — that is the finding itself, not drift #scope
- [gotcha] Scope creep showed up as orchestrator-sent follow-ups (B01 older-host chain projection, B05 extra_or_secret sweep, stale drain PID) more than as agent overreach; check each follow-up against "normal use" before sending #process

## Relations
- relates_to [[Hermes Capability Gating Pattern]]
