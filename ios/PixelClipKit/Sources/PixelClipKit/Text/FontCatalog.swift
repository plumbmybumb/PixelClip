import CoreGraphics
import CoreText
import Foundation

/// The curated marquee fonts, grouped by mood: faces that ship with iOS plus the open-licensed
/// families the app bundles (`BundledFonts`). Anything not actually installed on the device is
/// filtered out at runtime (`available(installed:)`). Declaration order is the picker's section order.
public enum FontMood: String, CaseIterable, Codable, Sendable, Identifiable {
    case system = "System", pixel = "Retro & Pixel", display = "Display", script = "Script"
    case elegant = "Elegant", editorial = "Editorial", playful = "Playful"
    public var id: String { rawValue }
}

public struct FontChoice: Identifiable, Hashable, Sendable {
    public enum SystemDesign: String, Hashable, Sendable { case standard, rounded, serif, monospaced }
    public enum Source: Hashable, Sendable {
        /// San Francisco / New York, resolved by the platform's system-font API.
        case system(SystemDesign)
        /// A font family by its `UIFont.familyNames` name.
        case family(String)
    }

    public let id: String
    public let name: String
    public let mood: FontMood
    public let source: Source

    public init(id: String, name: String, mood: FontMood, source: Source) {
        self.id = id; self.name = name; self.mood = mood; self.source = source
    }

    public var familyName: String? { if case .family(let f) = source { f } else { nil } }
    public var systemDesign: SystemDesign? { if case .system(let d) = source { d } else { nil } }
}

/// A font family bundled with the app (SIL OFL 1.1), as recorded in `Fonts/FONTS.json`.
public struct BundledFontFamily: Hashable, Sendable {
    /// CoreText / `UIFont.familyNames` name.
    public let family: String
    public let mood: FontMood
    /// Folder under `Fonts/` in the app bundle (holds the TTFs and the family's `OFL.txt`).
    public let folder: String
    /// The copyright line from the family's OFL.txt (shown in Credits & Licenses).
    public let copyright: String
    /// Font files, relative to `Fonts/` (the `UIAppFonts` entries without the `Fonts/` prefix).
    public let files: [String]
    /// Every face the files provide (static faces and variable named instances).
    public let faces: [FontFace]

    public init(family: String, mood: FontMood, folder: String, copyright: String, files: [String], faces: [FontFace]) {
        self.family = family; self.mood = mood; self.folder = folder; self.copyright = copyright; self.files = files; self.faces = faces
    }

    /// Path of the family's licence inside the app bundle.
    public var licensePath: String { "Fonts/\(folder)/OFL.txt" }
    public static let licenseName = "SIL Open Font License 1.1"
}

