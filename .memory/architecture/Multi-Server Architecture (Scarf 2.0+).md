---
title: Multi-Server Architecture (Scarf 2.0+)
type: note
permalink: scarf/architecture/multi-server-architecture-scarf-2.0
tags:
- architecture
- transport
- ssh
source_sha: c76d37fdd58cef8b1a3b1c24c036f29ab57919f3
source_paths: scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHTransport.swift, scarf/scarf/Features/Servers/Views/RemoteDiagnostics.swift, README.md
created: 2026-05-29
updated: 2026-05-29
reviewed: 2026-07-18
reviewed_by: audit:claude-code (background)
---

## Observations
- [design] Scarf is a multi-window app: each window is bound to exactly one Hermes server. Local `~/.hermes/` is synthesized as a server automatically; remote servers added via File → Open Server… → Add Server. #multi-window
- [design] Remote Hermes is reached over system SSH (uses ~/.ssh/config, ssh-agent, ProxyJump, ControlMaster). Scarf never prompts for passphrases — user must run `ssh-add` first. #ssh
- [design] Transport split: file I/O flows through scp/sftp; SQLite is served from atomic `sqlite3 .backup` snapshots cached under `~/Library/Caches/scarf/snapshots/<server-id>/`; chat (ACP) tunnels as `ssh -T host -- hermes acp` with JSON-RPC over stdio end-to-end. #transport
- [requirement] Remote host requirements: key-based SSH auth, `sqlite3` on remote PATH (for DB snapshots), `pgrep` on remote PATH (dashboard running-check), and `~/.hermes/` readable by the SSH user. #requirements
- [feature] Add-Server Test Connection probes fallback Hermes home paths (`/var/lib/hermes/.hermes`, `/opt/hermes/.hermes`, `/home/hermes/.hermes`, `/root/.hermes`) when `state.db` isn't found at `~/.hermes/`. #onboarding
- [tool] Manage Servers → 🩺 Run Diagnostics runs 14 checks in one SSH session (connectivity, sqlite3, config.yaml/state.db read access, effective non-login PATH) with per-check remediation hints and Copy Full Report. #diagnostics

## Relations
- extends [[Scarf Architecture Rules]]
- relates_to [[Hermes Integration]]