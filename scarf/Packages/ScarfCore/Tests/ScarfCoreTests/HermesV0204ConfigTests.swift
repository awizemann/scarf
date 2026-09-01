import Testing
import Foundation
@testable import ScarfCore

/// Phase 7 of the Hermes v0.20.4 parity cycle — stale delegation defaults
/// (`max_iterations` 50→250, new `max_concurrent_children`) and the new
/// `gateway.multiplex_profile_allowlist` true-optional list parse.
@Suite("Hermes v0.20.4 config parsing")
struct HermesV0204ConfigTests {

    // MARK: - Delegation defaults (HermesConfig+YAML.swift)

    @Test func delegationMaxIterationsDefaultsTo250WhenUnset() {
        let cfg = HermesConfig(yaml: "")
        #expect(cfg.delegation.maxIterations == 250)
    }

    @Test func delegationMaxIterationsReadsExplicitValue() {
        let cfg = HermesConfig(yaml: """
        delegation:
          max_iterations: 40
        """)
        #expect(cfg.delegation.maxIterations == 40)
    }

    @Test func delegationMaxConcurrentChildrenDefaultsTo10WhenUnset() {
        let cfg = HermesConfig(yaml: "")
        #expect(cfg.delegation.maxConcurrentChildren == 10)
    }

    @Test func delegationMaxConcurrentChildrenReadsExplicitValue() {
        let cfg = HermesConfig(yaml: """
        delegation:
          max_concurrent_children: 3
        """)
        #expect(cfg.delegation.maxConcurrentChildren == 3)
    }

    // MARK: - gateway.multiplex_profile_allowlist

    @Test func multiplexProfileAllowlistAbsentIsNil() {
        let cfg = HermesConfig(yaml: """
        gateway:
          multiplex_profiles: true
        """)
        #expect(cfg.multiplexProfileAllowlist == nil)
    }

    @Test func multiplexProfileAllowlistPopulatedList() {
        let cfg = HermesConfig(yaml: """
        gateway:
          multiplex_profile_allowlist:
            - work
            - personal
        """)
        #expect(cfg.multiplexProfileAllowlist == ["work", "personal"])
    }

    @Test func multiplexProfileAllowlistEmptyListIsEmptyNotNil() {
        let cfg = HermesConfig(yaml: """
        gateway:
          multiplex_profile_allowlist: []
        """)
        #expect(cfg.multiplexProfileAllowlist != nil)
        #expect(cfg.multiplexProfileAllowlist == [])
    }

    /// Malformed: present as a scalar rather than a bullet list. Upstream
    /// (`_normalize_multiplex_profile_allowlist`) fails safe to serving
    /// only the "default" profile — Scarf mirrors that by normalizing to
    /// `[]` (not `nil`, and not a crash).
    @Test func multiplexProfileAllowlistMalformedScalarFailsSafeToEmpty() {
        let cfg = HermesConfig(yaml: """
        gateway:
          multiplex_profile_allowlist: work
        """)
        #expect(cfg.multiplexProfileAllowlist == [])
    }

    /// Inline flow list, quoted entries with spacing — previously fell
    /// through to the scalar branch and was misread as malformed → `[]`.
    @Test func multiplexProfileAllowlistFlowListQuotedWithSpaces() {
        let cfg = HermesConfig(yaml: """
        gateway:
          multiplex_profile_allowlist: [ "work", 'personal' ]
        """)
        #expect(cfg.multiplexProfileAllowlist == ["work", "personal"])
    }

    /// Inline flow list, unquoted, no spaces.
    @Test func multiplexProfileAllowlistFlowListUnquoted() {
        let cfg = HermesConfig(yaml: """
        gateway:
          multiplex_profile_allowlist: [work,personal]
        """)
        #expect(cfg.multiplexProfileAllowlist == ["work", "personal"])
    }

