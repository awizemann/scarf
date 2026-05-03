import Testing
import Foundation
@testable import ScarfCore

/// Exercises the `SCARF_HERMES_HOME` test-mode override on `HermesProfileResolver`.
/// The override is the seam every E2E test relies on — without it, tests would
/// touch the user's real `~/.hermes`. Serialized because we mutate process-wide
/// environment.
///
/// **Marker file requirement.** As of v2.8 the override only activates when the
/// path contains the sentinel `HermesProfileResolver.testHomeMarkerFilename`.
/// Tests that want the override active drop the marker before `setenv`. Tests
/// that want to verify the override is rejected (relative path, missing
/// marker, empty value) skip the marker. The hardening prevents a leaked env
/// var from ever pivoting Scarf off the user's real `~/.hermes`.
@Suite(.serialized)
struct HermesProfileResolverOverrideTests {

    private static let envKey = "SCARF_HERMES_HOME"

    @Test func absoluteOverrideTakesPrecedenceWhenMarkerPresent() throws {
        let saved = ProcessInfo.processInfo.environment[Self.envKey]
        defer { restore(saved) }

        let tmp = NSTemporaryDirectory().appending("scarf-test-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: tmp + "/" + HermesProfileResolver.testHomeMarkerFilename))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        setenv(Self.envKey, tmp, 1)

        #expect(HermesProfileResolver.resolveLocalHome() == tmp)
        #expect(HermesProfileResolver.activeProfileName() == "test-override")
    }

    @Test func overrideIsIgnoredWhenMarkerMissing() throws {
        let saved = ProcessInfo.processInfo.environment[Self.envKey]
        defer { restore(saved) }

        // Real-looking dir, no marker — exactly the shape a leaked env
        // var or misconfigured launchctl plist would produce. Must NOT
        // override; must fall through to the real resolver.
        let tmp = NSTemporaryDirectory().appending("scarf-no-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        setenv(Self.envKey, tmp, 1)
        HermesProfileResolver.invalidateCache()

        let resolved = HermesProfileResolver.resolveLocalHome()
        #expect(resolved != tmp)
        #expect(resolved.hasSuffix("/.hermes") || resolved.contains("/.hermes/profiles/"))
    }

    @Test func emptyOverrideFallsThrough() {
        let saved = ProcessInfo.processInfo.environment[Self.envKey]
        defer { restore(saved) }

        setenv(Self.envKey, "", 1)
        HermesProfileResolver.invalidateCache()

        let resolved = HermesProfileResolver.resolveLocalHome()
        #expect(!resolved.isEmpty)
        #expect(resolved.hasSuffix("/.hermes") || resolved.contains("/.hermes/profiles/"))
    }

    @Test func relativeOverrideIsRejected() {
        let saved = ProcessInfo.processInfo.environment[Self.envKey]
        defer { restore(saved) }

        setenv(Self.envKey, "relative/path", 1)
        HermesProfileResolver.invalidateCache()

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

    @Test func overrideBypassesCacheWhenMarkerPresent() throws {
        let saved = ProcessInfo.processInfo.environment[Self.envKey]
        defer { restore(saved) }

        let first = NSTemporaryDirectory().appending("scarf-cache-bypass-1-\(UUID().uuidString)")
        let second = NSTemporaryDirectory().appending("scarf-cache-bypass-2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: first + "/" + HermesProfileResolver.testHomeMarkerFilename))
        try Data().write(to: URL(fileURLWithPath: second + "/" + HermesProfileResolver.testHomeMarkerFilename))
        defer {
            try? FileManager.default.removeItem(atPath: first)
            try? FileManager.default.removeItem(atPath: second)
        }

        setenv(Self.envKey, first, 1)
        #expect(HermesProfileResolver.resolveLocalHome() == first)

        // Flip env var without invalidating the cache. Override is read
        // fresh on every call, so the new value takes effect immediately.
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
