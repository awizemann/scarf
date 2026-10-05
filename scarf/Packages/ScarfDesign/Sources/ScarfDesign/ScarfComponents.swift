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

/// The one primary (filled accent) button. Use it instead of
/// `.buttonStyle(.borderedProminent)`: the system prominent style fills with
/// the app AccentColor but always draws a WHITE label, which is 2.39:1 on the
/// dark-mode accent (#E89360) and fails WCAG AA. This style draws the label in
/// `ScarfColor.onAccent` (white in light, brand-900 #3B1608 in dark), so it
/// clears AA in both appearances. tools/check-design-tokens.py fails the build
/// check on any `.borderedProminent` in the app or package sources.
///
/// Honors the environment the system styles do:
/// - `.controlSize`: mini 11pt semibold (6 × 2 padding), small 12pt
///   semibold (s3 × s1), regular 14pt medium with s4 × s2 (the original
///   look), large / extraLarge 16pt medium (s5 × s3). Sizes scale with
///   Dynamic Type on iOS.
/// - iOS: at least a 44 × 44pt hit target (the pill keeps its drawn size).
/// - `.disabled(true)`: the whole button (fill + label, so their contrast
///   relationship is preserved) drops to 45% opacity and loses its shadow.
///   WCAG 1.4.3 exempts inactive controls; the dimming is the state cue.
/// - Pressed: the fill steps to `accentActive`.
///
/// `.keyboardShortcut(.defaultAction)`, `.disabled`, and button roles work as
/// with any `ButtonStyle`. For a red (destructive) filled button use
/// `ScarfDestructiveButton`.
public struct ScarfPrimaryButton: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        ScarfFilledButtonBody(
            configuration: configuration,
            fill: ScarfColor.accent,
            pressedFill: ScarfColor.accentActive,
            label: ScarfColor.onAccent,
            shadow: true
        )
    }
}

/// Minimum hit target for the filled button styles: 44pt on iOS (HIG), none on
/// macOS (pointer). Internal so previews / snapshot tools can show the iOS frame.
private struct ScarfMinimumHitTargetKey: EnvironmentKey {
    #if os(iOS)
    static let defaultValue: CGFloat = 44
    #else
    static let defaultValue: CGFloat = 0
    #endif
}

extension EnvironmentValues {
    var scarfMinimumHitTarget: CGFloat {
        get { self[ScarfMinimumHitTargetKey.self] }
        set { self[ScarfMinimumHitTargetKey.self] = newValue }
    }
}

