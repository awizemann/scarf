import Foundation

/// Reader **and** surgical writer for `<profile_dir>/profile.yaml` — the file
/// that carries a Hermes profile's Bot Mode identity.
///
/// ## Why a direct file write, and not the CLI
///
/// `hermes profile` has no verb that touches `ui_meta`. Verified against the
/// audited tag (v2026.8.31 / Hermes 0.21.0): `hermes_cli/subcommands/profile.py`
/// registers `list / use / create / delete / describe / show / alias / rename /
/// export / import / install / update / info`, and the only writer of
/// profile.yaml on the CLI side is `hermes_cli/profiles.write_profile_meta`
/// (:951-991), whose entire keyword surface is `description`,
/// `description_auto`, and `display_name`. There is no `ui_meta` argument
/// anywhere in the subcommand tree. So for the bot block a direct file write
/// is the only mechanism available to a CLI-driven client.
///
/// ## The CAS-bypass caveat (read this before adding a writer call site)
///
/// The Hermes **desktop** does not write this file directly either — it goes
/// through the gateway RPC `profiles.configure`, which keeps a per-key
/// revision counter in `_ui_meta_revisions` and rejects a stale write
/// (`tui_gateway/methods_profiles.py:780-863`; compare-and-swap semantics
/// pinned by `tests/tui_gateway/test_profiles_ui_meta_cas.py`). Scarf's direct
/// write has **no such interlock**: if Hermes Desktop edits the same bot
/// between Scarf's read and Scarf's write, Scarf wins and the desktop's edit
/// is lost (and vice versa — Scarf does not bump `_ui_meta_revisions`, so a
/// desktop client will not notice that the value changed underneath it).
///
/// This is an accepted, bounded risk for a single-user tool editing its own
/// bots, but it is a real one:
/// - Read immediately before writing; never write from a roster snapshot that
///   has been sitting in a view model.
/// - Never write on a timer, on focus change, or as a side effect of merely
///   *displaying* a bot. Only an explicit user save.
/// - If Scarf ever speaks the gateway control socket, move this write to
///   `profiles.configure` with `ui_meta_expected_revisions` and delete the
///   direct path.
///
/// ## Preservation contract
///
/// Bytes outside the three regions Scarf edits — the top-level `display_name`
/// / `description` / `description_auto` scalars and the
/// `ui_meta:` → `hermes-bots:` subtree — are left untouched, including
/// comments, key order, blank lines, and the file's line-ending flavor. Inside
/// the `hermes-bots` block, keys Scarf models are re-emitted in a stable order
/// and everything else rides along verbatim in
/// ``HermesBotIdentity/unknownMetaLines``. That is strictly more conservative
/// than Hermes' own writer, which `safe_load`s and `safe_dump`s the whole file
/// and drops every comment in it.
///
/// **Two documented exceptions, both confined to the managed block.**
/// 1. *Blank lines inside `hermes-bots:` are not preserved.* Modeled keys are
///    re-emitted in a stable order and unknown keys are appended after them,
///    so a blank line's position no longer means anything once the block is
///    rewritten; keeping it would move it somewhere it wasn't. Blank lines
///    everywhere ELSE in the file — including between `ui_meta`'s children —
///    are untouched, and the block's own trailing blank line is left outside
///    the replaced range.
/// 2. *Key order inside `hermes-bots:` is not preserved* (see
///    ``renderBotMeta`` for why no consumer depends on it).
///
/// The writer **refuses** (returns `nil`) rather than guessing whenever the
/// file is in a shape it cannot edit safely — see ``write(identity:into:)``.
public enum HermesBotProfileYAML {

    /// The `ui_meta` key Bot Mode owns.
    public static let botMetaKey = "hermes-bots"

    /// Conservative ceiling on the rendered `hermes-bots` block, mirroring the
    /// gateway's own guard: `profiles.configure` rejects a `ui_meta` payload
    /// whose `json.dumps` exceeds 65536 bytes (`methods_profiles.py:789-791`),
    /// because the block rides `profiles.list` on every roster paint. Scarf
    /// measures the YAML it is about to write instead of a JSON encoding it
    /// cannot reconstruct for verbatim-preserved lines — a proxy, but one that
    /// errs on the side of writing less.
    public static let maxBotMetaBytes = 65_536

