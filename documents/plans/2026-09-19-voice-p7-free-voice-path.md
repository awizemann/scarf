# Voice P7 — a free, Hermes-supported voice path for Scarf

Task t-06481958 · 2026-09-19 · All Hermes citations at tag **v2026.9.14** (0.21.3), read via `git show`.
Scarf citations are working-tree paths.

---

## 1. What "chained" actually is at the tag

`voice.voice_chat_mode` has exactly two values, `chained` (default) and `gpt-live`
(`hermes_cli/config_defaults.py:1126-1132`; `tools/voice_live.py:33-34`). Chained is **not a
server-side conversation engine** — it is a *client loop* that the client drives against three
independent server capabilities (STT, a normal turn, TTS):

- The only chained implementation at the tag is the Hermes **desktop renderer**:
  `apps/desktop/src/app/chat/composer/hooks/use-voice-conversation.ts` (736 lines) — mic recorder →
  transcribe → `onSubmit(text)` → stream reply → `playSpeechText` / `startSpeechStream`, with
  barge-in (`lib/voice-barge-in.ts`), stop words (`lib/voice-stop-word.ts`) and a TTS lease.
  `use-composer-voice.ts:178,214-219` mounts either `useVoiceConversation` (chained) or
  `useVoiceLiveConversation` from the mode, and *falls back to chained* when live can't start.
- The **CLI/TUI** has its own record→STT→turn→TTS loop (`hermes_cli/cli_voice_mixin.py`,
  `hermes_cli/voice.py`), and the **gateways** transcribe inbound voice messages
  (`tools/transcription_tools.transcribe_audio`) and auto-TTS replies. Neither is reusable as a
  service by Scarf.
- The **dashboard/web server** exposes the pieces as REST (`hermes_cli/web_routers/audio.py`):
  `POST /api/audio/transcribe` (`:77`, base64 data-URL in → transcript out, 25 MB cap, routed via
  `tools.voice_mode.transcribe_recording` so silence returns `""` not a 400),
  `POST /api/audio/speak` (`:283`), `POST /api/audio/tts-lease` (`:340`),
  `WS /api/audio/speak-stream` (`:372`), `GET /api/audio/voice-config` (`:140`, client-direct keys),
  `GET /api/audio/voice-live/status` (`:167` → `resolve_gpt_live_status`).

**Is there anything server-side Scarf could call for STT?** Two answers:

| Route | Verdict |
|---|---|
| ACP | **No.** `AudioContentBlock` appears only in the `PromptBlock` union (`acp_adapter/content.py:12,19`); `_content_blocks_to_openai_user_content` (`:249-266`) handles text/image/resource/embedded only — an audio block is silently dropped. No `tools.*` STT function, no `create_webrtc_session` analogue for chained. |
| Host script over `ServerTransport` | **Yes.** Exactly the `HermesSpeechService` pattern: run the server's own interpreter and `from tools.voice_mode import transcribe_recording` (or `tools.transcription_tools.transcribe_audio`) on a file staged on the host. This is Hermes-blessed (the REST route does the same call, `audio.py:112-118`) and needs no gateway HTTP client — Scarf has none for `/api/audio/*` today. |

So: chained STT is client-side in the desktop app, but the transcription *function* is host-side
and script-reachable.

---

## 2. Free / local providers at the tag

**TTS** (`tools/tts_tool.py:100` `DEFAULT_PROVIDER = "edge"`; `:140-145`; registry `:157-180`;
defaults `config_defaults.py:1005-1068`). "Inference credentials never imply consent to paid
speech" (`:140-142`) — the default is free.