/// Shared body of the filled button styles (`ScarfPrimaryButton`,
/// `ScarfDestructiveButton`): one place for controlSize sizing, Dynamic
/// Type, the iOS hit target, the disabled treatment and the pressed state.
/// It's a `View` so it can read the environment (a `ButtonStyle` itself
/// isn't a `View`, so its `@Environment` isn't reliably updated).
///
/// Type per controlSize (sizes at the default Dynamic Type size, scaled
/// with the named text style on iOS via `@ScaledMetric`, so the default
/// look is unchanged): mini 11 semibold (caption2), small 12 semibold
/// (caption, = ScarfFont.captionStrong), regular 14 medium (body,
/// = bodyEmph), large / extraLarge 16 medium (callout, = subhead).
///
/// Hit target: on iOS the button's layout frame is at least 44 × 44pt and
/// the whole frame is tappable; the drawn pill keeps its size and is
/// centered in it. A small button in an HStack therefore lays out 44pt tall.
private struct ScarfFilledButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    /// Fill while pressed. `nil` darkens `fill` with a 12% black overlay,
    /// which only raises a white label's contrast.
    let pressedFill: Color?
    let label: Color
    let shadow: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.scarfMinimumHitTarget) private var minimumHitTarget

    @ScaledMetric(relativeTo: .caption2) private var miniSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var smallSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var regularSize: CGFloat = 14
    @ScaledMetric(relativeTo: .callout) private var largeSize: CGFloat = 16

    /// Opacity of the whole button (fill and label together) when disabled.
    static let disabledOpacity: Double = 0.45
    static let noShadow = ScarfShadow(color: .clear, radius: 0, x: 0, y: 0)

    private var font: Font {
        switch controlSize {
        case .mini:                 return .system(size: miniSize, weight: .semibold)
        case .small:                return .system(size: smallSize, weight: .semibold)
        case .regular:              return .system(size: regularSize, weight: .medium)
        case .large, .extraLarge:   return .system(size: largeSize, weight: .medium)
        @unknown default:           return .system(size: regularSize, weight: .medium)
        }
    }

    /// iOS lays mini / small out next to system `.bordered` buttons, whose
    /// pills are ~22 / ~28pt tall; the extra vertical padding there matches
    /// their height (macOS keeps the compact 2 / 4pt).
    #if os(iOS)
    private static let miniV: CGFloat = ScarfSpace.s1
    private static let smallV: CGFloat = ScarfSpace.s2 - 1
    #else
    private static let miniV: CGFloat = ScarfSpace.s1 / 2
    private static let smallV: CGFloat = ScarfSpace.s1
    #endif

    private var padding: (h: CGFloat, v: CGFloat) {
        switch controlSize {
        case .mini:                 return (ScarfSpace.s1 * 1.5, Self.miniV)
        case .small:                return (ScarfSpace.s3, Self.smallV)
        case .regular:              return (ScarfSpace.s4, ScarfSpace.s2)
        case .large, .extraLarge:   return (ScarfSpace.s5, ScarfSpace.s3)
        @unknown default:           return (ScarfSpace.s4, ScarfSpace.s2)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .font(font)
            .foregroundStyle(label)
            .padding(.horizontal, padding.h)
            .padding(.vertical, padding.v)
            .background(
                shape
                    .fill(pressed ? (pressedFill ?? fill) : fill)
                    .overlay(shape.fill(Color.black.opacity(pressed && pressedFill == nil ? 0.12 : 0)))
            )
            .scarfShadow(shadow && isEnabled ? .sm : Self.noShadow)
            .opacity(isEnabled ? (pressed ? 0.95 : 1) : Self.disabledOpacity)
            .modifier(ScarfHitTarget(minimum: minimumHitTarget, shape: shape))
    }
}

