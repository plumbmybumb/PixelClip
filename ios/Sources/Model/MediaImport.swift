import AVFoundation
import CoreGraphics
import CoreTransferable
import Foundation
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import PixelClipKit

/// What the editor works from.
enum EditorSource: @unchecked Sendable {
    case still(CGImage)
    /// GIF / APNG / HEICS with their own frame delays.
    case frames(SourceFrames)
    /// A movie (video or the motion part of a Live Photo), sampled at the chosen fps.
    case video(URL, duration: Double)

    var isAnimated: Bool {
        switch self {
        case .still: false
        case .frames(let f): f.isAnimated
        case .video: true
        }
    }
}

struct ImportedMedia: @unchecked Sendable, Identifiable {
    let id = UUID()
    var source: EditorSource
    var original: Data
    var originalExtension: String
    var kind: LibraryItem.Source
    var suggestedName: String
    /// Set when re-editing an existing item.
    var replacing: LibraryItem?
}

enum ImportError: LocalizedError {
    case unsupported
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unsupported: "That file type isn’t supported. Try a photo, GIF or short video."
        case .unreadable: "Couldn’t read that item."
        }
    }
}

/// A movie handed over by PhotosPicker, copied somewhere we own.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = MediaImporter.tempURL(ext: received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

enum MediaImporter {
    static func tempURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).\(ext)")
    }

    // MARK: Photos

    static func load(_ item: PhotosPickerItem) async throws -> ImportedMedia {
        let types = item.supportedContentTypes
        if types.contains(where: { $0.conforms(to: .gif) }), let data = try await item.loadTransferable(type: Data.self) {
            return try fromImageData(data, ext: "gif", kind: .gif, name: "GIF")
        }
        if types.contains(where: { $0.conforms(to: .livePhoto) }) {
            if let live = try? await item.loadTransferable(type: PHLivePhoto.self), let movie = await pairedVideo(of: live) {
                return try await fromMovie(movie, kind: .livePhoto, name: "Live Photo")
            }
        }
        if types.contains(where: { $0.conforms(to: .movie) }) {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw ImportError.unreadable }
            return try await fromMovie(movie.url, kind: .video, name: "Video")
        }
        guard let data = try await item.loadTransferable(type: Data.self) else { throw ImportError.unreadable }
        let ext = types.first?.preferredFilenameExtension ?? "jpg"
        return try fromImageData(data, ext: ext, kind: .photo, name: "Photo")
    }

    /// Writes a Live Photo's motion to a temporary .mov.
    static func pairedVideo(of live: PHLivePhoto) async -> URL? {
        guard let res = PHAssetResource.assetResources(for: live).first(where: { $0.type == .pairedVideo }) else { return nil }
        let dest = tempURL(ext: "mov")
        do {
            try await PHAssetResourceManager.default().writeData(for: res, toFile: dest, options: nil)
            return dest
        } catch {
            return nil
        }
    }

    // MARK: Files

    static func load(fileURL url: URL) async throws -> ImportedMedia {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let name = url.deletingPathExtension().lastPathComponent
        if type.conforms(to: .movie) {
            let dest = tempURL(ext: url.pathExtension)
            try FileManager.default.copyItem(at: url, to: dest)
            return try await fromMovie(dest, kind: .file, name: name)
        }
        guard type.conforms(to: .image) else { throw ImportError.unsupported }
        let data = try Data(contentsOf: url)
        return try fromImageData(data, ext: url.pathExtension.lowercased(), kind: .file, name: name)
    }

    // MARK: Paste

    static func load(providers: [NSItemProvider]) async throws -> ImportedMedia {
        for p in providers {
            for (type, ext) in [(UTType.gif, "gif"), (.png, "png"), (.heic, "heic"), (.jpeg, "jpg"), (.image, "png")]
            where p.hasItemConformingToTypeIdentifier(type.identifier) {
                if let data = try? await p.loadData(type) {
                    return try fromImageData(data, ext: ext, kind: .pasted, name: "Pasted")
                }
            }
        }
        throw ImportError.unsupported
    }

    // MARK: Builders

    static func fromImageData(_ data: Data, ext: String, kind: LibraryItem.Source, name: String) throws -> ImportedMedia {
        let frames = try ImageLoader.load(data: data)
        let source: EditorSource = frames.isAnimated ? .frames(frames) : .still(frames.images[0])
        let k: LibraryItem.Source = frames.isAnimated && kind == .photo ? .gif : kind
        return ImportedMedia(source: source, original: data, originalExtension: ext, kind: k, suggestedName: name)
    }

    static func fromMovie(_ url: URL, kind: LibraryItem.Source, name: String) async throws -> ImportedMedia {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ImportError.unreadable }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return ImportedMedia(source: .video(url, duration: duration), original: data,
                             originalExtension: url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased(),
                             kind: kind, suggestedName: name)
    }

    /// Rebuild an editor source from a stored original.
    @MainActor static func reopen(_ item: LibraryItem, library: LibraryStore) async throws -> ImportedMedia {
        let url = library.originalURL(item)
        var media: ImportedMedia
        switch item.source {
        case .video, .livePhoto:
            let tmp = tempURL(ext: url.pathExtension)
            try FileManager.default.copyItem(at: url, to: tmp)
            media = try await fromMovie(tmp, kind: item.source, name: item.name)
        default:
            let type = UTType(filenameExtension: url.pathExtension) ?? .image
            if type.conforms(to: .movie) {
                let tmp = tempURL(ext: url.pathExtension)
                try FileManager.default.copyItem(at: url, to: tmp)
                media = try await fromMovie(tmp, kind: item.source, name: item.name)
            } else {
                media = try fromImageData(try Data(contentsOf: url), ext: url.pathExtension, kind: item.source, name: item.name)
            }
        }
        media.replacing = item
        return media
    }
}

/// NSItemProvider is thread-safe but not annotated Sendable.
struct ItemProviders: @unchecked Sendable {
    let providers: [NSItemProvider]
}

extension NSItemProvider {
    func loadData(_ type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            _ = loadDataRepresentation(for: type) { data, error in
                if let data { cont.resume(returning: data) } else { cont.resume(throwing: error ?? ImportError.unreadable) }
            }
        }
    }
}

/// Samples a movie into frames.
enum VideoSampler {
    static func frames(url: URL, start: Double, end: Double, fps: Double, maxFrames: Int,
                       maxPixel: Int = ImageLoader.animationMaxPixel) async throws -> SourceFrames {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let tol = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        let step = 1 / fps
        var times: [CMTime] = []
        var t = start
        while t < end - 0.0001 && times.count < maxFrames {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += step
        }
        if times.isEmpty { times = [CMTime(seconds: start, preferredTimescale: 600)] }
        var images: [CGImage] = []
        for await result in gen.images(for: times) {
            try Task.checkCancellation()
            if let img = try? result.image { images.append(img) }
        }
        guard !images.isEmpty else { throw ImportError.unreadable }
        return SourceFrames(images: images, delays: Array(repeating: step, count: images.count))
    }

    /// A single frame (the poster while the full sample is prepared).
    static func poster(url: URL, at t: Double) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: ImageLoader.animationMaxPixel, height: ImageLoader.animationMaxPixel)
        return try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }
}
