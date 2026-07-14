---
title: Local-Models
type: note
permalink: scarf-wiki/local-models
created: 2026-07-13
updated: 2026-07-14
---

# Local Models (Ollama, LM Studio, vLLM, llama.cpp, custom endpoints)

Scarf's model picker has a **Remote | Local** filter (Settings → General → model row, and the
chat's "pick a model" sheet). The Local tab configures Hermes to chat against a model server
running **on the Hermes host** — for a remote server window, that means local to the *server*,
not to your Mac.

## Providers

| Provider | Endpoint default | Notes |
|---|---|---|
| **Ollama** | `http://127.0.0.1:11434/v1` | Scarf always saves the base URL — Hermes has no built-in Ollama default and would otherwise silently route to OpenRouter. Installed models are listed live (`/api/tags`) with size/quant details. |
| **LM Studio** | `http://127.0.0.1:1234/v1` | Base URL optional (Hermes' registry default; `LM_BASE_URL` env overrides). Hermes JIT-loads the selected model. |
| **vLLM / llama.cpp** | none — you supply it | Saved as provider `vllm` / `llamacpp` (Hermes runtime-aliases both to `custom`). |
| **Custom endpoint** | none — you supply it | Any OpenAI-compatible server. Optional API key and API mode (auto-detect, chat_completions, codex_responses, anthropic_messages, bedrock_converse). Leaving the model empty on a loopback URL lets Hermes auto-detect a single loaded model. |

No API key is needed for Ollama/LM Studio/vLLM/llama.cpp — Hermes substitutes a placeholder itself.

## Context window requirements

Hermes needs a model with at least a **64K-token context window** to run its agent loop reliably.
The Local picker enforces this floor: each Ollama model is listed with its context length, and
models under 64K can't be selected. The **llama3.1 family** (128K context) is the recommended
starting point. If a configured model fails the floor check, the error Scarf surfaces states the
real reason (context window too small) instead of a generic failure.



## Behavior notes

- **Live model list**: the picker probes the daemon through the server connection (3s budget) and
  distinguishes "couldn't reach it — is it running?" from "running but no models installed"
  (`ollama pull <model>`). A manual-entry field is always available.
- **Clean switching**: changing provider (local↔cloud or between locals) clears stale
  `model.base_url` / `model.api_key` / `model.api_mode` / `model.context_length` keys before writing the new selection —
  stale endpoint keys are a known source of misrouted chats upstream.
- **Multiple models**: local/remote is a *picker filter*, not an app mode — auxiliary task models
  and model presets are configured independently, exactly as before.

Verified against the Hermes v0.17 runtime reader (see repo memory:
`architecture/local-provider-config-keys-hermes-reader-verified-v0-17-0`). Shipped on branch
`feat/local-models` (v2.16.2 baseline).
