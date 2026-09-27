import Testing
import Foundation
@testable import ScarfCore

/// R16c (Hermes v0.21.5 audit follow-ups from the R14 remediation audit).
///
/// - F1: the Terminal launches hand `env PATH="$PATH:…" hermes …` to the
///   user's LOGIN shell, and csh/tcsh read `$PATH:` as a variable modifier.
/// - F2: a hermes path Test Connection found, saved with a space in it, was
///   read as a wrapper command line and exited 127.
/// - F3: the credential hint compared `model.provider` without Hermes' aliases.
/// - nvidia ids are natively `vendor/model`; the mismatch banner misread them.
/// - A local bot context followed the sticky `active_profile` after pinning.
/// - S07-F2 residual: Hermes' config-derived "served" answer for a root
///   gateway record with no `served_profiles`.
///
/// The shell tests run the generated command text in the real shells this
/// Mac has (sh, bash, zsh, dash, csh, tcsh), each with a throwaway `$HOME`, a
/// bare system PATH and no rc files — what ssh's `<shell> -c <command>` sees.
@Suite struct AuditFollowupsR16cTests {

    // MARK: - Helpers

    /// A throwaway `$HOME` holding an executable fake `hermes` at
    /// `relativePath` that prints its `HERMES_HOME` and argv.
    private static func homeWithHermes(at relativePath: String = ".local/bin/hermes") throws -> (home: URL, hermes: URL) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-r16c-\(UUID().uuidString)")
        let hermes = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: hermes.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho \"HOME_PIN=${HERMES_HOME:-none} ARGS=$*\"\n"
            .write(to: hermes, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hermes.path)
        return (home, hermes)
    }

    /// `<shell> -c <command>`, the way sshd runs a remote command with the
    /// user's login shell program.
    private static func run(_ shell: String, _ command: String, home: URL) throws -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-c", command]
        proc.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": shell]
        proc.currentDirectoryURL = home
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        proc.standardInput = FileHandle.nullDevice
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func remote(
        remoteHome: String? = nil, hint: String? = nil, hintIsPath: Bool? = nil
    ) -> ServerContext {
        ServerContext(id: UUID(), displayName: "box", kind: .ssh(SSHConfig(
            host: "box", remoteHome: remoteHome,
            hermesBinaryHint: hint, hermesBinaryHintIsPath: hintIsPath)))
    }

    /// The login shells on this Mac. `/bin/dash` is Ubuntu's `/bin/sh`.
    /// fish (rejects `${PATH}`) runs too when it is installed.
    static let shells: [String] = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/csh", "/bin/tcsh",
                                   "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
        .filter { FileManager.default.isExecutableFile(atPath: $0) }

    // MARK: - F1: csh/tcsh

    /// The fix, proven where it failed: the PATH word the old code emitted
    /// dies under csh/tcsh before hermes runs; the new one works there.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/tcsh")))
    func theOldPathWordFailsUnderTcshAndTheNewOneDoesNot() throws {
        let (home, _) = try Self.homeWithHermes()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = "env PATH=\"$PATH:\(HermesConfigReader.hermesInstallDirs)\" hermes --version"
        let (oldCode, oldOut) = try Self.run("/bin/tcsh", old, home: home)
        #expect(oldCode != 0)
        #expect(oldOut.contains("modifier"))
        #expect(HermesConfigReader.pathFallback.hasPrefix("PATH=\"$PATH\"\":"))
        let new = "env \(HermesConfigReader.pathFallback) hermes --version"
        #expect(try Self.run("/bin/tcsh", new, home: home) == (0, "HOME_PIN=none ARGS=--version"))
    }

    /// The Terminal launch's remote words, joined the way ssh joins them, run
    /// in every shell: a root home gets `-p default`, a named profile its
    /// `HERMES_HOME`, and `~/.local/bin` is found with no rc file read.
    @Test(arguments: shells)
    func theTerminalLaunchRunsInEveryLoginShell(shell: String) throws {
        let (home, _) = try Self.homeWithHermes()
        defer { try? FileManager.default.removeItem(at: home) }

        let root = try #require(Self.remote().remoteLoginShellHermesWords(args: ["gateway", "setup"]))
        #expect(try Self.run(shell, root.joined(separator: " "), home: home)
            == (0, "HOME_PIN=none ARGS=-p default gateway setup"), "\(shell), root home")

        let named = try #require(Self.remote(remoteHome: "~/.hermes/profiles/work")
            .remoteLoginShellHermesWords(args: ["--resume", "20260927_101010_abc123"]))
        #expect(try Self.run(shell, named.joined(separator: " "), home: home)
            == (0, "HOME_PIN=\(home.path)/.hermes/profiles/work ARGS=--resume 20260927_101010_abc123"),
            "\(shell), named profile")
    }

    /// F2 through the same launch: a probed path with a space is one word in
    /// every shell, csh included (single quotes).
    @Test(arguments: shells)
    func aProbedPathWithASpaceRunsInEveryLoginShell(shell: String) throws {
        let (home, hermes) = try Self.homeWithHermes(at: "My Tools/hermes")
        defer { try? FileManager.default.removeItem(at: home) }
        let words = try #require(Self.remote(hint: hermes.path, hintIsPath: true)
            .remoteLoginShellHermesWords(args: ["gateway", "setup"]))
        #expect(try Self.run(shell, words.joined(separator: " "), home: home)
            == (0, "HOME_PIN=none ARGS=-p default gateway setup"), "\(shell)")
    }

    @Test func aLocalContextHasNoRemoteWords() {
        #expect(ServerContext.local(home: URL(fileURLWithPath: "/tmp/h")).remoteLoginShellHermesWords(args: []) == nil)
    }

    // MARK: - F2: probed path vs typed wrapper

    @Test func aProbedPathIsNeverAFragmentButATypedWrapperStillIs() {
        let spaced = "/Users/Jane Doe/.local/bin/hermes"
        let probed = SSHConfig(host: "box", hermesBinaryHint: spaced, hermesBinaryHintIsPath: true)
        #expect(probed.hermesBinaryHintFragment == nil)
        #expect(!ServerContext(id: UUID(), displayName: "b", kind: .ssh(probed)).paths.hermesBinaryIsShellFragment)
        #expect(ServerContext(id: UUID(), displayName: "b", kind: .ssh(probed)).paths.hermesBinaryShellWord
            == "'/Users/Jane Doe/.local/bin/hermes'")

        let wrapper = "docker compose exec hermes hermes"
        let typed = SSHConfig(host: "box", hermesBinaryHint: wrapper)
        #expect(typed.hermesBinaryHintFragment == wrapper)
        let typedPaths = ServerContext(id: UUID(), displayName: "b", kind: .ssh(typed)).paths
        #expect(typedPaths.hermesBinaryIsShellFragment)
        #expect(typedPaths.hermesBinaryShellWord == wrapper)

        // A plain probed path, and no hint at all, go in exactly as before.
        let plain = SSHConfig(host: "box", hermesBinaryHint: "/home/u/.local/bin/hermes", hermesBinaryHintIsPath: true)
        #expect(ServerContext(id: UUID(), displayName: "b", kind: .ssh(plain)).paths.hermesBinaryShellWord
            == "/home/u/.local/bin/hermes")
        #expect(Self.remote().paths.hermesBinaryShellWord == "hermes")
        // Local never carries a hint.
        #expect(!ServerContext.local(home: URL(fileURLWithPath: "/tmp/h")).paths.hermesBinaryIsShellFragment)
    }

    /// Migration: a `servers.json` entry written before the key existed
    /// decodes with no flag and keeps the old reading (a wrapper stays
    /// words); the flag round-trips, and a typed value writes no key.
    @Test func legacyEntriesDecodeUnchangedAndTheFlagRoundTrips() throws {
        let legacy = Data(#"{"host":"box","hermesBinaryHint":"docker compose exec hermes hermes"}"#.utf8)
        let old = try JSONDecoder().decode(SSHConfig.self, from: legacy)
        #expect(old.hermesBinaryHintIsPath == nil)
        #expect(old.hermesBinaryHintFragment == "docker compose exec hermes hermes")

        let probed = SSHConfig(host: "box", hermesBinaryHint: "/Users/Jane Doe/bin/hermes", hermesBinaryHintIsPath: true)
        let json = String(decoding: try JSONEncoder().encode(probed), as: UTF8.self)
        #expect(json.contains("\"hermesBinaryHintIsPath\":true"))
        let back = try JSONDecoder().decode(SSHConfig.self, from: Data(json.utf8))
        #expect(back == probed)
        #expect(back.hermesBinaryHintFragment == nil)

        let typed = SSHConfig(host: "box", hermesBinaryHint: "hermes")
        #expect(!String(decoding: try JSONEncoder().encode(typed), as: UTF8.self).contains("hermesBinaryHintIsPath"))
    }

    /// The transport's one-shot command (`sh -c '<cmd>'` behind the login
    /// shell): the probed spaced path runs; the same value read the legacy
    /// way is split into `/…/My` + `Tools/hermes` and exits 127 — the bug.
    @Test func theTransportRunsAProbedSpacedPath() throws {
        let (home, hermes) = try Self.homeWithHermes(at: "My Tools/hermes")
        defer { try? FileManager.default.removeItem(at: home) }
        func transport(_ isPath: Bool?) -> SSHTransport {
            SSHTransport(contextID: UUID(), config: SSHConfig(
                host: "box", hermesBinaryHint: hermes.path, hermesBinaryHintIsPath: isPath), displayName: "box")
        }
        func throughLoginShell(_ cmd: String) -> String {
            "sh -c '" + cmd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let fixed = transport(true).remoteShellCommand(executable: hermes.path, args: ["cron", "list"])
        #expect(try Self.run("/bin/sh", throughLoginShell(fixed), home: home)
            == (0, "HOME_PIN=none ARGS=-p default cron list"))
        let legacy = transport(nil).remoteShellCommand(executable: hermes.path, args: ["cron", "list"])
        #expect(try Self.run("/bin/sh", throughLoginShell(legacy), home: home).0 == 127)
    }

    // MARK: - F3: provider aliases in the credential hint

    @Test func scopedTokensCountForEveryAliasOfTheirProvider() {
        for provider in ["copilot", "github", "github-copilot", "GitHub-Models", " github-model "] {
            #expect(HermesProviderCredentials.environmentHasProviderKey(["GITHUB_TOKEN": "t"], provider: provider),
                    "\(provider)")
            #expect(HermesProviderCredentials.dotEnvHasProviderKey("GH_TOKEN=t\n", provider: provider), "\(provider)")
        }
        for provider in ["huggingface", "hf", "hugging-face", "huggingface-hub"] {
            #expect(HermesProviderCredentials.environmentHasProviderKey(["HF_TOKEN": "t"], provider: provider),
                    "\(provider)")
        }
        // Still scoped: another provider, or none, doesn't count them.
        #expect(!HermesProviderCredentials.environmentHasProviderKey(["GITHUB_TOKEN": "t"], provider: "anthropic"))
        #expect(!HermesProviderCredentials.environmentHasProviderKey(["HF_TOKEN": "t"], provider: "github"))
        #expect(!HermesProviderCredentials.environmentHasProviderKey(["HF_TOKEN": "t"], provider: nil))
    }

    @Test func keylessProvidersAreRecognisedByAlias() {
        for provider in ["aws", "amazon-bedrock", "lm-studio", "lm_studio", "github-copilot-acp"] {
            #expect(HermesProviderCredentials.modelUsesKeylessEndpoint(provider: provider, baseURL: ""), "\(provider)")
        }
        // `ollama` IS `custom` to Hermes: a base_url makes it keyless even
        // when it is not on this machine.
        #expect(HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "ollama", baseURL: "https://gpu.example.com/v1"))
        #expect(!HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "ollama", baseURL: ""))
        #expect(!HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "openrouter", baseURL: "https://openrouter.ai/api/v1"))
    }

    // MARK: - nvidia vendor/model ids

    @Test func nvidiaVendorModelIdsAreNotAMismatch() {
        var cfg = HermesConfig.empty
        cfg.model = "meta/llama-3.1-70b-instruct"
        for provider in ["nvidia", "nim", "nvidia-nim"] {
            cfg.provider = provider
            #expect(ModelPreflight.detectMismatch(cfg) == nil, "\(provider)")
        }
        // Control: the same id under a direct provider IS a stale prefix.
        cfg.provider = "deepseek"
        #expect(ModelPreflight.detectMismatch(cfg) != nil)
    }

    // MARK: - Local bot context freezing

    /// A local context with no override re-resolves `active_profile` on every
    /// access; a pinned one must not, whether or not the pin happens to match
    /// the profile active right now.
    @Test func aLocalPinIsFrozenEvenWhenItMatchesTheActiveProfile() {
        let live = ServerContext(id: UUID(), displayName: "Local", kind: .local)
        #expect(live.localHomeOverride == nil)
        let root = HermesProfileScope.rootHome(forHome: HermesPathSet.defaultLocalHome)
        // The drift case whatever this Mac's sticky profile is: pinning to
        // the profile active right now used to return the live context.
        let active = HermesProfileResolver.activeProfileName()
        if active != "test-override" {
            #expect(live.pinnedToProfile(active).localHomeOverride
                == HermesProfileScope.resolveHome(baseHome: root, profile: active))
        }
        #expect(live.pinnedToProfile("default").localHomeOverride == root)
        #expect(live.pinnedToProfile(nil).localHomeOverride == root)
        #expect(live.pinnedToProfile("scout").localHomeOverride
            == HermesProfileScope.resolveHome(baseHome: root, profile: "scout"))
    }

    // MARK: - S07-F2 residual: config-derived served profile

    private static let v0213 = HermesCapabilities(
        versionLine: "hermes 0.21.3", semver: .init(major: 0, minor: 21, patch: 3), dateVersion: nil)
    private static let v0214 = HermesCapabilities(
        versionLine: "hermes 0.21.4", semver: .init(major: 0, minor: 21, patch: 4), dateVersion: nil)

    @Test func theRecordedRosterWinsAndConfigIsOnlyAskedWithoutIt() {
        var asked = false
        let withKey: [String: Any] = ["served_profiles": ["default"]]
        #expect(!HermesGatewayStateProjection.serves(profile: "work", root: withKey) { asked = true; return true })
        #expect(!asked, "an empty or listing roster is authoritative")
        #expect(HermesGatewayStateProjection.serves(profile: "work", root: ["served_profiles": ["default", "work"]]) { true })
        #expect(HermesGatewayStateProjection.serves(profile: "work", root: [:]) { true })
        #expect(!HermesGatewayStateProjection.serves(profile: "work", root: [:]) { false })
        #expect(!HermesGatewayStateProjection.serves(profile: "default", root: [:]) { true })
    }

    @Test func theConfigFallbackNeedsAnExplicitOptInALiveGatewayAndTheFloor() {
        func derived(_ yaml: String?, _ caps: HermesCapabilities = Self.v0214, live: Bool = true) -> Bool {
            HermesGatewayStateProjection.configDerivedServes(
                capabilities: caps, rootConfigYAML: { yaml }, rootGatewayIsLive: { live })
        }
        #expect(derived("multiplex_profiles: true\n"))
        #expect(derived("gateway:\n  multiplex_profiles: yes\n"))
        // `_bool_token` → None → True for an unrecognised string.
        #expect(derived("gateway:\n  multiplex_profiles: \"sure\"\n"))
        // Top-level wins when not null.
        #expect(!derived("multiplex_profiles: false\ngateway:\n  multiplex_profiles: true\n"))
        #expect(derived("multiplex_profiles: null\ngateway:\n  multiplex_profiles: true\n"))
        // Unset never counts; nor does a dead gateway, a missing file, or an older host.
        #expect(!derived("model:\n  default: x\n"))
        #expect(!derived("multiplex_profiles: true\n", live: false))
        #expect(!derived(nil))
        #expect(!derived("multiplex_profiles: true\n", Self.v0213))
        // Below the floor nothing is read or probed at all.
        var touched = false
        #expect(!HermesGatewayStateProjection.configDerivedServes(
            capabilities: Self.v0213,
            rootConfigYAML: { touched = true; return "multiplex_profiles: true\n" },
            rootGatewayIsLive: { touched = true; return true }))
        #expect(!touched)
    }

    /// End to end on the record: a multiplexer record whose writer has not
    /// stamped `served_profiles` yet projects the profile's entries only
    /// when the config fallback says it is served.
    @Test func aRecordWithoutTheRosterIsProjectedOnTheFallback() throws {
        let root = Data(#"{"gateway_state":"running","platforms":{"work:telegram":{"state":"connected"},"slack":{"state":"connected"}}}"#.utf8)
        #expect(HermesGatewayStateProjection.effectiveRecord(ownData: nil, rootData: root, profile: "work") == nil)
        let data = try #require(HermesGatewayStateProjection.effectiveRecord(
            ownData: nil, rootData: root, profile: "work", configDerived: { true }))
        let state = try JSONDecoder().decode(GatewayState.self, from: data)
        #expect(Set(try #require(state.platforms).keys) == ["telegram"])
    }
}
