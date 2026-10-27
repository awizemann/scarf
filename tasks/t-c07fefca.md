---
id: t-c07fefca
title: Release Scarf v3.7.0 (Hermes v0.22.5 parity)
status: done
added: 2026-10-26
priority: high
---

## Description

Prep (notes, README, wiki, zero-warning Xcode-beta Release builds) then maintainer cut with ./scripts/release.sh 3.7.0 after `git push origin main`.

## Plan



## Artifacts

Prep done on local main (6569d397, 33 ahead of origin): notes releases/v3.7.0/RELEASE_NOTES.md, README What's New + Hermes v0.22.5 target, wiki Home/Release-Notes-Index/Compatibility (dirty tier), runbook documents/plans/2026-10-26-v3.7.0-release-prep.md. Final gate all green: ScarfCore 4407, scripts 71 + tables 8/8, Xcode-beta Release Mac+iOS zero Scarf warnings, scarfTests 1996, VM UI v0.22.5 Smoke/Full/Live + v0.21.5 Smoke/Live PASS. Remaining: git push origin main; ./scripts/release.sh 3.7.0; post-cut checks; retest notes on gh #146/#147; commit wiki/documents tiers in Memophant.

