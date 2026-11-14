import SwiftUI
import PixelClipKit

/// An Extra, as a sheet (docs/DESIGN.md ▸ Extras): its mark, name and one line, a preview, the few
/// choices it needs, then Send to the clip (or add to the playlist instead). Drag down to close.
struct ExtraSheet: View {
    let request: ExtraRequest

    var body: some View {
        NavigationStack {
            Group {
                switch request.extra {
                case .tarot: TarotExtra(mode: request.mode)
                case .scenes: ScenesExtra(mode: request.mode)
                case .loops: LoopsExtra(mode: request.mode)
                case .reader: ReaderExtra(mode: request.mode, openDocID: request.readerDocID)
                }
            }
            .background(Z2.sheet.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Z2.sheet)
    }
}

/// The common frame of an Extra: header, content, the send buttons pinned at the bottom.
struct ExtraLayout<Content: View>: View {
    let extra: Extra
    let subtitle: String
    let mode: ComposeMode
    var working = false
    var disabled = false
    let send: () -> Void
    let addToPlaylist: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ExtraGlyph(extra: extra, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(extra.title).font(.title2.bold()).foregroundStyle(Z2.text).accessibilityAddTraits(.isHeader)
                        Text(subtitle).font(.footnote).foregroundStyle(Z2.secondary)
                    }
                }
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Z2SendButtons(mode: mode, working: working, disabled: disabled, send: send, addToPlaylist: addToPlaylist)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .background(Z2.sheet)
        }
    }
}

// MARK: - Scenes

/// The five live scenes (they run on the clip itself and follow how it's held), with their palettes.
struct ScenesExtra: View {
    let mode: ComposeMode
    @Environment(Sender.self) private var sender
    @Environment(\.dismiss) private var dismiss
    @AppStorage("scenes.chosen") private var scene = "sand"
    @State private var palette: String?

    var body: some View {
        let pal = SceneLook.palette(palette, for: scene)
        ExtraLayout(extra: .scenes, subtitle: "Live on the clip: tilt it and they move", mode: mode,
                    send: { sendScene(toPlaylist: false) }, addToPlaylist: { sendScene(toPlaylist: true) }) {
            Z2ClipFrame { SceneAnimation(scene: scene, palette: pal, bezel: false) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                ForEach(SceneCatalog.enabledIDs, id: \.self) { s in
                    Button {
                        withAnimation(Z2.spring) { scene = s; palette = nil }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            SceneAnimation(scene: s, bezel: false, playing: false)
                                .clipShape(.rect(cornerRadius: 8, style: .continuous))
                            Text(s.capitalized).font(.subheadline.weight(.semibold)).foregroundStyle(Z2.text)
                        }
                        .padding(8)
                        .background(Z2.card, in: .rect(cornerRadius: 14, style: .continuous))
                        .overlay {
                            if s == scene { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2) }
                        }
                    }
                    .buttonStyle(Z2Press(scale: 0.95))
                    .accessibilityLabel("\(s.capitalized) scene")
                    .accessibilityAddTraits(s == scene ? .isSelected : [])
                    .accessibilityIdentifier("scene.\(s)")
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(SceneLook.palettes(for: scene), id: \.self) { p in
                        Z2Chip(title: p.capitalized, selected: p == pal) { palette = p }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .sensoryFeedback(.selection, trigger: scene)
    }

    private func sendScene(toPlaylist: Bool) {
        let pal = SceneLook.palette(palette, for: scene)
        let content = MomentContent.scene(scene, params: SceneLook.params(scene: scene, palette: pal))
        let title = "\(scene.capitalized) · \(pal)"
        if toPlaylist { sender.addToPlaylist(content, name: title) } else { sender.sendNow(content, title: title) }
        dismiss()
    }
}

// MARK: - Loops

/// The 20 PixelClip pack loops.
struct LoopsExtra: View {
    let mode: ComposeMode
    @Environment(LibraryStore.self) private var library
    @Environment(Sender.self) private var sender
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: StarterPiece? = StarterStore.shared.pieces.first
    @State private var big: ClipFrames?

    var body: some View {
        ExtraLayout(extra: .loops, subtitle: "Twenty little animations made for the clip", mode: mode, disabled: chosen == nil,
                    send: { sendLoop(toPlaylist: false) }, addToPlaylist: { sendLoop(toPlaylist: true) }) {
            Z2ClipFrame {
                ClipScreenPreview(frames: big, glow: true, bezel: false, accessibilityLabel: chosen.map { "\($0.title), playing" } ?? "")
            }
            if let chosen {
                Text(chosen.title).font(.headline).foregroundStyle(Z2.text)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(StarterStore.shared.pieces) { piece in
                    LoopTile(piece: piece, selected: piece == chosen) { chosen = piece }
                }
            }
        }
        .task(id: chosen?.slug) {
            guard let chosen else { return }
            big = StarterStore.shared.cachedFrames(chosen)
            big = await StarterStore.shared.frames(chosen)
        }
        .sensoryFeedback(.selection, trigger: chosen)
    }

    private func sendLoop(toPlaylist: Bool) {
        guard let chosen, let item = StarterStore.shared.add(chosen, to: library) else { return }
        if toPlaylist { sender.addToPlaylist(.asset(item.id), name: item.name) } else { sender.sendNow(.asset(item.id), title: item.name) }
        dismiss()
    }
}

private struct LoopTile: View {
    let piece: StarterPiece
    let selected: Bool
    let action: () -> Void
    @State private var frames: ClipFrames?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                ClipScreenPreview(frames: frames ?? StarterStore.shared.cachedFrames(piece), glow: false, bezel: false, playing: false,
                                  accessibilityLabel: piece.title)
                Text(piece.title).font(.caption.weight(.semibold)).foregroundStyle(Z2.text).lineLimit(1)
            }
            .padding(6)
            .background(Z2.card, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2) }
            }
        }
        .buttonStyle(Z2Press(scale: 0.95))
        .accessibilityLabel(piece.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: piece.slug) { frames = await StarterStore.shared.frames(piece) }
    }
}


