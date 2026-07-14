---
id: t-eef64af3
title: Local models T2 — live model enumeration via server transport
status: done
added: 2026-07-13
---

## Description

Service that lists installed local models on the HERMES HOST (works for remote servers through the existing transport): Ollama via GET 127.0.0.1:11434/api/tags (curl through runProcess), fallback `ollama list`; LM Studio via GET :1234/v1/models if trivial (same OpenAI-compatible pattern). Graceful "daemon not running" state. Unit tests with canned JSON; no network in tests.

## Plan



## Artifacts



