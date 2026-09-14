import Foundation

/// Direct YAML editor for top-level `<platform>.allowed_<kind>:` list blocks.
/// Hermes v0.16 reads gateway allowlists from top-level platform sections
/// (`slack.allowed_channels`, `telegram.allowed_chats`, …) — NOT from
/// `gateway.platforms.<platform>.*`. `hermes config set` stringifies arrays
/// (the same gotcha that forced Home Assistant's watch lists to stay
/// read-only), so the Messaging Gateway editor sidesteps the CLI for these
/// keys by editing `~/.hermes/config.yaml` directly.
///
/// **Pure-function `setList`** is the heart of the editor — it splits the
/// YAML into lines, finds (or creates) the targeted block, and splices the
/// new items in while preserving every byte outside the block. The async
/// `saveList` wrapper wires it through `ServerContext.readText` /
/// `writeText`, so the same code path works on `.local` and `.ssh` servers
/// — local goes through `LocalTransport`, remote round-trips via SCP.
///
/// **Merge, don't clobber.** When the top-level `<platform>:` section already
/// exists (e.g. it holds `slack.reply_to_mode` or `busy_ack_enabled`), the
/// allowlist key is spliced in alongside its siblings, which stay
/// byte-for-byte. Only when the section is entirely absent do we append a
/// fresh `<platform>:` scaffold.
///
/// **Scalar fields don't go through here.** `gateway_restart_notification`
/// (and the legacy per-platform `busy_ack_enabled`) are scalars that
/// `hermes config set` handles cleanly — `GatewayBehaviorViewModel`
/// routes those through `PlatformSetupHelpers.saveForm` like every other
/// platform toggle.
///
/// **Why not use a real YAML library?** Same answer as everywhere else in
/// Scarf: zero external dependencies. The Hermes config flavor is a tightly
/// scoped subset (indent-based blocks, scalar-or-list values, no anchors /
/// aliases / flow style), and the targeted edit doesn't need to understand
/// the full grammar — only "find this block, replace it, preserve the rest".
public enum GatewayConfigWriter {

    /// Result of a surgical YAML edit.
    ///
    /// `.refused` is the load-bearing case: the file holds a shape this
    /// line-oriented editor cannot rewrite without risking data loss (a
    /// non-empty inline flow mapping for the section, or an item carrying a
    /// literal newline). Refusing beats the old behaviour, which fell
    /// through to "section missing" and appended a DUPLICATE top-level key
    /// — PyYAML resolves duplicates last-wins, so the original section's
    /// siblings were silently discarded.
    public enum WriteOutcome: Sendable, Equatable {
        /// The edit applied; payload is the new file text.
        case updated(String)
        /// The file already says what the caller asked for.
        case unchanged
        /// The editor declined; payload is a human-readable reason. The
        /// file must NOT be written.
        case refused(String)

        /// The text to write, or nil when there is nothing to write.
        public var text: String? {
            if case .updated(let s) = self { return s }
            return nil
        }
    }

    /// Insert or replace the top-level `<platform>.<key>:` block in the YAML,
    /// preserving everything else byte-for-byte.
    ///
    /// - When `items` is empty, the block (and only the block — siblings
    ///   stay) is removed from the YAML if present, and the function is a
    ///   no-op if the block was already absent.
    /// - When the top-level `<platform>:` section exists but the `<key>:`
    ///   leaf is missing, the new block is spliced into the existing section
    ///   alongside any sibling keys (which stay byte-for-byte).
    /// - When the `<platform>:` section is absent and `items` is non-empty,
    ///   the function appends a `<platform>:` scaffold at the end of the
    ///   file. This keeps the function idempotent on round-trip but means
    ///   the new block is appended rather than spliced into the middle of
    ///   the file — preserving the surrounding YAML byte-for-byte.
    /// - When the block is present, its bullet rows are replaced with the
    ///   new items at the block's OWN indent (derived from the file, not
    ///   assumed to be 2/4 — a 4-space-indented config used to get an
    ///   indent-2 key spliced into it, which PyYAML rejects outright, and a
    ///   PyYAML failure makes Hermes discard the whole config.yaml layer).
    ///   Items containing YAML-special characters are single-quoted
    ///   defensively.
    ///
    /// Refusal (see ``WriteOutcome``) is reported as the unchanged input by
    /// this String-returning entry point; callers that must distinguish
    /// "declined" from "already correct" use ``setListChecked``.
    public static func setList(
        in yaml: String,
        platform: String,
        key: String,
        items: [String]
    ) -> String {
        setListChecked(in: yaml, platform: platform, key: key, items: items).text ?? yaml
    }

