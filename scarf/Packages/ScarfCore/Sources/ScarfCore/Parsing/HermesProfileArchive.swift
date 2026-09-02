import Foundation

/// Archive-path rules for `hermes profile export` / `profile import`.
///
/// Hermes writes **gzipped tars, always** — there is no zip path in the
/// CLI at any version. `profiles.py::export_profile` does:
///
/// ```python
/// base = str(output).removesuffix(".tar.gz").removesuffix(".tgz")
/// ...
/// result = make_targz(base, tmpdir, canon)
/// ```
///
/// `make_targz` appends `.tar.gz` to `base`. So the extension is not
/// merely cosmetic: handing the CLI `~/foo.zip` makes it strip nothing,
/// then write **`~/foo.zip.tar.gz`** — a file at a path the caller never
/// asked for. Scarf offered `.zip` in the save panel, named the remote
/// scratch file `.zip`, and then reported "Exported" for a file that did
/// not exist. On remote hosts the follow-up download of the `.zip` path
/// failed outright, so remote profile export could never succeed.
public enum HermesProfileArchive {

    /// Extensions the CLI recognises and strips before re-appending.
    public static let recognizedExtensions = ["tar.gz", "tgz"]

    /// The canonical extension Scarf should produce.
    public static let preferredExtension = "tar.gz"

    /// Filename suffix for a profile's export, e.g. `dev-profile.tar.gz`.
    public static func suggestedFilename(for profileName: String) -> String {
        "\(profileName)-profile.\(preferredExtension)"
    }

    /// True when *path* already carries an extension `export_profile`
    /// strips — i.e. the file the CLI writes will land exactly here.
    public static func isRecognized(_ path: String) -> Bool {
        let lower = path.lowercased()
        return recognizedExtensions.contains { lower.hasSuffix("." + $0) }
    }

    /// Normalises a user-chosen destination to a path the CLI will write
    /// verbatim.
    ///
    /// `~/dev.tar.gz` → unchanged. `~/dev.zip` → `~/dev.tar.gz` (the zip
    /// extension is replaced, not appended to, so the user does not end
    /// up with `dev.zip.tar.gz`). `~/dev` → `~/dev.tar.gz`.
    public static func normalizedOutputPath(_ path: String) -> String {
        if isRecognized(path) { return path }
        var base = path
        // Strip one misleading archive-ish extension if present.
        for wrong in [".zip", ".tar", ".gz", ".gzip"] where base.lowercased().hasSuffix(wrong) {
            base = String(base.dropLast(wrong.count))
            break
        }
        return base + "." + preferredExtension
    }

    /// A `/tmp` scratch path for the remote-export round trip. `.tar.gz`
    /// so the CLI writes exactly this path and the download can find it.
    public static func remoteScratchPath(uuid: UUID = UUID()) -> String {
        "/tmp/scarf-profile-export-\(uuid.uuidString).\(preferredExtension)"
    }

    /// Validation verdict for an import path the user typed or picked.
    public enum ImportVerdict: Sendable, Equatable {
        case ok
        /// Readable, but the extension is not one `import_profile`
        /// expects. Import may still work (the CLI sniffs the tar), so
        /// this is a warning, not a block.
        case wrongExtension
    }

    /// Checks an import archive's extension. `import_profile` opens the
    /// path with `tarfile`, so `.tar.gz` and `.tgz` are the true shapes;
    /// a `.zip` will fail CLI-side, and warning early is kinder than
    /// surfacing a Python traceback.
    public static func validateImportPath(_ path: String) -> ImportVerdict {
        isRecognized(path) ? .ok : .wrongExtension
    }
}
