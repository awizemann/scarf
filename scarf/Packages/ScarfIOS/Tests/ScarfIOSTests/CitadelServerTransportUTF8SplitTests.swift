import Testing
import Foundation
import Citadel
import NIOCore
@testable import ScarfIOS

/// F5 (old bug, found in the final audit) — `CitadelServerTransport`'s exec
/// drain decoded UTF-8 ONE `ExecCommandOutput` CHUNK AT A TIME
/// (`buf.readString(length:)` per `.stdout`/`.stderr` case in `absorb`).
/// Citadel hands back one chunk per SSH data packet, and a multi-byte
/// character routinely lands split across two of them — CJK text, emoji,
/// anything outside ASCII in a chat message over ~32 KB. `readString` never
/// throws on invalid UTF-8; it silently substitutes U+FFFD, so the split
/// character became TWO replacement characters instead of one real one, with
/// no error anywhere in the call chain.
///
/// `absorb` is the one drain every exec/streamScript path shares
/// (`runExec` → `drain` → `absorb`), so the fix lives there: read RAW bytes
/// per chunk and accumulate them as `Data` — `ProcessResult.stdout`/`stderr`
/// are `Data` already, so there is no reason to round-trip through `String`
/// before the caller gets a chance to decode the whole thing at once.
///
/// These tests drive `CitadelServerTransport.absorb` directly with a fake
/// `AsyncSequence<ExecCommandOutput>` that splits a real multi-byte
/// character across chunk boundaries — no live SSH host required, same
/// technique `CitadelTransportP53Tests` uses to stage the timeout race.
@Suite("The iOS exec drain reassembles UTF-8 split across packets (F5)")
struct CitadelServerTransportUTF8SplitTests {

    /// Replays a fixed list of raw byte chunks as `.stdout` `ExecCommandOutput`
    /// values, then ends the sequence — the shape of a command that printed
    /// its output across several SSH data packets and then exited cleanly.
    private struct SplitStdoutChunks: AsyncSequence, Sendable {
        typealias Element = ExecCommandOutput
        let chunks: [[UInt8]]
        struct Iterator: AsyncIteratorProtocol {
            var remaining: [[UInt8]]
            mutating func next() async throws -> ExecCommandOutput? {
                guard !remaining.isEmpty else { return nil }
                let bytes = remaining.removeFirst()
                return .stdout(ByteBuffer(bytes: bytes))
            }
        }
        func makeAsyncIterator() -> Iterator { Iterator(remaining: chunks) }
    }

    @Test("a CJK character split across two packets reassembles, not as replacement characters")
    func splitCJKCharacterReassembles() async throws {
        // "before日after" — 日 (U+65E5) is E6 97 A5 in UTF-8. Split right
        // after its leading byte, so NEITHER chunk holds a complete
        // character: chunk 1 ends mid-sequence, chunk 2 starts mid-sequence.
        let whole = "before日after"
        let allBytes = Array(whole.utf8)
        let splitPoint = "before".utf8.count + 1  // "before" + 日's leading byte
        let chunk1 = Array(allBytes[..<splitPoint])
        let chunk2 = Array(allBytes[splitPoint...])
        let partial = PartialStdout()

        let result = try await CitadelServerTransport.absorb(
            SplitStdoutChunks(chunks: [chunk1, chunk2]),
            timeout: 5,
            midStream: .exitMinusOne,
            partial: partial)

        #expect(result.stdout == Data(allBytes), """
            The reassembled bytes don't match what was sent — the split \
            character was corrupted instead of carried through raw.
            """)
        #expect(String(data: result.stdout, encoding: .utf8) == whole, """
            Decoding the accumulated stdout produced something other than \
            "\(whole)". A multi-byte character split across two exec \
            packets was decoded PER PACKET instead of once over the fully \
            reassembled bytes.
            """)
        let decoded = String(data: result.stdout, encoding: .utf8) ?? ""
        #expect(!decoded.contains("\u{FFFD}"), """
            The decoded stdout contains a U+FFFD replacement character — \
            exactly the split-packet UTF-8 corruption this test exists to \
            catch (it fails against the old per-chunk `readString` decode).
            """)
        // `partial` (the timeout arm's mirror) must carry the same
        // byte-for-byte reassembly, not a re-decoded copy.
        #expect(partial.bytes() == Data(allBytes))
    }

    @Test("a 4-byte emoji split across four single-byte packets reassembles")
    func splitEmojiAcrossManySinglyByteFragmentedPackets() async throws {
        // 🎉 (U+1F389) is F0 9F 8E 89 in UTF-8 — split into four
        // single-byte packets, the most fragmented case Citadel could hand
        // back and the one an all-or-nothing per-chunk decode fails hardest
        // on (every single chunk is an incomplete sequence).
        let whole = "🎉"
        let allBytes = Array(whole.utf8)
        #expect(allBytes.count == 4)
        let chunks = allBytes.map { [$0] }
        let partial = PartialStdout()

        let result = try await CitadelServerTransport.absorb(
            SplitStdoutChunks(chunks: chunks),
            timeout: 5,
            midStream: .exitMinusOne,
            partial: partial)

        #expect(result.stdout == Data(allBytes))
        #expect(String(data: result.stdout, encoding: .utf8) == whole)
    }

    @Test("stderr is reassembled the same way as stdout")
    func splitStderrReassembles() async throws {
        struct SplitStderrChunks: AsyncSequence, Sendable {
            typealias Element = ExecCommandOutput
            let chunks: [[UInt8]]
            struct Iterator: AsyncIteratorProtocol {
                var remaining: [[UInt8]]
                mutating func next() async throws -> ExecCommandOutput? {
                    guard !remaining.isEmpty else { return nil }
                    return .stderr(ByteBuffer(bytes: remaining.removeFirst()))
                }
            }
            func makeAsyncIterator() -> Iterator { Iterator(remaining: chunks) }
        }
        let whole = "erro日r"
        let allBytes = Array(whole.utf8)
        let splitPoint = "erro".utf8.count + 1
        let chunk1 = Array(allBytes[..<splitPoint])
        let chunk2 = Array(allBytes[splitPoint...])

        let result = try await CitadelServerTransport.absorb(
            SplitStderrChunks(chunks: [chunk1, chunk2]),
            timeout: 5,
            midStream: .exitMinusOne,
            partial: PartialStdout())

        #expect(result.stderr == Data(allBytes))
        #expect(String(data: result.stderr, encoding: .utf8) == whole)
    }
}
