import Testing
@testable import Luma
import Foundation
import AVFoundation
import UIKit

@MainActor
@Suite(.serialized)
struct MusicPlayerTests {
    @Test func bulkDeletionPreservesUnselectedPlaybackAndCleansReferences() throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let player = fixture.player()
        let keep = try #require(player.track("golden"))
        let removed = player.tracks.filter { $0.id != keep.id }
        let playlist = try #require(player.createPlaylist(name: "Mixed", trackIDs: player.tracks.map(\.id)))
        for track in player.tracks { player.toggleFavorite(track); player.setLyrics("Saved lyrics", for: track) }
        player.select(keep)
        player.seek(to: 12)
        let result = player.removeImportedTracks(withIDs: Set(removed.map(\.id) + ["unknown"]))
        #expect(result == Set(removed.map(\.id)))
        #expect(player.current.id == keep.id && player.isPlaying && player.elapsed >= 12)
        #expect(player.tracks.map(\.id) == [keep.id])
        #expect(player.favorites == [keep.id] && player.lyrics.count == 1)
        #expect(player.tracks(in: playlist).map(\.id) == [keep.id])
        #expect(player.queue.isEmpty)
        for track in removed {
            #expect(!FileManager.default.fileExists(atPath: try #require(player.url(for: track)).path))
            #expect(FileManager.default.fileExists(atPath: TestAudio.url(for: track).path))
        }
        #expect(fixture.player().tracks.map(\.id) == [keep.id])
        player.pause()
    }

    @Test func bulkDeletionOfCurrentAndEntireLibraryRestoresEmptyState() throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let player = fixture.player()
        let current = try #require(player.tracks.first)
        player.select(current)
        player.setSleepTimer(endOfTrack: true)
        let playlist = try #require(player.createPlaylist(name: "All songs", trackIDs: player.tracks.map(\.id)))
        player.removeImportedTracks(withIDs: [current.id])
        #expect(!player.isPlaying && player.current.id != current.id && player.tracks.count == 2)
        player.play()
        // An already missing copy must not block removal of the remaining library.
        let last = try #require(player.tracks.last)
        try FileManager.default.removeItem(at: try #require(player.url(for: last)))
        player.removeImportedTracks(withIDs: Set(player.tracks.map(\.id)))
        #expect(player.tracks.isEmpty && player.current.id.isEmpty && !player.isPlaying)
        #expect(player.queue.isEmpty && player.recentIDs.isEmpty && player.analytics.session == nil)
        #expect(!player.sleepAtEndOfTrack && player.sleepDeadline == nil)
        #expect(player.tracks(in: playlist).isEmpty && player.playlists.count == 1)
        let restored = fixture.player()
        #expect(restored.tracks.isEmpty && restored.current.id.isEmpty && restored.error == nil)
        #expect(player.removeImportedTracks(withIDs: [current.id]).isEmpty)
    }

    @Test func emptyLibraryImportAndRemovingLastSongAreSafe() async throws {
        let fixture = Fixture(seed: false); defer { fixture.clean() }
        let player = fixture.player()
        #expect(player.tracks.isEmpty && player.current.id.isEmpty && player.error == nil)
        #expect(player.volume == 1 && player.playbackRate == 1)
        #expect(Bundle.main.url(forResource: "golden-hour", withExtension: "wav") == nil)
        player.play(); player.next(); player.previous(); player.seek(to: 12)
        #expect(!player.isPlaying && player.duration == 0 && player.queue.isEmpty)
        await player.importFiles([TestAudio.url(for: Track.demos[0])])
        let imported = try #require(player.tracks.first)
        #expect(player.current.id == imported.id && !player.isPlaying)
        player.play()
        #expect(player.isPlaying)
        player.removeImportedTrack(imported)
        #expect(player.tracks.isEmpty && player.current.id.isEmpty && !player.isPlaying)
        #expect(player.analytics.session == nil)
        let restored = fixture.player()
        #expect(restored.tracks.isEmpty && restored.error == nil && restored.current.id.isEmpty)
    }

    @Test func upgradeRemovesStarterReferencesAndPreservesUserLibrary() throws {
        let fixture = Fixture(seed: false); defer { fixture.clean() }
        var imported = Track.demos[0]; imported.id = "user-import"
        try FileManager.default.copyItem(at: TestAudio.url(for: imported), to: fixture.documents.appendingPathComponent(imported.filename))
        var history = ListeningAnalytics()
        history.begin(Track.demos[0]); history.record(seconds: 30, mediaSeconds: 30, duration: 48, at: Date())
        history.begin(imported); history.record(seconds: 30, mediaSeconds: 30, duration: 48, at: Date())
        let state = LibraryState(analytics: history, importedTracks: [imported], favorites: ["golden", imported.id],
                                 playlists: [Playlist(name: "My songs", trackIDs: ["golden", imported.id])],
                                 lyrics: ["golden": "old", imported.id: "mine"], recentIDs: ["golden", imported.id], currentID: "golden", elapsed: 20,
                                 contextIDs: ["golden", imported.id], queue: [QueueEntry(trackID: "golden")])
        fixture.defaults.set(try JSONEncoder().encode(state), forKey: "luma.library.v2")
        let player = fixture.player()
        #expect(player.tracks.map(\.id) == [imported.id])
        #expect(player.current.id == imported.id && player.elapsed == 0)
        #expect(player.favorites == [imported.id])
        #expect(player.playlists.first?.trackIDs == [imported.id])
        #expect(player.lyrics == [imported.id: "mine"])
        #expect(player.analytics.days.map(\.trackID) == [imported.id])
    }

    @Test func artworkExtractsDominantColorAndIgnoresTransparentPixels() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100))
        let image = renderer.image { context in
            UIColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 75, height: 100))
            UIColor.red.setFill()
            context.fill(CGRect(x: 75, y: 0, width: 25, height: 100))
        }
        let tint = ArtworkLoader.dominantTint(in: try #require(image.cgImage))
        #expect(tint.blue > 0.8 && tint.red < 0.2 && tint.green < 0.4)
        let transparent = renderer.image { _ in }
        #expect(ArtworkLoader.dominantTint(in: try #require(transparent.cgImage)) == .neutral)
    }

    @Test func artworkLoaderPreservesColorCachesAndHandlesMissingFiles() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1_600, height: 1_600)).image { context in
            UIColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_600, height: 1_600))
        }
        try #require(image.pngData()).write(to: url)
        let loader = ArtworkLoader()
        let loaded = await loader.load(url)
        let first = try #require(loaded)
        let second = await loader.load(url)
        #expect(first === second)
        #expect(first.image.size.width <= 1_024)
        let renderedTint = ArtworkLoader.dominantTint(in: try #require(first.image.cgImage))
        #expect(renderedTint.green > 0.7 && renderedTint.red < 0.2)
        #expect(first.tint == renderedTint)
        #expect(await loader.load(url.appendingPathExtension("missing")) == nil)
    }

    @Test func visualizerLevelsHandleSilenceAndInvalidReadings() {
        #expect(AudioVisualizer.displayLevel(decibels: -160) == 0)
        #expect(AudioVisualizer.displayLevel(decibels: -.infinity) == 0)
        #expect(AudioVisualizer.displayLevel(decibels: .nan) == 0)
        #expect(AudioVisualizer.displayLevel(decibels: 0) == 1)
        #expect(AudioVisualizer.displayLevel(decibels: 6) == 1)
        #expect(AudioVisualizer.displayLevel(decibels: -12) > AudioVisualizer.displayLevel(decibels: -36))
    }

    @Test func visualizerShowsSpectrumAndStopsWhenHidden() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        func makeAudio(name: String, amplitude: Float) throws -> AVAudioPlayer {
            let url = directory.appendingPathComponent(name + ".wav")
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132_300))
            buffer.frameLength = 132_300
            let channels = try #require(buffer.floatChannelData)
            for index in 0..<132_300 {
                channels[0][index] = 0
                // A tone followed by silence verifies both rising and falling bars.
                channels[1][index] = index < 22_050 ? amplitude * sin(2 * .pi * 440 * Float(index) / 44_100) : 0
            }
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            return try AVAudioPlayer(contentsOf: url)
        }
        let tone = try makeAudio(name: "tone", amplitude: 0.5)
        let silence = try makeAudio(name: "silence", amplitude: 0)
        let visualizer = AudioVisualizer()
        defer { visualizer.setActive(false); tone.stop(); silence.stop() }
        visualizer.attach(tone)
        visualizer.setActive(true)
        #expect(tone.play())
        try await Task.sleep(for: .milliseconds(250))
        #expect(visualizer.levels.count == AudioVisualizer.sampleCount)
        // A pure 440 Hz tone lights up a mid band, not the bass or treble ends.
        let loudestBand = try #require(visualizer.levels.indices.max { visualizer.levels[$0] < visualizer.levels[$1] })
        #expect(visualizer.levels[loudestBand] > 0.5)
        #expect((15...25).contains(loudestBand))
        #expect(visualizer.peaks[loudestBand] >= visualizer.levels[loudestBand])
        #expect(visualizer.levels.prefix(4).allSatisfy { $0 < 0.1 })
        #expect(visualizer.levels.suffix(6).allSatisfy { $0 < 0.1 })
        let loudest = visualizer.levels[loudestBand]
        try await Task.sleep(for: .milliseconds(1_250))
        #expect((visualizer.levels.max() ?? 0) < loudest * 0.5)
        // Muting drops the bars, matching the desktop app.
        tone.currentTime = 0
        tone.volume = 0
        try await Task.sleep(for: .milliseconds(400))
        #expect((visualizer.levels.max() ?? 0) < 0.05)
        tone.volume = 1
        visualizer.attach(silence)
        #expect(visualizer.levels.allSatisfy { $0 == 0 })
        tone.stop()
        #expect(silence.play())
        try await Task.sleep(for: .milliseconds(200))
        #expect(visualizer.levels.allSatisfy { $0 == 0 })
        visualizer.setActive(false)
        #expect(visualizer.peaks.allSatisfy { $0 == 0 })
        visualizer.attach(tone)
        tone.currentTime = 0
        #expect(tone.play())
        try await Task.sleep(for: .milliseconds(150))
        #expect(visualizer.levels.allSatisfy { $0 == 0 })
    }

    @MainActor final class Fixture {
        let name = "luma.tests." + UUID().uuidString
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var defaults: UserDefaults { UserDefaults(suiteName: name)! }
        init(seed: Bool = true) {
            try! FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            if seed {
                for track in Track.demos { try! FileManager.default.copyItem(at: TestAudio.url(for: track), to: documents.appendingPathComponent(track.filename)) }
                defaults.set(try! JSONEncoder().encode(Track.demos), forKey: "importedTracks")
            }
        }
        func player() -> Luma.MusicPlayer { Luma.MusicPlayer(defaults: defaults, documentsURL: documents, systemIntegration: false) }
        func clean() { LibraryRepository(documents: documents).flush(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: documents) }
    }

    @Test func importedAudioTransportAndRestore() throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let player = fixture.player()
        #expect(player.error == nil)
        player.select(Track.demos[0])
        #expect(player.isPlaying)
        #expect(player.duration == 48)
        player.seek(to: 12)
        player.previous()
        #expect(player.elapsed == 0)
        player.next()
        #expect(player.current.id == "blue")
        player.seek(to: 8)
        player.pause()
        let restored = fixture.player()
        #expect(restored.current.id == "blue")
        #expect(abs(restored.elapsed - 8) < 0.2)
        #expect(!restored.isPlaying)
        restored.seek(to: -10)
        #expect(restored.elapsed == 0)
        restored.seek(to: 999)
        #expect(restored.elapsed == restored.duration)
        restored.seek(to: .nan)
        #expect(restored.elapsed.isFinite)
    }

    @Test func playlistCRUDOrderAndPersistence() throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let player = fixture.player()
        #expect(player.createPlaylist(name: "  ") == nil)
        let playlist = try #require(player.createPlaylist(name: " Night Drive ", trackIDs: ["golden", "blue", "golden", "missing"]))
        #expect(playlist.name == "Night Drive")
        #expect(playlist.trackIDs == ["golden", "blue"])
        player.add([Track.demos[1], Track.demos[2]], to: playlist.id)
        player.moveInPlaylist(playlist.id, from: IndexSet(integer: 2), to: 0)
        player.updatePlaylist(playlist.id, name: "Moonlight", description: "After hours")
        let restored = fixture.player()
        let saved = try #require(restored.playlists.first)
        #expect(saved.name == "Moonlight")
        #expect(saved.description == "After hours")
        #expect(saved.trackIDs == ["rose", "golden", "blue"])
        restored.removeFromPlaylist(saved.id, at: IndexSet(integer: 1))
        #expect(restored.playlists[0].trackIDs == ["rose", "blue"])
        restored.deletePlaylist(saved.id)
        #expect(fixture.player().playlists.isEmpty)
    }

    @Test func queueEditingAndPreviousFollowActualPlayback() throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let player = fixture.player()
        player.select(Track.demos[0])
        player.enqueue(Track.demos[2], next: true)
        player.enqueue(Track.demos[0], next: false)
        #expect(player.queue.map(\.trackID) == ["rose", "blue", "rose", "golden"])
        #expect(Set(player.queue.map(\.id)).count == 4)
        player.next()
        #expect(player.current.id == "rose")
        player.previous()
        #expect(player.current.id == "golden")
        #expect(player.queue.first?.trackID == "rose")
        player.moveQueue(from: IndexSet(integer: 0), to: player.queue.count)
        player.removeQueue(at: IndexSet(integer: 1))
        let expected = player.queue
        #expect(fixture.player().queue == expected)
        player.clearQueue()
        player.repeatMode = .off
        player.next(automatic: true)
        #expect(!player.isPlaying)
    }

    @Test func repeatUsesPlaylistContextAndShuffleExhaustsCycle() throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let player = fixture.player()
        let collection = [Track.demos[0], Track.demos[2]]
        player.playCollection(collection, named: "Two tracks")
        player.repeatMode = .one
        player.next(automatic: true)
        #expect(player.current.id == "golden")
        player.repeatMode = .all
        player.next(automatic: true)
        #expect(player.current.id == "rose")
        player.next(automatic: true)
        #expect(player.current.id == "golden")
        #expect(!player.queue.contains { $0.trackID == "blue" })
        player.repeatMode = .off
        player.playCollection(Track.demos, named: "Shuffled", shuffled: true)
        var played: Set<String> = [player.current.id]
        for _ in 0..<2 { player.next(automatic: true); played.insert(player.current.id) }
        #expect(played.count == 3)
        #expect(player.queue.isEmpty)
        player.next(automatic: true)
        #expect(!player.isPlaying)
    }

    @Test func importDeleteAndPersistentFavoritesLyrics() async throws {
        let fixture = Fixture(seed: false); defer { fixture.clean() }
        let player = fixture.player()
        await player.importFiles([TestAudio.url(for: Track.demos[0])])
        let imported = try #require(player.tracks.last)
        #expect(imported.isImported)
        #expect(player.tracks.count == 1)
        let copied = try #require(player.url(for: imported))
        #expect(FileManager.default.fileExists(atPath: copied.path))
        player.toggleFavorite(imported)
        player.setLyrics("[00:01.00]A line of light", for: imported)
        let playlist = try #require(player.createPlaylist(name: "Imported", trackIDs: [imported.id]))
        player.enqueue(imported, next: true)
        let restored = fixture.player()
        #expect(restored.favorites.contains(imported.id))
        #expect(restored.lyrics[imported.id] == "[00:01.00]A line of light")
        restored.select(imported)
        #expect(restored.isPlaying)
        restored.removeImportedTrack(imported)
        #expect(!FileManager.default.fileExists(atPath: copied.path))
        #expect(restored.current.id != imported.id)
        #expect(!restored.favorites.contains(imported.id))
        #expect(restored.lyrics[imported.id] == nil)
        #expect(restored.playlists.first { $0.id == playlist.id }?.trackIDs == [])
        #expect(!restored.queue.contains { $0.trackID == imported.id })
        #expect(fixture.player().tracks.isEmpty)
    }

    @Test func invalidImportDoesNotEnterLibrary() async throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let file = fixture.documents.appendingPathComponent("invalid.mp3")
        let player = fixture.player()
        try Data("not audio".utf8).write(to: file)
        await player.importFiles([file])
        #expect(player.tracks.count == 3)
        #expect(player.error != nil)
        #expect(!player.importing)
    }

    @Test func lyricsParseMultipleTimestampsOffsetsAndPlainText() {
        let document = LyricsDocument("[ar:Artist]\n[offset:-500]\n[00:02.50][00:12.500]Hello\n[00:05]World")
        #expect(document.isSynchronized)
        #expect(document.lines.map(\.time) == [2, 4.5, 12])
        #expect(document.lines.map(\.text) == ["Hello", "World", "Hello"])
        #expect(document.activeLine(at: 1) == nil)
        #expect(document.activeLine(at: 5) == 1)
        #expect(document.activeLine(at: 12) == 2)
        let plain = LyricsDocument("First line\n\nSecond line")
        #expect(!plain.isSynchronized)
        #expect(plain.lines.count == 3)
    }

    @Test func sleepTimerAndEndOfTrackOverrideRepeat() {
        let fixture = Fixture(); defer { fixture.clean() }
        let player = fixture.player()
        player.select(Track.demos[0])
        player.setSleepTimer(minutes: 15)
        player.tick(now: Date().addingTimeInterval(901))
        #expect(!player.isPlaying)
        #expect(player.sleepDeadline == nil)
        player.play()
        player.repeatMode = .one
        player.setSleepTimer(endOfTrack: true)
        player.next(automatic: true)
        #expect(!player.isPlaying)
        #expect(!player.sleepAtEndOfTrack)
        player.playbackRate = 1.5
        player.volume = 0.4
        let restored = fixture.player()
        #expect(restored.playbackRate == 1.5)
        #expect(restored.volume == 0.4)
    }

    @Test func migratesLegacyFavoritesWithoutLosingTracks() throws {
        let fixture = Fixture(); defer { fixture.clean() }
        fixture.defaults.set(["golden", "missing"], forKey: "favorites")
        let player = fixture.player()
        #expect(player.favorites == ["golden"])
        #expect(player.tracks.count == 3)
        player.persist()
        #expect(try LibraryRepository(documents: fixture.documents).load().state != nil)
    }

    @Test func analyticsQualifiesOnceAndTracksRealTimeAtDifferentSpeeds() throws {
        var analytics = ListeningAnalytics()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        analytics.begin(Track.demos[0])
        analytics.record(seconds: 10, mediaSeconds: 20, duration: 48, at: date)
        #expect(analytics.days[0].plays == 0)
        analytics.record(seconds: 2, mediaSeconds: 4, duration: 48, at: date)
        #expect(analytics.days[0].plays == 1)
        analytics.record(seconds: 10, mediaSeconds: 20, duration: 48, at: date)
        #expect(analytics.days[0].plays == 1)
        #expect(analytics.days[0].seconds == 22)
        analytics.finish(at: date)
        analytics.finish(at: date)
        #expect(analytics.days[0].completions == 1)
        let restored = try JSONDecoder().decode(ListeningAnalytics.self, from: JSONEncoder().encode(analytics))
        #expect(restored.days == analytics.days)
        #expect(restored.session?.counted == true)
    }

    @Test func analyticsRanksTracksArtistsAlbumsAndIncludesUnplayed() {
        var analytics = ListeningAnalytics()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for _ in 0..<2 {
            analytics.begin(Track.demos[1])
            analytics.record(seconds: 24, mediaSeconds: 24, duration: 48, at: now, calendar: calendar)
        }
        analytics.begin(Track.demos[0])
        analytics.record(seconds: 24, mediaSeconds: 24, duration: 48, at: now.addingTimeInterval(-10 * 86400), calendar: calendar)
        let weekly = analytics.summary(period: .week, library: Track.demos, now: now, calendar: calendar)
        #expect(weekly.totalPlays == 2)
        #expect(weekly.listeningSeconds == 48)
        #expect(weekly.uniqueTracks == 1)
        #expect(weekly.mostPlayed.first?.trackID == "blue")
        #expect(weekly.leastPlayed.first?.plays == 0)
        #expect(weekly.artists.first?.title == "Luma Sessions")
        #expect(weekly.artists.first?.plays == 2)
        #expect(weekly.albums.first?.title == "A softer world")
        #expect(weekly.activity.count == 7)
        let all = analytics.summary(period: .all, library: Track.demos, now: now, calendar: calendar)
        #expect(all.totalPlays == 3)
        #expect(all.uniqueTracks == 2)
        #expect(all.activity.count == 30)
    }

    @Test func analyticsIgnoresSeeksAndPersistsAcrossPlayerInstances() {
        let fixture = Fixture(); defer { fixture.clean() }
        let player = fixture.player()
        player.select(Track.demos[0])
        for position in [25.0, 1.0, 35.0, 0.0] { player.seek(to: position) }
        player.pause()
        let summary = player.analytics.summary(period: .all, library: player.tracks)
        #expect(summary.totalPlays == 0)
        #expect(summary.listeningSeconds < 5)
        let restored = fixture.player()
        #expect(restored.analytics.days == player.analytics.days)
        restored.resetAnalytics()
        #expect(restored.analytics.days.isEmpty)
        #expect(fixture.player().analytics.days.isEmpty)
    }

    @Test func analyticsCountsNaturalCompletionWithoutDoubleCounting() async throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let player = fixture.player()
        let source = try AVAudioFile(forReading: TestAudio.url(for: Track.demos[0]))
        let frameCount = AVAudioFrameCount(source.processingFormat.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: frameCount))
        try source.read(into: buffer, frameCount: frameCount)
        let shortFile = fixture.documents.appendingPathComponent("one-second.wav")
        do {
            let output = try AVAudioFile(forWriting: shortFile, settings: source.fileFormat.settings)
            try output.write(from: buffer)
        }
        await player.importFiles([shortFile])
        let shortTrack = try #require(player.tracks.last)
        #expect(shortTrack.isImported)
        player.playCollection([shortTrack], named: "Short track")
        try await Task.sleep(for: .seconds(1.6))
        player.tick()
        let summary = player.analytics.summary(period: .all, library: player.tracks)
        #expect(!player.isPlaying)
        #expect(summary.totalPlays == 1)
        #expect(summary.completedPlays == 1)
        #expect(abs(summary.listeningSeconds - 1) < 0.1)
    }
}

private final class TestAudioBundle: NSObject {}
enum TestAudio {
    static func url(for track: Track) -> URL {
        Bundle(for: TestAudioBundle.self).url(forResource: (track.filename as NSString).deletingPathExtension, withExtension: "wav")!
    }
}
extension Track {
    static let demos = [
        Track(id: "golden", title: "Golden Hour", artist: "Luma Sessions", album: "Somewhere, nowhere", style: 0, filename: "golden-hour.wav", isImported: true, length: 48),
        Track(id: "blue", title: "Weightless", artist: "Luma Sessions", album: "A softer world", style: 1, filename: "weightless.wav", isImported: true, length: 48),
        Track(id: "rose", title: "Afterglow", artist: "Luma Sessions", album: "The quiet between", style: 2, filename: "afterglow.wav", isImported: true, length: 48)
    ]
}
