import Foundation
import Observation

/// iOS Memory editor state. Loads MEMORY.md / USER.md via the
/// transport, holds the text in-memory, saves on explicit action.
///
/// Lives in ScarfCore (not ScarfIOS) because it's pure file-I/O on
/// top of `ServerContext.readText` / `writeText` — no Keychain, no
/// Citadel, no UIKit — and that lets the state machine be unit-
/// tested on Linux with `InMemory` mocks.
///
/// **Which file.** Constructor takes `kind` (`.memory` or `.user`)
/// and picks the corresponding path via `ServerContext.paths`. Users
/// toggle between the two via navigation.
@Observable
@MainActor
public final class IOSMemoryViewModel {
    public enum Kind: Sendable, Equatable {
        /// `~/.hermes/memories/MEMORY.md` — the agent's persistent
        /// memory. Visible (and editable) to the agent at every
        /// session start.
        case memory
        /// `~/.hermes/memories/USER.md` — user-profile notes the
        /// agent reads but (by default) does not write.
        case user

        /// Heading shown in the UI.
        public var displayName: String {
            switch self {
            case .memory: return "MEMORY.md"
            case .user:   return "USER.md"
            }
        }

        /// SF Symbol used in the list row.
        public var iconName: String {
            switch self {
            case .memory: return "brain.head.profile"
            case .user:   return "person.crop.square"
            }
        }

        /// Terse explanation shown under the heading.
        public var subtitle: String {
            switch self {
            case .memory:
                return "Agent's persistent memory. Appears in every session prompt."
            case .user:
                return "Notes about you. Read by the agent but not modified automatically."
            }
        }

        /// Resolve the remote path for this memory file on the
        /// given context. `ServerContext.paths` exposes both
        /// `memoryMD` and `userMD` directly.
        public func path(on context: ServerContext) -> String {
            switch self {
            case .memory: return context.paths.memoryMD
            case .user:   return context.paths.userMD
            }
        }
    }

    public let kind: Kind
    public let context: ServerContext

    /// Content loaded from the file. `text` binds to the editor; the
    /// view compares against `originalText` to gate the Save button.
    public var text: String = ""
    public private(set) var originalText: String = ""

    public private(set) var isLoading: Bool = true
    public private(set) var isSaving: Bool = false
    public private(set) var lastError: String?

    public var hasUnsavedChanges: Bool { text != originalText }

    public init(kind: Kind, context: ServerContext) {
        self.kind = kind
        self.context = context
    }

    public func load() async {
        isLoading = true
        lastError = nil
        // Run the file read on a detached task — `ServerContext.readText`
        // blocks on transport I/O, and we don't want the MainActor
        // hanging during a remote SFTP fetch.
        let ctx = context
        let path = kind.path(on: context)
        let loaded: String? = await Task.detached {
            ctx.readText(path)
        }.value

        if let loaded {
            text = loaded
            originalText = loaded
        } else {
            // `readText` returns nil on missing file — treat as
            // empty (the user is creating the file for the first
            // time) rather than an error.
            text = ""
            originalText = ""
        }
        isLoading = false
    }

    public func save() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        lastError = nil
        let ctx = context
        let path = kind.path(on: context)
        let snapshot = text
        let ok: Bool = await Task.detached {
            ctx.writeText(path, content: snapshot)
        }.value
        isSaving = false
        if ok {
            originalText = snapshot
            return true
        } else {
            lastError = "Couldn't save \(kind.displayName) — check the connection and try again."
            return false
        }
    }

    /// Revert in-memory edits back to whatever the file contained
    /// at last load.
    public func revert() {
        text = originalText
    }
}
