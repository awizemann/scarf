import Foundation

/// One probe from cua-driver's health matrix, as folded into the status
/// payload by `tools/computer_use/permissions.py::_doctor`:
/// `{"label": …, "status": …, "message": …}` (every value stringified
/// Hermes-side). `status` is cua-driver's vocabulary, not Hermes's, so
/// Scarf renders it rather than switching on it — anything that isn't
/// `"ok"` is surfaced.
public struct HermesComputerUseCheck: Sendable, Equatable, Identifiable {
    public var id: String { label + status }
    public let label: String
    public let status: String
    public let message: String

    public init(label: String, status: String, message: String) {
        self.label = label
        self.status = status
        self.message = message
    }

    /// Hermes's own test for "worth showing": `if c["status"] != "ok"`.
    public var isProblem: Bool { severity != .ok }

    /// How loudly to render this probe.
    ///
    /// The `status` string is **cua-driver's** vocabulary, folded through
    /// `_doctor` verbatim (`str(p.get("status", ""))`) — Hermes neither
    /// defines nor validates it. "Not `ok`" therefore does not mean
    /// "failing": a driver that reports `skipped`, `n/a` or a value invented
    /// in a later release would be painted as a red error telling the user
    /// something is broken when nothing is. Only the failure vocabulary
    /// Hermes itself uses for probe rows (`hermes_cli/doctor_connectivity.py:29`
    /// — `ok` / `warn` / `fail`) reads as a fault; anything unrecognised is
    /// shown, quietly, as a note.
    public var severity: Severity {
        switch status.trimmingCharacters(in: .whitespaces).lowercased() {
        case "ok", "pass", "passed", "good", "success", "":
            return .ok
        case "fail", "failed", "error", "bad", "critical":
            return .failure
        case "warn", "warning", "degraded":
            return .warning
        default:
            return .unknown
        }
    }

    public enum Severity: Sendable, Equatable {
        /// Healthy — not shown at all.
        case ok
        /// A known-bad probe: render as an error.
        case failure
        /// A known-degraded probe: render as a warning.
        case warning
        /// A spelling this Scarf doesn't know. Shown, but never as a fault.
        case unknown
    }
}

/// `hermes computer-use permissions status --json` — the normalized
/// Computer Use readiness payload.
///
/// From `tools/computer_use/permissions.py::computer_use_status`, whose
/// docstring calls the key order "an API payload contract":
///
/// ```python
/// out = {"platform": plat, "platform_supported": plat in _RUNTIME_PLATFORMS,
///        "installed": bool(binary), "version": None, "ready": None,
///        "can_grant": plat == "darwin", "checks": [], "source": None,
///        "error": None, **{k: None for k in _BOOLS}}
/// ```
///
/// where `_BOOLS` is `("accessibility", "screen_recording",
/// "screen_recording_capturable")`.
///
/// Three things a caller must respect:
/// - **The booleans are tri-state.** `None` means *unknown* (driver
///   missing, probe failed) — not "denied". A UI that renders nil as ❌
///   tells the user to grant a permission that may already be granted.
/// - **`ready` is the single readiness signal**, and it means different
///   things per platform: on macOS both TCC grants, elsewhere driver
///   health. `can_grant` is macOS-only.
/// - **Exit 1 just means not ready** (`sys.exit(0 if st["ready"] else 1)`),
///   so stdout is parsed regardless of exit code.
///
/// The payload has been shape-stable since v0.18 — see
/// `HermesCapabilities.hasComputerUsePermissionsJSON`.
public struct HermesComputerUseStatus: Sendable, Equatable {
    /// Python's `sys.platform` for the HOST Hermes runs on — `darwin`,
    /// `win32`, `linux`. A remote Linux server is the reason this is read
    /// rather than assumed: Scarf runs on a Mac, the host may not be one.
    public let platform: String
    public let platformSupported: Bool
    public let installed: Bool
    public let version: String?
    /// Tri-state: nil = unknown.
    public let ready: Bool?
    /// macOS only — there is no TCC model to grant elsewhere.
    public let canGrant: Bool
    public let accessibility: Bool?
    public let screenRecording: Bool?
    public let screenRecordingCapturable: Bool?
    public let checks: [HermesComputerUseCheck]
    /// Probe failure text (`cua-driver permissions status failed: …`,
    /// `… timed out`). Non-nil means the booleans above are unknown for a
    /// reason worth showing.
    public let error: String?

    public init(
        platform: String,
        platformSupported: Bool,
        installed: Bool,
        version: String?,
        ready: Bool?,
        canGrant: Bool,
        accessibility: Bool?,
        screenRecording: Bool?,
        screenRecordingCapturable: Bool?,
        checks: [HermesComputerUseCheck],
        error: String?
    ) {
        self.platform = platform
        self.platformSupported = platformSupported
        self.installed = installed
        self.version = version
        self.ready = ready
        self.canGrant = canGrant
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.screenRecordingCapturable = screenRecordingCapturable
        self.checks = checks
        self.error = error
    }

    /// Whether this host has macOS TCC permission toggles at all. False on
    /// a remote Linux/Windows host, where the permission rows are
    /// meaningless and readiness is driver health instead.
    public var hasTCCPermissions: Bool { canGrant }

    /// Parse the `--json` stdout. `nil` when there is no payload — an
    /// older host, an argparse error, a transport failure — so a caller
    /// can hide the card rather than paint "not installed" over a host it
    /// never managed to ask.
    public static func parse(_ output: String) -> HermesComputerUseStatus? {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}"),
              start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              // `platform` is the one key present in every branch of
              // `computer_use_status`, including the early return. Without
              // it this isn't that payload.
              let platform = root["platform"] as? String
        else { return nil }
        let checks: [HermesComputerUseCheck] = (root["checks"] as? [Any] ?? []).compactMap { row in
            guard let d = row as? [String: Any] else { return nil }
            return HermesComputerUseCheck(
                label: d["label"] as? String ?? "",
                status: d["status"] as? String ?? "",
                message: d["message"] as? String ?? ""
            )
        }
        return HermesComputerUseStatus(
            platform: platform,
            platformSupported: root["platform_supported"] as? Bool ?? false,
            installed: root["installed"] as? Bool ?? false,
            version: root["version"] as? String,
            ready: root["ready"] as? Bool,
            canGrant: root["can_grant"] as? Bool ?? false,
            accessibility: root["accessibility"] as? Bool,
            screenRecording: root["screen_recording"] as? Bool,
            screenRecordingCapturable: root["screen_recording_capturable"] as? Bool,
            checks: checks,
            error: root["error"] as? String
        )
    }
}
