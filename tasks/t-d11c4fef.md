---
id: t-d11c4fef
title: UI automation pass (re-enable scarfUITests, cover real-file flows)
status: todo
added: 2026-09-02
---

## Description

Deferred until the current fix lanes land (Alan, 2026-09-02). scarfUITests is currently skipped in the shared scarf scheme (commit 26d2f5a) because its add-project flow interfered with concurrent local work. When picked up: (1) re-enable (skipped = NO in scarf.xcscheme); (2) make the suite safe to run alongside normal work — isolated HERMES home/sandbox per run (see UITestIsolation.swift), never touching the user's real ~/.hermes or project list; (3) grow coverage toward the flows unit fixtures can't reach — end-to-end paths against REAL Hermes-written files (the bot-create unsafeToWrite bug would have been caught: every hand-typed fixture passed while real PyYAML-wrapped files failed). Candidate flows: create bot (with/without optional fields), Make a Bot on an existing profile, add project, quick-command edit round-trip. Complements the generated-fixture convention (conventions/hermes-authored-file-fixtures-must-come-from-hermes-s-own).

## Plan



## Artifacts



