//
//  ScarfPreview.swift
//  Scarf Design System — quick component preview.
//
//  Open this file in Xcode and the canvas (⌥⌘P) shows every component at once,
//  in light and dark. Use it to sanity-check the bundle works after install.
//

import SwiftUI

public struct ScarfPreviewGallery: View {
    @State private var query = ""
    @State private var draft = "Hello, Scarf"

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ScarfSpace.s8) {

                // ── Header ──────────────────────────────────────────────
                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                    Text("Scarf Design System")
                        .scarfStyle(.largeTitle)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                    Text("Component preview — light / dark resolves from the asset catalog.")
                        .scarfStyle(.subhead)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }

                // ── Buttons ─────────────────────────────────────────────
                section("Buttons") {
                    HStack(spacing: ScarfSpace.s3) {
                        Button("Primary") {}.buttonStyle(ScarfPrimaryButton())
                        Button("Secondary") {}.buttonStyle(ScarfSecondaryButton())
                        Button("Ghost") {}.buttonStyle(ScarfGhostButton())
                        Button("Delete") {}.buttonStyle(ScarfDestructiveButton())
                    }
                }

                // ── Badges ──────────────────────────────────────────────
                section("Badges") {
                    HStack(spacing: ScarfSpace.s2) {
                        ScarfBadge("Neutral")
                        ScarfBadge("Brand",   kind: .brand)
                        ScarfBadge("Success", kind: .success)
                        ScarfBadge("Warning", kind: .warning)
                        ScarfBadge("Danger",  kind: .danger)
                        ScarfBadge("Info",    kind: .info)
                    }
                }

                // ── Inputs ──────────────────────────────────────────────
                section("Inputs") {
                    VStack(alignment: .leading, spacing: ScarfSpace.s3) {
                        ScarfTextField("Search", text: $query)
                        ScarfTextField("Compose a message", text: $draft)
                    }
                }

                // ── Card ────────────────────────────────────────────────
                section("Card") {
                    ScarfCard {
                        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                            ScarfSectionHeader("Connection", subtitle: "anthropic.com")
                            ScarfDivider()
                            HStack {
                                Text("Status")
                                    .scarfStyle(.body)
                                    .foregroundStyle(ScarfColor.foregroundMuted)
                                Spacer()
                                ScarfBadge("Connected", kind: .success)
                            }
                            HStack {
                                Text("Last run")
                                    .scarfStyle(.body)
                                    .foregroundStyle(ScarfColor.foregroundMuted)
                                Spacer()
                                Text("2 min ago")
                                    .scarfStyle(.bodyEmph)
                                    .foregroundStyle(ScarfColor.foregroundPrimary)
                            }
                        }
                    }
                }

                // ── Tool kind swatches (chat) ───────────────────────────
                section("Tool kinds") {
                    HStack(spacing: ScarfSpace.s3) {
                        toolSwatch("Bash",   ScarfColor.Tool.bash)
                        toolSwatch("Edit",   ScarfColor.Tool.edit)
                        toolSwatch("Search", ScarfColor.Tool.search)
                        toolSwatch("Web",    ScarfColor.Tool.web)
                        toolSwatch("Think",  ScarfColor.Tool.think)
                    }
                }

                // ── Brand gradient ──────────────────────────────────────
                section("Brand gradient") {
                    RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                        .fill(ScarfGradient.brand)
                        .frame(height: 80)
                        .overlay(
                            Text("amber → rust → deep")
                                .scarfStyle(.subhead)
                                .foregroundStyle(.white)
                        )
                }
            }
            .padding(ScarfSpace.s8)
        }
        .background(ScarfColor.backgroundPrimary.ignoresSafeArea())
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            Text(title)
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            content()
        }
    }

    private func toolSwatch(_ name: String, _ color: Color) -> some View {
        VStack(spacing: ScarfSpace.s1) {
            Circle().fill(color).frame(width: 24, height: 24)
            Text(name)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
        }
    }
}

#Preview("Light") {
    ScarfPreviewGallery()
        .frame(width: 720, height: 900)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    ScarfPreviewGallery()
        .frame(width: 720, height: 900)
        .preferredColorScheme(.dark)
}
