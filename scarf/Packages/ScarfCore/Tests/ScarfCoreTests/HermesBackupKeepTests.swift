import Testing
@testable import ScarfCore

/// v0.21.2 target bump (2026-09-14): the one behaviour change Scarf answers.
/// `hermes backup` defaults to `--keep 3` from v2026.9.11 and prunes older
/// `~/hermes-backup-*.zip` files; Scarf passes `--keep 0` where the flag
/// parses and nothing below the floor, where it would be an argparse error.
@Suite struct HermesBackupKeepTests {
    // MARK: the v0.21.2 four-test group (parse, all-on, degradation, patch-still-on)

    @Test func parseV0212ReleaseLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 21, patch: 2))
        #expect(caps.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 9, day: 11))
        #expect(caps.detected)
    }

    @Test func v0212FlagsAllOnForV0212Host() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")
        #expect(caps.isV0212OrLater)
        #expect(caps.hasBackupKeep)
    }

    @Test func v0211HostHidesEveryV0212Flag() {
        // `keep` occurs zero times in `hermes_cli/subcommands/backup.py` @ v2026.9.7.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        #expect(caps.isV0211OrLater)
        #expect(!caps.isV0212OrLater)
        #expect(!caps.hasBackupKeep)
        #expect(!HermesCapabilities.empty.hasBackupKeep)
    }

    @Test func laterReleasesStillEnableTheV0212Flag() {
        for line in ["Hermes Agent v0.21.3 (2026.9.20)", "Hermes Agent v0.22.0 (2026.10.1)", "Hermes Agent v1.0.0 (2027.1.1)"] {
            #expect(HermesCapabilities.parseLine(line).hasBackupKeep, "\(line)")
        }
    }

    /// A v0.21.2 host keeps every v0.21.1 flag: patches do not roll gates back.
    @Test func v0212HostStillEnablesEveryV0211Flag() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")
        #expect(caps.isV0211OrLater)
        #expect(caps.hasPluginsCompat)
        #expect(caps.hasCronCreatePaused)
        #expect(caps.hasCronFailureDeliver)
        #expect(caps.hasCronDispatchDiagnostics)
        #expect(caps.hasKanbanCompletionContract)
        #expect(caps.hasAuthPriority)
        #expect(caps.hasMCPOAuthFlow)
        #expect(caps.hasSessionsExportNoRedact)
        #expect(caps.hasServiceTierBoundedModes)
        #expect(caps.hasSharedMetricsSend)
        #expect(caps.hasPerplexityWebBackend)
    }

    // MARK: the argv

    @Test func aV0212HostGetsKeepZero() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")
        #expect(HermesBackupVerdict.argv(capabilities: caps) == ["backup", "--keep", "0"])
    }

    @Test func olderAndUndetectedHostsGetTheBareVerb() {
        let older = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        #expect(HermesBackupVerdict.argv(capabilities: older) == ["backup"])
        #expect(HermesBackupVerdict.argv(capabilities: .empty) == ["backup"])
        #expect(HermesBackupVerdict.baseArgv == ["backup"])
    }
}
