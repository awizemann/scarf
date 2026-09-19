#if canImport(WebKit)
import Testing
import Foundation
import WebKit
@testable import ScarfCore

/// The WKWebView media bridge, short of opening a microphone (which would
/// raise a TCC prompt for the test runner) or reaching the vendor.
@MainActor
@Suite struct WebViewVoiceMediaBridgeTests {

    // MARK: policy

    @Test func microphoneIsGrantedOnlyToOurPagesMainFrame() {
        let grants = WebViewVoiceMediaBridge.grantsCapture
        #expect(grants(true, "scarf-voice", "live", .microphone))
        #expect(!grants(true, "scarf-voice", "live", .camera))
        #expect(!grants(true, "scarf-voice", "live", .cameraAndMicrophone))
        #expect(!grants(false, "scarf-voice", "live", .microphone))
        #expect(!grants(true, "https", "live", .microphone))
        #expect(!grants(true, "scarf-voice", "evil", .microphone))
        #expect(!grants(true, "file", "", .microphone))
    }

    @Test func pageMessagesAreAcceptedOnlyFromOurPagesMainFrame() {
        let accepts = WebViewVoiceMediaBridge.acceptsMessage
        #expect(accepts(true, "scarf-voice", "live"))
        #expect(!accepts(false, "scarf-voice", "live"))
        #expect(!accepts(true, "https", "example.com"))
    }

    @Test func staleSessionMessagesAreDropped() {
        let current = WebViewVoiceMediaBridge.isCurrent
        #expect(current(["type": "ready", "secure": true], 7))          // no token: page-level
        #expect(current(["type": "event", "data": "{}", "token": 7], 7))
        #expect(!current(["type": "closed", "reason": "connection_lost", "token": 6], 7))
        #expect(!current(["type": "event", "token": "7"], 7))
    }

    @Test func theSchemeHandlerServesOnlyThePage() throws {
        #expect(VoiceLivePageSchemeHandler.serves(try #require(URL(string: "scarf-voice://live/index.html"))))
        #expect(VoiceLivePageSchemeHandler.serves(try #require(URL(string: "scarf-voice://live/"))))
        #expect(!VoiceLivePageSchemeHandler.serves(try #require(URL(string: "scarf-voice://live/other.js"))))
        #expect(!VoiceLivePageSchemeHandler.serves(try #require(URL(string: "scarf-voice://evil/index.html"))))
        #expect(!VoiceLivePageSchemeHandler.serves(try #require(URL(string: "https://live/index.html"))))
    }

    // MARK: the bundled page

