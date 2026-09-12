import Foundation
import Testing
@testable import ScarfCore

// MARK: - P46b finding 1: the picker BINDING, not just the options

/// P46 fixed the option list and left the selection alone. The sentinel row
/// the two top-level pickers prepend is tagged with the EMPTY string, and the
/// binding handed `Picker` the raw stored value — so a whitespace-only
/// `agent.reasoning_effort` (which `levels(capabilities:selected:)` correctly
/// widens nothing for, because `str(effort).strip()` is empty to Hermes,
/// `hermes_constants.py:884` @ `v2026.9.7`) matched no tag at all and the
/// control rendered blank. One shared function answers it for all four
/// pickers.
@Suite("P46b · reasoning-effort picker selection")
struct ReasoningPickerSelectionP46bTests {

    private static let target = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")

    /// The bug, at the level it actually lives: a whitespace-only value must
    /// resolve to the sentinel row's own tag, or the control is empty.
    @Test func aWhitespaceOnlyValueSelectsTheSentinelRow() {
        #expect(HermesReasoningEffort.pickerSelection(for: "  ") == "")
        #expect(HermesReasoningEffort.pickerSelection(for: "\t \n") == "")
    }

    @Test func theEmptyStringIsAlreadyTheSentinel() {
        #expect(HermesReasoningEffort.pickerSelection(for: "") == "")
    }

    /// Everything else passes through RAW, because a widened row's tag IS the
    /// raw stored string — normalising here would blank the control the other
    /// way round.
    @Test func aRealValuePassesThroughUntouched() {
        for stored in ["Max", "high", " high ", "Turbo", "  ULTRA"] {
            #expect(HermesReasoningEffort.pickerSelection(for: stored) == stored)
        }
    }

    /// The end-to-end invariant the three call sites need: whatever
    /// `pickerSelection` hands the control, one of the offered tags equals
    /// it. The sentinel row is modelled here the way the two top-level
    /// pickers prepend it.
    @Test func everySelectionMatchesOneOfTheOfferedTags() {
        for stored in ["", "  ", "high", "Max", " high ", "Turbo"] {
            let tags = [""] + HermesReasoningEffort.levels(
                capabilities: Self.target, selected: stored
            )
            let selection = HermesReasoningEffort.pickerSelection(for: stored)
            #expect(tags.contains(selection),
                    "“\(stored)” selects “\(selection)”, which is in none of \(tags)")
        }
    }

    /// The per-model override rows have no sentinel of their own, which is
    /// why they get one: an empty override value had no tag at all. What it
    /// resolves to is the GLOBAL row — `parse_reasoning_effort("")` is
    /// `None`, `resolve_per_model_reasoning_effort` returns `None`
    /// (`hermes_constants.py:935-941` @ `v2026.9.7`) and
    /// `resolve_reasoning_config` falls through to `agent.reasoning_effort`
    /// (`:970-976`).
    @Test func anEmptyOverrideNeedsTheSameSentinelRow() {
        let tags = [""] + HermesReasoningEffort.levels(capabilities: Self.target, selected: "")
        #expect(tags.contains(HermesReasoningEffort.pickerSelection(for: "")))
        #expect(tags.contains(HermesReasoningEffort.pickerSelection(for: "   ")))
    }

    /// The doc correction's substance: a cased row sits BESIDE the canonical
    /// one by design, and the notice stays quiet about it.
    @Test func aCasedValueKeepsItsOwnRowAndDrawsNoNotice() throws {
        let widened = HermesReasoningEffort.levels(capabilities: Self.target, selected: "Max")
        #expect(widened.first == "Max")
        #expect(widened.contains("max"), "the canonical row must survive beside the cased one")
        #expect(HermesReasoningEffort.unsupportedLevelNotice(for: "Max", capabilities: Self.target) == nil)
    }
}

// MARK: - P46b finding 2: the restart toggle must not create a block

/// `GatewayBehaviorViewModel` writes a bare
/// `<platform>.gateway_restart_notification`. On a nested-only host that
/// CREATES the top-level `<platform>:` block, which `platform_section` then
/// takes as the bridge source (`gateway/config_loader.py:171-180` @
/// `v2026.9.7`) — and every `platforms.<platform>.<shared key>` beside it
/// stops reaching `extra`. Moving the READER onto `sharedPlatformScalar` lets
/// the write be resolved onto the bridge source instead, so it creates
/// nothing.
@Suite("P46b · the restart toggle is bridge-resolved")
struct GatewayRestartBridgeP46bTests {

    /// A nested-only host: `require_mention` false lives under
    /// `platforms.slack`, and nothing is spelled at the top level.
    private static let nestedOnly = """
    platforms:
      slack:
        require_mention: false
        reply_in_thread: false
    """

