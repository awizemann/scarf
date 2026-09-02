import SwiftUI
import ScarfCore

/// Terminal tab — backend plus docker/container options.
/// Heavy docker/container settings are hidden unless a container backend is selected.
struct TerminalTab: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    /// v0.14 — local draft for the docker_extra_args CSV row. Synced
    /// back to YAML via `setDockerExtraArgs(_:)`. Initialized from the
    /// config in `.onAppear` so loads after a v0.14 host upgrade
    /// surface existing values immediately.
    @State private var dockerExtraArgsDraft: String = ""

    var body: some View {
        SettingsSection(title: "Backend", icon: "terminal") {
            PickerRow(label: "Backend", selection: viewModel.config.terminalBackend, options: viewModel.terminalBackends) { viewModel.setTerminalBackend($0) }
            EditableTextField(label: "Working Dir", value: viewModel.config.terminal.cwd) { viewModel.setTerminalCwd($0) }
            StepperRow(label: "Command Timeout (s)", value: viewModel.config.terminal.timeout, range: 10...3600, step: 10) { viewModel.setTerminalTimeout($0) }
            ToggleRow(label: "Persistent Shell", isOn: viewModel.config.terminal.persistentShell) { viewModel.setPersistentShell($0) }
        }

        if isContainerBackend {
            SettingsSection(title: "Container Limits", icon: "cpu.fill") {
                StepperRow(label: "CPU Count", value: viewModel.config.terminal.containerCPU, range: 0...64) { viewModel.setContainerCPU($0) }
                StepperRow(label: "Memory (MB)", value: viewModel.config.terminal.containerMemory, range: 0...65_536, step: 256) { viewModel.setContainerMemory($0) }
                StepperRow(label: "Disk (MB)", value: viewModel.config.terminal.containerDisk, range: 0...1_048_576, step: 1024) { viewModel.setContainerDisk($0) }
                ToggleRow(label: "Persistent", isOn: viewModel.config.terminal.containerPersistent) { viewModel.setContainerPersistent($0) }
            }
        }

        if viewModel.config.terminalBackend == "docker" {
            SettingsSection(title: "Docker", icon: "shippingbox") {
                EditableTextField(label: "Image", value: viewModel.config.terminal.dockerImage) { viewModel.setDockerImage($0) }
                ToggleRow(label: "Mount CWD", isOn: viewModel.config.terminal.dockerMountCwdToWorkspace) { viewModel.setDockerMountCwd($0) }
                // v0.14 — extra args forwarded verbatim to `docker run`.
                // Comma-separated input; the setter splits + writes a
                // proper YAML list.
                if capabilitiesStore?.capabilities.hasDockerExtraArgs == true {
                    EditableTextField(
                        label: "Extra args",
                        value: dockerExtraArgsDraft
                    ) { newValue in
                        dockerExtraArgsDraft = newValue
                        viewModel.setDockerExtraArgs(newValue)
                    }
                }
                if !viewModel.config.dockerEnv.isEmpty {
                    ForEach(viewModel.config.dockerEnv.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        ReadOnlyRow(verbatimLabel: key, value: value)
                    }
                }
            }
            .onAppear {
                dockerExtraArgsDraft = viewModel.config.terminal.dockerExtraArgs.joined(separator: ", ")
            }
        }

        if viewModel.config.terminalBackend == "modal" {
            SettingsSection(title: "Modal", icon: "cloud") {
                EditableTextField(label: "Image", value: viewModel.config.terminal.modalImage) { viewModel.setModalImage($0) }
                PickerRow(label: "Mode", selection: viewModel.config.terminal.modalMode, options: ["auto", "always", "never"]) { viewModel.setModalMode($0) }
            }
        }

        if viewModel.config.terminalBackend == "daytona" {
            SettingsSection(title: "Daytona", icon: "externaldrive.connected.to.line.below") {
                EditableTextField(label: "Image", value: viewModel.config.terminal.daytonaImage) { viewModel.setDaytonaImage($0) }
            }
        }

        if viewModel.config.terminalBackend == "singularity" {
            SettingsSection(title: "Singularity", icon: "aqi.medium") {
                EditableTextField(label: "Image", value: viewModel.config.terminal.singularityImage) { viewModel.setSingularityImage($0) }
            }
        }
    }

    private var isContainerBackend: Bool {
        ["docker", "modal", "daytona", "singularity"].contains(viewModel.config.terminalBackend)
    }
}
