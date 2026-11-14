import SwiftUI
import UIKit

// PixelClip's look (docs/DESIGN.md ▸ Principles): dark-first, a soft violet accent, the system font with
// Dynamic Type, one big primary button per screen and at most one quiet alternative. In light mode the
// same tokens fall back to the system's grouped backgrounds and labels, with the deep light accent.

enum Z2 {
    /// The screen's ground: #0E0C14 in dark mode, the grouped background in light mode.
    static let ground = dynamic(dark: 0x0E0C14, light: .systemGroupedBackground)
    /// Cards, tiles and rows: #1A1726.
    static let card = dynamic(dark: 0x1A1726, light: .secondarySystemGroupedBackground)
    /// A sheet's own surface: #15121E.
    static let sheet = dynamic(dark: 0x15121E, light: .systemGroupedBackground)
    /// The ring around a clip preview: #15121E.
    static let bezel = dynamic(dark: 0x15121E, light: .systemGray5)
    static let text = dynamic(dark: 0xF4F1FA, light: .label)
    static let secondary = dynamic(dark: 0xA99CC2, light: .secondaryLabel)
    /// Hints under a screen's content ("Drag to reorder…").
    static let hint = dynamic(dark: 0x7F7497, light: .tertiaryLabel)
    static let hairline = dynamic(dark: 0x2A2538, light: .separator)
    /// Chip and text-box borders: #332B45.
    static let border = dynamic(dark: 0x332B45, light: .separator)
    /// Text on the accent: #1A1030 on the bright dark-mode violet, white on the deep light one.
    static let onAccent = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x1A1030) : .white })
    /// Secondary text on the accent: #3E2F5E / white at 80 %.
    static let onAccentSecondary = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x3E2F5E) : UIColor(white: 1, alpha: 0.8) })
    /// "nearby" dot.
    static let nearby = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x8EF0B6) : .systemGreen })
    /// "can't find it" dot.
    static let away = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x5D5470) : .systemGray3 })

    private static func dynamic(dark: UInt32, light: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : light })
    }

    /// Springs: critically damped for UI, a little bounce only after a flick.
    static let spring = Animation.spring(duration: 0.35, bounce: 0)
    static let flick = Animation.spring(duration: 0.45, bounce: 0.18)
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Buttons

/// Feedback on touch-down (a quick scale and a slight dim), released with a spring. Every tile,
/// chip and button in the app uses it.
struct Z2Press: ButtonStyle {
    var scale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.08) : Z2.spring, value: configuration.isPressed)
    }
}

/// "Send to the clip": the one big button at the bottom of a screen.
struct Z2PrimaryButton: View {
    let title: String
    var systemImage: String?
    var working = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if working {
                    ProgressView().tint(Z2.onAccent)
                } else if let systemImage {
                    Image(systemName: systemImage).accessibilityHidden(true)
                }
                Text(title)
            }
            .font(.title3.bold())
            .foregroundStyle(Z2.onAccent)
            .frame(maxWidth: .infinity, minHeight: 60)
            .padding(.horizontal, 16)
            .background(Color.accentColor.opacity(disabled ? 0.4 : 1), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(Z2Press())
        .disabled(disabled || working)
    }
}

/// "Add to the playlist instead": the quiet alternative under the primary button.
struct Z2QuietButton: View {
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor.opacity(disabled ? 0.4 : 1))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(Z2Press())
        .disabled(disabled)
    }
}

/// The bottom of every making screen: the primary button and its one quiet alternative.
/// `mode == .playlist` (reached from the playlist's "+ Add something") turns the primary into
/// "Add to the playlist" and drops the alternative.
struct Z2SendButtons: View {
    let mode: ComposeMode
    var working = false
    var disabled = false
    let send: () -> Void
    let addToPlaylist: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            switch mode {
            case .send:
                Z2PrimaryButton(title: "Send to the clip", working: working, disabled: disabled, action: send)
                    .accessibilityIdentifier("sendToClip")
                Z2QuietButton(title: "Add to the playlist instead", disabled: disabled || working, action: addToPlaylist)
                    .accessibilityIdentifier("addToPlaylistInstead")
            case .playlist:
                Z2PrimaryButton(title: "Add to the playlist", working: working, disabled: disabled, action: addToPlaylist)
                    .accessibilityIdentifier("addToPlaylist")
            }
        }
    }
}

/// A choice chip (looks, stops, speeds): accent-filled when selected, outlined otherwise.
struct Z2Chip: View {
    let title: String
    var selected = false
    var font: Font = .subheadline.weight(.semibold)
    var minHeight: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(font)
                .foregroundStyle(selected ? Z2.onAccent : Z2.text)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: minHeight)
                .background(selected ? Color.accentColor : Z2.card, in: .capsule)
                .overlay { if !selected { Capsule().strokeBorder(Z2.border, lineWidth: 1) } }
                .contentShape(.capsule)
        }
        .buttonStyle(Z2Press(scale: 0.95))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(Z2.spring, value: selected)
    }
}

// MARK: - Surfaces

extension View {
    /// The card: #1A1726, continuous corners.
    func z2Card(radius: CGFloat = 18, padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Z2.card, in: .rect(cornerRadius: radius, style: .continuous))
    }

    /// A pushed screen: the ground behind it, an inline title.
    func z2Screen(_ title: String) -> some View {
        self.background(Z2.ground.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// "EXTRAS", "RECENT", "YOUR MESSAGE": small uppercase section labels.
struct Z2SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.footnote.weight(.semibold))
            .tracking(0.4)
            .foregroundStyle(Z2.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A clip-shaped preview with the 6 pt ring the mockups draw around it.
struct Z2ClipFrame<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(6)
            .background(Z2.bezel, in: .rect(cornerRadius: 20, style: .continuous))
    }
}

/// A row inside a grouped card: title (and detail) on the left, an accessory on the right.
struct Z2Row<Accessory: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        AdaptiveHStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(Z2.text)
                if let detail { Text(detail).font(.footnote).foregroundStyle(Z2.secondary) }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
    }
}

/// The hairline between rows of a grouped card.
struct Z2Divider: View {
    var body: some View { Rectangle().fill(Z2.hairline).frame(height: 1).padding(.leading, 16) }
}
