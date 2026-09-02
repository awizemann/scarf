import Testing
@testable import ScarfCore

/// Capability-aware display defaults for `checkpoints.*` and `delegation.*`.
///
/// Both surfaces had their server-side defaults changed by a Hermes release
/// (checkpoints at v0.21: enabled `true`→`false`, max_snapshots `50`→`20`;
/// delegation at v0.20.4: max_iterations `50`→`250`,
/// max_concurrent_children `3`→`10`). Scarf used to bake ONE release's
/// defaults into the parse, so an absent key displayed a value the connected
/// host did not actually use. Same sentinel + `display*(capabilities:)`
/// resolver shape as `displayMaxTurns` / `displayGatewayTurnLeaseTimeout`.
struct HermesCheckpointDelegationDefaultsTests {

    private let v021 = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
    private let v0206 = HermesCapabilities.parseLine("Hermes Agent v0.20.6 (2026.8.27)")
    private let v0204 = HermesCapabilities.parseLine("Hermes Agent v0.20.4 (2026.8.16)")
    private let v0200 = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)")

    // MARK: checkpoints

    @Test func checkpointKeysAbsentParseToSentinels() {
        let cfg = HermesConfig(yaml: "")
        #expect(cfg.checkpoints.enabled == nil)
        #expect(cfg.checkpoints.maxSnapshots == 0)
    }

    @Test func checkpointDisplayDefaultsAreHostAware() {
        let absent = HermesConfig(yaml: "")
        // v0.21 made auto-checkpointing opt-in and shrank the ring.
        #expect(absent.displayCheckpointsEnabled(capabilities: v021) == false)
        #expect(absent.displayCheckpointsMaxSnapshots(capabilities: v021) == 20)
        // Every older supported host keeps the old defaults.
        #expect(absent.displayCheckpointsEnabled(capabilities: v0206) == true)
        #expect(absent.displayCheckpointsMaxSnapshots(capabilities: v0206) == 50)
        #expect(absent.displayCheckpointsEnabled(capabilities: v0200) == true)
        // Unknown host resolves to the older behavior.
        #expect(absent.displayCheckpointsEnabled(capabilities: .empty) == true)
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
        #expect(HermesConfig(yaml: "").displayCheckpointsEnabled(capabilities: v0206) == true)
    }

    // MARK: delegation

    @Test func delegationKeysAbsentParseToSentinels() {
        let cfg = HermesConfig(yaml: "")
        #expect(cfg.delegation.maxIterations == 0)
        #expect(cfg.delegation.maxConcurrentChildren == 0)
    }

    @Test func delegationDisplayDefaultsAreHostAware() {
        let absent = HermesConfig(yaml: "")
        // Migrations 36/37 raised both at v0.20.4.
        #expect(absent.displayDelegationMaxIterations(capabilities: v0204) == 250)
        #expect(absent.displayDelegationMaxConcurrentChildren(capabilities: v0204) == 10)
        #expect(absent.displayDelegationMaxIterations(capabilities: v021) == 250)
        // Pre-v0.20.4 hosts still run the old, much lower ceilings.
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