    @Test func theTogglesKeyIsRewrittenOntoTheBridgeSource() throws {
        let out = HermesPlatformSharedKeys.resolved(
            ["slack.gateway_restart_notification": "false"],
            configText: Self.nestedOnly
        )
        #expect(out["platforms.slack.gateway_restart_notification"] == "false",
                "the toggle still writes a top-level block: \(out)")
        #expect(out["slack.gateway_restart_notification"] == nil)
    }

    /// The regression itself. Save the toggle the way the form does, apply
    /// the resulting keys to config.yaml, and re-read: before the fix the
    /// bare key created `slack:`, `platform_section` bridged from it, and
    /// `require_mention` came back at its TRUE default — a setting the user
    /// never touched, silently flipped by an unrelated toggle.
    @Test func savingTheToggleDoesNotUnbridgeRequireMention() throws {
        let out = HermesPlatformSharedKeys.resolved(
            ["slack.gateway_restart_notification": "false"],
            configText: Self.nestedOnly
        )
        // config.yaml as that batch leaves it — `hermes config set` writes
        // the key INTO the existing nested block rather than beside it.
        let target = try #require(out.keys.first)
        #expect(target == "platforms.slack.gateway_restart_notification")
        let saved = Self.nestedOnly + "\n    gateway_restart_notification: false\n"

        let config = HermesConfig(yaml: saved)
        #expect(config.slack.requireMention == false,
                "the restart toggle un-bridged `require_mention`")
        #expect(config.slack.replyInThread == false)
        let slack = try #require(config.gatewayPlatforms["slack"])
        #expect(slack.gatewayRestartNotification == false,
                "the toggle itself did not read back")
    }

    /// The counterfactual, which is what makes the test above a regression
    /// test: had the toggle kept its bare spelling, the top-level `slack:`
    /// block it creates becomes the bridge source and `require_mention`
    /// reverts to its TRUE default with nobody having touched it.
    @Test func theBareSpellingIsWhatUnbridgedIt() {
        let saved = Self.nestedOnly + "\nslack:\n  gateway_restart_notification: false\n"
        #expect(HermesConfig(yaml: saved).slack.requireMention == true,
                "this is the shape the fix avoids: if it no longer reproduces, the bridge precedence has changed and the fix needs re-reading")
    }

    /// And the read follows the bridge on a host that DOES have a top-level
    /// block: the value there wins, exactly as `platform_section` says.
    @Test func aTopLevelBlockIsStillTheBridgeSource() throws {
        let yaml = """
        slack:
          gateway_restart_notification: false
        platforms:
          slack:
            gateway_restart_notification: true
        """
        let slack = try #require(HermesConfig(yaml: yaml).gatewayPlatforms["slack"])
        #expect(slack.gatewayRestartNotification == false)
    }

    /// A platform whose shared keys nothing reads through the bridge keeps
    /// the flat spelling — the general hazard is filed, not closed, and this
    /// pins which platforms moved.
    @Test func onlySlackAndTelegramMoved() {
        #expect(HermesPlatformSharedKeys.bridgeResolvedKeys.contains(
            .init(platform: "slack", key: "gateway_restart_notification")))
        #expect(HermesPlatformSharedKeys.bridgeResolvedKeys.contains(
            .init(platform: "telegram", key: "gateway_restart_notification")))
        #expect(HermesPlatformSharedKeys.split(key: "discord.gateway_restart_notification") == nil,
                "discord has no bridge-resolved reader — moving its write would make it write-only")
    }

    /// The batch's own bare key must not pin the prefix to the top level:
    /// counting it was what made the rewrite resolve straight back onto the
    /// block it exists to avoid creating.
    @Test func theBatchsOwnSharedKeyDoesNotPinTheTopLevel() {
        let out = HermesPlatformSharedKeys.resolved(
            [
                "slack.gateway_restart_notification": "false",
                "display.busy_ack_enabled": "true",
            ],
            configText: Self.nestedOnly
        )
        #expect(out["platforms.slack.gateway_restart_notification"] == "false")
        #expect(out["display.busy_ack_enabled"] == "true", "an unrelated key must pass through")
    }

    /// …while an UNSHARED bare key in the same batch still pins it, because
    /// that key really does create the block (P46's own finding).
    @Test func anUnsharedBareKeyStillPinsTheTopLevel() {
        let out = HermesPlatformSharedKeys.resolved(
            [
                "slack.gateway_restart_notification": "false",
                "slack.some_unshared_key": "x",
            ],
            configText: Self.nestedOnly
        )
        #expect(out["slack.gateway_restart_notification"] == "false",
                "the batch creates `slack:`, so the bridge source is the top level: \(out)")
    }

}

