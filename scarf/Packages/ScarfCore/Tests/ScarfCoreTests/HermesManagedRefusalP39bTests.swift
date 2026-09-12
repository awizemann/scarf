import Foundation
import Testing
@testable import ScarfCore

/// The round-4 review of P39's own two commits. Each test here fails against
/// the code as P39 shipped it.
@Suite("P39b — anchored refusals, partial writes, the marker floor")
struct HermesAnchoredRefusalP39bTests {

    /// HIGH. `set_config_value` ECHOES the user's value on its success line
    /// (`✓ Set {key} = {value} in {config_path}`, `hermes_cli/config.py:3521`
    /// @ v2026.9.7). As bare substrings the failure markers matched that echo,
    /// and because this verdict runs `failureWins: true` a real write was
    /// reported as a refusal — for every QuickCommands free-text field and all
    /// fifteen platform-setup forms.
    @Test(arguments: [
        "is managed by",
        "Cannot set",
        "Cannot unset",
        "Cannot save configuration",
        "Invalid config key:",
    ])
    func anEchoedValueContainingAFailureMarkerIsStillASuccess(_ poison: String) {
        let out = HermesConfigSet.judge(
            output: "✓ Set quick_commands.note.command = echo '\(poison)' in /Users/a/.hermes/config.yaml",
            exitCode: 0
        )
        #expect(out.succeeded)
        #expect(out.warning == nil)
    }

    /// The same asymmetry on `config unset`, whose success line quotes the key
    /// the user chose (`✓ Unset {key} from {config_path}`, `:3582`).
    @Test func anEchoedKeyContainingAFailureMarkerUnsetsCleanly() {
        let out = HermesConfigUnset.judge(
            output: "✓ Unset quick_commands.Cannot unset.command from /Users/a/.hermes/config.yaml",
            exitCode: 0
        )
        #expect(out.succeeded)
    }

    /// And the real refusal, at column 0, still wins — anchoring must not buy
    /// the false positive back by losing the true one.
    @Test func theRealRefusalAtColumnZeroStillFails() {
        let out = HermesConfigSet.judge(
            output: """
            Cannot set configuration values: this Hermes installation is managed by nixos.
            Use your package manager to upgrade or reinstall Hermes.
            """,
            exitCode: 0
        )
        #expect(out.succeeded == false)
        #expect(out.detail == "Cannot set configuration values: this Hermes installation is managed by nixos.")
    }

    /// `plugins update` prints the raw `git pull` output and the post-update
    /// scan report (`hermes_cli/plugins_cmd.py:829`, `:844`) — text Hermes does
    /// not author — and judges with `failureWins`. A plugin whose scan finding
    /// or commit message says "is managed by" must not read as a refusal.
    @Test func aScanReportQuotingTheManagedPhraseDoesNotFlipAnUpdate() {
        let out = HermesCLIVerdict.judge(
            output: """
            From github.com/example/weather
             * branch            main       -> FETCH_HEAD
            Scan: SKILL.md says the data source is managed by the vendor.
            ✓ Plugin weather updated.
            """,
            exitCode: 0,
            successMarkers: HermesCLIMarkers.pluginsUpdateSuccess,
            failureMarkers: HermesCLIMarkers.pluginsUpdateFailure,
            anchoredFailureMarkers: HermesCLIMarkers.managedRefusalAnchored,
            failureWins: true
        )
        #expect(out.succeeded)
    }

    @Test func theManagedRefusalUnderAPluginStillWins() {
        let out = HermesCLIVerdict.judge(
            output: """
            Cannot save configuration: this Hermes installation is managed by nixos.
            ✓ Plugin weather updated.
            """,
            exitCode: 0,
            successMarkers: HermesCLIMarkers.pluginsUpdateSuccess,
            failureMarkers: HermesCLIMarkers.pluginsUpdateFailure,
            anchoredFailureMarkers: HermesCLIMarkers.managedRefusalAnchored,
            failureWins: true
        )
        #expect(out.succeeded == false)
    }

    /// A glyph-prefixed refusal is still anchored — ``HermesCLIVerdict/unglyphed``
    /// strips the `✗ ` `_exit_invalid` prints (`hermes_cli/config.py:3422-3424`).
    @Test func aGlyphPrefixedRefusalIsStillAnchored() {
        let out = HermesConfigSet.judge(
            output: "✗ Invalid config key: 'agent.' (empty or surrounding whitespace).",
            exitCode: 1
        )
        #expect(out.succeeded == false)
        #expect(out.detail?.contains("Invalid config key:") == true)
    }
}

