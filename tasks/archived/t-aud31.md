---
id: t-aud31
title: **[t-aud31]** Env-enricher parallelism flake — FIXED. `localTransportSubprocessEnvLetsEnricherWinPATH` + its sibling both mutate the process-global `LocalTransport.environmentEnricher`; they lived in the parallel `@Suite KanbanModelsTests`, so one test's enricher (nil) clobbered the other's (`{…ANTHROPIC_API_KEY…}`) mid-assertion (the `→ nil` flake; passed in isolation). Extracted both into a dedicated `@Suite(.serialized) struct LocalTransportEnvTests` (each still save/restores the global via `defer`) — mirrors how `M5FeatureVMTests` serializes `ServerContext.sshTransportFactory`. They were mislocated in KanbanModelsTests anyway. Verified: full `swift test` 613/613 across 4 consecutive runs, no enricher flake. (A SEPARATE rare flake in the t-aud25 tilde test surfaced during the runs — subprocess stdout crossing under parallel load — split to t-aud32.)
status: archived
---

## Description



## Plan



## Artifacts



