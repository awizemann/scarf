# S03b-voice — verdict: WORKS

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Read a message aloud with the system voice (Mac + iOS) | WORKS | none (AVSpeechSynthesizer only, no Hermes touchpoint) |
| 2 | Read a message aloud with Hermes Voice (local): Python discovery, then `text_to_speech_tool(text, output_path=…)`, then envelope, then magic-byte playback | WORKS | none |
| 3 | Same as 2 over SSH (remote $TMPDIR, profile HERMES_HOME, 120 s timeout) | WORKS | none |
| 4 | Hermes Voice failure: no python, tool error envelope, Ogg output. Should fall back to the system voice with a notice | WORKS | none |
| 5 | Live Voice readiness gating (`voice.voice_chat_mode`, v0.21.3 / v0.20.1 floors) and the mode setter | WORKS | none |
| 6 | GPT-Live session exchange on the host (`tools.voice_live.create_webrtc_session`) and its error classes | WORKS | none |
| 7 | Chained voice: on-device STT, then ACP prompt with a turn-note resource, then TTS of the reply. Includes interrupt/cancel | WORKS | none |
| 8 | Voice turns shown as chat bubbles, and iOS Live Voice sheet/consent | WORKS | none |

## Findings
None. Every Hermes contract I traced matches v2026.9.24.

## File coverage
| File | Hermes touchpoints? | Status |
|---|---|---|
| ScarfCore/Services/HermesSpeechService.swift | yes | OK |
| ScarfCore/Services/HermesTTSCache.swift | no (local cache) | NO-TOUCHPOINT |
| ScarfCore/VoiceLive/ChainedVoiceEngine.swift | yes (via host ACP + VoiceSpeaker) | OK |
| ScarfCore/VoiceLive/GPTLiveEngine.swift | yes (exchange + ACP delegation/cancel) | OK |
| ScarfCore/VoiceLive/VoiceConversationEngine.swift | yes (context notes, cancel semantics) | OK |
| ScarfCore/VoiceLive/VoiceConversationPhase.swift | no | NO-TOUCHPOINT |
| ScarfCore/VoiceLive/VoiceDataConsent.swift | no | NO-TOUCHPOINT |
| ScarfCore/VoiceLive/VoiceListener.swift | no (Apple Speech) | NO-TOUCHPOINT |
| ScarfCore/VoiceLive/VoiceLiveHostExchange.swift | yes | OK |
| ScarfCore/VoiceLive/VoiceLiveProtocol.swift | no (WebView bridge messages) | NO-TOUCHPOINT |
| ScarfCore/VoiceLive/VoiceLiveReadiness.swift | yes | OK |
| ScarfCore/VoiceLive/VoiceLiveText.swift | yes (history item shape) | OK |
| ScarfCore/VoiceLive/VoiceLiveTurnNote.swift | yes | OK |
| ScarfCore/VoiceLive/VoiceSpeaker.swift | yes (HermesSpeechService) | OK |
| ScarfCore/VoiceLive/WebViewVoiceMediaBridge.swift | no (WebRTC in WKWebView) | NO-TOUCHPOINT |
| ScarfIOS/Speech/OnDeviceDictation.swift | no | NO-TOUCHPOINT |
| ScarfIOS/Speech/PushToTalkController.swift | no | NO-TOUCHPOINT |
| Scarf iOS/Chat/VoiceLive/ChatController+VoiceTurnHost.swift | yes (ACP prompt/cancel) | OK |
| Scarf iOS/Chat/VoiceLive/VoiceLiveConsentSheet.swift | no | NO-TOUCHPOINT |
| Scarf iOS/Chat/VoiceLive/VoiceLiveSessionModel.swift | yes (voice_chat_mode selection) | OK |
| Scarf iOS/Chat/VoiceLive/VoiceLiveSessionSheet.swift | no | NO-TOUCHPOINT |
| scarf/Core/Services/MessageSpeechService.swift | yes (via HermesSpeechService) | OK |
| scarf/Features/Settings/Views/Tabs/VoiceTab.swift | yes (voice.*, tts.*, stt.* keys via SettingsViewModel) | OK |
| scarf/Features/VoiceLive/VoiceLiveComposerButton.swift | no | NO-TOUCHPOINT |
| scarf/Features/VoiceLive/VoiceLiveConsentSheet.swift | no | NO-TOUCHPOINT |
| scarf/Features/VoiceLive/VoiceLiveController.swift | yes (engine choice, playback pref) | OK |
| scarf/Features/VoiceLive/VoiceLivePanel.swift | no | NO-TOUCHPOINT |
| scarf/Features/VoiceLive/VoiceLivePresentation.swift | no | NO-TOUCHPOINT |

