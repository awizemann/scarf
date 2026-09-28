import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Blind re-audit B09 — Mac halves of S15-F2, S15-F3 and S15-F5.
@Suite struct BlindB09MacTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/scarfTests
            .deletingLastPathComponent()   // …/scarf
            .deletingLastPathComponent()   // repo root
    }

    // MARK: - S15-F2: no hint sends the user to an Edit that doesn't exist

    @Test func diagnosticsHintsNeverPointAtEdit() {
        for probe in RemoteDiagnosticsViewModel.ProbeID.allCases {
            let hint = probe.failureHint ?? ""
            #expect(!hint.contains("→ Edit"), "\(probe.rawValue): \(hint)")
        }
        let dirHint = RemoteDiagnosticsViewModel.ProbeID.hermesDirExists.failureHint ?? ""
        #expect(dirHint.contains("add it again"))
        #expect(dirHint.contains("Hermes data directory"))   // the Add Server field's label
        #expect((RemoteDiagnosticsViewModel.ProbeID.hermesBinaryLogin.failureHint ?? "")
            .contains("Advanced → Hermes binary"))
    }

    // MARK: - S15-F3: Remove Server never runs `ssh -O exit` on the main actor

    @Test func removeServerClosesTheMasterOffMain() throws {
        let src = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("scarf/scarf/Core/Persistence/ServerRegistry.swift"),
            encoding: .utf8)
        let body = try #require(src.range(of: "func removeServer(").map { String(src[$0.lowerBound...]) })
            .components(separatedBy: "\n    // MARK:").first ?? ""
        let calls = body.components(separatedBy: "\n")
            .filter { $0.contains("closeControlMaster()") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(calls.count == 1)
        #expect(calls.allSatisfy { $0.contains("OffPool.run") })
    }

    // MARK: - S15-F5: the env probe uses the user's shell

    @Test func loginShellPrefersTheAccountShellWhenSupported() {
        let all: (String) -> Bool = { _ in true }
        #expect(HermesFileService.loginShell(account: "/bin/bash", environment: "/bin/zsh", isExecutable: all)
                == "/bin/bash")
        #expect(HermesFileService.loginShell(account: "/opt/homebrew/bin/fish", environment: nil, isExecutable: all)
                == "/opt/homebrew/bin/fish")
        // Unsupported account shell → `$SHELL`, then zsh.
        #expect(HermesFileService.loginShell(account: "/bin/tcsh", environment: "/bin/bash", isExecutable: all)
                == "/bin/bash")
        #expect(HermesFileService.loginShell(account: "/bin/tcsh", environment: "/bin/csh", isExecutable: all)
                == "/bin/zsh")
        // A shell that isn't there is skipped.
        #expect(HermesFileService.loginShell(account: "/nix/bin/bash", environment: nil, isExecutable: { _ in false })
                == "/bin/zsh")
        #expect(HermesFileService.loginShell(account: nil, environment: nil) == "/bin/zsh")
    }

    /// The probe script runs in bash too (it is the shape the harvest uses).
    @Test func probeScriptWorksUnderBash() throws {
        let script = #"printf '%s\0%s\0' "SCARF_B09" "yes"; printf '%s\0%s\0' "PATH" "$PATH""#
        let result = try #require(
            HermesFileService.runShellProbe(script: script, interactive: false, timeout: 20, shell: "/bin/bash"))
        #expect(result["SCARF_B09"] == "yes")
        #expect(result["PATH"]?.isEmpty == false)
    }

    /// A hermes that only exists on the harvested PATH (Nix, a dev venv).
    @Test func hermesIsFoundOnAGivenPATH() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b09-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("hermes")
        try "#!/bin/sh\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        #expect(HermesFileService.executable(named: "hermes", onPATH: "/nonexistent:\(dir.path)") == bin.path)
        #expect(HermesFileService.executable(named: "hermes", onPATH: "relative/dir") == nil)
        #expect(HermesFileService.executable(named: "hermes", onPATH: nil) == nil)
    }
}
