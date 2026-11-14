import CoreText
import XCTest
@testable import PixelClipKit
#if canImport(UIKit)
import UIKit
#endif

/// The OFL fonts in ios/Sources/Resources/Fonts: manifest ⇄ generated Swift ⇄ Info.plist agree, the
/// files are real fonts with their OFL, and every PostScript name resolves once the files are
/// registered (UIFont on the simulator, CoreText on macOS), so the catalogue offers them.
final class BundledFontsTests: XCTestCase {
    static let fontsDir = Paths.iosDir.appendingPathComponent("Sources/Resources/Fonts")

    struct Manifest: Decodable {
        struct Family: Decodable {
            struct File: Decodable { let file: String; let bytes: Int; let variable: Bool }
            struct Face: Decodable { let postScriptName: String; let style: String; let ctWeight: Double; let italic: Bool; let file: String }
            let family: String, folder: String, mood: String, license: String, licenseFile: String, copyright: String
            let files: [File]
            let faces: [Face]
        }
        let totalBytes: Int
        let families: [Family]
    }

    static func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fontsDir.appendingPathComponent("FONTS.json")))
    }

    /// Registers every bundled font file for this process, the way UIAppFonts does for the app.
    static let registered: Bool = {
        for fam in BundledFonts.families {
            for file in fam.files {
                var error: Unmanaged<CFError>?
                let url = fontsDir.appendingPathComponent(file) as CFURL
                if !CTFontManagerRegisterFontsForURL(url, .process, &error),
                   let e = error?.takeRetainedValue(), CFErrorGetCode(e) != CTFontManagerError.alreadyRegistered.rawValue {
                    return false
                }
            }
        }
        return true
    }()

    func testGeneratedSwiftMatchesManifest() throws {
        let m = try Self.manifest()
        XCTAssertEqual(m.families.map(\.family), BundledFonts.families.map(\.family))
        XCTAssertEqual(m.totalBytes, BundledFonts.totalBytes)
        for (j, s) in zip(m.families, BundledFonts.families) {
            XCTAssertEqual(j.folder, s.folder)
            XCTAssertEqual(j.mood, "\(s.mood)")
            XCTAssertEqual(j.copyright, s.copyright)
            XCTAssertEqual(j.files.map(\.file), s.files)
            XCTAssertEqual(j.licenseFile, "\(s.folder)/OFL.txt")
            XCTAssertEqual("Fonts/" + j.licenseFile, s.licensePath)
            XCTAssertEqual(j.faces.map(\.postScriptName), s.faces.map(\.postScriptName), j.family)
            XCTAssertEqual(j.faces.map(\.ctWeight), s.faces.map(\.weight), j.family)
            XCTAssertEqual(j.faces.map(\.italic), s.faces.map(\.italic), j.family)
            XCTAssertEqual(j.faces.map(\.style), s.faces.map(\.styleName), j.family)
        }
    }

    func testFilesAreFontsWithTheirOFL() throws {
        let m = try Self.manifest()
        XCTAssertGreaterThanOrEqual(m.families.count, 20)
        var total = 0
        for fam in m.families {
            XCTAssertEqual(fam.license, "SIL Open Font License 1.1")
            let ofl = try String(contentsOf: Self.fontsDir.appendingPathComponent(fam.licenseFile), encoding: .utf8)
            total += ofl.utf8.count
            XCTAssertTrue(ofl.uppercased().contains("SIL OPEN FONT LICENSE"), fam.family)
            XCTAssertTrue(ofl.contains("Version 1.1"), fam.family)
            XCTAssertFalse(fam.copyright.isEmpty, fam.family)
            for f in fam.files {
                let data = try Data(contentsOf: Self.fontsDir.appendingPathComponent(f.file))
                XCTAssertEqual(data.count, f.bytes, f.file)
                total += data.count
                let magic = [UInt8](data.prefix(4))
                XCTAssertTrue(magic == [0, 1, 0, 0] || magic == Array("OTTO".utf8) || magic == Array("true".utf8), f.file)
            }
            for face in fam.faces { XCTAssertTrue(fam.files.map(\.file).contains(face.file), face.postScriptName) }
        }
        XCTAssertEqual(total, m.totalBytes)
        XCTAssertLessThan(total, 6 * 1024 * 1024, "keep the font bundle under ~6 MB")
    }

    func testInfoPlistRegistersEveryFontFile() throws {
        let data = try Data(contentsOf: Paths.iosDir.appendingPathComponent("Sources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let appFonts = try XCTUnwrap(plist["UIAppFonts"] as? [String])
        XCTAssertEqual(appFonts, BundledFonts.families.flatMap { $0.files.map { "Fonts/" + $0 } })
    }

    func testEveryPostScriptNameResolves() throws {
        XCTAssertTrue(Self.registered)
        for fam in BundledFonts.families {
            for face in fam.faces {
                #if canImport(UIKit)
                let font = try XCTUnwrap(UIFont(name: face.postScriptName, size: 40), "UIFont(name: \(face.postScriptName))")
                XCTAssertEqual(font.fontName, face.postScriptName)
                XCTAssertEqual(font.familyName, fam.family)
                #else
                let font = CTFontCreateWithName(face.postScriptName as CFString, 40, nil)
                XCTAssertEqual(CTFontCopyPostScriptName(font) as String, face.postScriptName)
                XCTAssertEqual(CTFontCopyFamilyName(font) as String, fam.family)
                #endif
            }
        }
    }

    func testCatalogueOffersBundledFamilies() throws {
        XCTAssertTrue(Self.registered)
        XCTAssertEqual(FontCatalog.registeredBundledFamilies(), Set(BundledFonts.families.map(\.family)))
        #if canImport(UIKit)
        // What the app does (CreateFonts.installed).
        let installed = Set(UIFont.familyNames).union(FontCatalog.registeredBundledFamilies())
        #else
        let installed = FontCatalog.installedFamilies()
        #endif
        let available = FontCatalog.available(installed: installed)
        for fam in BundledFonts.families {
            let choice = try XCTUnwrap(available.first { $0.familyName == fam.family }, "\(fam.family) is available")
            XCTAssertEqual(choice.mood, fam.mood)
            XCTAssertEqual(FontCatalog.faces(ofFamily: fam.family), FontCatalog.sortFaces(fam.faces), "faces come from the manifest")
            // The resolved CTFont really is the bundled face.
            let sel = FontSelection(familyID: choice.id, weight: 0)
            XCTAssertEqual(CTFontCopyFamilyName(FontCatalog.ctFont(for: sel, size: 50)) as String, fam.family)
        }
        XCTAssertEqual(Set(FontCatalog.curated.map(\.id)).count, FontCatalog.curated.count, "ids stay unique")
        // Groups from the brief.
        let mood = { (name: String) in BundledFonts.family(named: name)?.mood }
        XCTAssertEqual(mood("Press Start 2P"), .pixel)
        XCTAssertEqual(mood("Monoton"), .display)
        XCTAssertEqual(mood("Pacifico"), .script)
        XCTAssertEqual(mood("Playfair Display"), .editorial)
        // Weight / italic availability is the manifest's.
        let playfair = try XCTUnwrap(FontCatalog.choice("playfair-display")?.familyName)
        XCTAssertTrue(FontCatalog.faces(ofFamily: playfair).contains { $0.italic })
        XCTAssertEqual(FontCatalog.weightSteps(FontCatalog.faces(ofFamily: "Silkscreen")).map(\.name), ["Regular", "Bold"])
    }

    func testLEDStyleDefaultsToAPixelFace() {
        let all = FontCatalog.curated
        let fromRounded = FontCatalog.ledDefaultFont(current: FontSelection(familyID: FontCatalog.sfRounded, weight: 0.4), available: all)
        XCTAssertEqual(fromRounded?.familyID, "press-start-2p")
        XCTAssertEqual(fromRounded?.weight, 0)
        XCTAssertNil(FontCatalog.ledDefaultFont(current: FontSelection(familyID: "vt323", weight: 0), available: all),
                     "already a pixel face: keep it")
        let noPressStart = all.filter { $0.id != "press-start-2p" }
        XCTAssertEqual(FontCatalog.ledDefaultFont(current: .systemBold, available: noPressStart)?.familyID, "silkscreen")
        XCTAssertNil(FontCatalog.ledDefaultFont(current: .systemBold, available: all.filter { $0.mood != .pixel }))
    }
}
