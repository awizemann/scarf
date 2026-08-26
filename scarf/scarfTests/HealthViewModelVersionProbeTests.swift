import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Exercises `HealthViewModel`'s capability-gated `hermes version` probe
/// (Phase 3 of the Hermes v0.20.5 parity work).
///
/// At v0.20.5 the bare `hermes version` subcommand was removed — an unknown
/// token now falls through to plugin discovery and spawns a chat-agent
/// turn — while `hermes --version` gained the full "commits behind" update
/// section it used to lack. `HealthViewModel.probeVersion` must:
///   - use ["--version"] once the host is known to be >= 0.20.5,
///   - use ["version"] once the host is known to be < 0.20.5,
///   - and, when the host is unknown, always try `--version` first (safe
///     on every version) and only fall back to bare `version` when that
///     output lacks the update section AND the parsed version is below
///     0.20.5 (or unparseable).
@Suite struct HealthViewModelVersionProbeTests {

    // MARK: - versionProbeArguments(for:) — known-capabilities fast path

    @Test func knownV0205HostUsesVersionFlag() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.5 (2026.8.19)")
        #expect(HealthViewModel.versionProbeArguments(for: caps) == ["--version"])
    }

    @Test func knownLaterThanV0205HostUsesVersionFlag() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.9.1)")
        #expect(HealthViewModel.versionProbeArguments(for: caps) == ["--version"])
    }

    @Test func knownPreV0205HostUsesBareVersion() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.4 (2026.8.18)")
        #expect(HealthViewModel.versionProbeArguments(for: caps) == ["version"])
    }

    @Test func knownOldHostUsesBareVersion() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")
        #expect(HealthViewModel.versionProbeArguments(for: caps) == ["version"])
    }

    // MARK: - shouldFallBackToBareVersionSubcommand(output:) — bootstrap path

    @Test func outputWithUpdateSectionNeverFallsBack() {
        // Even if a version couldn't be parsed, the presence of the update
        // section itself is proof `--version` already told us everything
        // the bare `version` subcommand would have.
        let output = "Hermes Agent v0.20.5 (2026.8.19)\n3 commits behind origin/main\n"
        #expect(HealthViewModel.shouldFallBackToBareVersionSubcommand(output: output) == false)
    }

    @Test func newHostWithoutUpdateSectionNeverFallsBack() {
        // A v0.20.5+ host that's fully up to date legitimately has no
        // "commits behind" line — that's not evidence of the old short
        // banner, so no fallback (and no accidental bare `version` chat spawn).
        let output = "Hermes Agent v0.20.5 (2026.8.19)\n"
        #expect(HealthViewModel.shouldFallBackToBareVersionSubcommand(output: output) == false)
    }

    @Test func laterThanV0205HostWithoutUpdateSectionNeverFallsBack() {
        let output = "Hermes Agent v0.21.2 (2026.9.10)\n"
        #expect(HealthViewModel.shouldFallBackToBareVersionSubcommand(output: output) == false)
    }

    @Test func oldHostShortBannerFallsBack() {
        // Real pre-0.20.5 `--version` shape: short banner, no update status,
        // with a hint pointing at the `version` subcommand.
        let output = "Hermes Agent v0.20.0\nRun 'hermes version' for update status\n"
        #expect(HealthViewModel.shouldFallBackToBareVersionSubcommand(output: output) == true)
    }

    @Test func unparseableOutputFallsBack() {
        // No recognizable "Hermes Agent vX.Y.Z" line at all — can't confirm
        // the host is new enough to trust `--version` alone, so fall back.
        let output = "command not found\n"
        #expect(HealthViewModel.shouldFallBackToBareVersionSubcommand(output: output) == true)
    }

    @Test func emptyOutputFallsBack() {
        #expect(HealthViewModel.shouldFallBackToBareVersionSubcommand(output: "") == true)
    }

    // MARK: - probeVersion(_:cache:run:) — end-to-end argv selection

    /// Records every `(args)` the injected runner was called with, keyed by
    /// nothing but call order — one host per test, so order alone identifies
    /// the call.
    private final class RunnerSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        /// Maps argv (joined by a space) to the canned output to return.
        var responses: [String: String] = [:]
        var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
        func run(_ context: ServerContext, _ args: [String]) -> String {
            lock.lock(); _calls.append(args); lock.unlock()
            return responses[args.joined(separator: " ")] ?? ""
        }
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "scarf.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func localContext(home: String) -> ServerContext {
        ServerContext.local(home: URL(fileURLWithPath: home))
    }

    @Test func probeVersionWithWarmCacheAtV0205UsesVersionFlagOnly() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let cache = HermesVersionCache(
            defaults: defaults,
            probe: { _ in .parseLine("Hermes Agent v0.20.5 (2026.8.19)") }
        )
        let context = localContext(home: "/tmp/scarf-health-probe-a")
        // Warm the cache's in-process entry, mirroring an earlier
        // `HermesCapabilitiesStore` probe on the same host.
        _ = await cache.capabilities(for: context)

        let spy = RunnerSpy()
        spy.responses["--version"] = "Hermes Agent v0.20.5 (2026.8.19)\n1 commits behind origin/main\n"
        let output = HealthViewModel.probeVersion(context, cache: cache, run: spy.run)

        #expect(spy.calls == [["--version"]])
        #expect(output.contains("commits behind"))
    }

    @Test func probeVersionWithWarmCacheBelowV0205UsesBareVersionOnly() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let cache = HermesVersionCache(
            defaults: defaults,
            probe: { _ in .parseLine("Hermes Agent v0.20.4 (2026.8.18)") }
        )
        let context = localContext(home: "/tmp/scarf-health-probe-b")
        _ = await cache.capabilities(for: context)

        let spy = RunnerSpy()
        spy.responses["version"] = "Hermes Agent v0.20.4 (2026.8.18)\n2 commits behind origin/main\n"
        let output = HealthViewModel.probeVersion(context, cache: cache, run: spy.run)

        #expect(spy.calls == [["version"]])
        #expect(output.contains("commits behind"))
    }

    @Test func probeVersionWithColdCacheAndNewHostNeverIssuesBareVersion() {
        // Cold cache (nothing has probed this host yet) — probeVersion must
        // try `--version` first. Since the response already carries the
        // update section, it must NOT fall back to bare `version`, which
        // would spawn a chat turn on a real v0.20.5+ host.
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let cache = HermesVersionCache(defaults: defaults, probe: { _ in .empty })
        let context = localContext(home: "/tmp/scarf-health-probe-c")

        let spy = RunnerSpy()
        spy.responses["--version"] = "Hermes Agent v0.20.5 (2026.8.19)\nUp to date.\n"
        let output = HealthViewModel.probeVersion(context, cache: cache, run: spy.run)

        #expect(spy.calls == [["--version"]])
        #expect(output.contains("Up to date"))
    }

    @Test func probeVersionWithColdCacheAndOldHostFallsBackToBareVersion() {
        // Cold cache, and the host turns out to be pre-0.20.5 (short banner,
        // no update section) — probeVersion must fall back to bare `version`
        // to recover the "commits behind" line, since this host still has it.
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let cache = HermesVersionCache(defaults: defaults, probe: { _ in .empty })
        let context = localContext(home: "/tmp/scarf-health-probe-d")

        let spy = RunnerSpy()
        spy.responses["--version"] = "Hermes Agent v0.20.0\nRun 'hermes version' for update status\n"
        spy.responses["version"] = "Hermes Agent v0.20.0\n5 commits behind origin/main\n"
        let output = HealthViewModel.probeVersion(context, cache: cache, run: spy.run)

        #expect(spy.calls == [["--version"], ["version"]])
        #expect(output.contains("commits behind"))
    }

    @Test func probeVersionWithColdCacheAndUnparseableOutputFallsBack() {
        // Cold cache, and `--version` returns something we can't parse at
        // all (e.g. the binary isn't on PATH, or a future format change) —
        // conservatively fall back to bare `version` rather than silently
        // losing update-status forever.
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let cache = HermesVersionCache(defaults: defaults, probe: { _ in .empty })
        let context = localContext(home: "/tmp/scarf-health-probe-e")

        let spy = RunnerSpy()
        spy.responses["--version"] = "command not found\n"
        spy.responses["version"] = "Hermes Agent v0.19.0\n1 commits behind origin/main\n"
        let output = HealthViewModel.probeVersion(context, cache: cache, run: spy.run)

        #expect(spy.calls == [["--version"], ["version"]])
        #expect(output.contains("commits behind"))
    }
}