// MARK: - P46b findings 5 & 6: the managed-install cache

@Suite("P46b · managed-install cache races and derivations")
struct ManagedInstallCacheP46bTests {

    private static let modern = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
    private static let undetected = HermesCapabilities.empty

    private static func host(home: String) -> ServerContext {
        ServerContext(
            id: UUID(), displayName: "p46b",
            kind: .ssh(SSHConfig(host: "p46b", remoteHome: home))
        )
    }

    /// Finding 5. `invalidate` lands while the probe is in flight; the probe
    /// then returns the PRE-provision marker. Storing it would silently undo
    /// the invalidation for the life of the process.
    @Test func aProbeThatLandsAfterAnInvalidateIsNotStored() {
        let ctx = Self.host(home: "/tmp/p46b-race")
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let counter = Counter()
        // Only the FIRST probe blocks; a later one must not sit on the gate
        // (a test that waits out a timeout is asserting about the clock).
        let cache = HermesManagedInstallCache(probe: { _ in
            let n = counter.bumpAndRead()
            if n == 1 {
                started.signal()
                gate.wait()
            }
            return "nixos"
        }, timeout: 5)

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = cache.managedInstall(for: ctx, capabilities: Self.modern)
            done.signal()
        }
        started.wait()                     // the probe is in flight
        cache.invalidate(for: ctx)         // …and the host is re-provisioned
        gate.signal()
        done.wait()

        #expect(cache.cached(for: ctx, capabilities: Self.modern).isManaged == false,
                "the invalidated entry was resurrected by the in-flight probe")
        // …and the next ask really does re-probe rather than serve the stale one.
        _ = cache.managedInstall(for: ctx, capabilities: Self.modern)
        #expect(counter.value == 2, "the stale result was served instead of re-probed")
    }

    /// The ordinary path is untouched: no invalidation, one probe, memoized.
    @Test func anUncontendedProbeIsStillMemoized() {
        let ctx = Self.host(home: "/tmp/p46b-plain")
        let counter = Counter()
        let cache = HermesManagedInstallCache(probe: { _ in _ = counter.bumpAndRead(); return "nixos" })
        #expect(cache.managedInstall(for: ctx, capabilities: Self.modern).system == "nixos")
        #expect(cache.managedInstall(for: ctx, capabilities: Self.modern).system == "nixos")
        #expect(counter.value == 1)
    }

    /// Finding 6. A verdict derived while the capabilities were still
    /// undetected read "any marker ⇒ NixOS" (`hermes_cli/config.py:327-330` @
    /// `v2026.6.19`), and handing that stored verdict to a later caller kept
    /// the below-floor reading alive after detection landed. The marker is
    /// cached; the verdict is derived from the CALLER's capabilities.
    @Test func theCachedVerdictFollowsTheCallersCapabilities() {
        let ctx = Self.host(home: "/tmp/p46b-derive")
        let cache = HermesManagedInstallCache(probe: { _ in "brew" })
        // The connect-time read happens before `hermes --version` answers:
        // below the v0.20.5 floor ANY marker is `"NixOS"`, so the pane locks.
        #expect(cache.managedInstall(for: ctx, capabilities: Self.undetected).system == "NixOS")
        // Detection lands. `_IGNORED_MANAGED_VALUES` is `{"brew","homebrew"}`
        // (`hermes_cli/config.py:273` @ `v2026.9.7`), so the same cached
        // marker must now read as NOT managed and the pane must unlock.
        #expect(cache.cached(for: ctx, capabilities: Self.modern).isManaged == false,
                "the cached verdict was frozen at the undetected derivation")
        // …and the undetected reading is still what an undetected caller gets.
        #expect(cache.cached(for: ctx, capabilities: Self.undetected).system == "NixOS")
    }

    /// Nothing probed yet is still writable — the fail-open direction.
    @Test func nothingProbedIsNotManaged() {
        let cache = HermesManagedInstallCache(probe: { _ in "nixos" })
        #expect(cache.cached(for: Self.host(home: "/tmp/p46b-empty"),
                             capabilities: Self.modern).isManaged == false)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bumpAndRead() -> Int { lock.lock(); count += 1; defer { lock.unlock() }; return count }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}

// MARK: - P46b finding 8: a flow list splits on SEPARATOR commas only

/// `["a,b"]` is ONE item to PyYAML 6.0.3 and was two to Scarf: the split ran
/// before the quotes were honoured, and `stripYAMLQuotes` then tidied the
/// halves into a plausible-looking pair nothing downstream could question.
@Suite("P46b · quote-aware flow splitting")
struct FlowListSplitP46bTests {

    @Test func aCommaInsideADoubleQuotedEntryIsNotASeparator() {
        #expect(HermesYAML.parseFlatFlowList("\"a,b\"") == ["a,b"])
    }

