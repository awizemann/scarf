---
id: t-76edf0e0
title: Wiki — update Chat/ScarfGo/ACP pages for the load-only reconnect ladder
status: done
added: 2026-07-13
---

## Description

t-217da62b audit flag: wiki/Chat.md (4 mentions), wiki/ScarfGo.md, wiki/ACP-Subprocess.md (documents the now-deleted ACPClient.resumeSession), and wiki/Hermes-Version-Compatibility.md still describe the resume-with-load-fallback reconnect ladder. Commit d19dca4 removed resume entirely (load-only; resume was dead code and orphaned server-side sessions — see memory chat-session-layer note). Update the pages to describe the load-only ladder + DB reconcile behavior.

## Plan



## Artifacts



