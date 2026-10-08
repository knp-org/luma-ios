import Foundation
import AVFoundation
import SQLite3
import Testing
@testable import Luma

@MainActor
@Suite(.serialized)
struct PlayerUpgradeTests {
    private func audio(at url: URL, duration: Double, value: Float = 0.1) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 44_100)))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: value, count: Int(buffer.frameLength)) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    @Test func renamedDuplicateIsSkippedAndProgressCountsEveryFile() async throws {
        let fixture = MusicPlayerTests.Fixture(seed: false); defer { fixture.clean() }
        let source = fixture.documents.appendingPathComponent("first.wav")
        let renamed = fixture.documents.appendingPathComponent("renamed.wav")
        try audio(at: source, duration: 0.6)
        try FileManager.default.copyItem(at: source, to: renamed)
        let player = fixture.player()
        await player.importFiles([source, renamed])
        #expect(player.tracks.count == 1)
        #expect(player.importTotal == 2 && player.importCompleted == 2 && !player.importing)
        #expect(player.notice?.contains("Skipped 1") == true)
        #expect(player.tracks.first?.contentHash == (try AudioFileIdentity.hash(source)))
        let restored = fixture.player()
        await restored.importFiles([renamed])
        #expect(restored.tracks.count == 1)
        #expect(try Data(contentsOf: source) == Data(contentsOf: renamed))
    }

    @Test func albumOrderCompilationsSearchAndReplayGain() throws {
        var one = Track.demos[0], two = Track.demos[1], three = Track.demos[2]
        one.album = "Compilation"; one.albumArtist = "Various artists"; one.discNumber = 1; one.trackNumber = 2
        two.album = one.album; two.albumArtist = one.albumArtist; two.artist = "Another artist"; two.discNumber = 1; two.trackNumber = 1
        three.album = one.album; three.albumArtist = one.albumArtist; three.discNumber = 2; three.trackNumber = 1
        #expect(one.albumKey == two.albumKey)
        #expect([three, one, two].sorted(by: Track.albumOrder).map(\.id) == [two.id, one.id, three.id])
        one.genre = "Rock; Alternative"; one.year = "2024"
        #expect(one.genres == ["Rock", "Alternative"] && one.matches("2024") && one.matches("alternative"))
        one.replayGainTrackDB = -6; one.replayGainTrackPeak = 0.9
        one.replayGainAlbumDB = -3
        #expect(abs(ReplayGainMode.track.multiplier(for: one) - 0.501187) < 0.001)
        #expect(abs(ReplayGainMode.album.multiplier(for: one) - 0.707946) < 0.001)
        #expect(ReplayGainMode.off.multiplier(for: one) == 1)
        two.replayGainTrackDB = 6
        #expect(ReplayGainMode.track.multiplier(for: two, headroomDB: 6) == 1)
        #expect(abs(ReplayGainMode.track.multiplier(for: one, headroomDB: 6) - 0.251189) < 0.001)
        one.replayGainTrackDB = .nan
        #expect(ReplayGainMode.track.multiplier(for: one) == 1)
    }

    @Test func databaseRecoversPreviousSnapshotAndDamagedFile() throws {
        let fixture = MusicPlayerTests.Fixture(seed: false); defer { fixture.clean() }
        let repository = LibraryRepository(documents: fixture.documents)
        var first = LibraryState(); first.playlists = [Playlist(name: "First")]
        var second = first; second.playlists = [Playlist(name: "Second")]
        try repository.saveSynchronously(first); try repository.saveSynchronously(second)
        var db: OpaquePointer?
        #expect(sqlite3_open(repository.databaseURL.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "UPDATE snapshots SET payload = X'00' WHERE slot = 'current'", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let previous = try repository.load()
        #expect(previous.recovered && previous.state?.playlists.first?.name == "First")
        // A damaged SQLite file uses the separate last-committed recovery snapshot.
        try Data("damaged database".utf8).write(to: repository.databaseURL)
        let recovered = try repository.load()
        #expect(recovered.recovered && recovered.state?.playlists.first?.name == "Second")
        #expect(try FileManager.default.contentsOfDirectory(atPath: repository.directory.path).contains { $0.hasPrefix("Library-preserved-") })
        let journal = URL(fileURLWithPath: repository.databaseURL.path + "-journal")
        try Data("preserve pending journal".utf8).write(to: journal)
        try repository.restore(first)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: repository.directory.path).contains { $0.hasPrefix("Library-preserved-") && $0.hasSuffix("-journal") })
        #expect(try repository.load().state?.playlists.first?.name == "First")
    }

    @Test func unreadableStorageIsPreservedAndSaveFailureIsReported() async throws {
        let fixture = MusicPlayerTests.Fixture(seed: false); defer { fixture.clean() }
        let repository = LibraryRepository(documents: fixture.documents)
        try FileManager.default.createDirectory(at: repository.directory, withIntermediateDirectories: true)
        let damaged = Data("no valid recovery".utf8)
        try damaged.write(to: repository.databaseURL)
        #expect(throws: (any Error).self) { try repository.load() }
        #expect(try Data(contentsOf: repository.databaseURL) == damaged)
        let player = fixture.player()
        #expect(player.storageIssue != nil)
        player.persist(); repository.flush()
        #expect(try Data(contentsOf: repository.databaseURL) == damaged)
        try FileManager.default.removeItem(at: repository.directory)
        try Data("blocked directory".utf8).write(to: repository.directory)
        let failure: String? = await withCheckedContinuation { continuation in
            repository.save(LibraryState()) { continuation.resume(returning: $0) }
        }
        #expect(failure != nil)
    }

    @Test func backupRestoresByFileIdentityWithoutCopyingAudio() async throws {
        let fixture = MusicPlayerTests.Fixture(seed: false); defer { fixture.clean() }
        let file = fixture.documents.appendingPathComponent("music.wav")
        try audio(at: file, duration: 1)
        let player = fixture.player()
        await player.importFiles([file])
        let track = try #require(player.tracks.first)
        var old = track; old.id = "old-installation"; old.filename = "untrusted/unused.flac"
        var analytics = ListeningAnalytics(); analytics.begin(old)
        analytics.record(seconds: 0.6, mediaSeconds: 0.6, duration: 1, at: Date())
        let state = LibraryState(analytics: analytics, importedTracks: [old], favorites: [old.id], playlists: [Playlist(name: "Restored", trackIDs: [old.id])], lyrics: [old.id: "Saved lyrics"])
        let backup = try LibraryBackup.read(JSONEncoder().encode(LibraryBackup(library: state)))
        player.restoreBackup(backup)
        #expect(player.tracks.count == 1 && player.tracks.first?.filename == track.filename)
        #expect(player.playlists.first?.trackIDs == [track.id] && player.favorites == [track.id])
        #expect(player.lyrics[track.id] == "Saved lyrics" && player.analytics.days.first?.plays == 1)
        #expect(player.analytics.days.first?.trackID == track.id)
        #expect(fixture.player().playlists.first?.name == "Restored")
        #expect(throws: (any Error).self) { try LibraryBackup.read(Data("{}".utf8)) }
    }

    @Test func successorStartsOnDeviceClockBeforeAnyHandoffCallback() async throws {
        let fixture = MusicPlayerTests.Fixture(seed: false); defer { fixture.clean() }
        let source = fixture.documents.appendingPathComponent("one.wav"), next = fixture.documents.appendingPathComponent("two.wav")
        try audio(at: source, duration: 0.6); try audio(at: next, duration: 1.5, value: 0.2)
        let current = try AVAudioPlayer(contentsOf: source)
        current.prepareToPlay(); #expect(current.play())
        let scheduler = GaplessScheduler()
        scheduler.schedule(Track.demos[1], url: next, after: current, volume: 1, rate: 1)
        let start = try #require(scheduler.scheduledTime)
        #expect(abs(start - current.deviceCurrentTime - (current.duration - current.currentTime)) < 0.02)
        try await Task.sleep(for: .milliseconds(850))
        let successor = try #require(scheduler.take(for: Track.demos[1].id))
        #expect(successor.isPlaying && successor.currentTime > 0.1 && successor.currentTime < 0.6)
        successor.stop(); current.stop()
        #expect(scheduler.trackID == nil)
    }

    @Test func backupReconnectsLocalCopiesAndRejectsOutsidePaths() async throws {
        let fixture = MusicPlayerTests.Fixture(seed: false); defer { fixture.clean() }
        let file = fixture.documents.appendingPathComponent("keep.wav")
        try audio(at: file, duration: 1)
        var track = Track.demos[0]; track.filename = "keep.wav"; track.contentHash = try AudioFileIdentity.hash(file)
        let backup = LibraryBackup(library: LibraryState(importedTracks: [track], favorites: [track.id]))
        let recovered = await backup.localCopies(in: fixture.documents, existing: [])
        #expect(recovered.count == 1)
        let player = fixture.player()
        player.restoreBackup(backup, recoveredTracks: recovered)
        #expect(player.current.id == track.id && player.favorites == [track.id])
        #expect(player.analytics.session?.track.id == track.id)
        track.filename = "../keep.wav"
        let unsafe = LibraryBackup(library: LibraryState(importedTracks: [track]))
        #expect(await unsafe.localCopies(in: fixture.documents, existing: []).isEmpty)
        track.filename = "keep.wav"; track.contentHash = "wrong"
        let mismatched = LibraryBackup(library: LibraryState(importedTracks: [track]))
        #expect(await mismatched.localCopies(in: fixture.documents, existing: []).isEmpty)
    }

    @Test func gaplessHandoffUpdatesQueueAnalyticsAndHonorsSleep() async throws {
        let fixture = MusicPlayerTests.Fixture(seed: false); defer { fixture.clean() }
        let one = fixture.documents.appendingPathComponent("one.wav"), two = fixture.documents.appendingPathComponent("two.wav")
        try audio(at: one, duration: 0.8); try audio(at: two, duration: 1.5, value: 0.2)
        let player = fixture.player()
        await player.importFiles([one, two])
        let tracks = player.tracks
        player.select(tracks[0]); try await Task.sleep(for: .milliseconds(1100))
        #expect(player.current.id == tracks[1].id && player.isPlaying)
        #expect(player.analytics.days.first { $0.trackID == tracks[0].id }?.completions == 1)
        player.pause(); player.select(tracks[0]); player.setSleepTimer(endOfTrack: true)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(!player.isPlaying && player.current.id == tracks[0].id)
    }
}
