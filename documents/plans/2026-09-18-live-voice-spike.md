# Live Voice spike (P3): GPT-Live through a WKWebView, with Hermes holding the key

Task: t-29bc9831 · Date: 2026-09-18 · Branch: `feat/voice-spike` (commit `52dde703`, `scarf/Spikes/VoiceLive/`)
Hermes source: tag `v2026.9.14` (Hermes 0.21.3). Local install: `v0.21.2 (2026.9.11)` at `a89c1e1135`, 938 commits past v2026.9.11. The voice-live files I relied on are byte-identical to the tag (`git diff v2026.9.14 --` on `tools/voice_live.py`, `acp_adapter/{content,server}.py` and `tools/tool_backend_helpers.py` is empty).

## Verdict: GO

The design Alan chose holds up. Scarf will use a WKWebView for WebRTC (RTCPeerConnection + getUserMedia). A host script over `ServerTransport.streamScript` performs the session exchange by calling Hermes's own `tools.voice_live`, so the OpenAI key stays on the host. Each delegation becomes a normal ACP turn. We don't need a native WebRTC package. The only gap is ACP's missing `voice-live` surface. An ACP embedded-resource block closes it: the turn note goes to the model and stays out of the saved transcript, which matches what the desktop app and tui_gateway store.

**This spike did not make a live OpenAI call.** This host has no key: `resolve_gpt_live_status()` returns `available: false`, and the mode is `chained`. The one link that has never run end to end is OpenAI's `/v1/live/sessions` accepting a WebKit offer and connecting media. The first P4/P5 run with a key has to cover it (see Risks).

### What ran and what was reasoned

| Claim | Evidence |
|---|---|
| The host script calls `resolve_gpt_live_status` / `create_webrtc_session` in the Hermes venv with `HERMES_HOME` scoped | **Ran**: `run_exchange_tests.sh` against the real local venv, using a throwaway HERMES_HOME and a mock vendor endpoint. The status probe also ran read-only against the real `~/.hermes`, and `config.yaml`'s mtime did not change. |
| Error mapping (no_key / vendor+status / network / bad_request / unsupported) and key-echo redaction | **Ran**: all paths exercised. A mock 401 that echoed `sk-proj-…` was redacted. |
| A WebKit-generated SDP offer reaches the vendor byte-exact, including the trailing CRLF, with `delegation: {type: client}`, the model, the voice and the history | **Ran**: offer captured from the macOS WKWebView and sent through `sh -s` → python → HTTP to the mock. `sdp_byte_exact=True trailing_crlf=True`. |
| WKWebView has a secure context for `scarf-voice://` (custom scheme), `https://localhost` baseURL and `file://`, but not for a `nil` baseURL | **Ran**: macOS 27.0 and iOS 26.2 simulator. |
| RTCPeerConnection, the `oai-events` data channel (DTLS/SCTP) and remote-audio autoplay all work in WKWebView | **Ran**: in-page loopback, on macOS and the iOS simulator. |
| getUserMedia goes through `WKUIDelegate` media-capture permission. The track reports `echoCancellation: true`. The mic track goes into the offer as sendrecv | **Ran, with WebKit's mock capture device** (test-only SPI). The delegate was called with origin `scarf-voice://app`, type microphone. |
| The **real** microphone works under TCC for a hardened-runtime, non-sandboxed app | **Reasoned**: not run. I avoided raising a macOS TCC prompt for a throwaway bundle. Scarf already has `com.apple.security.device.audio-input` (`scarf/scarf/scarf.entitlements`) and `NSMicrophoneUsageDescription` (`scarf/scarf/Info.plist`). |
| Real device AEC quality, the AVAudioSession handoff and Bluetooth routes on iOS | **Not run**: simulator only, mock mic. Needs a real iPhone. |
| Over SSH/Citadel | **Reasoned**: it is the same `streamScript` path `HermesSpeechService.orchestratorScript` already runs over SSH. Size is fine (next section). |
| The ACP embedded-resource turn note is model-input only | **Ran offline** against Hermes's own parser: `acp.schema.PromptRequest` → `_extract_text` / `_content_blocks_to_openai_user_content` in the venv. No real turn was sent. |

