---
title: GPT-Live voice in WKWebView: origin, permission and hosting requirements
type: note
permalink: scarf/architecture/gpt-live-voice-in-wkwebview-origin-permission-and-hosting
tags: [voice, webkit, webrtc, gpt-live]
source_paths: [scarf/scarf/scarf.entitlements, scarf/scarf/Info.plist, scarf/Scarf iOS/Info.plist]
source_paths_inferred: false
source_sha: 0efaac8432c1f749c3e6e28427375e9c22e4ff00
created: 2026-09-18
updated: 2026-09-18
reviewed: 2026-09-21
reviewed_by: audit:claude-code (background)
---

Measured in the P3 Live Voice spike (2026-09-18, macOS 27.0 + iOS 26.2 simulator; harness at scarf/Spikes/VoiceLive on branch feat/voice-spike). Report: documents/plans/2026-09-18-live-voice-spike.md. Real-mic TCC and real-device AEC were NOT exercised (WebKit mock capture device only).

## Observations
- [constraint] Serve the voice page from a custom WKURLSchemeHandler scheme (scarf-voice://): isSecureContext is true on macOS and iOS; loadHTMLString with baseURL nil is about:blank, not secure, and navigator.mediaDevices is undefined #voice #webkit
- [gotcha] The WKWebView must be in a window's view hierarchy — a detached web view reports visibilityState hidden and audio.play() of the remote WebRTC track never resolves; alpha 0 or isHidden inside the hierarchy both play #voice #webkit
- [convention] Implement WKUIDelegate requestMediaCapturePermissionFor and grant only origin.protocol == scarf-voice + microphone; set mediaTypesRequiringUserActionForPlayback = [] (and allowsInlineMediaPlayback on iOS). The OS TCC prompt still follows. macOS requires the hardened-runtime audio-input entitlement + NSMicrophoneUsageDescription (the app is NOT sandboxed); iOS requires NSMicrophoneUsageDescription and NSSpeechRecognitionUsageDescription in Info.plist #voice #permissions
- [gotcha] WebKit hides host ICE candidates behind mDNS .local names until capture is granted, so an in-page WebRTC loopback test is flaky unless the TEST-ONLY SPI _setICECandidateFilteringEnabled:NO is set; _setMockCaptureDevicesEnabled: gives a headless mic. Never ship either #voice #testing
- [fact] WKWebView WebRTC offers carry opus/48000/2 + a webrtc-datachannel m-line and end in CRLF; getUserMedia track settings report echoCancellation true (WebKit uses the OS voice-processing unit) #voice

## Shipped in P4 (WebViewVoiceMediaBridge)

- [fact] The shipped bridge serves `VoiceLive/Resources/voice-live.html`, a ScarfCore SPM resource. Xcode copies it into `ScarfCore_ScarfCore.bundle` inside both scarf.app and scarf mobile.app, which was verified in the built products. `VoiceLiveMediaHostView` is the 1×1, alpha 0 host each platform embeds #voice #webkit
- [gotcha] In the `swift test` / xctest runner, the scheme page is a secure context but `navigator.mediaDevices` is undefined. The spike's app bundle, which had the hardened runtime, `audio-input` and `NSMicrophoneUsageDescription`, did see it. Package tests can load the page and drive its API, but they cannot assert `mediaDevices` or open a mic #voice #testing
- [convention] Every page message during a session carries the generation token the bridge started it with. The bridge drops any message whose token doesn't match, and a start whose generation was torn down while the page loaded never opens the mic. This fixed a review-found leak where ending during page load left the microphone on #voice

## Teardown, flush and page tests (F3, t-daa906da)

- [convention] Page `teardown()` stops the mic tracks, meters and playback synchronously and detaches the session, so a new `start()` can begin at once. It closes the old peer only after the open data channel drains, plus a 300 ms grace, capped at 1.5 s, so a `session.close` sent just before (by `endImmediately`) actually leaves the machine. It returns a promise, and the bridge's `teardown(onReleased:)` completion fires when that promise resolves. The completion holds the bridge, and with it the web view, until then #voice #webkit
- [gotcha] Only the page's own navigation failing before `ready` loses the page. `didFail` / `didFailProvisionalNavigation` for any other navigation, such as one the policy cancels, used to nil `secureContext`, and `fire()` then silently dropped the teardown, which left the mic open. Teardown is never gated on `secureContext` #voice #webkit
- [convention] `connectionState == 'disconnected'` is recoverable: `connection_lost` only if it stays down past `CONFIG.disconnectGraceMs` (8 s). `failed` / `closed` still fail at once #voice #webrtc
- [testing] The page's JS is executed in `swift test` (WebViewVoiceMediaBridgeTests). The page loads over the real scheme, then JS stand-ins for getUserMedia, RTCPeerConnection, the data channel and AudioContext are installed after load. This tests teardown ordering, the flush, getUserMedia error names and the disconnect grace without a mic or network. `scarfVoiceLive.config` exposes the timings for tests #voice #testing

## Relations
- feeds_into [[mac-live-voice-p5a-gate-voiceturnhost-on-chatviewmodel]]
- feeds_into [[scarfgo-live-voice-p5b-gate-mic-exclusivity-teardown-and]]
