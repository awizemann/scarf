---
id: t-ma2agt
title: **[miniapps/M2]** Fix MiniAppAgentSession prompt-completion hang + add runtime tests — `scarf.prompt` never resolved on a normal turn (it awaited a stream `.promptComplete` that `ACPClient` never emits; `sendPrompt`'s RETURN is the real completion signal), so the JS promise hung until teardown and the session wedged at `promptInFlight=true`. Fix: synthesize `.promptComplete` from `sendPrompt`'s return through `handle()` (also fires the `onEvent` "complete"). Added `scarfTests/MiniAppAgentSessionTests` (7 tests via an injected `clientFactory` + in-memory `FakeACPChannel`) guarding completion + the two 350c3bd concurrency fixes (atomic busy claim across the `ensureSession()` await; no continuation leak on stream end) + rate-limit / permission-auto-cancel / shutdown. Teeth verified (revert → 4/7 clean-fail); full `scarfTests` green. See [[ACP turn completion is sendPrompt's return, not a stream .promptComplete event]].
status: archived
---

## Description



## Plan



## Artifacts



