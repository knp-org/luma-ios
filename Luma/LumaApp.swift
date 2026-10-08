import SwiftUI
#if DEBUG
import AVFoundation
#endif

@main
struct LumaApp: App {
    @State private var player = Self.makePlayer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(AlbumTheme())
                .environment(player)
                .environment(\.lyricsClient, Self.lyricsClient)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { player.saveForBackground() }
                }
        }
    }

    private static func makePlayer() -> MusicPlayer {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let suite = "studio.luma.ui-tests"
            let defaults = UserDefaults(suiteName: suite)!
            if ProcessInfo.processInfo.arguments.contains("--reset-ui-state") { defaults.removePersistentDomain(forName: suite) }
            let documents = MusicPlayer.documents.appendingPathComponent("UITesting", isDirectory: true)
            if ProcessInfo.processInfo.arguments.contains("--reset-ui-state") { try? FileManager.default.removeItem(at: documents) }
            if ProcessInfo.processInfo.arguments.contains("--seed-test-library"), defaults.data(forKey: "luma.library.v2") == nil { seedTestLibrary(defaults: defaults, documents: documents) }
            if ProcessInfo.processInfo.arguments.contains("--color-artwork-fixture") { seedArtworkFixture(defaults: defaults, documents: documents) }
            if ProcessInfo.processInfo.arguments.contains("--readme-screenshots") { seedScreenshotLibrary(defaults: defaults, documents: documents) }
            return MusicPlayer(defaults: defaults, documentsURL: documents)
        }
        #endif
        return MusicPlayer()
    }

    private static let lyricsClient: any LyricsSearching = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") && arguments.contains("--mock-lyrics-api") { return FixtureLyricsClient() }
        #endif
        return LRCLIBClient()
    }()

    #if DEBUG
    private static func writeTestAudio(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050 * 48)!
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    /// Silent audio fixtures exist only after an explicit UI-test launch flag.
    private static func seedTestLibrary(defaults: UserDefaults, documents: URL) {
        do {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            let names = ["Golden Hour", "Weightless", "Afterglow"]
            let ids = ["golden", "blue", "rose"]
            let albums = ["Somewhere, nowhere", "A softer world", "The quiet between"]
            var tracks: [Track] = []
            for index in 0..<3 {
                let filename = "test-" + ids[index] + ".wav"
                try writeTestAudio(to: documents.appendingPathComponent(filename))
                tracks.append(Track(id: ids[index], title: names[index], artist: "Luma Sessions", album: albums[index], style: index,
                                    filename: filename, isImported: true, length: 48, genre: index == 1 ? "Jazz" : "Rock", year: index == 1 ? "2023" : "2024", trackNumber: index + 1, discNumber: 1, sampleRate: 22_050, bitDepth: 32, channels: 1))
            }
            defaults.set(try JSONEncoder().encode(LibraryState(importedTracks: tracks, currentID: tracks[0].id,
                         contextIDs: tracks.map(\.id), queue: tracks.dropFirst().map { QueueEntry(trackID: $0.id) })), forKey: "luma.library.v2")
        } catch { assertionFailure("Could not prepare test library: \(error)") }
    }

    /// Two locally generated color covers, only in the isolated UI-test library.
    private static func seedArtworkFixture(defaults: UserDefaults, documents: URL) {
        do {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            var tracks: [Track] = []
            for (index, name) in ["Amber", "Cobalt"].enumerated() {
                let audioName = "artwork-test-\(index).wav"
                let artworkName = "artwork-test-\(index).png"
                let audioURL = documents.appendingPathComponent(audioName)
                if !FileManager.default.fileExists(atPath: audioURL.path) { try writeTestAudio(to: audioURL) }
                let color = index == 0 ? Color(red: 1, green: 0.45, blue: 0.16) : Color(red: 0.18, green: 0.55, blue: 1)
                let renderer = ImageRenderer(content: AlbumArtwork(style: index, showType: false).colorMultiply(color).frame(width: 600, height: 600))
                try renderer.uiImage?.pngData()?.write(to: documents.appendingPathComponent(artworkName))
                tracks.append(Track(id: "artwork-test-\(index)", title: name, artist: "Artwork test", album: "Color study", style: index,
                                    filename: audioName, isImported: true, length: 48, artworkFilename: artworkName))
            }
            let state = LibraryState(importedTracks: tracks, currentID: tracks[0].id, contextIDs: tracks.map(\.id), queue: [QueueEntry(trackID: tracks[1].id)])
            defaults.set(try JSONEncoder().encode(state), forKey: "luma.library.v2")
        } catch { assertionFailure("Could not prepare artwork test fixture: \(error)") }
    }

    /// Fictional content for documentation captures. Never compiled into Release builds.
    private static func seedScreenshotLibrary(defaults: UserDefaults, documents: URL) {
        do {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            let titles = ["Silver Coast", "Blue Hour", "Late Signal", "Passing Lights", "Soft Focus", "Paper Sky", "Still Water", "First Light"]
            let artists = ["Mira Vale", "Mira Vale", "Northline", "Northline", "Iris Lane", "Iris Lane", "Mira Vale", "Northline"]
            let albums = ["Tidal Light", "Tidal Light", "Nocturne", "Nocturne", "Soft Focus", "Soft Focus", "Tidal Light", "Nocturne"]
            let colors: [Color] = [.init(red: 0.94, green: 0.51, blue: 0.25), .init(red: 0.25, green: 0.65, blue: 0.9), .init(red: 0.67, green: 0.42, blue: 0.85)]
            var tracks: [Track] = []
            for index in titles.indices {
                let id = "readme-\(index)"
                let filename = id + ".wav", cover = id + ".png"
                try writeTestAudio(to: documents.appendingPathComponent(filename))
                let group = artists[index] == "Mira Vale" ? 0 : (artists[index] == "Northline" ? 1 : 2)
                let renderer = ImageRenderer(content: AlbumArtwork(style: group, showType: false).colorMultiply(colors[group]).frame(width: 600, height: 600))
                guard let image = renderer.uiImage?.pngData() else { throw CocoaError(.fileWriteUnknown) }
                try image.write(to: documents.appendingPathComponent(cover))
                tracks.append(Track(id: id, title: titles[index], artist: artists[index], album: albums[index], style: group,
                                    filename: filename, isImported: true, length: 48, artworkFilename: cover, albumArtist: artists[index],
                                    genre: group == 0 ? "Ambient" : "Electronic", year: "2026", trackNumber: index + 1, discNumber: 1,
                                    sampleRate: 22_050, bitDepth: 32, channels: 1))
            }
            var history = ListeningAnalytics()
            for offset in 0..<7 {
                let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
                for index in 0..<(8 - offset % 4) {
                    let track = tracks[(index + offset) % tracks.count]
                    for _ in 0..<(1 + index % 3) {
                        history.begin(track)
                        history.record(seconds: 48, mediaSeconds: 48, duration: 48, at: day)
                        history.finish(at: day)
                    }
                }
            }
            history.begin(tracks[0])
            let state = LibraryState(analytics: history, importedTracks: tracks, favorites: [tracks[0].id, tracks[2].id, tracks[4].id],
                                     playlists: [Playlist(name: "Night Drive", description: "Ambient and electronic", trackIDs: [tracks[0].id, tracks[2].id, tracks[3].id, tracks[4].id]),
                                                 Playlist(name: "Slow Mornings", trackIDs: [tracks[1].id, tracks[5].id, tracks[6].id])],
                                     recentIDs: Array(tracks.prefix(5).map(\.id)), currentID: tracks[0].id, elapsed: 14,
                                     contextIDs: tracks.map(\.id), queue: tracks.dropFirst().map { QueueEntry(trackID: $0.id) })
            defaults.set(try JSONEncoder().encode(state), forKey: "luma.library.v2")
        } catch { assertionFailure("Could not prepare documentation screenshots: \(error)") }
    }
    #endif
}

#if DEBUG
/// Original sample text used only by explicitly opted-in UI tests; never sent online.
private struct FixtureLyricsClient: LyricsSearching {
    func search(_ query: LyricsQuery) async throws -> [LyricsMatch] {
        try await Task.sleep(for: .milliseconds(100))
        return [LyricsMatch(id: 42, trackName: query.title, artistName: query.artist, albumName: "Test version", duration: 48, instrumental: false,
                            plainLyrics: "Silver light upon the water\nQuiet streets beneath the moon",
                            syncedLyrics: "[00:00.00]Silver light upon the water\n[00:10.00]Quiet streets beneath the moon")]
    }
}
#endif

enum Theme {
    static let background = Color(white: 0.045)
    static let secondary = Color.white.opacity(0.53)
    static let accent = Color(white: 0.86)
}
