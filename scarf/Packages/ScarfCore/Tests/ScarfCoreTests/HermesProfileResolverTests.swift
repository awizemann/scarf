import Testing
import Foundation
@testable import ScarfCore

/// Exercises the `SCARF_HERMES_HOME` test-mode override on `HermesProfileResolver`.
/// The override is the seam every E2E test relies on — without it, tests would
/// touch the user's real `~/.hermes`. Serialized because we mutate process-wide
/// environment.
@Suite(.serialized)
struct HermesProfileResolverOverrideTests {

    private static let envKey = "SCARF_HERMES_HOME"

    @Test func absoluteOverrideTakesPrecedence() {
        let saved = ProcessInfo.processInfo.environment[Self.envKey]
        defer { restore(saved) }

        let tmp = NSTemporaryDirectory().appending("scarf-test-home-\(UUID().uuidString)")
        setenv(Self.envKey, tmp, 1)

        #expect(HermesProfileResolver.resolveLocalHome() == tmp)
        #expect(HermesProfileResolver.activeProfileName() == "test-override")
    }

    @Test func emptyOverrideFallsThrough() {
        let saved = ProcessInfo.processInfo.environment[Self.envKey]
        defer { restore(saved) }

        setenv(Self.envKey, "", 1)
        HermesProfileResolver.invalidateCache()

        // Empty override is treated as "no override" — fall through to
        // the normal profile resolver. Result must be the user's real
        // home (or whatever the resolver chose), never the empty string.
        let resolved = HermesProfileResolver.resolveLocalHome()
        #expect(!resolved.isEmpty)
        #expect(resolved.hasSuffix("/.hermes") || resolved.contains("/.hermes/profiles/"))
    }

    @Test func relativeOverrideIsRejected() {
        let saved = ProcessInfo.processInfo.environment[Self.envKey]
        defer { restore(saved) }

        setenv(Self.envKey, "relative/path", 1)
        HermesProfileResolver.invalidateCache()

        // Relative path → ignored, fall back to default. We don't want
        // a typo to land Scarf reading from `cwd/relative/path`.
        let resolved = HermesProfileResolver.resolveLocalHome()
        #expect(!resolved.hasSuffix("relative/path"))
    }

    @Test func unsetOverrideUsesProfileResolver() {
        let saved = ProcessInfo.processInfo.environment[Self.envKey]
        defer { restore(saved) }

        unsetenv(Self.envKey)
        HermesProfileResolver.invalidateCache()

        let resolved = HermesProfileResolver.resolveLocalHome()
        #expect(!resolved.isEmpty)
    }

    @Test func overrideBypassesCache() {
        let saved = ProcessInfo.processInfo.environment[Self.envKey]
        defer { restore(saved) }

        let first = NSTemporaryDirectory().appending("scarf-cache-bypass-1-\(UUID().uuidString)")
        let second = NSTemporaryDirectory().appending("scarf-cache-bypass-2-\(UUID().uuidString)")

        setenv(Self.envKey, first, 1)
        #expect(HermesProfileResolver.resolveLocalHome() == first)

        // Flip the env var without invalidating the cache. The override
        // path reads env on every call, so the new value takes effect
        // immediately — that's the property tests rely on when sweeping
        // multiple isolated homes across test methods.
        setenv(Self.envKey, second, 1)
        #expect(HermesProfileResolver.resolveLocalHome() == second)
    }

    private func restore(_ saved: String?) {
        if let saved {
            setenv(Self.envKey, saved, 1)
        } else {
            unsetenv(Self.envKey)
        }
        HermesProfileResolver.invalidateCache()
    }
}
