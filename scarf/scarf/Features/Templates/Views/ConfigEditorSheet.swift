import ScarfCore
import ScarfDesign
import SwiftUI

/// Post-install configuration editor. Thin wrapper around the same
/// `TemplateConfigSheet` the install flow uses — owns a
/// `TemplateConfigEditorViewModel` that loads the cached manifest +
/// current values from `<project>/.scarf/`, feeds them to the form,
/// and writes the edited values back to `config.json` on commit.
///
/// Entry points: right-click on the project list (when the project has
/// a cached manifest) and a button on the dashboard header (shown
/// only when `isConfigurable` is true).
struct ConfigEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: TemplateConfigEditorViewModel

    init(context: ServerContext, project: ProjectEntry) {
        _viewModel = State(
            initialValue: TemplateConfigEditorViewModel(
                context: context,
                project: project
            )
        )
    }

    var body: some View {
        // Single outer frame for every stage. Per-case frames used to
        // shrink the sheet from 480pt (editing) to 280pt (succeeded /
        // notConfigurable / failed) on stage transition, which forced
        // AppKit to relayout the sheet container mid-flight and
        // produced `_NSDetectedLayoutRecursion` on macOS — issue #75.
        // Stabilizing the size at the largest stage's intrinsic
        // (560 x 480, matching `TemplateConfigSheet`) means stage
        // transitions only change content, never container geometry.
        VStack(spacing: 0) {
            switch viewModel.stage {
            case .idle, .loading:
                centeredMessage("Loading configuration…", showSpinner: true)
            case .editing:
                if let form = viewModel.formViewModel,
                   let manifest = viewModel.manifest {
                    TemplateConfigSheet(
                        viewModel: form,
                        title: "Configure \(manifest.name)",
                        commitLabel: "Save",
                        project: nil,  // edit mode; VM carries the project
                        onCommit: { values in
                            viewModel.save(values: values)
                        },
                        onCancel: {
                            viewModel.cancel()
                            dismiss()
                        }
                    )
                } else {
                    unexpectedState
                }
            case .saving:
                centeredMessage("Saving…", showSpinner: true)
            case .succeeded:
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("Configuration saved").font(.title2.bold())
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(ScarfPrimaryButton())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Couldn't save").font(.title2.bold())
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(ScarfPrimaryButton())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            case .notConfigurable:
                VStack(spacing: 16) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No configuration")
                        .font(.title3.bold())
                    Text("This project wasn't installed from a schemaful template.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(ScarfPrimaryButton())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .task { viewModel.begin() }
    }

    @ViewBuilder
    private func centeredMessage(_ text: String, showSpinner: Bool) -> some View {
        VStack(spacing: 12) {
            if showSpinner { ProgressView() }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var unexpectedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Internal state inconsistency — please close and re-open.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(ScarfPrimaryButton())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 560, minHeight: 280)
        .padding()
    }
}
