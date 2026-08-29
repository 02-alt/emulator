import SwiftUI

// Building blocks for the Settings screen only (see SettingsView). Kept here so the visual language —
// a systematic spacing scale, monochrome section badges, and accessible value sliders — stays in one
// place and doesn't touch the rest of the app's UI.

/// An 8-pt spacing scale (with a 2/4 sub-step for fine rhythm). Every gap/inset in Settings comes from
/// this scale rather than ad-hoc numbers, so the screen reads with a consistent vertical rhythm.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}

/// A section header with a small monochrome glyph badge — gives each group an at-a-glance anchor while
/// staying within the app's flat, single-accent language (no coloured iOS-Settings tiles). The badge is
/// decorative; the whole header is exposed to VoiceOver as a single heading element.
struct SectionHeader: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.textSecondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.hairline))
                .accessibilityHidden(true)
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DS.textSecondary)
        }
        .textCase(nil)   // keep the title readable rather than the default tiny all-caps
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A labelled slider row: the control's name and its live value on one line, the slider (flanked by
/// meaning glyphs) beneath. The visible title/value are marked decorative and the *slider* carries the
/// accessibility — it's natively adjustable and announces the same formatted value, so VoiceOver reads
/// e.g. "Volume, 70 percent, adjustable" instead of an unlabelled "50 percent".
struct SettingSlider: View {
    let title: String
    var leadingIcon: String
    var trailingIcon: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    /// How the current value is shown (and read out). Defaults to a whole percent.
    var display: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(title)
                Spacer(minLength: Space.md)
                Text(display(value))
                    .font(DS.mono(13))
                    .monospacedDigit()
                    .foregroundStyle(DS.textSecondary)
            }
            .accessibilityHidden(true)   // the slider below is the accessible control

            Slider(value: $value, in: range) {
                Text(title)
            } minimumValueLabel: {
                Image(systemName: leadingIcon).font(.footnote).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: trailingIcon).font(.footnote).foregroundStyle(.secondary)
            }
            .tint(DS.accent)
            .accessibilityValue(display(value))
        }
        .padding(.vertical, Space.xxs)
    }
}
