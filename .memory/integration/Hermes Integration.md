---
title: Hermes Integration
type: note
permalink: scarf/integration/hermes-integration
tags: [hermes, integration]
source_sha: 1ebbf6c45e34bf8a4304b3b465026ff7216b112f
created: 2026-05-29
updated: 2026-05-29
reviewed: 2026-05-29
reviewed_by: human
---

## Observations
- [path] Hermes home: ~/.hermes/ — Scarf reads this directly (sandbox disabled) #paths
- [path] Key files: state.db (SQLite WAL, read-only), config.yaml, memories/MEMORY.md, memories/USER.md, SOUL.md, sessions/session_*.json, cron/jobs.json, logs/errors.log, logs/gateway.log, .env (secrets), skill-bundles/*.yaml #paths
- [transport] Chat uses ACP (Agent Client Protocol) — `hermes acp` subprocess over stdio JSON-RPC. Remote ACP tunnels as `ssh -T host -- hermes acp` #acp
- [remote] Remote Hermes reached via system SSH (~/.ssh/config, ssh-agent, ProxyJump, ControlMaster). File I/O via scp/sftp. SQLite served from atomic `sqlite3 .backup` snapshots cached in ~/Library/Caches/scarf/snapshots/<server-id>/ #remote
- [remote-reqs] Remote host requires: SSH key-based auth, sqlite3 on PATH, pgrep on PATH, ~/.hermes/ readable by SSH user. Diagnostics sheet runs 14 checks in one SSH session #remote
- [log-parsing] HermesLogService.parseLine treats the session_id tag between level and logger name as optional — older untagged lines still parse #logs

## Relations
- consumed_by [[Scarf Project Overview]]
- relates_to [[Hermes Version Management]]
