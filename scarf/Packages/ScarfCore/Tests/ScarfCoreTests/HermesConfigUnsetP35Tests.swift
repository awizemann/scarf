import Testing
@testable import ScarfCore

/// P35 / round-3 decision 10 — the "Host default" approvals row is wired to
/// `hermes config unset approvals.mode` behind `hasConfigUnset`, and the
/// verdict on that write is read from Hermes's OUTPUT.
@Suite("P35 — `config unset` argv and verdict")
struct HermesConfigUnsetP35Tests {

    /// `hermes_cli/subcommands/config.py:33-34` @ v2026.9.7 and `:51-54` @
    /// v2026.7.20 (the `hasConfigUnset` floor): `unset` takes exactly one
    /// positional `key` and no flags.
    ///
    /// P39 added the `--` separator: `key` is `nargs="?"`, so a key beginning
    /// with `-` was parsed as an option and exited 2.
    @Test func argvIsTheTaggedSubparserShape() {
        #expect(HermesConfigUnset.argv(key: "approvals.mode") == ["config", "unset", "--", "approvals.mode"])
    }

    @Test func successIsTheEmittersOwnLine() {
        // `print(f"✓ Unset {key} from {config_path}")` — config.py:3582.
        let out = HermesConfigUnset.judge(
            output: "✓ Unset approvals.mode from /Users/a/.hermes/config.yaml\n", exitCode: 0)
        #expect(out.succeeded)
        #expect(out.detail == nil)
    }

    /// The reason this write cannot be judged by exit code: `is_managed()` →
    /// `managed_error(...)` prints to stderr and RETURNS, so Python exits 0
    /// (`hermes_cli/config.py:3549-3551` @ v2026.9.7, `:8870-8872` @
    /// v2026.7.20). Judged by exit code this is "Saved approvals.mode".
    @Test func theManagedInstallRefusalExitsZeroAndIsStillAFailure() {
        let out = HermesConfigUnset.judge(
            output: """
            Cannot unset configuration values: this Hermes installation is managed by NixOS.
            Use your package manager to upgrade or reinstall Hermes.
            """,
            exitCode: 0
        )
        #expect(!out.succeeded)
        #expect(out.detail?.hasPrefix("Cannot unset configuration values:") == true)
    }

    @Test func theManagedKeyAndNotSetRefusalsQuoteTheirOwnLine() {
        let managedKey = HermesConfigUnset.judge(
            output: "Cannot unset 'approvals.mode': it is managed by your administrator (/etc/hermes/config.yaml) and cannot be changed. Contact your administrator to modify it.",
            exitCode: 1
        )
        #expect(!managedKey.succeeded)
        #expect(managedKey.detail?.contains("managed by your administrator") == true)

        let notSet = HermesConfigUnset.judge(
            output: "Config key not set: approvals.mode", exitCode: 1)
        #expect(!notSet.succeeded)
        #expect(notSet.detail == "Config key not set: approvals.mode")
    }

    /// Exit 0 with nothing printed is the unknown-verb case C5 forbids
    /// treating as success — the shape a pre-floor host would produce if the
    /// gate ever leaked.
    @Test func silentExitZeroIsNotSuccess() {
        #expect(!HermesConfigUnset.judge(output: "", exitCode: 0).succeeded)
    }

    /// The floor itself, four ways.
    @Test func theRowIsGatedOnHasConfigUnset() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.18.2 (2026.7.7.2)").hasConfigUnset)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)").hasConfigUnset)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasConfigUnset)
        #expect(!HermesCapabilities.empty.hasConfigUnset)
    }
}
