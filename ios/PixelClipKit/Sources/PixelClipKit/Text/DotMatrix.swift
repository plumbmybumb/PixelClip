import Foundation

/// The classic LED sign: an image sampled onto a grid of round dots. Integer maths after the
/// (cached) dot mask, so the same input always gives the same bytes.
public enum DotMatrix {
    public struct Grid: Equatable, Sendable {
        public let pitch: Int
        public let cols: Int
        public let rows: Int
        /// Top-left of the first cell (the grid is centred; leftover pixels become margins).
        public let originX: Int
        public let originY: Int
    }

    public static func grid(width: Int, height: Int, pitch: Int) -> Grid {
        let p = max(2, pitch)
        let cols = width / p, rows = height / p
        return Grid(pitch: p, cols: cols, rows: rows, originX: (width - cols * p) / 2, originY: (height - rows * p) / 2)
    }

    /// pitch×pitch coverage (0…255) of a centred disc of diameter `pitch * ratio`, 4×4 supersampled.
    /// `soft: false` (the default) snaps coverage to 0/255: hard-edged dots keep each dot row a
    /// single colour, which RLE16 stores as one run (anti-aliased discs would be all literals).
    public static func dotMask(pitch: Int, ratio: Double = 0.8, soft: Bool = false) -> [UInt8] {
        let p = max(2, pitch)
        // Work in quarter-pixels with integers: radius² in (quarter px)².
        let r = Double(p) * ratio * 2           // radius in quarter pixels = (p*ratio/2)*4
        let r2 = Int((r * r).rounded())
        let c = p * 4                           // centre ×2 (we compare doubled coordinates)
        var mask = [UInt8](repeating: 0, count: p * p)
        for y in 0..<p {
            for x in 0..<p {
                var hits = 0
                for sy in 0..<4 {
                    for sx in 0..<4 {
                        // Sample centre in doubled quarter-pixel units: 2*(4x + sx) + 1.
                        let dx = 2 * (4 * x + sx) + 1 - c
                        let dy = 2 * (4 * y + sy) + 1 - c
                        if dx * dx + dy * dy <= 4 * r2 { hits += 1 }
                    }
                }
                mask[y * p + x] = soft ? UInt8((hits * 255 + 8) / 16) : (hits >= 8 ? 255 : 0)
            }
        }
        return mask
    }

    /// Sample `img` (opaque, composited on black) into dots. A cell lights when its average's
    /// brightest channel reaches `threshold`; lit dots show that average pushed to full brightness
    /// (LEDs are on or off), unlit dots show `off` (nil: unlit dots stay black, which is far smaller
    /// to store and saves battery). Between dots is true black.
    /// `originX`/`originY` override where the first cell starts (cells then run to the edge), so a
    /// long strip can be sampled once on the same grid as the canvas.
    public static func render(_ img: RGBA8Image, pitch: Int, threshold: Int = 72,
                              off: RGBAColor? = nil, dotRatio: Double = 0.8,
                              originX: Int? = nil, originY: Int? = nil) -> RGBA8Image {
        var g = grid(width: img.width, height: img.height, pitch: pitch)
        if originX != nil || originY != nil {
            let ox = originX ?? g.originX, oy = originY ?? g.originY
            g = Grid(pitch: g.pitch, cols: max(0, (img.width - ox) / g.pitch), rows: max(0, (img.height - oy) / g.pitch), originX: ox, originY: oy)
        }
        let p = g.pitch
        let mask = dotMask(pitch: p, ratio: dotRatio)
        var out = [UInt8](repeating: 0, count: img.width * img.height * 4)
        for i in stride(from: 3, to: out.count, by: 4) { out[i] = 255 }
        let (offR, offG, offB, _) = (off ?? .black).withAlpha(1).premultipliedBytes
        let w = img.width
        let n = p * p
        img.bytes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                mask.withUnsafeBufferPointer { m in
                    for row in 0..<g.rows {
                        let y0 = g.originY + row * p
                        for col in 0..<g.cols {
                            let x0 = g.originX + col * p
                            var sr = 0, sg = 0, sb = 0
                            for y in y0..<(y0 + p) {
                                var o = (y * w + x0) * 4
                                for _ in 0..<p {
                                    sr += Int(src[o]); sg += Int(src[o + 1]); sb += Int(src[o + 2])
                                    o += 4
                                }
                            }
                            let ar = sr / n, ag = sg / n, ab = sb / n
                            let peak = max(ar, ag, ab)
                            let cr: Int, cg: Int, cb: Int
                            if peak >= threshold {
                                cr = ar * 255 / peak; cg = ag * 255 / peak; cb = ab * 255 / peak
                            } else {
                                cr = Int(offR); cg = Int(offG); cb = Int(offB)
                            }
                            for y in 0..<p {
                                var o = ((y0 + y) * w + x0) * 4
                                let mrow = y * p
                                for x in 0..<p {
                                    let k = Int(m[mrow + x])
                                    if k != 0 {
                                        dst[o] = UInt8((cr * k + 127) / 255)
                                        dst[o + 1] = UInt8((cg * k + 127) / 255)
                                        dst[o + 2] = UInt8((cb * k + 127) / 255)
                                    }
                                    o += 4
                                }
                            }
                        }
                    }
                }
            }
        }
        return RGBA8Image(width: img.width, height: img.height, bytes: out)
    }
}

