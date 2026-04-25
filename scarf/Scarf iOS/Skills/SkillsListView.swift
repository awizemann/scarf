import SwiftUI
import ScarfCore

/// iOS Skills browser. Read-only list grouped by category. Tapping
/// a skill shows its files + on-disk path — enough for a user to
/// verify what's installed without opening Terminal.
struct SkillsListView: View {
    let config: IOSServerConfig

    @State private var vm: IOSSkillsViewModel

    private static let sharedContextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A1"
    )!

    init(config: IOSServerConfig) {
        self.config = config
        let ctx = config.toServerContext(id: Self.sharedContextID)
        _vm = State(initialValue: IOSSkillsViewModel(context: ctx))
    }

    var body: some View {
        List {
            if let err = vm.lastError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if vm.categories.isEmpty, !vm.isLoading {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No skills installed")
                            .font(.headline)
                        Text("Skills live under `~/.hermes/skills/<category>/<name>/` on the remote. Install them from the Mac app or by cloning directly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                ForEach(vm.categories) { category in
                    Section(category.name) {
                        ForEach(category.skills) { skill in
                            NavigationLink {
                                SkillDetailView(skill: skill)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.name)
                                        .font(.body)
                                    Text("\(skill.files.count) file\(skill.files.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .scarfGoCompactListRow()
                        }
                    }
                }
            }
        }
        .scarfGoListDensity()
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if vm.isLoading && vm.categories.isEmpty {
                ProgressView("Scanning skills…")
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .refreshable { await vm.load() }
        .task { await vm.load() }
    }
}

private struct SkillDetailView: View {
    let skill: HermesSkill

    @Environment(\.serverContext) private var serverContext
    @State private var npxStatus: SkillPrereqService.Status?

    var body: some View {
        List {
            Section("Location") {
                LabeledContent("Category", value: skill.category)
                Text(skill.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            // v2.5 design-md prereq surface — the skill needs `npx`
            // (Node.js 18+) on the host. iOS read-only banner: same
            // wording as the Mac one, no install button (the user is
            // already going to need a shell to fix this).
            if skill.name.lowercased() == "design-md",
               case .missing(let hint) = npxStatus {
                Section("Prerequisite missing") {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("`npx` not found on the Hermes host.")
                                .font(.callout.weight(.medium))
                            Text(hint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 4)
                }
            }

            if skill.name.lowercased() == "spotify" {
                Section("Authentication") {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Spotify needs OAuth")
                                .font(.callout.weight(.medium))
                            Text("Run `hermes auth spotify` from the Scarf macOS app or a shell — it opens your browser to complete the OAuth flow. Once authorised, this skill picks up the credentials from `~/.hermes/auth.json` automatically.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "music.note")
                            .foregroundStyle(.green)
                    }
                    .padding(.vertical, 4)
                }
            }

            if !skill.files.isEmpty {
                Section("Files") {
                    ForEach(skill.files, id: \.self) { file in
                        Text(file)
                            .font(.caption.monospaced())
                    }
                }
            }
        }
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: skill.id) {
            // Only probe when this skill needs it. design-md is the
            // only skill in v2.5 with a host-side prereq surface; the
            // probe runs once per appear and isn't cached across
            // navigation events (cheap — single SSH `which` call).
            guard skill.name.lowercased() == "design-md" else {
                npxStatus = nil
                return
            }
            let svc = SkillPrereqService(context: serverContext)
            npxStatus = await svc.probe(binary: "npx")
        }
    }
}
