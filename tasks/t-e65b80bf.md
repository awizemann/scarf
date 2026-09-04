---
id: t-e65b80bf
title: Sweep remaining ^…$ ICU-anchor validators (Profiles, SkillInstallValidator, HermesProfileScope)
status: todo
added: 2026-09-04
priority: low
---

## Description

G2 (t-58bc7efe) fixed the slash-command name regex to \A…\z; the same ICU trailing-newline hole survives in ProfilesViewModel, SkillInstallValidator, and HermesProfileScope/Resolver. Note: SkillInstallValidator mirrors a Hermes-side Python regex with identical $ semantics — tightening it diverges from Hermes deliberately; verify against the tagged Hermes source (charter C2/C5) before changing.

## Plan



## Artifacts



