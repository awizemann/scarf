import Testing
import Foundation
@testable import ScarfCore

/// Pure-logic tests for the marker-block splice helpers in
/// `SecretsEnvBlock`. No Keychain access, no filesystem I/O — just
/// strings in, strings out. The Mac-side `KeychainEnvMirror` wraps
/// these with Keychain resolution + transport-aware writes; that
/// integration is covered separately in `KeychainEnvMirrorTests`.
@Suite("SecretsEnvBlock")
struct SecretsEnvBlockTests {

    // MARK: - envKeyName

    @Test func envKeyNameStandardCase() {
        #expect(
            SecretsEnvBlock.envKeyName(slug: "local-news", fieldKey: "api_token")
                == "SCARF_LOCAL_NEWS_API_TOKEN"
        )
    }

    @Test func envKeyNameNonAlphanumericChars() {
        // Dashes, underscores, dots, spaces all fold to single underscores.
        #expect(
            SecretsEnvBlock.envKeyName(slug: "foo.bar baz", fieldKey: "x-y-z")
                == "SCARF_FOO_BAR_BAZ_X_Y_Z"
        )
    }

    @Test func envKeyNameRunsCollapse() {
        // Three consecutive special chars produce a single underscore,
        // not three.
        #expect(
            SecretsEnvBlock.envKeyName(slug: "foo---bar", fieldKey: "a__b")
                == "SCARF_FOO_BAR_A_B"
        )
    }

    @Test func envKeyNameLeadingTrailingTrim() {
        // Leading/trailing dashes on the slug shouldn't produce
        // SCARF__... or trailing _ in the result.
        let key = SecretsEnvBlock.envKeyName(slug: "-foo-", fieldKey: "-bar-")
        #expect(key == "SCARF_FOO_BAR")
        #expect(!key.hasSuffix("_"))
        #expect(!key.contains("__"))
    }

    @Test func envKeyNameAllSymbolsFallsBackToUnnamed() {
        // Pathological input — slug is all special chars. Sanitizer
        // emits `UNNAMED` rather than the empty string, so the env
        // var name is still parseable.
        #expect(
            SecretsEnvBlock.envKeyName(slug: "!!!", fieldKey: "...")
                == "SCARF_UNNAMED_UNNAMED"
        )
    }

    // MARK: - renderBlock

    @Test func renderBlockEmptyEntriesReturnsEmpty() {
        // Empty entries is the documented "use removeBlock instead"
        // sentinel — renderBlock should not produce a block with
        // dangling markers.
        let result = SecretsEnvBlock.renderBlock(slug: "foo", entries: [])
        #expect(result.isEmpty)
    }

    @Test func renderBlockSortsEntries() {
        // Output is deterministic regardless of input order so two
        // runs with the same logical content produce byte-identical
        // bytes — load-bearing for the no-op-when-unchanged check
        // in the mirror's writeIfChanged.
        let aFirst = SecretsEnvBlock.renderBlock(
            slug: "foo",
            entries: [("ALPHA", "1"), ("BRAVO", "2")]
        )
        let bFirst = SecretsEnvBlock.renderBlock(
            slug: "foo",
            entries: [("BRAVO", "2"), ("ALPHA", "1")]
        )
        #expect(aFirst == bFirst)
        // Sanity: ALPHA precedes BRAVO in the output regardless of
        // insertion order.
        let alphaIdx = aFirst.range(of: "ALPHA")
        let bravoIdx = aFirst.range(of: "BRAVO")
        #expect(alphaIdx != nil && bravoIdx != nil)
        #expect(alphaIdx!.lowerBound < bravoIdx!.lowerBound)
    }

    @Test func renderBlockEmitsMarkersAroundEntries() {
        let result = SecretsEnvBlock.renderBlock(
            slug: "site-status-checker",
            entries: [("SCARF_SITE_STATUS_CHECKER_TOKEN", "abc")]
        )
        #expect(result.hasPrefix("# scarf-secrets:begin site-status-checker"))
        #expect(result.hasSuffix("# scarf-secrets:end site-status-checker"))
        #expect(result.contains("SCARF_SITE_STATUS_CHECKER_TOKEN=abc"))
    }

    /// Golden values: every right-hand side here was written to a scratch
    /// `.env` and loaded with Hermes's own loader
    /// (`hermes_cli.env_loader._load_dotenv_with_fallback` from the
    /// v2026.9.24 reference worktree's `.venv`, python-dotenv 1.2.2) under
    /// an empty environment, and each variable came back byte-identical to
    /// the left-hand side. The single-quoted `'it'\''s fine'` this replaced
    /// fails that parse (dotenv drops the line), and a single-quoted
    /// `${HOME}` was expanded by the loader's `parse_variables` pass.
    @Test func escapedValuesRoundTripThroughHermesDotenvLoader() {
        let cases: [(value: String, written: String)] = [
            ("hello world", "\"hello world\""),
            ("a#b", "\"a#b\""),
            ("a$b", "\"a$b\""),
            ("a\"b", "\"a\\\"b\""),
            ("a\\b", "\"a\\\\b\""),
            ("it's fine", "\"it's fine\""),
            ("x${HOME}y", "\"x${:-$}{HOME}y\""),
            ("p${a:-b}q", "\"p${:-$}{a:-b}q\""),
            ("${${", "\"${:-$}{${:-$}{\""),
            ("line1\nline2", "\"line1\\nline2\""),
            ("crlf\r\nend", "\"crlf\\r\\nend\""),
            ("$", "\"$\""),
            ("$$", "\"$$\""),
            ("trailing\\", "\"trailing${:-\\}\""),
            ("a'b\"c${d}e\\f", "\"a'b\\\"c${:-$}{d}e\\\\f\""),
            ("${}", "\"${:-$}{}\""),
            ("tab\there", "\"tab\there\""),
            ("abc-123_def", "abc-123_def"),
            ("\\n literal", "\"\\\\n literal\""),
            ("two\\\\", "\"two${:-\\}${:-\\}\""),
            ("\\", "\"${:-\\}\""),
            ("q\\\"", "\"q\\\\\\\"\""),
            ("a\\\\b", "\"a\\\\\\\\b\""),
        ]
        for (value, written) in cases {
            #expect(
                SecretsEnvBlock.escape(value) == written,
                "value \(value.debugDescription) escaped as \(SecretsEnvBlock.escape(value).debugDescription)"
            )
            let block = SecretsEnvBlock.renderBlock(slug: "x", entries: [("KEY", value)])
            #expect(block.contains("\nKEY=\(written)\n"))
            // One line per value, whatever it contains — the marker-based
            // splice depends on it.
            #expect(block.split(separator: "\n", omittingEmptySubsequences: false).count == 3)
        }
    }

    @Test func renderBlockLeavesPlainValuesUnquoted() {
        // No-special-chars values stay unquoted — readability + matches
        // the convention Hermes's existing ANTHROPIC_API_KEY entries
        // follow.
        let result = SecretsEnvBlock.renderBlock(
            slug: "x",
            entries: [("KEY", "abc-123_def")]
        )
        #expect(result.contains("\nKEY=abc-123_def\n"))
        #expect(!result.contains("KEY='abc-123_def'"))
    }

    // MARK: - applyBlock

    @Test func applyBlockToEmptyFile() {
        let block = sampleBlock(slug: "foo", entries: [("KEY", "value")])
        let result = SecretsEnvBlock.applyBlock(block, forSlug: "foo", to: "")
        #expect(result == block + "\n")
    }

    @Test func applyBlockToWhitespaceOnlyFile() {
        let block = sampleBlock(slug: "foo", entries: [("KEY", "value")])
        let result = SecretsEnvBlock.applyBlock(block, forSlug: "foo", to: "   \n  \n")
        // Whitespace-only treated like empty — block + newline, no
        // attempt to preserve the leading whitespace.
        #expect(result == block + "\n")
    }

    @Test func applyBlockAppendsToFileWithUserContent() {
        let existing = "ANTHROPIC_API_KEY=sk-test\nOPENAI_API_KEY=sk-other\n"
        let block = sampleBlock(slug: "foo", entries: [("KEY", "value")])
        let result = SecretsEnvBlock.applyBlock(block, forSlug: "foo", to: existing)
        // User content is preserved at the top.
        #expect(result.hasPrefix("ANTHROPIC_API_KEY=sk-test"))
        #expect(result.contains("OPENAI_API_KEY=sk-other"))
        // Block appended after a blank-line separator.
        #expect(result.contains("OPENAI_API_KEY=sk-other\n\n# scarf-secrets:begin foo"))
        // And ends with a trailing newline.
        #expect(result.hasSuffix("\n"))
    }

    @Test func applyBlockReplacesExistingBlockForSameSlug() {
        let oldBlock = sampleBlock(slug: "foo", entries: [("KEY", "old")])
        let newBlock = sampleBlock(slug: "foo", entries: [("KEY", "new")])
        let existing = "USER_VAR=something\n\n" + oldBlock + "\n"
        let result = SecretsEnvBlock.applyBlock(newBlock, forSlug: "foo", to: existing)
        #expect(result.contains("KEY=new"))
        #expect(!result.contains("KEY=old"))
        // User content above the block is preserved.
        #expect(result.contains("USER_VAR=something"))
    }

    @Test func applyBlockPreservesOtherSlugBlocks() {
        // The most important invariant — multiple project blocks
        // coexist in one file and editing one mustn't disturb the
        // other.
        let blockA = sampleBlock(slug: "alpha", entries: [("A_KEY", "1")])
        let blockB = sampleBlock(slug: "bravo", entries: [("B_KEY", "2")])
        let existing = blockA + "\n\n" + blockB + "\n"
        let updatedA = sampleBlock(slug: "alpha", entries: [("A_KEY", "1-updated")])
        let result = SecretsEnvBlock.applyBlock(updatedA, forSlug: "alpha", to: existing)
        // A was updated.
        #expect(result.contains("A_KEY=1-updated"))
        #expect(!result.contains("A_KEY=1\n"))
        // B is byte-identical.
        #expect(result.contains(blockB))
    }

    @Test func applyBlockIdempotent() {
        // Applying the output of one call back through applyBlock
        // with the same inputs produces the same string. Critical
        // for the launch reconciler — a no-op pass shouldn't keep
        // mutating the file.
        let block = sampleBlock(slug: "foo", entries: [("KEY", "value")])
        let existing = "USER_VAR=x\n"
        let once = SecretsEnvBlock.applyBlock(block, forSlug: "foo", to: existing)
        let twice = SecretsEnvBlock.applyBlock(block, forSlug: "foo", to: once)
        #expect(once == twice)
    }

    @Test func applyBlockEmptyBlockBehavesLikeRemove() {
        // Documented behaviour: passing an empty block is the same as
        // calling removeBlock — the splice path uses this when a
        // project's secrets are all cleared.
        let block = sampleBlock(slug: "foo", entries: [("KEY", "value")])
        let withBlock = "USER=x\n\n" + block + "\n"
        let viaApply = SecretsEnvBlock.applyBlock("", forSlug: "foo", to: withBlock)
        let viaRemove = SecretsEnvBlock.removeBlock(forSlug: "foo", from: withBlock)
        #expect(viaApply == viaRemove)
    }

    // MARK: - removeBlock

    @Test func removeBlockNoOpWhenAbsent() {
        let existing = "USER_VAR=hello\nOTHER=world\n"
        let result = SecretsEnvBlock.removeBlock(forSlug: "foo", from: existing)
        #expect(result == existing)
    }

    @Test func removeBlockStripsBlockOnly() {
        let block = sampleBlock(slug: "foo", entries: [("KEY", "value")])
        let existing = "USER_VAR=x\n\n" + block + "\n\nMORE_USER=y\n"
        let result = SecretsEnvBlock.removeBlock(forSlug: "foo", from: existing)
        #expect(!result.contains("scarf-secrets"))
        #expect(result.contains("USER_VAR=x"))
        #expect(result.contains("MORE_USER=y"))
    }

    @Test func removeBlockCollapsesAppendedBlankLineSeparator() {
        // Round-trip: append a block, then remove it. The blank line
        // we inserted at append time should be absorbed so repeated
        // install/uninstall cycles don't accumulate blank lines.
        let block = sampleBlock(slug: "foo", entries: [("KEY", "value")])
        let original = "USER_VAR=x\n"
        let appended = SecretsEnvBlock.applyBlock(block, forSlug: "foo", to: original)
        let removed = SecretsEnvBlock.removeBlock(forSlug: "foo", from: appended)
        // Removed content should be very close to the original — at
        // most one trailing newline difference. No accumulation of
        // blank lines across the cycle.
        #expect(removed.trimmingCharacters(in: .whitespacesAndNewlines)
                == original.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Slug-prefix collision

    @Test func slugPrefixCollisionIsolated() {
        // A file with both `foo` and `foo-bar` blocks; editing `foo`
        // must not match the `foo-bar` markers as a prefix-substring
        // of the begin-line.
        let blockShort = sampleBlock(slug: "foo", entries: [("SHORT", "1")])
        let blockLong = sampleBlock(slug: "foo-bar", entries: [("LONG", "2")])
        let existing = blockShort + "\n\n" + blockLong + "\n"
        let updatedShort = sampleBlock(slug: "foo", entries: [("SHORT", "1-updated")])
        let result = SecretsEnvBlock.applyBlock(updatedShort, forSlug: "foo", to: existing)
        // Short was updated.
        #expect(result.contains("SHORT=1-updated"))
        #expect(!result.contains("SHORT=1\n"))
        // Long block is byte-identical.
        #expect(result.contains(blockLong))
        // Both markers still present, exactly once each.
        #expect(occurrences(of: "# scarf-secrets:begin foo\n", in: result) == 1)
        #expect(occurrences(of: "# scarf-secrets:begin foo-bar\n", in: result) == 1)
    }

    @Test func removeBlockRespectsSlugPrefixIsolation() {
        let blockShort = sampleBlock(slug: "foo", entries: [("SHORT", "1")])
        let blockLong = sampleBlock(slug: "foo-bar", entries: [("LONG", "2")])
        let existing = blockShort + "\n\n" + blockLong + "\n"
        let result = SecretsEnvBlock.removeBlock(forSlug: "foo", from: existing)
        // foo gone, foo-bar preserved byte-identically.
        #expect(!result.contains("SHORT=1"))
        #expect(result.contains(blockLong))
    }

    // MARK: - Helpers

    private func sampleBlock(
        slug: String,
        entries: [(key: String, value: String)]
    ) -> String {
        SecretsEnvBlock.renderBlock(slug: slug, entries: entries)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var search = haystack.startIndex
        while let range = haystack.range(of: needle, range: search..<haystack.endIndex) {
            count += 1
            search = range.upperBound
        }
        return count
    }
}
