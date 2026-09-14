---
title: Config reads must survive an invisible config.yaml — HermesConfigReader fallback chain (gh#112)
type: note
permalink: scarf/architecture/config-reads-must-survive-an-invisible-config-yaml
source_paths: [scarf/scarf/Core/Services/HermesFileService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GuardedTextFile.swift]
source_paths_inferred: false
source_sha: 40e8ab1f137314b4c9199b2bf8ce8addbef95980
created: 2026-07-12
updated: 2026-07-12
reviewed: 2026-09-11
reviewed_by: claude-opus-5
---

Docker-hosted Hermes keeps `~/.hermes` INSIDE the container; the host `hermes` is a wrapper (docker compose exec). Writes (`hermes config set`) always worked; every direct file read (SFTP/cat) failed → "config.yaml not found" Settings + the chat preflight "no models" sheet on every start. Fixed 2026-07-12, commit 5dc1c55.

## Observations

- [fact] `HermesConfigReader` (ScarfCore/Services), remote-only (`guard context.isRemote`), fallback order: (1) direct `context.readText(paths.configYAML)`; (2) `cat "$(hermes config path)"` in ONE `/bin/sh -c` wrapper shell with the standard PATH prelude — path resolution AND the cat must run in the same shell; resolving then SFTP-reading the path does NOT work for containers; (3) `hermes config show` Model-line probe → synthesized minimal `model:` YAML through the normal parser. Step 3 is the only read that runs in-container; it unblocks the chat preflight gate but not full Settings.
- [gotcha] Step 2 still fails for pure in-container installs (host `cat` can't see the container path) — it exists for HERMES_HOME overrides and bind-mounted homes. There is NO code path to raw YAML / memory files / state.db in-container; the user fix is a bind mount (`~/.hermes:/root/.hermes` in compose), which IOSSettingsViewModel's empty-state message now teaches when the CLI answers but the file is invisible (probe non-nil = container signature).
- [fact] `hermes config show` Model line is a Python-dict repr — `{'default': 'x', 'provider': 'y'}` — key order varies, quotes flip to double when a value embeds a quote; parse per-key with either-quote regex (`parseModelShowLine`, unit-tested against real v0.17 output). `hermes config get` still does not exist as of v0.18.
- [convention] Tests faking a remote hermes over LocalTransport MUST set `hermesBinaryHint` to a nonexistent path (M5FeatureVMTests.makeFakeHermes uses `/nonexistent/scarf-test-hermes`), otherwise CLI fallbacks silently find the developer machine's real hermes and read the real config. #testing
- [fact] Callers: `IOSSettingsViewModel.load` (topology-aware guidance + model section from probe) and iOS `ChatView.passModelPreflight`. macOS `HermesFileService.loadConfig` deliberately NOT converted — it's on watcher-driven hot paths and would need failure-caching first.

## Relations
- relates_to [[ios-transport-must-be-pooled-per-serverid-sshconfig-un]]
- relates_to [[hermes-v0-18-compatibility-decisions]]
