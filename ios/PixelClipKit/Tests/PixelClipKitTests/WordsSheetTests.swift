import CoreText
import XCTest
@testable import PixelClipKit

/// §5b.1 "Words": the sheet the app renders (size picking, frames, the .hca, the id), the item it composes to, and
/// the virtual clip's validation, current and still.
final class WordsSheetTests: XCTestCase {
    static let registered: Void = { _ = BundledFontsTests.registered }()
    /// Write's Bold look (Fredoka Bold) and DOTS (DotGothic16 through the LED pattern).
    static func spec(_ text: String, led: Bool = false) -> WordsSheetSpec {
        _ = registered
        return led ? WordsSheetSpec(text: text, font: FontSelection(familyID: "dotgothic16"), led: true, ledPitch: 5, tracking: 0.04)
                   : WordsSheetSpec(text: text, font: FontSelection(familyID: "fredoka", weight: 0.4))
    }
    static let twelve = "belle nuit sur la ville où les toits dorment sous la lune ✦"

    func font(_ s: WordsSheetSpec) -> (CGFloat) -> CTFont { { FontCatalog.ctFont(for: s.font, size: $0) } }

    func testSizePickingIsAsLargeAsTheLimitsAllow() throws {
        for text in ["bonjour", Self.twelve] {
            let s = Self.spec(text)
            XCTAssertEqual(s.words.count, text == "bonjour" ? 1 : 12)
            let m = try XCTUnwrap(WordsSheetRenderer.pickSize(s, makeFont: font(s)))
            XCTAssertTrue(m.fits, text)
            XCTAssertLessThanOrEqual(m.capHeight, 72)
            XCTAssertLessThanOrEqual(m.lineHeight, 96)
            XCTAssertLessThanOrEqual(m.widest, 360)
            XCTAssertLessThanOrEqual(m.inkArea, 0.45 * 536 * 240)
            XCTAssertLessThanOrEqual(m.inks.count * m.frameWidth * m.frameHeight, 514_560)
            // As large as allowed: half a point more breaks a limit.
            XCTAssertFalse(WordsSheetRenderer.measure(s, size: m.size + 0.5, makeFont: font(s)).fits, text)
            print("WORDS_SIZE \(s.words.count) words: \(String(format: "%.2f", m.size)) pt, cap \(Int(m.capHeight)) px, widest \(Int(m.widest)) px, ink \(Int(m.inkArea / (536 * 240) * 100)) %")
        }
        // One short word is bounded by the line height (Fredoka's tall line), twelve by the ink area.
        let one = try XCTUnwrap(WordsSheetRenderer.pickSize(Self.spec("bonjour"), makeFont: font(Self.spec("bonjour"))))
        let many = try XCTUnwrap(WordsSheetRenderer.pickSize(Self.spec(Self.twelve), makeFont: font(Self.spec(Self.twelve))))
        XCTAssertGreaterThan(one.size, many.size)
        XCTAssertGreaterThan(one.lineHeight, 95, "a single word: as tall as a line may be")
        XCTAssertGreaterThan(many.inkArea, 0.43 * 536 * 240, "twelve words: as much ink as allowed")
        XCTAssertEqual(WordsSheetRenderer.words("a b c d e f g h i j k l m n"), Array("abcdefghijkl").map(String.init), "at most 12")
        XCTAssertNil(WordsSheetRenderer.pickSize(Self.spec("   "), makeFont: font(Self.spec(" "))))
    }