    /// Keys inside `hermes-bots` that ``HermesBotIdentity`` models. Everything
    /// else is preserved verbatim.
    static let knownMetaKeys: Set<String> = [
        "title", "description", "color", "shape", "imageKind",
        "custom", "hidden", "pinned", "groups", "group", "created",
    ]

    /// Unquoted scalars PyYAML resolves to something Python considers falsy.
    /// Same set (and same rationale) as `ProfileRoutesYAML`.
    private static let falsyScalars: Set<String> = [
        "false", "no", "off", "0", "", "null", "~",
    ]

    // MARK: - Parse

    /// Parse a `profile.yaml` into a bot identity. Never throws and never
    /// returns nil: a missing, empty, or malformed file yields an unmanaged
    /// identity carrying just the profile's name and directory — exactly how
    /// Hermes itself degrades (`read_profile_meta` returns empty defaults on
    /// any exception, and `_is_bot_managed` returns `False`).
    public static func parse(
        _ yaml: String,
        profileName: String,
        profileDirectory: String
    ) -> HermesBotIdentity {
        var identity = HermesBotIdentity(
            profileName: profileName,
            profileDirectory: profileDirectory
        )

        let lines = normalized(yaml).components(separatedBy: "\n")

        // Top-level scalars. Hermes strips these on read (`str(...).strip()`),
        // so Scarf compares and renders the stripped form too.
        identity.displayName = scalar(named: "display_name", in: lines).map(unquote)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        identity.profileDescription = scalar(named: "description", in: lines).map(unquote)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        identity.descriptionIsAuto = truthy(scalar(named: "description_auto", in: lines) ?? "") ?? false

        guard let uiMeta = locate(key: "ui_meta", indent: 0, in: lines, from: 0, to: lines.count) else {
            return identity
        }
        // An inline value (`ui_meta: {}` / `ui_meta: null`) has no block body
        // and therefore no `hermes-bots` mapping — not bot-managed either way.
        guard uiMeta.inlineValue == nil,
              let bots = locateBotBlock(in: lines, uiMeta: uiMeta)
        else { return identity }

        // `_is_bot_managed` requires `isinstance(ui_meta["hermes-bots"], dict)`.
        // A bare `hermes-bots:` header with no body is `None` to PyYAML — NOT
        // a dict, so NOT bot-managed. `hermes-bots: {}` is an empty dict, so
        // it IS. Getting this backwards would show phantom bots for every
        // profile someone half-edited.
        if let inline = bots.inlineValue {
            identity.isBotManaged = inline.hasPrefix("{")
            return identity
        }
        guard !bots.bodyRange.isEmpty else { return identity }
        identity.isBotManaged = true

        applyMeta(from: bots, lines: lines, to: &identity)
        return identity
    }

    /// Read the modeled keys out of a located `hermes-bots` block, sweeping
    /// everything else into `unknownMetaLines`.
    private static func applyMeta(from block: Block, lines: [String], to identity: inout HermesBotIdentity) {
        let baseIndent = block.bodyIndent ?? (block.keyIndent + 2)
        var unknown: [String] = []

        var i = block.bodyRange.lowerBound
        while i < block.bodyRange.upperBound {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            // Comments ride along so a rewrite never eats the user's notes.
            if trimmed.hasPrefix("#") { unknown.append(dedent(line, by: baseIndent)); i += 1; continue }

            let indent = indentOf(line)
            // A bullet, or anything deeper than the mapping's own indent,
            // belongs to whatever key preceded it — which the key branch below
            // already consumed. Reaching here means it is orphaned; keep it.
            guard indent == baseIndent, !trimmed.hasPrefix("- "),
                  let colon = trimmed.firstIndex(of: ":") else {
                unknown.append(dedent(line, by: baseIndent))
                i += 1
                continue
            }

            let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // The key's continuation lines: bullets at its own indent, or
            // anything indented deeper.
            let bodyEnd = continuationEnd(from: i + 1, limit: block.bodyRange.upperBound, baseIndent: baseIndent, lines: lines)
            let hasBody = bodyEnd > i + 1

            guard knownMetaKeys.contains(key) else {
                for j in i..<bodyEnd { unknown.append(dedent(lines[j], by: baseIndent)) }
                i = bodyEnd
                continue
            }

            let value = unquote(rawValue.hasPrefix("#") ? "" : rawValue)
            switch key {
            case "title": identity.title = value
            case "description": identity.botDescription = value
            case "color": identity.color = value
            case "shape": identity.shape = value
            case "imageKind": identity.imageKind = value.isEmpty ? nil : .init(rawValue: value)
            case "custom": identity.custom = truthy(rawValue)
            case "hidden": identity.hidden = truthy(rawValue)
            case "pinned": identity.pinned = truthy(rawValue)
            case "created": identity.created = Int(value)
            case "group":
                // Explicit null clears it; the desktop types the legacy scalar
                // as `null | string` and writes null when ungrouped.
                identity.legacyGroup = (value.isEmpty || value == "null" || value == "~") ? nil : value
            case "groups":
                if rawValue.hasPrefix("[") {
                    identity.groups = HermesYAML.parseFlatFlowList(
                        String(rawValue.dropFirst().prefix(while: { $0 != "]" }))
                    )
                } else if hasBody {
                    identity.groups = bullets(in: (i + 1)..<bodyEnd, lines: lines)
                } else {
                    identity.groups = []
                }
            default: break
            }
            i = bodyEnd
        }

        identity.unknownMetaLines = unknown
    }

