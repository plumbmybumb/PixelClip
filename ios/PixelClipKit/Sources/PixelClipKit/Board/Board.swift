import Foundation

/// PROTOCOL §5g: a *board* is a sheet of row pictures; the clip shows the header fixed at the top, stacks the rows
/// whose `until` is still ahead of its clock, scrolls them when they're taller than the screen and shows the empty
/// row when none remains. The clip knows nothing about what the rows mean.
public struct BoardRow: Codable, Sendable, Hashable {
    public var frame: Int
    /// Unix seconds: the row shows while the clock is before it (nil: always).
    public var until: Int?
    public init(frame: Int, until: Int? = nil) { self.frame = frame; self.until = until }
}

/// A board item as the app keeps it in Now / the playlist / a moment.
public struct BoardContent: Codable, Sendable, Hashable {
    public var sheet: String
    public var header: Int?
    public var empty: Int?
    public var rows: [BoardRow]
    public var scrollPxS: Int

    public init(sheet: String, header: Int?, empty: Int?, rows: [BoardRow], scrollPxS: Int = Board.defaultSpeed) {
        self.sheet = sheet; self.header = header; self.empty = empty; self.rows = rows; self.scrollPxS = scrollPxS
    }

    /// `{"type":"board","id":"<sheet>","header":0,"empty":1,"rows":[…],"scroll_px_s":16,…}`.
    public func playlistItem(durationMs: Int = PlaybackEngine.sceneDefaultMs, transition: Transition? = .fade) -> PlaylistItem {
        PlaylistItem(type: .board, id: sheet, durationMs: durationMs, transition: transition,
                     header: header, empty: empty, rows: rows, scrollPxS: scrollPxS)
    }

    /// A `queue[]` entry: the sheet in `asset` (`id` is the entry's own).
    public func queueEntry(id: String, at: Int, durationMs: Int, transition: Transition) -> QueueEntry {
        var e = QueueEntry(id: id, at: at, type: .board, asset: sheet, durationMs: durationMs, transition: transition)
        e.header = header; e.empty = empty; e.rows = rows; e.scrollPxS = scrollPxS
        return e
    }

    /// Read back from an item.
    public init?(item: PlaylistItem) {
        guard item.type == .board, let id = item.id, let rows = item.rows else { return nil }
        self.init(sheet: id, header: item.header, empty: item.empty, rows: rows, scrollPxS: item.scrollPxS ?? Board.defaultSpeed)
    }
}

public enum Board {
    /// §5g limits.
    public static let maxFrames = 48
    public static let maxRows = 47
    public static let minHeight = 16
    public static let maxPixels = 1_048_576
    public static let speedRange = 4...60
    public static let defaultSpeed = 16
    /// The black gap between two passes of a scrolling list.
    public static let loopGap = 48

    /// Whether a stored asset can be a board's sheet.
    public static func isValidSheet(width: Int, height: Int, frames: Int) -> Bool {
        (1...maxFrames).contains(frames) && (1...ClipCanvas.width).contains(width) && (minHeight...ClipCanvas.height).contains(height)
            && frames * width * height <= maxPixels
    }

    /// Why the clip would refuse this item given its sheet's frame count (nil: fine). §5g validation.
    public static func problem(_ item: PlaylistItem, sheetFrames n: Int) -> String? {
        guard let rows = item.rows, (1...maxRows).contains(rows.count) else { return "rows is 1–47 entries" }
        if rows.contains(where: { !(0..<n).contains($0.frame) }) { return "a row's frame is out of range" }
        if let h = item.header, !(0..<n).contains(h) { return "header is out of range" }
        if let e = item.empty, !(0..<n).contains(e) { return "empty is out of range" }
        if let s = item.scrollPxS, !speedRange.contains(s) { return "scroll_px_s is 4–60" }
        return nil
    }

    /// The rows still to show at `now` (all of them while the clock isn't synced).
    public static func visibleRows(_ rows: [BoardRow], now: Date, clockSynced: Bool = true) -> [BoardRow] {
        guard clockSynced else { return rows }
        let t = Int(now.timeIntervalSince1970)
        return rows.filter { ($0.until ?? .max) > t }
    }

    /// The panel at `tMs` into the item: the header fixed at the top, the rows stacked under it (centred), scrolling
    /// up at `speed` px/s with a 48 px gap when taller than the space left; the empty frame when no row remains.
    public static func frame(sheet: [RGB565Frame], header: Int?, empty: Int?, rows: [BoardRow], speed: Int, tMs: Int,
                             width: Int = ClipCanvas.width, height: Int = ClipCanvas.height) -> RGB565Frame {
        var out = RGB565Frame(width: width, height: height)
        func paste(_ f: RGB565Frame, y: Int, clipTop: Int) {
            let x = (width - f.width) / 2
            for row in 0..<f.height {
                let dy = y + row
                guard dy >= clipTop, dy < height else { continue }
                for col in 0..<f.width where x + col >= 0 && x + col < width {
                    out.pixels[dy * width + x + col] = f.pixels[row * f.width + col]
                }
            }
        }
        var top = 0
        if let h = header, sheet.indices.contains(h) {
            paste(sheet[h], y: 0, clipTop: 0)
            top = sheet[h].height
        }
        let frames = rows.compactMap { sheet.indices.contains($0.frame) ? sheet[$0.frame] : nil }
        if frames.isEmpty {
            if let e = empty, sheet.indices.contains(e) { paste(sheet[e], y: top, clipTop: top) }
            return out
        }
        let stack = frames.reduce(0) { $0 + $1.height }
        if stack <= height - top {
            var y = top
            for f in frames { paste(f, y: y, clipTop: top); y += f.height }
            return out
        }
        // Scrolling: one pass is the stack plus the gap; draw the passes that cross the space under the header.
        let period = stack + loopGap
        let offset = Int((Double(tMs) / 1000 * Double(speed)).rounded(.down)) % period
        var passStart = top - offset
        while passStart < height {
            var y = passStart
            for f in frames { paste(f, y: y, clipTop: top); y += f.height }
            passStart += period
        }
        return out
    }

    /// Is the list scrolling at all (the virtual clip redraws it then)?
    public static func scrolls(sheet: [RGB565Frame], header: Int?, rows: [BoardRow], height: Int = ClipCanvas.height) -> Bool {
        let top = header.flatMap { sheet.indices.contains($0) ? sheet[$0].height : nil } ?? 0
        let stack = rows.compactMap { sheet.indices.contains($0.frame) ? sheet[$0.frame].height : nil }.reduce(0, +)
        return stack > height - top
    }
}
