import Foundation
import Observation

/// iOS Settings view-state. Loads `~/.hermes/config.yaml` via the
/// transport, parses it into a `HermesConfig` with the ScarfCore
/// YAML port, and exposes the parsed struct plus a copy of the raw
/// text for users who want to see the source.
///
/// **M6 is read-only by design.** Editing config.yaml safely requires
/// either (a) a round-trip preserving YAML parser (comments, key
/// order, whitespace) or (b) delegating to `hermes config set` via
/// ACP. Either is more work than fits in M6; the Mac app's Settings
/// uses (a) via HermesFileService's manipulators. A later phase can
/// port the write side.
@Observable
@MainActor
public final class IOSSettingsViewModel {
    public let context: ServerContext

    /// Parsed config. Falls back to `.empty` when the file is missing
    /// or malformed; `lastError` carries the reason so the UI can
    /// surface it.
    public private(set) var config: HermesConfig = .empty
    /// Raw YAML text. Useful for the "View source" disclosure, and
    /// for diagnosing parse failures (our parser is forgiving but
    /// lossy on malformed input).
    public private(set) var rawYAML: String = ""

    public private(set) var isLoading: Bool = true
    public private(set) var lastError: String?

    public init(context: ServerContext) {
        self.context = context
    }

    public func load() async {
        isLoading = true
        lastError = nil
        let ctx = context
        let path = ctx.paths.configYAML

        let text: String? = await Task.detached {
            ctx.readText(path)
        }.value

        guard let text else {
            config = .empty
            rawYAML = ""
            lastError = "`\(path)` not found on \(ctx.displayName). Once Hermes is configured on this host, Settings will light up."
            isLoading = false
            return
        }

        rawYAML = text
        config = HermesConfig(yaml: text)
        isLoading = false
    }
}
