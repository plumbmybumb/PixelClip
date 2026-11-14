import Foundation

/// An asset the phone has rendered and may need to put on the clip.
public struct LocalAsset: Sendable, Equatable {
    public var id: String
    public var data: Data
    public var sha256: String
    public var name: String

    public init(id: String, data: Data, name: String? = nil) {
        self.id = id; self.data = data; self.sha256 = Hashing.sha256Hex(data); self.name = name ?? id
    }
}

public struct SyncOptions: Sendable, Equatable {
    /// Delete assets on the clip that the phone doesn't know about.
    public var deleteOrphans: Bool
    /// Ids with these prefixes are never deleted as orphans (reader and Tarot font atlases).
    public var protectedPrefixes: [String]
    /// Upload every library asset, not only the ones the playlist uses.
    public var uploadEntireLibrary: Bool
    public var setTime: Bool
    public var endSession: Bool
    /// Don't `PUT /playlist` when the clip already has the same document (`SendSkipRules`).
    public var skipUnchangedPlaylist: Bool
    /// The clip's playlist if already read this session (else the engine reads it when skipping).
    public var clipPlaylist: Playlist?
    /// Never deleted as orphans although this document doesn't use them (e.g. the playlist's pictures
    /// while the playlist is off: turning it on again then needs no upload, only Bluetooth).
    public var keepIDs: Set<String> = []

    public init(deleteOrphans: Bool = false, protectedPrefixes: [String] = [ReaderFontRenderer.assetPrefix, TarotFonts.bodyPrefix, TarotFonts.bigPrefix],
                uploadEntireLibrary: Bool = false, setTime: Bool = true, endSession: Bool = true,
                skipUnchangedPlaylist: Bool = false, clipPlaylist: Playlist? = nil) {
        self.deleteOrphans = deleteOrphans; self.protectedPrefixes = protectedPrefixes
        self.uploadEntireLibrary = uploadEntireLibrary; self.setTime = setTime; self.endSession = endSession
        self.skipUnchangedPlaylist = skipUnchangedPlaylist; self.clipPlaylist = clipPlaylist
    }
}

public struct SyncPlan: Sendable, Equatable {
    public struct Upload: Sendable, Equatable {
        public var id: String
        public var bytes: Int
        /// True when the clip has this id with different content.
        public var replaces: Bool
    }
    public var uploads: [Upload]
    /// Already on the clip with the same SHA-256.
    public var unchanged: [String]
    public var deletions: [String]
    public var playlist: Playlist
    public var setTime: Bool
    public var endSession: Bool
    /// The clip already has exactly this playlist: no `PUT /playlist` (unless an upload fails).
    public var playlistUnchanged = false

    public var uploadBytes: Int { uploads.reduce(0) { $0 + $1.bytes } }
    public var isNoOp: Bool { uploads.isEmpty && deletions.isEmpty }
}

public enum SyncStep: Sendable, Equatable {
    case reading
    case settingTime
    case deleting(index: Int, of: Int, id: String)
    case uploading(index: Int, of: Int, id: String, fraction: Double)
    case playlist
    case endingSession
    case finished
}

public struct SyncProgress: Sendable, Equatable {
    public var step: SyncStep
    /// 0…1 across the whole sync, weighted by bytes for uploads.
    public var overall: Double
}

public struct SyncReport: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public var id: String?
        public var step: String
        public var message: String
        /// The underlying clip error (status code and envelope), for the app's copy.
        public var clipError: ClipError?
        public init(id: String?, step: String, message: String, clipError: ClipError? = nil) {
            self.id = id; self.step = step; self.message = message; self.clipError = clipError
        }
    }
    public var uploaded: [String] = []
    public var unchanged: [String] = []
    public var deleted: [String] = []
    /// Playlist items dropped because their asset couldn't be put on the clip.
    public var droppedFromPlaylist: [String] = []
    public var playlistUpdated = false
    /// The clip already had this playlist (nothing PUT).
    public var playlistSkipped = false
    public var timeSet = false
    public var sessionEnded = false
    public var bytesSent = 0
    public var failures: [Failure] = []
    /// The clip stopped answering part-way; later steps were skipped.
    public var lostConnection = false

    public init() {}

    public var succeeded: Bool { failures.isEmpty && !lostConnection }
    /// The clip has the composed playlist now (sent, or already there).
    public var playlistInPlace: Bool { playlistUpdated || playlistSkipped }
}

/// Diffs the phone's library against the clip's inventory and makes the clip match.
///
/// Order: read inventory → set time → delete orphans (frees space first) → upload changes →
/// PUT playlist (minus anything that failed) → end session.
public struct SyncEngine: Sendable {
    public let client: any ClipClient

    public init(client: any ClipClient) { self.client = client }

