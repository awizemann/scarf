import Testing
import Foundation
@testable import ScarfCore

/// M7 — a live CLI pane reads bytes, not characters. `availableData` can end
/// mid-codepoint, and `String(data:encoding:.utf8) ?? ""` drops the whole
/// chunk when it does. For `hermes mcp login --flow device` that can be the
/// line carrying the user code, which exists nowhere else.
@Suite("Incremental UTF-8 decoding")
struct IncrementalUTF8DecoderTests {

    /// The prompt Hermes prints, with a multi-byte glyph in it.
    static let prompt = "→ Visit https://example.com/device and enter code WDJB-MJHT\n"

    @Test func splittingEveryByteBoundaryStillYieldsTheWholeText() {
        let bytes = Array(Self.prompt.utf8)
        for split in 1..<bytes.count {
            let decoder = IncrementalUTF8Decoder()
            var out = decoder.decode(Data(bytes[..<split]))
            out += decoder.decode(Data(bytes[split...]))
            out += decoder.flush()
            #expect(out == Self.prompt, "split at \(split)")
            // The naive decode is what this replaces: prove the split is
            // real for at least the boundaries inside the arrow.
            if split == 1 || split == 2 {
                #expect(String(data: Data(bytes[..<split]), encoding: .utf8) == nil)
            }
        }
    }

    @Test func aByteAtATimeReassemblesEveryCodepoint() {
        let decoder = IncrementalUTF8Decoder()
        var out = ""
        for byte in Array("café ☕️ 🎉".utf8) { out += decoder.decode(Data([byte])) }
        out += decoder.flush()
        #expect(out == "café ☕️ 🎉")
    }

    @Test func invalidBytesDoNotStallTheStream() {
        let decoder = IncrementalUTF8Decoder()
        // A lone continuation byte is not the start of anything.
        let out = decoder.decode(Data([0x41, 0xFF, 0x42]))
        #expect(out.contains("A") && out.contains("B"))
        // Nothing is held back, so the next line arrives intact rather than
        // glued to a byte that will never complete.
        #expect(decoder.decode(Data("ok\n".utf8)) == "ok\n")
    }

    @Test func anIncompleteTailIsHeldNotEmitted() {
        let decoder = IncrementalUTF8Decoder()
        let arrow = Array("→".utf8)
        #expect(decoder.decode(Data(arrow[0..<2])) == "")
        #expect(decoder.decode(Data(arrow[2...])) == "→")
    }
}
