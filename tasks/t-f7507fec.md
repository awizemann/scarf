---
id: t-f7507fec
title: Turn duration pill: /queue and /steer edge cases
status: todo
added: 2026-09-29
priority: low
---

## Description

From the 2026-09-29 fresh-eyes review of #148: when the main turn returns while a /queue'd turn is in flight, othersStillRunning() skips promptComplete, so closeTurnStopwatch never runs for the main turn and one pill spans both turns (lands on the queued turn's last message). In loaded history, a persisted /steer user row splits one turn into two pills. RichChatViewModel.swift closeTurnStopwatch / derivedHistoryTurnDurations.

## Plan



## Artifacts



