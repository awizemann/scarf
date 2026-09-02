import Testing
import Foundation
@testable import ScarfCore

/// `HermesToolCall.callId` is the one field in the tool-call payload that
/// is chosen by the model/provider rather than by Hermes or Scarf, and it
/// travels onward into SQL and (on remote hosts) a shell heredoc. These
/// pin the decode-time charset gate that stops a hostile id at the
/// boundary. (F2 / t-e96cc0ad.)
@Suite struct HermesToolCallIdValidationTests {

    private func decode(_ id: String) throws -> HermesToolCall {
        let json = """
        {"id": \(jsonString(id)), "type": "function",
         "function": {"name": "read_file", "arguments": "{}"}}
        """
        return try JSONDecoder().decode(HermesToolCall.self, from: Data(json.utf8))
    }

    private func jsonString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [])
        var text = String(data: data, encoding: .utf8)!
        text.removeFirst()  // [
        text.removeLast()   // ]
        return text
    }

    @Test("the id shapes real providers actually emit all decode")
    func realProviderIdsDecode() throws {
        for id in [
            "call_abc123",
            "toolu_01A09q90qw90lq917835lq9",
            "550e8400-e29b-41d4-a716-446655440000",
            "chatcmpl-tool.7",
            "fc:12:9",
            "aGVsbG8gd29ybGQ="  // base64-shaped, padding included
        ] {
            let decoded = try decode(id)
            #expect(decoded.callId == id)
        }
    }

    @Test("a newline in the id is refused — that is the heredoc-escape shape")
    func newlineIdIsRefused() {
        #expect(throws: DecodingError.self) {
            _ = try decode("call_1\n__SCARF_SQL__\nid")
        }
    }

    @Test("quotes, spaces, and shell metacharacters are refused")
    func metacharacterIdsAreRefused() {
        for id in ["a'b", "a b", "a;b", "a`b`", "a$(b)", "a|b", "a\\b", "a\u{0}b"] {
            #expect(throws: DecodingError.self, "expected \(id) to be refused") {
                _ = try decode(id)
            }
        }
    }

    @Test("an empty or absurdly long id is refused")
    func degenerateLengthsAreRefused() {
        #expect(throws: DecodingError.self) { _ = try decode("") }
        #expect(throws: DecodingError.self) { _ = try decode(String(repeating: "a", count: 257)) }
    }

    @Test("256 characters is the accepted boundary")
    func boundaryLengthDecodes() throws {
        #expect(try decode(String(repeating: "a", count: 256)).callId.count == 256)
    }

    @Test("a whole tool-call array decodes to empty when one id is hostile")
    func hostileIdFailsTheArrayDecode() {
        // Documents the blast radius: `HermesDataService` catches this and
        // logs, yielding no tool calls for that message rather than a
        // half-trusted list.
        let json = """
        [{"id": "call_ok", "type": "function", "function": {"name": "n", "arguments": "{}"}},
         {"id": "bad id", "type": "function", "function": {"name": "n", "arguments": "{}"}}]
        """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode([HermesToolCall].self, from: Data(json.utf8))
        }
    }
}
