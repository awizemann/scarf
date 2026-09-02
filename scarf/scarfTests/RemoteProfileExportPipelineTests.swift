import Testing
import Foundation
@testable import scarf

/// gh#132: profile export lands on this Mac, whichever host Hermes runs
/// on. The pipeline exports to a host-side scratch path, streams the archive
/// down, and moves it into the chosen destination. All steps are stubbed
/// closures — no SSH, no subprocess.
@Suite struct RemoteProfileExportPipelineTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _cliArgs: [[String]] = []
        private var _removed: [String] = []
        func recordCLI(_ args: [String]) { lock.lock(); defer { lock.unlock() }; _cliArgs.append(args) }
        func recordRemove(_ path: String) { lock.lock(); defer { lock.unlock() }; _removed.append(path) }
        var cliArgs: [[String]] { lock.lock(); defer { lock.unlock() }; return _cliArgs }
        var removed: [String] { lock.lock(); defer { lock.unlock() }; return _removed }
    }

    private static func tempDestination() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-profile-export-test-\(UUID().uuidString).zip")
    }

    private static func stream(chunks: [Data], throwing error: Error? = nil) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish(throwing: error)
        }
    }

    @Test("Happy path: CLI targets a /tmp scratch tar.gz, bytes land verbatim, scratch is removed")
    func happyPath() async {
        let recorder = Recorder()
        let dest = Self.tempDestination()
        defer { try? FileManager.default.removeItem(at: dest) }
        let payload = Data("PK\u{03}\u{04}fake-zip-bytes".utf8)

        let result = await RemoteProfileExport.run(
            profileName: "alpha",
            destination: dest,
            runCLI: { args, _ in recorder.recordCLI(args); return (0, "") },
            streamFile: { _ in Self.stream(chunks: [payload.prefix(5), payload.dropFirst(5)]) },
            removeRemote: { recorder.recordRemove($0) }
        )

        #expect(result.succeeded)
        #expect(result.message.contains("Exported"))
        #expect(result.message.contains(dest.path))
        #expect(try! Data(contentsOf: dest) == payload)

        // The CLI must be pointed at a generated scratch path on the host,
        // never at the Mac-side destination (the gh#129 bug class).
        #expect(recorder.cliArgs.count == 1)
        let args = recorder.cliArgs[0]
        // `--` before the profile name so a name can never be read as a flag.
        #expect(args.prefix(2) == ["profile", "export"])
        #expect(args.suffix(2) == ["--", "alpha"])
        let outputIndex = args.firstIndex(of: "--output")!
        let scratch = args[outputIndex + 1]
        #expect(scratch.hasPrefix("/tmp/scarf-profile-export-"))
        // `.tar.gz`, not `.zip`: `export_profile` strips only .tar.gz/.tgz
        // and then re-appends .tar.gz, so a `.zip` scratch path made the
        // CLI write `….zip.tar.gz` and the download look for a file that
        // never existed — remote export could not succeed at all.
        #expect(scratch.hasSuffix(".tar.gz"))
        #expect(scratch != dest.path)
        #expect(recorder.removed == [scratch])
    }

    @Test("A CLI traceback surfaces its last line and writes nothing locally")
    func cliFailureSurfacesLastLine() async {
        let recorder = Recorder()
        let dest = Self.tempDestination()
        let traceback = """
        Traceback (most recent call last):
          File "hermes", line 10, in <module>
        PermissionError: [Errno 13] Permission denied: '/tmp'
        """

        let result = await RemoteProfileExport.run(
            profileName: "alpha",
            destination: dest,
            runCLI: { _, _ in (1, traceback) },
            streamFile: { _ in Self.stream(chunks: []) },
            removeRemote: { recorder.recordRemove($0) }
        )

        #expect(!result.succeeded)
        #expect(result.message == "Failed: PermissionError: [Errno 13] Permission denied: '/tmp'")
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        // Nothing was exported, so there is nothing to clean up remotely.
        #expect(recorder.removed.isEmpty)
    }

    @Test("A mid-stream failure leaves no partial file and still cleans up the host")
    func streamFailureLeavesNoPartial() async {
        let recorder = Recorder()
        let dest = Self.tempDestination()

        struct Dropped: Error, LocalizedError {
            var errorDescription: String? { "SSH channel closed" }
        }
        let result = await RemoteProfileExport.run(
            profileName: "alpha",
            destination: dest,
            runCLI: { _, _ in (0, "") },
            streamFile: { _ in Self.stream(chunks: [Data("half".utf8)], throwing: Dropped()) },
            removeRemote: { recorder.recordRemove($0) }
        )

        #expect(!result.succeeded)
        #expect(result.message.contains("SSH channel closed"))
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        let partial = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.lastPathComponent).partial")
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(recorder.removed.count == 1)
    }

    @Test("An empty archive is a failure, not a silent zero-byte export")
    func emptyStreamFails() async {
        let dest = Self.tempDestination()
        let result = await RemoteProfileExport.run(
            profileName: "alpha",
            destination: dest,
            runCLI: { _, _ in (0, "") },
            streamFile: { _ in Self.stream(chunks: []) },
            removeRemote: { _ in }
        )
        #expect(!result.succeeded)
        #expect(result.message.contains("empty archive"))
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("An existing destination is replaced — NSSavePanel already confirmed the overwrite")
    func existingDestinationIsReplaced() async {
        let dest = Self.tempDestination()
        defer { try? FileManager.default.removeItem(at: dest) }
        try! Data("stale".utf8).write(to: dest)
        let fresh = Data("fresh-zip".utf8)

        let result = await RemoteProfileExport.run(
            profileName: "alpha",
            destination: dest,
            runCLI: { _, _ in (0, "") },
            streamFile: { _ in Self.stream(chunks: [fresh]) },
            removeRemote: { _ in }
        )

        #expect(result.succeeded)
        #expect(try! Data(contentsOf: dest) == fresh)
    }

    // `ProfilesViewModel.failureMessage` coverage lived alongside the
    // gh#131 verifier tests; the verifier is gone (no write-path sheet
    // remains) but the message reduction is load-bearing for every
    // Profiles CLI failure, so it's pinned here.

    @Test("A Python traceback failure reports its last line, not its first")
    func tracebackReducedToLastLine() {
        let traceback = """
        Traceback (most recent call last):
          File "/home/hermes/.hermes/hermes-agent/venv/bin/hermes", line 10, in <module>
            sys.exit(main())
        FileNotFoundError: [Errno 2] No such file or directory: '/home/hermes/exports/p.zip'
        """
        #expect(ProfilesViewModel.failureMessage(traceback)
                == "Failed: FileNotFoundError: [Errno 2] No such file or directory: '/home/hermes/exports/p.zip'")
    }

    @Test("Empty CLI output still produces a failure message")
    func emptyOutputStillReports() {
        #expect(ProfilesViewModel.failureMessage("  \n\n") == "Failed (no output).")
    }
}
