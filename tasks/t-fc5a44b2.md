---
id: t-fc5a44b2
title: Bots B1: native avatar rendering
status: done
added: 2026-09-01
priority: high
---

## Description

BotAvatarView: render assets/avatar.png when present; otherwise Scarf-native deterministic fallback porting Hermes's legacy geometric path (name hash*31 >>> 0 % 7 shape pick; FNV-1a 2166136261/16777619 seed + xorshift 13/17/5 sigil PRNG — avatar.tsx:29-47,107-115) with color/shape/pinned-seed from HermesBotIdentity. Note: blobatar@2.0.0 faces are NOT reproducible (external npm) — fallback is deliberately Scarf's own look. Deterministic snapshot/hash tests. Component placed per ScarfDesign conventions.

## Plan



## Artifacts



