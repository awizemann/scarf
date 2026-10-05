# v3.6.0 TestFlight + App Store submission checklist

Incremental ScarfGo build. The one-time setup (privacy URL, App Store Connect record, signing, public group) is done — see [`releases/v2.5.0/TESTFLIGHT_CHECKLIST.md`](../v2.5.0/TESTFLIGHT_CHECKLIST.md) for the full first-time walkthrough. This file is the per-build delta.

This build carries a **security fix** (SSH host-key verification), so it should go to the public App Store, not only TestFlight.

## Pre-flight

- [ ] `./scripts/release.sh 3.6.0` has run. It bumps `MARKETING_VERSION` to **3.6.0** and `CURRENT_PROJECT_VERSION` to **75** for every target, ScarfGo included. Archive ScarfGo from that bump commit; don't hand-edit the versions.
- [ ] `CURRENT_PROJECT_VERSION` (75 after the bump) is greater than the last build uploaded to App Store Connect. If App Store Connect already has 75 or higher, raise it in the `scarf mobile` target before archiving.
- [ ] Release build is warning-free with the archiving Xcode: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project scarf/scarf.xcodeproj -scheme "scarf mobile" -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO clean build` (see the prep plan for the result).
- [ ] ScarfIOS package tests green, including the host-key tests (`HostKeyPinningTests`); optionally `scripts/verify-ios-host-key-pinning.sh` against a real localhost sshd with a swapped key.
- [ ] Capabilities unchanged: Keychain Sharing only; **Push stays OFF** (`NotificationRouter.apnsEnabled = false`).
- [ ] `PrivacyInfo.xcprivacy` unchanged for iOS (no collected data types, UserDefaults CA92.1). ScarfGo still sends no analytics.
- [ ] The gh-pages privacy page is pushed with the host-key and retention wording (see the prep plan: the `.gh-pages-worktree` has an uncommitted `privacy/index.html` change). App Review follows the privacy URL.

## Manual checks on a device

- [ ] **Existing server, first launch after update:** connects normally, with no prompt. System › Server now shows a **Host key** fingerprint.
- [ ] **New server:** onboarding's Test Connection succeeds and the fingerprint is saved.
- [ ] **Changed key:** regenerate the host key on a test server (or point the entry at a different sshd on the same host:port). ScarfGo refuses to connect, the server list row says "Server identity changed. Review it in System.", chat doesn't retry in a loop, and System › Server shows the trusted and presented fingerprints.
- [ ] **Trust New Key:** the confirmation shows the presented fingerprint; after confirming, ScarfGo connects and the new key is trusted. Cancel leaves it refused.
- [ ] **Forget server:** removing the server also drops its saved key; re-adding pins afresh.
- [ ] **Live Voice consent:** on a device that agreed before, starting Live Voice shows the consent sheet again with the new line about Hermes's replies and status lines. Cancel sends nothing; agreeing starts the session. System › Settings › Live Voice Privacy shows the choice.
- [ ] **Contrast, light and dark mode:** primary buttons (light: deeper orange with white text; dark: light orange with dark text), destructive buttons (brick red, white text), swipe actions, status badges and banners, and the chat tool-call colours. Spot-check with Larger Text on (button labels grow, tap targets stay at least 44 pt).
- [ ] **App Review server:** the reviewer test host (see `documents/appstore-review/scarfgo-reviewer-access.md`) still connects. It is pinned on first connect, so nothing changes for the reviewer unless its host key is regenerated.

## Archive + upload

- [ ] Xcode → scheme **`scarf mobile`** → destination **Any iOS Device (arm64)** → Product → **Archive**.
- [ ] Organizer → **Distribute App** → **App Store Connect** → **Upload** (defaults; strip Swift symbols ON).
- [ ] Wait for processing (~5–15 min); App Store Connect emails when the build is ready.

## What to test (paste into TestFlight → What to Test)

```
v3.6.0 — server identity checks, readability, and corrected privacy text.

- Host keys: your existing servers should connect as before, and
  System > Server now shows each server's host key fingerprint. If a
  server's SSH key changes, ScarfGo should refuse to connect and show
  both fingerprints, and Trust New Key should let you accept the new one.
- Readability: check buttons, status badges, banners and destructive
  actions in light and dark mode, including with Larger Text on.
- Live Voice: you'll be asked to agree once more before your next
  session. The screen now says that Hermes's replies and status lines
  also go to OpenAI.

Known limitations: no push notifications.
Report issues via TestFlight feedback.
```

## Submit

- [ ] TestFlight → External Testers → **Public Beta** group → add the new build → **Submit for Review** (Beta Review ~24–48h).
- [ ] On approval, the existing public link `https://testflight.apple.com/join/qCrRpcTz` serves the new build automatically — no new URL.
- [ ] App Store → new version **3.6.0** → paste the per-version copy from [`APP_STORE_METADATA.md`](APP_STORE_METADATA.md) (What's New, Promotional text, updated Description) → select the same build → **Submit for Review**.
- [ ] Review **App Privacy** in App Store Connect per `APP_STORE_METADATA.md` → "App Privacy (nutrition label)".

## Rollback

- [ ] Expire the build in App Store Connect → TestFlight → Builds.
- [ ] Fix, re-archive with a higher `CURRENT_PROJECT_VERSION`, re-upload, re-add to Public Beta.
