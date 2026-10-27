# v3.7.0 TestFlight + App Store submission checklist

Incremental ScarfGo build. The one-time setup (privacy URL, App Store Connect record, signing, public group) is done — see [`releases/v2.5.0/TESTFLIGHT_CHECKLIST.md`](../v2.5.0/TESTFLIGHT_CHECKLIST.md) for the full first-time walkthrough. This file is the per-build delta.

This build brings ScarfGo's chat up to Hermes v0.22.5 (Hermes's gateway-backed chat from v0.22.3), plus the shared fixes from the Mac 3.7.0 release. No new permissions, capabilities or data collection.

**First, check whether ScarfGo 3.6.0 ever reached the App Store.** Its upload was still open on the task board. If App Store Connect has no 3.6.0 version live, skip 3.6.0 and ship this build instead: it contains everything in 3.6.0, including the SSH host-key security fix. Use the combined What's New in [`APP_STORE_METADATA.md`](APP_STORE_METADATA.md), and also run the 3.6.0 device checks from [`releases/v3.6.0/TESTFLIGHT_CHECKLIST.md`](../v3.6.0/TESTFLIGHT_CHECKLIST.md).

## Pre-flight

- [ ] `./scripts/release.sh 3.7.0` has run (done 2026-10-27). It set `MARKETING_VERSION` to **3.7.0** and `CURRENT_PROJECT_VERSION` to **76** for every target, ScarfGo included. Archive ScarfGo from main at or after the bump commit `e2efdc30`; don't hand-edit the versions.
- [ ] `CURRENT_PROJECT_VERSION` (76) is greater than the last build uploaded to App Store Connect. If App Store Connect already has 76 or higher, raise it in the `scarf mobile` target before archiving.
- [ ] Release build is warning-free with the archiving Xcode (checked during 3.7.0 prep: zero Scarf warnings): `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project scarf/scarf.xcodeproj -scheme "scarf mobile" -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO clean build`.
- [ ] Capabilities unchanged: Keychain Sharing only; **Push stays OFF** (`NotificationRouter.apnsEnabled = false`).
- [ ] `PrivacyInfo.xcprivacy`, `Info.plist` and entitlements are unchanged since 3.6.0 (no diff between the v3.6.0 and v3.7.0 tags). ScarfGo still sends no analytics.

## Manual checks on a device

Use a server running Hermes v0.22.3 or later for the first five, and one on an older Hermes for the last.

- [ ] **Resume a CLI chat:** start a chat in the Hermes CLI or TUI on the server, then open it in ScarfGo. It continues in the same session with its history (no new session in the list).
- [ ] **`/queue`:** send a prompt, then `/queue another prompt` while it runs. The chat stays in the working state until the queued prompt has its answer.
- [ ] **Clarifying question:** ask something that makes Hermes offer choices. It shows as a question card (not "Tool Approval Required"), and Skip declines.
- [ ] **Closing the app mid-reply:** background ScarfGo during a long reply and come back. The reply finished on the server; the connection-lost line doesn't say it stopped.
- [ ] **Duplicate config key:** with a `config.yaml` that has a key twice in one section (Hermes v0.21.6+), Settings shows the error and refuses to save.
- [ ] **Older Hermes (v0.21.5 or earlier):** chat, resume and Settings behave exactly as in 3.6.0.
- [ ] **Sessions list:** chats show where they were created (CLI, TUI, Desktop, ACP) instead of "local".
- [ ] **App Review server:** the reviewer test host (see `documents/appstore-review/scarfgo-reviewer-access.md`) still connects. If you upgrade its Hermes to v0.22.3+, restart its gateway and check a chat works before submitting.

## Archive + upload

- [ ] Xcode → scheme **`scarf mobile`** → destination **Any iOS Device (arm64)** → Product → **Archive**.
- [ ] Organizer → **Distribute App** → **App Store Connect** → **Upload** (defaults; strip Swift symbols ON).
- [ ] Wait for processing (~5–15 min); App Store Connect emails when the build is ready.

## What to test (paste into TestFlight → What to Test)

```
v3.7.0 — chat follows Hermes v0.22.5.

On a server with Hermes v0.22.3 or later:
- Open a chat you started in the Hermes CLI or TUI: it should
  continue in the same session, with its history.
- /queue a prompt while a reply runs: the chat stays busy until
  the queued prompt is answered.
- Questions where Hermes offers choices show as question cards;
  Skip declines.
- Leaving the app mid-reply no longer stops the reply.
- Settings warns about a key written twice in config.yaml and
  won't save it.

On older Hermes versions, everything should work as before.

Known limitations: no push notifications.
Report issues via TestFlight feedback.
```

## Submit

- [ ] TestFlight → External Testers → **Public Beta** group → add the new build → **Submit for Review** (Beta Review ~24–48h).
- [ ] On approval, the existing public link `https://testflight.apple.com/join/qCrRpcTz` serves the new build automatically — no new URL.
- [ ] App Store → new version **3.7.0** → paste the per-version copy from [`APP_STORE_METADATA.md`](APP_STORE_METADATA.md) → select the same build → **Submit for Review**.
- [ ] App Privacy: no change from 3.6.0 (still **Data Not Collected**).

## Rollback

- [ ] Expire the build in App Store Connect → TestFlight → Builds.
- [ ] Fix, re-archive with a higher `CURRENT_PROJECT_VERSION`, re-upload, re-add to Public Beta.
