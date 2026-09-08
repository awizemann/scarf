//
//  ConfigJourneyUITests.swift
//  scarfUITests
//
//  The depth half of the UI release gate for Scarf's three configuration
//  surfaces: Skills, Models, and Settings. Where `SectionSweepUITests`
//  proves every section RENDERS, these prove that driving the real
//  controls CHANGES THE RIGHT FILE in the Hermes home — and, for
//  Settings, that the change survives a relaunch.
//
//  ## The assertion that matters
//
//  Every journey here asserts against the FILE, not just the UI. A view
//  that optimistically flips a toggle and silently drops the write is
//  exactly the failure a UI-only assertion misses, and Scarf has shipped
//  that bug before (charter C5: never assume a CLI invocation worked
//  because the UI rendered). So each journey is: drive the control →
//  poll the file in `isolatedHome` → assert the value → put it back.
//
//  ## Which surface writes which file (verified, not assumed)
//
//  These three are NOT interchangeable, and the distinction is the whole
//  reason there are four tests instead of two:
//
//  - **Settings → General → Model** writes `model.default` /
//    `model.provider` into `<home>/config.yaml`, via
//    `LocalModelConfigPlan` → `hermes config set` (HermesFileService).
//    This is the "switch the active model" surface.
//  - **Settings → General → Timezone** writes the top-level `timezone`
//    key into `<home>/config.yaml` via `hermes config set timezone`.
//    Chosen for the persistence journey precisely BECAUSE it lives in
//    the Hermes home: `UserDefaults` is not isolated by
//    `SCARF_HERMES_HOME`, so a UserDefaults-backed setting would either
//    leak into the developer's own preferences or pass for the wrong
//    reason. (Same trap as the sidebar-collapse state, which the section
//    sweep works around with `NSArgumentDomain` launch arguments.)
//  - **The Models SECTION** does not touch `config.yaml` at all. It is
//    CRUD over Scarf's own preset catalog at
//    `<home>/scarf/model_presets.json` (`ModelPresetService`); presets
//    are applied per-project over ACP `session/set_model`, as an overlay
//    on the global config default. So its journey asserts against the
//    preset store, and the config.yaml journey goes through Settings.
//
//  ## Isolation
//
//  `ScarfUITestCase` pins every launch at a per-test throwaway home. On
//  top of that, each test here digests the developer's REAL
//  `~/.hermes/config.yaml` in setUp and re-checks it in tearDown: these
//  journeys exist to write config files, so "wrote the right file" and
//  "wrote nobody else's file" are both load-bearing, and a regression in
//  the isolation harness must fail HERE rather than quietly editing the
//  machine it runs on.
//

import CryptoKit
import XCTest

final class ConfigJourneyUITests: ScarfUITestCase {

    // MARK: - Real-home tripwire

    /// SHA-256 of the developer's real `~/.hermes/config.yaml` at setUp,
    /// or nil when they have no Hermes install.
    private var realConfigDigest: String?

    private static var realConfigPath: String {
        ((realHome as NSString).appendingPathComponent(".hermes") as NSString)
            .appendingPathComponent("config.yaml")
    }

    private static func digest(ofFileAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        realConfigDigest = Self.digest(ofFileAt: Self.realConfigPath)
    }

    override func tearDownWithError() throws {
        // Runs even when the test failed, which is when it matters most.
        let after = Self.digest(ofFileAt: Self.realConfigPath)
        XCTAssertEqual(
            after, realConfigDigest,
            "\(Self.realConfigPath) changed while a config journey ran — the isolated home leaked. Every write in this file must land in SCARF_HERMES_HOME."
        )
        realConfigDigest = nil
        try super.tearDownWithError()
    }

    // MARK: - Journey 1a: the fixture's skill is listed, and uninstalls

