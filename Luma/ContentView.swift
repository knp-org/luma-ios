import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(MusicPlayer.self) private var player
    @State private var selectedTab = 0
    @State private var showPlayer = false
    @State private var showImport = false

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Listen", systemImage: "headphones", value: 0) {
                ListenView(showImport: $showImport, showPlayer: $showPlayer, selectedTab: $selectedTab).accessibilityHidden(showPlayer)
            }
            Tab("Library", systemImage: "square.stack", value: 1) {
                LibraryView(showImport: $showImport, showPlayer: $showPlayer).accessibilityHidden(showPlayer)
            }
            Tab("Playlists", systemImage: "music.note.list", value: 2) {
                PlaylistsView(showPlayer: $showPlayer).accessibilityHidden(showPlayer)
            }
            Tab("Insights", systemImage: "chart.bar.xaxis", value: 3) {
                AnalyticsView(showPlayer: $showPlayer).accessibilityHidden(showPlayer)
            }
            Tab("Search", systemImage: "magnifyingglass", value: 4, role: .search) {
                SearchView(showPlayer: $showPlayer).accessibilityHidden(showPlayer)
            }
        }
        .tabViewBottomAccessory {
            if !player.tracks.isEmpty { MiniPlayer(showPlayer: $showPlayer).accessibilityHidden(showPlayer) }
        }
        .onChange(of: player.tracks.isEmpty) { _, empty in if empty { showPlayer = false } }
        .fullScreenCover(isPresented: $showPlayer) { NowPlayingView() }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await player.importFiles(urls) }
            case .failure(let error): player.error = error.localizedDescription
            }
        }
        .modifier(PlayerFeedback(active: !showPlayer))
    }
}

struct ListenView: View {
    @Environment(MusicPlayer.self) private var player
    @Binding var showImport: Bool
    @Binding var showPlayer: Bool
    @Binding var selectedTab: Int
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Image("LumaMark").resizable().scaledToFit().frame(width: 32, height: 32).accessibilityHidden(true)
                        Text("Luma").font(.title.bold())
                        Spacer()
                        GlassIcon(symbol: "slider.horizontal.3", label: "Player settings") { showSettings = true }
                    }
                    Button { showImport = true } label: { Label("Import music", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 10) }
                        .buttonStyle(.glass).accessibilityIdentifier("library.import")
                    if player.tracks.isEmpty {
                        ContentUnavailableView("No music", systemImage: "music.note", description: Text("Import audio files to get started."))
                            .accessibilityIdentifier("library.empty")
                    } else {
                        HStack(spacing: 16) {
                            NavigationLink {
                                TrackCollectionView(title: "Favorites", subtitle: "", source: .favorites, showPlayer: $showPlayer)
                            } label: { Label("Favorites", systemImage: "heart").frame(maxWidth: .infinity) }
                            Button { selectedTab = 2 } label: { Label("Playlists", systemImage: "music.note.list").frame(maxWidth: .infinity) }
                        }.buttonStyle(.glass)
                        HStack {
                            Text(player.recentTracks.isEmpty ? "Songs" : "Recently played").font(.title3.bold())
                            Spacer()
                            Button("View all") { selectedTab = 1 }.font(.subheadline)
                        }
                        ForEach(Array((player.recentTracks.isEmpty ? player.tracks : player.recentTracks).prefix(10))) { track in
                            TrackRow(track: track) { player.select(track); showPlayer = true }
                        }
                    }
                }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.background { AppBackground() }.toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $showSettings) { PlayerSettingsView() }
        }
    }
}