    // MARK: - Write

    /// Rewrite `profile.yaml` so it carries `identity`, touching nothing else.
    ///
    /// - Returns: the new file contents, or `nil` when the file is in a shape
    ///   this writer refuses to edit:
    ///   - a duplicate top-level `ui_meta:` (PyYAML's last-wins rule makes any
    ///     surgical edit ambiguous — and possibly invisible to Hermes);
    ///   - `ui_meta:` written as a **non-empty inline flow mapping**
    ///     (`ui_meta: {a: 1}`), which this line-oriented writer cannot split
    ///     without re-emitting a sibling key it does not model;
    ///   - a top-level `display_name` / `description` / `description_auto`
    ///     that carries a nested body instead of a scalar;
    ///   - a **duplicate `hermes-bots:`** inside `ui_meta` — PyYAML reads the
    ///     LAST, this writer's locator finds the FIRST, so an edit could be
    ///     silently invisible to Hermes (same rationale as the top-level
    ///     duplicate-key refusal);
    ///   - a **tab-indented** `ui_meta` body, which YAML forbids and this
    ///     space-counting writer would misread as an empty block (and then
    ///     append a second `hermes-bots` beside the hidden one);
    ///   - a rendered `hermes-bots` block over ``maxBotMetaBytes``, which the
    ///     gateway would reject anyway.
    ///
    ///   In every refusal case the caller must surface the file as
    ///   read-only rather than fall back to some other write — a partial
    ///   write here is somebody's bot roster.
    public static func write(identity: HermesBotIdentity, into yaml: String) -> String? {
        let source = normalized(yaml)
        guard let result = writeLF(identity: identity, into: source) else { return nil }
        return restoreLineEndings(result, matching: yaml)
    }

    /// Re-attach the source file's per-line terminators to the rewritten text.
    ///
    /// The old code flipped the WHOLE file to CRLF whenever a single `\r\n`
    /// appeared anywhere, which rewrote every untouched line in a
    /// mixed-ending file (and showed up as a whole-file diff to anything
    /// watching it). Lines that survive the edit keep the ending they had;
    /// lines Scarf actually wrote get the file's dominant ending. A pure-LF
    /// file — the overwhelmingly common case — takes the fast path and is
    /// byte-identical to before.
    private static func restoreLineEndings(_ result: String, matching original: String) -> String {
        guard original.contains("\r\n") else { return result }
        let rawLines = original.components(separatedBy: "\n")
        var content: [String] = []
        var endings: [String] = []
        content.reserveCapacity(rawLines.count)
        for raw in rawLines {
            if raw.hasSuffix("\r") {
                content.append(String(raw.dropLast()))
                endings.append("\r\n")
            } else {
                content.append(raw)
                endings.append("\n")
            }
        }
        let dominant = endings.filter { $0 == "\r\n" }.count * 2 >= endings.count ? "\r\n" : "\n"

        let outLines = result.components(separatedBy: "\n")
        var out = ""
        var cursor = 0
        for (index, line) in outLines.enumerated() {
            out += line
            guard index < outLines.count - 1 else { break }
            // Greedy re-sync: the writer only ever replaces contiguous
            // regions, so the next occurrence of this line at or after the
            // cursor is the line it came from.
            var matched: String?
            var probe = cursor
            while probe < content.count {
                if content[probe] == line { matched = endings[probe]; cursor = probe + 1; break }
                probe += 1
            }
            out += matched ?? dominant
        }
        return out
    }

