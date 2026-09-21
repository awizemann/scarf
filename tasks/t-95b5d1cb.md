---
id: t-95b5d1cb
title: Voice hardening leftovers from the 2026-09-19 review (consent in core, XCTest seam failsafe, ShellTestRunner)
status: todo
added: 2026-09-19
priority: low
---

## Description

Low-priority follow-ups from the fresh-eyes review of main after the voice merge:
1. VoiceDataConsent is enforced only in the app layers. GPTLiveEngine.start() (ScarfCore) could refuse to start when Self.externalRecipient has no recorded consent (a .failed(.consentRequired) phase), so a future core-side caller cannot open a billed, data-exporting session without it.
2. ProjectConfigKeychain (~141-146) routes to the in-memory store whenever NSClassFromString("XCTestCase") != nil. The DEBUG asserts only guard "real Keychain under XCTest", not the inverse. Add a failsafe the shipped app can never satisfy (e.g. also require the bundle id not be the shipped app id).
3. ShellTestRunner (ScarfCoreTests ~81-85): on timeout the defer removes the output dir while the child may still be alive after SIGTERM; diagnostics vanish exactly when needed. Wait/kill before removing.

## Plan



## Artifacts



