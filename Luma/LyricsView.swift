import SwiftUI
import UniformTypeIdentifiers

struct LyricsView: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let track: Track
    @State private var showEditor = false
    @State private var showImport = false
    @State private var showLookup = false
    @State private var followAlong = true
    private var text: String { player.lyrics[track.id] ?? "" }
    private var document: LyricsDocument { LyricsDocument(text) }
    private var activeLine: Int? { player.current.id == track.id ? document.activeLine(at: player.elapsed) : nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    TrackArtwork(track: track).frame(width: 46, height: 46).clipShape(.rect(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.headline).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Button {
                        if player.current.id == track.id { player.toggle() } else { player.select(track) }
                    } label: { Image(systemName: player.current.id == track.id && player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }.buttonStyle(.glass).accessibilityLabel("Play or pause lyrics track")
                }.padding(24)
                if text.isEmpty {
                    Spacer()
                    VStack(spacing: 18) {
                        Image(systemName: "quote.bubble").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(Theme.accent)
                        Text("No lyrics").font(.system(size: 30, design: .serif)).multilineTextAlignment(.center)
                        Text("Find lyrics online, paste text, or import an LRC file.")
                            .font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                        Button("Add lyrics") { showEditor = true }.buttonStyle(.glass).accessibilityIdentifier("lyrics.add")
                        Button("Find lyrics online", systemImage: "arrow.down.circle") { showLookup = true }.buttonStyle(.glass).accessibilityIdentifier("lyrics.findOnline")
                        Button("Import lyrics file") { showImport = true }.font(.subheadline)
                    }.padding(32)
                    Spacer()
                } else {
                    if document.isSynchronized {
                        HStack {
                            Label("TIME-SYNCED LYRICS", systemImage: "waveform").font(.system(size: 9, weight: .semibold)).tracking(1.5)
                            Spacer()
                            Button(followAlong ? "Following" : "Follow along") { followAlong.toggle() }.font(.caption)
                        }.foregroundStyle(Theme.secondary).padding(.horizontal, 24).padding(.bottom, 15)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 24) {
                                ForEach(document.lines) { line in
                                    if let time = line.time {
                                        Button {
                                            if player.current.id != track.id { player.select(track) }
                                            player.seek(to: time)
                                        } label: {
                                            lyricText(line).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                        }.buttonStyle(.plain).accessibilityLabel("\(line.text), seek to \(formattedTime(time))").id(line.id)
                                    } else { lyricText(line).id(line.id) }
                                }
                            }.padding(.horizontal, 26).padding(.vertical, 25).padding(.bottom, 100)
                        }
                        .onChange(of: activeLine) { _, line in
                            guard followAlong, let line else { return }
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { proxy.scrollTo(line, anchor: .center) }
                        }
                        .onAppear { if let activeLine { proxy.scrollTo(activeLine, anchor: .center) } }
                    }
                    // New documents reuse line indices; discard cached lazy rows when
                    // replacing plain text with timed lyrics (or editing existing lines).
                    .id(text)
                }
            }
            .background { AppBackground() }
            .navigationTitle("Lyrics").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Find lyrics online", systemImage: "arrow.down.circle") { showLookup = true }.accessibilityIdentifier("lyrics.findOnline")
                        Button("Edit lyrics", systemImage: "pencil") { showEditor = true }
                        Button("Import LRC or text", systemImage: "doc.badge.plus") { showImport = true }
                        if !text.isEmpty { ShareLink(item: text) { Label("Share lyrics", systemImage: "square.and.arrow.up") } }
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Lyrics options")
                }
            }
            .sheet(isPresented: $showEditor) { LyricsEditor(track: track) }
            .sheet(isPresented: $showLookup) { LyricsLookupView(track: track) }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.plainText, .text, UTType(filenameExtension: "lrc") ?? .data]) { result in
                switch result {
                case .success(let url): player.importLyrics(url, for: track)
                case .failure(let error): player.error = error.localizedDescription
                }
            }
            .modifier(PlayerFeedback())
        }
    }
    private func lyricText(_ line: LyricLine) -> some View {
        Text(line.text.isEmpty ? "♪" : line.text)
            .font(.system(size: 29, weight: .semibold)).tracking(-0.7)
            .foregroundStyle(!document.isSynchronized || activeLine == line.id ? .white : .white.opacity(0.32))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct LyricsEditor: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var text = ""
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(track.title).font(.title3.weight(.semibold))
                Text("Paste plain lyrics, or use LRC timestamps such as [00:12.50] to follow the music. Saving an empty field removes your lyrics.").font(.footnote).foregroundStyle(Theme.secondary)
                TextEditor(text: $text).font(.body).scrollContentBackground(.hidden).padding(12).background(.white.opacity(0.04), in: .rect(cornerRadius: 16)).accessibilityIdentifier("lyrics.editor")
            }.padding(24).background { AppBackground() }
                .navigationTitle("Edit lyrics").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { player.setLyrics(text, for: track); dismiss() }.accessibilityIdentifier("lyrics.save") }
                }
                .onAppear { text = player.lyrics[track.id] ?? "" }
        }
    }
}