struct TrackRow: View {
    @Environment(MusicPlayer.self) private var player
    let track: Track
    var action: () -> Void
    @State private var showPlaylistPicker = false
    @State private var showLyrics = false
    @State private var showInfo = false
    @State private var confirmRemoval = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 13) {
                    TrackArtwork(track: track).frame(width: 52, height: 52).clipShape(.rect(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Text(track.title).font(.system(size: 15, weight: .medium))
                            if player.favorites.contains(track.id) { Image(systemName: "heart.fill").font(.system(size: 9)) }
                        }.foregroundStyle(.white)
                        Text(track.artist).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }.lineLimit(1)
                    Spacer(minLength: 0)
                    if player.current.id == track.id && player.isPlaying { Equalizer(active: true).foregroundStyle(Theme.accent) }
                    else if let length = track.length { Text(formattedTime(length)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Play \(track.title) by \(track.artist)")
            Menu {
                Button("Play now", systemImage: "play", action: action)
                Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.enqueue(track, next: true) }
                Button("Play later", systemImage: "text.line.last.and.arrowtriangle.forward") { player.enqueue(track, next: false) }
                Divider()
                Button(player.favorites.contains(track.id) ? "Remove from favorites" : "Add to favorites", systemImage: player.favorites.contains(track.id) ? "heart.fill" : "heart") { player.toggleFavorite(track) }
                Button("Add to playlist", systemImage: "text.badge.plus") { showPlaylistPicker = true }
                Button("Lyrics", systemImage: "music.note") { showLyrics = true }
                Button("Track details", systemImage: "info.circle") { showInfo = true }
                if let url = player.url(for: track) { ShareLink(item: url) { Label("Share audio file", systemImage: "square.and.arrow.up") } }
                if track.isImported {
                    Divider()
                    Button("Remove from library", systemImage: "trash", role: .destructive) { confirmRemoval = true }
                }
            } label: { Image(systemName: "ellipsis").foregroundStyle(Theme.secondary).frame(width: 32, height: 44) }
                .accessibilityLabel("Options for \(track.title)")
        }
        .sheet(isPresented: $showPlaylistPicker) { AddToPlaylistView(tracks: [track]) }
        .sheet(isPresented: $showLyrics) { LyricsView(track: track) }
        .sheet(isPresented: $showInfo) { TrackInfoView(track: track) }
        .confirmationDialog("Remove \(track.title)?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove from library", role: .destructive) { player.removeImportedTrack(track) }
        } message: { Text("This removes Luma’s copy, saved lyrics, and playlist entries. Your original file stays in Files.") }
    }
}

struct MiniPlayer: View {
    @Environment(MusicPlayer.self) private var player
    @Binding var showPlayer: Bool
    var body: some View {
        HStack(spacing: 12) {
            Button { showPlayer = true } label: {
                HStack(spacing: 12) {
                    TrackArtwork(track: player.current).frame(width: 40, height: 40).clipShape(.rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.current.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text(player.current.artist).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }.lineLimit(1)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Open now playing")
            Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 19)).frame(width: 40, height: 44) }
                .buttonStyle(.plain).accessibilityLabel(player.isPlaying ? "Pause" : "Play").accessibilityIdentifier("mini.playPause")
            Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 18)).frame(width: 36, height: 44) }
                .buttonStyle(.plain).accessibilityLabel("Next track").accessibilityIdentifier("mini.next")
        }.padding(.horizontal, 14).padding(.vertical, 5)
    }
}

struct PlayerFeedback: ViewModifier {
    @Environment(MusicPlayer.self) private var player
    var active = true
    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top) {
                if active, player.storageIssue != nil {
                    Label("Library storage needs attention. Open player settings.", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption).padding(10).frame(maxWidth: .infinity).background(.ultraThinMaterial)
                }
            }
            .alert("Something went quiet", isPresented: Binding(get: { active && player.error != nil }, set: { if !$0 { player.error = nil } })) {
                Button("OK") { player.error = nil }
            } message: { Text(player.error ?? "") }
            .overlay(alignment: .top) {
                if active, let notice = player.notice {
                    Text(notice).font(.footnote.weight(.medium)).padding(.horizontal, 20).padding(.vertical, 14)
                        .glassEffect(in: .capsule).padding(.top, 6).allowsHitTesting(false)
                        .task(id: notice) {
                            try? await Task.sleep(for: .seconds(2.5))
                            if !Task.isCancelled && player.notice == notice { player.notice = nil }
                        }
                }
            }
            .overlay {
                if active && player.importing {
                    VStack(spacing: 12) {
                        ProgressView(value: Double(player.importCompleted), total: Double(max(1, player.importTotal)))
                        Text("Importing \(player.importCompleted) of \(player.importTotal)").font(.subheadline)
                        Text(player.importFilename).font(.caption).lineLimit(1)
                    }.frame(width: 240).padding(28).glassEffect(in: .rect(cornerRadius: 24))
                }
            }
    }
}