/// How a scrolling strip loops: it advances `step` px every `frameMs`, and after `frames` frames it
/// has moved exactly one `period`, so the last frame flows into the first.
public struct ScrollPlan: Equatable, Sendable {
    public let step: Int
    public let period: Int
    public let frames: Int
    public let frameMs: Int
    /// The frame cap forced a bigger step (and a lower frame rate to keep the speed).
    public let capped: Bool

    public var loopMs: Int { frames * frameMs }
    /// Actual speed in px/s.
    public var speed: Double { Double(step) * 1000 / Double(frameMs) }
}

public enum LoopMath {
    /// Plan a seamless scroll of content `contentWidth` px wide followed by `gap` px of space.
    /// - `speed`: px per second; `fps`: target frame rate; `pitch`: steps snap to this (LED cells).
    /// The period is `contentWidth + gap` rounded up to a whole number of steps.
    public static func scrollPlan(contentWidth: Int, gap: Int, speed: Double, fps: Double,
                                  pitch: Int = 1, maxFrames: Int = 400) -> ScrollPlan {
        let p = max(1, pitch)
        let base = max(1, contentWidth + max(0, gap))
        var frameMs = Int((1000 / max(1, fps)).rounded()).clampedTo(20, 200)
        func snap(_ s: Int) -> Int { max(p, ((s + p - 1) / p) * p) }
        var step = snap(max(1, Int((max(1, speed) * Double(frameMs) / 1000).rounded())))
        var frames = (base + step - 1) / step
        var capped = false
        if frames > maxFrames {
            capped = true
            step = snap((base + maxFrames - 1) / maxFrames)
            frames = (base + step - 1) / step
            // Keep the requested speed by holding each frame longer (down to 10 fps).
            frameMs = max(frameMs, Int((Double(step) * 1000 / max(1, speed)).rounded())).clampedTo(20, 100)
        }
        return ScrollPlan(step: step, period: frames * step, frames: frames, frameMs: frameMs, capped: capped)
    }

    /// x of copy 0 of the content at `frame`. Leftward content enters from the right edge;
    /// rightward from the left. Other copies sit at multiples of `plan.period`.
    public static func scrollX(frame: Int, plan: ScrollPlan, canvasWidth: Int, contentWidth: Int, leftward: Bool) -> Int {
        let o = (frame % max(1, plan.frames)) * plan.step
        return leftward ? canvasWidth - o : o - contentWidth
    }

    /// x positions of every copy of a `stripWidth`-wide strip (whose content starts `pad` px in)
    /// that touches the canvas at `frame`.
    public static func copies(frame: Int, plan: ScrollPlan, canvasWidth: Int, contentWidth: Int,
                              stripWidth: Int, pad: Int, leftward: Bool) -> [Int] {
        let x0 = scrollX(frame: frame, plan: plan, canvasWidth: canvasWidth, contentWidth: contentWidth, leftward: leftward) - pad
        let period = max(1, plan.period)
        // Smallest k with x0 + k*period + stripWidth > 0.
        var k = Int((Double(-stripWidth - x0) / Double(period)).rounded(.down))
        var xs: [Int] = []
        while x0 + k * period < canvasWidth {
            let x = x0 + k * period
            if x + stripWidth > 0 { xs.append(x) }
            k += 1
        }
        return xs
    }

    /// Per-character duration for a typewriter speed given in px/s (≈ 12 px per character).
    public static func typewriterCharMs(speed: Double) -> Int {
        Int((12_000 / max(1, speed)).rounded()).clampedTo(30, 400)
    }

    /// Bounce loop length in frames for `fps` (≈ 1.4 s, at least 8 frames).
    public static func bounceFrames(fps: Double) -> Int { max(8, Int((1.4 * fps).rounded())) }

    /// Vertical hop (0…1) of glyph `index` at `frame` of a `period`-frame bounce: each letter hops
    /// once per loop, the wave travelling left to right. Periodic in `frame` with `period`.
    public static func hop(frame: Int, period: Int, index: Int) -> Double {
        let t0 = Double(frame % max(1, period)) / Double(max(1, period)) - Double(index) * 0.07
        let t = t0 - t0.rounded(.down)
        return t < 0.45 ? sin(Double.pi * t / 0.45) : 0
    }
}

extension Int {
    func clampedTo(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}
