import Foundation

/// The live scenes' palettes as the firmware defines them (`core/src/scene.c`: `k_pal`, the per-scene
/// `palette` enums and defaults), for the app's pickers and its illustrative previews.
public enum SceneLook {
    public struct Stop: Sendable, Hashable { public let pos: Int, r: Int, g: Int, b: Int }

    private static func ramp(_ s: [(Int, Int, Int, Int)]) -> [Stop] { s.map { Stop(pos: $0.0, r: $0.1, g: $0.2, b: $0.3) } }

    /// Gradient ramps from black (0) to the brightest tone (255).
    public static let ramps: [String: [Stop]] = [
        "amber": ramp([(0, 0, 0, 0), (50, 0x2A, 0x10, 0x00), (115, 0x8A, 0x45, 0x00), (180, 0xE0, 0x96, 0x00), (220, 0xFF, 0xBE, 0x00), (255, 0xFF, 0xEC, 0xA8)]),
        "ocean": ramp([(0, 0, 0, 0), (50, 0x00, 0x12, 0x33), (115, 0x00, 0x42, 0x8C), (180, 0x08, 0x86, 0xD8), (220, 0x30, 0xC8, 0xF0), (255, 0xD0, 0xF8, 0xFF)]),
        "forest": ramp([(0, 0, 0, 0), (50, 0x08, 0x1C, 0x08), (115, 0x1A, 0x5C, 0x18), (180, 0x48, 0xA0, 0x2C), (220, 0x8C, 0xD2, 0x46), (255, 0xE8, 0xF8, 0xB0)]),
        "candy": ramp([(0, 0, 0, 0), (45, 0x34, 0x08, 0x3C), (100, 0xC8, 0x2C, 0x80), (150, 0xFF, 0x6E, 0xB4), (190, 0x96, 0x6E, 0xFF), (225, 0x46, 0xE6, 0xC8), (255, 0xFF, 0xF2, 0xA0)]),
        "mono": ramp([(0, 0, 0, 0), (80, 0x26, 0x28, 0x2E), (170, 0x96, 0x9A, 0xA4), (255, 0xFF, 0xFF, 0xFF)]),
        "ember": ramp([(0, 0, 0, 0), (55, 0x30, 0x02, 0x00), (120, 0x9C, 0x12, 0x00), (180, 0xF0, 0x50, 0x00), (225, 0xFF, 0x9A, 0x1E), (255, 0xFF, 0xE0, 0x8C)]),
        "classic": ramp([(0, 0, 0, 0), (35, 0x2F, 0x0F, 0x07), (75, 0x8F, 0x27, 0x07), (115, 0xC7, 0x47, 0x07), (155, 0xDF, 0x6F, 0x07), (195, 0xD7, 0x9F, 0x1F), (230, 0xE7, 0xD7, 0x7F), (255, 0xFF, 0xFF, 0xF0)]),
        "blue": ramp([(0, 0, 0, 0), (40, 0x04, 0x04, 0x2A), (90, 0x0A, 0x1A, 0x8C), (140, 0x1E, 0x50, 0xFF), (190, 0x40, 0xA8, 0xFF), (230, 0xA8, 0xE8, 0xFF), (255, 0xFF, 0xFF, 0xFF)]),
        "emerald": ramp([(0, 0, 0, 0), (40, 0x02, 0x18, 0x0A), (90, 0x04, 0x4C, 0x26), (140, 0x08, 0x9C, 0x4C), (190, 0x34, 0xE0, 0x84), (230, 0xB0, 0xFF, 0xD0), (255, 0xFF, 0xFF, 0xFF)]),
    ]

    /// The palettes a scene accepts (fire has its own flame ramps).
    public static func palettes(for scene: String) -> [String] {
        scene == "fire" ? ["classic", "blue", "emerald"] : ["amber", "ocean", "forest", "candy", "mono", "ember"]
    }

    /// The firmware's default palette for a scene.
    public static func defaultPalette(for scene: String) -> String {
        switch scene {
        case "water": "ocean"
        case "snow": "mono"
        case "fire": "classic"
        case "balls": "candy"
        case "lava": "ember"
        default: "amber"
        }
    }

    /// `palette` if the scene accepts it, else its default (an old "amber" fire becomes "classic").
    public static func palette(_ palette: String?, for scene: String) -> String {
        if let palette, palettes(for: scene).contains(palette) { return palette }
        return defaultPalette(for: scene)
    }

    /// The scene item's parameters for a palette.
    public static func params(scene: String, palette: String?) -> [String: SceneParam] {
        ["palette": .string(self.palette(palette, for: scene))]
    }

    /// Colour at `t` (0 = black … 1 = brightest) of a palette, as 0…1 RGB.
    public static func color(_ palette: String, at t: Double) -> (r: Double, g: Double, b: Double) {
        let stops = ramps[palette] ?? ramps["amber"]!
        let p = min(max(t, 0), 1) * 255
        for i in 1..<stops.count where Double(stops[i].pos) >= p {
            let a = stops[i - 1], b = stops[i]
            let f = (p - Double(a.pos)) / Double(max(1, b.pos - a.pos))
            func mix(_ x: Int, _ y: Int) -> Double { (Double(x) + (Double(y) - Double(x)) * f) / 255 }
            return (mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b))
        }
        let l = stops[stops.count - 1]
        return (Double(l.r) / 255, Double(l.g) / 255, Double(l.b) / 255)
    }
}