    /// A mapping-valued key must fail CLOSED to `[]` (Hermes restricts to
    /// the default profile), not fail OPEN to `nil` (serve-all).
    @Test func multiplexProfileAllowlistMappingFailsClosedToEmpty() {
        let cfg = HermesConfig(yaml: """
        gateway:
          multiplex_profile_allowlist:
            work: true
            personal: false
        """)
        #expect(cfg.multiplexProfileAllowlist == [])
    }

    /// Top-level `multiplex_profile_allowlist` takes precedence over
    /// `gateway.multiplex_profile_allowlist` (gateway/config.py:1190-1195,
    /// 1413-1423).
    @Test func multiplexProfileAllowlistTopLevelPrecedenceOverGateway() {
        let cfg = HermesConfig(yaml: """
        multiplex_profile_allowlist:
          - work
        gateway:
          multiplex_profile_allowlist:
            - personal
        """)
        #expect(cfg.multiplexProfileAllowlist == ["work"])
    }

    /// Top-level only, no `gateway.*` spelling present at all.
    @Test func multiplexProfileAllowlistTopLevelOnly() {
        let cfg = HermesConfig(yaml: """
        multiplex_profile_allowlist:
          - work
          - personal
        """)
        #expect(cfg.multiplexProfileAllowlist == ["work", "personal"])
    }

    // MARK: - auxiliary.background_review.enabled (NOT agent.*)

    @Test func backgroundReviewEnabledDefaultsToTrue() {
        let cfg = HermesConfig(yaml: "")
        #expect(cfg.auxiliary.backgroundReviewEnabled == true)
    }

    @Test func backgroundReviewEnabledReadsAuxiliaryKeyNotAgentKey() {
        let cfg = HermesConfig(yaml: """
        auxiliary:
          background_review:
            enabled: false
        """)
        #expect(cfg.auxiliary.backgroundReviewEnabled == false)

        // The task-spec-suggested `agent.background_review.enabled` path is
        // NOT read — confirms Scarf parses the real (auxiliary-nested) key.
        let wrongPath = HermesConfig(yaml: """
        agent:
          background_review:
            enabled: false
        """)
        #expect(wrongPath.auxiliary.backgroundReviewEnabled == true)
    }

    // MARK: - Voice/STT v0.20.4 keys

    @Test func wakeWordCaptureDefaultsToAuto() {
        let cfg = HermesConfig(yaml: "")
        #expect(cfg.voice.wakeWordCapture == "auto")
    }

    @Test func wakeWordCaptureReadsExplicitValue() {
        let cfg = HermesConfig(yaml: """
        wake_word:
          capture: client
        """)
        #expect(cfg.voice.wakeWordCapture == "client")
    }

    @Test func sttLocalUnloadAfterIdleSecondsDefaultsToZero() {
        let cfg = HermesConfig(yaml: "")
        #expect(cfg.voice.sttLocalUnloadAfterIdleSeconds == 0)
    }

    @Test func sttCloudTrimKeysAreTopLevelNotNestedUnderLocal() {
        let cfg = HermesConfig(yaml: """
        stt:
          cloud_trim_silence: false
          cloud_trim_threshold_db: -35
          cloud_trim_keep_ms: 250
        """)
        #expect(cfg.voice.sttCloudTrimSilence == false)
        #expect(cfg.voice.sttCloudTrimThresholdDB == -35)
        #expect(cfg.voice.sttCloudTrimKeepMS == 250)
    }

    @Test func sttCloudTrimSilenceDefaultsToTrue() {
        let cfg = HermesConfig(yaml: "")
        #expect(cfg.voice.sttCloudTrimSilence == true)
    }

    // MARK: - agent.cron_drain_timeout / agent.gateway_turn_lease_timeout

    @Test func cronDrainTimeoutDefaultsTo30() {
        let cfg = HermesConfig(yaml: "")
        #expect(cfg.cronDrainTimeout == 30)
    }

