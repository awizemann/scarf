---
id: t-e56c8a9b
title: Analytics P4: chat, session & Hermes events
status: done
added: 2026-08-20
---

## Description

Instrument per taxonomy doc §Sessions/§Hermes: chat_session_started (mode new/resume/continue_last; ChatViewModel.startNewSession/resumeSession/continueLastSession), session_resume_fallback (RichChatViewModel fallback paths — injectable recorder, ScarfCore must not depend on Stats), message_sent (has_attachment, input_mode; never content/length), agent_turn_completed/failed (duration_bucket, tool_call_count_bucket / error_kind), permission_prompt_responded (ChatViewModel.respondToPermission), model_preflight_result, hermes_version_detected + hermes_probe_failed (HermesCapabilitiesStore refresh outcomes), hermes_control_action (MenuBarMenu start/stop/restart). Acceptance: build + unit tests with InMemorySink; fresh-eye audit.

## Plan



## Artifacts