## Touchpoint inventory
| Touchpoint | Kind | Scarf | Hermes @v2026.9.24 | Status |
|---|---|---|---|---|
| `from tools.tts_tool import text_to_speech_tool`; `(text, output_path=)` | python import | HermesSpeechService.swift:551-558 | tools/tts_tool.py:419-421 | OK |
| Envelope `success/file_path/file_paths/provider/chunk_count/error` | JSON | HermesSpeechService.swift:321-358 | tools/tts_tool.py:464-469; tool_error success:false | OK |
| Chunk naming `<stem>.chunkNNN<ext>` | file path | HermesSpeechService.swift:377,432 | tools/tts_tool.py:400 | OK |
| Delivery parts `<stem>.partNN<ext>` | file path | HermesSpeechService.swift:379 | tools/tts_tool_delivery.py:413 | OK |
| Command-provider suffix swap | file path | HermesSpeechService.swift:370-372 | tools/tts_command_provider.py:306 | OK |
| output_path in $TMPDIR not write-denied | path policy | HermesSpeechService.swift:513-523 | tools/tts_tool.py:307-311; agent/file_safety.py:250-285 | OK |
| Intermediate artifacts swept, finals kept | cleanup | HermesSpeechService.swift:301-303 | tools/tts_tool.py:480-484 | OK |
| Synthesis timeout 120 s | timeout | HermesSpeechService.swift:64 | tools/tts_command_provider.py:273 | OK |
| `HERMES_HOME` export for profile | env | HermesSpeechService.swift:525; VoiceLiveHostExchange.swift:178 | load_config via HERMES_HOME | OK |
| Python discovery (shebang / install.sh exec / sibling) | shell | HermesPythonDiscovery.swift:34-119 | scripts/install.sh launcher | OK |
| `import tools.voice_live`; `create_webrtc_session(sdp, history)` | python import | VoiceLiveHostExchange.swift:208-218 | tools/voice_live.py:162-186 | OK |
| No-key ValueError text contains "API key" | error parse | VoiceLiveHostExchange.swift:222 | tools/voice_live.py:172 | OK |
| Vendor RuntimeError `(NNN)` status | error parse | VoiceLiveHostExchange.swift:225-227 | tools/voice_live.py:186 | OK |
| Response `transport.sdp`, `session.id` | JSON | VoiceLiveHostExchange.swift:232-237 | tools/voice_live.py:165 | OK |
| History items `{type:message, role, content:[{type,text}]}` → `session.input` | JSON | VoiceLiveText.swift:23-35 | tools/voice_live.py:157-158 | OK |
| `voice.voice_chat_mode` parse (gpt-live/gptlive/live, `_`→`-`) | config read | VoiceLiveReadiness.swift:29-35 | tools/voice_live.py:107-111; config_defaults.py:1195 | OK |
| `hermes config set voice.voice_chat_mode` | argv/config write | SettingsViewModel.swift:873-875 | config_defaults.py:1195 | OK |
| VOICE_LIVE_TURN_NOTE text and context suffix | prompt text | VoiceLiveTurnNote.swift:17-35 | tools/voice_live.py:73-90 | OK |
| ACP embedded resource → "[Attached file: …]" | ACP | VoiceLiveTurnNote.swift:24,38 | acp_adapter/content.py:116 | OK |
| ACP `session/cancel` for superseded voice turn | ACP | ChatController+VoiceTurnHost.swift:133 | acp_adapter/server.py cancel | OK |
| voice.record_key / max_recording_seconds / silence_duration / auto_tts | config write | SettingsViewModel.swift:862-866 | config_defaults.py:1203-1214 | OK |
| tts.{provider,edge,elevenlabs,openai,neutts,xai.*,deepinfra.*} | config write | SettingsViewModel.swift:877-900 | config_defaults.py:1053-1130 | OK |
| stt.* (local vad/thresholds/idle unload, cloud_trim_silence, …) | config write | SettingsViewModel.swift:901-931 | config_defaults.py:1137-1156 | OK |
| Capability floors hasHermesSpeechSynthesis (0.20.1) / hasGPTLiveVoice (0.21.3) | gate | HermesCapabilities.swift:1189, 2357 | n/a (floors out of scope) | OK |

## Not audited / couldn't verify
- Live runtime behaviour: WebRTC with the OpenAI vendor, and actual audio decode on-device. This is vendor-side and outside the Hermes contract.
- `_build_audio_delivery_files` combining under a no-platform delivery profile was only spot-checked for naming. Its output stays inside the `<stem>.*` derivations Scarf validates.
- SettingsViewModel's `setSetting` argv plumbing belongs to the settings section. I checked only the key names.
