import Testing
import Foundation
@testable import ScarfCore

/// Round-6 P53 — mattermost's `require_mention` has its own vocabulary.
///
/// Hermes's mattermost adapter decides the flag with
/// `str(self._extra_or_env("require_mention", "MATTERMOST_REQUIRE_MENTION",
/// "true")).lower() not in {"false", "0", "no"}`
/// (`plugins/platforms/mattermost/adapter.py:504-505` @ `v2026.9.7`).
///
/// Two things make that different from every other platform's flag:
///
/// 1. It is a three-word DENYlist. `off` is not in it — slack, discord and
///    telegram all spell theirs `{"false", "0", "no", "off"}`. So on the
///    `.env` side, where nothing stands between the user's text and that
///    comparison, `off` means require_mention is **on**.
/// 2. It is a DENYlist at all. `parseEnvBool`, which P51 reached for, is a
///    four-word truthy ALLOWlist — it answers false for `y`, for `maybe`,
///    for anything it does not recognise, where Hermes answers true.
///
/// On the config side a third thing applies: PyYAML has already turned the
/// scalar into a Python object, so the QUOTES decide. `"OFF"` is a `str` and
/// not one of the three words → true; bare `off` resolves to `False` →
/// `"false"` → false. `boolishValue` reads both as false.
@Suite("Mattermost's require_mention reads Hermes's own falsy set (P53)")
struct MattermostRequireMentionP53Tests {

    // MARK: - The `.env` side

