import Testing
import Foundation
@testable import ScarfCore

/// T1 (t-09019d73): the P8 audit's security HIGHs, written as the attacks
/// they are rather than as options.
///
/// - **SEC-H1/M3** — `ProjectRootPolicy` was mint-time-only and lexical, so a
///   symlinked root (or the firmlink spelling of home) walked straight past
///   it, and a row appended directly to the agent-writable `projects.json`
///   never met it at all.
/// - **SEC-H2** — the Keychain binding was a 32-bit FNV-1a of the path with
///   the service half unbound. The collision below was computed, not found:
///   meet-in-the-middle over four characters, seconds of CPU.
/// - **SEC-M1** — containment was checked on a PATH and the read happened
///   later, by path, following symlinks.
@Suite struct ProjectsT1SecurityTests {

    static func withTempDir(_ body: (String) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-t1-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body(dir.path)
    }

    // MARK: - SEC-M3: the policy is symlink- and firmlink-aware

    /// The audit's own example: `~/r → /`. Lexically `~/r` is an ordinary
    /// folder two levels down; physically it is the filesystem root, and
    /// every containment check anchored on it says yes to every path.
    @Test func aRootThatIsASymlinkToTheFilesystemRootIsRefused() throws {
        try Self.withTempDir { dir in
            let link = dir + "/r"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/")

            let refusal = ProjectRootPolicy.refusal(
                for: link, hermesHome: "/Users/x/.hermes", userHome: "/Users/x"
            )
            #expect(refusal?.underlying == .filesystemRoot)
            // Reported as a resolution, not as "you typed /": the message
            // has to tell the user what the folder actually is.
            if case .resolvesTo(let spelling, _) = refusal {
                #expect(spelling == "/")
            } else {
                Issue.record("expected a .resolvesTo refusal, got \(String(describing: refusal))")
            }
        }
    }

