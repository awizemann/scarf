import Testing
@testable import ScarfCore

/// P2 (v0.21.4 / v0.21.5): multiplex-by-default, the retired
/// `multiplex_profiles: false`, `gateway.standalone`, and parked profiles.
/// Every Hermes line below is the literal from the tagged source
/// (`hermes_cli/gateway_profile_lifecycle.py` @ `v2026.9.24`), with a sample
/// profile name substituted into the f-string.
@Suite struct HermesGatewayMultiplexParkingP2Tests {

    private static let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
    private static let v0214 = HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)")
    private static let v0215 = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")

    // MARK: - capability floors

    @Test func multiplexByDefaultFloorIsV0214() {
        #expect(Self.v0214.hasMultiplexByDefault)
        #expect(Self.v0215.hasMultiplexByDefault)
        #expect(!Self.v0213.hasMultiplexByDefault)
        #expect(!HermesCapabilities.empty.hasMultiplexByDefault)
    }

    @Test func v0215FlagsAreOffOnV0214() {
        #expect(Self.v0215.hasMultiplexOptOutRewrite)
        #expect(Self.v0215.hasGatewayStandaloneProfiles)
        #expect(Self.v0215.hasGatewayProfileParking)
        #expect(!Self.v0214.hasMultiplexOptOutRewrite)
        #expect(!Self.v0214.hasGatewayStandaloneProfiles)
        #expect(!Self.v0214.hasGatewayProfileParking)
    }

    // MARK: - multiplexStatus

    private static func status(_ yaml: String, _ caps: HermesCapabilities) -> HermesProfileRoutes.MultiplexStatus {
        ProfileRoutesYAML.parse(yaml).multiplexStatus(capabilities: caps)
    }

    /// The v0.21.4 finding: an ABSENT key read as "routing is off". Below the
    /// floor it still does — that is what keeps a v0.21.3 host identical.
    @Test func absentKeyIsOffBelowTheFloorAndDefaultOnAtIt() {
        let yaml = "gateway:\n  allow_all_users: true\n"
        #expect(Self.status(yaml, Self.v0213) == .off)
        #expect(Self.status(yaml, Self.v0214) == .defaultOn)
        #expect(Self.status(yaml, Self.v0215) == .defaultOn)
        #expect(Self.status("", Self.v0214) == .defaultOn)
    }

    @Test func explicitFalseIsOffBelowTheFloorAndRetiredAtIt() {
        for yaml in [
            "gateway:\n  multiplex_profiles: false\n",
            "gateway:\n  multiplex_profiles: no\n",
            "multiplex_profiles: off\n",
            // Top-level null falls through to the nested spelling.
            "multiplex_profiles: null\ngateway:\n  multiplex_profiles: false\n",
        ] {
            #expect(Self.status(yaml, Self.v0213) == .off, "\(yaml)")
            #expect(Self.status(yaml, Self.v0214) == .retiredOptOut, "\(yaml)")
        }
    }

    @Test func explicitTrueIsOnEverywhere() {
        let yaml = "gateway:\n  multiplex_profiles: true\n"
        #expect(Self.status(yaml, Self.v0213) == .on)
        #expect(Self.status(yaml, Self.v0214) == .on)
    }

    /// A top-level `false` still shadows a nested `true` (the spelling in
    /// effect decides), so it is the retired value that is read.
    @Test func topLevelFalseShadowsNestedTrue() {
        let yaml = "multiplex_profiles: false\ngateway:\n  multiplex_profiles: true\n"
        #expect(Self.status(yaml, Self.v0213) == .off)
        #expect(Self.status(yaml, Self.v0214) == .retiredOptOut)
    }

    /// v0.21.4 coerces an unrecognised token with `_coerce_bool(…, True)`
    /// (`gateway/config.py:781` @ `v2026.9.21`) — it is an explicit ON, not
    /// the retired `false`.
    @Test func unrecognisedTokenIsNotTheRetiredFalse() {
        let yaml = "gateway:\n  multiplex_profiles: maybe\n"
        #expect(Self.status(yaml, Self.v0213) == .off)
        #expect(Self.status(yaml, Self.v0214) == .on)
    }

    @Test func gatewayStandaloneIsReadFromTheGatewaySectionOnly() {
        #expect(ProfileRoutesYAML.parse("gateway:\n  standalone: true\n").gatewayStandalone)
        #expect(ProfileRoutesYAML.parse("gateway:\n  standalone: yes\n").gatewayStandalone)
        #expect(!ProfileRoutesYAML.parse("gateway:\n  standalone: false\n").gatewayStandalone)
        // `_standalone_truthy` reads no top-level alias (profiles.py:1029-1031).
        #expect(!ProfileRoutesYAML.parse("standalone: true\n").gatewayStandalone)
        #expect(!ProfileRoutesYAML.parse("").gatewayStandalone)
    }

    // MARK: - parked-profile lifecycle verdicts

    private static func judge(_ verb: HermesGatewayServiceVerdict.Verb, _ output: String, exit: Int32 = 0) -> HermesCLIOutcome {
        HermesGatewayServiceVerdict.judge(verb: verb, output: output, exitCode: exit)
    }

    /// `:44`, `:62-63`, `:75`.
    @Test func confirmedLifecycleLinesAreSuccesses() {
        let start = Self.judge(.start, "Profile 'work' served by the host gateway.\n")
        #expect(start.succeeded)
        #expect(start.warning == HermesGatewayServiceVerdict.profileServedNote)

        let stop = Self.judge(.stop,
            "Profile 'work' parked; its bots and cron are stopped. Start again with: hermes -p work gateway start\n")
        #expect(stop.succeeded)
        #expect(stop.warning == HermesGatewayServiceVerdict.profileParkedNote)

        let restart = Self.judge(.restart, "Profile 'work' restarted by the host gateway.\n")
        #expect(restart.succeeded)
        #expect(restart.warning == HermesGatewayServiceVerdict.profileRestartedNote)
    }

    /// `:46-47`, `:65-66`, `:71`, `:77-78` — intent persisted, host not yet
    /// confirmed. Never a success (C5), never a red failure.
    @Test func unconfirmedLifecycleLinesAreUnconfirmed() {
        let cases: [(HermesGatewayServiceVerdict.Verb, String)] = [
            (.start, "Profile 'work' unparked, but serving was not confirmed: host control socket did not answer.\nThe host retries on its next rescan (within 30s). Check gateway status.\n"),
            (.stop, "Profile 'work' parked, but immediate stop was not confirmed: host operation is still pending.\nThe host drops it on its next rescan (within 30s).\n"),
            (.restart, "Profile 'work' restart was not confirmed: host control socket did not answer.\n"),
            (.restart, "Profile 'work' stopped, but serving was not confirmed: host operation is still pending.\nThe host retries on its next rescan (within 30s). Check gateway status.\n"),
        ]
        for (verb, output) in cases {
            let outcome = Self.judge(verb, output)
            #expect(!outcome.succeeded, "\(output)")
            #expect(outcome.confidence == .unconfirmed, "\(output)")
            #expect(outcome.detail?.hasPrefix("Profile 'work'") == true, "\(output)")
        }
    }

    /// A confirmed line only counts for ITS verb — a start that printed the
    /// stop line is not a start.
    @Test func lifecycleLinesAreVerbSpecific() {
        let served = "Profile 'work' served by the host gateway.\n"
        #expect(!Self.judge(.stop, served).succeeded)
        #expect(!Self.judge(.restart, served).succeeded)
        let parked = "Profile 'work' parked; its bots and cron are stopped. Start again with: hermes -p work gateway start\n"
        #expect(!Self.judge(.start, parked).succeeded)
    }

    /// Case-sensitive: Hermes prints `Profile`, and the clause keeps its
    /// leading `'` so an unrelated sentence can't borrow it.
    @Test func nearMissesAreNotSuccesses() {
        #expect(!Self.judge(.start, "profile 'work' served by the host gateway.\n").succeeded)
        #expect(!Self.judge(.start, "The profile is served by the host gateway.\n").succeeded)
        #expect(!Self.judge(.restart, "Profile 'work' restarted by the host gateway.\n", exit: 1).succeeded)
    }

    /// Pre-target outputs judge exactly as before.
    @Test func existingGatewayVerdictsAreUnchanged() {
        let started = Self.judge(.start, "✓ Service started\n")
        #expect(started.succeeded)
        #expect(started.warning == nil)
        let nothing = Self.judge(.stop, "✗ No gateway running for this profile\n")
        #expect(nothing.succeeded)
        #expect(nothing.warning == HermesGatewayServiceVerdict.nothingWasRunningNote)
        #expect(Self.judge(.start, "", exit: 0).confidence == .unconfirmed)
    }

    // MARK: - parked `gateway status`

    /// `print_parked_status`'s named-profile early return (`:86-88`).
    @Test func namedParkedStatusIsRecognised() {
        #expect(HermesGatewayParkedStatus.parkedProfile(
            statusOutput: "Profile 'work': parked (hermes -p work gateway start)\n") == "work")
        #expect(HermesGatewayParkedStatus.parkedProfile(
            statusOutput: "\u{1B}[0mProfile 'a-b_1': parked (hermes -p a-b_1 gateway start)\n\n") == "a-b_1")
    }

    /// The DEFAULT profile lists parked satellites (`:89-97`) and then prints
    /// its own status — that is not this profile being parked.
    @Test func defaultProfileListingIsNotParked() {
        let output = """
        Served profiles: default, home
        Profile 'work': parked (hermes -p work gateway start)
        ✓ Gateway is running (PID: 4821)
          (Running manually, not as a system service)
        """
        #expect(HermesGatewayParkedStatus.parkedProfile(statusOutput: output) == nil)
        let stopped = "Profile 'work': parked (hermes -p work gateway start)\n✗ Gateway is not running\n"
        #expect(HermesGatewayParkedStatus.parkedProfile(statusOutput: stopped) == nil)
    }

    @Test func malformedParkedLinesAreRejected() {
        for output in [
            "",
            "✗ Gateway is not running\n",
            "Profile 'work': parked (hermes -p other gateway start)\n",
            "Profile '': parked (hermes -p  gateway start)\n",
            "Profile ': parked (hermes -p gateway start)\n",
            "profile 'work': parked (hermes -p work gateway start)\n",
        ] {
            #expect(HermesGatewayParkedStatus.parkedProfile(statusOutput: output) == nil, "\(output)")
        }
    }

    // MARK: - P7e: `gateway.multiplex_profile_allowlist` window

    private static let v0200 = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)")
    private static let v0201 = HermesCapabilities.parseLine("Hermes Agent v0.20.1 (2026.8.13)")
    private static let v0212 = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")

    /// Re-floored to 0.20.1 – 0.21.2 (P7e re-walk): `gateway/config.py`'s
    /// `_normalize_multiplex_profile_allowlist` first lands in commit
    /// `c8f235a106`, first tagged at v2026.8.13 (0.20.1) — `git tag
    /// --contains` that commit lists no earlier numbered tag. Migration 43
    /// (`hermes_cli/config_migrations.py:640-649` @ v2026.9.14) deletes the
    /// key on load, and every reader is gone in that SAME release
    /// (`git grep multiplex_profile_allowlist v2026.9.14 -- 'gateway/*.py'
    /// hermes_cli/gateway.py hermes_cli/profiles.py` is empty), whose
    /// `pyproject.toml` reads 0.21.3. The audit's `≥0.20.4` guess undershot
    /// the true floor and never named the ceiling at all.
    @Test func multiplexProfileAllowlistIsAWindowNotAFloor() {
        #expect(!Self.v0200.hasMultiplexProfileAllowlist)
        #expect(Self.v0201.hasMultiplexProfileAllowlist)
        #expect(Self.v0212.hasMultiplexProfileAllowlist)
        #expect(!Self.v0213.hasMultiplexProfileAllowlist)
        #expect(!Self.v0214.hasMultiplexProfileAllowlist)
        #expect(!Self.v0215.hasMultiplexProfileAllowlist)
        #expect(!HermesCapabilities.empty.hasMultiplexProfileAllowlist)
    }

    // `SettingsViewModel.multiplexProfileAllowlistWarning`'s window gating
    // is covered in the Mac app target (`scarfTests/ProfileRoutesAllowlistP7eTests.swift`)
    // since the view model lives there, not in ScarfCore.

    // MARK: - P7e: the v0.21.5 boxed STANDALONE warning

    /// Alan's live host, 2026-09-26: two profiles collided on
    /// `TELEGRAM_BOT_TOKEN`. Literal box shape from
    /// `standalone_warning_lines`/`_box` (`hermes_cli/gateway_multiplex_mode.py:299-335,221-225`
    /// @ v2026.9.24) — border width tracks the longest body line, so this
    /// fixture's borders are wider than a shorter reason would need, which
    /// is exactly why the parser keys on line prefixes rather than a fixed
    /// width.
    private static let standaloneBox = """
    ✓ Gateway is running (PID: 4821)
      (Running manually, not as a system service)

    ┌──────────────────────────────────────────────────────────────────────────────┐
    │ ⚠ This gateway is STANDALONE: it serves only its own profile.                │
    │ Profiles NOT served (their bots stay silent): gateway, scarfbox-test          │
    │ Why: duplicate TELEGRAM_BOT_TOKEN in 'gateway' and 'scarfbox-test' profiles   │
    │ Fix: hermes gateway migrate --multiplex                                      │
    └──────────────────────────────────────────────────────────────────────────────┘
    """

    @Test func standaloneBoxParsesUnservedReasonAndFix() {
        let warning = HermesGatewayStandaloneWarning.parse(statusOutput: Self.standaloneBox)
        #expect(warning?.unservedProfiles == ["gateway", "scarfbox-test"])
        #expect(warning?.reason == "duplicate TELEGRAM_BOT_TOKEN in 'gateway' and 'scarfbox-test' profiles")
        #expect(warning?.fixCommand == "hermes gateway migrate --multiplex")
    }

    @Test func noBoxMeansNoWarning() {
        #expect(HermesGatewayStandaloneWarning.parse(statusOutput: "✓ Gateway is running (PID: 4821)\n") == nil)
    }

    /// v0.21.4's DIFFERENT, unboxed line (`hermes_cli/gateway.py:1542-1548`
    /// @ v2026.9.21) must not be misread as the box — it carries no
    /// unserved-profile list or fix command for this parser to extract.
    @Test func theOlderV0214OneLinerIsNotTheBox() {
        #expect(HermesGatewayStandaloneWarning.parse(
            statusOutput: "⚠ Serving the default profile only: single-profile install\n") == nil)
    }

    @Test func standaloneStatusBoxFloorIsV0215() {
        #expect(Self.v0215.hasGatewayStandaloneStatusBox)
        #expect(!Self.v0214.hasGatewayStandaloneStatusBox)
        #expect(!HermesCapabilities.empty.hasGatewayStandaloneStatusBox)
    }
}