    /// With the seeded fixture home, `openhue` is installed; the Skills
    /// view lists it, and Uninstall removes it from `<home>/skills/`.
    ///
    /// Skips (rather than fails) without the fixture: the gate must never
    /// depend on `SCARF_UITEST_FIXTURE` being set, and an empty home has
    /// no skill to uninstall. Run it for real with:
    ///
    ///     FIXTURE="$(scripts/ui-fixture/make-ui-fixture.sh "$(mktemp -d)/fixture-home")"
    ///     TEST_RUNNER_SCARF_UITEST_FIXTURE="$FIXTURE" xcodebuild test … -testPlan Full \
    ///       -only-testing:scarfUITests/ConfigJourneyUITests
    @MainActor
    func testFixtureSkillIsListedAndUninstalls() throws {
        // Discovered from disk, never hard-coded — and at DEPTH TWO.
        //
        // `~/.hermes/skills/` is `<category>/<skill>`, not a flat list of
        // skills: the fixture's `hermes skills repair-official openhue`
        // lands at `skills/smart-home/openhue`, where `smart-home` is the
        // category the Skills list renders as a section header and
        // `openhue` is the skill (and the `skills.row.` key). A test that
        // read the first entry of `skills/` would look for a
        // `skills.row.smart-home` that has never existed.
        let skillsDir = (isolatedHome as NSString).appendingPathComponent("skills")
        let fm = FileManager.default
        let installed: [(category: String, name: String)] = ((try? fm.contentsOfDirectory(atPath: skillsDir)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .flatMap { category -> [(String, String)] in
                let categoryDir = (skillsDir as NSString).appendingPathComponent(category)
                return ((try? fm.contentsOfDirectory(atPath: categoryDir)) ?? [])
                    .filter { !$0.hasPrefix(".") }
                    .sorted()
                    .map { (category, $0) }
            }
        guard let skill = installed.first else {
            throw XCTSkip("No <category>/<skill> under \(skillsDir) — run with TEST_RUNNER_SCARF_UITEST_FIXTURE pointing at a seeded fixture home (scripts/ui-fixture/make-ui-fixture.sh).")
        }
        let skillName = skill.name
        let skillDir = ((skillsDir as NSString)
            .appendingPathComponent(skill.category) as NSString)
            .appendingPathComponent(skillName)

        let app = launchExpanded()
        defer { gracefulQuit(app) }

        try openSection(app, "Skills")

        let row = element(app, "skills.row.\(skillName)")
        XCTAssertTrue(
            row.waitForExistence(timeout: 20),
            "The fixture installed '\(skillName)' into \(skillDir) but the Skills list never showed a skills.row.\(skillName)."
        )
        attach(app, named: "skills — \(skillName) listed")

        row.click()

        // Uninstall lives in the DETAIL pane, so it only exists once a
        // skill is selected — waiting for it also proves the selection
        // took.
        let uninstall = element(app, "skills.detail.uninstall")
        XCTAssertTrue(
            uninstall.waitForExistence(timeout: 20),
            "Selected '\(skillName)' but the detail pane never offered skills.detail.uninstall."
        )
        uninstall.click()

        // t-ec6d2e6d (fixed 2026-09-08): Uninstall now passes the BARE skill
        // name and judges the CLI by its output, not its always-zero exit.
        // The assertions below run for real.
        // `hermes skills uninstall` is a spawned CLI call with a 60 s
        // timeout, so the disk is the thing to wait on.
        // 30s, not 90: `hermes skills uninstall` answers in about two
        // seconds; while the bug was open this wait always ran
        // to exhaustion. A minute and a half of idle polling per run is
        // not free — it is long enough to lose the app's window and to
        // take later tests in the same invocation down with it.
        let removed = waitUntil(timeout: 30, describing: "\(skillDir) to disappear") {
            !FileManager.default.fileExists(atPath: skillDir)
        }
        attach(app, named: "skills — after uninstall", keepAlways: !removed)
        XCTAssertTrue(
            removed,
            "Clicked Uninstall for '\(skillName)' but \(skillDir) is still on disk — the UI reported an action the CLI did not perform."
        )

        // And the list agrees with the disk.
        XCTAssertTrue(
            waitForDisappearance(of: row, timeout: 15),
            "'\(skillName)' is gone from disk but skills.row.\(skillName) is still in the list."
        )
    }

    // MARK: - Journey 1b: installing a skill through the UI

    /// Install a skill from the hub through the Skills view and see it
    /// land both in the list and in `<home>/skills/`.
    ///
    /// SkillsView has no offline install path: every route in
    /// (`Browse Hub`, `Install from URL…`) resolves over the network, and
    /// the fixture's own skill is seeded by `hermes skills repair-official`
    /// on the CLI, not through any UI affordance. So this journey probes
    /// the hub host first and skips cleanly when it is unreachable —
    /// keeping the Full plan green on a laptop with no network rather
    /// than failing for a reason that is not Scarf's.
    @MainActor
    func testInstallSkillFromHub() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: Self.hermesBinary),
            "No hermes binary at \(Self.hermesBinary) — nothing to install with."
        )
        try XCTSkipUnless(
            Self.hostIsReachable("https://raw.githubusercontent.com", timeout: 5),
            "Skill hub host unreachable within 5s — SkillsView offers no offline install path, so this journey is network-gated."
        )

