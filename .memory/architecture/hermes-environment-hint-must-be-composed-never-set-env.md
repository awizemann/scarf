---
title: HERMES_ENVIRONMENT_HINT must be composed, never set: env replaces config agent.environment_hint
type: note
permalink: scarf/architecture/hermes-environment-hint-must-be-composed-never-set-env
tags: [acp, ssh, environment-hint, gh142]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHTransport.swift, scarf/scarf/Core/Services/ACPClient+Mac.swift, scarf/Packages/ScarfIOS/Sources/ScarfIOS/ACPClient+iOS.swift]
source_paths_inferred: false
source_sha: 244c249f2734f8309ced10747cee69cf393617d8
created: 2026-09-29
updated: 2026-09-29
---

## Observations
- [invariant] Hermes resolves `(os.getenv("HERMES_ENVIRONMENT_HINT") or "").strip() or config agent.environment_hint` (agent/prompt_builder.py:1054-1058 @ v0.21.4), so any non-blank env value REPLACES the user's config hint. Scarf's value is always existing env (non-blank) else config hint, then a blank line, then Scarf's hint, via EnvironmentHintComposer #gh142
- [convention] Delivery: local spawn composes against the ENRICHED shell env on Process.environment (ACPClient.localACPEnvironment); Mac SSH and iOS Citadel prepend EnvironmentHintComposer.remoteShellFragment after any `cd` and before the COLUMNS/PATH assignment prefix, so it runs after the remote login profile and keeps a remote-exported hint. Plumbed as `environmentHint: EnvironmentHintRequest?` on ServerTransport.makeProcess, SSHTransport.composedRemoteCommand, ACPClient.forMacApp/forIOSApp, buildACPCommand #gh142
- [convention] Mac hints are deferred via `EnvironmentHintSlot`: the chat builds its ACPClient before project prep has run, so `forMacApp` offers two overloads—one with direct `environmentHint` and one with `environmentHintSlot` (keyed by projectCwd). The slot is read at channel open (`start()`), enabling lazy resolution for #142 P3 workflow. A nil slot or unmatched cwd falls back to direct `environmentHint` (nil = today's spawn); per-project keying prevents hint leakage across sessions #gh142
- [gotcha] Process.environment on the Mac ssh process never reaches the remote host (no SendEnv); a remote env var must ride the remote command string. A nil/blank Scarf hint yields an empty fragment, so commands stay byte-identical (tested) #ssh
- [fact] The config hint is a caller-supplied parameter (EnvironmentHintRequest.configHint); callers read agent.environment_hint from the target host's config.yaml with ProjectEnvironmentHint.readConfigHint (P3), never the transport #gh142
- [gotcha] Tests that execute the fragment use the async ShellTestRunner, not Process.waitUntilExit, to avoid parking pool threads (see the blocking-test convention) #testing

## Relations
- relates_to [[Remote hermes resolution: appended install-dir PATH, wrapper hints as shell words, probe on stdin]]
