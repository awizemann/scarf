---
id: t-90c8afa2
title: v0.21 W7: cron — decoder + incidents + doctor
status: todo
added: 2026-09-01
priority: high
---

## Description

Cron package: (1) HermesCronJob.swift:487-504 decoder must accept ID-keyed map {"jobs":{"<id>":{...}}} and bare repeat values ("forever"/"once"/3) per cron/jobs.py normalization; (2) activation of terminal (completed/error) jobs now raises — handle in CronViewModel enable toggle with friendly message; (3) ADOPT hasCronIncidents (floor is isV0206OrLater — W0 verified): `cron incidents [list|ack] [--state]` — HermesCronIncident model + parser + UI; (4) ADOPT hasCronDoctor (v0.21 floor): `cron doctor` surface; (5) ADOPT hasCronResumeRunNow (v0.20.6 floor): "Resume and run now"; (6) --deliver bot-chat[:profile] gated hasCronBotChatDelivery (v0.20.6 floor) — AND fix supportsCronDeliver(_:) at HermesCapabilities.swift:323: it only gates the `all` sentinel and returns true for bot-chat on old hosts, which would fail the whole cron create at argparse — add a bot-chat branch; (7) monitor_* fields pass through extra — verify no strip. Pre-0.20.6 renders byte-identical.

## Plan



## Artifacts