        let app = launchExpanded()
        defer { gracefulQuit(app) }

        try openSection(app, "Skills")

        // SkillsView's tab strip is now the same button-per-tab pattern as
        // SettingsView.tabStrip (t-42c56c2f) — each tab is a real `Button`
        // carrying `skills.tab.<rawValue>`, drivable by identifier rather
        // than the old `.pickerStyle(.segmented)` Picker, whose segments
        // surfaced as RadioButtons that `.click()` could not actually move.
        let hubTab = element(app, "skills.tab.Browse Hub")
        guard hubTab.waitForExistence(timeout: 20) else {
            throw XCTSkip("Skills view never exposed skills.tab.Browse Hub.")
        }

        // Retried for the same dropped-click reason as `openSection`.
        let browse = element(app, "skills.hub.browse")
        var reachedHub = false
        for attempt in 1...3 {
            ensureFrontmost(app)
            hubTab.click()
            if browse.waitForExistence(timeout: 10) { reachedHub = true; break }
            print("[ConfigJourney] Browse Hub tab did not open on attempt \(attempt)/3; retrying.")
        }
        guard reachedHub else {
            throw XCTSkip("skills.tab.Browse Hub did not open the hub view after 3 clicks.")
        }
        browse.click()

        // One row is enough — we are testing Scarf's install plumbing,
        // not the hub's catalogue.
        let anyInstall = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'skills.hub.install.'"))
        guard anyInstall.firstMatch.waitForExistence(timeout: 60) else {
            throw XCTSkip("`hermes skills browse` returned no hub rows within 60s — nothing to install. Not a Scarf failure.")
        }
        let target = anyInstall.firstMatch
        let skillName = String(target.identifier.dropFirst("skills.hub.install.".count))
        attach(app, named: "skills — hub row \(skillName)")
        target.click()