    /// An absent key parses to the 0 sentinel, NOT a baked-in default — the
    /// upstream default changed 1800 → 5 at v0.21.0, so the effective value
    /// is host-dependent and resolved by
    /// `displayGatewayTurnLeaseTimeout(capabilities:)`.
    @Test func gatewayTurnLeaseTimeoutAbsentIsSentinel() {
        let cfg = HermesConfig(yaml: "")
        #expect(cfg.gatewayTurnLeaseTimeout == 0)
    }

    @Test func gatewayTurnLeaseTimeoutParsesExplicitValue() {
        let cfg = HermesConfig(yaml: """
        agent:
          gateway_turn_lease_timeout: 45
        """)
        #expect(cfg.gatewayTurnLeaseTimeout == 45)
    }

    @Test func gatewayTurnLeaseTimeoutDisplayDefaultIsHostAware() {
        let absent = HermesConfig(yaml: "")
        let v021 = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
        let v0206 = HermesCapabilities.parseLine("Hermes Agent v0.20.6 (2026.8.27)")
        let v0204 = HermesCapabilities.parseLine("Hermes Agent v0.20.4 (2026.8.16)")
        #expect(absent.displayGatewayTurnLeaseTimeout(capabilities: v021) == 5)
        #expect(absent.displayGatewayTurnLeaseTimeout(capabilities: v0206) == 1800)
        #expect(absent.displayGatewayTurnLeaseTimeout(capabilities: v0204) == 1800)
        // Unknown host resolves to the older, larger default.
        #expect(absent.displayGatewayTurnLeaseTimeout(capabilities: .empty) == 1800)
    }

    /// An explicit on-disk value wins on every host — and critically, a
    /// v0.21 host's own default of 5 round-trips: it is >= the stepper's
    /// floor (`gatewayTurnLeaseTimeoutMinimum`) and a multiple of its step,
    /// so displaying it never snaps the value up.
    @Test func gatewayTurnLeaseTimeoutExplicitValueWinsAndFiveRoundTrips() {
        let explicit = HermesConfig(yaml: """
        agent:
          gateway_turn_lease_timeout: 5
        """)
        let v021 = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
        #expect(explicit.displayGatewayTurnLeaseTimeout(capabilities: v021) == 5)
        #expect(explicit.displayGatewayTurnLeaseTimeout(capabilities: .empty) == 5)
        #expect(HermesConfig.gatewayTurnLeaseTimeoutMinimum <= 5)
        #expect(5 % HermesConfig.gatewayTurnLeaseTimeoutMinimum == 0)
    }

    /// Hermes treats non-positive as "use the built-in default", and so does
    /// the display resolver — the sentinel and the on-disk semantics agree.
    @Test func gatewayTurnLeaseTimeoutNonPositiveResolvesToHostDefault() {
        let zero = HermesConfig(yaml: """
        agent:
          gateway_turn_lease_timeout: 0
        """)
        let v021 = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
        #expect(zero.displayGatewayTurnLeaseTimeout(capabilities: v021) == 5)
        #expect(zero.displayGatewayTurnLeaseTimeout(capabilities: .empty) == 1800)
    }

    // MARK: - auxiliary.*.max_concurrency (true-optional)

    @Test func auxiliaryMaxConcurrencyAbsentIsNil() {
        let cfg = HermesConfig(yaml: "")
        #expect(cfg.auxiliary.compression.maxConcurrency == nil)
        #expect(cfg.auxiliary.titleGeneration.maxConcurrency == nil)
    }

    @Test func auxiliaryMaxConcurrencyReadsExplicitValue() {
        let cfg = HermesConfig(yaml: """
        auxiliary:
          compression:
            max_concurrency: 2
          title_generation:
            max_concurrency: 4
        """)
        #expect(cfg.auxiliary.compression.maxConcurrency == 2)
        #expect(cfg.auxiliary.titleGeneration.maxConcurrency == 4)
    }
}