    /// Pure planning from an inventory snapshot.
    public static func plan(local: [LocalAsset], playlist: Playlist,
                            remote: [ClipAsset], options: SyncOptions) -> SyncPlan {
        var plan = basePlan(local: local, playlist: playlist, remote: remote, options: options)
        // Skips only when nothing the playlist points at is being replaced or removed.
        let quiet = plan.deletions.isEmpty && !plan.uploads.contains(where: \.replaces)
        if options.skipUnchangedPlaylist, quiet {
            plan.playlistUnchanged = SendSkipRules.playlistUnchanged(plan.playlist, onClip: options.clipPlaylist)
        }
        return plan
    }

    private static func basePlan(local: [LocalAsset], playlist: Playlist,
                                 remote: [ClipAsset], options: SyncOptions) -> SyncPlan {
        let byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        let wantedIDs: [String] = (options.uploadEntireLibrary
            ? local.map(\.id)
            : playlist.assetIDs.filter { byID[$0] != nil }).filter { seen.insert($0).inserted }
        var uploads: [SyncPlan.Upload] = []
        var unchanged: [String] = []
        for id in wantedIDs {
            guard let l = byID[id] else { continue }
            if let r = remoteByID[id] {
                if r.sha256.lowercased() == l.sha256 { unchanged.append(id) } else {
                    uploads.append(.init(id: id, bytes: l.data.count, replaces: true))
                }
            } else {
                uploads.append(.init(id: id, bytes: l.data.count, replaces: false))
            }
        }
        var deletions: [String] = []
        if options.deleteOrphans {
            let keep = Set(wantedIDs).union(byID.keys).union(options.keepIDs)
            deletions = remote.map(\.id).filter { id in
                !keep.contains(id) && !options.protectedPrefixes.contains { id.hasPrefix($0) }
            }.sorted()
        }
        // Playlist items pointing at assets neither local nor remote can't be satisfied.
        let available = Set(byID.keys).union(remoteByID.keys).subtracting(deletions)
        var pl = playlist
        pl.items = pl.items.filter { $0.type != .asset || ($0.id.map(available.contains) ?? false) }
        pl.queue = pl.queue?.filter { $0.type != .asset || ($0.asset.map(available.contains) ?? false) }
        // A board needs its sheet (§5g).
        pl.items = pl.items.filter { $0.type != .board || ($0.id.map(available.contains) ?? false) }
        pl.queue = pl.queue?.filter { $0.type != .board || ($0.asset.map(available.contains) ?? false) }
        // A words scene needs its sheet (§5b.1).
        pl.items = pl.items.filter { !$0.isWords || ($0.id.map(available.contains) ?? false) }
        pl.queue = pl.queue?.filter { !($0.type == .scene && $0.scene == WordsScene.name) || ($0.asset.map(available.contains) ?? false) }
        // An oracle needs all four of its assets.
        pl.items = pl.items.filter { $0.type != .oracle || $0.assetRefs.allSatisfy(available.contains) }
        pl.queue = pl.queue?.filter { $0.type != .oracle || $0.assetRefs.allSatisfy(available.contains) }
        return SyncPlan(uploads: uploads, unchanged: unchanged, deletions: deletions, playlist: pl,
                        setTime: options.setTime, endSession: options.endSession)
    }

    /// Fetch the clip's inventory and plan.
    public func plan(local: [LocalAsset], playlist: Playlist,
                     options: SyncOptions) async throws -> SyncPlan {
        let remote = try await client.assets()
        var options = options
        // What the skip rule compares against, when the caller hasn't read it already.
        if options.skipUnchangedPlaylist, options.clipPlaylist == nil { options.clipPlaylist = try? await client.playlist() }
        return Self.plan(local: local, playlist: playlist, remote: remote, options: options)
    }

    /// Plan and execute. Never throws for clip-side failures; they are reported.
    public func sync(local: [LocalAsset], playlist: Playlist, options: SyncOptions = SyncOptions(),
                     timeSource: @Sendable () -> TimeSync = { .now() },
                     progress: @escaping @Sendable (SyncProgress) -> Void = { _ in }) async -> SyncReport {
        var report = SyncReport()
        progress(.init(step: .reading, overall: 0))
        let plan: SyncPlan
        do { plan = try await self.plan(local: local, playlist: playlist, options: options) } catch {
            report.failures.append(.init(id: nil, step: "inventory", message: Self.describe(error), clipError: Self.clipError(error)))
            report.lostConnection = Self.isConnectionLoss(error)
            return report
        }
        return await execute(plan, local: local, timeSource: timeSource, progress: progress, report: report)
    }

