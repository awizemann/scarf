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
    /// The overrides start collapsed, but a rejected value must never be
    /// able to disable Install while its explanation is hidden inside a
    /// closed disclosure — so a problem forces the group open.
    @State private var overridesExpanded = false

    /// Loose validity check — accept anything that starts with `https://`
    /// (HTTP gets blocked because Hermes refuses non-TLS skill URLs by
    /// default to keep MITM-injected SKILL.md off the host).
    private var isValidURL: Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("https://") && trimmed.count > 10
    }

    /// Both overrides are interpolated into the install path
    /// `~/.hermes/skills/<category>/<name>/`. `--name` is checked by
    /// Hermes and aborts the install after the download with a message
    /// Scarf could only surface as a canned "Install failed"; `--category`
    /// is NOT checked by Hermes on the flag path at all, so a `..` typed
    /// here would place the skill outside the skills root. Both are
    /// validated against Hermes's own regexes before the button enables.
    private var categoryProblem: SkillInstallValidator.Problem? {
        SkillInstallValidator.problem(with: category, field: .category)
    }

    private var nameProblem: SkillInstallValidator.Problem? {
        SkillInstallValidator.problem(with: nameOverride, field: .name)
    }

    private var isValid: Bool {
        isValidURL && categoryProblem == nil && nameProblem == nil
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

            DisclosureGroup(
                "Optional overrides",
                isExpanded: Binding(
                    get: { overridesExpanded || categoryProblem != nil || nameProblem != nil },
                    set: { overridesExpanded = $0 }
                )
            ) {
                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Category")
                            .scarfStyle(.captionUppercase)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        ScarfTextField("e.g. productivity (defaults to `local`)", text: $category)
                            .accessibilityLabel("Category")
                        if let problem = categoryProblem {
                            Text(problem.userMessage)
                                .scarfStyle(.caption)
                                .foregroundStyle(ScarfColor.danger)
                                .accessibilityLabel("Category error: \(problem.userMessage)")
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Skill name")
                            .scarfStyle(.captionUppercase)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        ScarfTextField("Override if SKILL.md has no `name:`", text: $nameOverride)
                            .accessibilityLabel("Skill name")
                        if let problem = nameProblem {
                            Text(problem.userMessage)
                                .scarfStyle(.caption)
                                .foregroundStyle(ScarfColor.danger)
                                .accessibilityLabel("Skill name error: \(problem.userMessage)")
                        }
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
