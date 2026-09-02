import Testing
import Foundation
@testable import ScarfCore

/// F2 / t-e96cc0ad: untrusted text at the argv and shell boundaries.
@Suite struct UntrustedArgvGuardTests {

    @Test("a task title that opens with a dash is a positional, not a flag")
    func createTitleSitsBehindEndOfOptions() {
        let argv = KanbanCreateRequest(title: "--force is ignored").argv()
        #expect(argv.last == "--force is ignored")
        // `--` immediately precedes the title, and nothing follows the title.
        #expect(argv[argv.count - 2] == "--")
        // Every flag is still ahead of the marker, so argparse can see it.
        #expect(argv.firstIndex(of: "--json")! < argv.firstIndex(of: "--")!)
    }

    @Test("the end-of-options marker appears exactly once")
    func endOfOptionsIsNotDuplicated() {
        let argv = KanbanCreateRequest(
            title: "t",
            body: "b",
            assignee: "a",
            skills: ["s"]
        ).argv()
        #expect(argv.filter { $0 == "--" }.count == 1)
    }
}

/// The roster scan hands the remote's directory names to `printf`, and the
/// parser trusts the record framing it prints. A profile directory whose
/// NAME carries a tab or newline could otherwise forge whole rows — most
/// damagingly a second `Y` row for `default`, overwriting the default
/// bot's identity with attacker-supplied YAML.
@Suite struct BotsRosterScanNameGuardTests {

    private var script: String {
        BotsRosterScan.script(rootHome: "/tmp/scarf-roster-test", maxYAMLBytes: 65_536)
    }

    @Test("the script validates the profile id before it reaches printf")
    func scriptGuardsTheNameShellSide() {
        // The `case` guard must sit between the `n` capture and the first
        // printf — a Swift-side filter cannot undo a forged extra LINE.
        let s = script
        let guardIdx = s.range(of: "*[!a-z0-9_-]*)")
        let printfIdx = s.range(of: "printf 'Y")
        #expect(guardIdx != nil)
        #expect(printfIdx != nil)
        if let g = guardIdx, let p = printfIdx {
            #expect(g.lowerBound < p.lowerBound)
        }
        #expect(s.contains("${#n}"))
    }

    @Test("the shell guard is no narrower than the Swift addressability filter")
    func guardMatchesIsValidName() {
        // If the shell rejected something Swift accepts, the batched and
        // per-file scans would disagree — the parity contract this scan
        // exists to honour.
        for name in ["default", "work", "a", "a-b_c", "team-2026", String(repeating: "z", count: 64)] {
            #expect(HermesProfileScope.isValidName(name) || name == "default")
            #expect(shellAccepts(name))
        }
        for name in ["-lead", "_lead", "Work", "a b", "a\tb", "évil", String(repeating: "z", count: 65)] {
            #expect(!HermesProfileScope.isValidName(name))
        }
    }

    /// Mirror of the `case` guard, so the expectations above state the rule
    /// rather than re-reading the script text.
    private func shellAccepts(_ n: String) -> Bool {
        guard let first = n.first, n.count <= 64 else { return false }
        guard first != "-" && first != "_" else { return false }
        return n.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
