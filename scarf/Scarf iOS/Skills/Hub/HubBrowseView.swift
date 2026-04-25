import SwiftUI
import ScarfCore
import ScarfDesign

/// Browse / search the Hermes skills hub. Source picker is a `Menu`
/// (more compact than Mac's segmented Picker on a phone-width screen).
/// Search submits on Return; empty query falls through to a "browse"
/// listing (top results across the chosen source).
struct HubBrowseView: View {
    @Bindable var vm: SkillsViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ScarfColor.foregroundMuted)
                TextField("Search skills…", text: $vm.hubQuery)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit { vm.searchHub() }
                Menu {
                    Picker("Source", selection: $vm.hubSource) {
                        ForEach(vm.hubSources, id: \.self) { src in
                            Text(src).tag(src)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(vm.hubSource)
                            .font(.callout)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            HStack(spacing: 8) {
                Button {
                    vm.searchHub()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .buttonStyle(ScarfPrimaryButton())
                .controlSize(.small)
                .disabled(vm.isHubLoading)
                Button {
                    vm.browseHub()
                } label: {
                    Label("Browse", systemImage: "books.vertical")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.isHubLoading)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if vm.hubResults.isEmpty {
            ContentUnavailableView {
                Label("Browse the Hub", systemImage: "books.vertical")
            } description: {
                Text("Search for a skill or tap Browse to see top results across registries (skills.sh, official, etc.).")
                    .font(.caption)
            } actions: {
                Button {
                    vm.browseHub()
                } label: {
                    Label("Browse top skills", systemImage: "books.vertical")
                }
                .buttonStyle(ScarfPrimaryButton())
                .disabled(vm.isHubLoading)
            }
        } else {
            List {
                ForEach(vm.hubResults) { hubSkill in
                    HubSkillRow(skill: hubSkill, isInstalling: vm.isHubLoading) {
                        vm.installHubSkill(hubSkill)
                    }
                    .scarfGoCompactListRow()
                }
            }
            .scarfGoListDensity()
        }
    }
}

private struct HubSkillRow: View {
    let skill: HermesHubSkill
    let isInstalling: Bool
    let onInstall: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "books.vertical")
                .foregroundStyle(.tint)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.callout.monospaced())
                        .fontWeight(.medium)
                    if !skill.source.isEmpty {
                        Text(skill.source)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            Button {
                onInstall()
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .disabled(isInstalling)
            .accessibilityLabel("Install \(skill.name)")
            .accessibilityHint(skill.description)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}
