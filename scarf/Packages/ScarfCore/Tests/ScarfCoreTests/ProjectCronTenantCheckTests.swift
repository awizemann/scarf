import Testing
import Foundation
@testable import ScarfCore

/// #142 P6: the cockpit's "this cron job's Kanban tasks will be Untagged"
/// heuristic and the prompt it suggests.
@Suite struct ProjectCronTenantCheckTests {
    let tenant = "scarf:demo"

    @Test(arguments: [
        "Every morning run `hermes kanban create \"Triage\"` for new issues.",
        "Use HERMES KANBAN CREATE for each finding.",
        "hermes kanban\n  create \"wrapped\"",
        "Call the kanban_create tool for each failing check.",
    ])
    func flagsKanbanCreationWithoutATenant(prompt: String) {
        #expect(ProjectCronTenantCheck.needsTenant(prompt: prompt, tenant: tenant))
    }

    @Test(arguments: [
        "hermes kanban create --tenant scarf:demo \"Triage\"",
        "hermes kanban create \"x\" --TENANT other",           // some tenant is named
        "Call kanban_create with tenant scarf:demo.",           // the value, in prose
        "Summarise yesterday's commits.",                       // no Kanban at all
        "Run hermes kanban list and report blocked tasks.",     // not creation
        "mykanban create things",                               // not the word
    ])
    func leavesOtherPromptsAlone(prompt: String) {
        #expect(!ProjectCronTenantCheck.needsTenant(prompt: prompt, tenant: tenant))
    }

    @Test func noTenantMeansNoWarning() {
        #expect(!ProjectCronTenantCheck.needsTenant(prompt: "hermes kanban create x", tenant: "  "))
    }

    @Test func suggestionInsertsTheFlagAfterEveryCreate() {
        let prompt = "First `hermes kanban create \"a\"`, then Kanban Create \"b\"."
        let fixed = ProjectCronTenantCheck.suggestedPrompt(prompt: prompt, tenant: tenant)
        #expect(fixed == "First `hermes kanban create --tenant scarf:demo \"a\"`, then Kanban Create --tenant scarf:demo \"b\".")
        #expect(!ProjectCronTenantCheck.needsTenant(prompt: fixed, tenant: tenant))
    }

    @Test func suggestionAppendsAnInstructionForTheToolForm() {
        let prompt = "Call the kanban_create tool for each failing check."
        let fixed = ProjectCronTenantCheck.suggestedPrompt(prompt: prompt, tenant: tenant)
        #expect(fixed == prompt + "\n\n" + ProjectCronTenantCheck.instructionLine(tenant: tenant))
        #expect(fixed.contains("--tenant scarf:demo"))
        #expect(!ProjectCronTenantCheck.needsTenant(prompt: fixed, tenant: tenant))
    }
}