    @Test func aCommaInsideASingleQuotedEntryIsNotASeparator() {
        #expect(HermesYAML.parseFlatFlowList("'a,b', c") == ["a,b", "c"])
    }

    /// An escaped quote does not close the span, so the comma after it is
    /// still inside the scalar (PyYAML: `['a",b', 'd']`).
    @Test func anEscapedQuoteDoesNotEndTheEntry() {
        // Two entries, not three: the comma after the ESCAPED quote is still
        // inside the scalar. PyYAML 6.0.3 loads `["a\",b", d]` as
        // `['a",b', 'd']`, and decision 10's `unquote` opt-in is what turns
        // the escape back into the character.
        #expect(HermesYAML.parseFlatFlowList(#""a\",b", d"#, unquoting: true) == [#"a",b"#, "d"])
        // Without the opt-in the split is the same; only the escape survives
        // verbatim, which is the rule everywhere else.
        #expect(HermesYAML.parseFlatFlowList(#""a\",b", d"#).count == 2)
    }

    @Test func ordinarySeparatorsStillSplit() {
        #expect(HermesYAML.parseFlatFlowList("a, b ,c") == ["a", "b", "c"])
        #expect(HermesYAML.parseFlatFlowList("") == [])
        #expect(HermesYAML.parseFlatFlowList("a,,b") == ["a", "b"])
    }

    /// An unclosed quote is not an error this splitter may invent — the
    /// remainder is one entry and the caller's own handling decides.
    @Test func anUnclosedQuoteDoesNotDropTheRemainder() {
        #expect(HermesYAML.parseFlatFlowList("\"a, b") == ["\"a, b"])
    }

    /// The map arm shares the splitter, so a quoted VALUE carrying a comma
    /// stops turning the whole map into "unparseable".
    @Test func aQuotedMapValueMayCarryAComma() throws {
        let parsed = HermesYAML.parseNestedYAML(#"routes: {a: "x,y", b: z}"#)
        let map = try #require(parsed.maps["routes"])
        #expect(map["a"] == "x,y")
        #expect(map["b"] == "z")
    }
}

// MARK: - P46b finding 7: `existingNames` is required

/// A default of `[]` makes the collision fix opt-in, and the whole point is
/// that `hermes cron run <name>` raises `AmbiguousJobReference` for BOTH jobs
/// (`cron/jobs.py:1831-1846` @ `v2026.9.7`) when a caller forgets.
@Suite("P46b · duplicate naming has no silent default")
struct DuplicateNamingP46bTests {

    @Test func theSecondDuplicateOfOneJobGetsItsOwnName() {
        let job = HermesCronJob(
            id: "j1", name: "Nightly", prompt: "p",
            schedule: CronSchedule(kind: "interval"),
            enabled: true, state: "scheduled")
        let first = job.duplicatedAsNewJob(id: "j2", existingNames: ["Nightly"])
        let second = job.duplicatedAsNewJob(
            id: "j3", existingNames: ["Nightly", first.name]
        )
        #expect(first.name != second.name,
                "two duplicates share a name — `cron run` is ambiguous for both")
        #expect(first.name != "Nightly")
        #expect(second.name != "Nightly")
    }
}


// MARK: - P46b fresh-eyes: a quote only opens a scalar at an entry's start

/// The first draft of `splitFlowEntries` treated a quote ANYWHERE as opening
/// a quoted scalar, so a bare word carrying an apostrophe swallowed the
/// separator after it. PyYAML 6.0.3 reads `[a'b, c]` as two PLAIN scalars.
@Suite("P46b · a mid-word quote is not a quoted scalar")
struct FlowPlainScalarP46bTests {

    @Test func anApostropheInsideABareWordDoesNotSwallowTheComma() {
        #expect(HermesYAML.parseFlatFlowList("a'b, c") == ["a'b", "c"])
        #expect(HermesYAML.parseFlatFlowList(#"a"b, c"#) == [#"a"b"#, "c"])
    }

    /// …while leading whitespace before a real quoted entry is still skipped.
    @Test func aQuotedEntryMayBeIndented() {
        #expect(HermesYAML.parseFlatFlowList("x,   'a,b'") == ["x", "a,b"])
    }

    /// And a quoted map KEY carrying a comma — the other half of the same
    /// bug, since `splitFlowEntry` never saw a whole entry to split.
    /// PyYAML 6.0.3: `{'a,b': x}` is one pair.
    @Test func aQuotedMapKeyMayCarryAComma() throws {
        let map = try #require(HermesYAML.parseNestedYAML("m: {'a,b': x}").maps["m"])
        #expect(map == ["a,b": "x"])
    }
}
