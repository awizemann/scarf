import Testing
import Foundation
@testable import ScarfCore

/// `open_url` — the permission, the URL policy, and the per-host consent
/// records that sit on top of the grant.
@Suite struct MiniAppOpenURLTests {

    // MARK: - Permission vocabulary

    @Test func permissionParsesAndRoundTrips() throws {
        #expect(MiniAppPermission(rawValue: "open_url") == .openURL)
        #expect(MiniAppPermission(rawValue: " open_url ") == .openURL)   // trimmed
        #expect(MiniAppPermission.openURL.rawValue == "open_url")
        // Unknown neighbours stay unknown — no accidental prefix matching.
        #expect(MiniAppPermission(rawValue: "open_url:evil") == .unknown("open_url:evil"))
        #expect(MiniAppPermission(rawValue: "open-url") == .unknown("open-url"))

        let json = try JSONEncoder().encode([MiniAppPermission.openURL])
        #expect(String(data: json, encoding: .utf8) == "[\"open_url\"]")
        #expect(try JSONDecoder().decode([MiniAppPermission].self, from: json) == [.openURL])
    }

    /// Grantable, not sensitive (it can read nothing and cannot open
    /// anything without the destination confirmation), and — the part that
    /// matters for signing — a plain token the payload-v2 rules accept.
    @Test func permissionIsGrantableAndSignable() {
        #expect(MiniAppPermission.openURL.isSensitive == false)
        #expect(MiniAppPermission.openURL.summary == "Open links in your browser")
        let raw = MiniAppPermission.openURL.rawValue
        #expect(!raw.contains(","))
        #expect(!raw.contains("\u{1F}"))
    }

    /// A grant carrying `open_url` signs and verifies, and the tag is
    /// bound to that permission being present — the payload-v2 rules
    /// (length-prefixed components, no comma / 0x1F) accept the token.
    @Test func grantSigningRoundTripsWithOpenURL() throws {
        let signer = MiniAppGrantSigner(testServiceSuffix: "openurl-\(UUID().uuidString)")
        var grant = MiniAppGrant(
            projectId: "p", miniAppId: "m",
            permissions: ["open_url", "store"],
            decidedAt: "2026-09-04T00:00:00Z",
            manifestFingerprint: "fp"
        )
        grant.signature = try signer.signedTag(for: grant)
        #expect(signer.isAuthentic(grant))

        // Dropping open_url from the row must break the tag: a grant is
        // authentic for exactly the permissions it was signed with.
        var narrowed = grant
        narrowed.permissions = ["store"]
        #expect(!signer.isAuthentic(narrowed))
        // And adding it to a row signed without it must not verify either.
        var widened = MiniAppGrant(
            projectId: "p", miniAppId: "m", permissions: ["store"],
            decidedAt: "2026-09-04T00:00:00Z", manifestFingerprint: "fp"
        )
        widened.signature = try signer.signedTag(for: widened)
        widened.permissions = ["open_url", "store"]
        #expect(!signer.isAuthentic(widened))
    }

    // MARK: - Bridge gating

