import AppKit
import ScarfCore

// MARK: - Which chats are working

extension ChatSession {
    /// Closing this chat now would lose work the user is waiting on: a turn
    /// in flight, an approval or question waiting for an answer, or sends
    /// held for a client, or a start still carrying a typed message or
    /// kickoff prompt. An idle live chat, a released one and a blank one lose
    /// nothing: their sessions reopen from the list.
    var isWorking: Bool {
        hasTurnInFlight || !richChatViewModel.permissionQueue.isEmpty || hasHeldSends || startHoldsUserInput
    }
}

extension ChatViewModel {
    /// The chats a close or quit has to ask about.
    var workingChats: [ChatSession] {
        chats.filter { $0.isWorking || ($0 === focusedChat && ownerIsWorking?() == true) }
    }
}

// MARK: - The confirm

/// What closing a window, switching its profile or quitting Scarf says when
/// chats are still working (parallel chats P2, design §6). Plain values, so
/// the decision and its copy are tested without AppKit: `nil` means there is
/// nothing to ask, and the action goes ahead.
enum ChatClosePolicy {
    struct Prompt: Equatable {
        let title: String
        let message: String
    }

    /// What's being done to the working chats, for the sentence naming them.
    enum Action {
        case closeWindow
        case switchProfile

        func consequence(_ names: String) -> String {
            switch self {
            case .closeWindow: String(localized: "Closing this window stops \(names).")
            case .switchProfile: String(localized: "Switching profile stops \(names).")
            }
        }

        func kickoffConsequence(_ names: String) -> String {
            switch self {
            case .closeWindow: String(localized: "Closing this window discards the first message waiting for \(names).")
            case .switchProfile: String(localized: "Switching profile discards the first message waiting for \(names).")
            }
        }
    }

    /// The most chats named before the rest become "N more".
    nonisolated static let maxNames = 3
    /// The longest chat name quoted in full.
    nonisolated static let maxNameLength = 40

    /// The confirm for one window, or nil with nothing to lose in it.
    /// `parkedKickoffs` names the first messages waiting for a free chat
    /// (`ChatViewModel.parkedKickoffNames`): they go with the window.
    static func prompt(_ action: Action, workingChatNames names: [String], parkedKickoffs: [String] = []) -> Prompt? {
        guard !names.isEmpty || !parkedKickoffs.isEmpty else { return nil }
        let sentences = (names.isEmpty ? [] : [action.consequence(list(names))])
            + (parkedKickoffs.isEmpty ? [] : [action.kickoffConsequence(list(parkedKickoffs))])
        return Prompt(
            title: names.isEmpty ? kickoffTitle(count: parkedKickoffs.count) : title(chats: names.count),
            message: sentences.joined(separator: " ")
        )
    }

    /// The one confirm across every window (`workingChatNames`: one list per
    /// window), or nil with nothing working anywhere.
    static func quitPrompt(workingChatNames windows: [[String]], parkedKickoffs: [String] = []) -> Prompt? {
        let working = windows.filter { !$0.isEmpty }
        let names = working.flatMap { $0 }
        guard !names.isEmpty || !parkedKickoffs.isEmpty else { return nil }
        let title: String
        if names.isEmpty {
            title = kickoffTitle(count: parkedKickoffs.count)
        } else if working.count == 1 {
            title = Self.title(chats: names.count)
        } else {
            title = String(localized: "\(names.count) chats are still replying in \(working.count) windows")
        }
        var sentences: [String] = []
        if !names.isEmpty { sentences.append(String(localized: "Quitting Scarf stops \(list(names)).")) }
        if !parkedKickoffs.isEmpty {
            sentences.append(String(localized: "Quitting Scarf discards the first message waiting for \(list(parkedKickoffs))."))
        }
        return Prompt(title: title, message: sentences.joined(separator: " "))
    }

    private static func kickoffTitle(count: Int) -> String {
        count == 1
            ? String(localized: "1 first message hasn't been sent")
            : String(localized: "\(count) first messages haven't been sent")
    }

    private static func title(chats count: Int) -> String {
        count == 1
            ? String(localized: "1 chat is still replying")
            : String(localized: "\(count) chats are still replying")
    }

    /// The confirm's alert. Cancel is the Return key's default, so running
    /// work is never lost to one keypress; set outright because AppKit gives
    /// a button titled Cancel no Return key, even first. `confirmResponse` is
    /// what the destructive button answers.
    static func alert(for prompt: Prompt, confirmTitle: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        let confirm = alert.addButton(withTitle: confirmTitle)
        confirm.hasDestructiveAction = true
        confirm.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return alert
    }

    nonisolated static let confirmResponse = NSApplication.ModalResponse.alertSecondButtonReturn

    /// “A”, “B”, and 2 more.
    private static func list(_ names: [String]) -> String {
        var items = names.prefix(maxNames).map { name in
            let short = name.count > maxNameLength ? String(name.prefix(maxNameLength)) + "…" : name
            return "“\(short)”"
        }
        if names.count > maxNames {
            items.append(String(localized: "\(names.count - maxNames) more"))
        }
        return ListFormatter.localizedString(byJoining: items)
    }
}