    private static func writeLF(identity: HermesBotIdentity, into yaml: String) -> String? {
        var lines = yaml.components(separatedBy: "\n")

        // Refuse a file whose top-level ui_meta is ambiguous before changing
        // anything, so a refusal never leaves half an edit behind.
        let uiMetaHeaders = lines.indices.filter { indentOf(lines[$0]) == 0 && isKeyLine(lines[$0], named: "ui_meta") }
        if uiMetaHeaders.count > 1 { return nil }
        if let idx = uiMetaHeaders.first,
           let inline = inlineValue(of: lines[idx], key: "ui_meta"),
           inline.hasPrefix("{"), inline != "{}" {
            return nil
        }

        // Top-level scalars. `display_name` is cleared by REMOVING the key —
        // Hermes pops it rather than writing an empty string
        // (profiles.py:980-986), and the label formatter falls back to the id.
        guard let a = setScalar(
            "display_name",
            to: identity.displayName.isEmpty ? nil : quoted(identity.displayName),
            in: lines
        ) else { return nil }
        lines = a
        guard let b = setScalar(
            "description",
            to: identity.profileDescription.isEmpty ? nil : quoted(identity.profileDescription),
            in: lines
        ) else { return nil }
        lines = b
        // `description_auto` is only meaningful alongside a description, and
        // Hermes defaults it to False — so only write it when true, and drop
        // the key otherwise instead of leaving `false` litter behind.
        guard let c = setScalar(
            "description_auto",
            to: identity.descriptionIsAuto ? "true" : nil,
            in: lines
        ) else { return nil }
        lines = c

        return setBotBlock(identity: identity, in: lines)
    }

    /// Whether the rendered block fits the gateway's ceiling. Measured on the
    /// EXACT lines about to be written (audit fix): the previous code sized a
    /// `keyIndent: 2` rendering and then wrote a differently-indented one, so
    /// a deeply-indented file could sail past the guard it was supposed to be
    /// stopped by.
    private static func fitsSizeLimit(_ rendered: [String]) -> Bool {
        rendered.isEmpty || rendered.joined(separator: "\n").utf8.count <= maxBotMetaBytes
    }

