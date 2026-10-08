import SwiftUI

private struct LyricsClientKey: EnvironmentKey {
    static let defaultValue: any LyricsSearching = LRCLIBClient()
}

extension EnvironmentValues {
    var lyricsClient: any LyricsSearching {
        get { self[LyricsClientKey.self] }
        set { self[LyricsClientKey.self] = newValue }
    }
}

struct LyricsLookupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lyricsClient) private var client
    let track: Track
    @State private var title: String
    @State private var artist: String
    @State private var album = ""
    @State private var request: SearchRequest?
    @State private var phase = Phase.idle

    private struct SearchRequest: Equatable {
        let id = UUID()
        let query: LyricsQuery
    }
    private enum Phase {
        case idle, loading, results([LyricsMatch]), failed(String)
    }
    private var loading: Bool { if case .loading = phase { true } else { false } }

    init(track: Track) {
        self.track = track
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Song title", text: $title).accessibilityIdentifier("lyrics.searchTitle")
                    TextField("Artist (optional)", text: $artist).accessibilityIdentifier("lyrics.searchArtist")
                    TextField("Album (optional)", text: $album)
                    Button {
                        phase = .loading
                        request = SearchRequest(query: LyricsQuery(title: title, artist: artist, album: album, duration: track.length))
                    } label: {
                        Label("Search LRCLIB", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                    }
                    .disabled(loading || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("lyrics.search")
                } header: { Text("Find a song") } footer: {
                    Text("Search sends these details to LRCLIB. Your audio stays on your device. Add an album to narrow the results.")
                }
                .autocorrectionDisabled()

                Section {
                    switch phase {
                    case .idle:
                        ContentUnavailableView("Search lyrics", systemImage: "text.magnifyingglass", description: Text("Search for lyrics, preview a matching version, then save it for offline listening."))
                    case .loading:
                        HStack { Spacer(); ProgressView("Finding lyrics…"); Spacer() }.padding(.vertical, 24)
                    case .failed(let message):
                        ContentUnavailableView("Couldn’t find lyrics", systemImage: "wifi.exclamationmark", description: Text(message))
                            .accessibilityIdentifier("lyrics.searchError")
                    case .results(let matches):
                        if matches.isEmpty {
                            ContentUnavailableView("No lyrics found", systemImage: "text.magnifyingglass", description: Text("Check the title and artist, or clear the album and try again. You can still add lyrics manually."))
                                .accessibilityIdentifier("lyrics.noResults")
                        }
                        ForEach(matches) { match in
                            NavigationLink {
                                LyricsMatchPreview(track: track, match: match) { dismiss() }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(match.trackName).font(.headline)
                                    Text(match.artistName).font(.subheadline).foregroundStyle(Theme.secondary)
                                    if !match.albumName.isEmpty { Text(match.albumName).font(.caption).foregroundStyle(Theme.secondary) }
                                    Text("\(match.format) · \(formattedTime(match.duration))").font(.caption2).foregroundStyle(Theme.accent)
                                }.padding(.vertical, 4)
                            }.accessibilityIdentifier("lyrics.result.\(match.id)")
                        }
                    }
                } header: { if let request { Text("Results for \(request.query.title)") } }
                Section {
                    Link("Lyrics provided by LRCLIB", destination: URL(string: "https://lrclib.net")!)
                        .font(.footnote)
                    Text("Free lookup · No account or API key required").font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            .scrollContentBackground(.hidden).background { AppBackground() }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Find lyrics online").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: request) {
                guard let request else { return }
                do {
                    let matches = try await client.search(request.query)
                    try Task.checkCancellation()
                    phase = .results(matches)
                } catch is CancellationError {
                    // Closing the sheet cancels the request without showing an error.
                } catch {
                    guard !Task.isCancelled else { return }
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }
}

private struct LyricsMatchPreview: View {
    @Environment(MusicPlayer.self) private var player
    let track: Track
    let match: LyricsMatch
    let onSave: () -> Void
    @State private var confirmReplace = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(match.trackName).font(.title2.bold())
                Text([match.artistName, match.albumName].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(Theme.secondary)
                Label("\(match.format) · \(formattedTime(match.duration))", systemImage: match.isSynchronized ? "waveform" : "text.alignleft")
                    .font(.caption).foregroundStyle(Theme.accent)
                Text("Save to \(track.title) by \(track.artist)").font(.footnote).foregroundStyle(Theme.secondary)
                Divider()
                if let text = match.text {
                    Text(LyricsDocument(text).lines.map(\.text).joined(separator: "\n"))
                        .font(.body).lineSpacing(8).textSelection(.enabled)
                } else {
                    Text(match.instrumental ? "LRCLIB marks this version as instrumental. There are no lyrics to save." : "This version has no lyrics to save.")
                        .foregroundStyle(Theme.secondary)
                }
                Link("Source: LRCLIB", destination: URL(string: "https://lrclib.net")!).font(.footnote)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .background { AppBackground() }
        .navigationTitle("Preview lyrics").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save lyrics") {
                    if player.lyrics[track.id]?.isEmpty == false { confirmReplace = true } else { save() }
                }.disabled(match.text == nil).accessibilityIdentifier("lyrics.downloadSave")
            }
        }
        .alert("Replace saved lyrics?", isPresented: $confirmReplace) {
            Button("Replace lyrics", role: .destructive) { save() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The lyrics currently saved for \(track.title) will be replaced by this version from LRCLIB.") }
    }

    private func save() {
        guard let text = match.text else { return }
        player.setLyrics(text, for: track)
        onSave()
    }
}