Correction to the brief: the macOS app is **not sandboxed** (`ENABLE_APP_SANDBOX = NO`, hardened runtime, per the charter's non-goals). What matters for the mic is the hardened-runtime `audio-input` entitlement plus the usage string, and both are present.

---

## 1. Session exchange as a host script

**Hermes surface** (tag `v2026.9.14`):
- `tools/voice_live.py:131-144` `resolve_gpt_live_status()` returns `{mode, available, reason, model, voice}` and never includes the key.
- `tools/voice_live.py:162-186` `create_webrtc_session(sdp_offer, history)` POSTs `{session: build_session_config(history), transport: {type: webrtc, sdp}}` to `{base_url}/live/sessions` with a 30 s urlopen timeout. It raises `ValueError` when no key is available and `RuntimeError("… (<status>): <detail>")` when the vendor rejects the request. It catches **only** `HTTPError`, so `URLError` and timeouts propagate raw.
- Key order (`voice_live.py:114-123`, `tool_backend_helpers.py:151-162`): `voice.gpt_live.api_key` → `VOICE_TOOLS_OPENAI_KEY` → `OPENAI_API_KEY` (env/.env, then the `openai-api` credential pool). `base_url` comes from `voice.gpt_live.base_url` (default `https://api.openai.com/v1`).
- The dashboard route wraps the same call in `_config_profile_scope(profile)` (`hermes_cli/web_routers/audio.py:58-69, 167-197`) and maps ValueError→503 and RuntimeError→502. It checks the SDP only for emptiness and never strips it: *"a stripped offer answers 400 'failed to unmarshal SDP: EOF'"* (audio.py:189-191).

**Scoping.** `load_config()` and the `.env` / pool reads resolve from `HERMES_HOME`. Exporting `HERMES_HOME=<server's resolved home>` in the script therefore gives the same profile scoping the dashboard gets from `_config_profile_scope`. Scarf already resolves a per-window home (`HermesProfileScope` / `ServerContext`).

**Interpreter discovery.** Reuse `HermesSpeechService.orchestratorScript` (`ScarfCore/Services/HermesSpeechService.swift:416-440`): resolved hermes binary → `readlink -f` → sibling `python` (the git/uv/pipx venv layout; locally `~/.local/bin/hermes` → `~/.hermes/hermes-agent/venv/bin/hermes`, whose shebang is `#!/bin/sh`, so reading the shebang would not help). Fallback is `python3`. If that can't import Hermes, the shim reports `unsupported` instead of failing obscurely.

**Script shape** (`scarf/Spikes/VoiceLive/build_script.sh` emits exactly what Swift should generate):
```sh
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
hb="<hermesBinary>"; case "$hb" in */*) ;; *) hb=$(command -v "$hb" 2>/dev/null || printf '%s' "$hb") ;; esac
real=$(readlink -f "$hb" 2>/dev/null || printf '%s' "$hb"); pyd=$(dirname -- "$real")
if [ -x "$pyd/python" ]; then py="$pyd/python"; else py="python3"; fi
export HERMES_HOME="<home>"
"$py" -c '<voice_live_host.py — contains no single quote; pin with a test>' <<'SCARF_JSON'
{"op":"session","sdp":"v=0\r\n…\r\n","history":[…]}
SCARF_JSON
```
- The request travels as JSON. CR/LF are escaped as `\r\n`, so the heredoc stays single-line ASCII and the offer arrives byte-exact (verified).
- Output is one `SCARF_VOICE_LIVE:{json}` line. The caller parses the **last** marker line. Exit status is 0 whenever a marker printed. A non-zero exit or a missing marker counts as a transport/interpreter failure.
- `logging.disable(CRITICAL)` is required: `create_webrtc_session` logs the vendor detail at WARNING (`voice_live.py:185`), and that would otherwise land in stderr.
- Redaction of `sk-…`, `Bearer …` and `ek_…` is required: OpenAI's 401 body echoes a masked key prefix, and `RuntimeError` carries 600 chars of that body.

**Error mapping** (all ran):

| Shim `kind` | Cause | UI |
|---|---|---|
| `unsupported` | `import tools.voice_live` failed (pre-0.21.3 or wrong python) | hide the entry point |
| `no_key` | ValueError | "Add an OpenAI key on the host" hint, no session |
| `vendor` + `status` | RuntimeError / missing SDP (401 bad key, 403 no gpt-live access, 429 quota, 400 SDP) | error with the status, no retry loop |
| `network` | URLError / timeout / JSON | "Couldn't reach OpenAI from the Hermes host" |
| `bad_request` | empty SDP / unknown op | bug; log it without the SDP |
| (transport) | `streamScript` throws, or no marker line | "Couldn't reach the Hermes host" |

**Timeouts** (C10). Use `status` 20 s and `session` 45 s (the desktop uses 45 s, `voice-live.ts:328`). Everything is nonisolated/off-main.

**Size.** The script with a real WebKit offer is 6,269 bytes; the offer is about 1.9 KB. The desktop's history cap is 6,000 chars (`voice-live.ts:152-180`). Citadel sends the script base64-encoded as one argv token (`CitadelServerTransport.swift:254-270`), which works out to roughly 20 KB in the worst case. That is far below Linux `MAX_ARG_STRLEN` (128 KB). A unit test should cap it.

**Secrets.** The SDP offer and answer carry ICE ufrag/pwd and DTLS fingerprints. Never log either one (ScarfMon, os_log, error text).

## 2. WKWebView WebRTC on macOS and iOS

Probe results from Harness.swift + spike.html, macOS 27.0 and iOS 26.2 simulator:

| Load | isSecureContext | mediaDevices | loopback + data channel | autoplay |
|---|---|---|---|---|
| `scarf-voice://app/…` via `WKURLSchemeHandler` | **true** | yes | connected, round-trip OK | playing |
| `loadHTMLString(baseURL: https://localhost/)` | true | yes | OK | playing |
| `loadFileURL` | true | yes | OK | playing |
| `loadHTMLString(baseURL: nil)` (about:blank) | **false** | **no** | – | – |
| scheme page, web view **not in a view hierarchy** | true | yes | connected | **`play()` never resolves**; `visibilityState: hidden` (first run: whole page stalled) |
| scheme page, `alpha = 0` (in hierarchy) | true | yes | OK | playing (visible) |
| scheme page, `isHidden = true` (in hierarchy) | true | yes | OK | playing |

**Requirements for P4/P5:**
1. **Origin:** serve the page from a custom scheme (`scarf-voice://live/index.html`) with a `WKURLSchemeHandler`. It is a secure context on both platforms, needs no listener or file on disk, and gives a stable origin to check in the permission delegate. `baseURL: nil` removes `navigator.mediaDevices` entirely.
2. **Permission:** implement `webView(_:requestMediaCapturePermissionFor:initiatedByFrame:type:decisionHandler:)` (macOS 12 / iOS 15+). Grant **only** for `origin.protocol == "scarf-voice"` and microphone type; deny everything else. That suppresses WebKit's own per-origin prompt. The OS TCC prompt still comes on first use. macOS needs the existing `audio-input` entitlement and `NSMicrophoneUsageDescription`. iOS needs `NSMicrophoneUsageDescription`, which already exists (`Scarf iOS/Info.plist`, from P2).
3. **Playback:** `configuration.mediaTypesRequiringUserActionForPlayback = []`. On iOS also set `allowsInlineMediaPlayback = true`.
4. **Hosting:** the web view must be **in the window's view hierarchy**. A 1×1 view at `alpha 0` inside the voice panel is enough. A detached web view never plays audio.
5. **Echo cancellation:** WebKit honours `echoCancellation: true` (the track settings report it). On Apple platforms WebKit captures through the voice-processing I/O unit, so AEC/AGC/NS come from the OS. This is reasoned from WebKit behaviour and needs a real device to judge quality.
6. **AVAudioSession (iOS):** the harness process stayed `SoloAmbient` because the mock device doesn't touch it. Real capture makes WebKit switch the app's session to PlayAndRecord for the duration. **Before starting**, P5b must stop PushToTalk dictation and Scarf's TTS playback (`AVAudioEngine`/player), and restore the state after `closed`. End the session when the scene goes to background (ScarfGo has no background-audio mode, and a running session bills).
7. **ICE:** WebKit hides host candidates behind mDNS `.local` names until capture is granted. Our in-page loopback therefore needed the test-only filtering switch. In production the mic is granted before `createOffer`, and the vendor side is a public endpoint the client dials out to, so this should not matter. It is reasoned, and part of the first live test.
8. **The spike used test-only WebKit SPI** (`_setICECandidateFilteringEnabled:`, `_setMockCaptureDevicesEnabled:`) behind env flags. Never ship them.

Offer shape from WKWebView: `m=audio … UDP/TLS/RTP/SAVPF 111…` with `opus/48000/2`, `m=application … webrtc-datachannel` with `sctp-port:5000`, `setup:actpass`, and a trailing CRLF. That is the same shape Chromium/Electron produces for the desktop app.

**No native fallback needed.** If the first live test fails on the vendor side (for example if the SDP answer is rejected), the fallback is a native WebRTC Swift package (stasel/WebRTC or LiveKit's WebRTC-xcframework). The host exchange, bridge protocol, conversation core and ACP handoff below would all stay; only the media layer would change. That is why P4 puts media behind a protocol.

## 3. Data-channel protocol (from the desktop source)

Channel `oai-events`, created **before** `createOffer` so its m-line is negotiated (`voice-live.ts:299-307`). No trickle: gather ICE up to 10 s, then send the full offer (`:182-212, :309-317`). `setRemoteDescription({type:'answer', sdp})` is applied from the exchange response (`:336`).

**Server → client** (`voice-live.ts:373-441`):
- `session.started {session:{id}}`: live. The desktop marks the session started.
- `session.input_transcript.delta` / `session.output_transcript.delta {delta, start_ms, end_ms}`: user and assistant caption fragments. The desktop keeps up to 2,000 fragments; the context window is the last 5 min / 80 fragments.
- `session.delegation.created {delegation:{id, type, target}}`: **the delegation carries no text.** The client builds the turn from the transcript window (`use-voice-live-conversation.ts:46-68`, `delegationPrompt`): `prompt` = the last merged user utterance (the persisted row), and `context` = `User: …` / `Voice assistant: …` lines (model input only).
- `error {error:{code,message}}`: non-fatal notice. Ignore `context_injection_incomplete` (late appends after our own close).
- `session.closed {reason, usage:{seconds}}`: terminal; usage seconds is the billing figure.

**Client → server** (`voice-live.ts:444-507`):
- `session.commentary.append {delegation_id, content, event_id:"say_N"}`: **the answer the voice paraphrases aloud**. Chunk at sentence boundaries to at most 1,400 chars per append (vendor cap of 500 tokens, `:75-76, :106-149`).
- `session.thinking.append {delegation_id, content, event_id:"think_N"}`: quiet progress ("Hermes is working: <tool>. Not done yet.").
- `session.instructions.append {delegation_id:null, content}`: session-wide steer (the desktop's "respond now" nudge).
- `session.input_audio.mute` / `.unmute`, plus disabling the mic track locally.
- `session.close`, then wait up to 15 s for `session.closed` before teardown.

**The turn loop** (`use-voice-live-conversation.ts:261-432`):
- **Delegation.** If the spoken prompt is a stop phrase, end the session (`isVoiceStopCommand`, `lib/voice-stop-word.ts`). Otherwise, if a Hermes turn is busy, **interrupt it** (this is the barge-in and supersede path). Then submit the prompt and context. If the submit fails, `speak("Sorry, I could not reach Hermes…")`.
- **Streaming back.** Every 200 ms, speak newly completed sentences of the turn's unspoken assistant text (`sanitizeTextForSpeech` first). On settle, speak the tail and clear the delegation. If a new tool name appears, send `think`.
- **Finish.** There is **no explicit "delegation done" event.** A turn counts as settled once it has been seen busy or has produced a reply, and is then idle. If it settles with nothing spoken, send `think("Hermes finished that request without a spoken result.")`. If the turn is never observed, a 15 s grace period applies.
- **Barge-in.** Audio barge-in is handled vendor-side by the full-duplex model; there is no client event for it. At the Hermes level, barge-in is "a new delegation interrupts the busy turn". The spoken stop word is also checked on the user transcript after 1.5 s of quiet (the voice model answers a bare "stop" itself and never delegates it).
- **History seed.** `toLiveHistory` = the last 24 text turns / 6,000 chars as `{type:"message", role, content:[{type:"input_text"|"output_text", text}]}` (`voice-live.ts:152-180`), passed in the exchange's `history`.

## 4. ACP handoff and the voice turn note

**The gap:** `voice-live` exists only in tui_gateway. There, `prompt.submit {surface:"voice-live", voice_context}` (`tui_gateway/contracts/prompt_voice.py:36-37`, `methods_prompt.py:541, 582-588`) puts `voice_live_turn_note(context)` (`voice_live.py:73-90`) into the **model input only** through `_prepend_note` (`session_notifications.py:683-705`, `prompt_turn.py:513`). The prompt stays the persisted row (`prompt_turn.py:544-545`). ACP has nothing equivalent: `acp_adapter/server.py:781` `prompt()` ignores `_meta`/kwargs and persists `persist_user_message=user_text` (`:773-776`).

**The seam we can use.** `acp_adapter/content.py:224-226` `_extract_text` (which becomes `user_text` and so the persisted row) joins **only blocks with `.text`**. `_content_blocks_to_openai_user_content` (`:249-275`, the model input) also inlines `EmbeddedResourceContentBlock` text (`:185-221`, `:265-266`). Sending

```json
[{"type":"resource","resource":{"uri":"scarf://voice-live/voice-live-turn-note","mimeType":"text/plain","text":"<voice_live_turn_note(context)>"}},
 {"type":"text","text":"the dentist one, thursday not friday"}]
```

gives this (ran offline through Hermes's own schema + parser):
- `persist_user_message` = `'the dentist one, thursday not friday'`
- model input = `'[Attached file: voice-live-turn-note]\nURI: scarf://…\n\n[Note: this message is a delegation from a live spoken conversation…]\nthe dentist one, thursday not friday'`

On persistence, `durable_user_row_content` (`agent/session_persistence.py:78-87, 157-162`) stores the clean text as `content` and the wire bytes as the `api_content` sidecar. **That is exactly what tui_gateway's surface note produces,** so we get desktop parity.

**Options:**

| | Persisted `content` (transcript, titles, search, `session/load` replay) | Model sees note + context | Cost |
|---|---|---|---|
| **A. Embedded resource block** (recommended) | spoken words only | yes (+ an "[Attached file: …]" header) | Hermes doesn't advertise `promptCapabilities.embeddedContext` (`server.py:517`, only `image=True`), so we rely on tolerant parsing; pin it with a tag-cited test. `text_only_prompt` becomes false, so while busy the prompt is **queued as `user_text` only and loses the note** (`server.py:696-715`); Scarf must cancel and await the turn's return before submitting. |
| B. Prefix note in the text | note + transcript context persisted in state.db, visible in the transcript, auto-title and search | yes | pollutes history permanently, and context grows with every replay |
| C. No note | clean | no; replies come back with markdown/lists and lose "Thursday, not Friday" context | voice paraphrases anyway; lower quality |

**Recommendation: A.** C is the fallback if a future Hermes drops embedded-resource text. The note text is Hermes's own `VOICE_LIVE_TURN_NOTE`. Scarf has no API to fetch it, so it has to be vendored as a string with a `voice_live.py:73-81 @ v2026.9.14` citation and refreshed in each Hermes release audit. The ACP handoff:
1. `ACPClient.sendPrompt(sessionId:text:images:contextNotes:)`, where notes become resource blocks **before** the text block.
2. Completion is the return of `sendPrompt` (see memory "ACP turn completion is sendPrompt's return…").
3. Reply text comes from the turn's streaming assistant message in `RichChatViewModel` (`messages` + `isAgentWorking`); tool progress comes from `liveActivityStatus == .runningTool(name)` (`RichChatViewModel.swift:2246-2262`).
4. Supersede: `ACPClient.cancel`, then await the in-flight `acpPromptTask`, then submit.

## 5. Capability gating and probing

Show the Live Voice entry point only when **all** of these hold:
1. `HermesCapabilities.hasGPTLiveVoice`, new in the **v0.21.3 MARK cluster** (`isV0213OrLater`). `tools/voice_live.py` first ships in tag `v2026.9.14` (commit `f923faa0b8`, absent from `v2026.9.11`), and `pyproject.toml` at the tag reads `0.21.3`.
2. The status probe says `ok && mode == "gpt-live"`.
3. `available == true`.

**Probe:** the same host script with `{"op":"status"}`. Measured locally at about 0.3 s, no network, never returns the key. Run it off-main (C10, 20 s timeout) when a chat window's capabilities load. Cache it per server + HERMES_HOME. Invalidate it when the existing config watcher sees `config.yaml` / `.env` change, and re-run it on button press before spending anything.

**Dev-build caveat:** Alan's local install reports `0.21.2` but already contains `voice_live.py`, so the version floor hides the feature there even though the probe would pass. Keep both checks (C1 wants the flag), and test with a real v0.21.3 host.

### Hosts with no key, or mode `chained` (Alan's addendum)

| Host state | Entry point | Behaviour |
|---|---|---|
| Hermes < 0.21.3, or probe `unsupported` | **hidden** | C1: renders byte-identical to the prior release. |
| mode `chained` (the default, `config_defaults.py:1132`) | **hidden in the chat composer** (until P7 ships a chained engine; the same button then starts that engine) | Settings › Voice shows a read-only "Live Voice (GPT-Live): off" row with a hint: *set `voice.voice_chat_mode: gpt-live` on the host*. An optional one-click enable can use `hermes config set voice.voice_chat_mode gpt-live` (argv verified at `hermes_cli/subcommands/config.py:24-27`, C5). Scarf only writes that when the user asks. |
| mode `gpt-live`, `available == false` | **shown in a disabled/warning state** | Tapping opens a setup hint (Hermes's own `reason`: "no OpenAI API key (set OPENAI_API_KEY or voice.gpt_live.api_key)") and a cost note ($0.05/min). No session starts and nothing is spent. This mirrors the desktop's "not configured" notice (`use-composer-voice.ts:219-235`), minus its silent fallback to chained, which Scarf doesn't have yet. |
| mode `gpt-live`, available | **enabled** | Tapping starts a session (re-probe, then exchange). |

**Keep the free/chained path open for P7.** The desktop mounts either engine behind one shape ("same public shape as `useVoiceConversation`", `use-voice-live-conversation.ts:70-77`), and Scarf should do the same:
- The UI binds to an engine-agnostic `VoiceConversationEngine` (phase, captions, level, mute, end).
- The Hermes side is one `VoiceTurnHost` (submit, cancel, stream reply, activity).
- `GPTLiveEngine` (WebRTC) is the first conformer.
- P7's `ChainedVoiceEngine` (on-device STT from P2 dictation, then an ACP turn, then TTS via `HermesSpeechService` with free providers such as edge/Kokoro) slots in behind the same button and panel with no UI rewrite.
- Nothing in the phase model, panel or turn host may assume WebRTC or a key.

## 6. What to reuse

**From pr-143 (@danmarauda; credit in the commit trailers / file headers):**
- `VoiceLivePhase` + `VoiceLivePhaseReducer` (pure `(phase, event) → phase`) and `RealtimeVoicePhaseTests`. Reuse after adapting the events: add `thinking` (delegation in flight), and replace the audio-item events with `speakingChanged`/`delegation`/`started`/`closed(reason, usage)`.
- The `RealtimeTokenMintScript` style: a pure, unit-tested script builder, quoted heredoc, JSON-literal embedding, exit-code contract, and a redacting `description`. Its discovery (`pinokio` path + `python3`) is weaker than HermesSpeechService's, so use the latter.
- The `RealtimeVoiceError` user-facing copy pattern.
- `RealtimeVoiceServiceTests`' scripted-peer idea becomes a fake media bridge.
- **Do not reuse:** `OpenAIRealtimeVoiceService` / `URLSessionRealtimeSocket` / `RealtimeAudioMath` / `VoiceLiveAudioEngine`. That is the rejected direct-to-OpenAI WebSocket + PCM path; WebRTC does the audio.

**From this branch:**
- `HermesSpeechService` (`orchestratorScript` discovery + `payloadJSON` + marker parsing, and its `HermesSpeechServiceTests` fake transport, `:94`).
- The `voice.*` config keys already in `HermesConfig` (P2 commit `ce65afe1`).
- iOS `PushToTalkController` / `OnDeviceDictation`: the permission-flow pattern for P5b and the STT half of P7's chained engine. **Must be stopped** before a live session opens the mic.
- `MessageSpeechService`: must be muted during live sessions.
- `scarf/Spikes/VoiceLive/voice_live_host.py` becomes P4's Python body verbatim. `voice-live-bridge.html` is a line-cited port of `voice-live.ts` with the Swift bridge; it has not run against the vendor, so review it.

---

## Risks
1. **Never run against OpenAI.** Unknowns: acceptance of WebKit's offer, ICE through mDNS host candidates, `session.started` timing, and whether `usage` shows up. P4 must include a gated manual smoke test (≤2 min on a keyed host), and check that `session.closed` arrives on every exit path.
2. **Billing leaks.** $0.05/min while the session is open (`voice_live.py:18-20`). Close on end, window close, session switch, server switch, app quit, iOS background, and web-content-process termination (`webViewWebContentProcessDidTerminate`). Put a hard ceiling in the UI (the vendor caps around 30 min per pr-143's notes; unverified).
3. **Embedded-resource tolerance** is undocumented Hermes behaviour (Hermes doesn't advertise `embeddedContext`). Pin it with a tag-cited test and re-check in each release audit.
4. **Busy-queue note loss** (`server.py:696-715`): the supersede path must cancel and await before sending.
5. **iOS real-device audio:** session category handoff with TTS/dictation, AEC on speaker, Bluetooth/AirPods routes. P5b needs device testing.
6. **macOS TCC is per bundle.** Scarf Dev and Release each prompt once. Not exercised here; to test on this Mac, run `SPIKE_MIC=1 scarf/Spikes/VoiceLive/run_macos.sh` (it raises the prompt for the spike bundle).
7. **The vendored turn-note text drifts** from Hermes's. Refresh it per release audit.

---

## Build plan: three agents in parallel after P4's protocols land

### P4: shared core (ScarfCore). Blocks P5a/P5b only on the protocol files; land those first.
- `ScarfCore/VoiceLive/VoiceLiveHostExchange.swift`
  - Pure script builder (`static func script(op:hermesBinary:hermesHome:request:)`) + Python body constant.
  - `status(context:)` / `createSession(offerSDP:history:)` over `ServerTransport.streamScript`, with timeouts of 20 s / 45 s.
  - Last-marker parser.
  - `VoiceLiveHostError` (`unsupported`, `noKey(reason)`, `vendor(status:detail:)`, `network`, `badRequest`, `transport`, `malformedOutput`), with a redacting description.
- `ScarfCore/VoiceLive/VoiceLiveStatusStore.swift`: `@Observable` per-server cache of the status probe (off-main, invalidated by the config watcher), plus `VoiceLiveAvailability` (`.hidden` / `.needsSetup(reason)` / `.ready`) computed from caps + probe. The UI reads only this.
- `ScarfCore/VoiceLive/VoiceConversationEngine.swift` (**protocols first**):
  - `VoiceConversationEngine` (phase, captions, level, muted, `start()`, `end()`, `toggleMute()`).
  - `VoiceTurnHost` (`submitVoiceTurn(prompt:context:) async throws`, `cancelActiveTurn() async`, `isTurnBusy`, `unspokenTurnText()`, `activeToolName`, `seedTurns`).
  - `VoiceMediaBridge` (start(history), applyAnswer, failStart, think, speak, instruct, setMuted, close, `events: AsyncStream<VoiceMediaEvent>`).
- `ScarfCore/VoiceLive/VoiceConversationPhase.swift`: adapted pr-143 reducer, credited.
- `ScarfCore/VoiceLive/VoiceLiveText.swift`: ports of `delegationPrompt`, `chunkForCommentary`, `toLiveHistory`, `isVoiceStopCommand`, and a minimal `sanitizeTextForSpeech`, each cited to the tag.
- `ScarfCore/VoiceLive/GPTLiveEngine.swift`: `@MainActor @Observable` conformer implementing §3's turn loop (driven by observation or a 200 ms tick, with the 15 s grace, supersede → cancel+await, stop phrases).
- `ScarfCore/VoiceLive/WebViewVoiceMediaBridge.swift` (`#if canImport(WebKit)`; shared by both apps):
  - Owns the `WKWebView`.
  - `scarf-voice` `WKURLSchemeHandler` serving the page from a Swift string constant.
  - `WKScriptMessageHandler` decoding.
  - `callAsyncJavaScript` with arguments (never interpolation).
  - Media-capture delegate granting only its own origin/mic.
  - The configuration flags from §2.
  - A `view` for the platforms to embed.
- `ScarfCore/VoiceLive/VoiceLivePage.swift`: the page (from `voice-live-bridge.html`).
- `ScarfCore/ACP/ACPClient.swift`: `contextNotes:` overload → resource blocks before text.
- `ScarfCore/VoiceLive/VoiceLiveTurnNote.swift`: vendored `VOICE_LIVE_TURN_NOTE` + context formatting.
- `ScarfCore/Services/HermesCapabilities.swift`: `// MARK: v0.21.3 (v2026.9.14) flags`, `isV0213OrLater`, `hasGPTLiveVoice`.
- **Tests** (ScarfCoreTests):
  - Script builder: no `'` in the body; quoting of home/binary; size cap with a 6,000-char history.
  - Marker parse and error mapping, including redaction.
  - Bridge message decoding.
  - Text-port parity with `use-voice-live-conversation.test.ts` cases.
  - `GPTLiveEngine` with a fake bridge + fake turn host: delegation → submit with note; streamed reply → chunked speak; settle-without-reply → think; supersede → cancel-then-submit ordering; stop phrase ends; closed → phase ended/failed.
  - Capabilities cluster (parse, all-on, degradation, patch-still-on).
  - Contract test pinning the embedded-resource wire JSON.

### P5a: macOS UI (after P4's protocol files)
- `scarf/scarf/Features/VoiceLive/VoiceLiveButton.swift`: composer button in `RichChatInputBar`, driven by `VoiceLiveAvailability` (hidden / warning with setup popover / ready).
- `scarf/scarf/Features/VoiceLive/VoiceLivePanel.swift`: status orb, captions, mute, end, elapsed time + cost hint. Embeds the bridge's web view as `NSViewRepresentable`, 1×1 at alpha 0, **in the hierarchy**.
- `scarf/scarf/Features/Chat/ViewModels/ChatViewModel+VoiceTurnHost.swift`: conformance.
  - Submit goes through the existing `sendViaACP` path with `inputMode: .voiceLive` + `contextNotes`, so the bubble shows only the spoken text.
  - Cancel uses `stopACP` and awaits `acpPromptTask`.
  - Reply text / tool name come from `RichChatViewModel`.
- Teardown hooks: window close, session/server switch, app terminate. Mute `MessageSpeechService` auto-speak while live.
- Settings › Voice: Live Voice status row + hint (optional enable via `hermes config set`).

### P5b: iOS UI, ScarfGo (after P4's protocol files)
- `scarf/Scarf iOS/Chat/VoiceLiveButton.swift` + `VoiceLiveSheet.swift` (or a composer overlay). Hosts the web view as `UIViewRepresentable` in the hierarchy.
- `scarf/Scarf iOS/Chat/ChatController+VoiceTurnHost.swift`: conformance on the `ChatView.swift` send pipeline (`:1778`, `:1933`).
- Audio coordination: stop `PushToTalkController` + TTS before start, restore after `closed`. `scenePhase != .active` → `end()`.
- Real-device test checklist: AEC on speaker, AirPods, interruption (phone call), lock screen.

### P7 (later, not designed out)
`ChainedVoiceEngine: VoiceConversationEngine` reusing `VoiceTurnHost`, the panel/button, P2 dictation (STT) and `HermesSpeechService` (TTS). `VoiceLiveAvailability` gains `.chainedReady` when mode is `chained`.

## Open questions for Alan
1. **Gate:** is a version flag (≥0.21.3) plus the probe right, given your own dev install reports 0.21.2 while carrying voice_live? Or should the probe's `supported` be enough (C1 "detection")?
2. **Turn note:** OK to vendor `VOICE_LIVE_TURN_NOTE` and send it as an ACP embedded resource (undocumented tolerance, desktop-parity persistence)? Or would you rather ask upstream for an ACP `_meta.hermes.surface` first?
3. **Chained hosts:** hide the composer button (recommended) or show it with a "switch to Live" setup hint? And should Settings offer a one-click `hermes config set voice.voice_chat_mode gpt-live`?
4. **Budget:** a hard session ceiling or a visible running cost in the panel?
5. **Live smoke test:** who provides a keyed host for the first ≤2-minute run, and on which Mac/iPhone?
