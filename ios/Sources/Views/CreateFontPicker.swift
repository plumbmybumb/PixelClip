import SwiftUI
import PixelClipKit

/// The curated fonts grouped by mood, each name set in its own face, with weight and italic below.
/// Only fonts that are installed on this device are listed.
struct CreateFontPicker: View {
    @Binding var selection: FontSelection
    var sample: String = "Bonjour"
    var title: String = "Font"
    /// Only these fonts (`FontChoice.id`s); nil = every available one.
    var only: Set<String>? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        styleControls
                    }
                    ForEach(FontMood.allCases) { mood in
                        let fonts = CreateFonts.byMood(mood).filter { only?.contains($0.id) ?? true }
                        if !fonts.isEmpty {
                            Section(mood.rawValue) {
                                ForEach(fonts) { f in row(f).id(f.id) }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                // Open on the current font (the bundled faces sit below the system ones).
                .onAppear { proxy.scrollTo(selection.familyID, anchor: .center) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ f: FontChoice) -> some View {
        let selected = selection.familyID == f.id
        return Button {
            let weights = CreateFonts.weights(f).map(\.weight)
            // Keep the weight when the new family has it; otherwise the nearest one.
            let w = weights.min { abs($0 - selection.weight) < abs($1 - selection.weight) } ?? 0
            selection = FontSelection(familyID: f.id, weight: w, italic: selection.italic && CreateFonts.hasItalic(f))
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.name)
                        .font(CreateFonts.swiftUIFont(f, size: 22))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(sample)
                        .font(CreateFonts.swiftUIFont(f, size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(f.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var styleControls: some View {
        let f = CreateFonts.choice(selection.familyID)
        let weights = CreateFonts.weights(f)
        if weights.count > 1 {
            Picker("Weight", selection: $selection.weight) {
                ForEach(weights, id: \.weight) { w in Text(w.name).tag(w.weight) }
            }
        }
        if CreateFonts.hasItalic(f) {
            Toggle("Italic", isOn: $selection.italic)
        }
        if weights.count <= 1 && !CreateFonts.hasItalic(f) {
            Text("\(f.name) comes in one style.").foregroundStyle(.secondary)
        }
    }
}
