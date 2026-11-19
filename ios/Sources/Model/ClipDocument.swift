import Foundation
import Observation
import PixelClipKit

/// The clip's base item ("Now"): what it plays indefinitely, set by every plain send (Send, Draw, Write,
/// an Extra, a re-send from Recent, the Reader). The playlist only adds around it. Persisted in UserDefaults.
///
/// **Undo** (docs/DESIGN.md "Forgiveness over confirmation"): every change of Now — a new item of any kind,
/// or clearing it — remembers the previous Now (one level, persisted, so it survives a relaunch).
/// `undo()` puts it back and sends it through the normal send path (`ClipSender`). The toast is the UI's.
@MainActor @Observable
final class NowOnClip {
    static let shared = NowOnClip()

    private(set) var item: NowItem?
    /// There is a previous Now to put back (Home's Undo pill).
    var canUndo: Bool { previous != nil }
    /// What Undo would put back (`.some(nil)`: the clip had nothing on it).
    private(set) var previous: NowItem??

    private enum Keys {
        static let item = "nowOnClip.v1"
        static let previous = "nowOnClip.previous.v1"
        static let migrated = "nowOnClip.migrated.v1"
    }

    /// The previous Now as stored (`item` nil: nothing was on the clip).
    private struct Previous: Codable { var item: NowItem? }

    @ObservationIgnored private let defaults: UserDefaults
    /// How Undo sends (default: `ClipSender.shared.send()`); tests replace it.
    @ObservationIgnored var send: @MainActor () async -> Void = { await ClipSender.shared.send() }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        item = defaults.data(forKey: Keys.item).flatMap { try? JSONDecoder().decode(NowItem.self, from: $0) }
        previous = defaults.data(forKey: Keys.previous).flatMap { try? JSONDecoder().decode(Previous.self, from: $0) }.map(\.item)
    }

    func set(_ content: MomentContent, title: String) { set(NowItem(content: content, title: title)) }

    /// Makes `item` Now (nil clears it). `undoable` (default): the Now it replaces can be put back.
    func set(_ item: NowItem?, undoable: Bool = true) {
        guard item != self.item else { return }
        if undoable { setPrevious(.some(self.item)) }
        store(item)
    }

    /// Takes Now off (undoable).
    func clear() { set(nil) }

    /// Puts the previous Now back and sends it (the same path as any Send). One level: afterwards
    /// there's nothing to undo.
    func undo() async {
        guard let previous else { return }
        setPrevious(nil)
        store(previous)
        await send()
    }

    /// A library item was deleted: it stops being Now (not undoable) and can't come back through Undo.
    func forget(assetID: String) {
        if item?.content.assetID == assetID { store(nil) }
        if case .some(.some(let p)) = previous, p.content.assetID == assetID { setPrevious(nil) }
    }

    /// The clip was erased: nothing is on it, and there is nothing to put back (not undoable).
    func forgetAll() {
        store(nil)
        setPrevious(nil)
    }

    /// Shows this library picture (or anything with the same content).
    func shows(assetID: String) -> Bool { item?.content.assetID == assetID }

    var migrated: Bool {
        get { defaults.bool(forKey: Keys.migrated) }
        set { defaults.set(newValue, forKey: Keys.migrated) }
    }

    private func store(_ item: NowItem?) {
        self.item = item
        if let item, let data = try? JSONEncoder().encode(item) { defaults.set(data, forKey: Keys.item) } else { defaults.removeObject(forKey: Keys.item) }
    }

    private func setPrevious(_ p: NowItem??) {
        previous = p
        if case .some(let inner) = p, let data = try? JSONEncoder().encode(Previous(item: inner)) {
            defaults.set(data, forKey: Keys.previous)
        } else {
            defaults.removeObject(forKey: Keys.previous)
        }
    }
}

/// The one playlist document every send PUTs, composed by `PlaylistComposer` from Now (`NowOnClip`) and
/// the playlist (`PlaylistStore`, through `PlaylistSchedule`): Now first (held when alone), the playlist's
/// untimed entries a minute each while it's on, its timed entries as `queue[]`.
@MainActor
enum ClipDocument {
    static func inputs(library: LibraryStore, playlist: PlaylistStore = .shared,
                       nowItem: NowOnClip = .shared) -> PlaylistComposer.Inputs {
        // An oracle plays with its current settings (mode, card of the day, the ids of its deck, keys and notes) (a re-edit may have changed them); gone from the library, it drops out.
        func current(_ c: MomentContent) -> MomentContent {
            switch c {
            case .oracle(let o): return library.oracleItem(for: o.libraryKey).map { .oracle($0) } ?? .asset(o.libraryKey)
            default: return c
            }
        }
        var now = nowItem.item
        if let c = now?.content { now?.content = current(c) }
        let entries = playlist.entries.map { e -> PlaylistEntry in
            var e = e
            e.content = current(e.content)
            return e
        }
        // Pictures deleted from the library drop out (`rotationItem` is nil for them).
        return PlaylistSchedule.inputs(now: now, entries: entries, isOn: playlist.isOn, scrolls: library.scrolls) {
            library.rotationItem(for: $0)
        }
    }

