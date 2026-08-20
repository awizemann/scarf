---
id: t-da90e83e
title: R1: Privacy policy + analytics disclosure (BLOCKING — Alan wording decision)
status: done
added: 2026-08-20
priority: high
---

## Description

wiki/Privacy-Policy.md:41 states "No analytics" (mirrored to awizemann.github.io/scarf/privacy — linked from iOS Info.plist + App Store Connect; wiki/Support.md:74 repeats it), but v2.19.2..main ships opt-out macOS analytics on by default to api.swiftstats.co (swift-stats, ScarfMon backend). iOS collects nothing (verified). Update the policy to describe macOS collection accurately (event types, no PII — verified: closed-token props, ephemeral install-id, no userId), state iOS collects nothing, document the opt-out (Settings → Advanced), and add README/release-note disclosure. Alan must approve wording before the wiki/site copy is published. Evidence: documents/release-audit-v2.19.2-to-main-2026-08-20.md finding 1 + clean-areas.

## Plan



## Artifacts



