import Testing
import Foundation
@testable import ScarfCore

/// Unit coverage for ScarfGo per-connection profile scoping (issue #120,
/// Design B): the pure `HermesProfileScope` resolver and the
/// `InMemoryProfileSelectionStore` protocol behavior. Both are Linux-safe
/// (no Apple-only deps), so they run on ScarfCore's CI.
@Suite struct HermesProfileScopeTests {

    // MARK: - resolveHome

    @Test func defaultSelectionReturnsBaseUnchanged() {
        #expect(HermesProfileScope.resolveHome(baseHome: "~/.hermes", profile: nil) == "~/.hermes")
        #expect(HermesProfileScope.resolveHome(baseHome: "~/.hermes", profile: "") == "~/.hermes")
        #expect(HermesProfileScope.resolveHome(baseHome: "~/.hermes", profile: "   ") == "~/.hermes")
        #expect(HermesProfileScope.resolveHome(baseHome: "~/.hermes", profile: "default") == "~/.hermes")
    }

    @Test func namedProfileAppendsProfilesPath() {
        #expect(HermesProfileScope.resolveHome(baseHome: "~/.hermes", profile: "gateway")
                == "~/.hermes/profiles/gateway")
        #expect(HermesProfileScope.resolveHome(baseHome: "~/.hermes", profile: "admin")
                == "~/.hermes/profiles/admin")
    }

    @Test func customRootIsHonored() {
        // Docker / custom HERMES_HOME layout: profiles live under <root>/profiles.
        #expect(HermesProfileScope.resolveHome(baseHome: "/opt/data", profile: "coder")
                == "/opt/data/profiles/coder")
        #expect(HermesProfileScope.resolveHome(baseHome: "/home/deploy/.hermes", profile: "ci")
                == "/home/deploy/.hermes/profiles/ci")
    }

    @Test func trailingSlashesTrimmed() {
        #expect(HermesProfileScope.resolveHome(baseHome: "~/.hermes/", profile: "gateway")
                == "~/.hermes/profiles/gateway")
        #expect(HermesProfileScope.resolveHome(baseHome: "~/.hermes///", profile: nil) == "~/.hermes")
        // A lone slash is preserved (degenerate but must not crash / become empty)
        // and must not produce a double slash when a profile is appended.
        #expect(HermesProfileScope.resolveHome(baseHome: "/", profile: nil) == "/")
        #expect(HermesProfileScope.resolveHome(baseHome: "/", profile: "x") == "/profiles/x")
    }

    @Test func whitespaceAroundNameTrimmed() {
        #expect(HermesProfileScope.resolveHome(baseHome: "~/.hermes", profile: "  gateway  ")
                == "~/.hermes/profiles/gateway")
    }

    /// The security-critical case: a malformed name must NEVER produce a
    /// path outside `<base>/profiles/<valid-name>`. Anything that fails
    /// Hermes's own id regex fails safe to the base (default profile).
    @Test func invalidNamesFailSafeToBase() {
        let bad = [
            "../etc",            // path traversal
            "foo/bar",           // embedded slash
            "..",                // parent ref
            "Gateway",           // uppercase
            "a b",               // space
            "-leading",          // leading dash
            "a;rm -rf /",        // shell metacharacters
            "$(whoami)",         // command substitution
            "a.b",               // dot
            String(repeating: "a", count: 65), // too long (>64)
        ]
        for name in bad {
            #expect(HermesProfileScope.resolveHome(baseHome: "~/.hermes", profile: name) == "~/.hermes",
                    "expected fail-safe to base for invalid name \(name.debugDescription)")
        }
    }

    // MARK: - isValidName

    @Test func validNamesAccepted() {
        #expect(HermesProfileScope.isValidName("gateway"))
        #expect(HermesProfileScope.isValidName("a"))
        #expect(HermesProfileScope.isValidName("a1_b-c"))
        #expect(HermesProfileScope.isValidName("1abc"))                       // leading digit is allowed
        #expect(HermesProfileScope.isValidName(String(repeating: "a", count: 64)))
    }

    @Test func invalidNamesRejected() {
        #expect(!HermesProfileScope.isValidName(""))
        #expect(!HermesProfileScope.isValidName("A"))
        #expect(!HermesProfileScope.isValidName("-x"))
        #expect(!HermesProfileScope.isValidName("a/b"))
        #expect(!HermesProfileScope.isValidName(String(repeating: "a", count: 65)))
    }

    // MARK: - normalize

    @Test func normalizeMapsDefaultsAndInvalidToNil() {
        #expect(HermesProfileScope.normalize(nil) == nil)
        #expect(HermesProfileScope.normalize("") == nil)
        #expect(HermesProfileScope.normalize("default") == nil)
        #expect(HermesProfileScope.normalize("  default  ") == nil)
        #expect(HermesProfileScope.normalize("Bad Name") == nil)
        #expect(HermesProfileScope.normalize("../x") == nil)
        #expect(HermesProfileScope.normalize("gateway") == "gateway")
        #expect(HermesProfileScope.normalize("  gateway  ") == "gateway")
    }

    // MARK: - isProfileHome

    @Test func isProfileHomeDetectsNamedProfileDirs() {
        #expect(HermesProfileScope.isProfileHome("~/.hermes/profiles/gateway"))
        #expect(HermesProfileScope.isProfileHome("/opt/data/profiles/coder"))
        #expect(HermesProfileScope.isProfileHome("/home/deploy/.hermes/profiles/ci/"))  // trailing slash
    }

    @Test func isProfileHomeRejectsRootHomes() {
        #expect(!HermesProfileScope.isProfileHome("~/.hermes"))
        #expect(!HermesProfileScope.isProfileHome("/opt/data"))
        #expect(!HermesProfileScope.isProfileHome("/"))
        #expect(!HermesProfileScope.isProfileHome(""))
        // "profiles" must be the IMMEDIATE parent of a NAME, not the last
        // component itself (a bare `<root>/profiles` has no profile name).
        #expect(!HermesProfileScope.isProfileHome("~/profiles"))
        #expect(!HermesProfileScope.isProfileHome("~/.hermes/profiles"))
        // Nested below a profile is not itself a profile home.
        #expect(!HermesProfileScope.isProfileHome("~/.hermes/profiles/gw/sub"))
    }

    // MARK: - rootHome

    @Test func rootHomeStripsProfileSuffix() {
        #expect(HermesProfileScope.rootHome(forHome: "~/.hermes/profiles/gateway") == "~/.hermes")
        #expect(HermesProfileScope.rootHome(forHome: "/opt/data/profiles/coder") == "/opt/data")
        #expect(HermesProfileScope.rootHome(forHome: "~/.hermes/profiles/ci/") == "~/.hermes")
    }

    @Test func rootHomeReturnsRootHomesUnchanged() {
        #expect(HermesProfileScope.rootHome(forHome: "~/.hermes") == "~/.hermes")
        #expect(HermesProfileScope.rootHome(forHome: "/opt/data") == "/opt/data")
        #expect(HermesProfileScope.rootHome(forHome: "/") == "/")
        // Deeply nested NON-profile home passes through unchanged.
        #expect(HermesProfileScope.rootHome(forHome: "/a/b/c/.hermes") == "/a/b/c/.hermes")
        // A bare <root>/profiles (no name) is not a profile home → unchanged.
        #expect(HermesProfileScope.rootHome(forHome: "~/.hermes/profiles") == "~/.hermes/profiles")
    }

    @Test func rootHomeHandlesFilesystemRootProfile() {
        // Degenerate root "/": "/profiles/<name>" → "/" (not empty).
        #expect(HermesProfileScope.rootHome(forHome: "/profiles/gw") == "/")
    }

    // MARK: - profileName

    @Test func profileNameExtractsNamedProfile() {
        #expect(HermesProfileScope.profileName(forHome: "~/.hermes/profiles/gateway") == "gateway")
        #expect(HermesProfileScope.profileName(forHome: "/opt/data/profiles/coder") == "coder")  // Docker root
        #expect(HermesProfileScope.profileName(forHome: "/home/deploy/.hermes/profiles/ci/") == "ci")  // trailing slash
        #expect(HermesProfileScope.profileName(forHome: "a1_b-c") == nil)  // bare name, not a profile home
    }

    @Test func profileNameReturnsNilForRootHomes() {
        #expect(HermesProfileScope.profileName(forHome: "~/.hermes") == nil)
        #expect(HermesProfileScope.profileName(forHome: "/opt/data") == nil)
        #expect(HermesProfileScope.profileName(forHome: "/") == nil)
        #expect(HermesProfileScope.profileName(forHome: "") == nil)
        // A bare `<root>/profiles` (no name) is not a profile home.
        #expect(HermesProfileScope.profileName(forHome: "~/.hermes/profiles") == nil)
        // Nested below a profile is not itself a profile home.
        #expect(HermesProfileScope.profileName(forHome: "~/.hermes/profiles/gw/sub") == nil)
    }

    /// Defense-in-depth: a profile home whose trailing component fails
    /// Hermes's id regex fails safe to nil (default) rather than producing
    /// an unsafe key component — even though real profile names are always
    /// validated upstream, the extractor must not trust the path blindly.
    @Test func profileNameFailsSafeOnInvalidTrailingComponent() {
        #expect(HermesProfileScope.profileName(forHome: "~/.hermes/profiles/UPPER") == nil)
        #expect(HermesProfileScope.profileName(forHome: "~/.hermes/profiles/-leading") == nil)
        #expect(HermesProfileScope.profileName(forHome: "~/.hermes/profiles/a.b") == nil)
    }

    /// `resolveHome` then `profileName` round-trips back to the selection —
    /// the inverse property the skills-snapshot key relies on to derive the
    /// active profile from an already-scoped `HermesPathSet.home`.
    @Test func resolveThenProfileNameIsIdentity() {
        let base = "~/.hermes"
        #expect(HermesProfileScope.profileName(
            forHome: HermesProfileScope.resolveHome(baseHome: base, profile: "gateway")) == "gateway")
        #expect(HermesProfileScope.profileName(
            forHome: HermesProfileScope.resolveHome(baseHome: base, profile: nil)) == nil)
        #expect(HermesProfileScope.profileName(
            forHome: HermesProfileScope.resolveHome(baseHome: "/opt/data", profile: "admin")) == "admin")
    }

    /// `resolveHome` then `rootHome` round-trips back to the base for both
    /// named and default selections — the property the Profiles UI relies on
    /// to read the root-only `active_profile` file while scoped to a profile.
    @Test func resolveThenRootIsIdentity() {
        let base = "~/.hermes"
        #expect(HermesProfileScope.rootHome(
            forHome: HermesProfileScope.resolveHome(baseHome: base, profile: "gateway")) == base)
        #expect(HermesProfileScope.rootHome(
            forHome: HermesProfileScope.resolveHome(baseHome: base, profile: nil)) == base)
    }

    // MARK: - hermesHomeShellAssignment

    @Test func shellAssignmentScopesNamedProfileWithExpandableTilde() {
        // Named profile under a tilde root → ~ rewritten to $HOME, quoted.
        #expect(HermesProfileScope.hermesHomeShellAssignment(forHome: "~/.hermes/profiles/gateway")
                == "HERMES_HOME=\"$HOME/.hermes/profiles/gateway\" ")
    }

    @Test func shellAssignmentScopesAbsoluteProfileHomeSingleQuoted() {
        // Absolute paths are single-quoted → fully inert (no expansion).
        #expect(HermesProfileScope.hermesHomeShellAssignment(forHome: "/opt/data/profiles/coder")
                == "HERMES_HOME='/opt/data/profiles/coder' ")
    }

    /// Defense-in-depth: even though the profile-name half is regex-validated
    /// and the base is the user's own config, a base with shell metacharacters
    /// must be neutralized — `$HOME` still expands, nothing else does.
    @Test func shellAssignmentNeutralizesMetacharactersInTildeBase() {
        let out = HermesProfileScope.hermesHomeShellAssignment(forHome: "~/h$(touch x)`id`\"q\"/profiles/gw")
        // $ , backtick and " are backslash-escaped inside the double quotes;
        // the leading $HOME is preserved for expansion.
        #expect(out == "HERMES_HOME=\"$HOME/h\\$(touch x)\\`id\\`\\\"q\\\"/profiles/gw\" ")
        #expect(out.hasPrefix("HERMES_HOME=\"$HOME/"))
        #expect(out.contains("\\$("))               // the `$` is escaped → substitution inert
        #expect(out.contains("\\`id\\`"))           // backticks escaped
    }

    @Test func shellAssignmentSingleQuotesNeutralizeAbsoluteMetacharacters() {
        // A single-quoted absolute path with an embedded quote stays inert
        // via the classic '\'' close-escape-reopen idiom.
        let out = HermesProfileScope.hermesHomeShellAssignment(forHome: "/o'pt/profiles/x")
        #expect(out == "HERMES_HOME='/o'\\''pt/profiles/x' ")
    }

    @Test func shellAssignmentIsEmptyForTheStandardRoot() {
        // The standard root → no assignment, so a host that exports its own
        // HERMES_HOME keeps it; `-p default` does the pinning.
        #expect(HermesProfileScope.hermesHomeShellAssignment(forHome: "~/.hermes") == "")
        #expect(HermesProfileScope.hermesHomeShellAssignment(forHome: "~/.hermes/") == "")
        #expect(HermesProfileScope.hermesHomeShellAssignment(forHome: "$HOME/.hermes") == "")
        #expect(HermesProfileScope.hermesHomeShellAssignment(forHome: "") == "")
    }

    /// T6-F1: a custom root is named, so `-p default` resolves to it
    /// (`hermes_cli/profiles.py:2345-2369` @ v2026.9.24) rather than to the
    /// SSH user's own `~/.hermes`. This used to assert `""` for `/opt/data`.
    @Test func shellAssignmentNamesACustomRoot() {
        #expect(HermesProfileScope.hermesHomeShellAssignment(forHome: "/opt/data")
                == "HERMES_HOME='/opt/data' ")
        #expect(HermesProfileScope.hermesHomeShellAssignment(forHome: "/home/hermes/.hermes/")
                == "HERMES_HOME='/home/hermes/.hermes' ")
        #expect(HermesProfileScope.hermesHomeShellAssignment(forHome: "~/hermes-data")
                == "HERMES_HOME=\"$HOME/hermes-data\" ")
        // Still paired with the root pin: the assignment alone would follow
        // the custom root's active_profile.
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "hermes", args: ["config", "path"], home: "/opt/data")
                == ["-p", "default", "config", "path"])
    }

    /// The full round-trip the process layer relies on: resolve a selection
    /// to a home, then derive the shell scope. Default stays unscoped; a
    /// named profile scopes to its dir.
    @Test func resolveThenAssignRoundTrip() {
        let base = "~/.hermes"
        #expect(HermesProfileScope.hermesHomeShellAssignment(
            forHome: HermesProfileScope.resolveHome(baseHome: base, profile: nil)) == "")
        #expect(HermesProfileScope.hermesHomeShellAssignment(
            forHome: HermesProfileScope.resolveHome(baseHome: base, profile: "gateway"))
                == "HERMES_HOME=\"$HOME/.hermes/profiles/gateway\" ")
    }

    // MARK: - InMemoryProfileSelectionStore

    @Test func inMemoryStoreRoundTripAndIsolation() {
        let store = InMemoryProfileSelectionStore()
        let a = ServerID()
        let b = ServerID()

        #expect(store.selectedProfile(for: a) == nil)          // absent → default

        store.setSelectedProfile("admin", for: a)
        store.setSelectedProfile("gateway", for: b)
        #expect(store.selectedProfile(for: a) == "admin")
        #expect(store.selectedProfile(for: b) == "gateway")    // per-server isolation

        store.setSelectedProfile(nil, for: a)
        #expect(store.selectedProfile(for: a) == nil)          // clear → default
        #expect(store.selectedProfile(for: b) == "gateway")    // unaffected
    }

    @Test func inMemoryStoreNormalizesOnWriteAndRead() {
        let store = InMemoryProfileSelectionStore()
        let id = ServerID()
        store.setSelectedProfile("default", for: id)           // sentinel → default
        #expect(store.selectedProfile(for: id) == nil)
        store.setSelectedProfile("Bad Name", for: id)          // invalid → default
        #expect(store.selectedProfile(for: id) == nil)
        store.setSelectedProfile("  gateway ", for: id)        // trimmed
        #expect(store.selectedProfile(for: id) == "gateway")
        store.setSelectedProfile("../escape", for: id)         // invalid while active → clears
        #expect(store.selectedProfile(for: id) == nil)
    }

    // MARK: - End-to-end: profile-scoped remoteHome drives every path (B1)

    /// The mechanism ScarfGo's TabRoot relies on (#120 Phase B1): setting a
    /// server context's `remoteHome` to the resolved profile home makes
    /// EVERY derived `HermesPathSet` path (state.db, memories, sessions,
    /// cron, gateway_state, scarf/) follow the profile — which is what
    /// re-scopes the dashboard, memory, cron, sessions, and gateway
    /// surfaces. Exercised with the real `ServerContext`/`HermesPathSet`.
    @Test func profileScopedRemoteHomeDrivesAllDerivedPaths() {
        let scoped = HermesProfileScope.resolveHome(baseHome: "~/.hermes", profile: "gateway")
        let ctx = ServerContext(
            id: ServerID(),
            displayName: "Test",
            kind: .ssh(SSHConfig(host: "example", remoteHome: scoped))
        )
        let p = ctx.paths
        #expect(p.home == "~/.hermes/profiles/gateway")
        #expect(p.stateDB == "~/.hermes/profiles/gateway/state.db")
        #expect(p.memoriesDir == "~/.hermes/profiles/gateway/memories")
        #expect(p.sessionsDir == "~/.hermes/profiles/gateway/sessions")
        #expect(p.cronJobsJSON == "~/.hermes/profiles/gateway/cron/jobs.json")
        #expect(p.gatewayStateJSON == "~/.hermes/profiles/gateway/gateway_state.json")
        #expect(p.scarfDir == "~/.hermes/profiles/gateway/scarf")
    }

    @Test func defaultProfileLeavesContextPathsAtRoot() {
        let scoped = HermesProfileScope.resolveHome(baseHome: "~/.hermes", profile: nil)
        let ctx = ServerContext(
            id: ServerID(),
            displayName: "Test",
            kind: .ssh(SSHConfig(host: "example", remoteHome: scoped))
        )
        #expect(ctx.paths.home == "~/.hermes")
        #expect(ctx.paths.stateDB == "~/.hermes/state.db")
        #expect(ctx.paths.memoriesDir == "~/.hermes/memories")
    }
    // MARK: - Process-layer pinning (S13-F1 / S13-F2)

    @Test func profileFlagAlwaysEmitsAFlag() {
        #expect(HermesProfileScope.profileFlag("scout") == ["-p", "scout"])
        #expect(HermesProfileScope.profileFlag(" scout ") == ["-p", "scout"])
        #expect(HermesProfileScope.profileFlag("default") == ["-p", "default"])
        #expect(HermesProfileScope.profileFlag(nil) == ["-p", "default"])
        #expect(HermesProfileScope.profileFlag("") == ["-p", "default"])
    }

    @Test func rootHomeHermesArgvGetsDefaultPin() {
        for home in ["~/.hermes", "/opt/data", "/root/.hermes/", "~"] {
            #expect(HermesProfileScope.pinnedRemoteArguments(
                executable: "hermes", args: ["cron", "list"], home: home)
                == ["-p", "default", "cron", "list"], "\(home)")
        }
        // Full path whose last component is hermes.
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "~/.local/bin/hermes", args: ["acp"], home: "~/.hermes")
            == ["-p", "default", "acp"])
        // A configured binary hint with another name counts as hermes too.
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "/usr/local/bin/hermes-wrapper", args: ["acp"], home: "~/.hermes",
            configuredBinary: "/usr/local/bin/hermes-wrapper")
            == ["-p", "default", "acp"])
    }

    @Test func pinIsSkippedWhereItDoesNotBelong() {
        // Named-profile home: HERMES_HOME already pins it.
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "hermes", args: ["acp"], home: "~/.hermes/profiles/work") == ["acp"])
        // Not hermes.
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "/bin/sh", args: ["-c", "hermes acp"], home: "~/.hermes") == ["-c", "hermes acp"])
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "/usr/bin/hermes-agent", args: ["acp"], home: "~/.hermes") == ["acp"])
        // Already pinned by the caller (a bot) — never a second flag.
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "hermes", args: ["-p", "scout", "acp"], home: "~/.hermes") == ["-p", "scout", "acp"])
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "hermes", args: ["--profile", "scout", "acp"], home: "~/.hermes")
            == ["--profile", "scout", "acp"])
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "hermes", args: ["--profile=scout", "acp"], home: "~/.hermes") == ["--profile=scout", "acp"])
        // Bare version probes keep Hermes' fast path.
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "hermes", args: ["--version"], home: "~/.hermes") == ["--version"])
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "hermes", args: ["-V"], home: "~/.hermes") == ["-V"])
    }

    /// The remote OAuth / MCP login / Nous flows run
    /// `env PYTHONUNBUFFERED=1 <hermes> …`; the pin must land after the
    /// hermes token, with every skip rule still applying.
    @Test func envWrappedHermesGetsThePinAfterTheHermesToken() {
        let root = "~/.hermes"
        // NousAuthFlow shape.
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "env", args: ["PYTHONUNBUFFERED=1", "hermes", "auth", "add", "nous", "--no-browser"],
            home: root)
            == ["PYTHONUNBUFFERED=1", "hermes", "-p", "default", "auth", "add", "nous", "--no-browser"])
        // OAuthFlowController / MCPLoginController shape, with a path and
        // several assignments, via /usr/bin/env.
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "/usr/bin/env", args: ["PYTHONUNBUFFERED=1", "A_B=x=y", "~/.local/bin/hermes", "mcp", "login", "srv"],
            home: "/opt/data")
            == ["PYTHONUNBUFFERED=1", "A_B=x=y", "~/.local/bin/hermes", "-p", "default", "mcp", "login", "srv"])
        // A wrapper hint as the hermes token.
        let hint = "docker compose exec hermes hermes"
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "env", args: ["PYTHONUNBUFFERED=1", hint, "auth", "list"], home: root,
            configuredBinary: hint)
            == ["PYTHONUNBUFFERED=1", hint, "-p", "default", "auth", "list"])
        // No assignments at all.
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "env", args: ["hermes", "acp"], home: root) == ["hermes", "-p", "default", "acp"])
    }

    @Test func envWrappedArgvKeepsTheSkipRules() {
        // Named-profile home: pinned by HERMES_HOME already.
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "env", args: ["PYTHONUNBUFFERED=1", "hermes", "acp"], home: "~/.hermes/profiles/work")
            == ["PYTHONUNBUFFERED=1", "hermes", "acp"])
        // Already pinned, version probe, not hermes.
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "env", args: ["X=1", "hermes", "-p", "scout", "acp"], home: "~/.hermes")
            == ["X=1", "hermes", "-p", "scout", "acp"])
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "env", args: ["X=1", "hermes", "--version"], home: "~/.hermes")
            == ["X=1", "hermes", "--version"])
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "/usr/bin/env", args: ["which", "hermes"], home: "~/.hermes") == ["which", "hermes"])
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "/usr/bin/env", args: ["signal-cli", "link"], home: "~/.hermes") == ["signal-cli", "link"])
        // An env option ends the scan; the argv is left alone.
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "env", args: ["-i", "hermes", "acp"], home: "~/.hermes") == ["-i", "hermes", "acp"])
        // Only assignments, no command.
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "env", args: ["X=1"], home: "~/.hermes") == ["X=1"])
        // `=x` and `1A=x` are not assignments to env.
        #expect(!HermesProfileScope.isEnvAssignment("=x"))
        #expect(!HermesProfileScope.isEnvAssignment("1A=x"))
        #expect(HermesProfileScope.isEnvAssignment("_A1="))
    }

    @Test func rootPinShellFragmentMatchesTheArgvRule() {
        #expect(HermesProfileScope.rootPinShellFragment(forHome: "~/.hermes") == "-p default ")
        #expect(HermesProfileScope.rootPinShellFragment(forHome: "/opt/data") == "-p default ")
        #expect(HermesProfileScope.rootPinShellFragment(forHome: "~/.hermes/profiles/work") == "")
    }
}