    /// What a send PUTs now (timed entries that have played are left out).
    static func playlist(library: LibraryStore, playlist: PlaylistStore = .shared,
                         nowItem: NowOnClip = .shared, now: Date = Date()) -> Playlist {
        PlaylistComposer.playlist(inputs(library: library, playlist: playlist, nowItem: nowItem), now: now)
    }

    /// The playlist adds something around Now (rotating entries while it's on, one-offs still to come).
    static func hasPlaylist(library: LibraryStore, playlist: PlaylistStore = .shared, now: Date = Date()) -> Bool {
        !PlaylistComposer.plan(inputs(library: library, playlist: playlist)).isTonightEmpty(now: now)
    }

    /// From the oldest model (a library playlist of N entries): the first item becomes Now (if nothing
    /// is), the rest join the playlist. Runs once; returns the line for a toast when anything moved.
    /// (the earlier design's Tonight moves into the playlist when `PlaylistStore` first loads.)
    static func migrateIfNeeded(library: LibraryStore, playlist: PlaylistStore = .shared,
                                nowItem: NowOnClip = .shared) -> String? {
        guard !nowItem.migrated else { return nil }
        nowItem.migrated = true
        let legacy = library.legacyPlaylistSlots
        defer { library.clearLegacyPlaylist() }
        guard !legacy.isEmpty else { return nil }
        let r = NowMigration.migrate(library: legacy, tonight: .empty)
        if nowItem.item == nil, let now = r.now { nowItem.set(now, undoable: false) }
        let slots = r.tonight.extras.map { RotationSlot(id: $0.id, item: $0.item, title: $0.title) }
        for e in PlaylistMigration.entries(fromLegacy: slots) { playlist.add(e.content, name: e.name) }
        guard let now = r.now else { return nil }
        return r.moved == 0 ? "“\(now.title)” is on the clip." : "“\(now.title)” is on the clip; \(r.moved) more are in the playlist."
    }

    /// Identity of the composed document (and the content of its assets).
    static func fingerprint(library: LibraryStore, playlist: PlaylistStore = .shared) -> String {
        PlaylistComposer.fingerprint(inputs(library: library, playlist: playlist)) { library.item($0)?.sha256 }
    }

    static func isEmpty(library: LibraryStore, playlist: PlaylistStore = .shared) -> Bool {
        let p = self.playlist(library: library, playlist: playlist)
        return p.items.isEmpty && (p.queue ?? []).isEmpty
    }

    /// Something composed differs from what this clip (by its device id; nil: whichever clip was sent to
    /// last) was last sent, from any sender.
    static func hasUnsentChanges(library: LibraryStore, playlist: PlaylistStore = .shared, deviceID: String? = nil) -> Bool {
        !isEmpty(library: library, playlist: playlist)
            && fingerprint(library: library, playlist: playlist) != library.sentFingerprint(for: deviceID)
    }

    /// Record a successful PUT of the composed document to the clip with this device id.
    static func markSent(library: LibraryStore, playlist: PlaylistStore = .shared, deviceID: String?) {
        library.markSent(fingerprint: fingerprint(library: library, playlist: playlist), deviceID: deviceID)
    }

    /// The clip with this device id was erased (`POST /erase`): forget what the phone believed it had, so the next
    /// send uploads everything it needs. Nothing is on the clip and there is nothing to undo (Now and its previous
    /// go); the playlist switch goes off (its entries stay), so the next send is just that thing and turning the
    /// playlist on again sends the playlist; what was last sent to that clip goes; the clip's texts as last read go.
    /// The library, recents, drawings and Reader texts stay on the phone.
    static func forgetClipContent(library: LibraryStore, playlist: PlaylistStore = .shared, nowItem: NowOnClip = .shared,
                                  reader: ReaderStore = .shared, deviceID: String?) {
        nowItem.forgetAll()
        playlist.isOn = false
        library.forgetSent(deviceID: deviceID)
        reader.recordClipTexts([])
    }

    /// The assets a composed playlist needs, as stored on the phone.
    static func localAssets(for playlist: Playlist, library: LibraryStore) -> [LocalAsset] {
        library.localAssets(ids: playlist.assetIDs)
    }
}