    func testFramesAreTheLargestWordBoxPlusTwoWithTheWordCentredOnBlack() throws {
        for led in [false, true] {
            let sheet = try WordsSheetRenderer.render(Self.spec("bonne nuit Lune", led: led))
            XCTAssertEqual(sheet.frames.count, 3)
            XCTAssertTrue(sheet.frames.allSatisfy { $0.width == sheet.width && $0.height == sheet.height })
            var widest = 0, tallest = 0
            for f in sheet.frames {
                let box = try XCTUnwrap(WordsSheetRenderer.inkBox(f), "every word has ink")
                widest = max(widest, box.w); tallest = max(tallest, box.h)
                // Black outside the ink box (the clip's transparency), and the box roughly centred.
                for y in 0..<f.height { for x in 0..<f.width where !(box.x..<(box.x + box.w)).contains(x) || !(box.y..<(box.y + box.h)).contains(y) {
                    XCTAssertEqual(f.pixels[y * f.width + x], 0)
                } }
                XCTAssertLessThanOrEqual(abs((box.x + box.w / 2) - f.width / 2), led ? 4 : 2, "centred")
                XCTAssertLessThanOrEqual(abs((box.y + box.h / 2) - f.height / 2), led ? 4 : 2)
                XCTAssertTrue(f.pixels.contains { $0 == BrandPalette.accentPixel } || led, "the look's colour")
            }
            XCTAssertLessThanOrEqual(sheet.width, widest + 2 + (led ? 4 : 1))
            XCTAssertGreaterThanOrEqual(sheet.width, widest)
            XCTAssertLessThanOrEqual(sheet.height, tallest + 2 + (led ? 4 : 1))
            // The .hca: N frames of w × h, the sprite flag, within the limits; decodes to the same pixels.
            let file = try HCAFile(data: sheet.data)
            XCTAssertEqual([file.width, file.height, file.frameCount], [sheet.width, sheet.height, 3])
            XCTAssertTrue(file.isGlyphAtlas)
            XCTAssertTrue(WordsScene.isValidSheet(width: file.width, height: file.height, frames: file.frameCount))
            XCTAssertEqual(try file.decodeAllFrames(), sheet.frames)
        }
    }

    func testSheetIDIsStable() throws {
        let a = try WordsSheetRenderer.render(Self.spec("bonne nuit Lune"))
        let b = try WordsSheetRenderer.render(Self.spec("bonne  nuit\nLune"))
        XCTAssertEqual(a.id, b.id, "same words, same look → same id")
        XCTAssertEqual(a.data, b.data)
        XCTAssertTrue(a.id.hasPrefix("words-") && HCA.isValidAssetID(a.id), a.id)
        XCTAssertNotEqual(a.id, try WordsSheetRenderer.render(Self.spec("bonne nuit Lune", led: true)).id, "another look")
        XCTAssertNotEqual(a.id, try WordsSheetRenderer.render(Self.spec("bonne nuit")).id, "other words")
    }

    func testRestingStillPutsTheWordsAlongTheBottom() throws {
        let sheet = try WordsSheetRenderer.render(Self.spec(Self.twelve))
        let still = WordsSheetRenderer.restingStill(sheet.frames)
        XCTAssertEqual([still.width, still.height], [536, 240])
        let box = try XCTUnwrap(WordsSheetRenderer.inkBox(still))
        XCTAssertGreaterThanOrEqual(box.y + box.h, 236, "resting on the bottom edge")
        XCTAssertGreaterThan(box.y, 0, "piled from the bottom, not filling the screen")
    }

    // MARK: The item