        // `skills install` fuzzy-matches identifiers and EXITS 0 when
        // nothing matched, installing nothing (see the v0.21 seeding
        // note) — so the disk, not the exit code or the banner, is the
        // only honest verdict here.
        //
        // A NEW entry, not a non-empty directory: against the fixture home
        // `skills/` already holds a skill, so "is it non-empty" would pass
        // without installing anything at all.
        let before = Self.installedSkillPaths(inHome: isolatedHome)
        let grew = waitUntil(timeout: 150, describing: "a new skill under \(isolatedHome ?? "?")/skills") {
            !Self.installedSkillPaths(inHome: self.isolatedHome).subtracting(before).isEmpty
        }
        attach(app, named: "skills — after install", keepAlways: !grew)
        XCTAssertTrue(
            grew,
            "Clicked Install for hub skill '\(skillName)' but no new skill appeared under \(isolatedHome ?? "?")/skills (before: \(before.sorted())). `hermes skills install` exits 0 on a fuzzy miss, so a green banner here means nothing."
        )
    }

    // MARK: - Journey 2a: switching the active model writes config.yaml

    /// Change the active model through Settings → General and assert
    /// `<home>/config.yaml` carries it, then switch back.
    ///
    /// Driven through the picker's **Custom…** entry rather than the
    /// catalog columns: the catalog is a multi-MB models.dev file whose
    /// contents change under us, while Custom… is offline, deterministic,
    /// and exercises the same `applyModelPickerSelection` write path.
    @MainActor
    func testModelSwitchWritesConfigYAML() throws {
        // Deliberately SHORT. This journey types into the picker four
        // times (set, then restore), and every keystroke is a synthesized
        // event: long strings produced both truncated input
        // ("Antarctica/Tr") and outright "Failed to synthesize event:
        // Timed out while synthesizing event" on a loaded Mac. Still
        // unmistakably a test value, and still prefixed so the sheet's
        // provider inference has something to chew on.
        let sentinelModel = "uitest/m1"
        let sentinelProvider = "uitest"

        let app = launchExpanded()
        defer { gracefulQuit(app) }

        try openSection(app, "Settings")
        try selectSettingsTab(app, "General")

        let originalModel = configValue(atPath: ["model", "default"])
        let originalProvider = configValue(atPath: ["model", "provider"])
        XCTAssertNotEqual(
            originalModel, sentinelModel,
            "The fixture home already carries the sentinel model — this test could pass without writing anything."
        )

        try setModelThroughPicker(app, model: sentinelModel, provider: sentinelProvider)

        let applied = waitUntil(timeout: 60, describing: "config.yaml model.default == \(sentinelModel)") {
            self.configValue(atPath: ["model", "default"]) == sentinelModel
        }
        attach(app, named: "models — after switch", keepAlways: !applied)
        XCTAssertTrue(
            applied,
            "Selected '\(sentinelModel)' in the picker but \(configPath) still says model.default = \(configValue(atPath: ["model", "default"]) ?? "<absent>")."
        )
        XCTAssertEqual(
            configValue(atPath: ["model", "provider"]), sentinelProvider,
            "model.default was written but model.provider was not — the two must move together (a provider left behind routes chats to the wrong endpoint)."
        )

        // Switch back. Restoring is part of the journey, not cleanup:
        // "the picker can move the value back" is its own assertion, and
        // a one-way test would pass against a control that can only ever
        // be set once.
        guard let originalModel else {
            XCTFail("config.yaml had no model.default to restore.")
            return
        }
        try setModelThroughPicker(app, model: originalModel, provider: originalProvider ?? "")

        let restored = waitUntil(timeout: 60, describing: "config.yaml model.default back to \(originalModel)") {
            self.configValue(atPath: ["model", "default"]) == originalModel
        }
        XCTAssertTrue(
            restored,
            "Could not switch the model back to '\(originalModel)' — config.yaml now says \(configValue(atPath: ["model", "default"]) ?? "<absent>")."
        )
    }

    // MARK: - Journey 2b: the Models section writes the preset store

    /// Create a preset in the Models section, assert it lands in
    /// `<home>/scarf/model_presets.json`, then delete it and assert it is
    /// gone.
    ///
    /// This is the Models SECTION's real contract. It deliberately does
    /// NOT assert anything about config.yaml — presets are a Scarf-owned
    /// overlay applied per project over ACP, and a test that expected
    /// them in config.yaml would be encoding a misunderstanding of the
    /// feature as a requirement.
    @MainActor
    func testModelPresetCreateAndDeleteWritesPresetStore() throws {
        let presetName = "UITest Journey Preset"
        let presetModel = "uitest/preset-model"

        let app = launchExpanded()
        defer { gracefulQuit(app) }

        // Models is capability-gated (>= v0.13 `session/set_model`); an
        // older host legitimately has no row, which is not a failure.
        let sidebarRow = element(app, "sidebar.section.Models")
        try XCTSkipUnless(
            sidebarRow.waitForExistence(timeout: 15),
            "No Models sidebar row — the host Hermes predates ACP session/set_model, where the section is correctly hidden."
        )
        try openSection(app, "Models", gated: true)

        // Either entry point, depending on whether the home already has
        // presets: `models.newPreset` in the page header once the list has
        // loaded, `models.createFirstPreset` in the empty state. Both open
        // the same sheet. Waiting for EITHER (rather than the header one,
        // then probing the other) matters — the view shows a ProgressView
        // while `ModelPresetService` reads the store, and during that beat
        // neither button exists.
        let entry = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'models.newPreset' OR identifier == 'models.createFirstPreset'")
        ).firstMatch
        guard entry.waitForExistence(timeout: 25) else {
            XCTFail("Models section offered neither models.newPreset nor models.createFirstPreset within 25s.")
            return
        }
        ensureFrontmost(app)
        entry.click()

        let nameField = element(app, "models.preset.name")
        XCTAssertTrue(nameField.waitForExistence(timeout: 15), "New Preset sheet never showed models.preset.name.")
        nameField.click()
        nameField.typeText(presetName)

        // A preset needs a model before Save enables, and the picker's
        // Custom… entry is the offline way to supply one.
        element(app, "models.preset.modelPicker").click()
        try enterCustomModel(app, model: presetModel, provider: "uitest")

        let save = element(app, "models.preset.save")
        XCTAssertTrue(save.waitForExistence(timeout: 15), "Preset sheet never showed models.preset.save.")
        save.click()

        let storePath = (isolatedHome as NSString)
            .appendingPathComponent("scarf/model_presets.json")
        let written = waitUntil(timeout: 30, describing: "\(storePath) to contain '\(presetName)'") {
            (try? String(contentsOfFile: storePath, encoding: .utf8))?.contains(presetName) == true
        }
        attach(app, named: "models — preset created", keepAlways: !written)
        XCTAssertTrue(
            written,
            "Saved preset '\(presetName)' but it is not in \(storePath)."
        )

        let row = element(app, "models.row.\(presetName)")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Preset was written to disk but no models.row.\(presetName) appeared.")

        // Delete it again, through the confirmation dialog.
        element(app, "models.row.\(presetName).delete").click()
        // The confirmation is an NSAlert sheet. Scope to it: an app-wide
        // `buttons["Delete"]` can resolve to the alert's Touch Bar proxy,
        // which XCUITest refuses to click.
        let confirm = app.sheets.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "Delete confirmation dialog never appeared.")
        confirm.click()

        let deleted = waitUntil(timeout: 30, describing: "'\(presetName)' to leave \(storePath)") {
            (try? String(contentsOfFile: storePath, encoding: .utf8))?.contains(presetName) != true
        }
        XCTAssertTrue(deleted, "Confirmed the delete but '\(presetName)' is still in \(storePath).")
    }

    // MARK: - Journey 3: a Settings change survives a relaunch

    /// Change a Hermes-home-backed setting, quit, relaunch against the
    /// SAME isolated home, and assert the value is still there — in the
    /// UI and in the file.
    ///
    /// `isolatedHome` is minted in `setUpWithError` and only removed in
    /// `tearDownWithError`, so a second `makeApp()` inside one test method
    /// is already pinned at the same home; no base-class change was
    /// needed for the relaunch.
    ///
    /// Timezone is the value under test because it lives in
    /// `config.yaml`. A `UserDefaults`-backed setting would have been the
    /// wrong choice twice over: `SCARF_HERMES_HOME` does not isolate
    /// `UserDefaults`, so the test would both pollute the developer's own
    /// preferences and "persist" for a reason that has nothing to do with
    /// the Hermes home the app is pointed at.
    @MainActor
    func testSettingsChangePersistsAcrossRelaunch() throws {
        // Real IANA zone (Hermes may validate) that nobody's real config
        // would already be set to.
        let sentinelTimezone = "Antarctica/Troll"

        let firstLaunch = launchExpanded()

        try openSection(firstLaunch, "Settings")
        try selectSettingsTab(firstLaunch, "General")

        XCTAssertNotEqual(
            configValue(atPath: ["timezone"]), sentinelTimezone,
            "config.yaml is already set to the sentinel timezone — this test could pass without writing anything."
        )

        let edit = element(firstLaunch, "settings.timezone.edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 20), "Settings → General has no settings.timezone.edit button.")
        edit.click()

        let field = element(firstLaunch, "settings.timezone.field")
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Clicking Edit did not reveal settings.timezone.field.")
        // Through `replaceText`, which reads the field back: raw
        // `typeText` is NOT reliable against a SwiftUI TextField under
        // load. This exact step produced `timezone: AntarctUica/Troll` on
        // a real run — one keystroke landing out of order — which looks
        // for all the world like a config-writing bug and is not one.
        replaceText(in: field, firstLaunch, with: sentinelTimezone)
        field.typeKey(.return, modifierFlags: [])

        let saved = waitUntil(timeout: 60, describing: "config.yaml timezone == \(sentinelTimezone)") {
            self.configValue(atPath: ["timezone"]) == sentinelTimezone
        }
        attach(firstLaunch, named: "settings — timezone written", keepAlways: !saved)
        XCTAssertTrue(
            saved,
            "Committed '\(sentinelTimezone)' but \(configPath) says timezone = \(configValue(atPath: ["timezone"]) ?? "<absent>")."
        )

        gracefulQuit(firstLaunch)

        // Relaunch against the SAME isolatedHome — this is the actual
        // subject of the test.
        let secondLaunch = launchExpanded()
        defer { gracefulQuit(secondLaunch) }

        try openSection(secondLaunch, "Settings")
        try selectSettingsTab(secondLaunch, "General")

        let value = element(secondLaunch, "settings.timezone.value")
        XCTAssertTrue(value.waitForExistence(timeout: 30), "After relaunch, Settings → General has no settings.timezone.value.")
        // The row re-renders from the async config load, so it can still
        // read the pre-load placeholder ("—") for a beat.
        //
        // `.value`, not `.label`: the row is a SwiftUI `Text`, which
        // AppKit exposes as a StaticText carrying its string as the
        // accessibility VALUE. Asserting on `label` compares against ""
        // and fails on a perfectly good row.
        let shown = waitUntil(timeout: 30, describing: "the timezone row to read '\(sentinelTimezone)'") {
            (value.value as? String) == sentinelTimezone
        }
        attach(secondLaunch, named: "settings — timezone after relaunch", keepAlways: !shown)
        XCTAssertTrue(
            shown,
            "config.yaml persisted '\(sentinelTimezone)' but the relaunched UI shows '\(String(describing: value.value))' — the view is not reading the value back."
        )
        XCTAssertEqual(
            configValue(atPath: ["timezone"]), sentinelTimezone,
            "The relaunched app changed timezone out from under the test."
        )
    }

    // MARK: - Navigation helpers

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        // Scoped to the app's WINDOWS (sheets and alerts included), never the
        // whole app: AppKit mirrors some buttons into a Touch Bar proxy that
        // an app-wide `.firstMatch` can resolve to first, and clicking that
        // fails with "cannot be called with Touch Bar elements" (seen on the
        // Models row's Delete). Always `.firstMatch`: several elements can
        // legitimately answer to one identifier.
        app.windows.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Launch, surface, and open every collapsed sidebar nav section.
    ///
    /// The `-sidebar.section.collapsed.<Title> 0` launch arguments alone
    /// are NOT enough: `SidebarSectionCollapseStore` reads them through
    /// `NSArgumentDomain`, but a title that is not in the hard-coded list
    /// (or a section collapsed by some other route) still comes up shut,
    /// and a shut section's rows do not exist to click — which is exactly
    /// how the first run of these journeys "lost" Settings and Models.
    /// The sweep hits the headers as well for the same reason.
    private func launchExpanded() -> XCUIApplication {
        let app = makeApp(extraLaunchArguments: SectionSweepUITests.expandedSidebarLaunchArguments)
        launchAndSurface(app)
        assertAllSidebarSectionsExpanded(app)
        return app
    }

    /// Bring `app` back to the front before synthesizing events into it.
    ///
    /// Running several journeys in one `xcodebuild test` invocation, each
    /// launching and quitting Scarf, the app is not reliably frontmost by
    /// the time a later test clicks: observed failures were a dropped
    /// sidebar click ("Skills.root never appeared") and an outright
    /// "Failed to synthesize event: Timed out while synthesizing event",
    /// both in the middle of the run while the same steps passed in
    /// isolation. `activate()` is idempotent and cheap, so it is called at
    /// the top of every interaction phase rather than once at launch.
    private func ensureFrontmost(_ app: XCUIApplication) {
        guard app.state != .notRunning else { return }
        if app.state != .runningForeground {
            app.activate()
            waitForForeground(app, timeout: 10)
        }
    }

    /// Click into a sidebar section and wait for its root.
    ///
    /// `gated` is the section's `gated` flag from `Resources/Sections.json`
    /// and it decides what a MISSING row means. Only a capability-gated
    /// section may legitimately have no row (an older Hermes host hides
    /// it), and only that case may skip. For everything else a missing row
    /// is a failure — the first version of this helper skipped
    /// unconditionally, and quietly turned a genuinely lost Settings row
    /// into a green run, which is the one outcome a release gate must
    /// never produce.
    private func openSection(_ app: XCUIApplication, _ section: String, gated: Bool = false) throws {
        ensureFrontmost(app)
        let row = element(app, "sidebar.section.\(section)")
        if !row.waitForExistence(timeout: 20) {
            // Second look with the app explicitly re-fronted: the sidebar
            // is there, the runner just could not see it yet.
            ensureFrontmost(app)
        }
        guard row.waitForExistence(timeout: 20) else {
            guard gated else {
                XCTFail("sidebar.section.\(section) is missing and \(section) is not capability-gated.")
                return
            }
            throw XCTSkip("No sidebar.section.\(section) row — the section is capability-gated off on this host.")
        }
        // Retried: a click that lands while the app is not frontmost is
        // dropped silently, and re-clicking a sidebar row that is already
        // selected is a no-op, so retrying is free.
        let root = element(app, "\(section).root")
        for attempt in 1...3 {
            ensureFrontmost(app)
            row.click()
            if root.waitForExistence(timeout: 15) { return }
            print("[ConfigJourney] \(section).root absent after click attempt \(attempt)/3; retrying.")
        }
        XCTFail("\(section).root never appeared after clicking its sidebar row three times.")
    }

    private func selectSettingsTab(_ app: XCUIApplication, _ tab: String) throws {
        ensureFrontmost(app)
        let button = element(app, "settings.tab.\(tab)")
        XCTAssertTrue(button.waitForExistence(timeout: 20), "Settings has no settings.tab.\(tab).")
        button.click()
    }

    /// Open the model picker at `pickerIdentifier` and commit a custom
    /// model/provider pair through it.
    private func setModelThroughPicker(
        _ app: XCUIApplication,
        model: String,
        provider: String,
        pickerIdentifier: String = "settings.model.picker"
    ) throws {
        ensureFrontmost(app)
        let picker = element(app, pickerIdentifier)
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "No \(pickerIdentifier) on screen.")

        // Retried, like every other click in this file: a dropped click
        // here surfaced as "Model picker sheet never showed
        // models.picker.customToggle", which reads like a broken sheet
        // rather than a click that never happened. Clicking the row again
        // while the sheet is already up is harmless — the identifier below
        // is inside the sheet, so success is checked before any re-click.
        let toggle = element(app, "models.picker.customToggle")
        var sheetOpen = false
        for attempt in 1...3 {
            ensureFrontmost(app)
            picker.click()
            // Generous: the sheet loads the (multi-MB) models.dev catalog
            // off-main before it renders.
            if toggle.waitForExistence(timeout: 20) { sheetOpen = true; break }
            print("[ConfigJourney] model picker sheet did not open on attempt \(attempt)/3; retrying.")
        }
        XCTAssertTrue(sheetOpen, "Clicking \(pickerIdentifier) three times never opened the model picker sheet.")
        guard sheetOpen else { return }

        try enterCustomModel(app, model: model, provider: provider)
    }

    /// Drive the already-open `ModelPickerSheet` through its Custom…
    /// entry and hit Select.
    private func enterCustomModel(_ app: XCUIApplication, model: String, provider: String) throws {
        ensureFrontmost(app)
        let custom = element(app, "models.picker.customToggle")
        XCTAssertTrue(custom.waitForExistence(timeout: 30), "Model picker sheet never showed models.picker.customToggle.")
        custom.click()

        let modelField = element(app, "models.picker.customModelID")
        XCTAssertTrue(modelField.waitForExistence(timeout: 15), "Custom entry has no models.picker.customModelID field.")
        // Custom… pre-fills both fields with the CURRENT values, so each
        // one must be cleared before typing or the new value is appended
        // to the old.
        replaceText(in: modelField, app, with: model)
        replaceText(in: element(app, "models.picker.customProviderID"), app, with: provider)

        let select = element(app, "models.picker.select")
        XCTAssertTrue(select.waitForExistence(timeout: 15), "Model picker sheet has no models.picker.select button.")
        select.click()
    }

    /// Set a text field's contents, and VERIFY they took.
    ///
    /// Verified because blind typing produced a wrong value that looked
    /// like a product bug: the provider field came out as `uitest/` — a
    /// fragment of the neighbouring model ID — when the select-all/delete
    /// and the subsequent keystrokes raced the SwiftUI binding. Reading the
    /// field back and retrying once makes the input deterministic, so a
    /// later assertion failure means the app is wrong rather than the
    /// typing.
    private func replaceText(in field: XCUIElement, _ app: XCUIApplication, with text: String) {
        for attempt in 1...2 {
            field.click()
            // Typed through the APPLICATION, not the element: element-scoped
            // typing re-resolves and re-focuses the element for every call,
            // and it was that extra round trip that produced "Failed to
            // synthesize event: Timed out while synthesizing event" on a
            // busy Mac. The click above has already given the field focus.
            app.typeKey("a", modifierFlags: .command)
            // Select-all then type REPLACES the selection, so no separate
            // delete is needed — one fewer synthesized event, and the
            // delete keystroke was the one observed timing out. Only the
            // clear-to-empty case still needs it, since `typeText("")` is
            // a no-op.
            if text.isEmpty {
                app.typeKey(.delete, modifierFlags: [])
            } else {
                app.typeText(text)
            }

            if waitUntil(timeout: 5, describing: "\(field.identifier) to read '\(text)'", {
                ((field.value as? String) ?? "") == text
            }) { return }
            print("[ConfigJourney] \(field.identifier) read '\(String(describing: field.value))' instead of '\(text)' on attempt \(attempt)/2.")
        }
        XCTAssertEqual(
            (field.value as? String) ?? "", text,
            "Could not set \(field.identifier) to '\(text)' — it reads '\(String(describing: field.value))'."
        )
    }

    // MARK: - Skill-tree helpers

    /// Every installed skill in `home`, as `<category>/<skill>` keys.
    ///
    /// Depth two, because that is the shape of `~/.hermes/skills/`; see
    /// `testFixtureSkillIsListedAndUninstalls`.
    private static func installedSkillPaths(inHome home: String?) -> Set<String> {
        guard let home else { return [] }
        let fm = FileManager.default
        let skillsDir = (home as NSString).appendingPathComponent("skills")
        var found: Set<String> = []
        for category in ((try? fm.contentsOfDirectory(atPath: skillsDir)) ?? [])
        where !category.hasPrefix(".") {
            let categoryDir = (skillsDir as NSString).appendingPathComponent(category)
            for skill in ((try? fm.contentsOfDirectory(atPath: categoryDir)) ?? [])
            where !skill.hasPrefix(".") {
                found.insert("\(category)/\(skill)")
            }
        }
        return found
    }

    // MARK: - Config file helpers

    private var configPath: String {
        (isolatedHome as NSString).appendingPathComponent("config.yaml")
    }

    /// Read one scalar out of the isolated home's `config.yaml`.
    ///
    /// A deliberately small indentation-aware reader rather than a YAML
    /// dependency: the UI-test bundle links neither the app nor ScarfCore
    /// (that is also why `Sections.json` exists), and Hermes writes this
    /// file with plain two-space nesting and unquoted or single-quoted
    /// scalars. Anything more exotic than `a: b` / `a:\n  b: c` is out of
    /// scope on purpose — a test helper that silently half-parses is
    /// worse than one that only handles what it claims.
    ///
    /// Returns nil when the key is absent or the file is unreadable;
    /// callers compare against an expected value, so absent and wrong
    /// both read as "not yet".
    private func configValue(atPath keyPath: [String]) -> String? {
        guard !keyPath.isEmpty,
              let text = try? String(contentsOfFile: configPath, encoding: .utf8)
        else { return nil }

        var depth = 0
        var remaining = keyPath
        for rawLine in text.components(separatedBy: "\n") {
            guard let key = remaining.first else { break }
            let indent = rawLine.prefix { $0 == " " }.count
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // A shallower line than the block we are inside means the
            // parent key ended without the child appearing.
            if indent < depth * 2 { return nil }
            guard indent == depth * 2, trimmed.hasPrefix("\(key):") else { continue }

            let value = trimmed
                .dropFirst(key.count + 1)
                .trimmingCharacters(in: .whitespaces)
            remaining.removeFirst()
            if remaining.isEmpty {
                return Self.unquote(value)
            }
            // Descend: the key must have been a mapping, i.e. no inline
            // value.
            guard value.isEmpty else { return nil }
            depth += 1
        }
        return nil
    }

    private static func unquote(_ value: String) -> String {
        for quote in ["'", "\""] where value.count >= 2
            && value.hasPrefix(quote) && value.hasSuffix(quote) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    // MARK: - Waiting helpers

    /// Poll `condition` until it is true or `timeout` elapses.
    ///
    /// `XCTNSPredicateExpectation` rather than a sleep loop, for the same
    /// reason the base class uses it for `XCUIApplication.state`: it polls
    /// on the runner's own schedule and needs no KVO from the thing being
    /// observed — and this target has a standing no-`Thread.sleep` rule.
    private func waitUntil(
        timeout: TimeInterval,
        describing what: String,
        _ condition: @escaping () -> Bool
    ) -> Bool {
        if condition() { return true }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        expectation.expectationDescription = "Waiting for \(what)"
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        // `waitForExistence` only waits for APPEARANCE, so a disappearance
        // needs its own predicate expectation.
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// HEAD the host with a hard timeout, so an offline machine skips in
    /// seconds instead of hanging on a 75 s connect timeout.
    private static func hostIsReachable(_ urlString: String, timeout: TimeInterval) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        URLSession(configuration: configuration).dataTask(with: request) { _, response, _ in
            reachable = (response as? HTTPURLResponse) != nil
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        return reachable
    }

    private func attach(_ app: XCUIApplication, named name: String, keepAlways: Bool = false) {
        let shot = XCTAttachment(screenshot: windowScreenshot(app))
        shot.name = name
        shot.lifetime = keepAlways ? .keepAlways : .deleteOnSuccess
        add(shot)
    }
}
