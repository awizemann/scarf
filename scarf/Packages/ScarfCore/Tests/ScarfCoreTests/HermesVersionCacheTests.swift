import Testing
import Foundation
@testable import ScarfCore

/// Behavior of the shared connect-time version probe: single probe per
/// server, persistence across launches, failure fallback, reconciliation.
///
/// Every test injects a stub probe + an isolated `UserDefaults` suite, so
/// nothing here spawns `hermes` or touches the developer's real defaults.
@Suite struct HermesVersionCacheTests {

    // MARK: - Helpers

    /// Fresh, per-test `UserDefaults` suite. Removed on teardown by the
    /// caller via `defaults.removePersistentDomain(forName:)`.
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "scarf.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// A counting stub probe. `line` nil → simulates a failed probe.
    private final class ProbeSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var line: String?
        /// Calls that fail before `line` starts being returned — models a
        /// cold home whose first `hermes --version` outruns the timeout.
        var failuresBeforeSuccess = 0
        init(line: String?, failuresBeforeSuccess: Int = 0) {
            self.line = line
            self.failuresBeforeSuccess = failuresBeforeSuccess
        }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        func probe(_: ServerContext) -> HermesCapabilities {
            lock.lock()
            _calls += 1
            let current = _calls <= failuresBeforeSuccess ? nil : line
            lock.unlock()
            guard let current else { return .empty }
            return HermesCapabilities.parse(current)
        }
    }

    private func localContext(home: String) -> ServerContext {
        ServerContext.local(home: URL(fileURLWithPath: home))
    }

    private func sshContext(host: String, user: String? = nil, home: String? = nil) -> ServerContext {
        ServerContext(
            id: UUID(),
            displayName: host,
            kind: .ssh(SSHConfig(host: host, user: user, remoteHome: home))
        )
    }

    // MARK: - Retry on a cold miss

    @Test func aColdMissIsRetriedAndTheRetryIsMemoized() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let spy = ProbeSpy(line: "Hermes Agent v0.21.0 (2026.8.31)", failuresBeforeSuccess: 1)
        let cache = HermesVersionCache(defaults: defaults, probe: spy.probe, retryDelays: [0.01, 0.01])
        let ctx = localContext(home: "/tmp/scarf-cache-retry")

        let caps = await cache.capabilities(for: ctx)

        #expect(caps.detected)
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 21, patch: 0))
        #expect(spy.calls == 2)
        // The recovered answer is the memoized one: no third probe.
        _ = await cache.capabilities(for: ctx)
        #expect(spy.calls == 2)
    }

    @Test func retriesAreBoundedAndAPersistentMissStaysEmpty() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let spy = ProbeSpy(line: nil)
        let cache = HermesVersionCache(defaults: defaults, probe: spy.probe, retryDelays: [0.01, 0.01])
        let ctx = localContext(home: "/tmp/scarf-cache-retry-miss")

        let caps = await cache.capabilities(for: ctx)

        #expect(!caps.detected)
        #expect(spy.calls == 3)   // one attempt plus two retries, then stop
    }

    @Test func noRetryDelaysMeansOneAttempt() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let spy = ProbeSpy(line: nil)
        let cache = HermesVersionCache(defaults: defaults, probe: spy.probe, retryDelays: [])
        _ = await cache.capabilities(for: localContext(home: "/tmp/scarf-cache-retry-none"))
        #expect(spy.calls == 1)
    }

    // MARK: - Single cached probe

    @Test func secondReadIsACacheHitNotASecondProbe() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let spy = ProbeSpy(line: "Hermes Agent v0.20.0 (2026.8.3)")
        let cache = HermesVersionCache(defaults: defaults, probe: spy.probe)
        let ctx = localContext(home: "/tmp/scarf-cache-a")

        let first = await cache.capabilities(for: ctx)
        let second = await cache.capabilities(for: ctx)

        #expect(first.semver == HermesCapabilities.SemVer(major: 0, minor: 20, patch: 0))
        #expect(second == first)
        #expect(spy.calls == 1)
    }

    @Test func concurrentReadsShareOneProbe() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let spy = ProbeSpy(line: "Hermes Agent v0.20.0 (2026.8.3)")
        let cache = HermesVersionCache(defaults: defaults, probe: spy.probe)
        let ctx = localContext(home: "/tmp/scarf-cache-b")

        await withTaskGroup(of: HermesCapabilities.self) { group in
            for _ in 0..<8 { group.addTask { await cache.capabilities(for: ctx) } }
            for await result in group { #expect(result.detected) }
        }

        #expect(spy.calls == 1)
    }

    @Test func syncPathSharesTheSameCacheAsTheAsyncPath() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let spy = ProbeSpy(line: "Hermes Agent v0.19.0 (2026.7.1)")
        let cache = HermesVersionCache(defaults: defaults, probe: spy.probe)
        let ctx = localContext(home: "/tmp/scarf-cache-c")

        _ = await cache.capabilities(for: ctx)
        let sync = cache.capabilitiesSync(for: ctx)

        #expect(sync.semver?.minor == 19)
        #expect(spy.calls == 1)
    }

    // MARK: - Per-connection keying

    @Test func distinctHostsDoNotShareARememberedVersion() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let spy = ProbeSpy(line: "Hermes Agent v0.20.0 (2026.8.3)")
        let cache = HermesVersionCache(defaults: defaults, probe: spy.probe)

        let mac = localContext(home: "/Users/alan/.hermes")
        let docker = sshContext(host: "docker-box", user: "hermes")

        _ = await cache.capabilities(for: mac)
        // The Docker host has never been probed — it must not inherit the
        // Mac's remembered version.
        #expect(cache.cached(for: docker) == nil)
        #expect(!cache.lastKnown(for: docker).detected)

        spy.line = "Hermes Agent v0.14.0 (2026.6.1)"
        let dockerCaps = await cache.capabilities(for: docker)
        #expect(dockerCaps.semver?.minor == 14)
        #expect(cache.cached(for: mac)?.semver?.minor == 20)
        #expect(spy.calls == 2)
    }

    @Test func repointingAServerEntryStartsCold() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let spy = ProbeSpy(line: "Hermes Agent v0.20.0 (2026.8.3)")
        let cache = HermesVersionCache(defaults: defaults, probe: spy.probe)

        // Same registry row (same UUID), re-pointed at a different machine.
        let id = UUID()
        let before = ServerContext(id: id, displayName: "box", kind: .ssh(SSHConfig(host: "old-host")))
        let after = ServerContext(id: id, displayName: "box", kind: .ssh(SSHConfig(host: "new-host")))

        _ = await cache.capabilities(for: before)
        #expect(!cache.lastKnown(for: after).detected)
    }

    // MARK: - Persistence round-trip

    @Test func successfulProbePersistsAcrossLaunches() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let ctx = localContext(home: "/tmp/scarf-cache-d")

        let first = HermesVersionCache(
            defaults: defaults,
            probe: ProbeSpy(line: "Hermes Agent v0.20.0 (2026.8.3)").probe
        )
        _ = await first.capabilities(for: ctx)

        // Simulate a relaunch: brand-new cache instance, same defaults.
        let relaunched = HermesVersionCache(defaults: defaults, probe: { _ in .empty })
        #expect(relaunched.cached(for: ctx) == nil, "in-memory cache must not survive")
        let remembered = relaunched.lastKnown(for: ctx)
        #expect(remembered.semver == HermesCapabilities.SemVer(major: 0, minor: 20, patch: 0))
        #expect(remembered.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 8, day: 3))
    }

    @Test func failedProbeIsNeitherCachedNorPersisted() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let spy = ProbeSpy(line: nil)
        // No retries here: this test pins the caching semantics of ONE
        // failed probe; the retry behaviour has its own tests above.
        let cache = HermesVersionCache(defaults: defaults, probe: spy.probe, retryDelays: [])
        let ctx = localContext(home: "/tmp/scarf-cache-e")

        let failed = await cache.capabilities(for: ctx)
        #expect(failed == .empty)
        #expect(cache.cached(for: ctx) == nil)
        #expect(!cache.lastKnown(for: ctx).detected)

        // A host that comes back later must be re-probed, not pinned to the
        // failure.
        spy.line = "Hermes Agent v0.20.0 (2026.8.3)"
        let recovered = await cache.capabilities(for: ctx)
        #expect(recovered.detected)
        #expect(spy.calls == 2)
    }

    @Test func syncProbeFailureStaysConservativeAndIgnoresRememberedVersion() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let ctx = localContext(home: "/tmp/scarf-cache-f")

        let seeded = HermesVersionCache(
            defaults: defaults,
            probe: ProbeSpy(line: "Hermes Agent v0.20.0 (2026.8.3)").probe
        )
        _ = await seeded.capabilities(for: ctx)

        // Relaunch with a host that now fails to answer. CLI-flag gating must
        // fall back to `.empty`, NOT to the remembered v0.20 — forwarding a
        // v0.20-only flag to an unknown host is an argparse abort.
        let relaunched = HermesVersionCache(defaults: defaults, probe: { _ in .empty })
        #expect(relaunched.capabilitiesSync(for: ctx) == .empty)
    }

    // MARK: - Refresh / invalidate

    @Test func refreshObservesAnUpgradedHost() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let spy = ProbeSpy(line: "Hermes Agent v0.19.0 (2026.7.1)")
        let cache = HermesVersionCache(defaults: defaults, probe: spy.probe)
        let ctx = localContext(home: "/tmp/scarf-cache-g")

        #expect(await cache.capabilities(for: ctx).semver?.minor == 19)
        spy.line = "Hermes Agent v0.20.0 (2026.8.3)"
        // Without invalidation the cache would keep serving 0.19.
        #expect(await cache.capabilities(for: ctx).semver?.minor == 19)
        #expect(await cache.refresh(for: ctx).semver?.minor == 20)
        #expect(cache.lastKnown(for: ctx).semver?.minor == 20, "persisted value follows the upgrade")
    }

    @Test func expiredEntryIsReProbedSoAnUpgradeIsNoticed() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let spy = ProbeSpy(line: "Hermes Agent v0.19.0 (2026.7.1)")
        // ttl 0 → every read is a miss, standing in for "an hour later".
        let cache = HermesVersionCache(defaults: defaults, ttl: 0, probe: spy.probe)
        let ctx = localContext(home: "/tmp/scarf-cache-ttl")

        _ = await cache.capabilities(for: ctx)
        #expect(cache.cached(for: ctx) == nil, "expired entry must not be served")

        spy.line = "Hermes Agent v0.20.0 (2026.8.3)"
        #expect(cache.capabilitiesSync(for: ctx).isV020OrLater)
        #expect(spy.calls == 2)
    }

    // MARK: - Store reconciliation

    @MainActor
    @Test func storeSeedsFromRememberedVersionThenReconciles() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let ctx = localContext(home: "/tmp/scarf-cache-h")

        // Previous launch saw v0.20.
        let seeded = HermesVersionCache(
            defaults: defaults,
            probe: ProbeSpy(line: "Hermes Agent v0.20.0 (2026.8.3)").probe
        )
        _ = await seeded.capabilities(for: ctx)

        // This launch: the host has been DOWNGRADED to v0.19.
        let cache = HermesVersionCache(
            defaults: defaults,
            probe: ProbeSpy(line: "Hermes Agent v0.19.0 (2026.7.1)").probe
        )
        let store = HermesCapabilitiesStore(context: ctx, cache: cache)

        // Optimistic seed before the probe answers.
        #expect(store.capabilities.isV020OrLater)
        #expect(store.isProvisional)

        await store.refresh()

        // Reconciled to ground truth — the stale v0.20 UI is withdrawn.
        #expect(store.capabilities.semver?.minor == 19)
        #expect(!store.capabilities.isV020OrLater)
        #expect(!store.isProvisional)
        #expect(!store.isLoading)
    }

    @MainActor
    @Test func storeKeepsRememberedVersionWhenProbeFails() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let ctx = localContext(home: "/tmp/scarf-cache-i")

        let seeded = HermesVersionCache(
            defaults: defaults,
            probe: ProbeSpy(line: "Hermes Agent v0.20.0 (2026.8.3)").probe
        )
        _ = await seeded.capabilities(for: ctx)

        let cache = HermesVersionCache(defaults: defaults, probe: { _ in .empty })
        let store = HermesCapabilitiesStore(context: ctx, cache: cache)
        await store.refresh()

        #expect(store.capabilities.isV020OrLater)
        #expect(store.isProvisional, "unverified value must be flagged")
        #expect(!store.isLoading)
    }

    @MainActor
    @Test func storeFallsBackToEmptyWhenNothingIsRemembered() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let ctx = localContext(home: "/tmp/scarf-cache-j")

        let cache = HermesVersionCache(defaults: defaults, probe: { _ in .empty })
        let store = HermesCapabilitiesStore(context: ctx, cache: cache)
        await store.refresh()

        #expect(store.capabilities == .empty)
        #expect(!store.isProvisional)
        #expect(!store.capabilities.isV020OrLater, "conservative default: gated UI stays hidden")
    }

    @MainActor
    @Test func storeReusesAnAlreadyProbedResultWithoutASecondProbe() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let spy = ProbeSpy(line: "Hermes Agent v0.20.0 (2026.8.3)")
        let cache = HermesVersionCache(defaults: defaults, probe: spy.probe)
        let ctx = localContext(home: "/tmp/scarf-cache-k")

        _ = await cache.capabilities(for: ctx)
        let store = HermesCapabilitiesStore(context: ctx, cache: cache)

        // Seeded synchronously from the in-process result: no loading flash,
        // not provisional.
        #expect(store.capabilities.isV020OrLater)
        #expect(!store.isProvisional)
        #expect(!store.isLoading)
        #expect(spy.calls == 1)
    }
}
