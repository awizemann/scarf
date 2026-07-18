import Testing
import Foundation
@testable import ScarfCore

/// gh#112 follow-up: when both the file read and the `config show` probe
/// fail, the Settings banner must say *why* — the reporter's v2.16.1
/// carried the whole fallback chain yet still showed the generic "not
/// found", because no step could run (Docker-only `hermes`, no host-side
/// wrapper). These pin the probe-outcome classification and the message
/// each topology gets.
@Suite struct CLIProbeDiagnosisTests {

    // MARK: - classifyProbe

    @Test("Exit 127 means no hermes on the host's non-interactive PATH")
    func exit127IsCLINotFound() {
        let d = HermesConfigReader.classifyProbe(exitCode: 127, stdout: "", stderr: "sh: hermes: not found")
        #expect(d == .cliNotFound)
    }

    @Test("A non-zero exit carries the last output line — tracebacks end with the real error")
    func nonZeroExitCarriesLastLine() {
        let traceback = """
        Traceback (most recent call last):
          File "hermes", line 10, in <module>
        docker.errors.NotFound: container 'hermes' is not running
        """
        let d = HermesConfigReader.classifyProbe(exitCode: 1, stdout: "", stderr: traceback)
        #expect(d == .commandFailed(exitCode: 1, detail: "docker.errors.NotFound: container 'hermes' is not running"))
    }

    @Test("Stderr-silent failures fall back to stdout's last line")
    func silentStderrFallsBackToStdout() {
        let d = HermesConfigReader.classifyProbe(exitCode: 2, stdout: "usage: hermes ...\nerror: unknown command\n", stderr: "")
        #expect(d == .commandFailed(exitCode: 2, detail: "error: unknown command"))
    }

    @Test("Exit 0 after a failed parse means the output format is unrecognized")
    func exitZeroIsUnparsedOutput() {
        let d = HermesConfigReader.classifyProbe(exitCode: 0, stdout: "Hermes 0.15.1 configuration\nmodel: something", stderr: "")
        #expect(d == .outputUnparsed)
    }

    // MARK: - Settings banner selection

    @Test("The Docker-no-wrapper topology gets the wrapper-script walkthrough")
    @MainActor
    func cliNotFoundTeachesTheWrapper() {
        let m = IOSSettingsViewModel.unreachableConfigMessage(
            path: "~/.hermes/config.yaml", host: "100.68.160.25", diagnosis: .cliNotFound)
        #expect(m.contains("no `hermes` command is reachable over SSH"))
        #expect(m.contains("docker compose exec -T"))
        #expect(m.contains("Advanced → Hermes binary"))
    }

    @Test("A failing CLI surfaces its exit code and final error line")
    @MainActor
    func commandFailureSurfacesDetail() {
        let m = IOSSettingsViewModel.unreachableConfigMessage(
            path: "~/.hermes/config.yaml", host: "host",
            diagnosis: .commandFailed(exitCode: 1, detail: "container 'hermes' is not running"))
        #expect(m.contains("exit 1"))
        #expect(m.contains("container 'hermes' is not running"))
    }

    @Test("Unparsed output asks for a report instead of claiming 'not found'")
    @MainActor
    func unparsedOutputAsksForReport() {
        let m = IOSSettingsViewModel.unreachableConfigMessage(
            path: "~/.hermes/config.yaml", host: "host", diagnosis: .outputUnparsed)
        #expect(m.contains("couldn't find a model line"))
        #expect(!m.contains("not found on"))
    }

    @Test("No diagnosis (local context) keeps the original message")
    @MainActor
    func nilDiagnosisKeepsOriginalMessage() {
        let m = IOSSettingsViewModel.unreachableConfigMessage(
            path: "~/.hermes/config.yaml", host: "host", diagnosis: nil)
        #expect(m == "`~/.hermes/config.yaml` not found on host. Once Hermes is configured on this host, Settings will light up.")
    }
}
