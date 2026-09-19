---
id: t-3ba95f7e
title: Mac: local streamScript puts the script in argv (sh -c)
status: done
added: 2026-09-18
priority: low
---

## Description

Found in P4 (t-a4665c6e). On the Mac, LocalTransport runs scripts as `/bin/sh -c <script>`, so the whole script sits in the process's command line on the user's own machine while it runs: for Live Voice that's the SDP offer, for Hermes Voice the spoken text. It's local-only exposure, which is lower risk than the iOS/SSH case fixed in 5df8d8bd. Fix: feed the script on stdin (`/bin/sh -s`, or the same `head -c` pattern) to match the iOS transport; check every local streamScript caller.

## Plan



## Artifacts



