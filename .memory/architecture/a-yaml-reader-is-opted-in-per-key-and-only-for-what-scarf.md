---
title: A YAML reader is opted in per KEY, and only for what Scarf writes
type: note
permalink: scarf/architecture/a-yaml-reader-is-opted-in-per-key-and-only-for-what-scarf
tags: [yaml, config-parsing, verification]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesYAML.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/YAMLScalar.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesConfig+YAML.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesPlatformSharedKeys.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesApprovalMode.swift, scarf/scarf/Core/Services/HermesFileService.swift]
source_paths_inferred: false
source_sha: ad0ae4671d479a80f21bd3a621364348fc3743fd
created: 2026-09-11
updated: 2026-09-13
reviewed: 2026-09-18
reviewed_by: audit:claude-code (background)
---

P41 of the round-4 whole-surface audit (commits 2fb7cc08, d4a3ab4d, 402442a1, 151cdd3e on `fix/whole-surface-audit-r4`). Scarf emits every config.yaml scalar through ONE rule (`YAMLScalar.quoteIfNeeded`) but reads config.yaml through TWO decoders on purpose — and which one a key gets is now an explicit list rather than an accident.

## Observations
- [invariant] A quote-escaping WRITER needs its un-escaping reader in the same place, but that reader cannot be widened globally: `HermesYAML.stripYAMLQuotes` reads arbitrary HERMES-written values, where a backslash-n inside double quotes means two literal characters. So `YAMLScalar.unquote` is opted in per KEY (`HermesYAML.scarfWrittenMapPaths` / `scarfWrittenListPaths`) and only for paths Scarf itself writes #yaml
- [gotcha] A per-key map opt-in has FOUR decode sites, not one: the list item, the map VALUE, the map KEY (a double-quoted key was taken verbatim, so a key Scarf wrote grew one backslash per save) and the folded-continuation re-strip. Miss the last and one key decodes differently folded than on one line #yaml
- [gotcha] A finding that calls a block Scarf-written has to be grepped for its WRITER before the reader is widened. `gateway.multiplex_profile_allowlist` was listed as one of three and has no writer at either spelling — Scarf writes only the sibling bool `multiplex_profiles`, through `hermes config set` #verification
- [gotcha] A TYPE gate on a YAML scalar runs on the RAW text, before unquoting, and QUOTING is half of it. PyYAML types the scalar before any Hermes reader sees it, so a quoted approvals.mode of no or false is a str that misses _VALID_MODES and resolves to manual, while the bare spelling is a bool that resolves to off. Scarf ran the gate one layer too late and rendered 'Never ask' on a host that asks before every guarded command #config-parsing
- [convention] When a shared emitter absorbs a bespoke one, the tests that pinned the bespoke SPELLING have to become tests of the RULE — `quoteIfNeeded` single-quotes where the deleted routine double-quoted, so a byte-exact assertion pins the copy you just deleted #testing

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]


## P41b — the scanner under the opt-in (`9f23018f`)

The per-key opt-in decides WHICH decoder runs. P41b found that the scan that
gets the key out of the line in the first place was wrong for the one style
the opt-in exists to serve.

- [gotcha] **`HermesYAML.closingQuoteIndex` knew `''` and not `\"`.** A
  DOUBLE-quoted key — the style `YAMLScalar.doubleQuoted` emits whenever the
  key carries a control character, i.e. precisely the case decision 10's KEY
  half was written for — closed its span at the escaped quote, failed the
  `rest.hasPrefix(":")` guard, and `parseNestedYAML` dropped the whole row.
  Silent until the next `setReasoningOverrides` save, which rewrites the block
  from what the editor holds and therefore DELETED the row from the file. One
  fixture shows it: `"gpt\x01\"x": high` beside `plain: low` reads back as
  `plain` alone #yaml
- [convention] **`HermesYAML.blockKeySpan` is now the one block-style key
  scanner.** It returns the key's RAW span (quotes included) plus the text
  after the separator; `parseNestedYAML` and `HermesFileService`'s MCP entry
  reader both go through it. The reader used to split on
  `trimmed.firstIndex(of: ":")`, so an env or header name containing a colon
  was written correctly as `'A: B': v` and read back as `'A` / `B': v` — and
  persisted that way on the next save #yaml
