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
        for api in ["start ()", "applyAnswer (sdp)", "send (json)", "setMicrophoneEnabled (enabled)", "teardown ()"] {
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
}
#endif
