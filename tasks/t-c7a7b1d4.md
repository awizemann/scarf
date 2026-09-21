---
id: t-c7a7b1d4
title: iOS transport: stale "no stdin" error + document rc-file stdin edge
status: done
added: 2026-09-18
priority: low
---

## Description

Leftovers from F5 (t-97cf2ed9):
1. CitadelServerTransport.swift ~205-208 still throws "does not support stdin yet", although runExec now supports stdin (5df8d8bd). Wire stdin through, or correct the message.
2. Since streamScript now sends the script on stdin (`head -c N | /bin/sh`), a host whose login rc files read stdin (e.g. a `read` in .bashrc) would eat script bytes, and the call would then time out. Document it in the transport doc comment and the troubleshooting wiki.

## Plan



## Artifacts



