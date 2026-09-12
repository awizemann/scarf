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
