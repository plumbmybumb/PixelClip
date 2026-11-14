import CoreGraphics
import CoreText
import Foundation
import PixelClipKit

/// Sample content: used by "Add sample items" (Advanced ▸ Debug) and by the debug launch
/// arguments that drive the simulator screenshots (README ▸ Debug launch arguments):
///   -PixelClipDemo           seed the library (if empty) and sync it to the virtual clip
///   -PixelClipPlaylistDemo   a playlist of three things (a photo, a message, a one-off at 21:30)
///   -PixelClipScreen <name>  open send | draw | write | playlist | settings | calibrate | advanced |
///                       tarot | scenes | loops | reader | share | cantfind | resend
///   -PixelClipFlipped        the virtual clip with Flip Screen on (`orientation: flipped`)
///   -PixelClipOff -PixelClipSendPending [-PixelClipBackAfter <s>]   a send waiting for the clip (the capsule), the
///                       clip back in range after s seconds (the next 10 s look sends it)
///   -PixelClipTarot [-PixelClipTarotDraw <a,b,c | any | armed>] [-PixelClipTarotTurns <n>]   the Tarot as Now on the virtual
///                       clip, drawn (that row, or at random) and turned n times, or only armed (§5f.8)
///   -PixelClipScreen tarot | tarotreadings | tarotcard   the Tarot extra, its readings, L'Étoile's editor
@MainActor
enum DemoContent {
    #if DEBUG
    /// Screens a launch argument asked for that open themselves (Settings ▸ the calibration wizard).
    private static var requested: Set<String> = []
    /// `-PixelClipScreen tarotreadings | tarotcard`: how deep the Tarot extra opens (read once by it).
    static var tarotPath: String?

    /// True once for a screen requested with `-PixelClipScreen` (the screen then opens itself).
    static func consume(_ screen: String) -> Bool { requested.remove(screen) != nil }
    #endif

