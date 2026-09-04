import Testing
import Foundation
import ScarfCore
@testable import scarf

/// t-5810202c: the per-widget signature stat is now ONE batched `statAll`
/// per tick for the whole dashboard.
///
/// The failure mode of a batched short-circuit is staleness, so every test
/// here asserts both halves: that W widgets on one tick cost one pass, AND
/// that a widget whose file actually changed still sees the change.
@MainActor
@Suite struct WidgetSignatureBatchTests {

    // MARK: - Fixtures

    private struct Fixture {
        let home: TempHermesHome
        let root: String
        var context: ServerContext { home.context }

        init() throws {
            home = try TempHermesHome()
            root = home.path + "/proj"
            try FileManager.default.createDirectory(
                atPath: root + "/reports", withIntermediateDirectories: true
            )
        }

        @discardableResult
        func write(_ relative: String, _ text: String) throws -> String {
            let abs = root + "/" + relative
            try Data(text.utf8).write(to: URL(fileURLWithPath: abs))
            return abs
        }

        func cleanup() { home.cleanup() }
    }

    private func widget(type: String, title: String, path: String?, url: String? = nil)
    -> DashboardWidget {
        DashboardWidget(type: type, title: title, url: url, path: path)
    }

    private func dashboard(_ widgets: [DashboardWidget]) -> ProjectDashboard {
        ProjectDashboard(
            version: 1,
            title: "d",
            description: nil,
            updatedAt: nil,
            theme: nil,
            sections: [DashboardSection(title: "s", columns: nil, widgets: widgets)]
        )
    }

    // MARK: - Path collection

    @Test("every file-reading widget path is collected, resolved and de-duplicated")
    func filePathsCoversTheFileReadingTypes() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try fx.write("reports/a.md", "# a")
        try fx.write("reports/b.log", "line")
        try fx.write("reports/c.png", "notreallyapng")

        let dash = dashboard([
            widget(type: "markdown_file", title: "A", path: "reports/a.md"),
            widget(type: "log_tail", title: "B", path: "reports/b.log"),
            widget(type: "image", title: "C", path: "reports/c.png"),
            // Same file through a second widget — one stat, not two.
            widget(type: "markdown_file", title: "A again", path: "./reports/a.md"),
            // Reads no file: remote image, and the non-file widget types.
            widget(type: "image", title: "D", path: nil, url: "https://example.com/x.png"),
            widget(type: "stat", title: "E", path: nil),
            widget(type: "text", title: "F", path: nil)
        ])

