import Testing
@testable import ScarfCore

/// Capability-aware display defaults for `checkpoints.*` and `delegation.*`.
///
/// Floors below are pinned to the TAGGED Hermes source, not to release notes:
///
/// - `checkpoints.enabled` — `False` on every supported host. `cli.py` reads
///   `cp_cfg.get("enabled", False)` at v2026.3.30/v0.6.0 `:1163` (the
///   supported minimum) straight through v2026.8.31/v0.21.0 `:5501`. There
///   was never a `true` era inside the supported range.
/// - `checkpoints.max_snapshots` — `50` → `20` at v2026.5.7/v0.13.0
///   `cli.py:2311`; v2026.4.30/v0.12.0 `cli.py:2070` is the last `50`.
/// - `delegation.max_iterations` / `max_concurrent_children` — `50`/`3` →
///   `250`/`10` at v2026.8.16/v0.20.2 (`hermes_cli/config_defaults.py:1821`
///   and `:1846`, plus `config_migrations.py:757`/`:787` = migrations 36/37).
///   v2026.8.13/v0.20.1 `config_defaults.py:1764`/`:1789` is the last `50`/`3`.
///
/// Scarf used to bake ONE release's defaults into the parse, so an absent key
/// displayed a value the connected host did not actually use. Same sentinel +
/// `display*(capabilities:)` resolver shape as `displayMaxTurns` /
/// `displayGatewayTurnLeaseTimeout`.
struct HermesCheckpointDelegationDefaultsTests {

    private let v021 = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
    private let v0206 = HermesCapabilities.parseLine("Hermes Agent v0.20.6 (2026.8.27)")
    private let v0204 = HermesCapabilities.parseLine("Hermes Agent v0.20.4 (2026.8.18)")
    private let v0202 = HermesCapabilities.parseLine("Hermes Agent v0.20.2 (2026.8.16)")
    private let v0201 = HermesCapabilities.parseLine("Hermes Agent v0.20.1 (2026.8.13)")
    private let v0200 = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)")
    private let v013 = HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)")
    private let v012 = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")
    private let v06 = HermesCapabilities.parseLine("Hermes Agent v0.6.0 (2026.3.30)")

    // MARK: checkpoints

    @Test func checkpointKeysAbsentParseToSentinels() {
        let cfg = HermesConfig(yaml: "")
        #expect(cfg.checkpoints.enabled == nil)
        #expect(cfg.checkpoints.maxSnapshots == 0)
    }

    @Test func checkpointDisplayDefaultsAreHostAware() {
        let absent = HermesConfig(yaml: "")
        // `enabled` is false on EVERY supported host — no version branch.
        #expect(absent.displayCheckpointsEnabled(capabilities: v021) == false)
        #expect(absent.displayCheckpointsEnabled(capabilities: v0206) == false)
        #expect(absent.displayCheckpointsEnabled(capabilities: v0200) == false)
        #expect(absent.displayCheckpointsEnabled(capabilities: v013) == false)
        #expect(absent.displayCheckpointsEnabled(capabilities: v06) == false)
        #expect(absent.displayCheckpointsEnabled(capabilities: .empty) == false)
        // `max_snapshots` floor is v0.13.0, not v0.21.
        #expect(absent.displayCheckpointsMaxSnapshots(capabilities: v021) == 20)
        #expect(absent.displayCheckpointsMaxSnapshots(capabilities: v0206) == 20)
        #expect(absent.displayCheckpointsMaxSnapshots(capabilities: v0200) == 20)
        #expect(absent.displayCheckpointsMaxSnapshots(capabilities: v013) == 20)
        // Pre-floor branch is live: the supported minimum is v0.6.0.
        #expect(absent.displayCheckpointsMaxSnapshots(capabilities: v012) == 50)
        #expect(absent.displayCheckpointsMaxSnapshots(capabilities: v06) == 50)
        // Unknown host resolves to the older behavior.
        #expect(absent.displayCheckpointsMaxSnapshots(capabilities: .empty) == 50)
    }

    @Test func explicitCheckpointValuesWinOnEveryHost() {
        let cfg = HermesConfig(yaml: """
        checkpoints:
          enabled: true
          max_snapshots: 7
        """)
        #expect(cfg.displayCheckpointsEnabled(capabilities: v021) == true)
        #expect(cfg.displayCheckpointsMaxSnapshots(capabilities: v021) == 7)
        #expect(cfg.displayCheckpointsEnabled(capabilities: .empty) == true)
    }

    /// An explicit `false` must survive — the whole point of the optional
    /// sentinel. A plain `Bool` default of `true` could not express it and a
    /// plain `false` default could not tell "off" from "absent".
    @Test func explicitFalseIsDistinctFromAbsent() {
        let off = HermesConfig(yaml: """
        checkpoints:
          enabled: false
        """)
        #expect(off.checkpoints.enabled == false)
        #expect(off.displayCheckpointsEnabled(capabilities: v0206) == false)
        // Absent still reads as the host default (also false) — the parse
        // keeps them distinct even though they resolve alike.
        #expect(HermesConfig(yaml: "").checkpoints.enabled == nil)
    }

    // MARK: delegation

    @Test func delegationKeysAbsentParseToSentinels() {
        let cfg = HermesConfig(yaml: "")
        #expect(cfg.delegation.maxIterations == 0)
        #expect(cfg.delegation.maxConcurrentChildren == 0)
    }

    @Test func delegationDisplayDefaultsAreHostAware() {
        let absent = HermesConfig(yaml: "")
        // Migrations 36/37 raised both at v0.20.2 (tag v2026.8.16), NOT
        // v0.20.4 — v0.20.2 and v0.20.3 hosts already run 250/10.
        #expect(absent.displayDelegationMaxIterations(capabilities: v0202) == 250)
        #expect(absent.displayDelegationMaxConcurrentChildren(capabilities: v0202) == 10)
        #expect(absent.displayDelegationMaxIterations(capabilities: v0204) == 250)
        #expect(absent.displayDelegationMaxConcurrentChildren(capabilities: v0204) == 10)
        #expect(absent.displayDelegationMaxIterations(capabilities: v021) == 250)
        // Pre-v0.20.2 hosts still run the old, much lower ceilings.
        #expect(absent.displayDelegationMaxIterations(capabilities: v0201) == 50)
        #expect(absent.displayDelegationMaxConcurrentChildren(capabilities: v0201) == 3)
        #expect(absent.displayDelegationMaxIterations(capabilities: v0200) == 50)
        #expect(absent.displayDelegationMaxConcurrentChildren(capabilities: v0200) == 3)
        #expect(absent.displayDelegationMaxIterations(capabilities: .empty) == 50)
        #expect(absent.displayDelegationMaxConcurrentChildren(capabilities: .empty) == 3)
    }

    @Test func explicitDelegationValuesWinOnEveryHost() {
        let cfg = HermesConfig(yaml: """
        delegation:
          max_iterations: 12
          max_concurrent_children: 2
        """)
        #expect(cfg.displayDelegationMaxIterations(capabilities: v021) == 12)
        #expect(cfg.displayDelegationMaxConcurrentChildren(capabilities: v021) == 2)
        #expect(cfg.displayDelegationMaxIterations(capabilities: .empty) == 12)
    }
}
