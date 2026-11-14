import CoreGraphics
import Foundation

/// A raster paint layer under the PencilKit ink: fill-bucket results, pixel-pen cells and filled
/// shapes. Premultiplied RGBA8, row 0 at the top, canvas-sized. Stored compressed in drafts.
public struct PixelLayer: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var bytes: [UInt8]

    public init(width: Int = ClipCanvas.width, height: Int = ClipCanvas.height) {
        self.width = width; self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
    }

    public init(image: RGBA8Image) {
        width = image.width; height = image.height; bytes = image.bytes
    }

    public var image: RGBA8Image { RGBA8Image(width: width, height: height, bytes: bytes) }

    public var isEmpty: Bool {
        // memcmp against zeros: fast even in unoptimised builds (this runs on every pixel-pen move).
        let zeros = [UInt8](repeating: 0, count: bytes.count)
        return bytes.withUnsafeBytes { a in zeros.withUnsafeBytes { z in memcmp(a.baseAddress!, z.baseAddress!, a.count) == 0 } }
    }

    @inline(__always) private mutating func put(_ i: Int, _ c: (UInt8, UInt8, UInt8, UInt8)) {
        bytes[i * 4] = c.0; bytes[i * 4 + 1] = c.1; bytes[i * 4 + 2] = c.2; bytes[i * 4 + 3] = c.3
    }

    // MARK: Pixel pen

    /// Paint (or erase, when `color` is nil) the grid cell containing pixel (x, y).
    public mutating func setCell(x: Int, y: Int, cell: Int, color: RGBAColor?) {
        let c = max(1, cell)
        let cx = (x / c) * c, cy = (y / c) * c
        guard x >= 0, y >= 0, cx < width, cy < height else { return }
        let px = color.map { $0.withAlpha(1).premultipliedBytes } ?? (0, 0, 0, 0)
        for yy in cy..<min(height, cy + c) {
            for xx in cx..<min(width, cx + c) { put(yy * width + xx, px) }
        }
    }

    /// Paint every cell on the grid line between two pixels (Bresenham in cell space), so fast
    /// strokes leave no gaps.
    public mutating func strokeCells(from a: (x: Int, y: Int), to b: (x: Int, y: Int), cell: Int, color: RGBAColor?) {
        for p in Self.cellLine(from: a, to: b, cell: cell) { setCell(x: p.x * cell, y: p.y * cell, cell: cell, color: color) }
    }

    /// Cell coordinates visited by a line between two pixel positions.
    public static func cellLine(from a: (x: Int, y: Int), to b: (x: Int, y: Int), cell: Int) -> [(x: Int, y: Int)] {
        let c = max(1, cell)
        func floorDiv(_ v: Int) -> Int { v >= 0 ? v / c : -((-v + c - 1) / c) }
        var x0 = floorDiv(a.x), y0 = floorDiv(a.y)
        let x1 = floorDiv(b.x), y1 = floorDiv(b.y)
        let dx = abs(x1 - x0), dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        var out: [(x: Int, y: Int)] = []
        while true {
            out.append((x0, y0))
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x0 += sx }
            if e2 <= dx { err += dx; y0 += sy }
        }
        return out
    }

    // MARK: Fill bucket

    /// Flood-fill the region of `reference` (what you see: background + paint + ink + overlays)
    /// that is 4-connected to (x, y) and within `tolerance` of its colour (max channel difference).
    /// The region is grown by `dilate` px so it tucks under anti-aliased line edges, then painted
    /// into this layer (or cleared, when `color` is nil). Returns the number of pixels painted.
    @discardableResult
    public mutating func floodFill(x: Int, y: Int, reference: RGBA8Image, tolerance: Int = 40,
                                   color: RGBAColor?, dilate: Int = 1) -> Int {
        guard reference.width == width, reference.height == height,
              x >= 0, y >= 0, x < width, y < height else { return 0 }
        let mask = Self.regionMask(x: x, y: y, reference: reference, tolerance: tolerance, dilate: dilate)
        let px = color.map { $0.withAlpha(1).premultipliedBytes } ?? (0, 0, 0, 0)
        var n = 0
        for i in 0..<(width * height) where mask[i] { put(i, px); n += 1 }
        return n
    }

    /// The flood region as a mask (exposed for tests).
    public static func regionMask(x: Int, y: Int, reference: RGBA8Image, tolerance: Int, dilate: Int) -> [Bool] {
        let w = reference.width, h = reference.height
        var mask = [Bool](repeating: false, count: w * h)
        reference.bytes.withUnsafeBufferPointer { px in
            let s = (y * w + x) * 4
            let sr = Int(px[s]), sg = Int(px[s + 1]), sb = Int(px[s + 2])
            @inline(__always) func near(_ i: Int) -> Bool {
                let o = i * 4
                return max(abs(Int(px[o]) - sr), abs(Int(px[o + 1]) - sg), abs(Int(px[o + 2]) - sb)) <= tolerance
            }
            var stack = [y * w + x]
            mask[y * w + x] = true
            while let i = stack.popLast() {
                let cx = i % w, cy = i / w
                if cx > 0, !mask[i - 1], near(i - 1) { mask[i - 1] = true; stack.append(i - 1) }
                if cx + 1 < w, !mask[i + 1], near(i + 1) { mask[i + 1] = true; stack.append(i + 1) }
                if cy > 0, !mask[i - w], near(i - w) { mask[i - w] = true; stack.append(i - w) }
                if cy + 1 < h, !mask[i + w], near(i + w) { mask[i + w] = true; stack.append(i + w) }
            }
        }
        for _ in 0..<max(0, dilate) {
            var grown = mask
            for i in 0..<(w * h) where !mask[i] {
                let cx = i % w, cy = i / w
                if (cx > 0 && mask[i - 1]) || (cx + 1 < w && mask[i + 1]) || (cy > 0 && mask[i - w]) || (cy + 1 < h && mask[i + w]) {
                    grown[i] = true
                }
            }
            mask = grown
        }
        return mask
    }

    // MARK: Vector paint

    /// Draw into the layer with CoreGraphics in canvas coordinates (y-down, origin top-left).
    public mutating func draw(_ body: (CGContext) -> Void) {
        let w = width, h = height
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: Raster.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            body(ctx)
        }
    }
}

extension PixelLayer: Codable {
    private enum CodingKeys: String, CodingKey { case width, height, lzfse }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        let packed = try c.decode(Data.self, forKey: .lzfse)
        let raw = try (packed as NSData).decompressed(using: .lzfse) as Data
        guard raw.count == width * height * 4 else {
            throw DecodingError.dataCorruptedError(forKey: .lzfse, in: c, debugDescription: "pixel layer size mismatch")
        }
        bytes = [UInt8](raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(try (Data(bytes) as NSData).compressed(using: .lzfse) as Data, forKey: .lzfse)
    }
}
