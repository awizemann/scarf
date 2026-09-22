---
title: GPT-Live session exchange runs as a host script, not via the Hermes dashboard
type: note
permalink: scarf/architecture/gpt-live-session-exchange-runs-as-a-host-script-not-via-the
tags: [voice, gpt-live, transport, secrets]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/ServerTransport.swift, scarf/Packages/ScarfIOS/Sources/ScarfIOS/CitadelServerTransport.swift]
source_paths_inferred: false
source_sha: 904c0e60784d0936f39ccbd47242201c12ef23d0
created: 2026-09-18
updated: 2026-09-18
reviewed: 2026-09-22
reviewed_by: audit:claude-code (background)
---

Proven in the P3 spike against the real local Hermes venv with a throwaway HERMES_HOME and a mock vendor endpoint (scarf/Spikes/VoiceLive/voice_live_host.py + run_exchange_tests.sh on feat/voice-spike). No live OpenAI call was made.

## Observations
- [decision] Scarf performs the WebRTC SDP exchange by running tools.voice_live.create_webrtc_session / resolve_gpt_live_status inside the Hermes orchestrator venv over ServerTransport.streamScript (interpreter discovery as HermesSpeechService.synthesisScript does since P2: the hermes binary's own shebang python, falling back to the python beside `readlink -f hermes`; no bare python3 guess), with HERMES_HOME exported for profile scoping — the OpenAI key never leaves the host and no dashboard is needed #voice #transport
- [gotcha] The SDP offer must reach the vendor byte-exact including the trailing CRLF (a stripped offer answers 400); send it as JSON on a quoted heredoc so CR/LF travel as escapes #voice
- [gotcha] create_webrtc_session catches only HTTPError (URLError/timeouts propagate raw), logs the vendor detail at WARNING, and its RuntimeError carries up to 600 chars of vendor body that can echo a masked sk- key — disable logging and redact sk-/Bearer/ek_ before surfacing #voice #secrets
- [convention] Shim prints one SCARF_VOICE_LIVE:{json} marker line (parse the last), kinds unsupported/no_key/vendor(status)/network/bad_request; timeouts 20 s status, 45 s session; never log the offer or answer SDP (ICE pwd + DTLS fingerprints) #voice
- [fact] tools/voice_live.py first ships at tag v2026.9.14 (Hermes 0.21.3, commit f923faa0b8); status probe costs ~0.3 s locally with no network #voice #capabilities

## Shipped in P4 (VoiceLiveHostExchange, feat/voice-p4)

- [decision] There is no `status` op: Alan dropped the host status probe for gating (t-a4665c6e). The gate is hasGPTLiveVoice plus the parsed voice.voice_chat_mode, and a missing key only surfaces when a session starts, as `no_key` before any vendor call #voice
- [convention] Interpreter discovery is shared with Hermes Voice TTS through `HermesPythonDiscovery.shellLines`. It tries the resolved hermes binary's python shebang first, then `python`/`python3` beside the `readlink -f` target. It was extracted byte-identically from `HermesSpeechService` and is pinned by a golden test #voice
- [gotcha] `ValueError` does not always mean "no key". `json.JSONDecodeError`/`UnicodeDecodeError` from a 2xx with an unreadable body (`voice_live.py:182`, raised after the session may already exist) and urllib's "unknown url type" are ValueErrors too. The shim maps a ValueError to `no_key` only when its message contains "API key", otherwise to vendor/internal, so the UI never says "nothing was charged" wrongly #voice #cost
- [gotcha] `python -c` puts the current directory first on `sys.path`. Over SSH that is `$HOME`, where a `~/tools/` package would shadow Hermes's `tools`, so the script runs `cd /` first. `HermesSpeechService` got the same fix in 154459b6, done differently: its Python's first line drops "" and "." from `sys.path`, which keeps the cwd a TTS command provider may rely on #voice #security
- [fact] iOS `CitadelServerTransport.streamScript` writes the script to the exec channel's stdin and runs `PATH=… head -c <N> | /bin/sh` (since commit 5df8d8bd), so the script body never appears in `ps`. It uses `head -c` because Citadel 0.12's `TTYStdinWriter` cannot send EOF. Mac `SSHScriptRunner.runLocally` also sends the script via stdin using `/bin/sh -s` (since commit 834467ab), so scripts also never appear in argv on the user's Mac #voice #secrets

## Relations
- feeds_into [[GPT-Live voice in WKWebView: origin, permission and hosting requirements]]
