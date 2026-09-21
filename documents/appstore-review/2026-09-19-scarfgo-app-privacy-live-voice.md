# ScarfGo App Privacy for Live Voice — recommendation for Alan (t-11cc53ea)

Date: 2026-09-19. Advisory from the App Store review specialist agent, checked against the code (Info.plist mic string, PrivacyInfo.xcprivacy, PRIVACY_POLICY.md "Voice features").

## Recommendation: option (b) — declare "Audio Data" and "Other User Content", App Functionality, not linked, not used for tracking

Why "Data Not Collected" (option a) is the risky reading:
1. Apple defines *collect* as transmitting data off the device so that you **or your third-party partners** can access it longer than needed to service the request in real time. The WebRTC transport is app code the developer ships; the endpoint (OpenAI) is an external vendor. Apple has no carve-out for "the user brought their own API key" — the user configuring the destination reduces linkage, not the fact of transmission.
2. OpenAI's API retains inputs (abuse monitoring, up to 30 days by default), which is beyond real-time servicing. The 24-message seed context is the same story.
3. The optional-disclosure exemption needs the collection to be infrequent, optional **and not part of the app's primary functionality**. A marketed, continuously streaming voice session fails that.
4. Consistency: the mic usage string already says "stream your voice directly from this device to OpenAI"; a "Not Collected" label next to it is a metadata-consistency flag (Guidelines 5.1.1(i), 2.3.x). Starting accurate looks better than changing a public label later.

Guidelines: 5.1.1(i) policy/label consistency; 5.1.1(ii) permission (consent sheet + specific mic string satisfy it; keep "Cancel starts nothing"); 5.1.2 sharing with third parties needs consent and disclosure — satisfied if disclosed.

Trade-off: the label shows two "Data Not Linked to You" items. Minor optics cost, zero review risk. "Not linked" is defensible: the developer holds no identifier; the IP goes to the user's own OpenAI account relationship. Do NOT declare Coarse Location for the IP.

## Privacy manifest

Not strictly required for the app's own code (only for listed third-party SDKs), but Xcode's Privacy Report aggregates the manifest and Apple expects it to mirror the label. Add to `scarf/Scarf iOS/PrivacyInfo.xcprivacy`:

```xml
<key>NSPrivacyCollectedDataTypes</key>
<array>
    <dict>
        <key>NSPrivacyCollectedDataType</key>
        <string>NSPrivacyCollectedDataTypeAudioData</string>
        <key>NSPrivacyCollectedDataTypeLinked</key><false/>
        <key>NSPrivacyCollectedDataTypeTracking</key><false/>
        <key>NSPrivacyCollectedDataTypePurposes</key>
        <array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
    </dict>
    <dict>
        <key>NSPrivacyCollectedDataType</key>
        <string>NSPrivacyCollectedDataTypeOtherUserContent</string>
        <key>NSPrivacyCollectedDataTypeLinked</key><false/>
        <key>NSPrivacyCollectedDataTypeTracking</key><false/>
        <key>NSPrivacyCollectedDataTypePurposes</key>
        <array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
    </dict>
</array>
```

Required Reason APIs: AVAudioSession / WebRTC / WKWebView need no entry (microphone is a permission, not a Required Reason category). **Gap found regardless of this decision:** `Scarf iOS/Diagnostics/MetricKitSubscriber.swift` (~83-92, 148-155) and `ScarfCore/Services/HermesTTSCache.swift` (~151-171) read `contentModificationDate`, which is the File Timestamp category. Add `NSPrivacyAccessedAPICategoryFileTimestamp` with reason `C617.1` (files inside the app container), or App Store Connect sends ITMS-91053 and eventually rejects. Same item as task t-aa7be288 (R2).

## App Review notes (paste-ready)

"ScarfGo is a client for a self-hosted Hermes agent. Reviewer credentials: [demo host / SSH key]. Live Voice appears only when the Hermes host is 0.21.3+ with `voice.voice_chat_mode: gpt-live`; the demo host is configured this way. On first use a consent sheet explains that microphone audio and up to 24 recent chat messages stream directly from the device to OpenAI via WebRTC, using the OpenAI API key configured on the user's own host. The developer operates no server in this path and receives no data. Dictation uses on-device SFSpeechRecognizer only. Privacy label: Audio Data and Other User Content, App Functionality, not linked, not tracked. Privacy policy: https://awizemann.github.io/scarf/privacy/."

## What Alan decides
- (a) keep "Data Not Collected", or (b) declare the two types (recommended).
- If (b): Claude adds the xcprivacy entries + the File Timestamp reason and Alan updates App Store Connect App Privacy before the ScarfGo release that ships Live Voice.