/// The tenth exit-0 arm: config.yaml written, the `.env` mirror refused.
@Suite("P39b — the `.env` mirror partial write")
struct HermesConfigMirrorP39bTests {

    static let refusal = "Cannot set TERMINAL_ENV: it is managed by your administrator (/etc/hermes/.env) and cannot be changed."

    /// `save_env_value` → `_env_write_blocked`'s managed-SCOPE arm
    /// (`hermes_cli/config.py:3511`, `:2574-2578`, `:2560-2565`) refuses the
    /// mirror and returns; `:3521` prints the success line anyway. The
    /// config.yaml write DID land, so this is a partial write, not a failure.
    @Test func aRefusedEnvMirrorIsAPartialWriteNotAFailure() throws {
        let out = HermesConfigSet.judge(
            output: """
            \(Self.refusal)
            ✓ Set terminal.env = tmux in /Users/a/.hermes/config.yaml
            """,
            exitCode: 0
        )
        #expect(out.succeeded)
        #expect(out.detail == nil)
        let warning = try #require(out.warning)
        #expect(warning.contains("the .env mirror was refused"))
        #expect(warning.contains(Self.refusal))
    }

    /// `unset_config_value`'s twin, through `remove_env_value`
    /// (`:3574-3576` → `:2610-2612`).
    @Test func aRefusedEnvMirrorOnUnsetIsAlsoPartial() {
        let out = HermesConfigUnset.judge(
            output: """
            Cannot remove TERMINAL_ENV: it is managed by your administrator (/etc/hermes/.env) and cannot be changed.
            ✓ Unset terminal.env from /Users/a/.hermes/config.yaml
            """,
            exitCode: 0
        )
        #expect(out.succeeded)
        #expect(out.warning != nil)
    }

    /// The OTHER exit-0 shape with both lines: the `_is_env_config_key`
    /// branch (`:3461-3468`), where the `.env` write was the only write. That
    /// one stays a failure — nothing was saved.
    @Test func aRefusedEnvOnlyWriteIsStillAFailure() {
        let out = HermesConfigSet.judge(
            output: """
            Cannot set OPENAI_API_KEY: it is managed by your administrator (/etc/hermes/.env) and cannot be changed.
            ✓ Set openai_api_key in /Users/a/.hermes/.env
            """,
            exitCode: 0
        )
        #expect(out.succeeded == false)
        #expect(out.warning == nil)
    }

    /// The whole-command managed refusal returns BEFORE any success line, so
    /// it can never look partial.
    @Test func theWholeCommandRefusalIsNeverPartial() {
        let out = HermesConfigSet.judge(
            output: "Cannot set configuration values: this Hermes installation is managed by nixos.",
            exitCode: 0
        )
        #expect(out.succeeded == false)
        #expect(out.warning == nil)
    }

    @Test func theDiscriminatorIsTheFileHermesNames() {
        #expect(HermesConfigMirror.namesConfigFile("✓ Set a.b = c in /Users/a/.hermes/config.yaml"))
        #expect(HermesConfigMirror.namesConfigFile("✓ Set a in /Users/a/.hermes/.env") == false)
    }
}

/// The `.managed` marker's contents are only READ from v0.20.5 on.
@Suite("P39b — the managed-marker contents floor")
struct HermesManagedMarkerFloorP39bTests {

    static let v0205 = HermesCapabilities.parseLine("Hermes Agent v0.20.5 (2026.8.19)")
    static let v0204 = HermesCapabilities.parseLine("Hermes Agent v0.20.4 (2026.8.18)")
    static let v0211 = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
    static let v02051 = HermesCapabilities.parseLine("Hermes Agent v0.20.5.1 (2026.8.19)")

    // The four-test flag pattern: parse, all-on, prior-host degradation,
    // patch-still-on.

    @Test func theFlagIsOnAtItsFloorTag() {
        #expect(Self.v0205.hasManagedMarkerContents)
    }

    @Test func theFlagIsOnAtTheTargetTag() {
        #expect(Self.v0211.hasManagedMarkerContents)
    }

    /// v2026.8.18 and every tag before it end `get_managed_system` with
    /// `if managed_marker.exists(): return "NixOS"` — no read at all.
    @Test func thePriorHostDoesNotReadTheMarker() {
        #expect(Self.v0204.hasManagedMarkerContents == false)
        #expect(HermesCapabilities.empty.hasManagedMarkerContents == false)
    }

