import SwiftUI
import PixelClipKit

/// Playlist (docs/DESIGN.md ▸ Playlist): the on/off card, the entries (drag to reorder, swipe to remove
/// with a 5 s Undo, tap for "Play it once at a time"), and "+ Add something".
struct PlaylistView: View {
    @Environment(Router.self) private var router
    @Environment(Sender.self) private var sender
    @State private var store = PlaylistStore.shared
    @State private var timing: PlaylistEntry?

    var body: some View {
        List {
            Section {
                switchCard
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 12, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section {
                if store.entries.isEmpty {
                    Text("Nothing in the playlist yet. Add a photo, a drawing, a message or an extra: the clip plays them one after another.")
                        .font(.subheadline).foregroundStyle(Z2.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 24, bottom: 8, trailing: 24))
                }
                ForEach(store.entries) { entry in
                    Button { timing = entry } label: { PlaylistRow(entry: entry) }
                        .buttonStyle(Z2Press(scale: 0.98))
                        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { remove(entry) } label: { Label("Remove", systemImage: "trash") }
                        }
                        .accessibilityAction(named: "Remove") { remove(entry) }
                        .accessibilityHint("Opens the timing")
                        .accessibilityIdentifier("playlistRow.\(entry.id)")
                }
                .onMove { from, to in
                    store.move(fromOffsets: from, toOffset: to)
                    sender.send(.playlist, kind: .quiet)
                }
                if !store.entries.isEmpty {
                    Text("Drag to reorder · swipe left to remove · tap for timing")
                        .font(.footnote).foregroundStyle(Z2.hint)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .moveDisabled(true)
                        .deleteDisabled(true)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(Z2.spring, value: store.entries)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Z2PrimaryButton(title: "Add something", systemImage: "plus") { router.addSomething = true }
                    .accessibilityIdentifier("addSomething")
                Text("A photo, a drawing, a message or an extra").font(.footnote).foregroundStyle(Z2.hint)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(Z2.ground)
        }
        .z2Screen("Playlist")
        // The send in plain words (the same capsule as Home's), pushing the list down while it shows.
        .safeAreaInset(edge: .top, spacing: 0) { SendStatusCapsule().padding(.vertical, sender.stage == nil ? 0 : 6) }
        .sheet(item: $timing) { entry in TimingSheet(entryID: entry.id) }
        .sensoryFeedback(.impact(weight: .light), trigger: store.entries.map(\.id))
    }

    private var switchCard: some View {
        Toggle(isOn: Binding(get: { store.isOn }, set: { on in sender.turnPlaylist(on: on) })) {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.isOn ? "Playlist is on" : "Playlist is off").font(.headline).foregroundStyle(Z2.text)
                Text(store.isOn ? "The clip plays these one after another, a minute each"
                                : "The clip keeps showing what you sent last")
                    .font(.footnote).foregroundStyle(Z2.secondary)
            }
        }
        .tint(Color.accentColor)
        .z2Card(radius: 18, padding: 16)
        .accessibilityIdentifier("playlistSwitch")
    }

    /// Out at once, back with Undo for 5 seconds.
    private func remove(_ entry: PlaylistEntry) {
        guard let index = store.entries.firstIndex(where: { $0.id == entry.id }), let removed = store.remove(entry.id) else { return }
        sender.send(.playlist, kind: .quiet)
        router.show("Removed “\(removed.name)”", systemImage: "trash", undo: { [store, sender] in
            store.insert(removed, at: index)
            sender.send(.playlist, kind: .quiet)
        })
    }
}