extension BundledFonts {
    public static func family(named name: String) -> BundledFontFamily? {
        families.first { $0.family.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// One face of a family (e.g. "Didot Bold Italic").
public struct FontFace: Hashable, Sendable {
    public let postScriptName: String
    public let styleName: String
    /// CoreText weight trait, -1…1.
    public let weight: Double
    public let italic: Bool

    public init(postScriptName: String, styleName: String, weight: Double, italic: Bool) {
        self.postScriptName = postScriptName; self.styleName = styleName; self.weight = weight; self.italic = italic
    }
}

public enum FontCatalog {
    public static let sfPro = "sf-pro"
    public static let sfRounded = "sf-rounded"
    public static let sfMono = "sf-mono"
    public static let newYork = "new-york"

    private static func fam(_ name: String, _ mood: FontMood, id: String? = nil, label: String? = nil) -> FontChoice {
        FontChoice(id: id ?? name.lowercased().replacingOccurrences(of: " ", with: "-"), name: label ?? name, mood: mood, source: .family(name))
    }

    /// Everything we'd like to offer, in display order: the iOS families below, then the families the
    /// app bundles (`BundledFonts`, each in its mood). Nothing is downloaded at runtime.
    public static let curated: [FontChoice] = system + BundledFonts.families.map { fam($0.family, $0.mood) }

    private static let system: [FontChoice] = [
        FontChoice(id: sfPro, name: "SF Pro", mood: .system, source: .system(.standard)),
        FontChoice(id: sfRounded, name: "SF Pro Rounded", mood: .system, source: .system(.rounded)),
        FontChoice(id: sfMono, name: "SF Mono", mood: .system, source: .system(.monospaced)),
        FontChoice(id: newYork, name: "New York", mood: .system, source: .system(.serif)),

        fam("Didot", .elegant),
        fam("Bodoni 72", .elegant),
        fam("Bodoni 72 Smallcaps", .elegant, label: "Bodoni 72 Small Caps"),
        fam("Baskerville", .elegant),
        fam("Cochin", .elegant),
        fam("Hoefler Text", .elegant),
        fam("Palatino", .elegant),
        fam("Athelas", .elegant),
        fam("Iowan Old Style", .elegant),
        fam("Charter", .elegant),
        fam("Snell Roundhand", .elegant),
        fam("Savoye LET", .elegant, label: "Savoye"),
        fam("Zapfino", .elegant),

        fam("Futura", .display),
        fam("Avenir Next Condensed", .display),
        fam("Avenir Next", .display),
        fam("Impact", .display),
        fam("DIN Condensed", .display),
        fam("DIN Alternate", .display),
        fam("Copperplate", .display),
        fam("Optima", .display),
        fam("Gill Sans", .display),
        fam("Rockwell", .display),
        fam("Superclarendon", .display),
        fam("Academy Engraved LET", .display, label: "Academy Engraved"),
        fam("Arial Rounded MT Bold", .display, label: "Arial Rounded"),
        fam("Trebuchet MS", .display, label: "Trebuchet"),
        fam("DB LCD Temp", .display, label: "LCD"),

        fam("Marker Felt", .playful),
        fam("Chalkboard SE", .playful),
        fam("Noteworthy", .playful),
        fam("Bradley Hand", .playful),
        fam("Party LET", .playful, label: "Party"),
        fam("Chalkduster", .playful),
        fam("American Typewriter", .playful),
        fam("SignPainter", .playful),
        fam("Papyrus", .playful),
        fam("Courier New", .playful),
    ]

    public static func choice(_ id: String) -> FontChoice? { curated.first { $0.id == id } }

    /// Pixel faces the LED dot-matrix style switches to when it is first chosen, in preference order.
    public static let ledDefaultIDs = ["press-start-2p", "silkscreen"]

    /// The font the LED dot-matrix style should start with: the first available pixel default, or nil
    /// when the current font is already a Retro & Pixel face (or none of the defaults is installed).
    public static func ledDefaultFont(current: FontSelection, available: [FontChoice]) -> FontSelection? {
        if available.first(where: { $0.id == current.familyID })?.mood == .pixel { return nil }
        guard let pick = ledDefaultIDs.lazy.compactMap({ id in available.first { $0.id == id } }).first else { return nil }
        let regular = pick.familyName.flatMap(BundledFonts.family(named:))?.faces.first { !$0.italic }?.weight ?? 0
        return FontSelection(familyID: pick.id, weight: regular)
    }

    /// The curated list minus families that aren't installed. System designs are always present.
    /// Matching is case-insensitive on the family name.
    public static func available(installed: Set<String>, from list: [FontChoice] = curated) -> [FontChoice] {
        let lower = Set(installed.map { $0.lowercased() })
        return list.filter { c in
            guard let f = c.familyName else { return true }
            return lower.contains(f.lowercased())
        }
    }

    /// Families CoreText can see on this device, plus the bundled families that are registered.
    public static func installedFamilies() -> Set<String> {
        Set((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []).union(registeredBundledFamilies())
    }

    /// Bundled families whose every face resolves by PostScript name (i.e. `UIAppFonts` registered them).
    /// Checked by name rather than in the family lists: iOS keeps a private "Bebas Neue" (CoreUI, PS name
    /// "BebasNeue"), which hides our registered family of the same name from `UIFont.familyNames` even
    /// though "BebasNeue-Regular" resolves to our file.
    public static func registeredBundledFamilies() -> Set<String> {
        Set(BundledFonts.families.filter { fam in
            fam.faces.allSatisfy { face in
                CTFontCopyPostScriptName(CTFontCreateWithName(face.postScriptName as CFString, 12, nil)) as String == face.postScriptName
            }
        }.map(\.family))
    }

    // MARK: Faces

    /// Every face of a family, sorted by weight then upright first. Bundled families answer from their
    /// manifest (so weights and italics don't depend on registration); others ask CoreText.
    public static func faces(ofFamily family: String) -> [FontFace] {
        if let bundled = BundledFonts.family(named: family) { return sortFaces(bundled.faces) }
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        guard let matches = CTFontDescriptorCreateMatchingFontDescriptors(desc, nil) as? [CTFontDescriptor] else { return [] }
        var out: [FontFace] = []
        for d in matches {
            guard let fam = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String,
                  fam.caseInsensitiveCompare(family) == .orderedSame,
                  let ps = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String else { continue }
            let style = (CTFontDescriptorCopyAttribute(d, kCTFontStyleNameAttribute) as? String) ?? "Regular"
            let traits = (CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any]) ?? [:]
            let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            let sym = (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            let italic = sym & CTFontSymbolicTraits.traitItalic.rawValue != 0
            out.append(FontFace(postScriptName: ps, styleName: style, weight: weight, italic: italic))
        }
        return sortFaces(Array(Set(out)))
    }

    static func sortFaces(_ faces: [FontFace]) -> [FontFace] {
        faces.sorted { a, b in
            if a.weight != b.weight { return a.weight < b.weight }
            if a.italic != b.italic { return !a.italic }
            return a.postScriptName < b.postScriptName
        }
    }

    /// The face closest to the request: italic match first (when the family has one), then weight.
    public static func nearestFace(_ faces: [FontFace], weight: Double, italic: Bool) -> FontFace? {
        guard !faces.isEmpty else { return nil }
        let wantItalic = italic && faces.contains { $0.italic }
        let pool = faces.filter { $0.italic == wantItalic }
        return (pool.isEmpty ? faces : pool).min { a, b in
            let da = abs(a.weight - weight), db = abs(b.weight - weight)
            if da != db { return da < db }
            return a.postScriptName < b.postScriptName
        }
    }

    /// Distinct upright weights offered by a family, each with a representative style name.
    public static func weightSteps(_ faces: [FontFace]) -> [(weight: Double, name: String)] {
        var seen: [Double: String] = [:]
        for f in faces where !f.italic || !faces.contains(where: { !$0.italic }) {
            let w = (f.weight * 100).rounded() / 100
            if seen[w] == nil { seen[w] = f.styleName.replacingOccurrences(of: " Italic", with: "") }
        }
        return seen.keys.sorted().map { ($0, seen[$0]!) }
    }

    /// System weights (UIFont.Weight raw values) used by SF Pro / Rounded / Mono / New York.
    public static let systemWeights: [(weight: Double, name: String)] = [
        (-0.8, "Ultralight"), (-0.6, "Thin"), (-0.4, "Light"), (0, "Regular"), (0.23, "Medium"),
        (0.3, "Semibold"), (0.4, "Bold"), (0.56, "Heavy"), (0.62, "Black"),
    ]

    /// Platform-neutral resolution for named families (the app resolves system designs itself with
    /// UIFont; this falls back to the CoreText UI font for them, which is what tests use).
    public static func ctFont(for selection: FontSelection, size: CGFloat) -> CTFont {
        if let c = choice(selection.familyID), let family = c.familyName,
           let face = nearestFace(faces(ofFamily: family), weight: selection.weight, italic: selection.italic) {
            return CTFontCreateWithName(face.postScriptName as CFString, size, nil)
        }
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var traits: [CFString: Any] = [kCTFontWeightTrait: selection.weight]
        if selection.italic { traits[kCTFontSymbolicTrait] = CTFontSymbolicTraits.traitItalic.rawValue }
        let desc = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base),
                                                            [kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateWithFontDescriptor(desc, size, nil)
    }
}
