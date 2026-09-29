import Testing
@testable import ScarfCore

/// gh#147: `/title` is a client-side rename; `/retry` and `/undo` are
/// CLI/gateway-only and must never reach the wire.
@Suite struct TitleRetrySlashTests {

    @Test func titleWithNameIsAClientSideRename() {
        #expect(RichChatViewModel.clientSideSlashCommand(for: "/title Trip planning")
                == .renameSession(title: "Trip planning"))
        #expect(RichChatViewModel.clientSideSlashCommand(for: "  /title   -dash first  ")
                == .renameSession(title: "-dash first"))
    }

    @Test func bareTitleCarriesNoName() {
        #expect(RichChatViewModel.clientSideSlashCommand(for: "/title") == .renameSession(title: nil))
        #expect(RichChatViewModel.clientSideSlashCommand(for: "/title    ") == .renameSession(title: nil))
    }

    @Test func titlePrefixedNamesAreNotIntercepted() {
        #expect(RichChatViewModel.clientSideSlashCommand(for: "/titles x") == nil)
        #expect(RichChatViewModel.clientSideSlashCommand(for: "title x") == nil)
    }

    @Test(arguments: ["retry", "undo"])
    func cliOnlyNamesAreInterceptedWithANotice(name: String) throws {
        #expect(RichChatViewModel.clientSideSlashCommand(for: "/\(name)") == .cliOnly(name: name))
        #expect(RichChatViewModel.clientSideSlashCommand(for: "/\(name) please") == .cliOnly(name: name))
        let notice = try #require(RichChatViewModel.cliOnlySlashNotice(name: name))
        #expect(notice.contains("/\(name)"))
        #expect(notice.contains("Hermes CLI"))
    }

    @Test func cliOnlyNoticeIsNilForOtherNames() {
        #expect(RichChatViewModel.cliOnlySlashNotice(name: "title") == nil)
        #expect(RichChatViewModel.cliOnlySlashNotice(name: "goal") == nil)
    }

    /// Offered on every host (rename exists at every tagged Hermes, so no
    /// capability flag), greyed pre-session, and `retry`/`undo` are never
    /// listed.
    @Test func menuOffersTitleButNotRetryOrUndo() {
        let hosts = [
            HermesCapabilities.empty,
            HermesCapabilities.parseLine("Hermes Agent v0.6.0 (2026.3.30)"),
            HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        ]
        for caps in hosts {
            let roster = RichChatViewModel.alwaysAvailableCommands(capabilities: caps)
            let title = roster.first { $0.name == "title" }
            #expect(title?.argumentHint == "<name>", "\(caps.versionLine)")
            #expect(!roster.contains { $0.name == "retry" || $0.name == "undo" })
        }
        #expect(RichChatViewModel.sessionRequiredCommandNames.contains("title"))
    }

    @Test func titleHintsNameTheTitle() {
        #expect(RichChatViewModel.titlePendingNotice("X").contains("X"))
        #expect(RichChatViewModel.titleAppliedNotice("X").contains("X"))
        #expect(RichChatViewModel.titleUsageNotice.contains("/title"))
    }
}
