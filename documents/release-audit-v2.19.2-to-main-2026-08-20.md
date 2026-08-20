# Release fresh-eyes audit — v2.19.2..main (2026-08-20)

Scope: everything since the v2.19.2 tag after merging feat/hermes-v0204-parity (merge 08bb30e): the parity work (12 commits, previously deep-audited), the 8-commit analytics rollout, Marker 0.9.0 bump, 4 iOS App Store commits. ~10,250 insertions / 137 files. Three independent read-only auditors (analytics, iOS, merge-integration) under a cite-own-evidence rule; all citations spot-checkable. Build green on main; 1334/1335 ScarfCore tests (1 known pre-existing flake, chip filed).

## Verdict
Merge integrity, project-file registration, parity-analytics seams, PII posture, dedupe, and network backoff are all CLEAN. Nine actionable findings — one launch-blocking pair (privacy), one high correctness bug, the rest medium/low.

## Blocking before App Store submission / release cut
1. **Privacy policy contradicts shipped analytics** (wiki/Privacy-Policy.md:41 "No analytics", mirrored to the page linked from iOS Info.plist + App Store Connect; wiki/Support.md:74 repeats it). macOS now ships opt-out analytics on by default to api.swiftstats.co. iOS collects nothing (verified: nil recorder, no Stats link) but the policy covers both apps. Also no README/release-note disclosure. POLICY WORDING = Alan's call.
2. **iOS privacy manifest missing NSPrivacyAccessedAPICategoryFileTimestamp** (Scarf iOS/PrivacyInfo.xcprivacy declares only UserDefaults CA92.1; MetricKitSubscriber.swift:83,148 uses contentModificationDate; ScarfCore SSH/LocalTransport use .modificationDate). ITMS-91053 rejection risk on build 61 upload. Fix: add category with reason C617.1.
3. **ITSAppUsesNonExemptEncryption = YES** (project.pbxproj:539,583) obliges ERN/CCATS docs per submission; standard-crypto SSH client usually takes the exemption. Needs a deliberate decision.

## High
4. **reconnect_succeeded{trigger:wake} inverted** (scarfApp.swift:750-769): `.alive` (no reconnect happened) counted as success; `.recovered` (actual reconnect) not. Wake reconnect metrics ≈ inverse of reality; duration_bucket measures the probe loop.
5. **iOS resume fallback: untyped catch + silent** (Scarf iOS/ChatView.swift:2456-2461): any transient loadSession error silently opens a NEW session while replaying the old transcript — user context/attribution lost, no log, no analytics (Mac path has both, ChatViewModel.swift:1615,1622). Blast radius widened by v0.20.4 listable-children (reset/branch rows now tappable). Fix: catch only the "not restorable" case for fallback, surface/log the rest, add the analytics event.

## Medium
6. **Key import gate too loose** (OnboardingState.swift:99-106): accepts RSA/ECDSA/encrypted ed25519 that the decoder (ed25519-unencrypted-only) can never use; failure surfaces only at connect with the bad key stuck in Keychain; no private/public pair match check.
7. **Ingest write key committed in plaintext** (Analytics.swift:35, sk_stats_…): ships in binary necessarily, but repo presence invites stream pollution; outside the Keychain-for-credentials rule. Decide: rotate-on-abuse posture or move out of repo.

## Low
8. **Analytics accuracy nits**: error-banner Reconnect button records chat_session_started{mode:resume} (ChatView.swift:383→ChatViewModel.swift:837); skill_installed counts manifest entries not actual writes (TemplateInstallerViewModel.swift:271); taxonomy doc drifted in 4 places (documents/analytics/swift-stats-adoption-event-taxonomy.md).
9. **Splash asset** (LaunchView renders 837KB 1024px LaunchLogo at 120pt on cold-start main thread; purpose-built LaunchIcon 120/240/360 unused). Plus hygiene: private-key TextEditor lacks autocorrectionDisabled; pasted PEM never cleared from memory after import (verified never logged/persisted).

## Deferred-to-release-prep (state, not defects)
README/wiki still say target v0.20.0 + "What's New in 2.19.2"; MARKETING_VERSION 2.19.2 unbumped; wiki Hermes-Version-Compatibility has no v0.20.4 row. Handled by scarf-release-prep.

## Clean areas (verified)
Merge byte-identical to branch tip, no divergence window (branch cut from analytics tip). 3-file analytics∩parity overlap all coexist correctly. PBXFileSystemSynchronizedRootGroup covers all new files; all new views reachable. No PII in any traced event prop; ephemeral install-id per session, no userId; manifests accurate for what each app collects. Dedupe lock-guarded process-wide. Backoff/Retry-After/4xx handling sound; record() non-blocking, 10k cap. Marker bump Mac-only. Key material never logged; Scarf-PEM-first decode ordering correct. 059fe50 contains no hacks/TODOs. No connect-flow spinner dead ends.