    /// The same trick aimed at the Hermes home instead of `/`: a root that
    /// resolves to the directory holding `.env`, `state.db` and
    /// `projects.json`.
    @Test func aRootThatResolvesToTheHermesHomesParentIsRefused() throws {
        try Self.withTempDir { dir in
            let hermes = dir + "/.hermes"
            try FileManager.default.createDirectory(atPath: hermes, withIntermediateDirectories: true)
            let link = dir + "/innocent"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: dir)

            let refusal = ProjectRootPolicy.refusal(
                for: link, hermesHome: hermes, userHome: nil
            )
            #expect(refusal != nil)
            if case .containsHermesHome = refusal?.underlying {} else {
                Issue.record("expected containsHermesHome, got \(String(describing: refusal))")
            }
        }
    }

    /// `/System/Volumes/Data/Users/me` and `/Users/me` are the same
    /// directory across the data-volume firmlink, and NOTHING in Foundation
    /// rewrites one spelling into the other — `resolvingSymlinksInPath`
    /// leaves the prefix alone. A lexical compare against the home therefore
    /// missed it entirely.
    @Test func theFirmlinkSpellingOfHomeIsRefused() {
        let refusal = ProjectRootPolicy.refusal(
            for: "/System/Volumes/Data/Users/x",
            hermesHome: "/Users/x/.hermes",
            userHome: "/Users/x"
        )
        // Matched in the firmlink spelling, because the HOME's spelling set
        // carries that variant too — either side may be the one that lines
        // up, which is exactly why both are enumerated. What matters is the
        // verdict: this is the home directory.
        if case .homeDirectory(let named) = refusal?.underlying {
            #expect(named.hasSuffix("/Users/x"))
        } else {
            Issue.record("expected a homeDirectory refusal, got \(String(describing: refusal))")
        }
    }

    /// And the `/private` spelling of a system directory, which
    /// `resolvingSymlinksInPath` produces in one direction only (it STRIPS
    /// `/private`, it never adds it).
    @Test func thePrivateSpellingOfASystemDirectoryIsRefused() {
        #expect(ProjectRootPolicy.refusal(
            for: "/private/var", hermesHome: "/Users/x/.hermes", userHome: "/Users/x"
        )?.underlying == .systemDirectory("/var"))
    }

    /// A remote root can only be judged lexically: `open`/`realpath` here
    /// answer questions about THIS Mac. So the physical layer is off, and a
    /// local symlink of the same name must not colour the verdict — while
    /// the universal rules still apply.
    @Test func remoteRootsAreJudgedLexicallyOnly() throws {
        try Self.withTempDir { dir in
            let link = dir + "/r"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/")
            #expect(ProjectRootPolicy.refusal(
                for: link, hermesHome: "/home/deploy/.hermes", userHome: nil,
                resolveSymlinks: false
            ) == nil)
            // …but `/` and the system directories are absurd on any host.
            #expect(ProjectRootPolicy.refusal(
                for: "/etc", hermesHome: "/home/deploy/.hermes", userHome: nil,
                resolveSymlinks: false
            ) == .systemDirectory("/etc"))
        }
    }

    /// The policy must never become the reason a real project won't work.
    /// An ordinary folder — including a real one on disk, resolved and all —
    /// stays admissible.
    @Test func ordinaryRootsSurviveTheNewPhysicalLayer() throws {
        try Self.withTempDir { dir in
            let project = dir + "/my-project"
            try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
            #expect(ProjectRootPolicy.refusal(
                for: project, hermesHome: "/Users/x/.hermes", userHome: "/Users/x"
            ) == nil)
            // A temp dir lives under /var → /private/var; the resolved
            // spelling must not trip the `/var` system-directory rule.
            #expect(ProjectRootPolicy.refusalAtUse(for: project, context: .local) == nil)
        }
    }

    // MARK: - SEC-H2: the Keychain binding

    /// A REAL FNV-1a/32 collision, computed by meet-in-the-middle over four
    /// characters. Both paths hash to `0x78b03c16` under the retired
    /// scheme — which is the whole point: an attacker picks the sibling
    /// directory name, they don't go looking for luck.
    static let victimPath = "/Users/x/victim-project"
    static let collidingPath = "/Users/x/cqf90aabq"

    @Test func theLegacyHashCollisionIsReal() {
        #expect(
            TemplateKeychainRef.legacyShortHash(of: Self.victimPath)
                == TemplateKeychainRef.legacyShortHash(of: Self.collidingPath)
        )
    }

    /// The attack the collision buys: project A, sitting in a directory
    /// whose name the attacker chose, claims project B's ref. Under the old
    /// binding `belongs` said yes and `KeychainEnvMirror` mirrored B's
    /// secret into A's `.env` block. Under SHA-256 it says no.
    @Test func aCollidingPathCannotClaimAnotherProjectsRef() {
        let victimRef = TemplateKeychainRef.make(
            templateSlug: "acme-checker", fieldKey: "api_key", projectPath: Self.victimPath
        )
        #expect(victimRef.belongs(toProjectPath: Self.victimPath))
        #expect(victimRef.belongs(toProjectPath: Self.collidingPath) == false)
    }

    /// The other half of H2: the SERVICE wasn't bound at all, so one
    /// collision reached every template's namespace. The account is now
    /// derived from the slug too, so lifting an account onto a different
    /// service produces a ref that belongs to nobody.
    @Test func aRefCannotBeMovedToAnotherTemplatesService() {
        let mine = TemplateKeychainRef.make(
            templateSlug: "acme-checker", fieldKey: "api_key", projectPath: Self.victimPath
        )
        let smuggled = TemplateKeychainRef(
            service: "com.scarf.template.other-template", account: mine.account
        )
        #expect(smuggled.belongs(toProjectPath: Self.victimPath) == false)
        // …and the same project + field under a different template is a
        // genuinely different item, not the same one twice.
        let other = TemplateKeychainRef.make(
            templateSlug: "other-template", fieldKey: "api_key", projectPath: Self.victimPath
        )
        #expect(other.account != mine.account)
        #expect(other.belongs(toProjectPath: Self.victimPath))
    }

    @Test func newRefsAreMintedInTheSHA256Form() {
        let ref = TemplateKeychainRef.make(
            templateSlug: "acme-checker", fieldKey: "api_key", projectPath: Self.victimPath
        )
        #expect(ref.projectPathHash?.count == TemplateKeychainRef.bindingHashLength)
        #expect(TemplateKeychainRef.parse(ref.uri) == ref)
    }

    /// MIGRATION. Items minted before this change carry the 8-hex FNV
    /// account. Refusing them would make every already-configured project's
    /// secret vanish at once, so they still resolve — read-side only, for a
    /// deprecation window. The URI must still PARSE, too, or the ref never
    /// reaches `belongs` in the first place.
    @Test func legacyFNVRefsStillResolveDuringTheDeprecationWindow() {
        let legacyAccount = "api_key:\(TemplateKeychainRef.legacyShortHash(of: Self.victimPath))"
        let uri = "keychain://com.scarf.template.acme-checker/\(legacyAccount)"
        let ref = TemplateKeychainRef.parse(uri)
        #expect(ref != nil)
        #expect(ref?.belongs(toProjectPath: Self.victimPath) == true)
        #expect(ref?.projectPathHash?.count == TemplateKeychainRef.legacyHashLength)
    }

    /// The `/tmp` vs `/private/tmp` spelling tolerance is about the PATH,
    /// not about the hash, so it had to survive the change: a registry row
    /// spelling the project one way and the install spelling it the other
    /// is the ordinary case on macOS, and losing it would orphan those
    /// secrets silently.
    @Test func thePrivateSpellingStillBinds() {
        let ref = TemplateKeychainRef.make(
            templateSlug: "acme-checker", fieldKey: "api_key", projectPath: "/private/tmp/proj"
        )
        #expect(ref.belongs(toProjectPath: "/tmp/proj"))
        #expect(ref.belongs(toProjectPath: "/private/tmp/proj"))
        #expect(ref.belongs(toProjectPath: "/tmp/other") == false)
    }

    /// A hash of the wrong length is neither form and must not be admitted
    /// by the length-dispatch in `belongs`.
    @Test func aRefWithAnUnknownHashLengthBelongsToNobody() {
        let ref = TemplateKeychainRef(
            service: "com.scarf.template.acme-checker", account: "api_key:abcd"
        )
        #expect(ref.belongs(toProjectPath: Self.victimPath) == false)
        #expect(TemplateKeychainRef.parse(ref.uri) == nil)
    }

    // MARK: - SEC-M1: the read must be the thing that was checked

    /// The TOCTOU itself. `containedFilePath` said yes — the path resolved
    /// to a file inside the base — and the read then happened later, by
    /// path. Swap the file for a symlink in that window and the old code
    /// read through it. `readValidated` opens with `O_NOFOLLOW`, so the
    /// swapped leaf is refused no matter what the earlier check concluded.
    @Test func aSymlinkFlippedAfterTheCheckIsRefusedAtOpen() throws {
        try Self.withTempDir { dir in
            let base = dir + "/app"
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            let asset = base + "/index.html"
            try Data("<h1>ok</h1>".utf8).write(to: URL(fileURLWithPath: asset))
            let secret = dir + "/auth.json"
            try Data("{\"token\":\"s3cret\"}".utf8).write(to: URL(fileURLWithPath: secret))

            // Check passes on the honest file — this is the window opening.
            #expect(MiniAppAssetResolver.containedFilePath(
                requestPath: "/index.html", baseDirectory: base
            ) != nil)

            // …and the attacker flips it before the read.
            try FileManager.default.removeItem(atPath: asset)
            try FileManager.default.createSymbolicLink(atPath: asset, withDestinationPath: secret)

            let result = MiniAppAssetResolver.readValidated(
                path: asset, baseDirectory: base, maxBytes: 1 << 20
            )
            #expect(result == .failure(.notContained))
        }
    }

    /// Even a symlink whose target is legitimately INSIDE the base is
    /// refused — there is no way to tell it from the attack at open time.
    /// Recorded here as the deliberate narrowing it is, not as an accident.
    @Test func anInternalSymlinkIsAlsoRefused() throws {
        try Self.withTempDir { dir in
            let base = dir + "/app"
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            let real = base + "/real.js"
            try Data("1".utf8).write(to: URL(fileURLWithPath: real))
            let link = base + "/alias.js"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

            // The path check is happy: it resolves inside the base.
            #expect(MiniAppAssetResolver.containedFilePath(
                requestPath: "/alias.js", baseDirectory: base
            ) != nil)
            #expect(MiniAppAssetResolver.readValidated(
                path: link, baseDirectory: base, maxBytes: 1 << 20
            ) == .failure(.notContained))
        }
    }

    @Test func theHappyPathStillServesTheFile() throws {
        try Self.withTempDir { dir in
            let base = dir + "/app"
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            try Data("<h1>ok</h1>".utf8).write(to: URL(fileURLWithPath: base + "/index.html"))

            let result = MiniAppAssetResolver.readContainedFile(
                requestPath: "/index.html", baseDirectory: base, maxBytes: 1 << 20
            )
            guard case .success(let asset) = result else {
                Issue.record("expected a successful read, got \(result)")
                return
            }
            #expect(String(data: asset.data, encoding: .utf8) == "<h1>ok</h1>")
        }
    }

    /// The size cap is applied to the fd we are HOLDING, not to a stat of a
    /// path that may since have been replaced.
    @Test func theByteCapIsEnforcedOnTheOpenDescriptor() throws {
        try Self.withTempDir { dir in
            let base = dir + "/app"
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: base + "/big.txt"))
            #expect(MiniAppAssetResolver.readContainedFile(
                requestPath: "/big.txt", baseDirectory: base, maxBytes: 1024
            ) == .failure(.tooLarge(bytes: 4096)))
        }
    }

    /// Directories, fifos and device nodes are never mini-app assets.
    /// `fstat` on the descriptor is what settles it.
    @Test func nonRegularFilesAreRefused() throws {
        try Self.withTempDir { dir in
            let base = dir + "/app"
            let sub = base + "/sub"
            try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
            #expect(MiniAppAssetResolver.readValidated(
                path: sub, baseDirectory: base, maxBytes: 1 << 20
            ) == .failure(.notRegularFile))

            let fifo = base + "/pipe"
            #expect(mkfifo(fifo, 0o600) == 0)
            #expect(MiniAppAssetResolver.readValidated(
                path: fifo, baseDirectory: base, maxBytes: 1 << 20
            ) == .failure(.notRegularFile))
        }
    }

    /// A remote base has no local descriptor to validate; answering from
    /// this Mac's filesystem would return a DIFFERENT file of the same name.
    @Test func aNonLocalBaseIsRefusedRatherThanReadLocally() throws {
        try Self.withTempDir { dir in
            let base = dir + "/app"
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            try Data("local".utf8).write(to: URL(fileURLWithPath: base + "/index.html"))
            #expect(MiniAppAssetResolver.readContainedFile(
                requestPath: "/index.html", baseDirectory: base, maxBytes: 1 << 20, isLocal: false
            ) == .failure(.notLocal))
        }
    }

    /// Escapes stay distinguishable from misses, so the handler can answer
    /// honestly instead of collapsing everything into one 404.
    @Test func escapesAndMissesAreDistinguishable() throws {
        try Self.withTempDir { dir in
            let base = dir + "/app"
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            #expect(MiniAppAssetResolver.readContainedFile(
                requestPath: "../escape.txt", baseDirectory: base, maxBytes: 1 << 20
            ) == .failure(.notContained))
            #expect(MiniAppAssetResolver.readContainedFile(
                requestPath: "/nope.js", baseDirectory: base, maxBytes: 1 << 20
            ) == .failure(.notFound))
        }
    }

    // MARK: - SEC-H1: recovering the root a mini-app base came from

    @Test func theOwningProjectRootIsRecoveredFromAMiniAppBase() {
        #expect(MiniAppAssetResolver.projectRoot(
            ofMiniAppBase: "/Users/x/proj/.scarf/miniapps/kanban"
        ) == "/Users/x/proj")
        // Not the mini-app layout → nothing claimed.
        #expect(MiniAppAssetResolver.projectRoot(ofMiniAppBase: "/Users/x/proj") == nil)
        #expect(MiniAppAssetResolver.projectRoot(
            ofMiniAppBase: "/Users/x/proj/.scarf/miniapps/kanban/nested"
        ) == nil)
    }

    /// The row that re-opens the S1 HIGH through the root: `/Users/me`
    /// yields a base that looks perfectly contained, inside the user's home.
    @Test func aMiniAppBaseDerivedFromTheHomeDirectoryIsRefusedAtUse() {
        let home = NSHomeDirectory()
        let base = home + "/.scarf/miniapps/evil"
        let root = MiniAppAssetResolver.projectRoot(ofMiniAppBase: base)
        #expect(root == home)
        #expect(ProjectRootPolicy.refusalAtUse(for: root ?? "", context: .local) != nil)
    }
}