    /// Tab-indented body under `ui_meta:`. YAML forbids tabs as indentation
    /// outright, so PyYAML raises on the file — but this writer's `indentOf`
    /// counts only spaces, which makes a tab-indented line look like column 0
    /// and hides the whole body. The block would then be "not found" and a
    /// SECOND `hermes-bots` appended beside the invisible first one. Refuse
    /// instead; the file is already unloadable and Scarf must not make it
    /// worse.
    private static func hasTabIndentedBody(after keyIndex: Int, in lines: [String]) -> Bool {
        var i = keyIndex + 1
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\t") { return true }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { i += 1; continue }
            // A line at column 0 ends `ui_meta`'s region.
            guard indentOf(line) > 0 else { return false }
            i += 1
        }
        return false
    }

    /// Every direct `hermes-bots` child of `ui_meta`, not just the first.
    /// PyYAML resolves duplicate keys LAST-wins while ``locateBotBlock``
    /// takes the FIRST, so editing one of several is a coin flip on whether
    /// Hermes ever sees the edit — the same rationale as the top-level
    /// duplicate-key refusal in ``setScalar``.
    private static func botBlockCount(in lines: [String], uiMeta: Block) -> Int {
        guard let childIndent = uiMeta.bodyIndent else { return 0 }
        var count = 0
        for i in uiMeta.bodyRange where indentOf(lines[i]) == childIndent
            && isKeyLine(lines[i], named: botMetaKey) {
            count += 1
        }
        return count
    }

    private static func setBotBlock(identity: HermesBotIdentity, in input: [String]) -> String? {
        var lines = input

        let uiMeta = locate(key: "ui_meta", indent: 0, in: lines, from: 0, to: lines.count)

        guard let uiMeta else {
            // No ui_meta at all. Nothing to remove; nothing to add when the
            // profile isn't bot-managed.
            let body = identity.isBotManaged ? renderBotMeta(identity, keyIndent: 2) : []
            guard !body.isEmpty else { return lines.joined(separator: "\n") }
            guard fitsSizeLimit(body) else { return nil }
            return append(block: ["ui_meta:"] + body, to: lines).joined(separator: "\n")
        }

        // `ui_meta: {}` — an empty inline map. Replace the whole line.
        if let inline = uiMeta.inlineValue {
            // Only `{}` reaches here; a populated flow map was refused above,
            // and any other scalar (`null`, `~`) carries nothing to lose.
            _ = inline
            let body = identity.isBotManaged ? renderBotMeta(identity, keyIndent: 2) : []
            if body.isEmpty {
                lines.remove(at: uiMeta.keyIndex)
                return lines.joined(separator: "\n")
            }
            guard fitsSizeLimit(body) else { return nil }
            lines.replaceSubrange(uiMeta.keyIndex...uiMeta.keyIndex, with: ["ui_meta:"] + body)
            return lines.joined(separator: "\n")
        }

        if hasTabIndentedBody(after: uiMeta.keyIndex, in: lines) { return nil }
        guard botBlockCount(in: lines, uiMeta: uiMeta) <= 1 else { return nil }

        let existing = locateBotBlock(in: lines, uiMeta: uiMeta)
        let metaIndent = existing?.keyIndent ?? uiMeta.bodyIndent ?? 2
        let rendered = identity.isBotManaged ? renderBotMeta(identity, keyIndent: metaIndent) : []
        guard fitsSizeLimit(rendered) else { return nil }

        if let existing {
            let replaceRange = existing.keyIndex..<max(existing.bodyRange.upperBound, existing.keyIndex + 1)
            if rendered.isEmpty {
                lines.replaceSubrange(replaceRange, with: [])
                // Removing the only child would leave a bare `ui_meta:` header,
                // which PyYAML loads as None — harmless, but noise Scarf put
                // there. Drop it when nothing else lives under it.
                if let after = locate(key: "ui_meta", indent: 0, in: lines, from: 0, to: lines.count),
                   after.inlineValue == nil, after.bodyRange.isEmpty {
                    lines.remove(at: after.keyIndex)
                }
                return lines.joined(separator: "\n")
            }
            lines.replaceSubrange(replaceRange, with: rendered)
            return lines.joined(separator: "\n")
        }

        guard !rendered.isEmpty else { return lines.joined(separator: "\n") }
        // Splice as the last child of `ui_meta:` so sibling keys keep their
        // position (and their comments).
        let insertAt = uiMeta.bodyRange.isEmpty ? uiMeta.keyIndex + 1 : uiMeta.bodyRange.upperBound
        lines.insert(contentsOf: rendered, at: insertAt)
        return lines.joined(separator: "\n")
    }

    /// Render the `hermes-bots:` key and its body.
    ///
    /// Modeled keys come first in a stable order, then every verbatim line.
    /// Key ORDER is not preserved from the source file: Hermes' own writer
    /// round-trips through `safe_dump` and keeps only dict insertion order,
    /// and the gateway rebuilds the mapping key-wise, so no consumer depends
    /// on it. Key *content* — including keys Scarf doesn't know — is.
    static func renderBotMeta(_ identity: HermesBotIdentity, keyIndent: Int) -> [String] {
        let content = keyIndent + 2
        var out = ["\(spaces(keyIndent))\(botMetaKey):"]
        func put(_ key: String, _ value: String) { out.append("\(spaces(content))\(key): \(value)") }

        if let v = identity.title { put("title", quoted(v)) }
        if let v = identity.botDescription { put("description", quoted(v)) }
        if let v = identity.color { put("color", quoted(v)) }
        if let v = identity.shape { put("shape", quoted(v)) }
        if let v = identity.imageKind { put("imageKind", quoted(v.rawValue)) }
        if let v = identity.custom { put("custom", v ? "true" : "false") }
        if let v = identity.hidden { put("hidden", v ? "true" : "false") }
        if let v = identity.pinned { put("pinned", v ? "true" : "false") }
        if let v = identity.legacyGroup { put("group", quoted(v)) }
        if !identity.groups.isEmpty {
            out.append("\(spaces(content))groups:")
            for group in identity.groups {
                out.append("\(spaces(content + 2))- \(quoted(group))")
            }
        }
        if let v = identity.created { put("created", String(v)) }
        for line in identity.unknownMetaLines {
            out.append(line.isEmpty ? "" : "\(spaces(content))\(line)")
        }
        // A block with a header but no body loads as None, which is NOT a
        // dict — i.e. not bot-managed. Emit an explicit empty mapping so a
        // bot with no metadata yet still reads back as managed.
        if out.count == 1 { out[0] = "\(spaces(keyIndent))\(botMetaKey): {}" }
        return out
    }

    // MARK: - Scalar surgery

    /// Set (or remove, with `value == nil`) a top-level scalar key.
    /// Returns nil when the key exists but carries a nested body — a shape
    /// this writer will not silently flatten.
    private static func setScalar(_ key: String, to value: String?, in lines: [String]) -> [String]? {
        var out = lines
        let matches = out.indices.filter { indentOf(out[$0]) == 0 && isKeyLine(out[$0], named: key) }
        // Duplicate top-level keys: PyYAML takes the last one. Editing one of
        // several is a coin flip on whether Hermes sees the edit.
        if matches.count > 1 { return nil }

        guard let idx = matches.first else {
            guard let value else { return out }
            return append(block: ["\(key): \(value)"], to: out)
        }
        // Nested body under a key Scarf expects to be a scalar.
        let bodyEnd = continuationEnd(from: idx + 1, limit: out.count, baseIndent: 0, lines: out)
        if bodyEnd > idx + 1 { return nil }

        if let value {
            out[idx] = "\(key): \(value)"
        } else {
            out.remove(at: idx)
        }
        return out
    }

    private static func append(block: [String], to lines: [String]) -> [String] {
        var out = lines
        // Files conventionally end with a trailing newline, which shows up as
        // a final empty component. Insert before it so we don't grow the file
        // by a blank line on every write.
        while let last = out.last, last.isEmpty { out.removeLast() }
        out.append(contentsOf: block)
        out.append("")
        return out
    }

    // MARK: - Block location

    struct Block {
        let keyIndex: Int
        let keyIndent: Int
        /// Range of body lines. Empty when the key has no block body.
        let bodyRange: Range<Int>
        /// Indent of the first content line of the body, when there is one.
        let bodyIndent: Int?
        /// Inline value written on the key's own line (`{}`, `null`, …), or
        /// nil for a block-bodied key.
        let inlineValue: String?
    }

    /// `hermes-bots` as a DIRECT child of `ui_meta`, never a grandchild.
    /// `ui_meta` holds one namespace per client, so a `hermes-bots` key
    /// nested inside a *sibling* namespace (`shared-room.hermes-bots`) is
    /// somebody else's data — reading it would invent a bot, and writing
    /// through it would corrupt the other client's block.
    private static func locateBotBlock(in lines: [String], uiMeta: Block) -> Block? {
        guard let childIndent = uiMeta.bodyIndent else { return nil }
        return locate(
            key: botMetaKey,
            indent: childIndent,
            in: lines,
            from: uiMeta.bodyRange.lowerBound,
            to: uiMeta.bodyRange.upperBound
        )
    }

    /// Locate `key:` within `[from, to)`. `indent == nil` accepts the first
    /// matching key at whatever indent it sits at (used for `hermes-bots`,
    /// whose parent's body indent isn't fixed at 2 in a hand-edited file).
    static func locate(key: String, indent: Int?, in lines: [String], from: Int, to: Int) -> Block? {
        var i = max(0, from)
        let end = min(to, lines.count)
        var found: Int?
        var keyIndent = indent ?? 0
        while i < end {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { i += 1; continue }
            let lineIndent = indentOf(line)
            if let indent, lineIndent < indent { break }
            if (indent == nil || lineIndent == indent), isKeyLine(line, named: key) {
                found = i
                keyIndent = lineIndent
                break
            }
            i += 1
        }
        guard let found else { return nil }

        let inline = inlineValue(of: lines[found], key: key)
        if inline != nil {
            return Block(keyIndex: found, keyIndent: keyIndent, bodyRange: found + 1..<found + 1, bodyIndent: nil, inlineValue: inline)
        }

        var last = found
        var bodyIndent: Int?
        var j = found + 1
        while j < end {
            let line = lines[j]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Blank/comment lines never EXTEND the block — otherwise a trailing
            // comment at the end of the file would be swallowed and rewritten.
            if trimmed.isEmpty || trimmed.hasPrefix("#") { j += 1; continue }
            guard indentOf(line) > keyIndent else { break }
            if bodyIndent == nil { bodyIndent = indentOf(line) }
            last = j
            j += 1
        }
        return Block(
            keyIndex: found,
            keyIndent: keyIndent,
            bodyRange: (last > found) ? (found + 1..<last + 1) : (found + 1..<found + 1),
            bodyIndent: bodyIndent,
            inlineValue: nil
        )
    }

    /// Index one past the last continuation line of the key that starts at
    /// `start - 1`: bullets at `baseIndent`, or anything deeper.
    private static func continuationEnd(from start: Int, limit: Int, baseIndent: Int, lines: [String]) -> Int {
        var last = start - 1
        var j = start
        while j < limit {
            let line = lines[j]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { j += 1; continue }
            let indent = indentOf(line)
            if indent > baseIndent || (indent == baseIndent && trimmed.hasPrefix("- ")) {
                last = j
                j += 1
                continue
            }
            break
        }
        return last + 1
    }

    private static func bullets(in range: Range<Int>, lines: [String]) -> [String] {
        var out: [String] = []
        for idx in range {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { continue }
            out.append(unquote(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
        }
        return out
    }

    // MARK: - Scalars

    private static func normalized(_ yaml: String) -> String {
        yaml.replacingOccurrences(of: "\r\n", with: "\n")
    }

    static func indentOf(_ line: String) -> Int { line.prefix(while: { $0 == " " }).count }

    private static func spaces(_ n: Int) -> String { String(repeating: " ", count: n) }

    private static func dedent(_ line: String, by amount: Int) -> String {
        String(line.dropFirst(min(indentOf(line), amount)))
    }

    private static func isKeyLine(_ line: String, named key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("\(key):")
    }

    /// The value written on the key's own line, or nil when the key has a
    /// block body. A trailing comment is not a value.
    private static func inlineValue(of line: String, key: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\(key):") else { return nil }
        let rest = String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty || rest.hasPrefix("#") { return nil }
        return rest
    }

    /// A top-level scalar's raw value, or nil when the key is absent.
    private static func scalar(named key: String, in lines: [String]) -> String? {
        // Last one wins, matching PyYAML's duplicate-key rule.
        var value: String?
        for line in lines where indentOf(line) == 0 && isKeyLine(line, named: key) {
            value = inlineValue(of: line, key: key) ?? ""
        }
        return value
    }

    /// PyYAML/Python truthiness of an unquoted scalar. `nil` when the key was
    /// absent; the caller decides the default.
    private static func truthy(_ raw: String) -> Bool? {
        let value = raw.prefix(while: { $0 != "#" }).trimmingCharacters(in: .whitespaces).lowercased()
        return !falsyScalars.contains(value)
    }

    /// Characters that a **single-quoted** YAML scalar cannot carry on one
    /// line: every C0 control (newline included), DEL, and the three extra
    /// Unicode line breaks YAML 1.1 recognizes (NEL, LS, PS).
    ///
    /// This set is the whole reason `quoted` has two arms. A single-quoted
    /// scalar escapes exactly one thing — `''` for a literal quote — and has
    /// no escape for a line break at all, so emitting `'line1\nline2'` with a
    /// REAL newline produces a *multi-line flow scalar*. Verified against
    /// PyYAML 6.0.3, that fails in two distinct ways, both reachable from the
    /// editor's multi-line description field:
    ///
    /// 1. **Silent value destruction (the common case).** YAML line-folding
    ///    turns every interior newline into a space and every blank line into
    ///    a single newline. The user's paragraphs come back as one run-on
    ///    line — and because Scarf re-reads the file before the next save,
    ///    the mangled form is what gets persisted. Cumulative, and invisible.
    /// 2. **Total metadata loss (the sharp case).** A line that is exactly
    ///    `---` or `...` — ordinary in pasted prose or markdown — terminates
    ///    the document mid-scalar and PyYAML raises on the whole file.
    ///    Hermes' `read_profile_meta` swallows any exception and returns
    ///    empty defaults, and `_is_bot_managed` then returns False: the
    ///    profile loses `display_name`, `description`, the entire
    ///    `hermes-bots` block, and drops out of the bot roster entirely.
    private static func requiresDoubleQuoting(_ raw: String) -> Bool {
        raw.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
                || scalar.value == 0x85 || scalar.value == 0x2028 || scalar.value == 0x2029
        }
    }

    /// A YAML **double-quoted** scalar — the one flow style with escapes, and
    /// therefore the only single-line form that can carry a newline. PyYAML
    /// decodes `\n` / `\t` / `\xNN` / `\uNNNN` here exactly as written, so a
    /// value round-trips to the same Swift string it came from. Hermes' own
    /// writer would have chosen a block or double-quoted scalar for the same
    /// input (`atomic_yaml_write` → `yaml.safe_dump`), so nothing downstream
    /// is surprised by the style; this is just the form a line-oriented
    /// writer can own.
    private static func doubleQuoted(_ raw: String) -> String {
        var out = "\""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02x", scalar.value)
                } else if scalar.value == 0x85 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// The inverse of ``quoted`` — decode a flow scalar the way PyYAML does.
    ///
    /// Kept local to this type rather than folded into
    /// `unquote` (which every other parser shares and
    /// which only strips the outer pair): `hermes-bots` is the one block
    /// Scarf both reads AND writes, so it is the one block that has to
    /// round-trip escapes exactly, and widening the shared helper would
    /// change the meaning of every unrelated `\` in a Hermes config.
    static func unquote(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        if raw.first == "'" && raw.last == "'" {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        guard raw.first == "\"" && raw.last == "\"" else { return raw }
        var out = ""
        var it = Array(raw.dropFirst().dropLast())
        var i = 0
        func hex(_ count: Int) -> String? {
            guard i + count <= it.count else { return nil }
            let digits = String(it[i..<(i + count)])
            guard digits.allSatisfy(\.isHexDigit),
                  let value = UInt32(digits, radix: 16),
                  let scalar = Unicode.Scalar(value) else { return nil }
            i += count
            return String(Character(scalar))
        }
        while i < it.count {
            let c = it[i]
            i += 1
            guard c == "\\", i < it.count else { out.append(c); continue }
            let esc = it[i]
            i += 1
            switch esc {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "0": out.append("\0")
            case "a": out.append("\u{07}")
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "v": out.append("\u{0B}")
            case "e": out.append("\u{1B}")
            case "\\": out.append("\\")
            case "\"": out.append("\"")
            case "/": out.append("/")
            case "x": out.append(hex(2) ?? "\\x")
            case "u": out.append(hex(4) ?? "\\u")
            case "U": out.append(hex(8) ?? "\\U")
            default: out.append(esc)
            }
        }
        it = []
        return out
    }

    /// Quote only when the value would otherwise change meaning — same rule as
    /// `ProfileRoutesWriter.quoted`, so ordinary titles stay readable — with
    /// one hard rule layered on top: a value carrying a line break or any
    /// other control character is emitted as a **double-quoted** scalar,
    /// never a single-quoted one. See ``requiresDoubleQuoting``.
    ///
    /// Post-condition, and the invariant every caller relies on: for ANY
    /// input string this returns a single line of valid YAML that PyYAML
    /// loads back as that exact string.
    static func quoted(_ raw: String) -> String {
        if raw.isEmpty { return "''" }
        if requiresDoubleQuoting(raw) { return doubleQuoted(raw) }
        let needsQuoting = raw.contains(":")
            || raw.contains("#")
            || raw.contains("&")
            || raw.contains("*")
            || raw.contains(">")
            || raw.contains("|")
            || raw.contains("{")
            || raw.contains("[")
            || raw.contains(",")
            || raw.contains("\n")
            || raw.first == "@"
            || raw.first == "-"
            || raw.first == "?"
            || raw.first == "!"
            || raw.first == "%"
            || raw.first == " "
            || raw.last == " "
            || raw.first == "\""
            || raw.first == "'"
            || Double(raw) != nil
            || ["true", "false", "null", "yes", "no", "on", "off", "~"].contains(raw.lowercased())
        if !needsQuoting { return raw }
        return "'\(raw.replacingOccurrences(of: "'", with: "''"))'"
    }
}