/// The PixelClip pack bundled with the app (`PixelClip.app/Starter/`: 20 approved loops + `starter.json`).
/// Previews decode the real `.hca` files (what the clip will play), off the main thread, cached.
@MainActor @Observable
final class StarterStore {
    static let shared = StarterStore()

    let pieces: [StarterPiece]
    @ObservationIgnored private var cache: [String: ClipFrames] = [:]
    @ObservationIgnored private let folder: URL?

    init(bundle: Bundle = .main) {
        folder = bundle.url(forResource: "Starter", withExtension: nil)
        pieces = folder.flatMap { try? Data(contentsOf: $0.appendingPathComponent("starter.json")) }
            .flatMap { try? StarterPack.pieces(manifest: $0) } ?? []
    }

    func data(_ piece: StarterPiece) -> Data? {
        folder.flatMap { try? Data(contentsOf: $0.appendingPathComponent(piece.file)) }
    }

    func cachedFrames(_ piece: StarterPiece) -> ClipFrames? { cache[piece.slug] }

    func frames(_ piece: StarterPiece) async -> ClipFrames? {
        if let hit = cache[piece.slug] { return hit }
        guard let url = folder?.appendingPathComponent(piece.file) else { return nil }
        let frames = await Task.detached(priority: .userInitiated) { () -> ClipFrames? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? ClipFrames.decode(data)
        }.value
        if let frames { cache[piece.slug] = frames }
        return frames
    }

    /// Adds a piece to the library (once) and returns its item.
    @discardableResult
    func add(_ piece: StarterPiece, to library: LibraryStore) -> LibraryItem? {
        guard let data = data(piece) else { return nil }
        return try? library.addStarter(piece, data: data)
    }

    /// After an app update: pieces already in the library whose bundled file changed get re-imported
    /// (size differs → compare bytes). Returns the refreshed items.
    @discardableResult
    func refreshStale(in library: LibraryStore) -> [LibraryItem] {
        pieces.compactMap { piece in
            guard let existing = library.item(piece.assetID), existing.byteSize != piece.bytes, let data = data(piece) else { return nil }
            let refreshed = try? library.addStarter(piece, data: data)
            return refreshed?.sha256 == existing.sha256 ? nil : refreshed
        }
    }
}



// Live scenes (sand, water, snow, fire, balls) run on PixelClip's firmware: they cost no storage and
// react to how the clip is held. The app can't run the firmware's simulation, so the previews are
// looping illustrations drawn here in the scene's real palette (`SceneLook`, from core/src/scene.c),
// on the clip's pixel grid.

/// An animated, illustrative preview of a live scene in a palette, as a clip screen.
struct SceneAnimation: View {
    let scene: String
    var palette: String?
    var bezel = true
    var playing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        let pal = SceneLook.palette(palette, for: scene)
        ZStack {
            if bezel {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.09))
            }
            Group {
                if playing && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                        SceneCanvas(scene: scene, palette: pal, t: ctx.date.timeIntervalSince(start))
                    }
                } else {
                    SceneCanvas(scene: scene, palette: pal, t: 2.4)
                }
            }
            .background(.black)
            .clipShape(.rect(cornerRadius: 9, style: .continuous))
            .padding(bezel ? 3 : 0)
        }
        .aspectRatio(ClipCanvas.aspect, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(scene.capitalized) live scene, \(pal)")
        .accessibilityAddTraits(.isImage)
    }
}

/// One frame of the illustration at time `t` (seconds), in 8-px cells of the 536 × 240 screen.
private struct SceneCanvas: View {
    let scene: String
    let palette: String
    let t: Double

    private static let cols = 67, rows = 30