/// Grows the layout frame to `minimum` (centering the drawn button) and makes
/// all of it tappable; with no minimum (macOS) the hit shape is the button's
/// own rounded rect and layout is untouched.
private struct ScarfHitTarget: ViewModifier {
    let minimum: CGFloat
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if minimum > 0 {
            content
                .frame(minWidth: minimum, minHeight: minimum)
                .contentShape(Rectangle())
        } else {
            content.contentShape(shape)
        }
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

/// The filled red button for destructive actions. White `onDanger` label on
/// `dangerFill` (red-600 #B83C38 in both appearances, 5.61:1); pressed
/// darkens the fill. Same controlSize sizing and disabled treatment as
/// `ScarfPrimaryButton`. Use `ScarfColor.danger` for danger text and icons,
/// never as this fill: white on its dark value is 3.27:1.
public struct ScarfDestructiveButton: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        ScarfFilledButtonBody(
            configuration: configuration,
            fill: ScarfColor.dangerFill,
            pressedFill: nil,
            label: ScarfColor.onDanger,
            shadow: false
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

/// A status tone: a tint fill and the text color that reads on it. Use it for
/// any badge, pill, status strip or tile, not only `ScarfBadge`:
/// `.foregroundStyle(kind.text)` on `.background(kind.fill)` (or a lighter
/// `kind.fill.opacity(f)` banner wash; `kind.text.opacity(a)` for a border).
/// Every pair is >= 4.5:1 over backgroundPrimary / Secondary / Tertiary in
/// both appearances (tools/check-design-tokens.py, which also pins this
/// mapping). Don't wash with the status color itself
/// (`ScarfColor.warning.opacity(...)`): that's the darker text hue.
public enum ScarfBadgeKind {
    case neutral, brand, success, danger, warning, info

    /// The tint behind the text.
    public var fill: Color {
        switch self {
        case .neutral: return ScarfColor.neutralTint
        case .brand:   return ScarfColor.accentTint
        case .success: return ScarfColor.successTint
        case .danger:  return ScarfColor.dangerTint
        case .warning: return ScarfColor.warningTint
        case .info:    return ScarfColor.infoTint
        }
    }

    /// The kind's tint at an absolute wash `alpha` (<= `fillAlpha`): a lighter
    /// banner wash in the same hue, e.g. `.warning.tinted(0.12)`.
    public func tinted(_ alpha: Double) -> Color { fill.opacity(min(alpha / fillAlpha, 1)) }

    /// The alpha baked into `fill` (Status/*Tint, Accent/AccentTint,
    /// Status/NeutralTint); tools/check-design-tokens.py pins these.
    public var fillAlpha: Double {
        switch self {
        case .neutral: return 0.06
        case .brand:   return 0.10
        case .warning: return 0.18
        case .success, .danger, .info: return 0.16
        }
    }

    /// Text and icons on `fill` (and on any surface): the status color.
    public var text: Color {
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

/// A tool-call kind's chip colors, mirroring `ToolKind` (ScarfCore): `color`
/// for the kind's icon and label, `wash` for the chip behind them (use
/// `wash.opacity(f)` for an unfocused, lighter chip). Every pair is >= 4.5:1
/// in both appearances on every surface (tools/check-design-tokens.py pins
/// this mapping too).
public enum ScarfToolTone {
    case read, edit, execute, fetch, browser, other

    public var color: Color {
        switch self {
        case .read:    return ScarfColor.success
        case .edit:    return ScarfColor.info
        case .execute: return ScarfColor.warning
        case .fetch:   return ScarfColor.Tool.web
        case .browser: return ScarfColor.Tool.search
        case .other:   return ScarfColor.foregroundMuted
        }
    }

    /// The chip at an absolute wash `alpha` (<= its tint's 0.16 / 0.18).
    public func tinted(_ alpha: Double) -> Color { wash.opacity(min(alpha / washAlpha, 1)) }

    /// The alpha baked into `wash`; tools/check-design-tokens.py pins these.
    public var washAlpha: Double {
        switch self {
        case .execute: return 0.18
        case .other:   return 0.06
        default:       return 0.16
        }
    }

    public var wash: Color {
        switch self {
        case .read:    return ScarfColor.successTint
        case .edit:    return ScarfColor.infoTint
        case .execute: return ScarfColor.warningTint
        case .fetch:   return ScarfColor.Tool.webTint
        case .browser: return ScarfColor.Tool.searchTint
        case .other:   return ScarfColor.neutralTint
        }
    }
}

public struct ScarfBadge: View {
    /// Pre-built so the localized and verbatim initializers can share one
    /// body. A `String` property here bound `Text`'s VERBATIM overload, so
    /// none of these labels were ever extractable (go/no-go blocking
    /// condition 6, A2-F2). Literal call sites now take the
    /// `LocalizedStringKey` init and extract; call sites passing a runtime
    /// `String` take the explicit `verbatim:` init and keep working.
    let text: Text
    let kind: ScarfBadgeKind

    public init(_ text: LocalizedStringKey, kind: ScarfBadgeKind = .neutral) {
        self.text = Text(text)
        self.kind = kind
    }

    /// For text computed at runtime (a job state, a peer name, a count) —
    /// never a localizable literal.
    public init(verbatim text: String, kind: ScarfBadgeKind = .neutral) {
        self.text = Text(verbatim: text)
        self.kind = kind
    }

    public var body: some View {
        text
            .scarfStyle(.captionStrong)
            .foregroundStyle(kind.text)
            .padding(.horizontal, ScarfSpace.s2)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(kind.fill)
            )
    }
}

// MARK: - Inputs

public struct ScarfTextField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String

    public init(_ placeholder: LocalizedStringKey, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    /// For a placeholder computed at runtime — `TextField`'s own
    /// `StringProtocol` overload, which is not localized.
    public init(verbatim placeholder: String, text: Binding<String>) {
        self.placeholder = LocalizedStringKey(placeholder)
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
    let title: Text
    let subtitle: Text?

    public init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
    }

    /// For a header composed at runtime (a profile name, a peer host).
    public init(verbatim title: String, verbatimSubtitle subtitle: String? = nil) {
        self.title = Text(verbatim: title)
        self.subtitle = subtitle.map { Text(verbatim: $0) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            if let subtitle {
                subtitle
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
    let title: Text
    let subtitle: Text?
    let trailing: Trailing

    public init(_ title: LocalizedStringKey,
                subtitle: LocalizedStringKey? = nil,
                @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.trailing = trailing()
    }

    /// For a page title composed at runtime (a project name, a server host).
    public init(verbatim title: String,
                verbatimSubtitle subtitle: String? = nil,
                @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = Text(verbatim: title)
        self.subtitle = subtitle.map { Text(verbatim: $0) }
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .scarfStyle(.title2)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                if let subtitle {
                    subtitle
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

// MARK: - Tab strip

/// A tab a `ScarfTabStrip` can render. Backed by a `String` `RawRepresentable`
/// so each strip's `.accessibilityIdentifier` composes as `"<prefix>.<rawValue>"`
/// and stays independent of the (localized) display text.
public protocol ScarfTabStripTab: Identifiable, Hashable {
    var rawValue: String { get }
    var displayName: LocalizedStringResource { get }
}

/// Row-of-buttons tab strip, extracted from `SettingsView.tabStrip` (t-42c56c2f)
/// so every feature that needs a driveable tab switcher shares one
/// implementation. A SwiftUI `.pickerStyle(.segmented)` Picker is NOT an
/// option here: on macOS its segments surface as accessibility RadioButtons
/// whose selection XCUITest cannot move (click reports success, the binding
/// never changes — see the XCUITest input/click reliability memory note).
/// A real `Button` per tab is fully drivable and keyboard/VoiceOver
/// navigable, at the cost of losing segmented-control chrome.
public struct ScarfTabStrip<Tab: ScarfTabStripTab>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let identifierPrefix: String
    let icon: (Tab) -> String?

    /// - Parameters:
    ///   - tabs: Tabs to render, in order.
    ///   - selection: The active tab.
    ///   - identifierPrefix: Prefix for each button's `.accessibilityIdentifier`
    ///     (e.g. `"settings.tab"` → `"settings.tab.General"`).
    ///   - icon: Optional SF Symbol name per tab. Omit for a text-only strip.
    public init(
        tabs: [Tab],
        selection: Binding<Tab>,
        identifierPrefix: String,
        icon: @escaping (Tab) -> String? = { _ in nil }
    ) {
        self.tabs = tabs
        self._selection = selection
        self.identifierPrefix = identifierPrefix
        self.icon = icon
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ScarfSpace.s1) {
                ForEach(tabs) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, ScarfSpace.s6)
        }
        .background(
            ScarfColor.backgroundSecondary
                .overlay(
                    Rectangle()
                        .fill(ScarfColor.border)
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    private func tabButton(_ tab: Tab) -> some View {
        let isActive = selection == tab
        return Button {
            selection = tab
        } label: {
            HStack(spacing: 6) {
                if let iconName = icon(tab) {
                    Image(systemName: iconName)
                        .font(.system(size: 12))
                }
                Text(tab.displayName)
                    .scarfStyle(isActive ? .bodyEmph : .body)
            }
            .foregroundStyle(isActive ? ScarfColor.accent : ScarfColor.foregroundMuted)
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.vertical, 10)
            .overlay(
                Rectangle()
                    .fill(isActive ? ScarfColor.accent : Color.clear)
                    .frame(height: 2),
                alignment: .bottom
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Stable handle for UI journeys: the visible tab label is
        // localized, so a test that clicked by title would only pass in
        // English.
        .accessibilityIdentifier("\(identifierPrefix).\(tab.rawValue)")
        .accessibilityLabel(Text(tab.displayName))
        // Selection is colour-only visually; give VoiceOver/Voice Control
        // the state as a trait since the control is selectable (tabs),
        // per the macOS accessibility label conventions note.
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