/// Thumbnail, name, "1 min" (or "once, at 21:30 · then back to the playlist"), drag handle.
private struct PlaylistRow: View {
    let entry: PlaylistEntry
    @State private var store = PlaylistStore.shared

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = store.thumbnail(for: entry) {
                    Image(uiImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                } else {
                    Color.black
                }
            }
            .frame(width: 96, height: 43)
            .background(.black)
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.subheadline.weight(.semibold)).foregroundStyle(Z2.text).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(store.timingLine(entry, now: ctx.date)).font(.footnote).foregroundStyle(Z2.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "line.3.horizontal").foregroundStyle(Z2.hint).accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Z2.card, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay {
            if entry.isTimed {
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Z2.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .contentShape(.rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Tap on an entry: "Play it once at a time" (on/off and the time).
private struct TimingSheet: View {
    let entryID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(Sender.self) private var sender
    @State private var store = PlaylistStore.shared
    @State private var time = Date()

    private var entry: PlaylistEntry? { store.entry(entryID) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let entry {
                    HStack(spacing: 12) {
                        if let image = store.thumbnail(for: entry) {
                            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 96, height: 43).clipShape(.rect(cornerRadius: 6, style: .continuous))
                        }
                        Text(entry.name).font(.headline).foregroundStyle(Z2.text)
                    }
                    VStack(spacing: 0) {
                        Toggle(isOn: Binding(get: { entry.isTimed }, set: { on in
                            setTime(on ? time : nil)
                        })) {
                            Text("Play it once at a time").foregroundStyle(Z2.text)
                        }
                        .tint(Color.accentColor)
                        .padding(16)
                        .accessibilityIdentifier("playOnceToggle")
                        if entry.isTimed {
                            Z2Divider()
                            DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                                .foregroundStyle(Z2.text)
                                .padding(16)
                                .onChange(of: time) { _, t in setTime(t) }
                        }
                    }
                    .background(Z2.card, in: .rect(cornerRadius: 18, style: .continuous))
                    Text(entry.isTimed ? "It plays for a minute at that time, then the clip goes back to the playlist."
                                       : "It takes its turn in the playlist, a minute each time.")
                        .font(.footnote).foregroundStyle(Z2.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Z2.sheet.ignoresSafeArea())
            .navigationTitle("Timing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear {
            time = entry?.at ?? Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date()
        }
        .animation(Z2.spring, value: entry?.isTimed)
    }

    /// The next such time of day (today, else tomorrow); nil puts it back in the rotation.
    private func setTime(_ t: Date?) {
        let at = t.map { d -> Date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            return PlaylistSchedule.upcoming(hour: c.hour ?? 0, minute: c.minute ?? 0)
        }
        store.setTime(entryID, at: at)
        sender.send(.playlist, kind: .quiet)
    }
}

/// Playlist ▸ + Add something: the same makers as Home, ending in "Add to the playlist".
struct AddSomethingSheet: View {
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            option("A photo", "photo") { router.picking = .playlist }
                            option("A drawing", "pencil") { router.open(.draw(.playlist)) }
                        }
                        GridRow {
                            option("A message", "textformat") { router.open(.write(.playlist)) }
                                .gridCellColumns(2)
                        }
                    }
                    Z2SectionLabel(text: "An extra")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                        ForEach(Extra.allCases) { extra in
                            Button {
                                go { router.extra = ExtraRequest(extra: extra, mode: .playlist) }
                            } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    ExtraGlyph(extra: extra)
                                    Spacer(minLength: 6)
                                    Text(extra.title).font(.subheadline.weight(.semibold)).foregroundStyle(Z2.text)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                                .background(Z2.card, in: .rect(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(Z2Press(scale: 0.95))
                            .accessibilityLabel(extra.title)
                        }
                    }
                }
                .padding(20)
            }
            .background(Z2.sheet.ignoresSafeArea())
            .navigationTitle("Add to the playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func option(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button { go(action) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage).font(.title2).foregroundStyle(Color.accentColor)
                Text(title).font(.headline).foregroundStyle(Z2.text)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background(Z2.card, in: .rect(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(Z2Press())
    }

    /// Closes this sheet, then opens the maker (a sheet can't present over a closing one).
    private func go(_ action: @escaping () -> Void) {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            action()
        }
    }
}
