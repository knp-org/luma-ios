import SwiftUI

struct PlaylistsView: View {
    @Environment(MusicPlayer.self) private var player
    @Binding var showPlayer: Bool
    @State private var showCreate = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    NavigationLink { TrackCollectionView(title: "Favorites", subtitle: "", source: .favorites, showPlayer: $showPlayer) } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "heart.fill").font(.system(size: 26, weight: .light)).frame(width: 64, height: 64).glassEffect(in: .rect(cornerRadius: 16))
                            VStack(alignment: .leading, spacing: 5) { Text("Favorites").font(.headline); Text("\(player.favorites.count) tracks · Made for you").font(.caption).foregroundStyle(Theme.secondary) }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }.padding(18).background(.white.opacity(0.04), in: .rect(cornerRadius: 22))
                    }.buttonStyle(.plain)
                    HStack {
                        Text("YOUR PLAYLISTS").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Theme.secondary)
                        Spacer()
                        Text("\(player.playlists.count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                    }
                    if player.playlists.isEmpty {
                        VStack(spacing: 15) {
                            Image(systemName: "music.note.list").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(Theme.accent)
                            Text("No playlists").font(.system(size: 25, design: .serif))
                            Text("Create a playlist and add songs from your library.").font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    ForEach(player.playlists) { playlist in
                        NavigationLink { PlaylistDetailView(playlistID: playlist.id, showPlayer: $showPlayer) } label: { PlaylistRow(playlist: playlist) }.buttonStyle(.plain).accessibilityLabel("Open playlist \(playlist.name)")
                    }
                    Button { showCreate = true } label: { Label("Create a playlist", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 9) }.buttonStyle(.glass).accessibilityIdentifier("playlist.create")
                }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.background { AppBackground() }.navigationTitle("Playlists").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("New playlist", systemImage: "plus") { showCreate = true } } }
                .sheet(isPresented: $showCreate) { PlaylistEditor() }
        }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    var body: some View {
        HStack(spacing: 14) {
            PlaylistArtwork(playlist: playlist).frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(playlist.name).font(.system(size: 17, weight: .medium)).lineLimit(1)
                Text("\(playlist.trackIDs.count) tracks").font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.secondary)
        }.contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

struct PlaylistEditor: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    var playlist: Playlist? = nil
    var initialTracks: [Track] = []
    var onSave: (() -> Void)? = nil
    @State private var name = ""
    @State private var description = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Playlist name", text: $name).accessibilityIdentifier("playlist.name") }
                Section("Description") { TextField("Playlist description", text: $description, axis: .vertical).lineLimit(3...5) }
                Section { Text("Add tracks from your library, then arrange them in any order.").font(.footnote).foregroundStyle(Theme.secondary) }
            }
            .scrollContentBackground(.hidden).background { AppBackground() }
            .navigationTitle(playlist == nil ? "New playlist" : "Edit playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let playlist { player.updatePlaylist(playlist.id, name: name, description: description) }
                        else { player.createPlaylist(name: name, description: description, trackIDs: initialTracks.map(\.id)) }
                        dismiss(); onSave?()
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("playlist.save")
                }
            }.onAppear { name = playlist?.name ?? ""; description = playlist?.description ?? "" }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

