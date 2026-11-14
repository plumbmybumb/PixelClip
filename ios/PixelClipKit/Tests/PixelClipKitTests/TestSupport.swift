import Foundation
@testable import PixelClipKit

/// Deterministic PRNG (SplitMix64) so "random" tests are reproducible.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Paths {
    /// …/ios/PixelClipKit/Tests/PixelClipKitTests/TestSupport.swift → repo root.
    static let thisFile = URL(fileURLWithPath: #filePath)
    static let testsDir = thisFile.deletingLastPathComponent().deletingLastPathComponent()
    static let fixturesDir = testsDir.appendingPathComponent("Fixtures")
    static let iosDir = testsDir.deletingLastPathComponent().deletingLastPathComponent()
    static let repoRoot = iosDir.deletingLastPathComponent()
    static let referenceFixtures = repoRoot.appendingPathComponent("tools/fixtures")
    static let fixturesOut = iosDir.appendingPathComponent("fixtures-out")

    /// The C tools from `cmake -S core -B build/core && cmake --build build/core`.
    static func cTool(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let dir = ProcessInfo.processInfo.environment["HCA_TOOLS_DIR"] {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        candidates.append(repoRoot.appendingPathComponent("build/core/tools/\(name)"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

func frame(_ w: Int, _ h: Int, _ f: (Int, Int) -> UInt16) -> RGB565Frame {
    var px = [UInt16](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w { px[y * w + x] = f(x, y) } }
    return RGB565Frame(width: w, height: h, pixels: px)
}

func jsonObject(_ data: Data) throws -> NSObject {
    try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as! NSObject
}

func jsonObject(_ string: String) throws -> NSObject { try jsonObject(Data(string.utf8)) }

#if os(macOS)
@discardableResult
func runTool(_ tool: URL, _ args: [String]) throws -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = tool
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
#endif
