# Draft reply — PR #143 (@danmarauda)

Status: DRAFT for Alan to approve. Not posted.

---

Hi @danmarauda — thank you, genuinely. This PR is what got voice onto Scarf's roadmap, and it's a pleasure to review: the code is careful, the commit messages explain *why*, and the test coverage is excellent (93 voice tests, all green here, plus a clean macOS build on current `main`). A few things stood out in particular:

- The ephemeral-token design keeps the OpenAI key on the Hermes host and redacts the token's `description` so it can't leak into a log line or alert. That's exactly the right instinct.
- Passing user text as a JSON heredoc instead of interpolating it into the shell, and checking the audio's magic bytes rather than trusting the provider label, show real attention to the edge cases.
- The perf pass on the live transcript view (splitting the text into settled blocks plus a live tail) is a nice touch most people wouldn't bother with.

**What we're bringing in, with you as the author**

We've landed two of your commits on a `feat/voice` branch with your authorship kept intact, so they'll show under your name when that branch merges to `main`:

1. **ScarfGo push-to-talk dictation** — your commit, as written.
2. **Hermes-provider speech playback for chat replies**: your `HermesSpeechService`, cache, and the System Voice / Hermes Voice picker.

We're adding a few follow-up commits on top of these before the branch merges. None of them are about quality; they come from Scarf's project rules:

- Dictation: when a device can't transcribe on-device, the current code quietly uses Apple's servers, while the permission text says "on this device". We're making it always on-device, with a clear message when that isn't available.
- Speech playback: the shared speech service takes its server from whichever window appeared last, so with two servers open, one window's reply could be spoken by the other server. We're passing each window's own server instead. We're also checking server-reported file paths before deleting anything, putting the "Hermes Voice" option behind a Hermes version check, and removing the kokoro-specific path. Scarf only calls Hermes's own TTS tool, and a local kokoro setup still works there as a command provider.

**Live Voice: a different route, with your work as the starting point**

We're not merging the direct-to-OpenAI Live Voice path. The reason is architectural, not quality: Scarf's rule is that it's a client for Hermes, and that session talks to OpenAI Realtime without Hermes, so none of Hermes's tools or memory are involved and the conversation isn't saved to the chat. Hermes v0.21.3 has since shipped its own GPT-Live mode (`tools/voice_live.py`, `POST /api/audio/voice-live/session`). In that mode the voice model hands every real request to Hermes, which answers with your selected model and full toolset. (The audio itself still streams from the device straight to OpenAI, as in your design; what changes is that Hermes sets up the session and does the real work. Scarf shows a one-time consent that says so before the first session.) We're building Scarf's Live Voice on that route for both macOS and ScarfGo, and your PR is the blueprint we're working from: the phase model, the barge-in handling and the testing approach. You'll be credited in the release notes.

If you'd like to stay involved (and we'd love that), we'd welcome your review on the Live Voice work once it's up, or a follow-up PR from you on top of it. The voice-live route gives you a much more capable backend to play with.

We'll close this PR once `feat/voice` lands on `main` and link the commits here. Thanks again. This was a great first contribution.
