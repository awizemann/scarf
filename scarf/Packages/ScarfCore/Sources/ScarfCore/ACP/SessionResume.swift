import Foundation
#if canImport(os)
import os
#endif

/// How a chat resumes a past session over ACP, shared by the Mac chat and
/// ScarfGo so neither can drift into a silent "new session wearing the old
/// transcript" (#146).
///
/// Hermes's ACP adapter restores ONLY sessions it created itself:
/// `_restore` returns None for any row whose `source != "acp"`
/// (acp_adapter/session.py:428 @ v0.21.5), and `load_session` then answers
/// None (acp_adapter/server.py:616-624), which reaches the wire as
/// `null`/`{}` (``ACPClientError/sessionNotRestorable(sessionId:)``). A
/// session born in hermes-webui, the CLI, a gateway platform or cron can
/// therefore never be `session/load`-ed; the only honest option is a fresh
/// session in the same cwd, SAID OUT LOUD in the transcript — the model has
/// none of the earlier context, whatever the replayed transcript shows.
///
/// Bot Chat makes the same source call up front
/// (`CanonicalBotChat.isACPBorn`) and picks a different transport instead;
/// chat has no second transport, so it continues as a new session.
public enum SessionResume {

    /// Why a resume continued as a new session instead of reopening.
    public enum FallbackReason: Equatable, Sendable {
        /// The session's `sessions.source` is not `"acp"` — Hermes can't
        /// load it, so Scarf never asked. Carries the raw source.
        case nonACPSource(String)
        /// `session/load` answered not-restorable (an ACP session Hermes
        /// no longer has, or a row the source lookup couldn't read).
        case notRestorable
    }

    public enum Outcome: Equatable, Sendable {
        /// Hermes reopened the session. `head` is the load's
        /// `sessionProvenance.currentHermesSessionId`, when reported.
        case loaded(sessionId: String, head: String?)
        /// A fresh ACP session carries the chat on, without the earlier
        /// context.
        case continuedAsNew(sessionId: String, reason: FallbackReason)

        public var sessionId: String {
            switch self {
            case .loaded(let id, _), .continuedAsNew(let id, _): return id
            }
        }

        public var loadedHead: String? {
            if case .loaded(_, let head) = self { return head }
            return nil
        }

        public var fallbackReason: FallbackReason? {
            if case .continuedAsNew(_, let reason) = self { return reason }
            return nil
        }
    }

    /// The source a resume must NOT try to load, or nil when a load is
    /// worth attempting. An unknown source (nil / empty — the lookup
    /// failed, or a pre-`source` row) attempts the load: Hermes is the
    /// authority, and its not-restorable answer is still handled.
    public static func unloadableSource(_ source: String?) -> String? {
        guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty, source != "acp" else { return nil }
        return source
    }

    /// True only for the load failure a fresh session may answer. Every
    /// other error (a timeout, a dead process, a JSON-RPC error such as a
    /// future -32602) is transient or real, and must surface as an error
    /// with a retry — never be papered over by a new session.
    public static func isNotRestorable(_ error: Error) -> Bool {
        if case ACPClientError.sessionNotRestorable = error { return true }
        return false
    }

    /// Resolve a resume: skip the load for a non-ACP source, load
    /// otherwise, and fall back to `newSession` ONLY on not-restorable.
    /// Any other load error, and any `newSession` error, is rethrown.
    ///
    /// Logs every fallback and records `session_resume_fallback` for it
    /// here, once, so the Mac and ScarfGo can't drift apart (the string
    /// seam is a no-op on iOS, which installs no recorder).
    public static func resolve(
        sessionId: String,
        source: String?,
        load: (String) async throws -> (sessionId: String, head: String?),
        newSession: () async throws -> String,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Outcome {
        if let unloadable = unloadableSource(source) {
            let newId = try await newSession()
            noteFallback(from: sessionId, to: newId, reason: .nonACPSource(unloadable))
            return .continuedAsNew(sessionId: newId, reason: .nonACPSource(unloadable))
        }
        do {
            let loaded = try await load(sessionId)
            return .loaded(sessionId: loaded.sessionId, head: loaded.head)
        } catch where isNotRestorable(error) {
            let newId = try await newSession()
            noteFallback(from: sessionId, to: newId, reason: .notRestorable)
            return .continuedAsNew(sessionId: newId, reason: .notRestorable)
        } catch {
            #if canImport(os)
            logger.error("session/load failed for \(sessionId, privacy: .public) — not falling back: \(error.localizedDescription, privacy: .public)")
            #endif
            throw error
        }
    }

    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "SessionResume")
    #endif

    private static func noteFallback(from oldId: String, to newId: String, reason: FallbackReason) {
        #if canImport(os)
        switch reason {
        case .nonACPSource(let source):
            logger.info("Session \(oldId, privacy: .public) has source \(source, privacy: .public); Hermes can't load it — continuing as new session \(newId, privacy: .public)")
        case .notRestorable:
            logger.info("Session \(oldId, privacy: .public) not restorable over ACP — continuing as new session \(newId, privacy: .public)")
        }
        #endif
        ScarfAnalytics.record("session_resume_fallback", ["kind": analyticsKind(for: reason)])
    }

    /// Read `sessions.source` for `sessionId` from state.db (read-only,
    /// C3) on a private data service, so the lookup can't close the chat
    /// view model's own connection under a history load. Nil when the row
    /// or the DB can't be read.
    public static func fetchSource(context: ServerContext, sessionId: String) async -> String? {
        let service = HermesDataService(context: context)
        guard await service.open() else { return nil }
        let source = await service.fetchSession(id: sessionId)?.source
        await service.close()
        return source
    }

    /// The analytics `kind` for a fallback (`session_resume_fallback`).
    public static func analyticsKind(for reason: FallbackReason) -> String {
        switch reason {
        case .nonACPSource: return "non_acp_source"
        case .notRestorable: return "new_session_fallback"
        }
    }

    /// The persistent transcript notice for a fallback.
    ///
    /// - Parameter mentionsKanban: add the Kanban sentence. Only an
    ///   ACP-born session can have tasks stamped with its id (`kanban list
    ///   --session` filters on the originating ACP session, and takes ONE
    ///   id — hermes_cli/kanban_parser.py:239 @ v0.21.5), so the chat's
    ///   badge, which follows the new id, stops counting them. Pass true
    ///   only where a chat surface shows that badge.
    public static func notice(for reason: FallbackReason, mentionsKanban: Bool = false) -> String {
        switch reason {
        case .nonACPSource(let source):
            return String(localized: "This session started in \(source). Hermes can’t reopen it here, so this chat continues as a new session without its earlier context.")
        case .notRestorable:
            let base = String(localized: "Hermes couldn’t reopen this session, so this chat continues as a new session without its earlier context.")
            guard mentionsKanban else { return base }
            return base + " " + String(localized: "Kanban tasks the earlier session started are still on the Kanban board, but this chat’s badge no longer counts them.")
        }
    }
}