    @Test func openURLIsDeniedWithoutTheGrant() {
        #expect(MiniAppBridgeMethod.openURL.requiredPermission == .openURL)
        #expect(MiniAppBridgeDispatcher(grantedPermissions: []).preflight(.openURL)?.errorCode
                == "permission_denied")
        // Another grant is not this grant.
        #expect(MiniAppBridgeDispatcher(grantedPermissions: [.net, .store]).preflight(.openURL)?.errorCode
                == "permission_denied")
        #expect(MiniAppBridgeDispatcher(grantedPermissions: [.openURL]).preflight(.openURL) == nil)
    }

    @Test func shimExposesOpenURL() {
        let js = MiniAppBridge.javaScriptSource(context: MiniAppContext(
            projectId: "p", projectName: "N", projectRoot: "/r",
            serverId: "s", miniAppId: "m", generated: true
        ))
        #expect(js.contains("openURL: async (url) => post(\"open.url\", [String(url)])"))
    }

    // MARK: - URL policy

    @Test func acceptsAPlainHTTPSURL() throws {
        let ok = try #require(try? MiniAppOpenURLPolicy.validate("https://Example.COM./a/b?q=1#f").get())
        #expect(ok.host == "example.com")           // lowercased, trailing dot stripped
        #expect(ok.url.absoluteString.contains("q=1"))
    }

    @Test func rejectsEverythingOutsideTheShape() {
        func refusal(_ s: String) -> MiniAppOpenURLPolicy.Refusal? {
            if case .failure(let r) = MiniAppOpenURLPolicy.validate(s) { return r }
            return nil
        }
        #expect(refusal("") == .empty)
        #expect(refusal("   ") == .empty)
        // Scheme: http is refused, not upgraded; and no launcher schemes.
        #expect(refusal("http://example.com") == .schemeNotHTTPS)
        #expect(refusal("file:///etc/passwd") == .schemeNotHTTPS)
        #expect(refusal("javascript:alert(1)") == .schemeNotHTTPS)
        #expect(refusal("HTTPS://example.com") == nil)   // scheme case-insensitive
        // Userinfo confusable: host is evil.example, it READS as apple.com.
        #expect(refusal("https://apple.com@evil.example/") == .userInfoPresent)
        #expect(refusal("https://u:p@evil.example/") == .userInfoPresent)
        // No host at all.
        #expect(refusal("https:///path") == .missingHost)
        #expect(refusal("https://") == .malformed || refusal("https://") == .missingHost)
        // Hosts that could lie on the confirmation line. An IPv6 literal
        // is refused outright (it isn't a name a user can judge).
        #expect(refusal("https://[::1]/") == .illegalHost)
        // Control characters / interior whitespace.
        #expect(refusal("https://example.com/a\nb") == .illegalCharacters)
        #expect(refusal("https://example.com/\u{202E}gnp.exe") == .illegalCharacters)
        // Oversize.
        let long = "https://example.com/" + String(repeating: "a", count: 3000)
        #expect(refusal(long) == .tooLong)
    }

    /// THE HOMOGRAPH CASE. A Unicode host is not refused — `URL` converts
    /// it to punycode, and the policy's ASCII charset then accepts THAT.
    /// Which is the safe direction and the whole point: the confirmation
    /// says `xn--pple-43d.com`, not `аpple.com`, so a lookalike domain
    /// announces itself as one instead of borrowing Apple's name. (Same
    /// choice `ImageHostConsentStore` makes.)
    @Test func unicodeHostsAreShownAsPunycode() throws {
        let cyrillic = try #require(try? MiniAppOpenURLPolicy.validate("https://аpple.com/").get())
        #expect(cyrillic.host == "xn--pple-43d.com")
        #expect(cyrillic.host != "apple.com")
        let already = try #require(try? MiniAppOpenURLPolicy.validate("https://xn--80ak6aa92e.com/").get())
        #expect(already.host == "xn--80ak6aa92e.com")
    }

    @Test func displayStringTruncatesVisibly() {
        let url = URL(string: "https://example.com/" + String(repeating: "a", count: 500))!
        let shown = MiniAppOpenURLPolicy.displayString(url, maxLength: 40)
        #expect(shown.count == 41)
        #expect(shown.hasSuffix("…"))
    }

    // MARK: - Per-host consent (the second gate)

    /// The Keychain suffix is derived from the SUITE, not fresh per call —
    /// two stores in one test must share the machine key, or every record
    /// one writes reads as unsigned to the other.
    private func store(_ suite: String) -> ImageHostConsentStore {
        ImageHostConsentStore(suiteName: suite, testServiceSuffix: suite, purpose: .openURL)
    }

    @Test func alwaysAllowPersistsAndIsHostScoped() {
        let suite = "com.scarf.tests.openurl.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let s = store(suite)
        let url = URL(string: "https://docs.example/a")!

        #expect(s.isAllowed(url: url, projectId: "P") == false)
        #expect(s.allow(url: url, projectId: "P") == "docs.example")
        // Persisted, and covers other paths on the same host…
        #expect(s.isAllowed(url: URL(string: "https://docs.example/other?x=1")!, projectId: "P"))
        // …but not a different host, or a different project.
        #expect(s.isAllowed(url: URL(string: "https://evil.example/a")!, projectId: "P") == false)
        #expect(s.isAllowed(url: url, projectId: "Q") == false)
        // A fresh store instance still sees it (this is the "Always" part).
        #expect(store(suite).isAllowed(url: url, projectId: "P"))
    }

    /// "Open Once" writes nothing — the next request asks again. Modeled
    /// the way the bridge does it: it simply never calls `allow`.
    @Test func openOnceLeavesNoRecord() {
        let suite = "com.scarf.tests.openurl.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let s = store(suite)
        let url = URL(string: "https://docs.example/a")!
        #expect(s.isAllowed(url: url, projectId: "P") == false)
        #expect(UserDefaults(suiteName: suite)?
            .stringArray(forKey: "com.scarf.miniApp.openURLHosts.P") == nil)
    }

    /// THE ATTACK: the mini-app's agent has a terminal, so it writes the
    /// allowlist itself. An untagged (or wrongly tagged) record is not a
    /// record.
    @Test func plantedRecordIsIgnored() {
        let suite = "com.scarf.tests.openurl.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let s = store(suite)
        let url = URL(string: "https://evil.example/steal?d=secrets")!

        UserDefaults(suiteName: suite)?.set(
            ["evil.example"], forKey: "com.scarf.miniApp.openURLHosts.P"
        )
        #expect(s.isAllowed(url: url, projectId: "P") == false)
        // A made-up tag doesn't help either.
        UserDefaults(suiteName: suite)?.set(
            ["evil.example\u{1F}ZmFrZXRhZw=="], forKey: "com.scarf.miniApp.openURLHosts.P"
        )
        #expect(s.isAllowed(url: url, projectId: "P") == false)
        // And a legitimate allow rewrites from the VERIFIED set, dropping
        // the planted neighbour rather than carrying it forward.
        s.allow(url: URL(string: "https://good.example/")!, projectId: "P")
        #expect(s.allowedHosts(projectId: "P") == ["good.example"])
    }

    /// The two purposes are separate records: blessing an image host says
    /// nothing about opening links to it, and a tag can't be replayed
    /// across the boundary.
    @Test func imageConsentIsNotOpenURLConsent() {
        let suite = "com.scarf.tests.openurl.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let suffix = "openurl-\(UUID().uuidString)"
        let images = ImageHostConsentStore(suiteName: suite, testServiceSuffix: suffix, purpose: .remoteImage)
        let links = ImageHostConsentStore(suiteName: suite, testServiceSuffix: suffix, purpose: .openURL)
        let url = URL(string: "https://cdn.example/x.png")!

        images.allow(url: url, projectId: "P")
        #expect(images.isAllowed(url: url, projectId: "P"))
        #expect(links.isAllowed(url: url, projectId: "P") == false)

        // Lift the image record verbatim into the open-url key: the tag
        // covers a different payload version, so it does not verify.
        let record = UserDefaults(suiteName: suite)?
            .stringArray(forKey: "com.scarf.imageWidget.allowedHosts.P") ?? []
        #expect(record.count == 1)
        UserDefaults(suiteName: suite)?.set(record, forKey: "com.scarf.miniApp.openURLHosts.P")
        #expect(links.isAllowed(url: url, projectId: "P") == false)
    }

    @Test func revokeDropsTheHost() {
        let suite = "com.scarf.tests.openurl.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let s = store(suite)
        let url = URL(string: "https://docs.example/a")!
        s.allow(url: url, projectId: "P")
        s.revoke(host: "docs.example", projectId: "P")
        #expect(s.isAllowed(url: url, projectId: "P") == false)
    }

    // MARK: - Pace

    /// The bridge's own limiter settings: a burst of `openURL` calls stops
    /// after five in a minute, so a loop cannot become a dialog cannon.
    /// (The one-confirmation-at-a-time rule is enforced in
    /// `ScarfMiniAppBridge`, which needs a `WKWebView`; this covers the
    /// arithmetic it relies on.)
    @Test func openURLBurstIsRateLimited() {
        let rl = MiniAppRateLimiter(maxEvents: 5, windowSeconds: 60)
        var history: [Date] = []
        let t0 = Date(timeIntervalSince1970: 5000)
        for i in 0..<5 {
            let (allowed, h) = rl.decide(now: t0.addingTimeInterval(Double(i) * 0.01), history: history)
            history = h
            #expect(allowed, "call \(i) should be allowed")
        }
        let (sixth, after) = rl.decide(now: t0.addingTimeInterval(0.06), history: history)
        #expect(!sixth)
        #expect(after.count == 5)
        // A minute later the window has slid.
        #expect(rl.decide(now: t0.addingTimeInterval(61), history: after).allowed)
    }
}
