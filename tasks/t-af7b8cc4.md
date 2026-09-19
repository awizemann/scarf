---
id: t-af7b8cc4
title: Voice release blockers: privacy policy, Mac mic string, string catalogs
status: todo
added: 2026-09-18
priority: high
---

## Description

From F4 (t-ba3ccc85). These must be done before the release that ships voice:
1. `scarf/docs/PRIVACY_POLICY.md` has no Live Voice section: audio goes directly from the device to OpenAI, recent chat (up to 24 messages / 6,000 chars) is shared as context, and dictation stays on-device. Update it, its wiki mirror, and the hand-rendered gh-pages copy (see memory "privacy policy page on gh-pages is hand-generated").
2. The Mac NSMicrophoneUsageDescription ("Scarf uses the microphone for Hermes voice chat.") should mention Live Voice streaming to OpenAI. Update InfoPlist.xcstrings translations too.
3. The new voice strings (all phases) aren't in Localizable.xcstrings: the CLI build doesn't extract them. Extract them (Xcode build with string-catalog sync, or the repo's localization tooling) and check the source→catalogue coverage (see task t-3bcd1d7f).

## Plan



## Artifacts



