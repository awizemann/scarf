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
        Group {
            switch viewModel.stage {
            case .idle, .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading configuration…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minWidth: 560, minHeight: 320)
                .padding()
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
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Saving…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minWidth: 560, minHeight: 320)
                .padding()
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
                .frame(minWidth: 560, minHeight: 280)
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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minWidth: 560, minHeight: 280)
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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minWidth: 560, minHeight: 280)
                .padding()
            }
        }
        .task { viewModel.begin() }
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 560, minHeight: 280)
        .padding()
    }
}