- [fact] **A key has a LENGTH limit and no quoting style raises it.** PyYAML
  refuses a simple key past 1024 characters of emitted token
  (`yaml/scanner.py:283-291`), measured from the token start to the `:`, so
  the two quote characters count against it. `YAMLScalar.exceedsSimpleKeyLimit`
  measures the emitted form for exactly that reason. The consequence is the
  same one this whole family shares: `load_config` discards the entire
  config.yaml layer (`gateway/config.py:775-791` @ `v2026.9.7`) #yaml


## P51 — the reader's TRIM, and the one place it must not apply (`76206b4d`)

Round-5 decision 14. The per-key opt-in decides which DECODER runs; P41b fixed the SCAN that
gets the key out of the line. P51 fixed the TRIM that runs on both.

- [gotcha] **`CharacterSet.whitespaces` is Unicode `Zs` plus tab; PyYAML's whitespace is
  neither.** PyYAML's scanner keeps U+00A0, U+3000, U+2009, U+1680, U+202F, U+205F and
  U+2000–U+200A as ordinary scalar/key/entry CONTENT. Verified on 6.0.3, leading and trailing,
  in the block value, the block key, the list item and both flow shapes: `model: gpt\u{A0}`
  loads as `{'model': 'gpt\xa0'}`. Since `yaml.safe_dump` emits such a value BARE, a value
  Hermes itself wrote rendered SHORT in Scarf and the next save PERSISTED the trimmed form —
  the same silent-rewrite family as the quote-doubling and escape-growth defects above, reached
  through the trim instead of the escape table. One `HermesYAML.yamlWhitespace` (space + tab)
  serves all seventeen reader trims #yaml
- [decision] **Tab stays in the narrowed set.** PyYAML refuses a tab in every position this
  parser would trim one from (`k: v\t`, `k:\tv` — both `ScannerError`, 6.0.3), so such a
  document does not load at all and `load_config` discards the whole config.yaml layer
  (`gateway/config.py:775-791` @ `v2026.9.7`). Trimming a character that only appears in a file
  Hermes refuses decides nothing
- [invariant] **A parser trim and a Python-`.strip()` mirror are DIFFERENT rules and must not be
  unified.** `HermesYAML.normalizedScalar` and `HermesReasoningEffort.normalizedLevel` keep the
  WIDE `.whitespacesAndNewlines` trim on purpose: they run just before a typed comparison, and
  every Hermes reader on that side calls `str.strip()` — `_bool_token`'s
  `str(value).strip().lower()` (`gateway/config.py:31`), `_normalize_approval_mode`'s
  `mode.strip().lower()` (`tools/approval_context.py:207`), `parse_reasoning_effort`'s
  `str(effort).strip().lower()` (`hermes_constants.py:884`), all @ `v2026.9.7`. Python's
  `str.strip()` removes all 29 `c.isspace()` characters, U+00A0 and the `Zs` block included, so
  `reasoning_effort: high\u{A0}` IS `high` to Hermes. Narrowing there would have made Scarf
  claim the host ignores a value it honours — the unsafe direction, again. A test pins the two
  rules disagreeing on one input #config-parsing
- [todo] **Two readers still carry the wide trim**, filed as `t-295ef4d2` with line numbers:
  `GatewayConfigWriter` (`:502`, `:594`, `:641`, `:644-645`) and `ProfileRoutesYAML` (ten
  sites). The latter matters more than it looks — `profile_routes` entries ARE Scarf-written
  through `YAMLScalar.quoteIfNeeded`, so its round trip is lossy in the rewriting direction.
  Both should take `HermesYAML.yamlWhitespace` rather than a private copy



## P57 — the FOLD, and the trim that ran outside the quotes (round 6)

P41b fixed the quote SCAN, P51 the TRIM's character set. P57 fixed where in the loop the
fold-continuation test runs, and which side of the quotes the `.strip()` mirror runs on.

