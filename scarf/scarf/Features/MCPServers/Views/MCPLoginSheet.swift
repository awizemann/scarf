import SwiftUI
import ScarfCore
import ScarfDesign

/// Runs `hermes mcp login <name>` and shows what it says (v0.21.1 `--flow`).
///
/// The device-code branch is the reason this is a sheet and not a fire-and-
/// forget menu item: Hermes prints a verification URL AND a short user code
/// that the person has to read and type somewhere else, then blocks polling
/// the token endpoint until they do. Swallowing that output — or showing a
/// spinner over it — makes the flow impossible to complete.
struct MCPLoginSheet: View {
    let serverName: String
    /// The server's configured `oauth.flow`, used as the initial selection so
    /// the sheet opens on what the config already says.
    let configuredFlow: String?
    /// v0.21.1 gate. When false the sheet sends no `--flow` at all (the flag
    /// does not exist on the host) and hides the picker.
    let supportsFlowOverride: Bool
    let context: ServerContext
    let onFinished: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var controller: MCPLoginController
    @State private var flow: String

    init(
        serverName: String,
        configuredFlow: String?,
        supportsFlowOverride: Bool,
        context: ServerContext,
        onFinished: @escaping (Bool) -> Void
    ) {
        self.serverName = serverName
        self.configuredFlow = configuredFlow
        self.supportsFlowOverride = supportsFlowOverride
        self.context = context
        self.onFinished = onFinished
        _controller = State(initialValue: MCPLoginController(context: context))
        // Clamp to the two values `mcp_config.py:640` accepts. An unknown
        // spelling round-trips in the model on purpose, but selecting it here
        // would leave the picker with nothing highlighted and then send a
        // value Hermes rejects.
        let known = ["browser", "device"]
        _flow = State(initialValue: known.contains(configuredFlow ?? "") ? configuredFlow! : "browser")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            Text("Sign in to \(serverName)")
                .scarfStyle(.title2)

            if supportsFlowOverride {
                Picker("Flow", selection: $flow) {
                    Text("Browser (PKCE redirect)").tag("browser")
                    Text("Device code").tag("device")
                }
                .pickerStyle(.segmented)
                .disabled(controller.isRunning)
            }

            if let prompt = controller.devicePrompt {
                devicePromptCard(prompt)
            }

            ScrollView {
                Text(controller.output.isEmpty ? "Waiting for hermes…" : controller.output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 180)
            .padding(ScarfSpace.s2)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                    .fill(ScarfColor.backgroundSecondary)
            )

            if let error = controller.errorMessage {
                Text(error)
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.danger)
                    .textSelection(.enabled)
            } else if controller.succeeded == true {
                Text("Signed in.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.success)
            }

            HStack {
                Spacer()
                Button(controller.isRunning ? "Cancel" : "Close") {
                    controller.stop()
                    onFinished(controller.succeeded == true)
                    dismiss()
                }
                Button(controller.succeeded == nil ? "Sign In" : "Try Again") {
                    // No `--flow` on a pre-v0.21.1 host: the flag does not
                    // exist there and argparse would exit 2.
                    controller.start(server: serverName, flow: supportsFlowOverride ? flow : nil)
                }
                .buttonStyle(ScarfPrimaryButton())
                .disabled(controller.isRunning)
            }
        }
        .padding(ScarfSpace.s5)
        .frame(width: 560)
        .onDisappear { controller.stop() }
    }

    /// The two things the person actually needs, lifted out of the log: where
    /// to go and what to type. The code is rendered monospaced and selectable
    /// because it is transcribed by hand.
    @ViewBuilder
    private func devicePromptCard(_ prompt: HermesMCPDevicePrompt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Open this on any device and enter the code:")
                .scarfStyle(.footnote)
                .foregroundStyle(ScarfColor.foregroundMuted)
            HStack(spacing: ScarfSpace.s2) {
                Text(prompt.verificationURL)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Open") { controller.openVerificationURL() }
                    .controlSize(.small)
            }
            HStack(spacing: ScarfSpace.s2) {
                Text(prompt.userCode)
                    .font(.system(.title3, design: .monospaced, weight: .bold))
                    .textSelection(.enabled)
                Button("Copy") { controller.copyUserCode() }
                    .controlSize(.small)
            }
        }
        .padding(ScarfSpace.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .fill(ScarfColor.accentTint)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Device code sign-in for \(serverName)")
    }
}
