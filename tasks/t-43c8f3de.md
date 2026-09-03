---
id: t-43c8f3de
title: Chat activity-bubble UX (P1–P4)
status: doing
added: 2026-09-02
---

## Description

Approved 2026-09-02 (Alan). Aggregate a turn's tool/reasoning activity into one expandable ActivityBubble per segment (counts header + latest tool card + disclosure to full list; identical calls collapse ×N); streamed text renders as its own bubble; the trailing live ActivityBubble replaces the typing dots with real status (Running <tool>… / Reasoning… / Receiving response…) from live VM data (not the polled sessions.last_activity_description column). Data fixes riding along: backfill tool-call args from completion events (Hermes omits rawInput on many starts — "{}" cards), and stop rendering the thoughts-only blank shell. Presentation-layer only; preserves MessageGroupView Equatable perf machinery and the density hide toggles. Torture-test case: the ShabuBox SEO session (169 execute calls, model looping — the ×N collapse makes that legible).

## Plan



## Artifacts



