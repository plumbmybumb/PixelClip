import SwiftUI
import PixelClipKit

// Shared vocabulary: title2-bold section headers, 16–24 pt continuous corners on
// `secondarySystemGroupedBackground` (white on the grouped grey in light mode), 34 pt icon tiles tinted at 14 %, press-down scale feedback.

// MARK: - Small pieces

struct SectionHeader: View {
    let title: String
    var detail: String?
    var body: some View {
        AdaptiveHStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title2.bold())
            Spacer(minLength: 0)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A row that becomes a leading-aligned column at accessibility text sizes, so side-by-side
/// labels and buttons wrap instead of clipping.
struct AdaptiveHStack<Content: View>: View {
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        let layout = size.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: alignment, spacing: spacing))
        layout { content }
    }
}

/// Press feedback on touch-down (apple-design §1): a quick scale, released with a spring.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.1) : .spring(duration: 0.3, bounce: 0), value: configuration.isPressed)
    }
}

/// The rounded card used across the app.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 18
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func card(radius: CGFloat = 18, padding: CGFloat = 18) -> some View { modifier(CardBackground(radius: radius, padding: padding)) }
}

/// A 34 pt tinted glyph tile.
struct IconTile: View {
    let systemImage: String
    var tint: Color = .accentColor
    var body: some View {
        Image(systemName: systemImage)
            .font(.body)
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(0.14), in: .rect(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Icon tile + title + body text, the "Today’s Practice" card shape.
struct FeatureCard: View {
    let systemImage: String
    let title: String
    let text: String
    var tint: Color = .accentColor
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(systemImage: systemImage, tint: tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.body).foregroundStyle(.secondary)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// A capsule label ("Coming soon", "In playlist").
struct Badge: View {
    let text: String
    var systemImage: String?
    var tint: Color = .accentColor
    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: .capsule)
    }
}

/// Errors are inline, with a way forward — never a dead-end alert.
struct InlineBanner: View {
    let message: String
    var systemImage = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(message).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A progress indicator that always says what it's doing.
struct WorkingLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Battery

/// The clip's battery, the same everywhere: the level in quarters, orange under 20 %, red under
/// 10 % (or near the Wi‑Fi cutoff), a bolt while USB power is connected.
struct BatteryGlyph: View {
    let reading: BatteryReading
    var showsPercent = true

    init(reading: BatteryReading, showsPercent: Bool = true) {
        self.reading = reading
        self.showsPercent = showsPercent
    }

    init(battery: ClipStatus.Battery?, showsPercent: Bool = true) {
        self.init(reading: BatteryReading(battery), showsPercent: showsPercent)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: reading.symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
            if showsPercent, let pct = reading.pct {
                Text("\(pct)%").monospacedDigit()
                    .foregroundStyle(reading.level == .normal ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.accessibilityText)
    }

    private var tint: Color {
        if reading.onUSB { return .green }
        switch reading.level {
        case .normal: return .primary
        case .low: return .orange
        case .critical: return .red
        }
    }
}

extension Color {
    /// Label colour on accent-filled buttons: black on the bright dark-mode violet (10.0:1), white on the deep
    /// light-mode one (5.64:1). See `BrandPalette`.
    static let onAccent = Color("OnAccent")
}

/// `.glass` / `.glassProminent` behind one type, for a conditional style.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Formatting

extension String {
    /// "times from 12 min ago" → "Times from 12 min ago".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

extension Double {
    /// "10 s", "1 min 20 s".
    var durationText: String {
        let s = Int(self.rounded())
        if s < 60 { return "\(s) s" }
        return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s"
    }
}
