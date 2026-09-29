# DRAFT GitHub replies (not posted; Alan approves each)

## #140 — CPU pegged during chat (then close)
Thanks for retesting. 50–75% while drag-scrolling a very long history and staying smooth is what I'd expect, so I'm closing this. If the typing slowdown or the 100% CPU ever comes back, reopen it with a fresh performance capture and I'll take another look.

## #141 — sqlite3 not found (ask, then close)
The clearer message shipped in v3.4.0: when the host has no `sqlite3`, ScarfGo now says so and gives the install command instead of "Connection issue". Once you're on the current ScarfGo build, could you confirm you see that message, or no message at all after installing `sqlite3`? I'll close this after that.

## #145 — branch / fork
An update for the next release (3.5.0):
- Sessions made with Hermes's `/branch` now show a **Branch** label in the Sessions list, the chat sidebar and ScarfGo. On the Mac, hovering it names the session it came from.
- A **Fork** button still waits on NousResearch/hermes-agent#124540, so a fork made from Scarf is recorded as a branch in Hermes, not a loose copy.

## #146 — resuming a hermes-webui session (DRAFT — confirm against P1's final behaviour before posting)
The fix is in the next release (3.5.0). When you open a session that was started outside Scarf, such as in hermes-webui, Scarf no longer pretends to resume it. The old conversation stays on screen, and a note says Hermes can't reopen that session here, so your next message starts a new session without the earlier context. Sessions started in Scarf still resume normally. If a resume fails for any other reason, Scarf now shows the error instead of quietly starting over.

Thanks for confirming session 3 carried on normally; that ruled out a second bug.

## #147 — /retry and /title
Thanks for the screenshots. These commands are missing because Hermes only offers apps like Scarf a smaller set of commands than its own CLI: help, model, tools, context, reset, compress, steer, queue and version. Anything else typed in chat went to the model as ordinary text.

In the next release (3.5.0):
- **`/title <name>`** works in Scarf chat, on the Mac and in ScarfGo. It renames the chat through Hermes.
- **`/retry` and `/undo`** aren't sent to the model anymore. Scarf tells you to use the Hermes CLI for them. I didn't fake them in Scarf: a proper retry has to remove the last exchange from Hermes's history first, and only Hermes can do that.

I've asked Hermes to make them available to apps: NousResearch/hermes-agent#127870. Once that lands, they'll show up in Scarf's menu.

## #148 — total processing time (feature)
Glad the timer is working for you. In the next release (3.5.0), each reply ends with its total processing time for the prompt, including all tool steps. It also shows when you reopen an older session, worked out from the times Hermes saved.