        let paths = WidgetSignatureBatch.filePaths(in: dash, projectRoot: fx.root)
        #expect(paths.count == 3)
        #expect(paths.contains(fx.root + "/reports/a.md"))
        #expect(paths.contains(fx.root + "/reports/b.log"))
        #expect(paths.contains(fx.root + "/reports/c.png"))
    }

    @Test("a path the resolver refuses is never batched")
    func filePathsDropsRefusedPaths() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let dash = dashboard([
            widget(type: "markdown_file", title: "escape", path: "../../../etc/passwd"),
            widget(type: "markdown_file", title: "absolute", path: "/etc/passwd"),
            widget(type: "markdown_file", title: "empty", path: nil)
        ])
        #expect(WidgetSignatureBatch.filePaths(in: dash, projectRoot: fx.root).isEmpty)
        // No dashboard at all is not an error, it's no paths.
        #expect(WidgetSignatureBatch.filePaths(in: nil, projectRoot: fx.root).isEmpty)
    }

    // MARK: - One pass per tick

    @Test("W widgets asking on one tick cost exactly one statAll pass")
    func oneTickIsOnePass() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let a = try fx.write("reports/a.md", "# a")
        let b = try fx.write("reports/b.log", "line")
        let c = try fx.write("reports/c.png", "png")
        let paths = [a, b, c]

        let batch = WidgetSignatureBatch()
        for path in paths {
            let lookup = await batch.signature(
                for: path, tick: "1", among: paths, context: fx.context
            )
            guard case .known(let sig) = lookup else {
                Issue.record("expected a batched answer for \(path)")
                return
            }
            #expect(sig != nil)
        }
        #expect(batch.passCount == 1)

        // A NEW tick is a new pass — the whole point is that the batch is a
        // per-tick coalescer, not a cache with a lifetime of its own.
        _ = await batch.signature(for: a, tick: "2", among: paths, context: fx.context)
        _ = await batch.signature(for: b, tick: "2", among: paths, context: fx.context)
        #expect(batch.passCount == 2)
    }

    @Test("concurrent askers on one tick still run one pass")
    func concurrentAskersCoalesce() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let a = try fx.write("reports/a.md", "# a")
        let b = try fx.write("reports/b.log", "line")
        let paths = [a, b]
        let batch = WidgetSignatureBatch()

        // The real shape: several widgets' `.task` bodies resuming on the
        // main actor in the same tick, each awaiting the batch.
        async let one = batch.signature(for: a, tick: "1", among: paths, context: fx.context)
        async let two = batch.signature(for: b, tick: "1", among: paths, context: fx.context)
        async let three = batch.signature(for: a, tick: "1", among: paths, context: fx.context)
        let results = await [one, two, three]
        #expect(results.allSatisfy { if case .known(let s) = $0 { return s != nil } else { return false } })
        #expect(batch.passCount == 1)
    }

    // MARK: - The invalidation edge (the risk this change carries)

    @Test("a widget whose file changed gets a DIFFERENT signature on the next tick")
    func aChangedFileIsSeen() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let a = try fx.write("reports/a.md", "# a")
        let b = try fx.write("reports/b.log", "line")
        let paths = [a, b]
        let batch = WidgetSignatureBatch()

        let before = await batch.signature(for: a, tick: "1", among: paths, context: fx.context)
        // Size is half the signature precisely so a same-second rewrite still
        // registers — write different bytes, not just different content.
        try fx.write("reports/a.md", "# a much longer body than before")
        let after = await batch.signature(for: a, tick: "2", among: paths, context: fx.context)
        #expect(before != after)
        // And the file that did NOT change reads identically across the two
        // passes, so its widget still skips.
        let bBefore = await batch.signature(for: b, tick: "1", among: paths, context: fx.context)
        let bAfter = await batch.signature(for: b, tick: "2", among: paths, context: fx.context)
        #expect(bBefore == bAfter)
    }

    @Test("the batched signature is byte-identical to the per-widget one")
    func batchedMatchesPerWidgetSignature() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let a = try fx.write("reports/a.md", "# a")
        let batch = WidgetSignatureBatch()
        let batched = await batch.signature(
            for: a, tick: "1", among: [a], context: fx.context
        )
        let direct = WidgetFileRead.signature(a, transport: fx.context.makeTransport())
        #expect(batched == .known(direct))
    }

    // MARK: - Degradation

    @Test("an absent file is a known-nil signature, not 'unchanged'")
    func anAbsentFileIsKnownNil() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let missing = fx.root + "/reports/gone.md"
        let batch = WidgetSignatureBatch()
        let lookup = await batch.signature(
            for: missing, tick: "1", among: [missing], context: fx.context
        )
        // `.known(nil)` — the widget must still run its read (and surface the
        // read error). `.unknown` would send it to its own stat, which is
        // merely wasteful; treating it as unchanged would be a bug.
        #expect(lookup == .known(nil))
    }

    @Test("a path outside the batch is unknown, so its widget stats itself")
    func anUncoveredPathIsUnknown() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let a = try fx.write("reports/a.md", "# a")
        let b = try fx.write("reports/b.log", "line")
        let batch = WidgetSignatureBatch()
        // This is the "renders somewhere the panel didn't collect it" case —
        // a widget outside a dashboard panel, or one whose path the panel
        // could not resolve. It must never be told "nothing changed".
        let lookup = await batch.signature(
            for: b, tick: "1", among: [a], context: fx.context
        )
        #expect(lookup == .unknown)
        // Asking for an uncovered path must not have consumed a pass either.
        #expect(batch.passCount == 0)
    }

    @Test("no scope installed at all degrades to unknown")
    func noScopeIsUnknown() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let a = try fx.write("reports/a.md", "# a")
        let scope: WidgetSignatureScope? = nil
        let lookup = await scope.lookup(path: a, tick: "1", context: fx.context)
        #expect(lookup == .unknown)
    }

    @Test("an empty dashboard costs a pass that stats nothing")
    func emptyPathSetIsCheap() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let batch = WidgetSignatureBatch()
        let lookup = await batch.signature(
            for: "/nowhere", tick: "1", among: [], context: fx.context
        )
        #expect(lookup == .unknown)
        #expect(batch.passCount == 0)
    }
}
