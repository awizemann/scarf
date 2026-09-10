import Foundation

/// Per-line terminator preservation for the surgical YAML writers.
///
/// Every writer in Scarf promises the same thing: the bytes OUTSIDE the key
/// it was asked to edit do not move. Flipping the whole file to CRLF because
/// one `\r\n` appeared somewhere breaks that promise on a mixed-ending file —
/// every untouched line is rewritten, and anything watching the file sees a
/// whole-file diff. `HermesBotProfileYAML` solved this first; `YAMLLineEndings`
/// is that solution lifted out so `GatewayConfigWriter` stops having its own
/// (wholesale) answer to the same question.
public enum YAMLLineEndings {

    /// LF-only copy, for the line-array editors to work on.
    public static func normalized(_ yaml: String) -> String {
        yaml.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Re-attach the source file's per-line terminators to the rewritten
    /// text.
    ///
    /// Lines that survive the edit keep the ending they had; lines the writer
    /// actually produced get the file's dominant ending. A pure-LF file — the
    /// overwhelmingly common case — takes the fast path and comes back
    /// byte-identical.
    public static func restore(_ result: String, matching original: String) -> String {
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
            // Greedy re-sync: these writers only ever replace contiguous
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
}
