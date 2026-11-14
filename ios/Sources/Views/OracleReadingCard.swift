import SwiftUI
import PixelClipKit

/// The Tarot's reading on Home (PROTOCOL §5f.1, §5f.7): while the Tarot is Now and the clip has drawn its row, the
/// three cards with their keywords and, larger than the clip can show it, the lean draw's five lines (by card, by
/// position, by the numbers, together, and; the one on the clip highlighted while it shows), the three cards' briefs
/// (the one on the clip highlighted during the detail screens), then the whole paragraph, which the clip no longer
/// shows. The texts are the app's own from the row with the oracle's saved bundle (`SentenceReader`, the same bytes
/// as the clip; the "and" screen's fit is judged in the oracle's body font, as the clip does); the clip's `reading`
/// stands in when the bundle isn't on this iPhone.
struct OracleReadingCard: View {
    let oracleID: String
    @Environment(ClipSession.self) private var session
    @Environment(LibraryStore.self) private var library
    /// The oracle's saved bundle, parsed once per bundle (an empty view never runs a `.task`, so no lazy load).
    private var reader: SentenceReader? { OracleBundleCache.shared.reader(forOracle: oracleID, library: library) }

    var body: some View {
        Group {
            if let shown {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(shown.cards.enumerated()), id: \.offset) { _, card in
                            cardView(card)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    if !shown.lean.isEmpty {
                        lines(shown.lean, current: shown.leanPage)
                            .accessibilityIdentifier("oracleLean")
                    }
                    if !shown.briefs.isEmpty {
                        Divider().overlay(Z2.hairline)
                        lines(shown.briefs, current: shown.detailPage, font: .system(.body, design: .serif))
                            .accessibilityIdentifier("oracleBriefs")
                    }
                    if !shown.paragraph.isEmpty {
                        Divider().overlay(Z2.hairline)
                        Text(shown.paragraph)
                            .font(.system(.body, design: .serif))
                            .foregroundStyle(Z2.text)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("oracleParagraph")
                    }
                }
                .padding(16)
                .background(Z2.card, in: .rect(cornerRadius: 22, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("The cards’ sentence")
            }
        }
        .animation(Z2.spring, value: shown)
        // The "and" screen's fit is judged in the oracle's body font (rendered once, off the main actor).
        .task(id: oracleID) { _ = await TarotFontStore.shared.fonts(textSize) }
    }

    /// Lines in order, `current` (an index into them) in full colour and the others dimmed; all full when nil.
    private func lines(_ items: [(Int, String)], current: Int?, font: Font = .system(.title3, design: .serif)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items, id: \.0) { k, line in
                Text(line)
                    .font(font)
                    .foregroundStyle(current == nil || current == k ? Z2.text : Z2.secondary.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private struct Shown: Equatable {
        var cards: [Int]
        /// The lean screens with their index 0–4 (empty ones left out).
        var lean: [(Int, String)]
        /// The cards' briefs with their detail index 0–2 (cards without one left out).
        var briefs: [(Int, String)]
        var paragraph: String
        /// The lean screen / detail card on the clip, nil when it isn't showing one.
        var leanPage: Int?
        var detailPage: Int?
        static func == (l: Shown, r: Shown) -> Bool {
            l.cards == r.cards && l.lean.map(\.1) == r.lean.map(\.1) && l.lean.map(\.0) == r.lean.map(\.0)
                && l.briefs.map(\.1) == r.briefs.map(\.1) && l.briefs.map(\.0) == r.briefs.map(\.0)
                && l.paragraph == r.paragraph && l.leanPage == r.leanPage && l.detailPage == r.detailPage
        }
    }

    private var textSize: TarotTextSize { library.oracleRecipe(for: oracleID)?.spec.textSize ?? .large }

    /// The row drawn and what to say about it, when there is something to show.
    private var shown: Shown? {
        guard let o = session.oracleNow, let three = o.three else { return nil }
        let page = o.page >= 0 ? o.page : nil
        let leanPage = o.state == .lean ? page : nil
        let detailPage = o.state == .detail ? page : nil
        guard let reader else {
            // No bundle on this iPhone: the clip's own text for the screen it shows (or its paragraph).
            guard let text = o.reading, !text.isEmpty else { return nil }
            let onScreen = o.state == .lean || o.state == .detail
            return Shown(cards: three, lean: onScreen ? [(0, text)] : [], briefs: [], paragraph: onScreen ? "" : text,
                         leanPage: nil, detailPage: nil)
        }
        let fits: ((String) -> Bool)? = TarotFontStore.shared.cached(textSize).map { f in
            let face = ReaderBoundFont(f.body).normal
            return { OracleScreens.fitsLeanPage($0, face: face) }
        }
        let lean = (reader.composeLean(a: three[0], b: three[1], c: three[2], fits: fits) ?? [])
            .enumerated().filter { !$0.element.isEmpty }.map { ($0.offset, $0.element) }
        let briefs = three.enumerated().compactMap { k, card in
            reader.field(card, .brief).flatMap { $0.isEmpty ? nil : (k, $0) }
        }
        let paragraph = reader.compose(a: three[0], b: three[1], c: three[2])?.text ?? ""
        guard !lean.isEmpty || !briefs.isEmpty || !paragraph.isEmpty else { return nil }
        return Shown(cards: three, lean: lean, briefs: briefs, paragraph: paragraph, leanPage: leanPage, detailPage: detailPage)
    }

    private func cardView(_ i: Int) -> some View {
        let keyword = reader?.field(i, .kw) ?? TarotBundle.shared.readings?[i]?.keyword(.fr) ?? ""
        return VStack(spacing: 6) {
            Group {
                if let img = TarotBundle.shared.face(i) {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Z2.bezel).aspectRatio(236.0 / 448.0, contentMode: .fit)
                }
            }
            .frame(maxWidth: 96)
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            Text(keyword)
                .font(.footnote.weight(.semibold))
                .italic()
                .foregroundStyle(Color.accentColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reader?.field(i, .name) ?? TarotBundle.shared.title(i, language: .fr)), \(keyword)")
    }
}

/// Parsed phrase bundles of the library's oracles, by bundle id (they are content-hashed).
@MainActor
final class OracleBundleCache {
    static let shared = OracleBundleCache()
    private var readers: [String: SentenceReader] = [:]

    func reader(forOracle id: String, library: LibraryStore) -> SentenceReader? {
        guard let key = library.oracleRecipe(for: id)?.reader else { return nil }
        if let r = readers[key] { return r }
        guard let r = library.sentenceReader(forOracle: id) else { return nil }
        readers[key] = r
        return r
    }
}
