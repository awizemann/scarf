import Foundation
import ScarfCore

/// Remote profile export that lands on **this Mac** (gh#132).
///
/// `hermes profile export` has no stdout mode (only `--output <path>`),
/// so the sessions-export trick (gh#129/PR#130) isn't available. Instead:
/// export to a scratch path on the host, stream the archive down chunk-by-
/// chunk, move it into the `NSSavePanel` destination, delete the scratch.
/// Same shape as `RemoteBackupService` — a ~300 MB profile never lands in
/// memory (`transport.readFile` is a fully-buffered `cat`, scoped by its
/// own comment to files under 1 MB; never use it here).
///
/// Steps are injected as closures so tests can pin the pipeline without
/// SSH — the same seam idea as `SessionsViewModel.sessionExportRunner`.
enum RemoteProfileExport {

    /// Host-side scratch path. `/tmp` so it exists and is writable for
    /// any SSH user; UUID so concurrent exports can't collide; generated
    /// (never user input) so it needs no shell quoting.
    ///
    /// The extension must be `.tar.gz`: `export_profile` strips exactly
    /// `.tar.gz`/`.tgz` and re-appends `.tar.gz`, so the old `.zip`
    /// scratch path made the CLI write `…​.zip.tar.gz` while the download
    /// step went looking for `….zip`. That file never existed, so remote
    /// profile export failed every single time.
    static func remoteTempPath(uuid: UUID = UUID()) -> String {
        HermesProfileArchive.remoteScratchPath(uuid: uuid)
    }

    /// Report progress every 16 MiB — often enough to show life on a
    /// 300 MB pull, rare enough to not thrash the main actor.
    private static let progressStride: Int64 = 16 << 20

    static func run(
        profileName: String,
        destination: URL,
        runCLI: ([String], TimeInterval) -> (exitCode: Int32, output: String),
        streamFile: (String) -> AsyncThrowingStream<Data, Error>,
        removeRemote: (String) -> Void,
        onProgress: (Int64) -> Void = { _ in }
    ) async -> (succeeded: Bool, message: String) {
        let remoteTemp = remoteTempPath()
        let export = runCLI(["profile", "export", "--output", remoteTemp, "--", profileName], 300)
        guard export.exitCode == 0 else {
            return (false, ProfilesViewModel.failureMessage(export.output))
        }
        // From here the archive exists on the host — clean it up on every path.
        defer { removeRemote(remoteTemp) }

        // Download into a hidden sibling of the destination (same volume,
        // so the final move is atomic) and only move into place on
        // success — a failed stream must not leave a truncated archive where
        // the user chose to save.
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: partial) else {
            return (false, "Export failed: couldn't write to \(destination.deletingLastPathComponent().path).")
        }
        var written: Int64 = 0
        do {
            defer { try? handle.close() }
            var nextReport = progressStride
            for try await chunk in streamFile(remoteTemp) {
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                if written >= nextReport {
                    nextReport = written + progressStride
                    onProgress(written)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return (false, "Export download failed: \(error.localizedDescription)")
        }
        guard written > 0 else {
            try? FileManager.default.removeItem(at: partial)
            return (false, "Export failed: the host produced an empty archive.")
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return (false, "Export failed moving the archive into place: \(error.localizedDescription)")
        }
        let size = written.formatted(.byteCount(style: .file))
        return (true, "Exported \(size) to \(destination.path)")
    }
}
