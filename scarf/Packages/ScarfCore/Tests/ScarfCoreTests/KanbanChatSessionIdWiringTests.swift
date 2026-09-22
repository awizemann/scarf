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
        // `issuedFor` is the id `KanbanChatBadgeState.beginPoll()` hands back —
        // i.e. the bound chat session — and is both what scopes the filter and
        // what the result is stamped with, so a stale reply can be rejected.
        #expect(src.contains("KanbanListFilter(session: issuedFor)"))
        #expect(src.contains("let issuedFor = state.beginPoll()"))
        #expect(src.contains("state.accept(count: count, issuedFor: issuedFor)"))
        #expect(src.contains("state.fail(issuedFor: issuedFor)"))
        // The bound id comes from the host via `bind(to:)`, never re-derived.
        #expect(src.contains("func bind(to sessionId: String?)"))
        #expect(src.contains("state.bind(to: sessionId)"))

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

        // The poller: `sid` is bound from `richChat.sessionId` and is the only
        // thing the badge is ever pointed at.
        let poller = try Self.region(src, from: ".task(id: kanbanBadgePollKey)", lines: 24)
        #expect(poller.contains("let sid = richChat.sessionId"))
        #expect(poller.contains("bind(to: sid)"))
        // Both exits rebind: the unpollable one to nil, so a chat with no
        // session (a fresh window, a /new) renders no number instead of the
        // previous chat's.
        #expect(
            poller.contains("bind(to: nil)"),
            "the no-session path must clear the badge, or a switched chat keeps a stale count"
        )
        let clearOffset = try #require(poller.range(of: "bind(to: nil)")).lowerBound
        let runOffset = try #require(poller.range(of: "run(capabilities:")).lowerBound
        #expect(clearOffset < runOffset, "the clear belongs on the early-return path, not after run")

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
        let pollKey = try Self.region(src, from: "private var kanbanBadgePollKey: String", lines: 10)
        #expect(pollKey.contains("richChat.sessionId ?? \"\""))
        // …and the scene phase, so a backgrounded window stops spawning
        // `hermes kanban list` every five seconds (C10) — the same pause
        // KanbanBoardView/KanbanListView/KanbanInspectorPane already have.
        #expect(
            pollKey.contains("scenePhase"),
            "the badge poll key must carry the scene phase, or a backgrounded chat window polls forever"
        )
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
