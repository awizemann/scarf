---
title: Real SSH server option for the VM UI gate, and what Hermes v0.22.5 costs a host
type: note
permalink: scarf/operations/real-ssh-server-option-for-the-vm-ui-gate-and-what-hermes
source_paths: [scripts/ui-gate-vm.sh, scripts/ui-fixture/real-remote-server.py]
source_paths_inferred: false
source_sha: ecd49dbc13fd15797d5b5c384937c18952edd5a9
created: 2026-11-01
updated: 2026-11-01
---

Added for v3.8.0. Loopback never showed the slow-start lost-prompt bug; the real server did on its first full run.

## Observations
- [fact] ui-gate-vm.sh --real-remote user@host --real-remote-key <file> runs the Live plan against a real server in a throwaway Hermes home, removed afterwards; memory floor SCARF_VM_REAL_REMOTE_MIN_MB defaults to 100 #uigate
- [fact] On v0.22.5 one hermes acp is about 170 MB and a gateway about 280 MB; a temporary HERMES_HOME gets its own gateway and about 400 MB of dependencies unless hard-linked; session/new took about 20 s on 1 vCPU #hermes
- [gotcha] 1 GB and 8.7 GB disk can't host this; 2 GB memory with 2 GB swap never went below 259 MB available #droplet
- [gotcha] Upgrade a server with Hermes's own installer pinned to a commit, never by hand with uv sync: a hand sync leaves no committed environment and hermes acp refuses to start until hermes pm repair, which installs .[all] #hermes
- [gotcha] A background hermes -z in a temporary home starts a gateway that recreates the home after deletion; kill by /proc environ HERMES_HOME before removing it #hermes