    @Test func aPatchReleaseKeepsTheFlagOn() {
        #expect(Self.v02051.hasManagedMarkerContents)
    }

    /// The behavioural half: below the floor a `brew` marker means MANAGED,
    /// because Hermes never opens the file. Above it, it means not managed.
    @Test(arguments: ["brew", "homebrew", "guix", "", "true"])
    func belowTheFloorAnyPresentMarkerIsManaged(_ raw: String) {
        #expect(HermesManagedInstall.system(fromMarker: raw, readsMarkerContents: false) == "NixOS")
    }

    @Test func belowTheFloorAnAbsentMarkerIsStillNotManaged() {
        #expect(HermesManagedInstall.system(fromMarker: nil, readsMarkerContents: false) == nil)
    }

    @Test func aboveTheFloorBrewMeansNotManaged() {
        #expect(HermesManagedInstall.system(fromMarker: "brew", readsMarkerContents: true) == nil)
    }

    /// The probe threads capabilities through, so the cache's answer for one
    /// marker differs by host version.
    @Test func theCacheHonoursTheFloor() {
        let old = HermesManagedInstallCache(probe: { _ in "brew" })
        let new = HermesManagedInstallCache(probe: { _ in "brew" })
        let ctx = Self.host(home: "/tmp/p39b-home")
        #expect(old.managedInstall(for: ctx, capabilities: Self.v0204).isManaged)
        #expect(new.managedInstall(for: ctx, capabilities: Self.v0211).isManaged == false)
    }

    static func host(home: String) -> ServerContext {
        ServerContext(
            id: UUID(), displayName: "box",
            kind: .ssh(SSHConfig(host: "box", remoteHome: home))
        )
    }
}

/// The production probe, over a real temp home and a local `ServerContext`.
@Suite("P39b — `transportProbe` over a real filesystem")
struct HermesTransportProbeP39bTests {

    static let modern = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")

    @Test func anAbsentMarkerReadsAsNil() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(HermesManagedInstallCache.transportProbe(Self.local(home: home)) == nil)
    }

    /// An EMPTY marker file is present, and `get_managed_system` resolves an
    /// empty marker to the legacy system (`:288-289`) — i.e. managed.
    @Test func anEmptyMarkerFileIsPresentAndMeansManaged() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try "".write(toFile: home + "/.managed", atomically: true, encoding: .utf8)

        let ctx = Self.local(home: home)
        let raw = HermesManagedInstallCache.transportProbe(ctx)
        #expect(raw == "")
        #expect(HermesManagedInstall.system(fromMarker: raw, readsMarkerContents: true) == "nixos")
    }

    @Test func aMarkerNamingASystemReadsItsContents() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try "home-manager\n".write(toFile: home + "/.managed", atomically: true, encoding: .utf8)

        let raw = HermesManagedInstallCache.transportProbe(Self.local(home: home))
        #expect(HermesManagedInstall.system(fromMarker: raw, readsMarkerContents: true) == "home-manager")
    }

    /// Present but unreadable (`chmod 000`). Hermes catches the `OSError` and
    /// treats the marker as EMPTY (`hermes_cli/config.py:285-286`), which
    /// resolves to managed — the probe must not report "absent".
    @Test func anUnreadableMarkerIsPresentAndTheretoreManaged() throws {
        let home = try Self.makeHome()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: home + "/.managed")
            try? FileManager.default.removeItem(atPath: home)
        }
        let marker = home + "/.managed"
        try "nixos".write(toFile: marker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: marker)

        // Root can read anything; the case under test does not exist there.
        try #require(getuid() != 0)

        let raw = HermesManagedInstallCache.transportProbe(Self.local(home: home))
        #expect(raw == "")
        #expect(HermesManagedInstall.system(fromMarker: raw, readsMarkerContents: true) == "nixos")
    }

    /// A probe that outruns its timeout must not hang the Settings load, must
    /// fall OPEN (the verdicts still catch every refusal, and a wrong
    /// read-only lock has no recovery), and must not be memoized — the next
    /// surface that asks deserves a fresh attempt.
    ///
    /// P39c: "not cached" is proved by ASKING AGAIN. The old assertion read
    /// `cached(for:).isManaged == false`, which an empty cache satisfies too —
    /// it could not tell "nothing was memoized" from "`.notManaged` was
    /// memoized", which is the whole point of the test.
    @Test func aProbeThatOutrunsTheTimeoutFallsOpenAndIsNotCached() {
        let release = Self.Release()
        let cache = HermesManagedInstallCache(
            probe: { _ in
                release.waitForRelease()
                return "nixos"
            },
            timeout: 0.05
        )
        let ctx = Self.local(home: "/tmp/p39b-timeout")

        // First ask: the probe is still blocked, so the answer falls open.
        let answer = cache.managedInstall(for: ctx, capabilities: Self.modern)
        #expect(answer.isManaged == false)

        // Let the probe answer, then ask again. If the fall-open had been
        // memoized this stays `.notManaged` for the life of the process.
        release.release()
        let second = cache.managedInstall(for: ctx, capabilities: Self.modern)
        #expect(second.isManaged)
        #expect(second.system == "nixos")
        // And THAT one is cached.
        #expect(cache.cached(for: ctx, capabilities: Self.modern).isManaged)
        cache.invalidate(for: ctx)
    }

    /// A gate the probe closure can block on without a semaphore's
    /// one-signal-per-wait arithmetic: every call after ``release()`` returns
    /// at once.
    final class Release: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false

        func release() {
            lock.lock(); released = true; lock.unlock()
        }

        private var isReleased: Bool {
            lock.lock(); defer { lock.unlock() }; return released
        }

        /// Bounded so a regression fails the suite instead of hanging it.
        func waitForRelease() {
            for _ in 0..<10_000 where !isReleased { usleep(1_000) }
        }
    }

    /// The default ceiling is a named product choice, not a literal buried in
    /// the probe.
    @Test func theTimeoutIsNamedAndPositive() {
        #expect(HermesManagedInstallCache.probeTimeout == 5)
    }

    static func makeHome() throws -> String {
        let home = NSTemporaryDirectory() + "p39b-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)
        return home
    }

    static func local(home: String) -> ServerContext {
        ServerContext.local(home: URL(fileURLWithPath: home))
    }
}