| Provider | Key | Default | Cost | Needs on host | Remote headless Linux, no GPU |
|---|---|---|---|---|---|
| `edge` | `tts.provider: edge`, `tts.edge.voice` | `en-US-AriaNeural` | free | `pip install edge-tts` (lazy, `:70`) + **outbound network to Microsoft** | ✅ best default |
| `piper` | `tts.piper.voice` | `en_US-lessac-medium` | free | `pip install piper-tts` (wheels embed espeak-ng); voice `.onnx` downloaded on first use into `~/.hermes/cache/piper-voices/` | ✅ fully offline |
| `kittentts` | `tts.kittentts.model` | `kitten-tts-nano-0.8-int8` (~25 MB) | free | wheel from the KittenML release URL (`:173-176`) | ✅ tiny, CPU |
| `neutts` | `tts.neutts.{model,device}` | `neuphonic/neutts-air-q4-gguf`, `device: cpu` | free | `espeak-ng` + `pip install neutts[all]`, HF model download | ✅ CPU-capable, heaviest |
| kokoro | — | — | — | **not a built-in at the tag** (only docs/plugin mentions) | plugin only |
| openai / elevenlabs / gemini / xai / mistral / minimax / deepinfra | — | — | paid | API key | n/a |

Fallback engine when no provider is installed: edge, else neutts, else an error
(`tts_tool.py:200-211`).

**STT** (`tools/transcription_tools.py:1-9`, `:235-264`; defaults `config_defaults.py:1070-1123`).
`stt.provider` is **deliberately unseeded**; unset ⇒ autodetect ladder
**local → groq → openai → mistral → xai → elevenlabs → deepinfra** (`:237-239, 260-264`), i.e. a
host with no keys already resolves to free local whisper.

| Provider | Key | Default | Cost | Needs on host | Remote headless Linux, no GPU |
|---|---|---|---|---|---|
| `local` (faster-whisper) | `stt.local.{model,language,vad,…}` | `model: base`, VAD on, `unload_after_idle_seconds: 0` | free | `pip install faster-whisper` (lazy-installed, `transcription_local.py:58-68`) + CTranslate2 model download | ✅ `tiny`/`base` are fine on CPU; `small`+ gets slow |
| `local_command` | `HERMES_LOCAL_STT_COMMAND` | — | free | any local whisper CLI | ✅ |
| groq / openai / mistral / xai / elevenlabs / deepinfra | `stt.<p>.model` | see defaults | paid | API key | n/a |

Global `stt.language` defaults to `"en"` (`:1078`). Local providers are marked host-only for
client-direct (`tools/voice_client_config.py:_resolve_stt_client_config`, "local provider" → relay),
which is exactly why Scarf's script-over-transport approach is the right shape for them.

**Bottom line: a Hermes host with zero API keys already has a complete free voice stack —
faster-whisper in, edge-tts out.**

---

## 3. Three candidate `ChainedVoiceEngine` designs

All three conform to `VoiceConversationEngine` (`…/VoiceLive/VoiceConversationEngine.swift:17-56`)
and drive the existing `VoiceTurnHost` (`:157-212`) — no panel/button rewrite (design report §5,
`documents/plans/2026-09-18-live-voice-spike.md:180-186`). None uses `VoiceMediaBridge`/WebKit:
`waitForMediaRelease()` has a default no-op (`:59-62`), `approximateCostUSD` returns 0.

### A. On-device STT → ACP turn → host TTS (`HermesSpeechService`) — *recommended*
- **STT:** Apple `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`, the code already
  shipped for iOS (`ScarfIOS/Speech/OnDeviceDictation.swift:175-202`, availability gate at `:175-176`).
  macOS: `SFSpeechRecognizer` is macOS 10.15+ and `supportsOnDeviceRecognition` is macOS 13+; Scarf's
  Mac target is **macOS 26.2** (`project.pbxproj:809`) so both are available. The Speech code lives in
  `ScarfIOS` whose `Package.swift` already declares macOS for indexing (`:18-25`) — the file needs
  moving to `ScarfCore` (or a new shared `ScarfSpeech`) as part of this work.
- **Turn:** `VoiceTurnHost.submitVoiceTurn` with `VoiceLiveTurnNote` context notes — unchanged.
- **TTS:** `HermesSpeechService` (`ScarfCore/Services/HermesSpeechService.swift`) → host `tts.*`
  provider, already magic-byte-verified and cached (`HermesTTSCache`); fall back to
  `AVSpeechSynthesizer` exactly as `MessageSpeechService` already does (`scarf/Core/Services/MessageSpeechService.swift:10-28`).