struct PlaylistDetailView: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    let playlistID: String
    @Binding var showPlayer: Bool
    @State private var showAdd = false
    @State private var showEdit = false
    @State private var confirmDelete = false
    @State private var query = ""
    private var playlist: Playlist? { player.playlists.first { $0.id == playlistID } }

    var body: some View {
        Group {
            if let playlist {
                let allTracks = player.tracks(in: playlist)
                let tracks = allTracks.filter { $0.matches(query) }
                List {
                    VStack(alignment: .leading, spacing: 18) {
                        PlaylistArtwork(playlist: playlist).frame(width: 190, height: 190).clipShape(.rect(cornerRadius: 24)).frame(maxWidth: .infinity).padding(.vertical, 12)
                        Text(playlist.name).font(.system(size: 32, design: .serif))
                        if !playlist.description.isEmpty { Text(playlist.description).font(.subheadline).foregroundStyle(Theme.secondary) }
                        Text("\(tracks.count) tracks · \(formattedTime(tracks.compactMap(\.length).reduce(0, +)))").font(.caption).foregroundStyle(Theme.secondary)
                        CollectionControls(tracks: tracks, title: playlist.name)
                        Button { showAdd = true } label: { Label("Add music", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 6) }.buttonStyle(.glass).accessibilityIdentifier("playlist.addMusic")
                    }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                    Section {
                        if tracks.isEmpty { Text(query.isEmpty ? "No songs in this playlist." : "No matching songs.").font(.subheadline).foregroundStyle(Theme.secondary).listRowBackground(Color.clear) }
                        ForEach(tracks) { track in
                            TrackRow(track: track) { player.select(track, within: tracks, named: playlist.name); showPlayer = true }.listRowBackground(Color.clear)
                        }
                        .onDelete { offsets in
                            let ids = Set(offsets.map { tracks[$0].id })
                            player.removeFromPlaylist(playlist.id, at: IndexSet(playlist.trackIDs.indices.filter { ids.contains(playlist.trackIDs[$0]) }))
                        }
                        .onMove { if query.isEmpty { player.moveInPlaylist(playlist.id, from: $0, to: $1) } }
                        .moveDisabled(!query.isEmpty)
                    } header: { Text("TRACKS").tracking(2) } footer: { if !tracks.isEmpty { Text("Edit to reorder. Swipe a track to remove it from this playlist.") } }
                }
                .listStyle(.plain).scrollContentBackground(.hidden).background { AppBackground() }
                .navigationTitle(playlist.name).navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "Search this playlist")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Add music", systemImage: "plus") { showAdd = true }
                            Button("Rename playlist", systemImage: "pencil") { showEdit = true }
                            ShareLink(item: "\(playlist.name)\n\(playlist.description)\n\n" + allTracks.map { "\($0.title) — \($0.artist)" }.joined(separator: "\n")) { Label("Share track list", systemImage: "square.and.arrow.up") }
                            Button("Delete playlist", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Playlist options")
                    }
                }
                .sheet(isPresented: $showAdd) { TrackSelectionView(playlistID: playlist.id) }
                .sheet(isPresented: $showEdit) { PlaylistEditor(playlist: playlist) }
                .confirmationDialog("Delete \(playlist.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete playlist", role: .destructive) { player.deletePlaylist(playlist.id); dismiss() }
                } message: { Text("The songs stay in your library.") }
            } else { ContentUnavailableView("Playlist unavailable", systemImage: "music.note.list") }
        }
    }
}

struct TrackSelectionView: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    let playlistID: String
    @State private var selected: Set<String> = []
    @State private var query = ""
    private var existing: Set<String> { Set(player.playlists.first { $0.id == playlistID }?.trackIDs ?? []) }
    private var tracks: [Track] { player.tracks.filter { query.isEmpty || "\($0.title) \($0.artist)".localizedCaseInsensitiveContains(query) } }
    var body: some View {
        NavigationStack {
            List {
                ForEach(tracks) { track in
                    Button {
                        if selected.contains(track.id) { selected.remove(track.id) } else { selected.insert(track.id) }
                    } label: {
                        HStack(spacing: 12) {
                            TrackArtwork(track: track).frame(width: 45, height: 45).clipShape(.rect(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) { Text(track.title).font(.subheadline.weight(.medium)); Text(track.artist).font(.caption).foregroundStyle(Theme.secondary) }
                            Spacer()
                            Image(systemName: selected.contains(track.id) || existing.contains(track.id) ? "checkmark.circle.fill" : "circle").font(.title3)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(existing.contains(track.id)).accessibilityLabel("Select \(track.title)")
                }
            }.scrollContentBackground(.hidden).background { AppBackground() }.searchable(text: $query, prompt: "Find music").navigationTitle("Add music").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add \(selected.count)") { player.add(player.tracks.filter { selected.contains($0.id) }, to: playlistID); dismiss() }.disabled(selected.isEmpty).accessibilityIdentifier("playlist.confirmAdd")
                    }
                }
        }
    }
}

struct AddToPlaylistView: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    let tracks: [Track]
    var onSave: (() -> Void)? = nil
    @State private var showCreate = false
    var body: some View {
        NavigationStack {
            List {
                Button { showCreate = true } label: { Label("New playlist", systemImage: "plus") }
                ForEach(player.playlists) { playlist in
                    Button {
                        player.add(tracks, to: playlist.id)
                        player.notice = "Added to \(playlist.name)"
                        dismiss(); onSave?()
                    } label: { PlaylistRow(playlist: playlist) }.buttonStyle(.plain)
                        .accessibilityLabel("Add to \(playlist.name)")
                }
                if player.playlists.isEmpty { Text("Create a playlist and we’ll add your selected music to it.").font(.subheadline).foregroundStyle(Theme.secondary) }
            }.scrollContentBackground(.hidden).background { AppBackground() }.navigationTitle("Add to playlist").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("playlistPicker.done") } }
                .sheet(isPresented: $showCreate) { PlaylistEditor(initialTracks: tracks, onSave: { dismiss(); onSave?() }) }
        }.presentationDetents([.medium, .large])
    }
}
