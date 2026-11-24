import Testing
import Foundation
@testable import ScarfCore

/// gh#150: ScarfGo memoises a positive model preflight per server so chat
/// start/resume skips the config read; negatives must always re-check.
@Suite struct ModelPreflightCacheTests {

    @Test func configuredVerdictIsRemembered() {
        let cache = ModelPreflightCache()
        let server = ServerID()
        #expect(!cache.isKnownConfigured(server))
        cache.record(.configured, for: server)
        #expect(cache.isKnownConfigured(server))
    }

    @Test(arguments: [ModelPreflight.Result.missingModel, .missingProvider, .missingBoth])
    func negativeVerdictIsNotRemembered(_ result: ModelPreflight.Result) {
        let cache = ModelPreflightCache()
        let server = ServerID()
        cache.record(result, for: server)
        #expect(!cache.isKnownConfigured(server))
    }

    @Test func negativeVerdictClearsAnEarlierPositive() {
        let cache = ModelPreflightCache()
        let server = ServerID()
        cache.record(.configured, for: server)
        cache.record(.missingModel, for: server)
        #expect(!cache.isKnownConfigured(server))
    }

    @Test func invalidateDropsOnlyThatServer() {
        let cache = ModelPreflightCache()
        let a = ServerID(), b = ServerID()
        cache.record(.configured, for: a)
        cache.record(.configured, for: b)
        cache.invalidate(a)
        #expect(!cache.isKnownConfigured(a))
        #expect(cache.isKnownConfigured(b))
    }

    @Test func entriesArePerServer() {
        let cache = ModelPreflightCache()
        let a = ServerID(), b = ServerID()
        cache.record(.configured, for: a)
        #expect(!cache.isKnownConfigured(b))
    }
}
