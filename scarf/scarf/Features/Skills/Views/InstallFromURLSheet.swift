import SwiftUI
import ScarfCore
import ScarfDesign

/// v0.12+ direct-URL skill install. Hermes accepts an HTTPS URL pointing
/// at a SKILL.md (or a tarball) and installs it under
/// `~/.hermes/skills/<category>/<name>/`. Authors who don't ship via a
/// registry can use this to share a one-off skill with a single URL.
///
/// Capability-gated upstream — SkillsView only opens this sheet when
/// `HermesCapabilities.hasSkillURLInstall` is true.
struct InstallFromURLSheet: View {
    let viewModel: SkillsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var url: String = ""
    @State private var category: String = ""
    @State private var nameOverride: String = ""

    /// Loose validity check — accept anything that starts with `https://`
    /// (HTTP gets blocked because Hermes refuses non-TLS skill URLs by
    /// default to keep MITM-injected SKILL.md off the host).
    private var isValid: Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("https://") && trimmed.count > 10
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            Text("Install Skill from URL")
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)

            Text("Paste an HTTPS URL pointing at a SKILL.md or a tarball. Hermes downloads, scans, and installs it under `~/.hermes/skills/<category>/<name>/`.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)

            VStack(alignment: .leading, spacing: 4) {
                Text("URL")
                    .scarfStyle(.captionUppercase)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                ScarfTextField("https://example.com/path/to/SKILL.md", text: $url)
                    .accessibilityLabel("URL")
            }

            DisclosureGroup("Optional overrides") {
                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Category")
                            .scarfStyle(.captionUppercase)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        ScarfTextField("e.g. productivity (defaults to `local`)", text: $category)
                            .accessibilityLabel("Category")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Skill name")
                            .scarfStyle(.captionUppercase)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        ScarfTextField("Override if SKILL.md has no `name:`", text: $nameOverride)
                            .accessibilityLabel("Skill name")
                    }
                }
                .padding(.top, ScarfSpace.s2)
            }
            .scarfStyle(.body)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(ScarfGhostButton())
                Button("Install") {
                    let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cat = category.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = nameOverride.trimmingCharacters(in: .whitespacesAndNewlines)
                    viewModel.installFromURL(
                        trimmedURL,
                        categoryOverride: cat.isEmpty ? nil : cat,
                        nameOverride: name.isEmpty ? nil : name
                    )
                    dismiss()
                }
                .buttonStyle(ScarfPrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(ScarfSpace.s5)
        .frame(width: 460)
    }
}
