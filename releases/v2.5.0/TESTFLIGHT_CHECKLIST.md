# v2.5 TestFlight submission checklist

Pre-flight steps to take ScarfGo to public TestFlight. Order matters — Apple review wants the privacy URL to resolve at submission time, and the build needs to upload before review can start.

## 0. Apple Developer Program prerequisites

- Apple Developer Program enrollment active (team `3Q6X2L86C4`).
- iOS Distribution certificate in login Keychain (`Apple Distribution: Alan Wizemann`).
- App Store provisioning profile for the iOS bundle ID (auto-managed in Xcode is fine).
- App Store Connect access for the team.

## 1. Privacy policy live

- [ ] Copy `scarf/docs/PRIVACY_POLICY.md` content into `.gh-pages-worktree/privacy/index.html` (wrap in minimal HTML, or leave as Markdown if GitHub Pages renders Markdown — GitHub Pages with Jekyll does).
- [ ] `cd .gh-pages-worktree && git add privacy/index.html && git commit -m "docs(privacy): publish v2.5 policy" && git push`
- [ ] Verify https://awizemann.github.io/scarf/privacy/ resolves (give it ~1 min after push).

The privacy URL is required by App Store Connect before submitting for Beta App Review. Without it the submission button is disabled.

## 2. Xcode target configuration

Open `scarf/scarf.xcodeproj`, select the `scarf mobile` target.

- [ ] Signing & Capabilities → "Automatically manage signing" ON, team set to `3Q6X2L86C4`.
- [ ] Capabilities present: Keychain Sharing only. **Push Notifications stays OFF** — `NotificationRouter.apnsEnabled = false` and the entitlement is absent. Match the two: enable both later together.
- [ ] Info.plist sanity:
  - Bundle Identifier matches App Store Connect record.
  - `LSApplicationCategoryType = public.app-category.developer-tools`.
  - `NSAppTransportSecurity` allows the SSH ports the app dials? — N/A for SSH (raw TCP); ATS only governs HTTPS. Skip.

## 3. Version bump

The version bump runs automatically via `./scripts/release.sh 2.5.0` in Phase G. Do NOT bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` manually before that — the script writes the version commit and reads `CURRENT_PROJECT_VERSION` to compute the next build number.

## 4. Archive + upload

- [ ] Xcode → Product → Scheme → `scarf mobile`.
- [ ] Destination → "Any iOS Device (arm64)".
- [ ] Product → Archive. Wait for build (~3-5 min).
- [ ] Organizer opens automatically. Select the archive → Distribute App.
- [ ] Distribution method: **App Store Connect**.
- [ ] Destination: **Upload**.
- [ ] Distribution options: leave defaults (manage versioning automatically; include bitcode if offered = N/A on Xcode 14+; strip Swift symbols ON).
- [ ] Re-sign: automatic.
- [ ] Upload. Apple processes the binary (~5-15 min); App Store Connect emails when ready.

## 5. App Store Connect metadata (TestFlight tab)

Once the binary is processed:

- [ ] **App information** (one-time, persists across builds):
  - Subtitle: "On-the-go Hermes companion"
  - Privacy policy URL: https://awizemann.github.io/scarf/privacy/
  - Category: Developer Tools
  - Age rating: 4+ (no restricted content)
- [ ] **Test information** (per-build is fine, persists if not changed):
  - Beta App Description (paragraph): see "Beta description copy" below.
  - Email: alan@wizemann.com
  - Beta App Review information: account credentials only if the app required them — N/A (BYO Hermes host).
  - Marketing URL (optional): https://github.com/awizemann/scarf
- [ ] **What to test** (per-build):
  ```
  v2.5.0 — first public TestFlight build of ScarfGo. Try connecting to a
  Hermes host (you'll need an SSH-reachable Hermes install). Test:
  - Onboarding + Add a second server
  - Project-scoped chat
  - Session resume from Dashboard
  - Sessions tab project filter
  - Forget a server / re-onboard
  Known limitations: no push, no in-app Settings editor, English only.
  Report issues via TestFlight feedback.
  ```

### Beta description copy

> ScarfGo is the iOS companion to Scarf, the Mac client for the Hermes AI agent. Connect to a Hermes server you operate (Mac, Linux, or any SSH-reachable host) and run sessions, browse memory, manage cron jobs, and resume conversations from your phone. All data stays between your device and your Hermes host — no developer servers in between.

## 6. Submit for Beta App Review

- [ ] TestFlight tab → External Testers → Add a public group called "Public Beta".
- [ ] Add the new build to the group.
- [ ] Click **Submit for Review**.
- [ ] Apple's Beta Review queue is typically 24-48h.

## 7. After approval

- [ ] Apple issues a public TestFlight URL (`https://testflight.apple.com/join/XXXXXX`).
- [ ] Record the URL — needed in Phases E (wiki ScarfGo page) and F (README v2.5 section).
- [ ] **DO NOT** publicize it yet. Update wiki + README in branches first; the user (Alan) decides when to push live.

## Rollback

If a build breaks on TestFlight:

- [ ] Disable the build in App Store Connect → TestFlight → Builds → Expire.
- [ ] Fix the bug, archive a new build with the same `MARKETING_VERSION` (Apple requires the build number — `CURRENT_PROJECT_VERSION` — to monotonically increase).
- [ ] Upload + add to Public Beta group + submit if Apple flagged the prior build for re-review.

## Open items / future TestFlight builds

- **Push notifications** — flip `NotificationRouter.apnsEnabled = true` simultaneously with: enabling the Push Notifications capability, generating an APNs auth key, deploying the Hermes-side push sender. Stops being a no-op only when all three exist.
- **iPad support** — `.tabViewStyle(.sidebarAdaptable)` is wired but iPad layout hasn't been smoke-tested. Probably free, but verify before flipping the iPad flag in the target.
- **Localization** — English only for v1. Mac ships 7 languages; iOS strings are extracted but no translations.
