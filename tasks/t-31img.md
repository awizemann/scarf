---
id: t-31img
title: **[enhancement/gh#113]** Composer heads-up when an image is attached to a session whose active model isn't vision-capable (so users aren't left guessing why it didn't land — see t-77ec00 root cause: Hermes routes non-vision-model images to a lossy text pipeline). Needs a per-model vision-capability signal on the Scarf side (models.dev lookup or heuristic; `HermesCapabilities` is version-scoped, not per-model) — design + source TBD. Risk: LOW (additive UX).
status: done
added: 2026-06-13, source: gh#113 root cause
---

## Description



## Plan



## Artifacts



