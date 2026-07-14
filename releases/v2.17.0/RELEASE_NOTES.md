# Scarf v2.17.0

The headline: **local models**. Scarf can now run against Ollama, LM Studio, vLLM, llama.cpp, or any OpenAI-compatible endpoint — with a proper picker, live model discovery, and guardrails so the model you pick actually works. Alongside it, a deep **chat reliability overhaul** that fixes four ways a chat session could silently stall, and a settings fix that was quietly resetting your dropdowns. This is a feature release, not a patch — but it stays fully compatible with your current Hermes (no version bump required).

## Local models: pick a model running on your own hardware

The model picker (Settings → the model row, and the chat's "pick a model" sheet) gains a **Remote | Local** filter. The Local tab lists **Ollama, LM Studio, vLLM, llama.cpp, and Custom endpoint**, each writing exactly the config Hermes needs — including the base URL Ollama requires but Hermes doesn't default (without it, Hermes silently falls through to a cloud provider).

- **Live model discovery.** For a local server, Scarf asks the daemon what's actually installed and lists it — with each model's size and quantization. It distinguishes "the daemon isn't running" from "no models installed yet," so you're never left guessing. This works for a **remote** server's daemon too, over the same SSH connection — Scarf probes the Hermes host's local endpoint, not your Mac's.
- **Context-window gating.** Hermes requires a model with at least a **64K token context window**, and rejects anything smaller at chat time with an opaque error. Scarf now reads each local model's real context window and **blocks** sub-64K models in the picker with a plain-language explanation (and a nudge toward the llama3.1 family), so you find out before you pick, not after a cryptic failure. Errors that do come back from Hermes now show the real reason instead of "Internal error."
- **Image heads-up.** If you attach an image to a model that can't see images, Scarf now warns you in the composer — including for local models, where it reads the daemon's own capability report. (Otherwise Hermes quietly routes the image to a lossy text description, which is where the confusing "this model can't read images / requires a paid subscription" replies came from.)
- **Clean switching.** Changing provider — local↔cloud or between locals — now scrubs stale endpoint keys so a leftover `base_url` can't silently misroute your next chat.

**One honest caveat:** on Hermes versions before 0.18 (and until an upstream fix ships), Hermes's *auxiliary* features — automatic chat titles, context compression, and image-vision routing — don't yet recognize local providers and fall back to cloud providers or degrade. Your main chat works correctly against the local model; these secondary features are the rough edge. We've filed the upstream fix ([hermes-agent #64144](https://github.com/NousResearch/hermes-agent/issues/64144)); updating Hermes once it lands resolves it.

## Chat sessions that don't silently stall

Dogfooding the local-model work surfaced four long-standing ways a chat could wedge or lose output — all now fixed:

- **Phantom sessions.** Opening a session the server could no longer restore left Scarf attached to a session that didn't exist, so your next message came back as a bare refusal. Scarf now detects the not-restorable response and cleanly starts a fresh session instead.
- **The deaf transcript.** Re-sending a message identical to one already in your history could cause the entire reply to stream in *invisibly* — the turn ran on the server, but nothing painted. Fixed.
- **The stuck spinner.** A chat that wedged on start would spin forever with the sidebar frozen — restart-only recovery. Session starts are now bounded by a watchdog that surfaces a retry, and clicking another chat always supersedes a slow start instead of locking the UI.
- **Mid-turn cleanup.** Switching away from or deleting a session mid-reply now cancels the turn cleanly instead of orphaning the process — including when you delete the active session from the Sessions tab.

## Settings dropdowns that remember your choice

Some Settings dropdowns — Web Tools search/extract backends, a few Advanced controls — saved your selection but reloaded showing blank or the default. The Mac app was carrying a **duplicate config parser** that had drifted out of sync with the shared one and didn't understand newer keys. We deleted the duplicate (the app now uses one parser everywhere) and added a build-time gate that fails CI if any settable key ever lacks a reader again, so this class of bug can't come back.

## Also new

- **"Choose model…" on the mismatch banner.** When your configured model and provider don't line up, the banner now always offers a one-click path to just pick a valid model from the full picker — not only the two guessed fixes.

## Under the hood

- New `LocalModelProviders` / `LocalModelEnumerator` / `LocalModelConfigPlan` in ScarfCore, source-verified against the Hermes v0.17 runtime and covered by an extensive test suite; every provider-switch write path routes through one config planner with crash-safe ordering.
- The session-layer fixes moved the ACP pipe readers off the Swift concurrency pool (they could starve it), added generation-based supersede to the start path, and made `session/load` failure handling and reconnect load-only (which also stops Hermes from accumulating orphan sessions on reconnect).
- ScarfCore suite: **978 tests**; Mac app test bundle: **264**. Two upstream Hermes contributions filed this cycle ([issue #64144 / PR #64146](https://github.com/NousResearch/hermes-agent/pull/64146), plus a review comment on an in-flight alias PR).

## Upgrade notes

- **Sparkle** will offer the update automatically, or use **Scarf → Check for Updates**. macOS 14.6+ deployment target unchanged.
- **No Hermes version floor.** Everything here works against Hermes 0.17 (verified). The local-model auxiliary-feature caveat above resolves by updating Hermes to 0.18+ once the upstream alias fix ships.
- **iOS / ScarfGo: no new build needed for this release.** The Mac local-model and session-layer work compiles in shared ScarfCore but doesn't change iOS runtime behavior. (A separate iOS-only fix — routing the ScarfGo model-preflight write through the same config planner so it scrubs stale keys — is queued for the next TestFlight build.)
