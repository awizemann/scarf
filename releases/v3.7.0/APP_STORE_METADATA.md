# ScarfGo v3.7.0 — App Store Connect per-version copy

The set-once **App information** is unchanged — [`releases/v2.5.0/APP_STORE_METADATA.md`](../v2.5.0/APP_STORE_METADATA.md) remains the source of truth for those fields. This file carries the per-version fields for v3.7.0. (Verify character counts against Apple's limits before pasting.)

## Promotional text (max 170 chars, editable without resubmission)

```
Ready for Hermes v0.22.5: resume chats started in the Hermes CLI, answer Hermes's questions in place, and keep replies running when you leave the app.
```

## What's New text (max 4000 chars)

Use this one if ScarfGo 3.6.0 is live on the App Store:

```
ScarfGo now follows the new way Hermes runs chat, from Hermes v0.22.3 on.

• Resume chats you started elsewhere. A chat you began in the Hermes CLI or TUI now continues in ScarfGo, with its history, instead of starting fresh.
• Queued prompts work as expected. After /queue, the chat stays busy until the queued prompt has its answer.
• Hermes's questions are question cards. When Hermes asks you to pick an option, it shows as a question, and Skip declines.
• Leaving the app no longer stops a reply. Hermes finishes it on your server.
• Safer settings. Newer Hermes refuses to start if config.yaml has a key written twice. Settings now points this out and won't save such a file.
• Sessions show where each chat was created (CLI, TUI, Desktop or ACP).
• Token usage no longer counts the same tokens twice.

Older Hermes versions keep working exactly as before.
```

If 3.6.0 never reached the App Store, use this combined version instead, so the security fix is announced:

```
A security fix, and ScarfGo now follows the new way Hermes runs chat.

• ScarfGo now verifies your server's identity. It remembers each server's SSH host key the first time it connects (servers you already use are remembered on their next connection, with nothing to set up) and refuses to connect if the key ever changes. System > Server shows the key ScarfGo trusts, and Trust New Key lets you accept a new one after you've checked it.
• Resume chats you started elsewhere. On Hermes v0.22.3 or later, a chat you began in the Hermes CLI or TUI continues in ScarfGo, with its history.
• Queued prompts, Hermes's questions shown as question cards, and replies that keep running when you leave the app, all on Hermes v0.22.3 or later.
• Safer settings: Settings points out a key written twice in config.yaml, which newer Hermes refuses to load, and won't save such a file.
• Easier to read: buttons, status text and warnings meet accessibility contrast standards in light and dark mode, and grow with Larger Text.
• Live Voice will ask once more: the consent screen now also says that Hermes's replies and short status lines go to OpenAI during a session.

Privacy: ScarfGo itself sends no analytics. The full policy is at awizemann.github.io/scarf/privacy.
```

If you use the combined version, also apply the two Description corrections and the App Review note from [`releases/v3.6.0/APP_STORE_METADATA.md`](../v3.6.0/APP_STORE_METADATA.md).

## Description

No change needed for 3.7.0 beyond the 3.6.0 corrections. If the Requirements line still names a Hermes range, update it to "Works with Hermes v0.6.0 through v0.22.5; newer features appear when your server has them."

## App Privacy (nutrition label)

No change: **Data Not Collected**. `PrivacyInfo.xcprivacy`, `Info.plist` and the entitlements are identical between the v3.6.0 and v3.7.0 tags.

## Version

Marketing version **3.7.0**, in lockstep with the macOS release. Build number **76** (`CURRENT_PROJECT_VERSION` after the bump), as long as that's higher than the last build uploaded to App Store Connect.

## Screenshots

No new screens need capturing.
