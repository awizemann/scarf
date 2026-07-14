# Local models — plan (2026-07-13)

Surface local model providers (Ollama, LM Studio, vLLM/llama.cpp, custom endpoints) in Scarf's
model-selection UI. Investigation (see memory:
`architecture/local-model-providers-what-exists-below-the-ui-and-what`) found the plumbing already
exists — aliases, validation fail-safes, a working free-form path — but nothing sources it in the UI.

**Framing:** a *picker filter* (Remote | Local sections in `ModelPickerSheet`), not an app-global
mode — Scarf runs multiple models (main + auxiliary + presets), so local/remote is per-selection.
"Local" = local to the **Hermes host**, so remote servers' Ollama works through the transport.

**Hard constraint:** do NOT add local providers to `overlayOnlyProviders` —
`check-hermes-tables.py` lane 3 fails for Scarf overlays Hermes doesn't define. Local surfacing is
a client-side descriptor table + UI grouping.

**Branch:** `feat/local-models` (from v2.16.2). Each task: plan → execute → test for real →
adversarial fresh-eyes audit → clean commit, run by a subagent; sequential (T0 → T1 → T2 → T3 → T4).

| Task | Board ID | Scope |
|---|---|---|
| T0 research | t-15c5d10f | Reader-verify Hermes config keys per local provider (base_url/env/api_mode/credentials) |
| T1 descriptors | t-476df553 | `LocalModelProvider` table in ScarfCore + tests |
| T2 enumeration | t-eef64af3 | Installed-model listing via transport (Ollama :11434/api/tags, LM Studio :1234/v1/models) |
| T3 UI | t-8eeb9242 | Remote/Local control in ModelPickerSheet (covers Settings, preflight, Credential Pools) |
| T4 ship | t-7e4b4f86 | Feature-wide adversarial audit, docs, dogfood build (`./scripts/build-detached.sh`) |

Exit criterion: Alan picks an installed Ollama model from the picker's Local section on this Mac
and chats with it.
