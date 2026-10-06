---
id: t-27a18eaa
title: Analytics P2: tighten emissions (gating, dedupe, lifecycle, toggle)
status: done
added: 2026-10-06
---

## Description

Gate agent_turn_*; defer launch events until first activation; dedupe connection_degraded per host+cause process-wide; drop .appBackground (flush on resign); bounded terminate flush; fix Settings toggle race/no-client; remove dead enum cases + deep_link test token; section_viewed per session; document series breaks.

## Plan



## Artifacts



