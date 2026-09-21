import Foundation
import Testing
@testable import ScarfCore

/// WHICH id reaches Hermes's `kanban list --session=…`.
///
/// Hermes stamps a task's `session_id` from the environment variable the ACP
/// adapter sets to its own ACP session id (`acp_adapter/server.py:793-794` @
/// tag `v2026.9.21`), so the filter matches ONLY if Scarf sends that same ACP
/// session id. Sending a `sessions.id` row id, a Scarf-local `UUID()`, or the
/// terminal-mode DB id that `ChatViewModel` also writes into
/// `RichChatViewModel.sessionId` would spell the flag perfectly and silently
/// return an empty board forever.
///
/// The existing kanban tests are all string/decoder tests: they prove the
/// flag's SPELLING and would pass unchanged against any of those wrong ids.
/// This suite pins the VALUE's provenance.
///
/// **Why a source sweep.** The two links in the chain live in the macOS app
/// target (`KanbanChatBadgeViewModel`, `ChatTranscriptPane`), which ScarfCore
/// cannot import, and the id's origin is an `ACPClient.newSession` /
/// `loadSession` round trip — reproducing that behaviourally would need a
/// full ACP mock plus a SwiftUI host. The sweep asserts the wiring instead:
/// each hop's argument is spelled from the previous hop, with no other id
/// source anywhere near a kanban scope. A refactor that feeds a different id
/// has to edit one of these lines, and fails here.
///
/// Not `@MainActor`, and it compiles one regex over two small files — see the
/// project's ScarfCore test-hog rule.
@Suite("Kanban --session carries the chat's ACP session id")
struct KanbanChatSessionIdWiringTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/ScarfCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/ScarfCore
            .deletingLastPathComponent()   // …/Packages
            .deletingLastPathComponent()   // …/scarf
            .deletingLastPathComponent()   // repo root
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private static let badgePath =
        "scarf/scarf/Features/Chat/ViewModels/KanbanChatBadgeViewModel.swift"
    private static let panePath =
        "scarf/scarf/Features/Chat/Views/ChatTranscriptPane.swift"

    /// Spellings that would mean a DIFFERENT id had been wired in. Each is a
    /// real id that exists in the same scope: the Hermes DB row id on a
    /// `HermesSession`, the selected-session id the sessions list carries,
    /// and a freshly minted Scarf-local identifier.
    private static let wrongIdSpellings = [
        "UUID(", "session.id", "hermesSession", "dbSessionId", "selectedSessionId",
    ]

    // MARK: - Hop 1: the poller's parameter is the only thing that scopes the filter

    @Test("the badge scopes KanbanListFilter with its own sessionId parameter, nothing else")
    func badgeFilterUsesThePassedSessionId() throws {
        let src = try Self.source(Self.badgePath)

        let constructions = src.ranges(of: "KanbanListFilter(")
        #expect(constructions.count == 1, "the badge must build exactly one kanban filter")
        #expect(src.contains("KanbanListFilter(session: sessionId)"))

        // `sessionId` must be a parameter threaded from `run`, never re-derived.
        #expect(src.contains("func run("))
        #expect(src.contains("sessionId: String"))
        #expect(src.contains("await poll(sessionId: sessionId)"))
        #expect(src.contains("private func poll(sessionId: String)"))

        for wrong in Self.wrongIdSpellings {
            #expect(!src.contains(wrong), "\(wrong) must not be an id source in the kanban badge")
        }
    }

    // MARK: - Hop 2: the host passes the chat's ACP session id

    /// The `count` lines starting at the first line containing `anchor` —
    /// the only slice of this large view file that scopes a kanban call.
    private static func region(_ src: String, from anchor: String, lines count: Int) throws -> String {
        let lines = src.components(separatedBy: "\n")
        let start = try #require(
            lines.firstIndex(where: { $0.contains(anchor) }),
            "anchor \(anchor) is gone — the kanban wiring moved and this pin needs re-aiming"
        )
        return lines[start..<min(start + count, lines.count)].joined(separator: "\n")
    }

    @Test("the transcript pane feeds the badge and the hand-off from richChat.sessionId")
    func paneFeedsTheACPSessionId() throws {
        let src = try Self.source(Self.panePath)

        // The poller: `sid` is bound from `richChat.sessionId` and is what
        // `run(sessionId:)` receives.
        let poller = try Self.region(src, from: ".task(id: kanbanBadgePollKey)", lines: 16)
        #expect(poller.contains("let sid = richChat.sessionId"))
        #expect(poller.contains("sessionId: sid"))

        // The hand-off to the full Kanban board: same source.
        let handoff = try Self.region(src, from: "private func handleOpenKanban()", lines: 10)
        #expect(handoff.contains("guard let sessionId = richChat.sessionId else { return }"))
        #expect(handoff.contains("sessionId: sessionId"))

        // `richChat.sessionId` must be the ONLY id spelled into either kanban
        // scope — the rest of this file legitimately handles other ids.
        for wrong in Self.wrongIdSpellings {
            #expect(!poller.contains(wrong), "\(wrong) must not scope the kanban badge poll")
            #expect(!handoff.contains(wrong), "\(wrong) must not scope the kanban hand-off")
        }

        // The poll key restarts the loop when the chat's session changes; if
        // it stopped keying on the same id the badge would show another
        // session's count after a /new.
        let pollKey = try Self.region(src, from: "private var kanbanBadgePollKey: String", lines: 8)
        #expect(pollKey.contains("richChat.sessionId ?? \"\""))
    }

    // MARK: - Hop 3: the filter turns exactly that id into the flag

    @Test("the id the badge holds is what lands in --session, unaltered")
    func theIdReachesTheFlagVerbatim() {
        // An ACP session id is an opaque uuid-shaped string; the filter must
        // pass it through untouched, not normalise or re-case it.
        let acpSessionId = "64c89a0a-5877-4920-bb53-2ecf469129d1"
        let argv = KanbanListFilter(session: acpSessionId).argv()

        #expect(HermesCLIOption.value(of: "--session", in: argv) == acpSessionId)
        // A different id must not be able to satisfy the assertion above.
        #expect(HermesCLIOption.value(of: "--session", in: argv) != "some-db-row-id")
    }
}
