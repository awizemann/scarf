---
id: t-e96cc0ad
title: Audit F2: data/transport security
status: done
added: 2026-09-02
priority: urgent
---

## Description

Cross-cutting security: validate HermesToolCall.callId charset at decode + SQLValueInliner reject/encode newlines (heredoc-delimiter escape) + sanitizeFTSQuery newline handling; `--` end-of-options before user positionals in cron create/update argv AND (now VERIFIED by the real Kanban audit) every free-text Kanban positional — KanbanCreateRequest.swift:110-112 title, KanbanService.swift:259-260 comment, :291 block reason (also stop space-splitting it), :361 promote reason, :411 swarm goal — HermesPeerCLI.swift:64 is the precedent; delete BOTH forgeable "no matching tasks" sentinels (KanbanService.swift:64, KanbanViewModel.swift:106 — --json already emits []); KanbanInspectorPane.swift:514 worker body: plain Text or scheme-filtered rendering (match comment bodies); secrets out of argv (ntfy→.env NTFY_TOKEN, `hermes auth add` via stdin after verifying prompt reads stdin, whatsapp_cloud flag upstream + document); SSHTransport.writeFile remote chmod 600 for private basenames; BotsRosterScan shell-side name validation; webhook Secret→SecureField + surface generated HMAC secret; CuratorService stderr + CronViewModel argv logging privacy .private.

## Plan



## Artifacts



