import Foundation

struct HealthCheck: Identifiable {
    let id = UUID()
    let label: String
    let status: CheckStatus
    let detail: String?

    enum CheckStatus {
        case ok
        case warning
        case error
    }
}

struct HealthSection: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let checks: [HealthCheck]
}

@Observable
final class HealthViewModel {
    private let fileService = HermesFileService()

    var version = ""
    var updateInfo = ""
    var hasUpdate = false
    var statusSections: [HealthSection] = []
    var doctorSections: [HealthSection] = []
    var issueCount = 0
    var warningCount = 0
    var okCount = 0
    var isLoading = false
    var hermesRunning = false
    var hermesPID: pid_t?
    var actionMessage: String?

    /// Text output from `hermes dump` / `hermes debug share`. Shown in an expandable panel.
    var diagnosticsOutput: String = ""
    var isSharingDebug = false

    func load() {
        isLoading = true
        refreshProcessStatus()
        loadVersion()
        let statusOutput = runHermes(["status"]).output
        statusSections = parseOutput(statusOutput)
        let doctorOutput = runHermes(["doctor"]).output
        doctorSections = parseOutput(doctorOutput)
        computeCounts()
        isLoading = false
    }

    func refreshProcessStatus() {
        hermesPID = fileService.hermesPID()
        hermesRunning = hermesPID != nil
    }

    func stopHermes() {
        fileService.stopHermes()
        actionMessage = "Stop signal sent"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshProcessStatus()
            self?.actionMessage = nil
        }
    }

    func startHermes() {
        runHermes(["gateway", "start"])
        actionMessage = "Start requested"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.refreshProcessStatus()
            self?.actionMessage = nil
        }
    }

    func restartHermes() {
        fileService.stopHermes()
        actionMessage = "Restarting..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.runHermes(["gateway", "start"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.refreshProcessStatus()
                self?.actionMessage = nil
            }
        }
    }

    private func loadVersion() {
        let output = runHermes(["version"]).output
        let lines = output.components(separatedBy: "\n")
        version = lines.first ?? ""
        if let updateLine = lines.first(where: { $0.contains("commits behind") }) {
            updateInfo = updateLine.trimmingCharacters(in: .whitespaces)
            hasUpdate = true
        } else {
            updateInfo = ""
            hasUpdate = false
        }
    }

    private func parseOutput(_ output: String) -> [HealthSection] {
        var sections: [HealthSection] = []
        var currentTitle = ""
        var currentChecks: [HealthCheck] = []

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("◆ ") {
                if !currentTitle.isEmpty {
                    sections.append(HealthSection(
                        title: currentTitle,
                        icon: iconForSection(currentTitle),
                        checks: currentChecks
                    ))
                }
                currentTitle = String(trimmed.dropFirst(2))
                currentChecks = []
                continue
            }

            if trimmed.hasPrefix("✓ ") {
                let text = String(trimmed.dropFirst(2))
                let (label, detail) = splitCheck(text)
                currentChecks.append(HealthCheck(label: label, status: .ok, detail: detail))
            } else if trimmed.hasPrefix("⚠ ") || trimmed.hasPrefix("⚠") {
                let text = trimmed.replacingOccurrences(of: "⚠ ", with: "").replacingOccurrences(of: "⚠", with: "")
                let (label, detail) = splitCheck(text)
                currentChecks.append(HealthCheck(label: label, status: .warning, detail: detail))
            } else if trimmed.hasPrefix("✗ ") {
                let text = String(trimmed.dropFirst(2))
                let (label, detail) = splitCheck(text)
                currentChecks.append(HealthCheck(label: label, status: .error, detail: detail))
            } else if trimmed.hasPrefix("→ ") || trimmed.hasPrefix("Error:") {
                if !currentChecks.isEmpty {
                    let last = currentChecks.removeLast()
                    let extra = trimmed.replacingOccurrences(of: "→ ", with: "").replacingOccurrences(of: "Error:", with: "").trimmingCharacters(in: .whitespaces)
                    let combined = [last.detail, extra].compactMap { $0 }.joined(separator: " ")
                    currentChecks.append(HealthCheck(label: last.label, status: last.status, detail: combined))
                }
            } else if !trimmed.isEmpty && trimmed.contains(":") && !trimmed.hasPrefix("┌") && !trimmed.hasPrefix("│") && !trimmed.hasPrefix("└") && !trimmed.hasPrefix("─") && !trimmed.hasPrefix("Run ") && !trimmed.hasPrefix("Found ") && !trimmed.hasPrefix("Tip:") {
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    let val = parts[1].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty && key.count < 30 {
                        currentChecks.append(HealthCheck(label: key, status: .ok, detail: val))
                    }
                }
            }
        }

        if !currentTitle.isEmpty {
            sections.append(HealthSection(
                title: currentTitle,
                icon: iconForSection(currentTitle),
                checks: currentChecks
            ))
        }

        return sections
    }

    private func splitCheck(_ text: String) -> (String, String?) {
        if let parenStart = text.firstIndex(of: "(") {
            let label = text[text.startIndex..<parenStart].trimmingCharacters(in: .whitespaces)
            let detail = String(text[parenStart...]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            return (label, detail)
        }
        return (text, nil)
    }

    private func computeCounts() {
        let allChecks = (statusSections + doctorSections).flatMap(\.checks)
        okCount = allChecks.filter { $0.status == .ok }.count
        warningCount = allChecks.filter { $0.status == .warning }.count
        issueCount = allChecks.filter { $0.status == .error }.count
    }

    private func iconForSection(_ title: String) -> String {
        switch title {
        case "Environment": return "gearshape.2"
        case "API Keys": return "key"
        case "Auth Providers": return "person.badge.key"
        case "API-Key Providers": return "key.horizontal"
        case "Terminal Backend": return "terminal"
        case "Messaging Platforms": return "bubble.left.and.bubble.right"
        case "Gateway Service": return "antenna.radiowaves.left.and.right"
        case "Scheduled Jobs": return "clock.arrow.2.circlepath"
        case "Sessions": return "text.bubble"
        case "Python Environment": return "chevron.left.forwardslash.chevron.right"
        case "Required Packages": return "shippingbox"
        case "Configuration Files": return "doc.text"
        case "Directory Structure": return "folder"
        case "External Tools": return "wrench"
        case "API Connectivity": return "wifi"
        case "Submodules": return "arrow.triangle.branch"
        case "Tool Availability": return "wrench.and.screwdriver"
        case "Skills Hub": return "lightbulb"
        case "Honcho Memory": return "brain"
        default: return "circle"
        }
    }

    /// Capture `hermes dump` output — a setup summary used for debugging / support.
    /// Does NOT upload anything.
    func runDump() {
        actionMessage = "Running dump…"
        let result = runHermes(["dump"])
        diagnosticsOutput = result.output
        actionMessage = result.exitCode == 0 ? "Dump captured" : "Dump failed"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.actionMessage = nil
        }
    }

    /// Upload a debug report via `hermes debug share`. THIS UPLOADS DATA to Nous
    /// Research support infrastructure — caller must confirm with the user first.
    func runDebugShare() {
        isSharingDebug = true
        actionMessage = "Uploading debug report…"
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: ["debug", "share"], timeout: 120)
            await MainActor.run {
                self.isSharingDebug = false
                self.diagnosticsOutput = result.output
                self.actionMessage = result.exitCode == 0 ? "Upload complete" : "Upload failed"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    self?.actionMessage = nil
                }
            }
        }
    }

    @discardableResult
    private func runHermes(_ arguments: [String]) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: HermesPaths.hermesBinary)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
        } catch {
            return ("", -1)
        }
    }
}
