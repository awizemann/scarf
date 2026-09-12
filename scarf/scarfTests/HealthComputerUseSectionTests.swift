import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Phase 4 of the Hermes v0.21.1 parity work (finding C8): the Health
/// pane's Computer Use card, built from `hermes computer-use permissions
/// status --json`.
///
/// The card's whole value is telling a Mac user which TCC grant is
/// missing, so the rules it must not break are:
///   - a `null` permission is UNKNOWN, never "denied";
///   - the macOS grant rows do not render on a host with no TCC model
///     (a remote Linux server), where readiness is driver health;
///   - a missing driver is one clear row, not two false denials.
@Suite struct HealthComputerUseSectionTests {

    private func status(
        platform: String = "darwin",
        supported: Bool = true,
        installed: Bool = true,
        version: String? = "cua-driver 0.4.2",
        ready: Bool? = true,
        canGrant: Bool = true,
        accessibility: Bool? = true,
        screenRecording: Bool? = true,
        capturable: Bool?? = nil,
        checks: [HermesComputerUseCheck] = [],
        error: String? = nil
    ) -> HermesComputerUseStatus {
        HermesComputerUseStatus(
            platform: platform, platformSupported: supported, installed: installed,
            version: version, ready: ready, canGrant: canGrant,
            accessibility: accessibility, screenRecording: screenRecording,
            // Default: mirror the grant, which is what the driver reports in
            // the ordinary case. `capturable:` overrides it, including with
            // an explicit nil.
            screenRecordingCapturable: capturable ?? screenRecording,
            checks: checks, error: error
        )
    }

    // MARK: - `screen_recording_capturable` (tri-state, like the grant rows)

    /// Granted-but-not-capturable: a stale TCC entry records the grant while
    /// capture still fails. Hermes's own doctor makes this row outrank the
    /// plain pass (`tools/computer_use/doctor.py:204-207` @ v2026.9.7); the
    /// card said "Screen Recording granted" and stopped, which is the exact
    /// wrong answer for a user whose screenshots are black.
    @Test func grantedButNotCapturableIsAnError() {
        let section = HealthViewModel.computerUseSection(
            status(screenRecording: true, capturable: .some(false)))
        let row = section.checks.first { $0.label == "Screen Recording granted but not capturable" }
        #expect(row?.status == .error)
        #expect(row?.detail?.contains("re-grant") == true)
        // The plain grant row is still there — this one is additional.
        #expect(section.checks.contains { $0.label == "Screen Recording granted" })
    }

    @Test func capturableTrueIsAnOKRow() {
        let section = HealthViewModel.computerUseSection(
            status(screenRecording: true, capturable: .some(true)))
        #expect(section.checks.first { $0.label == "Screen Recording capturable" }?.status == .ok)
    }

    /// nil means Scarf could not ask — a warning carrying the probe's own
    /// reason, never a denial. Same tri-state rule as the two grant rows.
    @Test func capturableNilIsUnknownNotDenied() {
        let section = HealthViewModel.computerUseSection(
            status(screenRecording: true, capturable: .some(nil),
                   error: "cua-driver permissions status timed out"))
        let row = section.checks.first { $0.label == "Screen Recording capture unknown" }
        #expect(row?.status == .warning)
        #expect(row?.detail == "cua-driver permissions status timed out")
        #expect(!section.checks.contains { $0.label.contains("not capturable") })
    }

