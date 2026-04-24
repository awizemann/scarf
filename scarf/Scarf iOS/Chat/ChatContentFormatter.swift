import Foundation

/// Splits a chat message body into alternating text + fenced-code
/// segments so ChatView can render each part appropriately. Text
/// gets the existing AttributedString(markdown:) path; code gets a
/// horizontally-scrollable monospaced block (pass-1 UX: long lines
/// wrapped onto 4–5 visual rows each, which ate vertical space and
/// made code unreadable on an iPhone).
///
/// Keeps the parser deliberately simple: we recognise the common
/// fenced form (```\n...\n``` and ```lang\n...\n```) and leave
/// everything else in the .text bucket. Inline `backticks` stay in
/// the text segment — AttributedString handles those fine.
enum ChatContentFormatter {

    enum Segment: Equatable {
        case text(String)
        case code(language: String?, body: String)
    }

    /// Split the given message body into an ordered list of segments.
    /// A body with no fenced code yields a single `.text` segment.
    static func segments(for body: String) -> [Segment] {
        // Fast path: no fences at all.
        guard body.contains("```") else { return [.text(body)] }

        var result: [Segment] = []
        var pending = ""
        var i = body.startIndex

        while i < body.endIndex {
            // Try to match a fence opening at this position.
            if body[i...].hasPrefix("```") {
                // Flush the accumulated text.
                if !pending.isEmpty {
                    result.append(.text(pending))
                    pending = ""
                }

                // Parse the optional language token up to the first newline.
                let afterFence = body.index(i, offsetBy: 3)
                var j = afterFence
                while j < body.endIndex, body[j] != "\n" {
                    j = body.index(after: j)
                }
                let lang = String(body[afterFence..<j]).trimmingCharacters(in: .whitespaces)

                // Skip the newline after the language line, if any.
                let bodyStart = (j < body.endIndex) ? body.index(after: j) : j

                // Scan for the closing fence.
                var k = bodyStart
                while k < body.endIndex {
                    if body[k...].hasPrefix("```") {
                        break
                    }
                    k = body.index(after: k)
                }
                let codeBody = String(body[bodyStart..<k])
                result.append(.code(
                    language: lang.isEmpty ? nil : lang,
                    body: codeBody.hasSuffix("\n") ? String(codeBody.dropLast()) : codeBody
                ))

                if k < body.endIndex {
                    // Skip the closing ```.
                    i = body.index(k, offsetBy: 3)
                    // Skip a single trailing newline if present so
                    // the next text segment doesn't start with a
                    // cosmetic blank line.
                    if i < body.endIndex, body[i] == "\n" {
                        i = body.index(after: i)
                    }
                } else {
                    // Unterminated fence — keep everything we saw
                    // as text instead, preserving user input rather
                    // than silently swallowing it.
                    pending = String(body[i..<body.endIndex])
                    i = body.endIndex
                }
            } else {
                pending.append(body[i])
                i = body.index(after: i)
            }
        }

        if !pending.isEmpty {
            result.append(.text(pending))
        }
        return result
    }
}
