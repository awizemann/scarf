//
//  ScarfComponents.swift
//  Scarf Design System — opinionated SwiftUI component primitives.
//
//  These mirror the buttons, cards, badges, and inputs used in the Scarf UI kit.
//  Keep them small. Reach for them instead of inlining the same `.padding()
//  .background() .clipShape()` chain across screens.
//

import SwiftUI

// MARK: - Buttons

public struct ScarfPrimaryButton: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scarfStyle(.bodyEmph)
            .foregroundStyle(ScarfColor.onAccent)
            .padding(.horizontal, ScarfSpace.s4)
            .padding(.vertical, ScarfSpace.s2)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                    .fill(configuration.isPressed ? ScarfColor.accentActive : ScarfColor.accent)
            )
            .scarfShadow(.sm)
            .opacity(configuration.isPressed ? 0.95 : 1)
    }
}

public struct ScarfSecondaryButton: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scarfStyle(.bodyEmph)
            .foregroundStyle(ScarfColor.foregroundPrimary)
            .padding(.horizontal, ScarfSpace.s4)
            .padding(.vertical, ScarfSpace.s2)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                    .fill(configuration.isPressed
                          ? ScarfColor.borderStrong
                          : ScarfColor.backgroundSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                            .strokeBorder(ScarfColor.borderStrong, lineWidth: 1)
                    )
            )
    }
}

public struct ScarfGhostButton: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scarfStyle(.bodyEmph)
            .foregroundStyle(ScarfColor.foregroundPrimary)
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.vertical, ScarfSpace.s2)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                    .fill(configuration.isPressed
                          ? ScarfColor.accentTint
                          : Color.clear)
            )
    }
}

public struct ScarfDestructiveButton: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scarfStyle(.bodyEmph)
            .foregroundStyle(.white)
            .padding(.horizontal, ScarfSpace.s4)
            .padding(.vertical, ScarfSpace.s2)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                    .fill(ScarfColor.danger.opacity(configuration.isPressed ? 0.85 : 1.0))
            )
    }
}

// MARK: - Card

public struct ScarfCard<Content: View>: View {
    let padding: CGFloat
    let content: () -> Content

    public init(padding: CGFloat = ScarfSpace.s4, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.content = content
    }

    public var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                    .fill(ScarfColor.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                    .strokeBorder(ScarfColor.border, lineWidth: 1)
            )
            .scarfShadow(.sm)
    }
}

// MARK: - Badge / Pill

public enum ScarfBadgeKind {
    case neutral, brand, success, danger, warning, info

    var fill: Color {
        switch self {
        case .neutral: return ScarfColor.backgroundTertiary
        case .brand:   return ScarfColor.accentTint
        case .success: return ScarfColor.success.opacity(0.16)
        case .danger:  return ScarfColor.danger.opacity(0.16)
        case .warning: return ScarfColor.warning.opacity(0.18)
        case .info:    return ScarfColor.info.opacity(0.16)
        }
    }
    var fg: Color {
        switch self {
        case .neutral: return ScarfColor.foregroundMuted
        case .brand:   return ScarfColor.accent
        case .success: return ScarfColor.success
        case .danger:  return ScarfColor.danger
        case .warning: return ScarfColor.warning
        case .info:    return ScarfColor.info
        }
    }
}

public struct ScarfBadge: View {
    let text: String
    let kind: ScarfBadgeKind

    public init(_ text: String, kind: ScarfBadgeKind = .neutral) {
        self.text = text
        self.kind = kind
    }

    public var body: some View {
        Text(text)
            .scarfStyle(.captionStrong)
            .foregroundStyle(kind.fg)
            .padding(.horizontal, ScarfSpace.s2)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(kind.fill)
            )
    }
}

// MARK: - Inputs

public struct ScarfTextField: View {
    let placeholder: String
    @Binding var text: String

    public init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    public var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .scarfStyle(.body)
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.vertical, ScarfSpace.s2)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                    .fill(ScarfColor.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                    .strokeBorder(ScarfColor.borderStrong, lineWidth: 1)
            )
    }
}

// MARK: - Section header

public struct ScarfSectionHeader: View {
    let title: String
    let subtitle: String?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            if let subtitle {
                Text(subtitle)
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
        }
    }
}

// MARK: - Divider

public struct ScarfDivider: View {
    public init() {}
    public var body: some View {
        Rectangle()
            .fill(ScarfColor.border)
            .frame(height: 1)
    }
}

// MARK: - Page header

/// Standard page-level title/subtitle/actions header used at the top of
/// every feature route. Mirrors the `ContentHeader` component in the
/// design system's static-site / ui-kit. Drops a hairline divider at the
/// bottom so feature content can flush against it.
public struct ScarfPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    public init(_ title: String,
                subtitle: String? = nil,
                @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scarfStyle(.title2)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                if let subtitle {
                    Text(subtitle)
                        .scarfStyle(.footnote)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.top, ScarfSpace.s5)
        .padding(.bottom, ScarfSpace.s4)
        .overlay(
            Rectangle()
                .fill(ScarfColor.border)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}