    /// With no Screen Recording grant, the grant row is the whole story —
    /// a second unknown row underneath it is noise, and on a denied grant
    /// the capturable field is meaningless.
    @Test func capturableRowIsAbsentWhenScreenRecordingIsNotGranted() {
        for grant: Bool? in [false, nil] {
            let section = HealthViewModel.computerUseSection(
                status(ready: false, screenRecording: grant, capturable: .some(nil)))
            #expect(!section.checks.contains { $0.label.contains("capturable") },
                    "grant=\(String(describing: grant))")
            #expect(!section.checks.contains { $0.label.contains("capture unknown") },
                    "grant=\(String(describing: grant))")
        }
    }

    @Test func grantedMacHostReadsAllOK() {
        let section = HealthViewModel.computerUseSection(status())
        #expect(section.title == "Computer Use")
        #expect(section.checks.allSatisfy { $0.status == .ok })
        #expect(section.checks.contains { $0.label == "Accessibility granted" })
        #expect(section.checks.contains { $0.label == "Screen Recording granted" })
    }

    @Test func deniedScreenRecordingIsAnErrorWithTheGrantCommand() {
        let section = HealthViewModel.computerUseSection(status(ready: false, screenRecording: false))
        let row = section.checks.first { $0.label == "Screen Recording not granted" }
        #expect(row?.status == .error)
        #expect(row?.detail?.contains("permissions grant") == true)
    }

    /// The important one: `null` is "we couldn't ask", and must never be
    /// rendered as a denial with a "go grant this" instruction.
    @Test func unknownPermissionIsAWarningNotADenial() {
        let section = HealthViewModel.computerUseSection(
            status(ready: nil, accessibility: nil, screenRecording: nil,
                   error: "cua-driver permissions status timed out"))
        #expect(section.checks.contains { $0.label == "Accessibility unknown" && $0.status == .warning })
        #expect(section.checks.contains { $0.label == "Screen Recording unknown" && $0.status == .warning })
        #expect(!section.checks.contains { $0.label.contains("not granted") })
        // The probe error is surfaced as the reason, then once more as its
        // own row so it is visible even if the labels are skimmed.
        #expect(section.checks.contains { $0.label == "Probe error" })
    }

    /// A remote Linux host has no TCC model — the two grant rows would be
    /// meaningless there, so Hermes's own CLI branches and so does this.
    @Test func nonMacHostShowsDriverHealthInsteadOfGrantRows() {
        let section = HealthViewModel.computerUseSection(
            status(platform: "linux", canGrant: false, accessibility: nil, screenRecording: nil))
        #expect(!section.checks.contains { $0.label.contains("Accessibility") })
        #expect(!section.checks.contains { $0.label.contains("Screen Recording") })
        let health = section.checks.first { $0.label == "Driver healthy" }
        #expect(health?.status == .ok)
        #expect(health?.detail?.contains("linux") == true)
    }

    @Test func missingDriverIsOneRowNotTwoFalseDenials() throws {
        let section = HealthViewModel.computerUseSection(
            status(installed: false, version: nil, ready: nil, accessibility: nil, screenRecording: nil))
        try #require(section.checks.count == 1)
        #expect(section.checks[0].label == "cua-driver not installed")
        #expect(section.checks[0].status == .warning)
    }

    @Test func unsupportedPlatformSaysSoAndStopsThere() throws {
        let section = HealthViewModel.computerUseSection(
            status(platform: "freebsd13", supported: false, installed: false,
                   version: nil, ready: nil, canGrant: false,
                   accessibility: nil, screenRecording: nil))
        try #require(section.checks.count == 1)
        #expect(section.checks[0].label.contains("freebsd13"))
    }

    /// Non-`ok` driver probes are appended verbatim; `ok` ones are not
    /// noise on a health card that already says "installed".
    @Test func onlyProblemChecksAreSurfaced() {
        let section = HealthViewModel.computerUseSection(status(checks: [
            HermesComputerUseCheck(label: "Bundle identity", status: "ok", message: ""),
            HermesComputerUseCheck(label: "Screenshot probe", status: "warn", message: "empty image"),
            HermesComputerUseCheck(label: "Version", status: "fail", message: "too old"),
        ]))
        #expect(!section.checks.contains { $0.label == "Bundle identity" })
        #expect(section.checks.first { $0.label == "Screenshot probe" }?.status == .warning)
        #expect(section.checks.first { $0.label == "Version" }?.status == .error)
    }
}

/// Phase 4 finding B2: `hermes debug share` could never succeed from
/// Scarf. From v0.18 `_confirm_upload` exits 1 on a non-TTY without
/// `--yes`, and every Scarf invocation is non-TTY.
@Suite struct HealthDebugShareArgvTests {

    @Test func v0211HostGetsTheYesFlag() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        #expect(HealthViewModel.debugShareArguments(local: false, capabilities: caps)
            == ["debug", "share", "-y"])
    }

    /// A pre-v0.18 host has neither the flag nor the non-TTY gate. Sending
    /// `-y` there is an argparse error that breaks a command which worked.
    @Test func preV018HostOmitsTheYesFlag() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.17.0 (2026.6.19)")
        #expect(HealthViewModel.debugShareArguments(local: false, capabilities: caps)
            == ["debug", "share"])
    }

    /// Unknown host: fail closed on the flag, same as every other gate.
    @Test func undetectedHostOmitsTheYesFlag() {
        #expect(HealthViewModel.debugShareArguments(local: false, capabilities: .empty)
            == ["debug", "share"])
    }

    /// `--local` never carries `-y`: there is no upload to confirm, and the
    /// flag predates every host Scarf supports so it needs no gate.
    @Test func localNeverConfirmsAnUpload() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        #expect(HealthViewModel.debugShareArguments(local: true, capabilities: caps)
            == ["debug", "share", "--local"])
        #expect(HealthViewModel.debugShareArguments(local: true, capabilities: .empty)
            == ["debug", "share", "--local"])
    }
}