/// The iOS twin of the Mac's managed-host lock. P39 gave iOS the verdicts and
/// not the probe; the round-4 review called that out and Alan's call was to do
/// it now.
@Suite("P39b — the iOS managed-host lock")
@MainActor
struct IOSManagedHostP39bTests {

    static func vm() -> IOSSettingsViewModel {
        IOSSettingsViewModel(context: ServerContext(
            id: UUID(), displayName: "box",
            kind: .ssh(SSHConfig(host: "box", remoteHome: "/home/a/.hermes"))
        ))
    }

    @Test func anUnmanagedHostHasNoBannerAndIsNotLocked() {
        let model = Self.vm()
        #expect(model.isManagedHost == false)
        #expect(model.managedBannerText == nil)
    }

    /// The same sentence the Mac shows, naming the package manager — "use
    /// your package manager" is useless without it.
    @Test func aManagedHostGetsOneBannerNamingTheSystem() throws {
        let model = Self.vm()
        model.managedInstall = HermesManagedInstall(system: "home-manager")
        #expect(model.isManagedHost)
        let text = try #require(model.managedBannerText)
        #expect(text.contains("home-manager"))
        #expect(text.contains("read-only"))
    }

    /// Reaching the write at all means something got past the locked editor.
    /// It must refuse with the banner's sentence, not spawn a process whose
    /// only outcome is Hermes's own exit-0 refusal.
    @Test func aWriteOnAManagedHostIsRefusedBeforeAnythingIsSpawned() async {
        let model = Self.vm()
        model.managedInstall = HermesManagedInstall(system: "nixos")
        await #expect(throws: SettingsSaveError.self) {
            try await model.saveValue(key: "display.streaming", value: "true")
        }
        await #expect(throws: SettingsSaveError.self) {
            try await model.unsetValue(key: "display.streaming")
        }
        #expect(model.isSaving == false)
    }

    /// And the probe is actually wired into `load()` — the half the round-4
    /// review found missing. A source scan, because driving `load()` needs a
    /// reachable host.
    @Test func theIosViewModelConsumesTheSharedProbeCache() throws {
        let source = try String(contentsOf: Self.packageRoot
            .appendingPathComponent("Sources/ScarfCore/ViewModels/IOSSettingsViewModel.swift"),
            encoding: .utf8)
        #expect(source.contains("HermesManagedInstallCache.shared.managedInstall(for:"))
        #expect(source.contains("hasManagedMarkerContents") || source.contains("capabilitiesSync"))
    }

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfCore/
    }
}
