import Foundation

/// Decodes a byte stream that arrives in arbitrary chunks into text, without
/// losing a character that straddles two reads.
///
/// `FileHandle.availableData` returns however many bytes are ready, which is
/// a byte count and not a character boundary. `String(data:encoding:.utf8)`
/// is all-or-nothing: one truncated multi-byte sequence at the end makes it
/// return nil, and the usual `?? ""` throws the ENTIRE chunk away. On a live
/// CLI pane that means an arbitrary line can simply never appear — for the
/// MCP device flow, potentially the line carrying the user code.
///
/// This keeps the undecodable tail (at most three bytes — the longest
/// incomplete UTF-8 sequence) and prepends it to the next chunk. Genuinely
/// invalid bytes are not held forever: once a chunk cannot be salvaged by
/// trimming a short tail, it is decoded lossily so the stream keeps moving.
///
/// Not thread-safe by itself — give each stream its own decoder and call it
/// from that stream's serial queue (a `readabilityHandler`'s calls are
/// serialised for one handle).
public final class IncrementalUTF8Decoder: @unchecked Sendable {
    /// Bytes of an incomplete sequence carried over from the previous chunk.
    private var pending = Data()

    public init() {}

    /// Decode `chunk` together with any carried-over tail. Returns the text
    /// decoded so far; an empty string means everything in hand is still an
    /// incomplete sequence.
    public func decode(_ chunk: Data) -> String {
        var data = pending
        data.append(chunk)
        pending = Data()
        if let text = String(data: data, encoding: .utf8) { return text }
        // Not decodable as-is. Walk back at most three bytes to the last
        // lead byte: if the sequence it starts is INCOMPLETE, that tail is a
        // boundary split — hold it for the next read. Anything else is
        // genuinely bad input, decoded lossily so the pane keeps moving.
        let bytes = [UInt8](data)
        var i = bytes.count - 1
        let lowest = max(0, bytes.count - 3)
        while i >= lowest {
            let byte = bytes[i]
            if byte & 0xC0 != 0x80 {  // ASCII or a lead byte
                let expected: Int
                switch byte {
                case 0x00...0x7F: expected = 1
                case 0xC0...0xDF: expected = 2
                case 0xE0...0xEF: expected = 3
                case 0xF0...0xF7: expected = 4
                default: expected = 0  // invalid lead
                }
                if expected > bytes.count - i {
                    pending = Data(bytes[i...])
                    return String(decoding: bytes[..<i], as: UTF8.self)
                }
                break
            }
            i -= 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Anything still held back, decoded lossily. Call at end of stream so a
    /// truncated final sequence is shown rather than silently dropped.
    public func flush() -> String {
        defer { pending = Data() }
        guard !pending.isEmpty else { return "" }
        return String(decoding: pending, as: UTF8.self)
    }
}