    @Test("`off` in .env means require_mention is ON")
    func offIsNotFalsyInEnv() {
        #expect(HermesYAML.mattermostRequireMention(envValue: "off") == true, """
            `off` is not in mattermost's falsy set — the toggle would have \
            shown the opposite of what the gateway does.
            """)
        #expect(HermesYAML.mattermostRequireMention(envValue: "OFF") == true)
        #expect(HermesYAML.mattermostRequireMention(envValue: "Off") == true)
    }

    @Test("an unrecognised spelling is TRUE, not false")
    func anythingOutsideTheThreeWordsIsTrue() {
        for value in ["y", "Y", "maybe", "1", "yes", "on", "enabled", "true"] {
            #expect(HermesYAML.mattermostRequireMention(envValue: value) == true,
                    "`\(value)` should be true — it is not one of the three falsy words")
        }
    }

    @Test("the three falsy words, and only those, are false")
    func theThreeFalsyWordsAreFalse() {
        for value in ["false", "FALSE", "False", "0", "no", "NO", "No"] {
            #expect(HermesYAML.mattermostRequireMention(envValue: value) == false,
                    "`\(value)` should be false")
        }
    }

    @Test("absent is the adapter's `true` default; empty is the empty string, also true")
    func absentAndEmpty() {
        #expect(HermesYAML.mattermostRequireMention(envValue: nil) == true)
        // `get_scoped_secret` returns `val if val is not None else default`
        // (`gateway/platforms/_shared.py:17-30`), so "" is a VALUE.
        #expect(HermesYAML.mattermostRequireMention(envValue: "") == true)
    }

    /// The old reader, pinned as the thing this replaced — if `parseEnvBool`
    /// ever agreed with Hermes, this fix would be unnecessary, and saying so
    /// is cheaper than a comment claiming it.
    @Test("the truthy-allowlist shape disagrees with Hermes on three spellings")
    func theOldShapeWasWrong() {
        // A local restatement of `PlatformSetupHelpers.parseEnvBool`, which
        // lives in the app target.
        func truthyAllowlist(_ s: String) -> Bool {
            ["true", "1", "yes", "on"].contains(s.lowercased())
        }
        for value in ["off", "y", "maybe"] {
            #expect(truthyAllowlist(value) == false)
            #expect(HermesYAML.mattermostRequireMention(envValue: value) == true,
                    "`\(value)` — the two readers must disagree, or this fix is a no-op")
        }
    }

    // MARK: - The config.yaml side

    @Test("a QUOTED `\"OFF\"` is a string, and a string is true")
    func aQuotedOffIsTrue() {
        #expect(HermesYAML.mattermostRequireMention(configScalar: "\"OFF\"") == true, """
            PyYAML loads a quoted scalar as a `str`, `str()` leaves it alone, \
            and `OFF` is not one of the three falsy words.
            """)
        #expect(HermesYAML.mattermostRequireMention(configScalar: "'off'") == true)
        // …but a quoted falsy WORD still is one.
        #expect(HermesYAML.mattermostRequireMention(configScalar: "\"no\"") == false)
    }

    @Test("a BARE `off` resolves to False and is false")
    func aBareOffIsFalse() {
        for value in ["off", "Off", "OFF", "no", "false", "False"] {
            #expect(HermesYAML.mattermostRequireMention(configScalar: value) == false,
                    "bare `\(value)` resolves to Python False")
        }
        for value in ["on", "On", "yes", "true", "TRUE"] {
            #expect(HermesYAML.mattermostRequireMention(configScalar: value) == true,
                    "bare `\(value)` resolves to Python True")
        }
    }

    @Test("a bare `y` is a string to PyYAML, so it is true")
    func aBareYIsAString() {
        // PyYAML's bool resolver regex does not include bare y/n, whatever
        // the YAML 1.1 spec says — and a string that is not one of the three
        // words is true.
        #expect(HermesYAML.mattermostRequireMention(configScalar: "y") == true)
        #expect(HermesYAML.mattermostRequireMention(configScalar: "n") == true)
        // Nor does it include mixed case outside its own spellings.
        #expect(HermesYAML.mattermostRequireMention(configScalar: "yEs") == true)
        #expect(HermesYAML.mattermostRequireMention(configScalar: "oFf") == true)
    }

    @Test("an integer stringifies: 0 is false, every other number is true")
    func integersStringify() {
        #expect(HermesYAML.mattermostRequireMention(configScalar: "0") == false)
        #expect(HermesYAML.mattermostRequireMention(configScalar: "1") == true)
        #expect(HermesYAML.mattermostRequireMention(configScalar: "2") == true)
        #expect(HermesYAML.mattermostRequireMention(configScalar: "-1") == true)
    }

    /// The radix forms, against a PyYAML oracle.
    ///
    /// Every pair below was produced by running
    /// `str(yaml.safe_load("k: <scalar>")["k"]).lower() not in
    /// {"false", "0", "no"}` under PyYAML (round-6 P53b) — the real chain
    /// `adapter.py:491-505` walks. `Int(_:)` is not PyYAML's `int` resolver:
    /// `0x0` and `0b0` are the int ZERO there and fell through to the string
    /// compare here, reading TRUE where Hermes reads false.
    ///
    /// The near-misses are the point of the table: `0X0` and `0B0` are
    /// upper-case and the resolver's pattern is lower-case only, `0o0` has
    /// no `0o` alternative at all (`0[0-7_]+` does not admit an `o`), and
    /// `08` is not octal — all four stay STRINGS and are therefore true.
    @Test("the radix forms agree with PyYAML, near-misses included")
    func theRadixFormsMatchTheOracle() {
        let oracle: [(String, Bool)] = [
        ("0", false),
        ("1", true),
        ("2", true),
        ("-1", true),
        ("0x0", false),
        ("0X0", true),
        ("0b0", false),
        ("0B0", true),
        ("0o0", true),
        ("0x10", true),
        ("0b1", true),
        ("00", false),
        ("010", true),
        ("08", true),
        ("0_", false),
        ("0__0", false),
        ("0_0", false),
        ("-0_0", false),
        ("0x_0", false),
        ("0x00", false),
        ("0b00", false),
        ("-0x0", false),
        ("+0b0", false),
        ("0x", true),
        ("0b", true),
        ("0o", true),
        ("0xG", true),
        ("_0", true),
        ("0.0", true),
        ("0e0", true),
        ("1:00", true),
        ("0x0_0", false),
        ("+0", false),
        ("-0", false),
        ("12_3", true),
        ]
        for (scalar, expected) in oracle {
            #expect(HermesYAML.mattermostRequireMention(configScalar: scalar) == expected, """
                `\(scalar)` reads \
                \(String(describing: HermesYAML.mattermostRequireMention(configScalar: scalar))) \
                where PyYAML + the three-word compare give \(expected)
                """)
        }
    }

    @Test("absent stays absent, so the caller can fall back to .env")
    func absentIsNil() {
        #expect(HermesYAML.mattermostRequireMention(configScalar: nil) == nil)
        #expect(HermesYAML.mattermostRequireMention(configScalar: "   ") == nil)
    }

    /// The universal reader and this one must disagree, or the whole key is
    /// pointless — the calibration that stops a future refactor collapsing
    /// them back together.
    @Test("`boolishValue` and the mattermost reader disagree where it matters")
    func theUniversalReaderIsNotTheSame() {
        #expect(HermesYAML.boolishValue("off") == false)
        #expect(HermesYAML.mattermostRequireMention(configScalar: "\"OFF\"") == true)
        #expect(HermesYAML.boolishValue("y") == nil)
        #expect(HermesYAML.mattermostRequireMention(configScalar: "y") == true)
    }

    // MARK: - Through the real config parse

    @Test("the parse resolves a nested `off` and a nested `\"off\"` differently")
    func theParseCarriesTheRule() {
        func settings(_ yaml: String) -> MattermostSettings {
            HermesConfig(yaml: yaml).mattermost
        }
        let bare = settings("platforms:\n  mattermost:\n    require_mention: off\n")
        #expect(bare.requireMention == false)
        #expect(bare.requireMentionIsSet == false)

        let quoted = settings("platforms:\n  mattermost:\n    require_mention: \"off\"\n")
        #expect(quoted.requireMention == true, """
            A quoted `off` is the string `off`, which Hermes reads as TRUE — \
            the parse is still going through the universal boolish set.
            """)
        #expect(quoted.requireMentionIsSet == true)

        // Absence still reads as absence, so the form falls back to `.env`.
        #expect(settings("platforms:\n  mattermost: {}\n").requireMentionIsSet == nil)
    }
}

/// Round-6 P53 — the modal editor's locked-`Enabled` footer named two
/// gestures that do not exist inside the modal.
///
/// P50b gated the iOS `CronEditorView`'s `Enabled` toggle and gave the
/// section footer `IOSCronViewModel.resumeRefusalMessage` — the LIST
/// banner's sentence, whose two arms end in "use Resume & Run Now to re-arm
/// it." and "Duplicate it to schedule a new run.". Both remedies live on the
/// list ROW (the context menu and, since P50b, the trailing swipe), and the
/// sheet is covering that list: from inside the editor neither is reachable.
/// Round-5 lesson 4 — a hint that names a remedy is walked like a button —
/// applied to a sheet instead of a row.
@Suite("The cron editor's lock note names a reachable remedy (P53)")
@MainActor
struct CronEditorLockNoteP53Tests {

    private func job(
        name: String = "nightly",
        kind: String = "once",
        runAt: String? = "2020-01-01T00:00:00Z",
        state: String = "completed",
        enabled: Bool = false
    ) -> HermesCronJob {
        HermesCronJob(
            id: "job_1", name: name, prompt: "hi",
            schedule: CronSchedule(kind: kind, runAt: runAt),
            enabled: enabled, state: state)
    }

    @Test("the note never names a gesture the sheet cannot perform unaided")
    func theNoteNamesNoUnreachableGesture() {
        for offer in [CronRecoveryOffer.none,
                      CronRecoveryOffer(canResume: false, canRearm: true)] {
            let note = IOSCronViewModel.editorEnabledLockNote(job(), offer: offer)
            // Every gesture the note names must be prefixed by the dismissal
            // it requires, so the copy is walkable as written. Both arms DO
            // name one, so the assertion is unconditional — an `if` that
            // guards it lets a note that names no gesture at all pass as if
            // it had been checked.
            #expect(note.contains("Duplicate") || note.contains("Resume & Run Now"), """
                The note names neither remedy: \(note)
                """)
            #expect(note.contains("Close this editor"), """
                The note names a list-row gesture without saying the \
                editor has to be dismissed first: \(note)
                """)
        }
    }

    @Test("the note keeps the banner's reason verbatim")
    func theNoteKeepsTheReason() {
        let spent = job()
        let banner = IOSCronViewModel.resumeRefusalMessage(spent, offer: .none)
        let note = IOSCronViewModel.editorEnabledLockNote(spent, offer: .none)
        #expect(note.contains("\"nightly\""), "the note stopped naming the job: \(note)")
        // The reason clause — everything before the banner's remedy — must
        // survive, so the two surfaces state one rule.
        let reason = banner.components(separatedBy: " — ").first?
            .components(separatedBy: ". ").first ?? banner
        let trimmed = reason.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        #expect(note.hasPrefix(trimmed), """
            The note no longer opens with the banner's own reason — the two \
            surfaces have drifted into two rules. banner: \(banner) note: \(note)
            """)
    }

    @Test("the re-arm arm points at the gesture that actually re-arms")
    func theRearmArmPointsAtTheContextMenu() {
        let note = IOSCronViewModel.editorEnabledLockNote(
            job(), offer: CronRecoveryOffer(canResume: false, canRearm: true))
        #expect(note.contains("Resume & Run Now"), "got: \(note)")
        #expect(note.contains("press and hold"), """
            "Resume & Run Now" is in the row's CONTEXT MENU, not its swipe \
            actions — the note must name the gesture that reaches it: \(note)
            """)
    }

    @Test("the no-rearm arm points at Duplicate, which is a swipe since P50b")
    func theDuplicateArmPointsAtTheSwipe() {
        let note = IOSCronViewModel.editorEnabledLockNote(job(), offer: .none)
        #expect(note.contains("Duplicate"), "got: \(note)")
        #expect(note.contains("swipe"), """
            P50b moved Duplicate off the long press and onto the row's \
            trailing swipe; the note must name where it is now: \(note)
            """)
    }

    /// A recurring job in `error` is terminal too, and its note must read as
    /// a sentence rather than a fragment — the reason clause is trimmed by
    /// punctuation, so every arm has to be checked, not just the one shape.
    @Test("the error-recurring arm reads as a sentence")
    func theErrorRecurringArmIsWellFormed() {
        let note = IOSCronViewModel.editorEnabledLockNote(
            job(kind: "cron", runAt: nil, state: "error", enabled: true), offer: .none)
        #expect(note.hasSuffix("."), "got: \(note)")
        #expect(!note.contains(" ."), "a stray space before a full stop: \(note)")
        #expect(!note.contains(".."), "a doubled full stop: \(note)")
    }

    /// The past-deadline one-shot's REASON carries an em dash of its own
    /// ("Can't resume \"X\" — the one-shot time (…) is in the past …"), so a
    /// note built by trimming the assembled sentence at its first `" — "`
    /// kept only the three words before it. The reason is a field now.
    @Test("the past-deadline arm keeps the whole reason, dash and all")
    func thePastDeadlineArmKeepsItsReason() {
        // Not terminal, paused, one-shot whose time has passed, and no
        // re-arm door: `refusesResume && !canRearm`.
        let past = job(kind: "once",
                       runAt: "2020-01-01T00:00:00Z",
                       state: "paused",
                       enabled: false)
        #expect(past.isTerminal == false, "the arm under test needs a NON-terminal job")
        let note = IOSCronViewModel.editorEnabledLockNote(past, offer: .none)
        #expect(note.contains("the one-shot time"), """
            The reason was cut at its own em dash — the note no longer says \
            WHY the toggle is locked: \(note)
            """)
        #expect(note.contains("is in the past"), "got: \(note)")
        #expect(note.contains("Close this editor"), "got: \(note)")
    }

    /// The terminal one-shot wording (`oneShotRefusalMessage`'s terminal
    /// arm) also carries an em dash mid-reason, and lost the clause after it
    /// the same way. Asserted on the pieces, because `resumeRefusalMessage`
    /// routes a terminal job to `terminalRefusalMessage`.
    @Test("the terminal one-shot's reason survives its own em dash")
    func theTerminalOneShotArmKeepsItsReason() {
        let parts = IOSCronViewModel.oneShotRefusalParts(job(), offer: .none)
        #expect(parts.reason.contains("a completed one-shot can't be resumed"), """
            The reason clause stops at the em dash: \(parts.reason)
            """)
        #expect(parts.remedy == "Duplicate it to schedule a new run.")
        #expect(parts.sentence == IOSCronViewModel.oneShotRefusalMessage(job(), offer: .none))
    }

    /// The list banner is unchanged — it is the surface where both remedies
    /// ARE one gesture away, and P50b's swipe action exists because of it.
    @Test("the list banner keeps naming its remedies")
    func theBannerIsUnchanged() {
        let banner = IOSCronViewModel.resumeRefusalMessage(job(), offer: .none)
        #expect(banner.contains("duplicate it"), "got: \(banner)")
        let rearm = IOSCronViewModel.resumeRefusalMessage(
            job(), offer: CronRecoveryOffer(canResume: false, canRearm: true))
        #expect(rearm.contains("use Resume & Run Now to re-arm it."), "got: \(rearm)")
    }
}
