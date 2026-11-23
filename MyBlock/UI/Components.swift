// Shared pieces. Flat color, square corners, hairline rules, sentence case. No outlines,
// no drop shadows, no pills.

import SwiftUI

enum ButtonVariant {
    /// Track red bar with an arrow. One per screen.
    case primary
    /// Light grey bar with an arrow.
    case secondary
    /// Red text with an arrow, for quiet actions.
    case ghost
}

private struct PressedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Set by `PressStyle` so a label can draw its own pressed state.
    var isPressed: Bool {
        get { self[PressedKey.self] }
        set { self[PressedKey.self] = newValue }
    }
}

/// Hands the pressed state to the label.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.isPressed, configuration.isPressed)
    }
}

/// For plain taps (rows, icons): a slight fade while pressed.
struct PressFade: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// The look of a button, usable as the label of other controls (PhotosPicker, ShareLink).
/// Text sits left, an arrow sits right: it reads as a direction, like a sign.
struct ButtonLabel: View {
    let label: String
    var variant: ButtonVariant = .primary
    var fill = true
    var compact = false
    var icon: String?
    /// Trailing glyph; nil hides it.
    var arrow: String? = "arrow.right"
    /// Text color for `.ghost` (red on white; sky on navy).
    var ghostColor: Color = Theme.red
    @Environment(\.isPressed) private var pressed
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            if let icon { Image(systemName: icon).font(.system(size: 16, weight: .semibold)) }
            Text(label)
                .font(Theme.Fonts.button)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if fill { Spacer(minLength: Theme.Space.sm) }
            if let arrow { Image(systemName: arrow).font(.system(size: 16, weight: .semibold)) }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, variant == .ghost ? 0 : Theme.Space.lg + 2)
        .frame(maxWidth: fill ? .infinity : nil, minHeight: compact ? Theme.minTouch : 60)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch variant {
        case .primary: Theme.accentText
        case .secondary: Theme.text
        case .ghost: ghostColor.opacity(pressed ? 0.6 : 1)
        }
    }

    private var background: Color {
        switch variant {
        case .primary: pressed ? Theme.redPressed : Theme.red
        case .secondary: pressed ? Theme.hairline : Theme.tint
        case .ghost: .clear
        }
    }
}

struct MBButton: View {
    let label: String
    var variant: ButtonVariant = .primary
    var fill = true
    var compact = false
    var icon: String?
    var arrow: String? = "arrow.right"
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ButtonLabel(label: label, variant: variant, fill: fill, compact: compact, icon: icon, arrow: arrow)
        }
        .buttonStyle(PressStyle())
        .disabled(disabled)
    }
}

/// Bare glyph button for small, optional actions (settings, help, flip camera).
struct IconButton: View {
    let systemName: String
    let label: String
    /// Over the camera or video: white glyph with a soft shadow for legibility.
    var onDark = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(onDark ? Theme.onDark : Theme.text)
                .shadow(color: onDark ? .black.opacity(0.45) : .clear, radius: 3)
                .frame(width: Theme.minTouch, height: Theme.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(label)
    }
}

/// Solid disc with a number or letter.
struct LaneBadge: View {
    let text: String
    var size: CGFloat = 28
    var fill: Color = Theme.navy

    var body: some View {
        Text(text)
            .font(Theme.Fonts.roboto(.black, size * 0.46, relativeTo: .caption))
            .foregroundStyle([Theme.yellow, Theme.sky, Theme.tint].contains(fill) ? Theme.navy : Theme.white)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .accessibilityHidden(true)
    }
}

/// Small sentence-case label above a group of content.
struct SectionLabel: View {
    let text: String
    var color: Color = Theme.textMuted
    var body: some View {
        Text(text)
            .font(Theme.Fonts.meta)
            .foregroundStyle(color)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Full-width hairline.
struct Rule: View {
    var color: Color = Theme.hairline
    var body: some View { Rectangle().fill(color).frame(height: 1).accessibilityHidden(true) }
}

/// A labelled value with − and + keys. VoiceOver treats it as one adjustable control.
struct StepperRow: View {
    let label: String
    var hint: String?
    @Binding var value: Double
    var unit = "s"
    let step: Double
    let min: Double
    let max: Double

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.Fonts.label).foregroundStyle(Theme.text)
                if let hint { Text(hint).textStyle(.small).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                key("minus") { set(value - step) }.disabled(value <= min)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(formatted).font(Theme.Fonts.number).foregroundStyle(Theme.text).monospacedDigit()
                    if !unit.isEmpty { Text(unit).font(Theme.Fonts.smallBold).foregroundStyle(Theme.textMuted) }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 60)
                key("plus") { set(value + step) }.disabled(value >= max)
            }
            .fixedSize()
        }
        .padding(.vertical, 14)
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(formatted) \(unit == "s" ? "seconds" : unit)")
        .accessibilityHint(hint ?? "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(value + step)
            case .decrement: set(value - step)
            @unknown default: break
            }
        }
    }

    private var formatted: String { value.formatted(.number.precision(.fractionLength(0...1))) }

    private func set(_ v: Double) {
        value = (Swift.min(max, Swift.max(min, v)) * 100).rounded() / 100
    }

    private func key(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.navy)
                .frame(width: 36, height: 36)
                .background(Theme.tint, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .frame(width: Theme.minTouch, height: Theme.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressFade())
    }
}

/// Text tabs with a red bar under the chosen one.
struct SegmentTabs<Value: Hashable>: View {
    let items: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: Theme.Space.xl) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button { selection = item.0 } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.1)
                            .font(Theme.Fonts.button)
                            .foregroundStyle(selection == item.0 ? Theme.text : Theme.textMuted)
                        Rectangle().fill(selection == item.0 ? Theme.red : .clear).frame(height: 3)
                    }
                    .fixedSize()
                    .frame(minHeight: Theme.minTouch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item.0 ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
    }
}

extension Binding where Value == Bool {
    /// True while `optional` holds a value; setting false clears it.
    init<T>(isPresent optional: Binding<T?>) {
        self.init(get: { optional.wrappedValue != nil }, set: { if !$0 { optional.wrappedValue = nil } })
    }
}