    public func execute(_ plan: SyncPlan, local: [LocalAsset], timeSource: @Sendable () -> TimeSync = { .now() },
                        progress: @escaping @Sendable (SyncProgress) -> Void = { _ in },
                        report initial: SyncReport = SyncReport()) async -> SyncReport {
        var report = initial
        report.unchanged = plan.unchanged
        let byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Weights: fixed small costs + bytes for uploads.
        let fixed = 4096.0
        let totalWeight = fixed * Double(2 + plan.deletions.count + (plan.setTime ? 1 : 0) + (plan.endSession ? 1 : 0))
            + Double(plan.uploadBytes)
        var done = 0.0
        func emit(_ step: SyncStep, _ extra: Double = 0) {
            progress(.init(step: step, overall: min(1, (done + extra) / max(totalWeight, 1))))
        }

        // Every remaining step needs the clip; bail out on the first transport failure.
        func fail(_ id: String?, _ step: String, _ error: any Error) -> Bool {
            report.failures.append(.init(id: id, step: step, message: Self.describe(error), clipError: Self.clipError(error)))
            if Self.isConnectionLoss(error) { report.lostConnection = true; return true }
            return false
        }

        if plan.setTime {
            emit(.settingTime)
            do { try await client.setTime(timeSource()); report.timeSet = true } catch {
                if fail(nil, "time", error) { return report }
            }
            done += fixed
        }

        for (i, id) in plan.deletions.enumerated() {
            emit(.deleting(index: i + 1, of: plan.deletions.count, id: id))
            do { try await client.deleteAsset(id: id); report.deleted.append(id) } catch {
                if case ClipError.http(404, _) = error { report.deleted.append(id) } else if fail(id, "delete", error) {
                    return report
                }
            }
            done += fixed
        }

        var failedUploads = Set<String>()
        for (i, up) in plan.uploads.enumerated() {
            guard let asset = byID[up.id] else { continue }
            let base = done
            let n = plan.uploads.count
            let weight = Double(up.bytes)
            emit(.uploading(index: i + 1, of: n, id: up.id, fraction: 0))
            let reporter: ProgressHandler = { f in
                progress(.init(step: .uploading(index: i + 1, of: n, id: up.id, fraction: f),
                               overall: min(1, (base + weight * f) / max(totalWeight, 1))))
            }
            do {
                switch try await client.putAsset(id: up.id, data: asset.data, progress: reporter) {
                case .created: report.uploaded.append(up.id); report.bytesSent += up.bytes
                case .alreadyPresent: report.unchanged.append(up.id)
                }
            } catch {
                failedUploads.insert(up.id)
                if fail(up.id, "upload", error) { return report }
            }
            done += weight
        }

        emit(.playlist)
        var pl = plan.playlist
        if !failedUploads.isEmpty {
            // Keep items whose asset was already on the clip (an old version is better than a 422).
            let replaced = Set(plan.uploads.filter(\.replaces).map(\.id))
            let dropped = failedUploads.subtracting(replaced)
            report.droppedFromPlaylist = pl.items.compactMap(\.assetRef).filter(dropped.contains)
            // An item goes when any asset it needs didn't make it (an oracle's deck, keys or notes too).
            pl.items = pl.items.filter { dropped.isDisjoint(with: $0.assetRefs) }
            pl.queue = pl.queue?.filter { dropped.isDisjoint(with: $0.assetRefs) }
        }
        if plan.playlistUnchanged && failedUploads.isEmpty {
            report.playlistSkipped = true
        } else {
            do { try await client.putPlaylist(pl); report.playlistUpdated = true } catch {
                if fail(nil, "playlist", error) { return report }
            }
        }
        done += fixed

        if plan.endSession {
            emit(.endingSession)
            do { try await client.endSession(); report.sessionEnded = true } catch {
                _ = fail(nil, "session", error)
            }
            done += fixed
        }
        done = totalWeight
        emit(.finished)
        return report
    }

    /// Make sure one asset is on the clip, then play it now ("Show now"). `scroll`: a strip's scroll
    /// block (`Playlist.showScroll(for:fallback:)`), so it scrolls instead of showing its first screen.
    public func showNow(_ asset: LocalAsset, durationMs: Int? = nil, scroll: PlaylistItem.Scroll? = nil,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let remote = try await client.assets()
        if remote.first(where: { $0.id == asset.id })?.sha256.lowercased() != asset.sha256 {
            _ = try await client.putAsset(id: asset.id, data: asset.data, progress: progress)
        }
        progress(1)
        try await client.show(id: asset.id, durationMs: durationMs, scroll: scroll)
    }

    static func isConnectionLoss(_ error: any Error) -> Bool {
        (error as? ClipError)?.isUnreachable ?? (error is URLError)
    }

    static func clipError(_ error: any Error) -> ClipError? {
        if let e = error as? ClipError { return e }
        if let u = error as? URLError { return .unreachable(u.localizedDescription) }
        return nil
    }

    static func describe(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
