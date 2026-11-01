# Scarf v3.8.0

**Chats keep running when you click away.** Until now, clicking into another chat stopped the one you left. In 3.8.0 a Scarf window keeps several chats live at once, so you can start a long job in one chat, work in another, and come back to the finished answer.

## Parallel chats

Each chat now has its own connection to Hermes. Switching chats no longer interrupts anything:

- **Replies keep going in the background.** Each chat keeps its own transcript, and its own half-typed message.
- **The sidebar shows what each chat is doing:** needs an answer, error, replying, or finished and not yet read.
- **Approvals don't get lost.** A chat that needs your approval while in the background says so in its row, and sends a notification if your Notify setting is on. Click the notification to go straight to that chat.
- **A limit keeps your hosts healthy.** Each server keeps up to 4 chats live over SSH, or 8 on your own Mac. When you open one more, Scarf quietly releases the oldest idle chat, which picks up where it left off when you return to it. If every chat is busy, Scarf asks which one to stop, or you can wait.

## Scarf asks before stopping your work

Closing a window, quitting, or switching profile now asks first when a chat is still working, and says what would stop. Wizard and Upgrade Project prompts that are waiting to start are named too, so they don't vanish silently.

## Prompts are harder to lose

- **A chat's prompts reach Hermes in the order you sent them.** Prompts sent in quick succession could previously overtake each other.
- **A failed start no longer swallows your message.** If a chat can't connect, what you typed comes back to you, or Scarf tells you it couldn't be sent. Wizard and Upgrade Project prompts wait with an Open Now or Discard choice.
- **Gateway failures show Hermes's own explanation.** If a gateway dies mid-turn, Hermes can't say whether the turn finished, so Scarf shows Hermes's message and never resends it. If that leaves a lost turn blocking the session, a **Discard Lost Turn** button clears it (on ScarfGo, a hint explains what to do).

## Smaller fixes

- Deleting a chat that's still replying now works on Hermes v0.22.5, which refuses to delete a session with a turn running. Scarf stops the turn first, then deletes it, and says "session deleted" only once Hermes confirms. This also applies to the Sessions tab.
- If Hermes refuses to delete a session, Scarf shows Hermes's reason instead of an exit code.
- ScarfGo asks before you switch away from a chat that's still replying, since parallel chats aren't on iOS yet.
- A message sent while a chat is still starting now waits and goes out when the chat is ready, instead of failing with "No session ID". If the start fails, your text comes back to the composer.
- SSH recovery no longer closes a healthy connection during a network blip or just after waking, which could drop every chat on that server.
- Approval cards ignore number keys for a moment after they appear, so a digit you were typing can't approve something you haven't read. "Needs your answer" notifications no longer show the command itself.
- If Scarf can't confirm the approval mode you picked after a chat reconnects, it stops sending prompts and says so, rather than carrying on with looser approvals.

## Under the hood

- Chat is rebuilt around a per-chat session object, with one window holding many.
- New live UI tests run against real Hermes on v0.22.5 and v0.21.5, and over a real SSH server: chats replying at once, background approvals, deleting a working chat, closing with chats running, and a real SSH connection at the chat limit.

## Known issue

In rare cases during our automated testing, a Scarf window froze after clicking New or Wait, and had to be force quit. We traced it to the chat list switching its scrollbar on and off without end, on Macs set to always show scrollbars, and this release includes a fix. We haven't seen the freeze since, but it was rare enough that we can't promise it's gone. If it happens to you, please open an issue on GitHub.

## Upgrade notes

- Updates arrive via Sparkle's built-in updater; or grab the zip from this release.
- macOS 15.0+ (Apple Silicon and Intel). ScarfGo gets its confirm and lost-turn hint in its next App Store and TestFlight build.
- Compatible with Hermes v0.6.0 through v0.22.5. Parallel chats need no particular Hermes version. Each live chat runs its own `hermes acp` process on the host, so a host with several chats open runs several processes.
