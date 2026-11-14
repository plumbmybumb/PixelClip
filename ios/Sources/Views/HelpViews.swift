import SwiftUI
import PixelClipKit

// Help in plain words: the card a failed calibration shows, and Settings ▸ "Can't find the clip?".

// MARK: - Problem card

/// Inline, with a way forward — what went wrong in plain words, and Connection Help when it applies.
struct ProblemCard: View {
    let problem: SendProblem
    var onHelp: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(systemImage: problem.systemImage, tint: .orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(problem.title).font(.headline)
                Text(problem.message).font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if problem.needsConnectionHelp, let onHelp {
                    Button("Connection Help", action: onHelp)
                        .font(.body.weight(.semibold))
                        .buttonStyle(.borderless)
                        .padding(.top, 2)
                        .accessibilityHint("Shows the steps to connect to the clip")
                }
            }
            Spacer(minLength: 0)
        }
        .card()
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Steps

/// One numbered or iconed row: 34 pt tile, headline, secondary text.
struct GuideRow: View {
    let systemImage: String
    let title: String
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(systemImage: systemImage, tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Can't find the clip?

/// Settings ▸ If something's off ▸ Can't find the clip?: the buttons, staying near, Bluetooth.
struct CantFindClipSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GuideRow(systemImage: "power", title: "Is it on?",
                             text: "Tap the bottom button once to turn the clip on. To turn it off, hold the top button until it says “bye”.")
                    GuideRow(systemImage: "iphone.radiowaves.left.and.right", title: "Keep your iPhone near",
                             text: "The clip and your iPhone find each other within a few steps. Anything you send while it’s away waits, and goes by itself when the clip is near.")
                    GuideRow(systemImage: "dot.radiowaves.left.and.right", title: "Bluetooth on",
                             text: "PixelClip uses Bluetooth to wake the clip. If it’s off, turn it on in Control Center; if PixelClip isn’t allowed, turn it on in the Settings app ▸ Apps ▸ PixelClip.")
                    GuideRow(systemImage: "battery.25percent", title: "It says “Battery low”",
                             text: "Charge it for a few minutes over USB‑C, then try again.")
                    GuideRow(systemImage: "wifi", title: "iPhone asks to join “PixelClip-…”",
                             text: "Tap Join. It’s the clip’s own little network, only for big pictures; your iPhone goes back to your usual Wi‑Fi afterwards.")
                }
                .padding(20)
            }
            .background(Z2.sheet.ignoresSafeArea())
            .navigationTitle("Can’t find the clip?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
