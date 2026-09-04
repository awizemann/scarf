import Foundation
import ScarfCore

/// The MCP stdio transport: newline-delimited JSON on stdin, one response
/// line per request on stdout, diagnostics on stderr (stdout carries the
/// protocol and nothing else — a stray `print` corrupts the stream).
public enum ProjectMCPStdioLoop {

    /// A single frame's ceiling. A `tools/call` carrying a whole dashboard
    /// is tens of KB; a line past this is a runaway or hostile writer, and
    /// buffering it unbounded is how a stdio server dies of memory rather
    /// than of an error message.
    static let maxLineBytes = 8 * 1024 * 1024

    /// CR, space and tab around a frame are framing noise, not content.
    private static func isFramingWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x0D || byte == 0x20 || byte == 0x09
    }

    /// Read until stdin closes. Returns when the client hangs up, which is
    /// the normal way an MCP stdio server ends.
    public static func run(
        server: ProjectMCPServer,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        // A client that hangs up mid-response would otherwise kill this
        // process with SIGPIPE before the write call can report EPIPE.
        signal(SIGPIPE, SIG_IGN)

        var buffer = Data()
        // Set while the TAIL of an over-long frame is still arriving.
        // Without it, the bytes after the dropped prefix get parsed as a
        // fresh request and the client receives a parse error it never
        // asked for.
        var discardingUntilNewline = false

        func drain() {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if discardingUntilNewline {
                    discardingUntilNewline = false  // resynced.
                    continue
                }
                respond(to: Data(line))
            }
            if buffer.count > maxLineBytes {
                FileHandle.standardError.write(Data(
                    ("scarf-projects: dropping an unterminated frame over \(maxLineBytes) "
                        + "bytes; skipping to the next newline\n").utf8
                ))
                buffer.removeAll(keepingCapacity: false)
                discardingUntilNewline = true
            }
        }

        func respond(to line: Data) {
            // Trim BOTH ends: a client writing CRLF leaves a `\r` before
            // the newline, and `JSONDecoder` rejects the trailing byte —
            // every request from such a client would come back as a parse
            // error for a reason that isn't about its JSON.
            var trimmed = line.drop { Self.isFramingWhitespace($0) }
            while let last = trimmed.last, Self.isFramingWhitespace(last) {
                trimmed = trimmed.dropLast()
            }
            guard !trimmed.isEmpty else { return }

            guard let request = JSONRPCRequest.decode(Data(trimmed)) else {
                // No id to answer under, so this is the one case that
                // takes the spec's null-id form.
                emit(JSONRPCResponse.failure(
                    id: .null,
                    code: .parseError,
                    message: "Could not parse a JSON-RPC request from that line."
                ))
                return
            }
            guard let response = server.handle(request) else { return }
            emit(response)
        }

        /// Writes through the THROWING API on purpose. `FileHandle.write`
        /// raises an Objective-C exception when the client has already
        /// closed the pipe, which Swift cannot catch — the server would
        /// die of a broken pipe instead of noticing its client left.
        func emit(_ response: JSONRPCResponse) {
            do {
                try output.write(contentsOf: response.encoded())
            } catch {
                FileHandle.standardError.write(Data(
                    "scarf-projects: stdout closed (\(error.localizedDescription)); stopping\n".utf8
                ))
            }
        }

        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }  // EOF: client hung up.
            buffer.append(chunk)
            drain()
        }
        drain()

        // Anything left has no terminating newline, so it was never a
        // frame. Say so on stderr rather than vanishing: a client whose
        // last write was truncated otherwise sees only silence.
        if !buffer.isEmpty, !discardingUntilNewline {
            FileHandle.standardError.write(Data(
                ("scarf-projects: stdin ended mid-frame; \(buffer.count) unterminated "
                    + "byte(s) were not processed\n").utf8
            ))
        }
    }
}
