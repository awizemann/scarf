---
id: t-aud12
title: **[t-aud12 → deferred to t-aud24]** Investigated, deliberately NOT applied as-specified. Swapping `.onAppear { load() }`→`.task` across the 9 switch-nav feature views is a NO-OP for the re-fetch problem: `ContentView`'s `@ViewBuilder switch coordinator.selectedSection` destroys+recreates each view per switch, so `.task` fires on every switch just like `.onAppear` (the audit verifier flagged this too). The real fix is coordinator-level data caching / view persistence so re-entry doesn't re-fetch, plus the per-VM cancellable-load treatment (à la t-aud11) for the other 8 VMs. Both are architectural → scoped as t-aud24 rather than churning 9 files for zero benefit.
status: archived
---

## Description



## Plan



## Artifacts