    static func applyLaunchArguments(library: LibraryStore, session: ClipSession, router: Router, sender: Sender) async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-PixelClipBattery"), i + 1 < args.count {
            let v = args[i + 1]
            await session.virtualClip.setBattery(pct: Int(v.prefix { $0.isNumber }) ?? 60, usb: v.hasSuffix("usb"))
        }
        if args.contains("-PixelClipReaderDemo") { ReaderStore.shared.seedDemo() }
        if args.contains("-PixelClipDemo") {
            if library.items.isEmpty { await addSamples(to: library) }
            if session.useVirtual {
                // Same document as every Send (Now + the playlist + readings).
                // Straight to the virtual clip (over its "Wi‑Fi"), as before the fast lane.
                var playlist = ClipDocument.playlist(library: library)
                if let p = try? await ReaderStore.shared.prepare(playlist, client: session.virtualClip) { playlist = p }
                if let p = try? await TarotReaderSend.prepare(playlist, client: session.virtualClip, library: library, clipPlaylist: nil) {
                    playlist = p
                }
                let report = await SyncEngine(client: session.virtualClip).sync(local: ClipDocument.localAssets(for: playlist, library: library),
                                                                           playlist: playlist, options: SyncOptions(endSession: false))
                await session.connect()
                if report.timeSet { session.recordClockSync() }
                if report.succeeded { ClipDocument.markSent(library: library, deviceID: session.status?.device.id) }
            }
        }
        if args.contains("-PixelClipPlaylistDemo") { await seedPlaylist(library: library) }
        if args.contains("-PixelClipTarot"), session.useVirtual {
            let settings = TarotSettings.shared
            if let item = try? await TarotMaker.make(spec: settings.spec, settings: settings, library: library) {
                NowOnClip.shared.set(library.content(for: item.id), title: item.name)
                var playlist = ClipDocument.playlist(library: library)
                if let p = try? await TarotReaderSend.prepare(playlist, client: session.virtualClip, library: library, clipPlaylist: nil) {
                    playlist = p
                }
                let report = await SyncEngine(client: session.virtualClip).sync(local: ClipDocument.localAssets(for: playlist, library: library),
                                                                                playlist: playlist, options: SyncOptions(endSession: true))
                if report.succeeded { ClipDocument.markSent(library: library, deviceID: session.status?.device.id) }
                let clip = session.virtualClip
                if let j = args.firstIndex(of: "-PixelClipTarotDraw"), args.indices.contains(j + 1) {
                    // "a,b,c" forces the row; anything else draws at random
                    let row = args[j + 1].split(separator: ",").compactMap { Int($0) }
                    if args[j + 1] == "armed" {
                        try? await VirtualClipClient.$transport.withValue(.bluetooth) { try await clip.oracleTurn() }   // a tap arms
                    } else {
                        try? await VirtualClipClient.$transport.withValue(.bluetooth) { try await clip.oracleDraw(cards: row.count == 3 ? row : nil) }
                    }
                    let turns = args.firstIndex(of: "-PixelClipTarotTurns").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 0
                    for _ in 0..<turns {
                        try? await Task.sleep(for: .milliseconds(1300))   // past any shuffle
                        try? await VirtualClipClient.$transport.withValue(.bluetooth) { try await clip.oracleTurn() }
                    }
                    try? await Task.sleep(for: .milliseconds(1300))
                    _ = await session.refresh()   // Home's Turn button reads /status.oracle
                }
                await session.updateVirtualScreen()
            }
        }
        if args.contains("-PixelClipNoBluetooth"), session.useVirtual {
            // Settings ▸ Debug ▸ Simulate BLE Unavailable: no fast lane, no doorbell (the Wi‑Fi path).
            session.simulateBluetoothUnavailable = true
        }
        if args.contains("-PixelClipFlipped"), session.useVirtual {
            // The virtual clip with Flip Screen on (orientation screenshots). Set as the fast lane
            // would, so no Wi‑Fi session starts.
            let clip = session.virtualClip
            _ = try? await VirtualClipClient.$transport.withValue(.bluetooth) { try await clip.putConfig(ClipConfig(orientation: .flipped)) }
            await session.updateVirtualScreen()
        }
        if args.contains("-PixelClipFreshClip") {
            // A factory-fresh virtual clip (nothing stored, clock unset): the next Send uploads everything.
            await session.resetVirtualClip()
        }
        if args.contains("-PixelClipSmokeItems") { await addSmokeItems(to: library) }
        // The demo's document (Now + the playlist) on the virtual clip, its session ended like any send.
        if args.contains("-PixelClipDemo"), session.useVirtual { sender.send(.playlist, kind: .quiet) }
        if args.contains("-PixelClipOff") {
            // The clip is away: Wi‑Fi off and nothing heard over Bluetooth (failure screenshots).
            await session.virtualClip.setReachable(false)
            await session.virtualClip.setBluetoothPresent(false)
            session.markSessionEnded()
        }
        if args.contains("-PixelClipSendPending") {
            // A send while the clip is away (with -PixelClipOff): the waiting capsule, looking every 10 s.
            sender.send(.playlist, kind: .quiet)
        }
        if let i = args.firstIndex(of: "-PixelClipBackAfter"), i + 1 < args.count, let s = Double(args[i + 1]) {
            // The clip comes back in range after `s` seconds: the waiting send's next look hears it and sends.
            let clip = session.virtualClip
            Task {
                try? await Task.sleep(for: .seconds(s))
                await clip.setBluetoothPresent(true)
                await clip.setReachable(true)
                sendLog("demo: the virtual clip is back in range")
            }
        }
        if args.contains("-PixelClipWiFiOff") {
            // Session over, Wi‑Fi off, but the clip is nearby: Connect/Send ring it over Bluetooth.
            if session.isConnected { try? await session.virtualClip.endSession() }
            await session.virtualClip.setReachable(false)
            session.markSessionEnded()
            await session.peekNearby()
        }
        if let i = args.firstIndex(of: "-PixelClipScreen"), i + 1 < args.count {
            try? await Task.sleep(for: .milliseconds(400))
            switch args[i + 1] {
            case "send":
                let photo = PlaceholderArt.sunsetPhoto()
                if let data = ImageLoader.pngData(photo), let m = try? MediaImporter.fromImageData(data, ext: "png", kind: .sample, name: "Golden Hour") {
                    router.openMedia(m, mode: .send)
                }
            case "draw": router.open(.draw(.send))
            case "write": router.open(.write(.send))
            case "playlist": router.open(.playlist)
            case "settings": router.open(.settings)
            case "calibrate": requested.insert("calibrate"); router.open(.settings)
            case "advanced": router.path = [.settings, .advanced]
            case "tarot": router.extra = ExtraRequest(extra: .tarot)
            case "tarotreadings", "tarotcard":
                router.extra = ExtraRequest(extra: .tarot)
                tarotPath = args[i + 1]
            case "scenes": router.extra = ExtraRequest(extra: .scenes)
            case "loops": router.extra = ExtraRequest(extra: .loops)
            case "reader": router.extra = ExtraRequest(extra: .reader, readerDocID: ReaderStore.shared.documents.first?.id)
            case "share": router.shareSheetPreview = true
            case "cantfind": router.cantFind = true
            case "resend": router.resend = library.items.max { $0.updatedAt < $1.updatedAt }?.id
            case "add": router.open(.playlist); try? await Task.sleep(for: .milliseconds(500)); router.addSomething = true
            default: break
            }
        }
        #endif
    }

    #if DEBUG
    /// `-PixelClipPlaylistDemo`: a photo, a message and a one-off at 21:30 (screenshots).
    static func seedPlaylist(library: LibraryStore) async {
        let store = PlaylistStore.shared
        guard store.entries.isEmpty else { return }
        if library.items.isEmpty { await addSamples(to: library) }
        if let photo = library.items.first(where: { $0.name == "Golden Hour" }) { store.add(.asset(photo.id), name: "Booth photo") }
        if let msg = library.items.first(where: { $0.name == "Hello" }) { store.add(.asset(msg.id), name: "“good night”") }
        if let orbit = library.items.first(where: { $0.name == "Orbit" }) {
            let e = store.add(.asset(orbit.id), name: "“happy birthday ♥”")
            store.setTime(e.id, at: PlaylistSchedule.upcoming(hour: 21, minute: 30))
        }
    }

    /// What Safari would hand the Share Extension for the sample article (screenshot harness).
    static let shareModel: ShareModel = {
        let m = ShareModel(title: "Le retour des trains de nuit", text: ReaderDemoTexts.trains,
                           url: URL(string: "https://example.com/trains-de-nuit"))
        return m
    }()
    #endif

    /// `-PixelClipSmokeItems` (the context-menu UI test): one item of every kind — a still and an animation
    /// (the samples), a created scrolling strip and a PixelClip pack piece.
    static func addSmokeItems(to library: LibraryStore) async {
        if !library.items.contains(where: { $0.source == .sample }) { await addSamples(to: library) }
        if let piece = StarterStore.shared.pieces.first { StarterStore.shared.add(piece, to: library) }
        if !library.items.contains(where: { $0.kind == .strip }) { await addSmokeStrip(to: library) }
        // A photo (newest, so it sits in the grid's first row).
        if !library.items.contains(where: { $0.source == .photo && $0.kind == .still }) {
            let photo = await Task.detached(priority: .userInitiated) { PlaceholderArt.sunsetPhoto() }.value
            let t = CropTransform(scale: CropTransform.fillScale(for: CGSize(width: photo.width, height: photo.height)))
            if let out = try? await Task.detached(operation: {
                try RenderWorker.render(images: [photo], durations: [0], transform: t, adjustments: ImageAdjustments(), encodeFile: true)
            }).value, let data = out.hca, let original = ImageLoader.pngData(photo) {
                _ = try? library.add(RenderedAsset(data: data, poster: out.preview.images.first, frameCount: 1, durationMs: 0,
                                                   edit: EditParams(transform: t, adjustments: ImageAdjustments(), fps: 0)),
                                     name: "Photo", source: .photo, original: original, originalExtension: "png")
            }
        }
    }

    private static func addSmokeStrip(to library: LibraryStore) async {
        let spec = MarqueeSpec(text: "Bonne nuit", motion: .scroll, speed: 120)
        let made = await Task.detached(priority: .userInitiated) { () -> (RenderedAsset, Data)? in
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 100, nil)
            guard let strip = MarqueeRenderer.renderStrip(spec, font: font) else { return nil }
            let p = CreationEncoder(dither: spec.dither).process(strip.image)
            guard let data = try? HCAEncoder.encodeStrip(p.frame) else { return nil }
            let edit = EditParams(transform: CropTransform(scale: 1), adjustments: ImageAdjustments(amoledDark: false, dither: spec.dither), fps: 0)
            let asset = RenderedAsset(data: data, poster: ClipRenderer.makeCGImage(StripScroller.firstScreen(p.frame)), frameCount: 1,
                                      durationMs: strip.passMs, edit: edit, strip: (strip.width, strip.scroll))
            return (asset, Raster.cgImage(strip.image).flatMap(ImageLoader.pngData) ?? Data())
        }.value
        guard let (asset, original) = made else { return }
        struct Recipe: Encodable { var creator = "text"; var spec: MarqueeSpec }
        _ = try? CreateLibrary.save(asset, original: original, name: "Bonne nuit", recipe: try? JSONEncoder().encode(Recipe(spec: spec)),
                                    replacing: nil, library: library)
    }

    /// Three items: a sunset still, an orbit animation and a scrolling message.
    static func addSamples(to library: LibraryStore) async {
        // Drawing is CPU work: keep it off the main actor.
        let art = await Task.detached(priority: .userInitiated) {
            (SourceFrames(images: [PlaceholderArt.sunsetPhoto()], delays: [0]),
             SourceFrames(images: PlaceholderArt.orbitFrames(), delays: Array(repeating: 0.06, count: 24)),
             SourceFrames(images: PlaceholderArt.marqueeFrames(), delays: Array(repeating: 0.05, count: 48)))
        }.value
        let photo = art.0.images[0], orbit = art.1.images, marquee = art.2.images
        let size = CGSize(width: photo.width, height: photo.height)
        let jobs: [(String, [CGImage], Double, CropTransform, LibraryItem.Source)] = [
            ("Golden Hour", [photo], 0, CropTransform(scale: CropTransform.fillScale(for: size) * 1.15, offsetY: -30), .sample),
            ("Orbit", orbit, 0.06, CropTransform(scale: 1), .sample),
            ("Hello", marquee, 0.05, CropTransform(scale: 1), .sample),
        ]
        for (name, images, delay, t, source) in jobs {
            let durations = Array(repeating: images.count > 1 ? delay : 0, count: images.count)
            let adjustments = ImageAdjustments()
            guard let out = try? await Task.detached(operation: {
                try RenderWorker.render(images: images, durations: durations, transform: t, adjustments: adjustments, encodeFile: true)
            }).value, let data = out.hca, let original = ImageLoader.pngData(images[0]) else { continue }
            let rendered = RenderedAsset(data: data, poster: out.preview.images.first, frameCount: images.count,
                                         durationMs: images.count > 1 ? Int(Double(images.count) * delay * 1000) : 0,
                                         edit: EditParams(transform: t, adjustments: adjustments, fps: images.count > 1 ? 1 / delay : 0))
            if let item = try? library.add(rendered, name: name, source: source, original: original, originalExtension: "png"),
               NowOnClip.shared.item == nil {
                NowOnClip.shared.set(.asset(item.id), title: item.name)   // the first sample is what PixelClip plays
            }
        }
    }
}
