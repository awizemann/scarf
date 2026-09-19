---
title: Mac Live Voice (P5a): gate, VoiceTurnHost on ChatViewModel, panel hosting and teardown
type: note
permalink: scarf/architecture/mac-live-voice-p5a-gate-voiceturnhost-on-chatviewmodel
tags: [voice, gpt-live, macos, architecture]
source_paths: [scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift, scarf/scarf/Features/Chat/Views/ChatTranscriptPane.swift, scarf/scarf/scarfApp.swift]
source_paths_inferred: false
source_sha: ad0ae4671d479a80f21bd3a621364348fc3743fd
created: 2026-09-18
updated: 2026-09-18
---

Built in P5a (task t-8c80d256, branch feat/voice-p5a). The twin of the ScarfGo P5b note. Everything binds to the P4 core (VoiceConversationEngine / VoiceTurnHost).

## Observations
- [decision] The composer Live Voice button renders only when ChatViewModel.voiceLiveAvailability(capabilities:) is .ready; voiceChatModeRaw is read off-main in refreshConfigDiagnostics (ChatView .task, so it refreshes when the user returns from Settings) and nil reads as chained, so the entry stays hidden until config is known (C1). Bot Chat's ChatTranscriptPane passes allowsVoiceLive: false because voice turns would bypass the bot send route #voice #capabilities
- [convention] ChatViewModel conforms to VoiceTurnHost in ChatViewModel.swift itself (not a separate file) because it drives the private acpClient / promptTurns / busyTurnOrigins; typed and voice turns share launchPromptTask (voice passes origin: .voice), the bubble is added with no await before hand-off, and cancelActiveVoiceTurn fires session/cancel unawaited then waits (10 s cap) for EVERY in-flight Scarf-started prompt #voice #acp
- [invariant] VoiceLivePanel sits above the composer inside ChatTranscriptPane and hosts VoiceLiveMediaHostView for the whole session; ChatTranscriptPane.onDisappear ends the session, so leaving Chat, switching to terminal mode or closing the window never leaves an unseen billed session #voice #cost
- [gotcha] Teardown hooks: stopACP (every deliberate ACP teardown), startNewSession/resumeSession/continueLastSession before reset(), ContextBoundRoot onDisappear (window close, server/profile switch) and NSApplication.willTerminate (best effort; the close JS may not finish before exit) all call voiceLive.endImmediately(). A DYING connection skips stopACP, so handleConnectionDied calls voiceLive.endForLostConnection() (panel: "connection to Hermes was lost"); no session can start during the reconnect ladder because canHostVoiceTurns needs acpClient #voice #lifecycle
- [convention] User-facing copy lives in VoiceLivePresentation (String(localized:) per VoiceSessionFailure case, setup guidance for every setupHint case, idle/stop-phrase end lines); ScarfCore englishDescription strings are never shown #voice #i18n

## F2a lifecycle and turn rules (t-dd450d3a, branch feat/voice-f2a)

- [decision] One Live Voice session app-wide: VoiceLiveSessionRegistry.shared (weak holder) REFUSES a start in a second window while another window's session is starting or running, rather than ending it (ScarfGo also refuses a start while something else holds the mic; ending would cut off a conversation and its Hermes turn in a window the user isn't looking at). The composer and Start Again say "running in another Scarf window". Tests inject a fresh registry per controller #voice #cost
- [invariant] VoiceLiveController.isStartPending covers the gap before the start task runs (engine still .idle): holdsSession counts it, and end/endImmediately in that gap cancel the task and drop the never-started session #voice #lifecycle
- [invariant] ChatViewModel tracks every session/prompt it starts in promptTurns keyed by a per-turn token (origin .typed/.voice); each turn settles only its own entry, and acpStatus/promptComplete/notification move only when no OTHER interruptive turn is in flight. Reason: Hermes answers a prompt sent mid-turn at once ("Queued for the next turn", acp_adapter/server.py:696-715) and runs it inside the running turn's _finish_turn (:927-938), so the OLDER sendPrompt returns last #acp #voice
- [decision] Voice cancels only voice turns. busyTurnOrigins accumulates origins until every interruptive turn returns; isVoiceTurnBusy is false once anything typed is in the run, and submitVoiceTurn then sends nothing, returns normally, and voiceTurnReply answers ChatViewModel.voiceBusyReply (the voice speaks it; a composer hint explains). Returning rather than throwing is deliberate: a throw makes the engine say "could not reach Hermes" #voice #acp
- [done] The message speaker button stands down while any Live Voice session holds the speaker (SpeakMessageButtonState) and shows Hermes Voice's loading state; VoiceLivePanel posts VoiceOver announcements from VoiceLivePresentation.announcement (not speaking/listening flips) #voice #a11y



## F4 consent and copy (t-ba3ccc85)

- [convention] The consent sheet (`VoiceLiveConsentSheet` + pure `VoiceLiveConsentCopy`, scarf/Features/VoiceLive/) is presented by ChatTranscriptPane from `voiceLive.pendingConsent`; Settings › Voice › Live Voice has a Privacy Consent row (`LabeledSettingsRow`) with Review… (the same sheet, `.review` mode) and Reset. `endImmediately` drops a pending consent. The failure footer shows message + guidance only, never vendor detail #voice #privacy



## Relations
- relates_to [[Live Voice core (ScarfCore/VoiceLive): the engine-agnostic surface both apps bind to]]
- relates_to [[ScarfGo Live Voice (P5b): gate, mic exclusivity, teardown and the shared prompt path]]
- relates_to [[ACP turn completion is sendPrompt's return, not a stream .promptComplete event]]
