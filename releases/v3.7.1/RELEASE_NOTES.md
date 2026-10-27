# Scarf v3.7.1

A small follow-up to 3.7.0: **`/undo` and `/retry` now work in Scarf's chat on Hermes v0.22.3 and later.** From v0.22.3, Hermes's gateway answers both commands itself, but Scarf still stopped them with a "use the Hermes CLI" note. Scarf now sends them to Hermes and then redraws the chat to match what Hermes kept. Older Hermes versions behave exactly as before.

## `/undo` and `/retry` in chat

On Hermes v0.22.3 and later, typing `/undo` (or `/undo N`) or `/retry` in a chat now does what it does in the Hermes CLI:

- **`/undo`** removes the last turn (or the last N turns) from the conversation. Scarf shows Hermes's reply, such as how many turns it removed or that there was nothing to undo.
- **`/retry`** throws away the last answer and asks the model again. The new answer replaces the old one in the transcript. If Hermes refuses (for example, while another prompt is still running), Scarf shows Hermes's reason instead of doing nothing.

Hermes doesn't delete undone turns; it marks them as no longer part of the conversation. After either command, Scarf rebuilds the transcript from Hermes's own record, so what you see is exactly what the model will see next. A prompt you queued with `/queue` while the command ran keeps its place and its answer.

On Hermes v0.22.1 and earlier, both commands keep showing the "use the Hermes CLI" note, because those versions can't run them over chat.

## Smaller fixes

- If Scarf can't read a chat's history from Hermes (for example, a remote host drops the connection), the transcript now stays as it was instead of going blank. This also applies when Scarf reconnects to a chat.

## Under the hood

- New capability flag for Hermes's chat rewind commands (v0.22.3+), with tests for both sides of the floor.
- New live UI test that runs `/undo` and `/retry` against a real Hermes and checks both the transcript and Hermes's stored conversation. The UI release gate now runs in a Tart virtual machine by default.
- The app's Swift package versions are now pinned in the repository, so a fresh clone builds with the same SwiftTerm and other packages the release was tested with.

## Upgrade notes

- Updates arrive via Sparkle's built-in updater; or grab the zip from this release.
- macOS 15.0+ (Apple Silicon and Intel). ScarfGo (iOS 18.6+) gets `/undo` and `/retry` in its next App Store and TestFlight build.
- Compatible with Hermes v0.6.0 through v0.22.5. `/undo` and `/retry` need Hermes v0.22.3 or later.