    @Test func thePageIsBundledAndSelfContained() throws {
        let html = String(decoding: try #require(VoiceLivePage.html), as: UTF8.self)
        #expect(html.contains("messageHandlers.scarfVoiceLive"))
        for api in ["start (token)", "applyAnswer (sdp)", "send (json)", "setMicrophoneEnabled (enabled)", "teardown ()"] {
            #expect(html.contains(api), "\(api)")
        }
        #expect(html.contains("createDataChannel('oai-events')"))
        #expect(html.contains("echoCancellation: true"))
        // No external fetches: nothing but the inline script runs.
        #expect(!html.contains("src=\""))
        #expect(!html.contains("http://") && !html.contains("https://"))
        #expect(!html.contains("fetch("))
        #expect(!html.contains("console.log"))   // never log SDP
    }

    // MARK: WebKit, for real (no microphone)

    /// Loads the page through the custom scheme and checks the spike's key
    /// finding holds in the shipped bridge: a secure context, with the page
    /// API installed. (`navigator.mediaDevices` itself is NOT asserted: in the
    /// xctest runner it is `undefined`, while the P3 spike's app bundle —
    /// hardened runtime + `audio-input` + `NSMicrophoneUsageDescription`, the
    /// same shape as both Scarf apps — saw it. The runner has neither.)
    @Test func thePageLoadsAsASecureContextWithTheAPI() async throws {
        let bridge = WebViewVoiceMediaBridge()
        var events: [VoiceMediaEvent] = []
        bridge.onEvent = { events.append($0) }
        let secure = await bridge.loadPage()
        #expect(secure == true)
        #expect(events.first == .pageReady(secureContext: true))

        let probe = try await bridge.webView.callAsyncJavaScript(
            "return [window.isSecureContext, typeof window.scarfVoiceLive.start, scarfVoiceLive.send(payload)].join(',')",
            arguments: ["payload": "{}"], in: nil, contentWorld: .page) as? String
        #expect(probe == "true,function,false")   // no channel yet: send refuses

        // Teardown before any start is harmless, and a second load is cached.
        bridge.teardown()
        #expect(await bridge.loadPage() == true)
    }

    @Test func aScriptErrorSurfacesTheExceptionMessage() async throws {
        let bridge = WebViewVoiceMediaBridge()
        #expect(await bridge.loadPage() == true)
        do {
            try await bridge.applyAnswer(sdp: "v=0")
            Issue.record("expected a throw")
        } catch let error as WebViewVoiceMediaBridge.BridgeError {
            guard case .script(let message) = error else { Issue.record("\(error)"); return }
            #expect(message.contains("not running"))
        }
    }

    // MARK: the page's own JavaScript, executed (F3)
    //
    // The runner has no microphone and no network, so the page runs against
    // JS stand-ins for getUserMedia, RTCPeerConnection, the data channel and
    // AudioContext, installed after load. Everything under test (teardown,
    // mic release, the flush, error mapping, disconnect grace) is the
    // shipped page's code.

    static let harness = """
    window.__log = []
    class FakeTrack { constructor () { this.enabled = true; this.readyState = 'live' }
      stop () { this.readyState = 'ended'; __log.push('track.stop') } }
    class FakeStream { constructor () { this.tracks = [new FakeTrack()] }
      getTracks () { return this.tracks } getAudioTracks () { return this.tracks } }
    class FakeChannel extends EventTarget {
      constructor () { super(); this.readyState = 'connecting'; this.bufferedAmount = 0 }
      send (d) { __log.push('send ' + JSON.parse(d).type) }
      close () { if (this.readyState !== 'closed') { this.readyState = 'closed'; __log.push('channel.close') } }
      open () { this.readyState = 'open'; this.dispatchEvent(new Event('open')) } }
    class FakePC extends EventTarget {
      constructor () { super(); window.__pc = this; this.connectionState = 'new'; this.iceGatheringState = 'complete'; this.localDescription = null }
      addTrack () {}
      createDataChannel () { window.__channel = new FakeChannel(); return window.__channel }
      async createOffer () { return { type: 'offer', sdp: 'v=0 fake\\r\\n' } }
      async setLocalDescription (d) { this.localDescription = d }
      async setRemoteDescription () {}
      close () { this.connectionState = 'closed'; __log.push('pc.close') }
      setState (s) { this.connectionState = s; this.dispatchEvent(new Event('connectionstatechange')) } }
    window.RTCPeerConnection = FakePC
    window.AudioContext = class {
      createAnalyser () { return { fftSize: 512, frequencyBinCount: 8, getByteTimeDomainData () {} } }
      createMediaStreamSource () { return { connect () {} } }
      close () { __log.push('context.close'); return Promise.resolve() } }
    window.__gum = async () => new FakeStream()
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: { getUserMedia: c => window.__gum(c) } })
    return true
    """

    /// A bridge with the page loaded and the stand-ins installed.
    private func harnessedBridge() async throws -> (WebViewVoiceMediaBridge, EventLog) {
        let bridge = WebViewVoiceMediaBridge()
        let log = EventLog()
        bridge.onEvent = { log.events.append($0) }
        #expect(await bridge.loadPage() == true)
        _ = try await js(bridge, Self.harness)
        return (bridge, log)
    }

    @MainActor final class EventLog { var events: [VoiceMediaEvent] = [] }

    @discardableResult
    private func js(_ bridge: WebViewVoiceMediaBridge, _ body: String) async throws -> Any? {
        try await bridge.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    private func pageLog(_ bridge: WebViewVoiceMediaBridge) async throws -> [String] {
        try await js(bridge, "return window.__log.slice()") as? [String] ?? []
    }

    /// Polls until `condition` holds. The 10 s bound is a CEILING only the
    /// failure path pays, never a budget the green path spends: every caller
    /// asserts the condition afterwards, so a timeout still fails the test.
    private func waitFor(_ condition: @MainActor () async throws -> Bool) async rethrows {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Start a session on the stand-ins and open its data channel.
    private func startLive(_ bridge: WebViewVoiceMediaBridge, _ log: EventLog) async throws {
        try await bridge.startMedia()
        await waitFor { log.events.contains { if case .offer = $0 { return true } else { return false } } }
        _ = try await js(bridge, "window.__channel.open(); return true")
        await waitFor { log.events.contains(.channelOpen) }
    }

    /// F3 #4 + #8: teardown releases the microphone AT ONCE, but closes the
    /// peer only after the data channel had a moment to deliver the
    /// `session.close` sent just before, and reports release only then.
    @Test func teardownReleasesTheMicAtOnceAndFlushesTheCloseBeforeClosingThePeer() async throws {
        let (bridge, log) = try await harnessedBridge()
        try await startLive(bridge, log)
        bridge.send(#"{"type":"session.close"}"#)
        let released = EventLog()
        bridge.teardown { released.events.append(.channelOpen) }
        let atOnce = try await pageLog(bridge)       // runs after teardown's synchronous part
        #expect(atOnce.contains("track.stop"))
        #expect(!atOnce.contains("pc.close"))         // the close is still being flushed
        #expect(released.events.isEmpty)
        await waitFor { !released.events.isEmpty }
        let after = try await pageLog(bridge)
        #expect(!released.events.isEmpty)
        let order = after.filter { ["send session.close", "track.stop", "channel.close", "pc.close"].contains($0) }
        #expect(order == ["send session.close", "track.stop", "channel.close", "pc.close"])
        // A torn-down page can start again.
        let restarted = try await js(bridge, "return window.__pc.connectionState") as? String
        #expect(restarted == "closed")
    }

    @Test func teardownWithNoPageReportsReleasedAtOnce() {
        let bridge = WebViewVoiceMediaBridge()
        var released = false
        bridge.teardown { released = true }
        #expect(released)
    }

    /// F3 #5: a navigation failure after the page is up (e.g. one the policy
    /// cancelled) must not cost the bridge its ability to tear the live
    /// session down: the microphone would stay open.
    @Test func aLaterNavigationFailureStillLetsTeardownReleaseTheMic() async throws {
        let (bridge, log) = try await harnessedBridge()
        try await startLive(bridge, log)
        bridge.webView(bridge.webView, didFail: nil, withError: URLError(.cancelled))
        bridge.webView(bridge.webView, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))
        #expect(bridge.secureContext == true)
        let released = EventLog()
        bridge.teardown { released.events.append(.channelOpen) }
        await waitFor { !released.events.isEmpty }
        #expect(try await pageLog(bridge).contains("track.stop"))
    }

    /// F3 #6: getUserMedia's exception name decides the reason Swift gets.
    @Test(arguments: [("NotAllowedError", "microphone_denied"), ("NotReadableError", "microphone_busy"),
                      ("NotFoundError", "microphone_not_found"), ("TypeError", "microphone_failed")])
    func microphoneErrorsAreReportedByName(_ name: String, _ reason: String) async throws {
        let (bridge, log) = try await harnessedBridge()
        _ = try await js(bridge, "window.__gum = async () => { throw new DOMException('no', '\(name)') }; return true")
        var thrown: Error?
        do { try await bridge.startMedia() } catch { thrown = error }
        await waitFor { log.events.contains(.transportClosed(reason: reason)) }
        #expect(log.events.contains(.transportClosed(reason: reason)))
        // The start's throw, which can reach the engine first, maps the same.
        let error = try #require(thrown)
        let mapped = GPTLiveEngine.failure(forMediaStartError: error)
        if case .mediaUnavailable = GPTLiveEngine.failure(forCloseReason: reason, usageSeconds: nil) {
            guard case .mediaUnavailable = mapped else { Issue.record("\(mapped)"); return }
        } else {
            #expect(mapped == GPTLiveEngine.failure(forCloseReason: reason, usageSeconds: nil))
        }
    }

    /// F3 #7: 'disconnected' is recoverable within the grace; only a
    /// disconnection that outlasts it (or 'failed') loses the connection.
    ///
    /// Timed on the PAGE's clock, not Swift's: the grace timer runs in the
    /// page, and page timers fire in due order, so a recovery scheduled 20 ms
    /// in always beats a 150 ms grace and a 300 ms wait always outlasts it.
    /// The first version slept in Swift between the two `setState` calls and
    /// went red in the full parallel run whenever a round trip to the page
    /// took longer than the grace.
    @Test func aDisconnectIsLostOnlyAfterTheGrace() async throws {
        let (bridge, log) = try await harnessedBridge()
        _ = try await js(bridge, "scarfVoiceLive.config.disconnectGraceMs = 150; return true")
        try await startLive(bridge, log)
        let lost = VoiceMediaEvent.transportClosed(reason: "connection_lost")
        let recovered = try await js(bridge, """
            window.__pc.setState('disconnected')
            await new Promise(r => setTimeout(r, 20))
            window.__pc.setState('connected')
            await new Promise(r => setTimeout(r, 300))
            return !window.__log.includes('track.stop')
            """) as? Bool
        #expect(recovered == true)                     // it came back in time
        #expect(!log.events.contains(lost))
        let lostAtOnce = try await js(bridge, """
            window.__pc.setState('disconnected')
            return window.__log.includes('track.stop')
            """) as? Bool
        #expect(lostAtOnce == false)                   // not lost before the grace
        await waitFor { log.events.contains(lost) }
        #expect(log.events.contains(lost))
        #expect(try await pageLog(bridge).contains("track.stop"))
    }

}
#endif
