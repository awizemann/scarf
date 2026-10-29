import Foundation
import ScarfCore

/// How many chats may hold a `hermes acp` process at once, per SSH
/// ControlMaster, across every window (parallel chats P1, design §4).
///
/// Each live remote chat holds one channel on its host's shared master,
/// beside log tails and query bursts. OpenSSH allows 10 channels per
/// connection by default; past that, ssh quietly opens a new, fully
/// authenticated connection — the gh#138 side effects (browser tabs,
/// hardware-key touches). Hence 4 per remote master; 8 locally, where the
/// cost is only memory.
///
/// Keyed by the master (`ControlMasterKey`), not by server: two entries for
/// the same `user@host:port` share one. Members are weak; the live count is
/// computed on demand from each chat's own state (`holdsProcess`), so there
/// is no counter to drift. Bot Chat (`ChatViewModel.Mode.single`) never
/// registers. Injectable: tests build their own (every test context is
/// `.local`).
///
/// Not counted, deliberately: Bot Chat's chat, and the embedded terminal's
/// `hermes` process (terminal mode) — both one per window at most. And a
/// released chat costs only its in-memory transcript; on re-attach the
/// transcript is reloaded from state.db by the full start path, so what it
/// shows is what Hermes stored, not the copy kept meanwhile.
@MainActor
final class LiveChatBudget {
    static let shared = LiveChatBudget()

    private let localLimit: Int
    private let remoteLimit: Int

    init(localLimit: Int = 8, remoteLimit: Int = 4) {
        self.localLimit = localLimit
        self.remoteLimit = remoteLimit
    }

    func limit(for key: ControlMasterKey) -> Int {
        key.isRemote ? remoteLimit : localLimit
    }

    private struct Member {
        weak var chat: ChatSession?
    }

    private var members: [ControlMasterKey: [Member]] = [:]

    /// Count `chat` from now on (idempotent).
    func register(_ chat: ChatSession) {
        let key = ControlMasterKey.of(chat.context)
        prune(key)
        guard !(members[key] ?? []).contains(where: { $0.chat === chat }) else { return }
        members[key, default: []].append(Member(chat: chat))
    }

    /// The chats on `key` that still belong to a window. A chat whose
    /// window is gone has nothing that can reach it, and its process was
    /// stopped with the window (`ChatViewModel.leaveChat`).
    func chats(on key: ControlMasterKey) -> [ChatSession] {
        prune(key)
        return (members[key] ?? []).compactMap(\.chat).filter { $0.host != nil }
    }

    /// Chats holding a process on `key` right now.
    func liveCount(on key: ControlMasterKey) -> Int {
        chats(on: key).filter(\.holdsProcess).count
    }

    enum Admission {
        case granted
        /// Every slot is taken by a chat that can't be released: these
        /// (working, or shown in a window).
        case full(working: [ChatSession])
    }

    /// May a chat on `key` spawn a process? `excluding` is the chat about to
    /// spawn (or restart in place): its own slot doesn't count against it.
    /// `leaving` is a chat its window is about to move off, so it is no
    /// longer "shown" — idle, it may be released.
    ///
    /// Full: release the least recently used idle chat (`releaseProcess`;
    /// its transcript stays, it re-attaches when focused). Nothing idle:
    /// `.full`, and the caller asks the user.
    func admit(on key: ControlMasterKey, excluding: ChatSession?, leaving: ChatSession? = nil) -> Admission {
        let others = chats(on: key).filter { $0 !== excluding && $0.holdsProcess }
        let excess = others.count - limit(for: key) + 1
        guard excess > 0 else { return .granted }
        let releasable = others
            .filter { !$0.isBusyForBudget && (!$0.isShownInWindow || $0 === leaving) }
            .sorted { $0.lastUsedAt < $1.lastUsedAt }
        guard releasable.count >= excess else {
            return .full(working: others.filter { chat in !releasable.contains { $0 === chat } })
        }
        for chat in releasable.prefix(excess) {
            chat.releaseProcess()
        }
        return .granted
    }

    /// `admit` for `chat` itself, on its own master.
    func admit(_ chat: ChatSession) -> Admission {
        register(chat)
        return admit(on: ControlMasterKey.of(chat.context), excluding: chat)
    }

    private func prune(_ key: ControlMasterKey) {
        members[key]?.removeAll { $0.chat == nil }
    }
}
