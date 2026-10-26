import Testing
import Foundation
@testable import ScarfCore

/// Gateway-backed `session/load` moves a session to whatever cwd it is sent
/// (acp_adapter/gateway_server.py `_moved` / `_move_workspace` @ v0.22.5),
/// so a non-project chat reopens in its own `sessions.cwd`, retrying once in
/// the default cwd when the gateway refuses a missing folder
/// (`invalid_params`, gateway/session_mutation_policy.py:46-50).
@Suite struct SessionResumeCwdTests {

    static let home = "/Users/me"
    static let project = "/Users/me/proj"
    static let cliFolder = "/Users/me/code/cli-thing"
    static let missingFolder = ACPClientError.rpcError(code: -32603, message: "Internal error", details: "invalid_params")

    // MARK: - cwd choice

    @Test func nonProjectChatOnGatewayHostUsesItsOwnFolder() {
        #expect(SessionResume.loadCwd(defaultCwd: Self.home, projectPath: nil,
                                      sessionCwd: Self.cliFolder, gatewayBacked: true) == Self.cliFolder)
    }

    @Test func projectChatKeepsTheProjectFolder() {
        #expect(SessionResume.loadCwd(defaultCwd: Self.project, projectPath: Self.project,
                                      sessionCwd: Self.cliFolder, gatewayBacked: true) == Self.project)
    }

    @Test func preGatewayHostsAreUnchanged() {
        #expect(SessionResume.loadCwd(defaultCwd: Self.home, projectPath: nil,
                                      sessionCwd: Self.cliFolder, gatewayBacked: false) == Self.home)
        #expect(SessionResume.loadCwd(defaultCwd: Self.project, projectPath: Self.project,
                                      sessionCwd: Self.cliFolder, gatewayBacked: false) == Self.project)
    }

    @Test func nullEmptyOrRelativeCwdFallsBackToDefault() {
        for cwd in [nil, "", "   ", ".", "relative/path"] as [String?] {
            #expect(SessionResume.loadCwd(defaultCwd: Self.home, projectPath: nil,
                                          sessionCwd: cwd, gatewayBacked: true) == Self.home, "\(String(describing: cwd))")
        }
    }

    // MARK: - load + retry

    /// Records every cwd `load` was called with.
    actor Calls {
        var cwds: [String] = []
        var cwdReads = 0
        func load(_ cwd: String) { cwds.append(cwd) }
        func read() { cwdReads += 1 }
    }

    @Test func gatewayNonProjectLoadsInSessionFolder() async throws {
        let calls = Calls()
        let result = try await SessionResume.loadInSessionFolder(
            defaultCwd: Self.home, projectPath: nil, gatewayBacked: true,
            sessionCwd: { await calls.read(); return Self.cliFolder },
            load: { cwd in await calls.load(cwd); return "ok" })
        #expect(result == "ok")
        #expect(await calls.cwds == [Self.cliFolder])
    }

    @Test func missingFolderRetriesOnceInTheDefaultCwd() async throws {
        let calls = Calls()
        let result = try await SessionResume.loadInSessionFolder(
            defaultCwd: Self.home, projectPath: nil, gatewayBacked: true,
            sessionCwd: { Self.cliFolder },
            load: { cwd in
                await calls.load(cwd)
                if cwd == Self.cliFolder { throw Self.missingFolder }
                return "ok"
            })
        #expect(result == "ok")
        #expect(await calls.cwds == [Self.cliFolder, Self.home])
    }

    @Test func secondMissingFolderPropagatesAndIsNotRestorable() async {
        let calls = Calls()
        do {
            _ = try await SessionResume.loadInSessionFolder(
                defaultCwd: Self.home, projectPath: nil, gatewayBacked: true,
                sessionCwd: { Self.cliFolder },
                load: { cwd -> String in await calls.load(cwd); throw Self.missingFolder })
            Issue.record("expected a throw")
        } catch {
            #expect(SessionResume.isNotRestorable(error, gatewayBacked: true))
        }
        #expect(await calls.cwds == [Self.cliFolder, Self.home])
    }

    @Test func otherErrorsAreNotRetried() async {
        let calls = Calls()
        let other = ACPClientError.rpcError(code: -32603, message: "Internal error", details: "permission_denied")
        do {
            _ = try await SessionResume.loadInSessionFolder(
                defaultCwd: Self.home, projectPath: nil, gatewayBacked: true,
                sessionCwd: { Self.cliFolder },
                load: { cwd -> String in await calls.load(cwd); throw other })
            Issue.record("expected a throw")
        } catch {
            #expect(!SessionResume.isNotRestorable(error, gatewayBacked: true))
        }
        #expect(await calls.cwds == [Self.cliFolder])
    }

    @Test func defaultCwdFailureIsNotRetried() async {
        // NULL cwd → the default is tried once; its refusal isn't retried.
        let calls = Calls()
        await #expect(throws: ACPClientError.self) {
            _ = try await SessionResume.loadInSessionFolder(
                defaultCwd: Self.home, projectPath: nil, gatewayBacked: true,
                sessionCwd: { nil },
                load: { cwd -> String in await calls.load(cwd); throw Self.missingFolder })
        }
        #expect(await calls.cwds == [Self.home])
    }

    @Test func projectAndPreGatewayLoadsNeverReadTheRow() async throws {
        for (project, gateway) in [(Self.project as String?, true), (nil, false), (Self.project, false)] {
            let calls = Calls()
            let defaultCwd = project ?? Self.home
            _ = try await SessionResume.loadInSessionFolder(
                defaultCwd: defaultCwd, projectPath: project, gatewayBacked: gateway,
                sessionCwd: { await calls.read(); return Self.cliFolder },
                load: { cwd in await calls.load(cwd); return "ok" })
            #expect(await calls.cwds == [defaultCwd])
            #expect(await calls.cwdReads == 0)
        }
        // Pre-gateway: a missing-folder error is not retried either.
        let calls = Calls()
        await #expect(throws: ACPClientError.self) {
            _ = try await SessionResume.loadInSessionFolder(
                defaultCwd: Self.home, projectPath: nil, gatewayBacked: false,
                sessionCwd: { Self.cliFolder },
                load: { cwd -> String in await calls.load(cwd); throw Self.missingFolder })
        }
        #expect(await calls.cwds == [Self.home])
    }

    @Test func invalidParamsIsNotRestorableOnlyOnGatewayHosts() {
        #expect(SessionResume.isNotRestorable(Self.missingFolder, gatewayBacked: true))
        #expect(!SessionResume.isNotRestorable(Self.missingFolder))
        #expect(!SessionResume.isNotRestorable(
            ACPClientError.rpcError(code: -32602, message: "Invalid params", details: "invalid_params"),
            gatewayBacked: true))
    }

    @Test func resolveContinuesAsNewWhenBothFoldersAreRefused() async throws {
        let outcome = try await SessionResume.resolve(
            sessionId: "s1", source: "cli", gatewayBacked: true,
            load: { id in
                try await SessionResume.loadInSessionFolder(
                    defaultCwd: Self.home, projectPath: nil, gatewayBacked: true,
                    sessionCwd: { Self.cliFolder },
                    load: { _ -> (String, String?) in throw Self.missingFolder })
            },
            newSession: { "new" })
        #expect(outcome == .continuedAsNew(sessionId: "new", reason: .notRestorable))
    }

    // MARK: - sessions.cwd read

    #if canImport(SQLite3)
    @Test func fetchCwdReadsTheColumnAndToleratesNullAndAbsence() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: """
            INSERT INTO sessions (id, source, started_at, cwd) VALUES ('a', 'cli', 1, '/srv/work'),
                                                                     ('b', 'cli', 2, NULL);
            """)
        defer { try? FileManager.default.removeItem(at: home) }
        let ctx = ServerContext.local(home: home)
        #expect(await SessionResume.fetchCwd(context: ctx, sessionId: "a") == "/srv/work")
        #expect(await SessionResume.fetchCwd(context: ctx, sessionId: "b") == nil)
        #expect(await SessionResume.fetchCwd(context: ctx, sessionId: "missing") == nil)

        // A schema without `sessions.cwd`: nil, no error.
        let old = try HermesV0215R18bTests.makeHome(schema: """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, started_at REAL NOT NULL);
            """, seed: """
            INSERT INTO sessions (id, source, started_at) VALUES ('a', 'cli', 1);
            """)
        defer { try? FileManager.default.removeItem(at: old) }
        #expect(await SessionResume.fetchCwd(context: .local(home: old), sessionId: "a") == nil)
    }
    #endif
}
