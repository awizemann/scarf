---
title: ScarfGo App Store privacy label stays Data Not Collected
type: note
permalink: scarf/decisions/scarfgo-app-store-privacy-label-stays-data-not-collected
tags: [appstore, privacy, scarfgo]
source_paths: [scarf/Scarf iOS/PrivacyInfo.xcprivacy, scarf/Packages/ScarfCore/Sources/ScarfCore/VoiceLive/VoiceDataConsent.swift, scarf/docs/PRIVACY_POLICY.md]
source_paths_inferred: false
source_sha: 69e9e2b223c365909a2bb3c91debc5fa304fdc65
created: 2026-10-05
updated: 2026-10-05
---

Decided by Alan on 2026-10-05 during 3.6.0 release prep, after the privacy policy was corrected to say what Live Voice sends to OpenAI.

## Observations
- [decision] ScarfGo's App Store privacy label and iOS PrivacyInfo.xcprivacy declare no collected data: by default ScarfGo sends nothing, and Live Voice is off until the user starts it and consents, using the user's own OpenAI key on their Hermes host; the developer receives nothing #appstore #privacy
- [constraint] Keep this true: any new ScarfGo feature that sends data to the developer or a third party by default would invalidate the label, so it must be opt-in and consent-gated or the label changes with it #privacy
- [convention] App Review notes for each ScarfGo release explain the Live Voice path (audio, replies and status lines from the device; recent messages from the host) and why the label stays Data Not Collected; the text lives in releases/v<ver>/APP_STORE_METADATA.md #appstore
- [fact] The iOS manifest declares UserDefaults CA92.1 and File Timestamp C617.1 (MetricKit reports and the TTS cache in the app container) as of 3.6.0 #appstore
