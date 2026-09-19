import Foundation

/// One transcript fragment from the voice layer (a
/// `session.input_transcript.delta` / `session.output_transcript.delta`).
public struct VoiceTranscriptFragment: Sendable, Equatable {
    public enum Speaker: String, Sendable { case user, assistant }
    public let speaker: Speaker
    public let text: String
    public let startMs: Int
    public let endMs: Int

    public init(speaker: Speaker, text: String, startMs: Int, endMs: Int) {
        self.speaker = speaker
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// One seed message for a new GPT-Live session — the vendor's
/// `{type:"message", role, content:[{type, text}]}` item, built by
/// ``VoiceLiveText/liveHistory(from:maxMessages:maxChars:)``.
public struct VoiceLiveHistoryMessage: Sendable, Equatable, Encodable {
    public enum Role: String, Sendable, Encodable { case user, assistant }
    public struct Content: Sendable, Equatable, Encodable {
        public let type: String   // "input_text" | "output_text"
        public let text: String
    }

    public let type = "message"
    public let role: Role
    public let content: [Content]

    public init(role: Role, text: String) {
        self.role = role
        self.content = [Content(type: role == .assistant ? "output_text" : "input_text", text: text)]
    }

    private enum CodingKeys: String, CodingKey { case type, role, content }
}

/// Pure text helpers for Live Voice, each a port of the Hermes desktop app's
/// implementation at tag v2026.9.14 so Scarf's voice behaves like Hermes's
/// own client. Keep them line-faithful; refresh them in each Hermes release
/// audit.
public enum VoiceLiveText {

    // MARK: - Delegation prompt

    /// `delegationPrompt` — `apps/desktop/src/app/chat/composer/hooks/
    /// use-voice-live-conversation.ts:46-68`. The delegation event carries no
    /// text: `prompt` is the user's last merged utterance (the persisted user
    /// row), `context` the `User:` / `Voice assistant:` exchange that rides
    /// the model input only.
    public static func delegationPrompt(_ fragments: [VoiceTranscriptFragment]) -> (prompt: String, context: String) {
        var turns: [(speaker: VoiceTranscriptFragment.Speaker, text: String)] = []
        for fragment in fragments {
            if let last = turns.last, last.speaker == fragment.speaker {
                turns[turns.count - 1].text += fragment.text
            } else {
                turns.append((fragment.speaker, fragment.text))
            }
        }
        let lastUser = turns.last(where: { $0.speaker == .user })
        let prompt = collapseWhitespace(lastUser?.text ?? "")
        let transcript = turns
            .map { "\($0.speaker == .user ? "User" : "Voice assistant"): \(collapseWhitespace($0.text))" }
            .filter { !$0.hasSuffix(": ") }
            .joined(separator: "\n")
        return (prompt.isEmpty ? String(transcript.suffix(400)) : prompt, transcript)
    }

    /// `contextWindow` — `apps/desktop/src/lib/voice-live.ts:259-269`: the
    /// last 5 minutes (by the newest fragment's end), at most 80 fragments.
    public static func contextWindow(
        _ transcript: [VoiceTranscriptFragment],
        windowMs: Int = 5 * 60_000,
        maxFragments: Int = 80
    ) -> [VoiceTranscriptFragment] {
        guard let last = transcript.last else { return [] }
        let floor = last.endMs - windowMs
        return Array(transcript.filter { $0.endMs >= floor }.suffix(maxFragments))
    }

    // MARK: - Commentary chunking

    /// Vendor cap: 500 tokens per append (`voice-live.ts:75-76`).
    public static let appendCharLimit = 1_400

    /// `chunkForCommentary` — `voice-live.ts:106-149`: split a reply into
    /// append-sized chunks on sentence boundaries.
    public static func chunkForCommentary(_ text: String, limit: Int = appendCharLimit) -> [String] {
        let clean = collapseWhitespace(text)
        guard !clean.isEmpty else { return [] }
        if clean.count <= limit { return [clean] }
        var chunks: [String] = []
        var current = ""
        for sentence in splitSentences(clean) {
            if sentence.count > limit {
                if !current.isEmpty { chunks.append(current); current = "" }
                var rest = Substring(sentence)
                while !rest.isEmpty {
                    chunks.append(String(rest.prefix(limit)))
                    rest = rest.dropFirst(limit)
                }
                continue
            }
            let candidate = current.isEmpty ? sentence : "\(current) \(sentence)"
            if candidate.count > limit {
                chunks.append(current)
                current = sentence
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// JS `text.split(/(?<=[.!?])\s+/)` on already-collapsed text (single
    /// spaces only).
    private static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character == " ", let p = previous, ".!?".contains(p) {
                out.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        out.append(current)
        return out
    }

    // MARK: - Seed history

    /// A text turn from the chat transcript, for seeding a new session.
    public struct SeedTurn: Sendable, Equatable {
        public let role: VoiceLiveHistoryMessage.Role
        public let text: String
        public init(role: VoiceLiveHistoryMessage.Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// `toLiveHistory` — `voice-live.ts:152-180`: the most recent text turns,
    /// newest kept, each trimmed to 1,200 characters, within 24 messages and
    /// 6,000 characters.
    public static func liveHistory(
        from turns: [SeedTurn],
        maxMessages: Int = 24,
        maxChars: Int = 6_000
    ) -> [VoiceLiveHistoryMessage] {
        var out: [VoiceLiveHistoryMessage] = []
        var budget = maxChars
        for turn in turns.reversed() {
            let text = String(collapseWhitespace(turn.text).prefix(1_200))
            if text.isEmpty { continue }
            if out.count >= maxMessages || budget - text.count < 0 { break }
            budget -= text.count
            out.insert(VoiceLiveHistoryMessage(role: turn.role, text: text), at: 0)
        }
        return out
    }

    // MARK: - Stop phrases

    /// `STOP_PHRASES` — `apps/desktop/src/lib/voice-stop-word.ts:17-34`.
    static let stopPhrases: Set<String> = [
        "stop", "stop listening", "stop it", "stop please", "please stop", "stop stop",
        "that is all", "that's all", "never mind", "nevermind", "end conversation",
        "end the conversation", "goodbye", "good bye", "bye", "cancel",
    ]

    /// `ADDRESS_PREFIXES` — `voice-stop-word.ts:38`, in order.
    static let addressPrefixes = ["hey hermes", "hey hermes,", "hermes", "hermes,", "ok", "okay", "hey"]

    /// `isVoiceStopCommand` — `voice-stop-word.ts:43-94`: true only when the
    /// WHOLE utterance is a stop phrase (optionally addressed to Hermes), so
    /// "stop the docker container" is never swallowed.
    public static func isStopCommand(_ transcript: String) -> Bool {
        let normalized = normalizeForStop(transcript)
        guard !normalized.isEmpty else { return false }
        return stopPhrases.contains(normalized) || stopPhrases.contains(stripAddress(normalized))
    }

    private static func normalizeForStop(_ text: String) -> String {
        let punctuation = Set(".,!?;:…")
        let spaced = String(text.lowercased().map { punctuation.contains($0) ? " " : $0 })
        return collapseWhitespace(spaced)
    }

    private static func stripAddress(_ text: String) -> String {
        for prefix in addressPrefixes where text != prefix {
            if text.hasPrefix(prefix + " ") {
                return String(text.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }

    // MARK: - Speech sanitizing

    /// `sanitizeTextForSpeech` — `apps/desktop/src/lib/speech-text.ts:154-167`
    /// (with `stripMarkdownTables`, `:102-143`): code blocks become " code
    /// block omitted ", links keep their label, URLs become " link ", emoji,
    /// headings, emphasis markers and bullets go, tables are skipped, and
    /// whitespace collapses. The live voice paraphrases what it is given, so
    /// markdown must not reach it.
    public static func sanitizeForSpeech(_ text: String) -> String {
        var s = normalizeLineBreaks(stripMarkdownTables(text))
        s = replace(s, #"```[\s\S]*?(?:```|$)"#, " code block omitted ")
        s = replace(s, #"^\s*(?:\([^)\n]{1,48}\)\s*)?(?:processing|thinking|reasoning|analyzing|pondering|contemplating|musing|cogitating|ruminating|deliberating|mulling|reflecting|computing|synthesizing|formulating|brainstorming)\.\.\.\s*"#, " ", options: [.caseInsensitive])
        s = replace(s, #"\[([^\]]+)\]\(([^)]+)\)"#, "$1")
        s = replace(s, #"`([^`]+)`"#, "$1")
        s = replace(s, #"\bhttps?://\S+"#, " link ", options: [.caseInsensitive])
        s = replace(s, #"(?:[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}]|[\x{FE0F}\x{200D}]|[\x{E0020}-\x{E007F}])+"#, " ")
        s = replace(s, #"^#{1,6}\s+"#, "", options: [.anchorsMatchLines])
        s = replace(s, #"[*_~>#]"#, "")
        s = replace(s, #"^\s*[-+*]\s+"#, "", options: [.anchorsMatchLines])
        return collapseWhitespace(s)
    }

    /// Streaming speech: the end (exclusive, in `Character`s) of the longest
    /// prefix of a still-streaming `raw` reply that is safe to sanitize and
    /// speak on its own, or `0`. The prefix ends just after a sentence end
    /// (`.`, `!` or `?` followed by whitespace) that is outside a code fence,
    /// inline code and an unclosed link label, on a line with no `|` (a
    /// possible table row, which ``sanitizeForSpeech(_:)`` drops only once
    /// its delimiter row arrives). Sanitizing such prefixes piecewise gives
    /// the same words as sanitizing the whole reply, so a stable raw offset
    /// can track what has been spoken. One linear scan; no regex.
    public static func speakableBoundary(in raw: [Character]) -> Int {
        var inFence = false
        var inCode = false
        var inLinkLabel = false
        var best = 0                 // from completed lines
        var lineCandidate: Int?      // on the current line, void if it has a pipe
        var linePipe = false
        var index = 0
        while index < raw.count {
            let character = raw[index]
            if character == "`" {
                if index + 2 < raw.count, raw[index + 1] == "`", raw[index + 2] == "`" {
                    inFence.toggle()
                    inCode = false
                    index += 3
                    continue
                }
                if !inFence { inCode.toggle() }
            } else if character == "\n" {
                if let lineCandidate { best = lineCandidate }
                lineCandidate = nil
                linePipe = false
            } else if !inFence {
                switch character {
                case "|":
                    linePipe = true
                    lineCandidate = nil
                case "[":
                    inLinkLabel = true
                case "]":
                    inLinkLabel = false
                case ".", "!", "?":
                    if !inCode, !inLinkLabel, !linePipe, index + 1 < raw.count, raw[index + 1].isWhitespace {
                        lineCandidate = index + 1
                    }
                default:
                    break
                }
            }
            index += 1
        }
        return lineCandidate ?? best
    }

    /// The speech for `raw[range]`, one piece of a reply cut at
    /// ``speakableBoundary(in:)``. Leading whitespace is dropped first: a
    /// piece that starts with a paragraph break would otherwise sanitize to
    /// a stray ". " (the break before it already ended a sentence).
    public static func speechSegment(_ raw: [Character], _ range: Range<Int>) -> String {
        sanitizeForSpeech(String(raw[range].drop(while: \.isWhitespace)))
    }

    /// `normalizeLineBreaks` — `speech-text.ts:145-152`.
    private static func normalizeLineBreaks(_ text: String) -> String {
        var s = replace(text, #"\r\n?"#, "\n")
        s = replace(s, #"(\p{L})-\n(\p{L})"#, "$1$2")
        s = replace(s, #"([.!?])([*_~`>"'’”)}\]]*)[ \t]*\n{2,}[ \t]*"#, "$1$2 ")
        s = replace(s, #"[ \t]*\n{2,}[ \t]*"#, ". ")
        s = replace(s, #"[ \t]*\n[ \t]*"#, " ")
        return s
    }

    private struct TableRow {
        let blockquoteDepth: Int
        let cells: [String]
    }

    /// `stripMarkdownTables` — `speech-text.ts:102-143`.
    private static func stripMarkdownTables(_ text: String) -> String {
        let lines = replace(text, #"\r\n?"#, "\n").components(separatedBy: "\n")
        var tableLines = Set<Int>()
        var index = 1
        while index < lines.count {
            guard let delimiter = parseTableRow(lines[index]),
                  let header = parseTableRow(lines[index - 1]),
                  delimiter.cells.allSatisfy(isDelimiterCell),
                  header.cells.count == delimiter.cells.count,
                  header.blockquoteDepth == delimiter.blockquoteDepth else {
                index += 1
                continue
            }
            tableLines.insert(index - 1)
            tableLines.insert(index)
            var row = index + 1
            while row < lines.count {
                guard let body = parseTableRow(lines[row]), body.blockquoteDepth == delimiter.blockquoteDepth else { break }
                tableLines.insert(row)
                row += 1
            }
            index = row
        }
        return lines.enumerated().filter { !tableLines.contains($0.offset) }.map(\.element).joined(separator: "\n")
    }

    /// `MARKDOWN_TABLE_DELIMITER_CELL_RE` — `/^:?-{3,}:?$/`.
    private static func isDelimiterCell(_ cell: String) -> Bool {
        var body = Substring(cell)
        if body.hasPrefix(":") { body = body.dropFirst() }
        if body.hasSuffix(":") { body = body.dropLast() }
        return body.count >= 3 && body.allSatisfy { $0 == "-" }
    }

    /// `parseMarkdownTableRow` — `speech-text.ts:49-100`.
    private static func parseTableRow(_ line: String) -> TableRow? {
        var row = Array(line)
        var depth = 0
        while true {
            let indentation = row.prefix { $0 == " " || $0 == "\t" }
            if indentation.contains("\t") || indentation.count > 3 { return nil }
            row.removeFirst(indentation.count)
            guard row.first == ">" else { break }
            depth += 1
            row.removeFirst()
            if row.first == " " { row.removeFirst() }
        }
        while let last = row.last, last.isWhitespace { row.removeLast() }
        let pipes = row.indices.filter { row[$0] == "|" && isUnescapedPipe(row, $0) }
        guard let firstPipe = pipes.first, let lastPipe = pipes.last else { return nil }
        let leading = firstPipe == 0
        let trailing = lastPipe == row.count - 1
        if leading { row.removeFirst() }
        if trailing, !row.isEmpty { row.removeLast() }
        let cells = splitTableCells(row)
        if cells.count < 2 && !(leading && trailing && cells.count == 1) { return nil }
        return TableRow(blockquoteDepth: depth, cells: cells)
    }

    private static func isUnescapedPipe(_ row: [Character], _ index: Int) -> Bool {
        var backslashes = 0
        var cursor = index - 1
        while cursor >= 0 && row[cursor] == "\\" {
            backslashes += 1
            cursor -= 1
        }
        return backslashes % 2 == 0
    }

    private static func splitTableCells(_ row: [Character]) -> [String] {
        var cells: [String] = []
        var start = 0
        for index in row.indices where row[index] == "|" && isUnescapedPipe(row, index) {
            cells.append(String(row[start..<index]).trimmingCharacters(in: .whitespaces))
            start = index + 1
        }
        cells.append(String(row[start...]).trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: - Helpers

    /// JS `.replace(/\s+/g, ' ').trim()`.
    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func replace(
        _ text: String,
        _ pattern: String,
        _ template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
