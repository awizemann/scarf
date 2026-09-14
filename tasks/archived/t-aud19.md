---
id: t-aud19
title: **[t-aud19]** iOS onboarding navigation — DOCUMENTED linear-by-design (audit option b). Added a doc comment to `OnboardingRootView` explaining the flow is intentionally one-directional: it generates/imports an SSH key + writes config as it advances, so arbitrary back-stepping could strand a half-provisioned state; the only backward path is `goBackToServerDetails()` for test-failure recovery, and Cancel returns to the server list. Chose documentation over a `Previous` button because general back-nav through this key-generating state machine risks inconsistency for ~0 user benefit. Comment-only.
status: archived
---

## Description



## Plan



## Artifacts



