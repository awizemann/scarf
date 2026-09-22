# Scarf v3.3.0

This release gives Scarf a voice. You can dictate into the ScarfGo composer, have assistant replies read aloud through the connected server's own text-to-speech provider, and hold a full two-way spoken conversation with Hermes on the Mac and on your iPhone. The conversation mode follows the host's own Hermes voice setting: the default *chained* mode is free and keeps your voice on the device, and the *GPT-Live* mode uses OpenAI's real-time voice model when the host is configured for it. Every real request still goes to Hermes as a normal chat turn, answered by your model with your full toolset. Alongside voice, the sessions list stops claiming a free session cost "$0.00" when Hermes never priced it, the chat window's Kanban badge stops leaking counts between chats, closing a chat window now really stops the agent process behind it, and ScarfGo reassembles multi-byte text correctly across SSH packets.

Thanks to [@danmarauda](https://github.com/danmarauda), whose pull request [#143](https://github.com/awizemann/scarf/pull/143) contributed the GPT-Live voice chat, Hermes-provider playback, and iOS push-to-talk work this release builds on.

## Voice conversation (Mac and ScarfGo)

A waveform button next to Send starts a spoken conversation with Hermes; the same button lives in the ScarfGo composer. Which engine runs follows the host's `voice.voice_chat_mode`, the same setting Hermes's own apps use:

- **Chained (Hermes's default, free).** Your speech becomes text on your Mac or iPhone using Apple's on-device recognizer, and Scarf refuses to run when your language has no on-device model rather than falling back to Apple's servers. The words go to Hermes like a typed message. The reply is read aloud by the host's text-to-speech provider (Hermes Voice) or by the system voice, whichever the Mac's Playback Engine setting says. No key, no consent sheet, nothing sent to a third party by Scarf. Needs Hermes v0.20.1 or later. Say "stop" or "goodbye" to end.
- **GPT-Live.** An OpenAI voice model listens and speaks in real time and hands every request to Hermes. Needs Hermes v0.21.3 or later, Settings → Voice → Mode set to GPT-Live, and an OpenAI key on the host; the key never leaves the host. Your voice streams directly from your device to OpenAI, so both apps show a one-time consent before the first session that says exactly what leaves the device, and Cancel starts nothing and bills nothing. The panel shows elapsed time and an approximate running cost (about $0.05 per minute, billed to the host's key). A silent session ends itself after about three minutes; closing the window, switching sessions or servers, or quitting ends it immediately, so nothing keeps billing unattended.

Both modes share the same rules: one voice session app-wide, a spoken request never cancels a typed turn that is already running (the voice tells you Hermes is busy, and the composer hint says why), and the session ends when the Hermes connection dies. Live Voice stays out of Bot Chat.

The chained listener went through a real-room shakedown before shipping. Measured with the Mac's built-in speaker, Hermes's spoken reply reads at the microphone as loud as a person, so the first build heard its own reply, transcribed the first word, and sent it back to Hermes in a loop. The listener now runs Apple's voice-processing input chain for echo cancellation, needs a sustained onset rather than one loud tick to barge in, never emits a transcript heard during playback without a confirmed onset, and waits for a quiet microphone before it decides you have finished speaking.

## Hermes Voice playback (Mac)

Settings → Voice → Playback Engine → **Hermes Voice** speaks assistant replies through the connected server's own configured text-to-speech provider, falling back to the system voice. It runs Hermes's own TTS path on the message's own server, accepts MP3, FLAC and AIFF by their actual bytes rather than by extension, and no longer lets a `~/tools` package on the host shadow Hermes's module. Needs Hermes v0.20.1 or later; older hosts keep the system voice.

## Dictation (ScarfGo)

Hold the composer's mic button to dictate. Recognition is on-device only, never a server fallback, and the app tells you when your language has no on-device model instead of sending audio anywhere. The final audit closed two ways a take could stick: a quick tap or a VoiceOver double-tap used to start a recording that never ended, because the gesture fired at touch-down before the long press succeeded; and a hung recognizer left the composer stuck in "transcribing" with both dictation and voice disabled. Both are bounded now, and the dictation action is accessible to VoiceOver with a Settings deep link when permission was refused.

## Costs that tell the truth

Hermes stores an *unknown* cost as the placeholder `0.0`, the same number as a genuinely free session, and marks the difference only in `cost_status`. Scarf read the column and then ignored it, so every session on a free-tier model showed a confident "$0.00" where Hermes had said "n/a". One shared rule now decides the presentation: an unknown cost shows the same dash the list already uses for a missing model, with a "cost unknown" VoiceOver label; a subscription-included price shows a genuine zero without the "est." marker; a positive amount always shows. A session that never completed a priced turn on a current host is read as unknown too, not "$0.00", by probing for the column rather than trusting a NULL. A NaN or negative amount is dropped instead of rendered in a currency label. The Dashboard's per-model breakdown is now headed "By model · all time", because that is what the query has always reported; it sat under "Last 7 days" and read as part of it.

## Chat windows that clean up after themselves

- **Closing a chat window stops the agent.** Closing a window, or switching server or profile, dismissed the voice session and nothing else, leaving `hermes acp` running, holding its SSH channel and, on a wedged host, retrying a reconnect into nothing. The window's teardown now stops ACP, ends any voice session, and cancels the reconnect ladder.
- **Config reads off the main actor.** The synchronous config read at the head of every session start and resume, every model-preset switch, and the voice toggle ran on the main actor, an SSH round-trip on a remote host. All three now run off-main, bounded by the existing watchdog.
- **The Kanban badge belongs to one chat.** The chat header's live Kanban count never reset, so switching chats left the previous chat's number on screen, and a poll issued for one chat could land on the next up to twenty seconds later. The badge now clears on every session change, drops results stamped for a chat that is no longer bound, counts the Review column, and pauses when the window is in the background instead of spawning `hermes kanban list` every five seconds forever.
- **Composer accessibility.** The text area now has a name for VoiceOver and Voice Control, IME composition no longer sends a half-typed message, and the image attachment cap is enforced where the images are added.

## ScarfGo

- **Text arrives whole over SSH.** Every command's output was decoded one SSH packet at a time, and a multi-byte character that straddled two packets (CJK text, an emoji, any long message) came back as two replacement characters with no error anywhere. Output is now accumulated as bytes and decoded once.
- **Host scripts on standard input.** Every host script ScarfGo runs, and every local script Scarf runs on the Mac, now goes to the shell on standard input rather than in the command line, so a Live Voice offer or a TTS text never appears in `ps` on the host. One consequence is documented on the wiki: a login shell whose rc file reads from stdin (a "press Enter to continue" gate) will eat the script and time out; the fix is to guard that line for interactive shells only.
- Live Voice never cancels a typed turn on iOS either, matching the Mac.
- The iOS build rides the next TestFlight and App Store release.

## Under the hood

- ScarfCore holds about 3,700 tests and the Mac app target about 1,500, including on-screen UI tests for the unknown-cost dash and the Kanban badge lifecycle, chained-engine tests that swap only the seam they test, and source sweeps that keep force-try and fixed sleeps out of the voice tests.
- Tests never touch the real login Keychain; the test seam mints its own.
- The UI release gate distinguishes a wedged test runner (RUNNER-FAILED) from a genuine test failure, so a run that executed nothing no longer sends anyone hunting for a broken assertion.
- The voice strings are translated into all six supported languages; the privacy policy gained a voice section, the Mac microphone usage text, and the analytics install id.

## Upgrade notes

- Updates arrive via Sparkle's built-in updater; or grab the zip from this release.
- macOS 14.6+ (Apple Silicon and Intel). ScarfGo for iOS ships separately via TestFlight and the App Store; the iOS changes above ride its next build.
- Compatible with Hermes v0.6.0 through v0.21.3. Hermes Voice playback and chained voice conversation need v0.20.1 or later; GPT-Live needs v0.21.3 or later. Everything newer than your host's version stays hidden; nothing changes on a host you don't upgrade.
- The first voice session asks for Microphone and Speech Recognition permission. GPT-Live additionally shows a one-time privacy consent per device, which you can review or reset in Settings → Voice (Mac) or Settings → Live Voice Privacy (ScarfGo).
