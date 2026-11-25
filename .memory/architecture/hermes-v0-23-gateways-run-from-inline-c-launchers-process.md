---
title: Hermes v0.23 gateways run from inline -c launchers; process matcher must recognise them
type: note
permalink: scarf/architecture/hermes-v0-23-gateways-run-from-inline-c-launchers-process
tags: [gateway, hermes-v0.23]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesGatewayProcessMatch.swift]
source_paths_inferred: false
source_sha: d6fad1d094f9131d4ed3245996ff6ca75a784dcd
created: 2026-11-24
updated: 2026-11-24
reviewed: 2026-11-24
reviewed_by: audit:claude-code (background)
---

gh#154. Scarf's HERMES card/menu bar/Stop fallback find the gateway by matching its command line (pgrep -f / ps). v0.23 changed that command line.

## Observations
- [fact] Since Hermes v0.23.0 the gateway runs as `<python> -I -c '<launcher source>' [-p name] gateway run` (bin/hermes, runtime_command) or `-P -c` (bundled/Docker/sealed macOS launcher); HermesGatewayProcessMatch accepts these by anchoring on the first -c program's first statement and its hermes_cli.main entry, like Hermes's own _BOOTSTRAPS #gateway
- [gotcha] The launcher source is multi-line: pgrep sees real newlines, Linux ps prints `?`, macOS `ps -ww` prints the literal text `\012`; without -ww ps truncates the line before `gateway run` #gateway
- [gotcha] On v0.23 one host gateway serves every profile: `hermes -p ops gateway run` exits saying the default gateway already serves it, so named profiles are detected through the multiplexer path, not their own pgrep #gateway
- [gotcha] A local default-profile gateway of any version makes the default pgrep pattern succeed, so a local live test only discriminates by checking the specific PID, not the Dashboard #testing