    /// ``setList`` with the refusal case visible to the caller.
    public static func setListChecked(
        in yaml: String,
        platform: String,
        key: String,
        items: [String]
    ) -> WriteOutcome {
        // Preserve the file's line-ending flavor: work on LF internally,
        // re-emit CRLF on output when the input used CRLF (a CRLF file
        // previously failed every `trimmed ==` match, so the section was
        // "missing" and a DUPLICATE top-level section was appended — which
        // PyYAML resolves last-wins, clobbering the original section).
        normalizedRoundTrip(yaml) { normalized in
            setListLF(in: normalized, platform: platform, key: key, items: items)
        }
    }

    private static func setListLF(
        in yaml: String,
        platform: String,
        key: String,
        items: [String]
    ) -> WriteOutcome {
        let trimmedItems = items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let bad = trimmedItems.first(where: containsLineBreak) {
            return .refused(
                "\(platform).\(key): entry contains a line break, which cannot be written "
                + "as a single YAML row (\(debugSnippet(bad)))."
            )
        }

        var lines = yaml.components(separatedBy: "\n")
        switch expandTopLevelFlowMapping(&lines, section: platform) {
        case .refused(let why):
            return .refused(why)
        case .none, .expanded:
            break
        }

        // Locate `<key>:` whose parent is the top-level `<platform>:` section.
        let location = locateBlock(in: lines, platform: platform, key: key)

        let updated: String
        switch location {
        case .found(let blockRange, let indents, let blockScalar):
            updated = replaceBlock(
                in: lines,
                blockRange: blockRange,
                key: key,
                items: trimmedItems,
                keyIndent: indents.key,
                itemIndent: indents.item,
                blockScalar: blockScalar
            )
        case .platformPresentKeyMissing(let insertAfter, let rewriteHeaderAt, let indents):
            if trimmedItems.isEmpty { return .unchanged }
            if let rewriteHeaderAt {
                lines[rewriteHeaderAt] = rewriteFlowEmptyHeaderToBlock(lines[rewriteHeaderAt])
            }
            updated = spliceNewKey(
                lines: lines,
                insertAfterLineIndex: insertAfter,
                key: key,
                items: trimmedItems,
                keyIndent: indents.key,
                itemIndent: indents.item
            )
        case .platformMissing:
            if trimmedItems.isEmpty { return .unchanged }
            updated = appendScaffold(
                yaml: lines.joined(separator: "\n"),
                platform: platform,
                key: key,
                items: trimmedItems
            )
        }
        return updated == yaml ? .unchanged : .updated(updated)
    }

    /// Insert or replace a nested `key: value` MAP block under a top-level
    /// section — same surgical contract as `setList` (byte-for-byte outside
    /// the block, key removed entirely when `pairs` is empty), but the block
    /// body is `<mapKey>: <value>` rows instead of bullets, at the block's
    /// own derived indent. Used by the v0.20 `agent.reasoning_overrides`
    /// editor (`hermes config set` cannot write dicts). Map keys containing
    /// YAML structure characters are single-quoted; pair order is preserved
    /// as given.
    public static func setMap(
        in yaml: String,
        section: String,
        key: String,
        pairs: [(key: String, value: String)]
    ) -> String {
        setMapChecked(in: yaml, section: section, key: key, pairs: pairs).text ?? yaml
    }

    /// ``setMap`` with the refusal case visible to the caller.
    public static func setMapChecked(
        in yaml: String,
        section: String,
        key: String,
        pairs: [(key: String, value: String)]
    ) -> WriteOutcome {
        // Same CRLF round-trip contract as `setList` — see the comment there.
        normalizedRoundTrip(yaml) { normalized in
            setMapLF(in: normalized, section: section, key: key, pairs: pairs)
        }
    }