    func testComposedItemJSON() throws {
        let content = MomentContent.words(sheet: "words-0123456789", text: "bonne nuit")
        XCTAssertEqual(content.type, .scene)
        XCTAssertEqual(content.assetID, "words-0123456789")
        XCTAssertEqual(content.clipCurrentID, "scene:words")
        let slot = try XCTUnwrap(NowItem(content: content, title: "“bonne nuit”").slot { _ in nil })
        let json = try jsonObject(ClipJSON.encoder().encode(slot.item)) as! NSDictionary
        XCTAssertEqual(json["type"] as? String, "scene")
        XCTAssertEqual(json["scene"] as? String, "words")
        XCTAssertEqual(json["id"] as? String, "words-0123456789")
        XCTAssertEqual((json["params"] as? NSDictionary)?["bounce"] as? Int, 60)
        XCTAssertEqual(slot.item.assetRefs, ["words-0123456789"], "the sync uploads the sheet")
        // A queue entry carries the sheet in `asset`.
        let m = Moment(id: "t-w", at: 1_800_000_000, content: content, durationS: 60, title: "Words")
        let entry = try jsonObject(ClipJSON.encoder().encode(m.entry)) as! NSDictionary
        XCTAssertEqual(entry["scene"] as? String, "words")
        XCTAssertEqual(entry["asset"] as? String, "words-0123456789")
        XCTAssertEqual(m.entry.assetRefs, ["words-0123456789"])
        XCTAssertEqual(m.entry.asPlaylistItem.id, "words-0123456789")
        // Read back from an item (the text isn't on the clip).
        XCTAssertEqual(MomentContent(item: slot.item), .words(sheet: "words-0123456789", text: ""))
        XCTAssertTrue(MomentContent(item: slot.item)!.sameContent(as: content))
        let pl = Playlist(items: [slot.item])
        XCTAssertEqual(pl.assetIDs, ["words-0123456789"])
        // A plan drops a words item whose sheet is neither local nor on the clip.
        XCTAssertTrue(SyncEngine.plan(local: [], playlist: pl, remote: [], options: SyncOptions()).playlist.items.isEmpty)
    }

    // MARK: The virtual clip

    func testVirtualClipValidatesAndShowsTheWords() async throws {
        let clip = VirtualClipClient(options: .instant)
        let sheet = try WordsSheetRenderer.render(Self.spec("bonne nuit Lune"))
        let item = PlaylistItem.words(sheet: sheet.id, durationMs: 0)
        await expectHTTP(422, "unknown_asset") { try await clip.putPlaylist(Playlist(items: [item])) }
        var noID = item
        noID.id = nil
        await expectHTTP(422, "invalid_playlist") { try await clip.putPlaylist(Playlist(items: [noID])) }
        _ = try await clip.putAsset(id: sheet.id, data: sheet.data, progress: nil)
        // Not a sheet: a full-screen picture (13 frames would be too many too).
        _ = try await clip.putAsset(id: "pic", data: try clipAsset(0x1234), progress: nil)
        var notSheet = item
        notSheet.id = "pic"
        try await clip.putPlaylist(Playlist(items: [notSheet]))   // 536×240 × 1 is within the limits…
        let thirteen = try HCAEncoder.encode(frames: (0..<13).map { _ in .init(pixels: RGB565Frame(width: 40, height: 20, fill: 0xFFFF), durationMs: 0) },
                                             glyphAtlas: true)
        _ = try await clip.putAsset(id: "words-13", data: thirteen, progress: nil)
        notSheet.id = "words-13"
        await expectHTTP(422, "invalid_playlist") { try await clip.putPlaylist(Playlist(items: [notSheet])) }
        // The sheet can't be shown as a picture.
        await expectHTTP(422, "unknown_asset") { try await clip.putPlaylist(Playlist(items: [.asset(sheet.id, durationMs: 0)])) }
        try await clip.putPlaylist(Playlist(items: [item]))
        let st = try await clip.status()
        XCTAssertEqual(st.playlist.current, "scene:words")
        let d = await clip.display()
        XCTAssertEqual(d.frame, WordsSheetRenderer.restingStill(sheet.frames), "the words resting along the bottom")
        // POST /show of the sheet shows it as the words scene (it's in use by a words item).
        try await clip.putPlaylist(Playlist(items: [.asset("pic", durationMs: 0), item]))
        try await clip.show(id: sheet.id, durationMs: nil, scroll: nil)
        let shown = try await clip.status()
        XCTAssertEqual(shown.playlist.current, "scene:words")
        // A sheet no words item uses can't be shown as a picture (404, as the firmware's http_api.c).
        await expectHTTP(404, "unknown_asset") { try await clip.show(id: "words-13", durationMs: nil, scroll: nil) }
        try await clip.putPlaylist(Playlist(items: [item]))
        // Deleting the sheet drops the item.
        try await clip.deleteAsset(id: sheet.id)
        let pl = try await clip.playlist()
        XCTAssertTrue(pl.items.isEmpty)
    }
}