- **Free?** Fully, on a keyless host. **Latency:** STT ~0 network (on-device, ends at end-of-speech);
  turn = normal Hermes latency; TTS = one host round trip per sentence/chunk (edge-tts adds a
  Microsoft hop, typically a few hundred ms; piper is local and faster). ~1–2 s to first audio.
- **Privacy:** audio **never leaves the device**. Only transcript text and reply text cross to the
  host; reply text reaches Microsoft if `tts.provider: edge`. That is a genuinely better boundary
  than GPT-Live.
- **Hermes version:** needs only `hasHermesSpeechSynthesis` (v0.20.1+, already gated in
  `HermesSpeechService`'s header). Strictly *lower* than Live Voice's 0.21.3 — C1 gating gets easier.
- **Turn-taking / barge-in:** half-duplex, like the Hermes desktop. Silence-based end-of-utterance
  (mirror `voice.silence_threshold` / `silence_duration`, `config_defaults.py:1152-1153`), stop
  phrases (`voice.stop_phrases`, `:1158-1160`, port of `isVoiceStopCommand` already in `VoiceLiveText`),
  and barge-in = keep the recognizer live during playback and stop TTS on speech onset
  (`voice.barge_in*`, `:1154-1157`). No AEC from WebRTC, so on speaker the mic hears the TTS —
  start with a grace window + headphone-friendly copy, same compromise the desktop makes.
- **Effort:** medium. Engine + phase wiring + moving dictation to shared code + tests. ~1 solid chunk.

### B. Host-side STT via a Hermes tool script
Same as A but STT runs on the host: stage the recorded memo on the server (base64 heredoc through
`ServerTransport.streamScript`, mirroring `HermesSpeechService.orchestratorScript`) and call
`tools.voice_mode.transcribe_recording`.
- **Free?** Yes (faster-whisper). **Latency:** worse — upload of a 16 kHz PCM memo (32 KB/s) over SSH
  plus CPU whisper decode (`base` on CPU ≈ real-time-ish); expect +1–3 s per utterance, plus a
  cold-model penalty on the first turn unless a lease warms it.
- **Privacy:** raw audio leaves the device to the host (not to a vendor, if `stt.provider` is local —
  but if the host has an OpenAI/Groq key the autodetect ladder sends it to a **cloud vendor**, so
  Scarf must read `stt.provider` and warn).
- **Hermes version:** `transcribe_recording` predates 0.21.3; needs a capability flag + a probe.
- **Barge-in:** poor — no partial results while the host decodes.
- **Effort:** high (audio staging, chunking, timeouts, cleanup) for a worse result. Value is narrow:
  devices where on-device STT is unavailable/unauthorized, and non-Apple-supported languages.

### C. Fully on-device (Apple STT + `AVSpeechSynthesizer`)
- **Free?** Yes, and **zero host setup** — works against any Hermes, any host, offline for the voice
  layer. **Latency:** lowest (no TTS round trip). **Privacy:** nothing but the turn text leaves.
- **Downside:** system voice quality vs. edge/piper; no host-configured voice.
- **Hermes version:** none. **Barge-in:** same as A, easier (local playback, instant stop).
- **Effort:** low — it is A minus `HermesSpeechService`. In practice **it is A's fallback leg**, not a
  separate engine: build A with a `TTS: hermes | system` selector and C is the `system` branch.

---

## 4. How Scarf should present it

**Composer button.** Yes — one button, engine chosen by mode. Replace the binary
`VoiceLiveAvailability` (`…/VoiceLive/VoiceLiveReadiness.swift:44-64`) with a three-way verdict:

| Host state | Button | Engine |
|---|---|---|
| `voice_chat_mode: gpt-live` + Hermes ≥ 0.21.3 | shown | `GPTLiveEngine` |
| `chained` (the default) | **shown** (today: `.hidden(.chainedMode)`) | `ChainedVoiceEngine` |
| Hermes too old for both | hidden | — |

This is the Hermes desktop's own behaviour (`use-composer-voice.ts:214-219`), it closes the "many
hosts have no OpenAI key" gap, and it makes the composer button *always* meaningful.
Keep charter C1: the button renders nothing when neither engine is available.

**Settings › Voice** should become one "Voice conversation" section:
- **Mode** picker (Chained / Live), writing `voice.voice_chat_mode` through the existing writer.
- **Live row:** status from `resolve_gpt_live_status` (`tools/voice_live.py`) — mode, `available`,
  `reason` ("no OpenAI API key…"), model, voice — plus the $0.05/min note.
- **Chained rows:** resolved **STT provider** (with "free, on device" when Scarf does the STT, or the
  host's `stt.provider` when it doesn't, and a warning when the autodetect ladder would reach a paid
  cloud provider), and resolved **TTS provider** from `tts.provider` (free badge for
  edge/piper/kittentts/neutts) reusing the existing Playback-Engine picker
  (`HermesSpeechService.PlaybackEngine`: hermes | system).
- **Guidance:** "No OpenAI key needed. Your voice is transcribed on this device; replies are spoken
  by the host's TTS (edge-tts sends reply text to Microsoft) or by the system voice."

---

## 5. Recommendation

**Build design A, with C as its built-in fallback leg, and skip B.** It is free on every host,
needs a *lower* Hermes floor than Live Voice, has a strictly better privacy boundary than GPT-Live,
reuses ~everything already written (dictation, `HermesSpeechService`, the panel, `VoiceTurnHost`),
and makes `chained` — Hermes's default, i.e. most hosts — a first-class Scarf experience instead of a
hidden button. Revisit B only if a real host turns up where on-device STT can't be used.

### Follow-up tasks

1. **Move on-device dictation into shared code (`ScarfCore`)**
   `OnDeviceDictation.swift` / the transcriber half of `PushToTalkController.swift` live in `ScarfIOS`.
   Extract the recognizer + availability check into ScarfCore (or `ScarfSpeech`) so macOS and iOS share
   one STT path; verify `supportsOnDeviceRecognition` on macOS 26 and add the Mac Speech usage string / TCC entry.

2. **`ChainedVoiceEngine: VoiceConversationEngine` in ScarfCore**
   Half-duplex loop: listen → on-device transcript → `submitVoiceTurn` → stream reply → speak in
   sentence chunks. Port Hermes's silence/stop-phrase/barge-in semantics from `voice.*`
   (`config_defaults.py:1146-1160`); reuse `VoiceLiveText` sanitizing and `VoiceTextOnlyTurnLedger`.
   Unit tests with a fake STT + fake turn host, mirroring the `GPTLiveEngine` suite.

3. **Speech output routing for the chained engine**
   Drive `HermesSpeechService` per chunk with `AVSpeechSynthesizer` fallback (the
   `MessageSpeechService` pattern), stop-on-barge-in, and mute `MessageSpeechService` while a voice
   session runs. Decide whether to take a `tts-lease`-equivalent warm-up for local providers.

4. **Three-way `VoiceLiveAvailability` + composer button**
   Replace `.hidden(.chainedMode)` with `.chainedReady`; the one button mounts the engine the mode
   selects. Update `VoiceLiveReadiness` tests and the Mac/iOS button call sites.

5. **Settings › Voice: one voice-conversation section**
   Mode picker, GPT-Live status from `resolve_gpt_live_status`, resolved chained STT/TTS provider
   rows with free/paid badges, and the privacy sentence. Warn when the host's STT autodetect ladder
   would reach a paid cloud provider.

6. **Host free-TTS setup helper (optional)**
   Detect that `tts.provider` resolves to a provider whose package is missing and surface Hermes's own
   remediation strings (`tts_tool.py:157-180`) — e.g. `pip install edge-tts` / `piper-tts` — as a
   copyable hint. No silent installs.

7. **Update the Live Voice design report + memory note**
   Record the P7 decision (A over B), the lower Hermes floor (v0.20.1 `hasHermesSpeechSynthesis` vs
   0.21.3), and the composer-button change, so the next release audit re-checks the chained pieces too.