    private static func setMapLF(
        in yaml: String,
        section: String,
        key: String,
        pairs: [(key: String, value: String)]
    ) -> WriteOutcome {
        let trimmedPairs = pairs.filter {
            !$0.key.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if let bad = trimmedPairs.first(where: { containsLineBreak($0.key) || containsLineBreak($0.value) }) {
            return .refused(
                "\(section).\(key): entry contains a line break, which cannot be written "
                + "as a single YAML row (\(debugSnippet(bad.key + ": " + bad.value)))."
            )
        }

        var lines = yaml.components(separatedBy: "\n")
        switch expandTopLevelFlowMapping(&lines, section: section) {
        case .refused(let why):
            return .refused(why)
        case .none, .expanded:
            break
        }

        func entryRows(_ indent: Int) -> [String] {
            trimmedPairs.map {
                "\(spaces(indent))\(yamlQuoteIfNeeded($0.key)): \(yamlQuoteIfNeeded($0.value))"
            }
        }

        let updated: String
        switch locateBlock(in: lines, platform: section, key: key) {
        case .found(let blockRange, let indents, let blockScalar):
            var newLines = Array(lines.prefix(blockRange.lowerBound))
            let comments = blockScalar
                ? PreservedComments(headerComment: nil, interior: [])
                : preservedComments(in: lines, blockRange: blockRange, key: key)
            if !trimmedPairs.isEmpty {
                newLines.append("\(spaces(indents.key))\(key):\(comments.headerSuffix)")
                newLines.append(contentsOf: comments.interior)
                newLines.append(contentsOf: entryRows(indents.item))
            } else {
                newLines.append(contentsOf: comments.interior)
            }
            let tailStart = blockRange.upperBound + 1
            if tailStart < lines.count {
                newLines.append(contentsOf: lines.suffix(from: tailStart))
            }
            updated = newLines.joined(separator: "\n")
        case .platformPresentKeyMissing(let insertAfter, let rewriteHeaderAt, let indents):
            if trimmedPairs.isEmpty { return .unchanged }
            if let rewriteHeaderAt {
                lines[rewriteHeaderAt] = rewriteFlowEmptyHeaderToBlock(lines[rewriteHeaderAt])
            }
            var newLines = Array(lines.prefix(insertAfter + 1))
            newLines.append("\(spaces(indents.key))\(key):")
            newLines.append(contentsOf: entryRows(indents.item))
            if insertAfter + 1 < lines.count {
                newLines.append(contentsOf: lines.suffix(from: insertAfter + 1))
            }
            updated = newLines.joined(separator: "\n")
        case .platformMissing:
            if trimmedPairs.isEmpty { return .unchanged }
            var trimmed = lines.joined(separator: "\n")
            while trimmed.hasSuffix("\n\n") { trimmed.removeLast() }
            if !trimmed.isEmpty && !trimmed.hasSuffix("\n") { trimmed.append("\n") }
            var newLines: [String] = []
            if !trimmed.isEmpty { newLines.append("") }
            newLines.append("\(section):")
            newLines.append("  \(key):")
            newLines.append(contentsOf: entryRows(4))
            newLines.append("")
            updated = trimmed + newLines.joined(separator: "\n")
        }
        return updated == yaml ? .unchanged : .updated(updated)
    }

    /// Async wrapper that reads, mutates, writes via the given context.
    /// Returns `false` on read failure, write failure, or an editor refusal
    /// (a config.yaml shape this line editor cannot rewrite safely).
    ///
    /// **Call this off the main actor.** `ServerContext.readText` /
    /// `writeText` are `nonisolated` but genuinely blocking: on an `.ssh`
    /// server they are a synchronous SCP round-trip, and `GuardedTextFile`
    /// additionally waits on config.yaml's cross-process write lock. Callers
    /// (e.g. `GatewayBehaviorViewModel`) wrap it in `Task.detached` for
    /// exactly that reason — charter C10 forbids blocking the main actor on
    /// process spawns and remote I/O.
    public static func saveList(
        context: ServerContext,
        platform: String,
        key: String,
        items: [String]
    ) -> Bool {
        let path = context.paths.configYAML
        // GUARDED. `readText(path) ?? ""` used to collapse "unreadable" into
        // "empty", so a blipped read published a config.yaml holding nothing
        // but this one allowlist. `GuardedTextFile` is the single shared
        // guard for every config.yaml writer; a refusal reports as the same
        // `false` this function already returns for a write failure.
        //
        // SERIALIZED (GW-F3 / DI H4): `mutate` holds config.yaml's write
        // lock from the read to the publish, so a Settings direct-YAML save
        // (or the Kanban enabler) can no longer splice its section into
        // bytes this rewrite is about to replace. Contention past the wait
        // bound reports as the same `false` — never a hang.
        let file = GuardedTextFile(context: context, label: "config.yaml")
        do {
            try file.mutate(path) { loaded in
                switch setListChecked(in: loaded.text, platform: platform, key: key, items: items) {
                case .updated(let text): return text
                case .unchanged: return nil          // already correct
                case .refused(let why): throw WriteRefusal(reason: why)
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Thrown by ``saveList`` when the editor declines the edit, so a
    /// refusal cannot be mistaken for "already correct".
    struct WriteRefusal: Error {
        let reason: String
    }

    // MARK: - Internals

    /// Run `body` on a framing-normalized copy (no BOM, LF line endings)
    /// and restore the framing on output, so a BOM'd and/or CRLF
    /// config.yaml survives the write byte-for-byte outside the edited key.
    ///
    /// **BOM.** A leading U+FEFF is not in `.whitespaces` OR
    /// `.whitespacesAndNewlines` (exactly as `\r` was not, before P10), so
    /// it stayed glued to the first line's content and defeated every
    /// `trimmed == "slack:"` header match. The file's FIRST top-level
    /// section therefore read as MISSING and the write appended a DUPLICATE
    /// `<platform>:` block — PyYAML resolves duplicates last-wins, so the
    /// original section's siblings were silently lost. Stripped here once
    /// and re-prefixed on the way out.
    ///
    /// **Line endings are restored PER LINE.** The old code re-emitted CRLF
    /// on any file that contained one `\r\n`, converting every LF-only line
    /// in a mixed file — a wholesale rewrite, which is the one thing this
    /// editor promises never to do. `YAMLLineEndings.restore` (lifted from
    /// `HermesBotProfileYAML`, which solved this first) gives every surviving
    /// line back the terminator it had and the newly written rows the file's
    /// dominant one. A pure-LF file takes the fast path and is byte-identical.
    private static func normalizedRoundTrip(
        _ yaml: String,
        _ body: (String) -> WriteOutcome
    ) -> WriteOutcome {
        if yaml.hasPrefix(YAMLScalar.bom) {
            switch normalizedRoundTrip(YAMLScalar.strippingBOM(yaml), body) {
            case .updated(let text): return .updated(YAMLScalar.bom + text)
            case .unchanged: return .unchanged
            case .refused(let why): return .refused(why)
            }
        }
        guard yaml.contains("\r\n") else { return body(yaml) }
        switch body(YAMLLineEndings.normalized(yaml)) {
        case .updated(let text):
            return .updated(YAMLLineEndings.restore(text, matching: yaml))
        case .unchanged:
            return .unchanged
        case .refused(let why):
            return .refused(why)
        }
    }

    /// True when `s` carries a CR or LF anywhere. See
    /// ``YAMLScalar/containsLineBreak(_:)`` — one implementation, shared
    /// with the MCP-entry writers.
    private static func containsLineBreak(_ s: String) -> Bool {
        YAMLScalar.containsLineBreak(s)
    }

    private static func debugSnippet(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    }

    /// Indents derived from the file being edited — never assumed.
    private struct BlockIndents {
        let key: Int
        let item: Int
    }

    /// Result of locating the targeted block in the YAML line array.
    private enum BlockLocation {
        /// Block found; the closed range covers the header line + all bullet
        /// rows attributed to it. Replacing this slice with the new block
        /// completes the edit.
        /// `blockScalar` is true when the header was `key: |` / `key: >`
        /// (with any chomp/indent indicator) and the range therefore covers
        /// the header PLUS the scalar's literal body lines. Those body lines
        /// are text, not YAML, so none of them is preserved as a comment.
        case found(ClosedRange<Int>, BlockIndents, blockScalar: Bool)
        /// The top-level `<platform>:` section exists, but the leaf `<key>:`
        /// is absent under it. `insertAfter` is the line index after which
        /// the new key should be inserted (last line in the platform's
        /// block, or the platform header itself if the body is empty).
        case platformPresentKeyMissing(insertAfter: Int, rewriteHeaderAt: Int?, indents: BlockIndents)
        /// The top-level `<platform>:` section is missing entirely.
        case platformMissing
    }

    private static func locateBlock(
        in lines: [String],
        platform: String,
        key: String
    ) -> BlockLocation {
        // Walk top-to-bottom looking for `<platform>:` at indent 0.
        guard let platformIdx = firstIndex(
            of: lines,
            headerLineEqualTo: "\(platform):",
            indent: 0
        ) else {
            // Hermes emits a preserved-but-empty section flow-style:
            // `slack: {}` (`_strip_default_values` preserve_keys). That IS
            // the section — missing it here used to append a DUPLICATE
            // top-level `slack:` block, which PyYAML resolves last-wins but
            // leaves the file malformed for stricter parsers. Treat it as
            // an existing empty section; the write replaces the inline `{}`
            // with a block body (see `rewriteFlowEmptyHeaderToBlock`).
            // (A NON-empty inline mapping is expanded to block rows before
            // we get here — see `expandTopLevelFlowMapping`.)
            if let flowIdx = firstIndex(of: lines, flowEmptyHeaderFor: platform) {
                return .platformPresentKeyMissing(
                    insertAfter: flowIdx,
                    rewriteHeaderAt: flowIdx,
                    indents: BlockIndents(key: 2, item: 4)
                )
            }
            return .platformMissing
        }

        // Inside the platform block, find `<key>:` at the section's OWN body
        // indent (a 4-space-indented section is legal YAML and common in
        // hand-written configs), OR the end of the platform's body if the
        // key is missing.
        var bodyIndent: Int?
        var keyIdx: Int?
        var keyIsBlockScalar = false
        var i = platformIdx + 1
        var lastBodyIdx = platformIdx
        while i < lines.count {
            let line = lines[i]
            let indent = leadingSpaces(line)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }
            if indent == 0 {
                // Out of the platform's block (next top-level section).
                break
            }
            if bodyIndent == nil { bodyIndent = indent }
            if indent == bodyIndent, let kind = keyLineKind(trimmed: trimmed, key: key) {
                switch kind {
                case .blockHeader:
                    keyIdx = i
                case .blockScalarHeader:
                    keyIdx = i
                    keyIsBlockScalar = true
                case .inlineValue:
                    // `key: {…}` / `key: […]` / `key: scalar` — the whole
                    // block is this single line; replacing it completes the
                    // edit. (Stock cli-config.yaml.example ships
                    // `reasoning_overrides: {}` uncommented — treating this
                    // as key-missing used to splice a DUPLICATE key.)
                    return .found(
                        i...i,
                        BlockIndents(key: indent, item: indent * 2),
                        blockScalar: false
                    )
                }
                break
            }
            lastBodyIdx = i
            i += 1
        }

        // The file's own indent STEP is its section body indent, so a
        // 2-space file keeps `  key:` / `    - item` (byte-identical to the
        // previous release) and a 4-space file gets `    key:` /
        // `        - item` instead of a mixed 4/6 shape.
        let step = bodyIndent ?? 2
        guard let keyIdx else {
            return .platformPresentKeyMissing(
                insertAfter: lastBodyIdx,
                rewriteHeaderAt: nil,
                indents: BlockIndents(key: step, item: step * 2)
            )
        }

        let keyIndent = leadingSpaces(lines[keyIdx])

        if keyIsBlockScalar {
            // A block scalar's value is EVERY more-indented line that follows —
            // blank lines and `#`-looking lines included, since inside a
            // literal/folded block those are text, not comments. Absorb them
            // all so the replacement takes the body along with the header.
            var last = keyIdx
            var j = keyIdx + 1
            while j < lines.count {
                let line = lines[j]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { j += 1; continue }
                if leadingSpaces(line) <= keyIndent { break }
                last = j
                j += 1
            }
            return .found(
                keyIdx...last,
                BlockIndents(key: keyIndent, item: keyIndent + step),
                blockScalar: true
            )
        }

        // Walk down the bullet rows until we leave the block (a non-bullet
        // at or above the key's indent). Block-style YAML allows bullets at
        // the same indent as their parent key, so `indent >= keyIndent` is
        // the membership test — and the FIRST bullet's indent is what we
        // re-emit at, so a file using 2- or 8-space item indents keeps it.
        var endIdx = keyIdx
        var itemIndent: Int?
        var j = keyIdx + 1
        while j < lines.count {
            let line = lines[j]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                j += 1
                continue
            }
            let indent = leadingSpaces(line)
            let isBullet = trimmed.hasPrefix("- ") || trimmed == "-"
            if isBullet && indent >= keyIndent {
                if itemIndent == nil { itemIndent = indent }
                endIdx = j
                j += 1
                continue
            }
            // Anything not a bullet at indent <= the key ends the block.
            if indent <= keyIndent { break }
            // Deeper non-bullet content (e.g. a folded scalar continuation)
            // is still part of this key's value — absorb it.
            endIdx = j
            j += 1
        }

        return .found(
            keyIdx...endIdx,
            BlockIndents(key: keyIndent, item: itemIndent ?? (keyIndent + step)),
            blockScalar: false
        )
    }

    /// Classify a trimmed line against `<key>:`.
    private enum KeyLineKind {
        /// `key:` with nothing (or only a comment) after the colon — a block
        /// header whose bullet/entry rows follow on subsequent lines.
        case blockHeader
        /// `key: <something>` — an inline value (flow dict `{…}`, flow list
        /// `[…]`, or scalar) occupying a single line.
        case inlineValue
        /// `key: |` / `key: >` (with any chomping or indentation indicator,
        /// and an optional trailing comment) — a BLOCK SCALAR header whose
        /// value is the more-indented lines that follow. Classifying this as
        /// `.inlineValue` replaced the header alone and ORPHANED the body,
        /// which PyYAML rejects with a ScannerError; `gateway/config.py`
        /// (`:775-791` @ v2026.9.7) then discards the whole config.yaml
        /// layer. The body must be replaced together WITH the header.
        case blockScalarHeader
    }

    /// Match `trimmed` against the target key, tolerating an inline flow /
    /// scalar value or a trailing comment. Returns nil when the line is not
    /// this key at all.
    private static func keyLineKind(trimmed: String, key: String) -> KeyLineKind? {
        let header = "\(key):"
        guard trimmed.hasPrefix(header) else { return nil }
        let rest = trimmed.dropFirst(header.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty || rest.hasPrefix("#") { return .blockHeader }
        if HermesYAML.blockScalarHeader(rest) != nil { return .blockScalarHeader }
        return .inlineValue
    }

    // MARK: - Inline flow mapping expansion

    private enum FlowExpansion {
        case none
        case expanded
        case refused(String)
    }

    /// Rewrite a top-level `section: {a: b, c: d}` line into an equivalent
    /// block mapping so the rest of the editor can splice into it:
    ///
    ///     slack: {reply_to_mode: first}   ->   slack:
    ///                                            reply_to_mode: first
    ///
    /// Without this, `locateBlock` reported `.platformMissing` and the write
    /// appended a SECOND top-level `slack:` — PyYAML takes the last one, so
    /// `reply_to_mode` was silently lost. Empty `{}` is left alone (handled
    /// by `rewriteFlowEmptyHeaderToBlock`). Content this parser cannot read
    /// back verbatim (nesting, an entry without a `key: value` split) is
    /// REFUSED rather than guessed at.
    private static func expandTopLevelFlowMapping(
        _ lines: inout [String],
        section: String
    ) -> FlowExpansion {
        let header = "\(section):"
        for (i, line) in lines.enumerated() {
            guard leadingSpaces(line) == 0 else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard trimmed.hasPrefix(header) else { continue }
            let rest = trimmed.dropFirst(header.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard rest.hasPrefix("{") else { continue }
            guard let close = rest.lastIndex(of: "}") else {
                return .refused(
                    "\(section): inline mapping is not closed on one line; refusing to edit "
                    + "config.yaml rather than risk clobbering it."
                )
            }
            let after = rest[rest.index(after: close)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard after.isEmpty || after.hasPrefix("#") else { continue }
            let inner = String(rest[rest.index(after: rest.startIndex)..<close])
                .trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .none }   // `{}` — the empty-section path
            guard let pairs = parseOrderedFlowPairs(inner) else {
                return .refused(
                    "\(section): inline mapping uses a shape this editor cannot rewrite "
                    + "(\(debugSnippet(inner))); refusing rather than clobbering it."
                )
            }
            var replacement = [header + (after.isEmpty ? "" : "  " + after)]
            replacement.append(contentsOf: pairs.map { "  \($0.key): \($0.value)" })
            lines.replaceSubrange(i...i, with: replacement)
            return .expanded
        }
        return .none
    }

    /// Split the body of a single-line flow mapping into ORDERED verbatim
    /// `key: value` pairs. Quote-aware so `{a: 'x, y'}` is one entry.
    /// Returns nil for anything nested or not splittable — callers refuse.
    private static func parseOrderedFlowPairs(_ inner: String) -> [(key: String, value: String)]? {
        var entries: [String] = []
        var current = ""
        var quote: Character?
        for ch in inner {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "'", "\"":
                quote = ch
                current.append(ch)
            case "{", "[", "}", "]":
                return nil          // nested flow collection — out of scope
            case ",":
                entries.append(current)
                current = ""
            default:
                current.append(ch)
            }
        }
        if quote != nil { return nil }
        entries.append(current)

        var pairs: [(key: String, value: String)] = []
        for entry in entries {
            let e = entry.trimmingCharacters(in: .whitespaces)
            if e.isEmpty { continue }
            guard let sep = flowPairSeparatorIndex(in: e) else { return nil }
            let k = String(e[e.startIndex..<sep]).trimmingCharacters(in: .whitespaces)
            let v = String(e[e.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty, !v.isEmpty else { return nil }
            pairs.append((key: k, value: v))
        }
        return pairs.isEmpty ? nil : pairs
    }

    /// First `: ` (or trailing `:`) outside quotes — the flow-mapping
    /// key/value separator. A colon with a non-space successor belongs to
    /// the key (`llama3:8b: high`), matching `HermesYAML`.
    private static func flowPairSeparatorIndex(in s: String) -> String.Index? {
        var quote: Character?
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == ":" {
                let next = s.index(after: i)
                if next == s.endIndex || s[next] == " " || s[next] == "\t" { return i }
            }
            i = s.index(after: i)
        }
        return nil
    }

    // MARK: - Splicing

    private static func replaceBlock(
        in lines: [String],
        blockRange: ClosedRange<Int>,
        key: String,
        items: [String],
        keyIndent: Int,
        itemIndent: Int,
        blockScalar: Bool
    ) -> String {
        var newLines = Array(lines.prefix(blockRange.lowerBound))
        let comments = blockScalar
            ? PreservedComments(headerComment: nil, interior: [])
            : preservedComments(in: lines, blockRange: blockRange, key: key)
        if !items.isEmpty {
            newLines.append("\(spaces(keyIndent))\(key):\(comments.headerSuffix)")
            newLines.append(contentsOf: comments.interior)
            for item in items {
                newLines.append("\(spaces(itemIndent))- \(yamlQuoteIfNeeded(item))")
            }
        } else {
            // The key is going away, but the user's standalone comments are
            // not the key — keep them where they were.
            newLines.append(contentsOf: comments.interior)
        }
        // Drop the old block but keep everything after it.
        let tailStart = blockRange.upperBound + 1
        if tailStart < lines.count {
            newLines.append(contentsOf: lines.suffix(from: tailStart))
        }
        return newLines.joined(separator: "\n")
    }

    private static func spliceNewKey(
        lines: [String],
        insertAfterLineIndex: Int,
        key: String,
        items: [String],
        keyIndent: Int,
        itemIndent: Int
    ) -> String {
        var newLines = Array(lines.prefix(insertAfterLineIndex + 1))
        newLines.append("\(spaces(keyIndent))\(key):")
        for item in items {
            newLines.append("\(spaces(itemIndent))- \(yamlQuoteIfNeeded(item))")
        }
        if insertAfterLineIndex + 1 < lines.count {
            newLines.append(contentsOf: lines.suffix(from: insertAfterLineIndex + 1))
        }
        return newLines.joined(separator: "\n")
    }

    private static func appendScaffold(
        yaml: String,
        platform: String,
        key: String,
        items: [String]
    ) -> String {
        var trimmed = yaml
        // Ensure exactly one trailing newline before the appended block,
        // so the scaffold sits on its own line cleanly.
        while trimmed.hasSuffix("\n\n") {
            trimmed.removeLast()
        }
        if !trimmed.isEmpty && !trimmed.hasSuffix("\n") {
            trimmed.append("\n")
        }
        var lines: [String] = []
        if !trimmed.isEmpty {
            lines.append("")  // blank separator
        }
        lines.append("\(platform):")
        lines.append("  \(key):")
        for item in items {
            lines.append("    - \(yamlQuoteIfNeeded(item))")
        }
        lines.append("")  // trailing newline so subsequent edits append cleanly
        return trimmed + lines.joined(separator: "\n")
    }

    // MARK: - YAML scanning helpers

    private static func leadingSpaces(_ line: String) -> Int {
        var n = 0
        for c in line {
            if c == " " { n += 1 } else { break }
        }
        return n
    }

    /// Find the first line whose trimmed content equals `header` (or is
    /// `header` followed only by a `# comment`) AND whose leading-space
    /// count equals `indent`. Comment-only and blank lines are skipped;
    /// stray `\r` (CRLF remnants) is stripped before matching so a section
    /// header is never mistaken for missing — a miss here appends a second
    /// top-level section, which PyYAML resolves last-wins (data loss).
    /// Returns the line's index or `nil`.
    private static func firstIndex(
        of lines: [String],
        headerLineEqualTo header: String,
        indent: Int
    ) -> Int? {
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard leadingSpaces(line) == indent else { continue }
            if trimmed == header { return i }
            if trimmed.hasPrefix(header) {
                let rest = trimmed.dropFirst(header.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.isEmpty || rest.hasPrefix("#") { return i }
            }
        }
        return nil
    }

    /// Find the first top-level line of the form `<platform>: {}` (an empty
    /// flow mapping, optionally followed only by a `# comment`). Hermes
    /// emits this shape for a preserved-but-empty section; it is the section
    /// header + an empty body in one line.
    private static func firstIndex(
        of lines: [String],
        flowEmptyHeaderFor platform: String
    ) -> Int? {
        let header = "\(platform):"
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard leadingSpaces(line) == 0, trimmed.hasPrefix(header) else { continue }
            let rest = trimmed.dropFirst(header.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard rest.hasPrefix("{}") else { continue }
            let after = rest.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            if after.isEmpty || after.hasPrefix("#") { return i }
        }
        return nil
    }

    /// Turn `platform: {}` (possibly with a trailing comment) into a bare
    /// `platform:` block header so child rows can be spliced beneath it.
    /// The comment, if any, is preserved.
    private static func rewriteFlowEmptyHeaderToBlock(_ line: String) -> String {
        guard let range = line.range(of: "{}") else { return line }
        var rewritten = line
        rewritten.removeSubrange(range)
        while rewritten.hasSuffix(" ") { rewritten.removeLast() }
        return rewritten
    }

    private static func spaces(_ n: Int) -> String {
        String(repeating: " ", count: n)
    }

    // MARK: - Comment preservation

    /// The user's comments that live INSIDE the block we are about to
    /// replace: the trailing `# …` on the key's own line, and every
    /// comment-only row between the key and its last item.
    ///
    /// Without this, `replaceBlock` / `setMapLF` replaced the whole block
    /// range with freshly generated rows and the comments went with it —
    /// `allowed_channels: []  # none yet` lost its note, and a `# internal
    /// only` sitting between two bullets was deleted on save. Comments are
    /// the one thing in a config a tool has no business throwing away.
    ///
    /// Interior comments are re-emitted directly under the key rather than
    /// back between the bullets they sat between — a bullet's identity is
    /// its VALUE, and the values are exactly what this edit replaces, so
    /// there is no honest "where it was" to restore to. The first save of a
    /// config with interleaved comments therefore reflows the block once and
    /// is stable from then on (the idempotence assertion in
    /// `HermesP19YAMLHardeningTests` pins that).
    private struct PreservedComments {
        /// Trailing comment from the key's own line, `#` included.
        let headerComment: String?
        /// Comment-only lines from inside the block, verbatim and in order.
        let interior: [String]

        var headerSuffix: String { headerComment.map { "  " + $0 } ?? "" }
    }

    private static func preservedComments(
        in lines: [String],
        blockRange: ClosedRange<Int>,
        key: String
    ) -> PreservedComments {
        let headerLine = lines[blockRange.lowerBound]
        var header: String?
        if let keyColon = headerLine.range(of: "\(key):") {
            header = trailingComment(in: String(headerLine[keyColon.upperBound...]))
        }
        var interior: [String] = []
        if blockRange.lowerBound < blockRange.upperBound {
            for line in lines[(blockRange.lowerBound + 1)...blockRange.upperBound]
            where line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") {
                interior.append(line)
            }
        }
        return PreservedComments(headerComment: header, interior: interior)
    }

    /// The `# …` comment in `fragment`, or nil. A `#` only opens a comment
    /// when preceded by whitespace (or the fragment's start) and not inside
    /// a quoted scalar — `a#b` is the value `a#b`, per YAML.
    private static func trailingComment(in fragment: String) -> String? {
        var quote: Character?
        var afterSpace = true
        var i = fragment.startIndex
        while i < fragment.endIndex {
            let ch = fragment[i]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == "#", afterSpace {
                let comment = String(fragment[i...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return comment.isEmpty ? nil : comment
            }
            afterSpace = ch == " " || ch == "\t"
            i = fragment.index(after: i)
        }
        return nil
    }

    /// Quote a YAML scalar if emitting it bare would change what PyYAML
    /// loads. One implementation, shared with the MCP-entry map writers —
    /// see ``YAMLScalar/quoteIfNeeded(_:)``. P10 had two quoting routines
    /// in two files; this one quoted map keys and the other did not, which
    /// is the HIGH P19 fixed.
    static func yamlQuoteIfNeeded(_ raw: String) -> String {
        YAMLScalar.quoteIfNeeded(raw)
    }

}

extension GatewayConfigWriter.WriteOutcome {
    /// The text to write when the edit applied, `unchanged` (the caller's
    /// own input) when there was nothing to do, and `nil` ONLY when the
    /// editor refused — so a refusal can never be mistaken for a no-op.
    public func appliedText(orUnchanged unchanged: String) -> String? {
        switch self {
        case .updated(let text): return text
        case .unchanged: return unchanged
        case .refused: return nil
        }
    }
}