- [gotcha] **`yaml.dump` has no `width=`, so a fold point lands wherever the spaces are — and a
  continuation line routinely BEGINS with `- ` or `#`.** Hermes emits through
  `atomic_yaml_write` → `yaml.dump(data, Dumper=IndentDumper, default_flow_style=False,
  sort_keys=False, allow_unicode=True)` (`utils.py:262-271` @ `v2026.9.7`), i.e. the emitter's
  default 80 columns. `parseNestedYAML`'s continuation join sat BELOW the comment skip and
  behind `!isListItem`, so a `- ` continuation was read as a list item (value truncated at the
  fold, plus a phantom `lists[<enclosing path>]` entry) and a `#` continuation was dropped as a
  comment — and because a `#` in the string is exactly what makes PyYAML SINGLE-quote it, that
  second case also left the value with a dangling opening `'`, which `normalizedScalar` then cut
  again at the ` #` it could now see. A PyYAML 6.0.3 oracle over **572 folded `yaml.dump`
  documents found 44** where Scarf disagreed with the loader; after the hoist, **0**. The test is
  nine fixtures captured verbatim from the emitter, with a lane that re-emits each one and pins
  the bytes #yaml
- [decision] **The `#` arm of that hoist is NARROWER than the `- ` arm, and the EMITTER is the
  reason.** A deeper `#` line can also be a genuine indented comment, which PyYAML discards
  (`gateway:` / `  port: 8080` / `      # c` / `  host: local` loads as
  `{'gateway': {'port': 8080, 'host': 'local'}}`, 6.0.3). The discriminator is that PyYAML never
  emits a PLAIN scalar whose continuation begins with `#` — a `#` after a space forces a quoting
  style — so a folded `#` continuation is ALWAYS inside a still-open quoted scalar.
  `HermesYAML.isOpenQuotedScalar` (over `closingQuoteIndex`, on the ACCUMULATED value so a
  multi-line fold keeps working) is that test, and the zero-occurrence claim is re-measured
  against the live emitter by a test rather than asserted in a comment. The `- ` arm needs no
  such narrowing: a genuine list item can never sit deeper than the sibling scalar before it,
  which is the same argument `lastScalarIndent` already carried #yaml
- [gotcha] **A `.strip()` mirror has to strip on the same SIDE of the quotes Python does.**
  `_bool_token` is `str(value).strip().lower()` (`gateway/config.py:29-32` @ `v2026.9.7`) over
  the object PyYAML loaded — and for a quoted scalar that object is the quoted BODY, so
  `require_mention: " false"` is `false` to Hermes. `boolishValue` and `HermesConfig+YAML`'s
  `boolTrueDefault` compared the body verbatim, recognised nothing, and fell to the caller's
  default — ON for a true-by-default key whose host had it OFF. New `HermesYAML.strippedScalar`
  = `normalizedScalar` + `.whitespacesAndNewlines` INSIDE the quotes; the outer trim and round-5
  decision 14's parser/mirror split are untouched, and a test pins the two functions disagreeing.
  This is P41b's `HermesApprovalMode.normalize` finding, two readers over #config-parsing
- [gotcha] **The int resolver is half of that reader, and P53b's port only answered ZERO.**
  `_bool_token` compares `str(int)`, so `01`, `+1`, `0x1`, `0b1` are all the token `"1"` (truthy)
  and `00`, `-0`, `0x0`, `0b0` are all `"0"` (falsy) — none of which a word compare matches.
  `pyYAMLIntBoolToken` extends `pyYAMLIntIsZero` with the only other value whose `str()` is a
  token: **one**, and only unsigned or `+`-signed, because `str(-1)` keeps its sign. Everything
  else (`2`, `16`, `-1`) stays `nil`, and a QUOTED spelling stays `nil` because it is a `str` no
  resolver touches. Oracle: **1041 disagreements in 2065 adversarial scalars for `boolishValue`
  and 525 for the true-by-default rule; 0 after** #config-parsing
- [gotcha] **A flat dotted key is not a block, and the prefix scan could not tell.**
  `HermesPlatformSharedKeys.isBlock` answered TRUE for `slack` on a hand-edited
  `slack.enabled: true`, because `values["slack.enabled"]` matches the `slack.` descendant
  prefix. PyYAML keeps that line as the independent top-level key `"slack.enabled"`, so
  `yaml_cfg.get("slack")` is `None`, `isinstance(None, dict)` is False, and `platform_section`
  (`gateway/config_loader.py:171-180` @ `v2026.9.7`) falls through to `platforms.slack` — while
  Scarf read from AND wrote to a top-level `slack:` section Hermes does not bridge, the write
  then creating the real block and unbridging every nested shared key beside it. `parseNestedYAML`
  had tracked these paths since P38 for the last-wins purge; `ParsedYAML` now SURFACES them as
  `dottedLiteralPaths` and `isBlock` excludes them — and their descendants, since
  `slack.enabled:` opened as a header is `{"slack.enabled": {…}}`, still not a `slack` dict
  #platforms



