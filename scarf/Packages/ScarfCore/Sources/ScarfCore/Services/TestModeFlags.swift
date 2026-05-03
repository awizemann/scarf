import Foundation

/// Process-wide toggles for test-mode launches.
///
/// Read `CommandLine.arguments` once at first access and cache the result so
/// any code path can ask `TestModeFlags.shared.isTestMode` without paying for
/// a re-scan. The harness sets `--scarf-test-mode` from XCUITest's
/// `XCUIApplication.launchArguments` and pairs it with `SCARF_HERMES_HOME`
/// (read by `HermesProfileResolver`) to drive Scarf against an isolated
/// Hermes home.
///
/// The flags themselves don't do anything on their own — they're hook points
/// for production code paths to gate behavior. v1 lands the wiring; the
/// gating sites (Sparkle update prompt, capability live-probe, first-run
/// walkthrough) are added incrementally as the harness exercises them and
/// surfaces flakes.
public struct TestModeFlags: Sendable {
    /// True when the process was launched with `--scarf-test-mode`. Read
    /// once from `CommandLine.arguments`; never mutated.
    public let isTestMode: Bool

    /// Default singleton — cached on first access. Production code reads
    /// this; tests that need a different shape construct their own value.
    public static let shared: TestModeFlags = TestModeFlags(
        arguments: CommandLine.arguments
    )

    /// Constructor exposed for tests so a synthetic argv can be passed
    /// without involving the real `CommandLine`. Production callers use
    /// `.shared`.
    public init(arguments: [String]) {
        self.isTestMode = arguments.contains("--scarf-test-mode")
    }
}
