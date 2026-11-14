// Renders the app icon set: a dot-matrix sparkle on the clip's black AMOLED, in the app's accent violet.
//   swift scripts/make_icon.swift Sources/Assets.xcassets/AppIcon.appiconset
// Writes icon.png (light), icon-dark.png (dark) and icon-tinted.png (white on transparent, for iOS tinting).
import AppKit

let size = 1024
let dir = CommandLine.arguments.dropFirst().first ?? "."
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// 14 × 14 dots. '#' lit, '+' lit dim, '.' off.
let rows = [
    "..............",
    "......#.......",
    "......#.......",
    "......#.......",
    ".....###......",
    "....#####.....",
    ".###########..",
    "....#####.....",
    ".....###......",
    "......#.......",
    "......#...+...",
    "......#..+++..",
    "..........+...",
    "..............",
]
let n = rows.count
let pitch = Double(size) / Double(n)
let radius = pitch * 0.42

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

enum Variant { case light, dark, tinted }

func render(_ variant: Variant, to name: String) {
    let alpha: CGImageAlphaInfo = variant == .tinted ? .premultipliedLast : .noneSkipLast
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: alpha.rawValue)!
    if variant != .tinted {   // opaque black (App Store icons must not have alpha)
        ctx.setFillColor(rgb(0, 0, 0))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }
    let lit = variant == .tinted ? rgb(1, 1, 1) : rgb(0.77, 0.63, 1.0)
    let dim = variant == .tinted ? rgb(1, 1, 1, 0.45) : rgb(0.35, 0.28, 0.47)
    let off = variant == .tinted ? rgb(1, 1, 1, 0.07) : (variant == .dark ? rgb(0.06, 0.05, 0.08) : rgb(0.09, 0.075, 0.12))
    for (r, row) in rows.enumerated() {
        for (c, ch) in row.enumerated() {
            let x = (Double(c) + 0.5) * pitch
            let y = Double(size) - (Double(r) + 0.5) * pitch   // CoreGraphics origin is bottom-left
            let dot = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            if ch == "#" && variant != .tinted {   // the glow of a lit pixel
                let glow = CGGradient(colorsSpace: space,
                                      colors: [rgb(0.77, 0.63, 1.0, 0.55), rgb(0.77, 0.63, 1.0, 0)] as CFArray,
                                      locations: [0.55, 1])!
                ctx.drawRadialGradient(glow, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                       endCenter: CGPoint(x: x, y: y), endRadius: radius * 1.45, options: [])
            }
            ctx.setFillColor(ch == "#" ? lit : ch == "+" ? dim : off)
            ctx.fillEllipse(in: dot)
        }
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}

render(.light, to: "icon.png")
render(.dark, to: "icon-dark.png")
render(.tinted, to: "icon-tinted.png")