## P57b — the adversarial review of P57 (round 6)

`ccc21bcc`, `7e9f2ec2`, `172ded54`, `8dc79784` on `fix/whole-surface-audit-r6`. Two of P57's
three fixes had regressed something; two more defects were pre-existing in the same readers.
Full write-up and oracle counts: the **P57b** section of [[Hermes v0.21.1 Compatibility Decisions]].

- [invariant] **A trim is a per-READER claim about the Hermes side, not a reader-wide default.**
  `display.busy_ack_enabled` never reaches `_bool_token`: `_bridge_section_to_env` exports
  `str(section[key])` UNSTRIPPED (`gateway/run.py:1816-1821` @ `v2026.9.7`) and
  `gateway/run_busy.py:727` compares `.lower()` of that to the literal `"true"`. P57 gave it
  `strippedScalar` anyway, so quoted `' true'` — OFF on the host — drew ON in Scarf. Before
  routing a key through a `.strip()` mirror, open the reader that actually consumes it
  #config-parsing
- [gotcha] **The `["true","yes","on"]` word list is right only for a BARE scalar.** PyYAML's bool
  resolver turns all nine spellings into `True` → `str(True).lower()`; QUOTED, `'yes'`/`'on'` are
  the strings and DISABLE. The quotes are the whole difference — `mattermostRequireMention`'s
  shape, whose `pyYAMLTrue` set this reader now shares. The bare arm compares the LOWERED text
  for anything the resolver leaves a string, so `tRuE` enables and `oN` does not #config-parsing
- [gotcha] **A `.strip()` mirror must strip the DECODED string.** `strippedScalar` returned a
  double-quoted body verbatim, and `yaml.dump({"k": "false\t"})` really emits `k: "false\t"` —
  the escape is why the emitter chose double quotes. New `HermesYAML.unquotedScalar` applies
  `YAMLScalar.unquote`'s table to the quoted arm; `normalizedScalar` stays verbatim because its
  other caller RE-EMITS the value, and decoding there would rewrite the file #yaml
- [gotcha] **A dotted key is evidence against a section only when the dot CROSSES that section's
  boundary.** `slack:` + `  a.b:` + `    c: 1` is `{'slack': {'a.b': {'c': 1}}}` — a real `slack`
  dict — while `slack.enabled: true` at the top level is not. The PATH cannot separate them; only
  where the dot was WRITTEN can, so `ParsedYAML.dottedLiteralParentDepths` records `stack.count`
  and `isBlock` excludes on `parentDepth < sectionDepth`. The recorded-`maps` test runs under the
  same exclusion, or a literal `platforms.slack:` header under `gateway:` claims the nested
  section it only looks like #platforms
- [gotcha] **A `|`/`>` block scalar is not an empty section, and an opted-in key really carries
  one.** The header pushed a stack frame, so the body was parsed as YAML: `- ` lines became a
  phantom `lists[<key>]`, `#` lines vanished, and the value was never recorded. Hermes's own docs
  teach `agent:` / `  system_prompt: |` over a `#####` body
  (`optional-skills/security/godmode/SKILL.md:136-148` @ `v2026.9.7`), and
  `HermesPersonalities.parseUserDefined(yaml:)` reads
  `agent.personalities.<name>.system_prompt` — so a block-scalar personality prompt rendered
  EMPTY. `PendingBlockScalar` claims every line deeper than the KEY verbatim, with PyYAML's
  clip/strip/keep chomping and `>` folding (more-indented lines keep their breaks). 96/96
  oracle documents disagreed before, 0 after #yaml
- [convention] **A "0 disagreements" claim names the corpus it was measured on**, and the test
  re-measures that corpus's SIZE before asserting zero — otherwise a shrunken table and a fixed
  reader are indistinguishable. And a test that pins the DEFECT's spelling (`values[…] == nil`
  for a block-scalar header) has to become a test of the RULE #testing
