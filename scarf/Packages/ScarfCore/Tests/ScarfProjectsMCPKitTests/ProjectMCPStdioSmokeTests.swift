import Testing
import Foundation
@testable import ScarfProjectsMCPKit
@testable import ScarfCore

/// End-to-end over the real transport: spawn the built binary, speak
/// newline-delimited JSON-RPC at its stdin, read its stdout.
///
/// Hermetic — `--hermes-home` points the child at a temp directory, so the
/// developer's `~/.hermes` is never touched even though this is a real
/// process doing real file I/O. That flag exists for exactly this.
@Suite struct ProjectMCPStdioSmokeTests {

    /// The binary next to the test bundle. `nil` when the executable
    /// wasn't built into this products directory (an Xcode-driven run of
    /// the package tests), in which case the test skips rather than
    /// failing for a reason that isn't about the code.
    /// Anchors the search in the bundle that actually contains this test
    /// code. `Bundle.main` is the RUNNER (swift-testing's own harness, or
    /// Xcode's xctest), which is somewhere else entirely — betting on it
    /// is what made this test quietly skip.
    private final class BundleAnchor {}

    static var binaryURL: URL? {
        var roots: [URL] = [
            Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent(),
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
        ]
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            roots.append(bundle.bundleURL.deletingLastPathComponent())
        }
        for root in roots {
            let candidate = root.appendingPathComponent("scarf-projects-mcp")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    @Test("a client that writes CRLF is answered, not sent a parse error")
    func crlfFramingIsAccepted() throws {
        guard let binary = Self.binaryURL else {
            Issue.record("scarf-projects-mcp is not in this products directory")
            return
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-mcp-crlf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--hermes-home", home.path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\r\n".utf8
        ))
        try stdin.fileHandleForWriting.close()
        let output = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        process.waitUntilExit()

        #expect(output.contains("\"result\""))
        #expect(!output.contains("-32700"))
    }

    @Test("initialize, tools/list and a tools/call round-trip over stdio")
    func stdioRoundTrip() throws {
        // The executable is a dependency of this test target, so it is
        // always built. Missing means the wiring broke — fail loudly
        // rather than skip, which is how this test spent its first run
        // proving nothing.
        guard let binary = Self.binaryURL else {
            Issue.record("scarf-projects-mcp is not in this products directory")
            return
        }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-mcp-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("hermes", isDirectory: true)
        let project = base.appendingPathComponent("smoke-project", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"project_register","arguments":{"name":"Smoke","path":"\#(project.path)"}}}"#,
        ].joined(separator: "\n") + "\n"

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--hermes-home", home.path]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        stdin.fileHandleForWriting.write(Data(requests.utf8))
        // Closing stdin is how an MCP stdio client hangs up; the server
        // drains and exits, which is what bounds this test.
        try stdin.fileHandleForWriting.close()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let lines = String(decoding: output, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        // Three requests, one notification — four messages in, three out.
        #expect(lines.count == 3)

        var byID: [Int: [String: JSONValue]] = [:]
        for line in lines {
            guard case .object(let message) = try JSONDecoder()
                .decode(JSONValue.self, from: Data(line.utf8)),
                case .int(let id)? = message["id"]
            else {
                Issue.record("unexpected frame: \(line)")
                continue
            }
            #expect(message["jsonrpc"] == .string("2.0"))
            guard case .object(let result)? = message["result"] else {
                Issue.record("frame \(id) carried no result: \(line)")
                continue
            }
            byID[id] = result
        }

        #expect(byID[1]?["protocolVersion"] == .string("2025-06-18"))
        if case .array(let tools)? = byID[2]?["tools"] {
            #expect(tools.count == 7)
        } else {
            Issue.record("tools/list returned no tools")
        }
        #expect(byID[3]?["isError"] == .bool(false))

        // The call really wrote, through the real services.
        #expect(FileManager.default.fileExists(
            atPath: project.path + "/.scarf/project.json"
        ))
        #expect(FileManager.default.fileExists(
            atPath: home.path + "/scarf/projects.json"
        ))
    }

    /// A client that closes stdout while still holding stdin open used to
    /// leave this loop parsing frames forever, handling and serializing
    /// requests whose answers had nowhere to go — the stderr line says
    /// "stopping", and it wasn't true. Bounded here by the fact that the
    /// call must RETURN with unread bytes still in the pipe.
    @Test("a closed stdout stops the read loop instead of parsing into the void")
    func closedStdoutEndsTheLoop() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-mcp-epipe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let input = Pipe(), output = Pipe()
        // Hang up on the reading side FIRST: the server's first write then
        // fails with EPIPE (SIGPIPE is ignored inside `run`).
        try output.fileHandleForReading.close()

        let requests = Array(repeating: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, count: 8)
            .joined(separator: "\n") + "\n"
        input.fileHandleForWriting.write(Data(requests.utf8))
        // stdin stays OPEN on purpose — EOF must not be what ends this.

        let server = ProjectMCPServer(context: ServerContext.local(home: home))
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            ProjectMCPStdioLoop.run(
                server: server,
                input: input.fileHandleForReading,
                output: output.fileHandleForWriting
            )
            finished.signal()
        }

        #expect(
            finished.wait(timeout: .now() + 5) == .success,
            "run() never returned — the loop kept reading after stdout closed"
        )
        try? input.fileHandleForWriting.close()
    }
}
