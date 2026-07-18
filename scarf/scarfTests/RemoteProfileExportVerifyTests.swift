import Testing
import Foundation
@testable import scarf

/// gh#131: the remote profile-export sheet's Verify reported a green
/// "Path is available" for a destination whose parent directory doesn't
/// exist on the host — `hermes profile export --output` doesn't create
/// intermediate directories, so that green preceded a guaranteed
/// traceback. These pin the extracted verdict logic against stubbed
/// filesystem answers, no transport involved.
@Suite struct RemoteProfileExportVerifyTests {

    private typealias Verifier = RemoteWritablePathVerifier

    /// A host filesystem simulated as [path: isDirectory].
    private static func verdict(path: String, fs: [String: Bool]) -> Verifier.Verdict {
        Verifier.verdict(
            path: path,
            host: "build-box",
            exists: { fs[$0] != nil },
            isDirectory: { fs[$0] }
        )
    }

    @Test("The gh#131 repro: missing parent directory is no longer green")
    func missingParentWarns() {
        let v = Self.verdict(path: "~/exports/my-profile.zip", fs: [:])
        #expect(v == .warn("~/exports/ doesn't exist on build-box — create it first, or choose another path."))
    }

    @Test("Existing parent directory verifies OK")
    func existingParentIsOK() {
        let v = Self.verdict(path: "~/exports/my-profile.zip", fs: ["~/exports": true])
        #expect(v == .ok("Path is available on build-box."))
    }

    @Test("A parent that is a file, not a directory, warns")
    func fileParentWarns() {
        let v = Self.verdict(path: "~/exports/my-profile.zip", fs: ["~/exports": false])
        #expect(v == .warn("~/exports isn't a directory on build-box."))
    }

    @Test("A home-root path skips the parent check — $HOME always exists")
    func homeRootSkipsParentCheck() {
        let v = Self.verdict(path: "~/my-profile.zip", fs: [:])
        #expect(v == .ok("Path is available on build-box."))
    }

    @Test("An existing file still warns about overwrite")
    func existingFileWarnsOverwrite() {
        let v = Self.verdict(path: "~/exports/my-profile.zip",
                             fs: ["~/exports": true, "~/exports/my-profile.zip": false])
        #expect(v == .warn("File already exists on build-box — export will overwrite it."))
    }

    @Test("A directory at the destination warns")
    func directoryDestinationWarns() {
        let v = Self.verdict(path: "~/exports", fs: ["~/exports": true])
        #expect(v == .warn("Path is a directory. Choose a file path that doesn't yet exist."))
    }

    @Test("Non-zip extension still warns once the parent checks out")
    func nonZipWarns() {
        let v = Self.verdict(path: "~/exports/my-profile.tar", fs: ["~/exports": true])
        #expect(v == .warn("Extension isn't `.zip`. The export command writes a zip archive."))
    }

    @Test("A Python traceback failure reports its last line, not its first")
    @MainActor
    func tracebackReducedToLastLine() {
        let traceback = """
        Traceback (most recent call last):
          File "/home/hermes/.hermes/hermes-agent/venv/bin/hermes", line 10, in <module>
            sys.exit(main())
        FileNotFoundError: [Errno 2] No such file or directory: '/home/hermes/exports/p.zip'
        """
        let message = ProfilesViewModel.failureMessage(traceback)
        #expect(message == "Failed: FileNotFoundError: [Errno 2] No such file or directory: '/home/hermes/exports/p.zip'")
    }

    @Test("Empty CLI output still produces a failure message")
    @MainActor
    func emptyOutputStillReports() {
        #expect(ProfilesViewModel.failureMessage("  \n\n") == "Failed (no output).")
    }
}