    var body: some View {
        Canvas(rendersAsynchronously: false) { gc, size in
            let cw = size.width / CGFloat(Self.cols), ch = size.height / CGFloat(Self.rows)
            func cell(_ x: Int, _ y: Int, _ v: Double) {
                guard v > 0.02 else { return }
                let c = SceneLook.color(palette, at: v)
                gc.fill(Path(CGRect(x: CGFloat(x) * cw, y: CGFloat(y) * ch, width: cw + 0.5, height: ch + 0.5)),
                        with: .color(Color(red: c.r, green: c.g, blue: c.b)))
            }
            switch scene {
            case "fire": fire(cell)
            case "water": water(cell)
            case "snow": snow(cell)
            case "balls": balls(gc, size: size)
            default: sand(cell)
            }
        }
    }

    private func hash(_ x: Int, _ y: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Double(h & 0xFFFF) / 65_535
    }

    private func fire(_ cell: (Int, Int, Double) -> Void) {
        let R = Self.rows
        for x in 0..<Self.cols {
            let fx = Double(x)
            let height = 15 + 6 * sin(fx * 0.31 + t * 2.1) + 4 * sin(fx * 0.77 - t * 3.3) + 3 * sin(fx * 0.13 + t * 1.3)
            for y in 0..<R {
                let up = Double(R - 1 - y)
                let flicker = 0.12 * sin(fx * 1.7 + up * 0.9 + t * 9) + 0.1 * (hash(x, y + Int(t * 12)) - 0.5)
                cell(x, y, max(0, min(1, 1.05 - up / max(4, height) + flicker)))
            }
        }
    }

    private func water(_ cell: (Int, Int, Double) -> Void) {
        let R = Double(Self.rows)
        let tilt = sin(t * 0.6) * 5
        for x in 0..<Self.cols {
            let fx = Double(x)
            let surface = R * 0.45 + tilt * (fx / Double(Self.cols) - 0.5) * 2
                + 1.6 * sin(fx * 0.22 - t * 2.2) + 0.8 * sin(fx * 0.53 + t * 1.6)
            for y in 0..<Self.rows {
                let depth = Double(y) - surface
                guard depth >= 0 else { continue }
                let crest = depth < 1.2 ? 0.35 : 0
                let shimmer = 0.08 * sin(fx * 0.9 + Double(y) * 0.7 + t * 3)
                cell(x, y, max(0.25, min(1, 0.85 - depth / R * 0.9 + crest + shimmer)))
            }
        }
    }

    private func sand(_ cell: (Int, Int, Double) -> Void) {
        let R = Self.rows
        let lean = sin(t * 0.35) * 0.45
        var top = [Double](repeating: 0, count: Self.cols)
        for x in 0..<Self.cols {
            let fx = Double(x) / Double(Self.cols - 1) - 0.5
            top[x] = Double(R) * (0.62 - lean * fx - 0.05 * sin(Double(x) * 0.4 + t * 0.5))
            for y in Int(max(0, top[x]))..<R { cell(x, y, 0.45 + 0.4 * hash(x, y)) }
        }
        // A stream of grains pouring from the top and settling on the pile.
        for i in 0..<26 {
            let x = (i * 37 + Int(t * 3)) % Self.cols
            let speed = 7 + Double(i % 5)
            let y = (t * speed + Double(i) * 1.7).truncatingRemainder(dividingBy: max(1, top[x]))
            cell(x, Int(y), 0.75 + 0.25 * hash(i, 3))
        }
    }

    private func snow(_ cell: (Int, Int, Double) -> Void) {
        let R = Double(Self.rows)
        for x in 0..<Self.cols {
            let drift = R - 3 - 1.5 * sin(Double(x) * 0.17 + 1) - 0.8 * sin(Double(x) * 0.5 + t * 0.2)
            for y in Int(max(0, drift))..<Self.rows { cell(x, y, 0.55 + 0.35 * hash(x, y)) }
        }
        for i in 0..<70 {
            let speed = 2.5 + Double(i % 7) * 0.6
            let y = (t * speed + Double(i) * 3.1).truncatingRemainder(dividingBy: R)
            let x = (Double(i * 53 % Self.cols) + 2.5 * sin(t * 0.8 + Double(i))).truncatingRemainder(dividingBy: Double(Self.cols))
            cell((Int(x) + Self.cols) % Self.cols, Int(y), 0.7 + 0.3 * hash(i, 7))
        }
    }

    private func balls(_ gc: GraphicsContext, size: CGSize) {
        let s = size.width / CGFloat(ClipCanvas.width)
        for i in 0..<9 {
            let r = 12 + Double(i % 4) * 4
            let w = Double(ClipCanvas.width) - 2 * r, h = Double(ClipCanvas.height) - 2 * r
            let vx = 60 + Double(i) * 17
            let p = (Double(i) * 97 + t * vx).truncatingRemainder(dividingBy: 2 * w)
            let x = r + (p < w ? p : 2 * w - p)
            let bounce = abs(sin(t * (1.6 + Double(i) * 0.21) + Double(i)))
            let y = r + h * (1 - bounce * (0.55 + 0.45 * Double(i % 3) / 2))
            let c = SceneLook.color(palette, at: 0.55 + 0.45 * Double(i) / 8)
            gc.fill(Path(ellipseIn: CGRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s)),
                    with: .color(Color(red: c.r, green: c.g, blue: c.b)))
        }
    }
}

