import Foundation
import UIKit
import Testing
import AVFoundation
@testable import Luma

private final class FLACFixtureBundle: NSObject {}

@MainActor
struct FLACArtworkTests {
    private func taggedFLAC(_ comments: [String], at url: URL) throws {
        try flac(blocks: [], at: url)
        var data = try Data(contentsOf: url)
        func little(_ value: Int) -> Data { Data(integer(UInt32(value)).reversed()) }
        var payload = little(4) + Data("Luma".utf8) + little(comments.count)
        for comment in comments { payload += little(comment.utf8.count) + Data(comment.utf8) }
        var offset = 4
        while offset + 4 <= data.count {
            let type = data[offset]
            let length = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            if type & 0x7F == 4 {
                let block = Data([type]) + integer(UInt32(payload.count)).suffix(3) + payload
                data.replaceSubrange(offset..<(offset + 4 + length), with: block)
                try data.write(to: url); return
            }
            offset += 4 + length
        }
        Issue.record("Missing Vorbis comment fixture")
    }

    @Test func nativeTagsImportAndRepairExistingLibraryWithoutChangingAudioOrCounts() async throws {
        let fixture = MusicPlayerTests.Fixture(seed: false); defer { fixture.clean() }
        let input = fixture.documents.appendingPathComponent("tagged.FLAC")
        try taggedFLAC(["title=ನೀಲಿ ಹಾಡು", "ARTIST=First artist", "artist=Second artist", "ARTIST=First artist", "ALBUM=Test album", "ALBUMARTIST=Album artist", "GENRE=Rock", "genre=Alternative", "DATE=2024-05-21", "YEAR=1999", "TRACKNUMBER=02/14", "DISCNUMBER=2/3", "REPLAYGAIN_TRACK_GAIN=-6.1 dB", "REPLAYGAIN_ALBUM_GAIN=-4.2 dB", "REPLAYGAIN_TRACK_PEAK=0.91"], at: input)
        let original = try Data(contentsOf: input)
        let player = fixture.player()
        await player.importFiles([input])
        var track = try #require(player.tracks.first)
        #expect(track.title == "ನೀಲಿ ಹಾಡು" && track.artist == "First artist; Second artist")
        #expect(track.album == "Test album" && track.albumArtist == "Album artist")
        #expect(track.genre == "Rock; Alternative" && track.year == "2024")
        #expect(track.trackNumber == 2 && track.discNumber == 2)
        #expect(track.sampleRate == 96_000 && track.bitDepth == 24 && track.channels == 2)
        #expect(track.replayGainTrackDB == -6.1 && track.replayGainAlbumDB == -4.2 && track.replayGainTrackPeak == 0.91)
        let copied = try #require(player.url(for: track))
        #expect(try Data(contentsOf: copied) == original)

        track.title = "Old title"; track.artist = "Unknown artist"; track.album = "Imported audio"
        track.genre = nil; track.year = nil; track.albumArtist = nil; track.flacMetadataVersion = nil
        var analytics = ListeningAnalytics()
        analytics.begin(track); analytics.record(seconds: 0.2, mediaSeconds: 0.2, duration: 0.3, at: Date())
        let state = LibraryState(analytics: analytics, importedTracks: [track], favorites: [track.id],
                                 playlists: [Playlist(name: "Keep", trackIDs: [track.id])], lyrics: [track.id: "My lyrics"], currentID: track.id)
        try LibraryRepository(documents: fixture.documents).saveSynchronously(state)
        let restored = fixture.player()
        let sessionSeconds = restored.analytics.session?.mediaSeconds
        await restored.refreshFLACMetadata()
        #expect(restored.current.artist == "First artist; Second artist" && restored.current.year == "2024")
        #expect(restored.analytics.days.first?.artist == restored.current.artist)
        #expect(restored.analytics.days.first?.plays == 1 && restored.analytics.session?.mediaSeconds == sessionSeconds)
        #expect(restored.favorites == [track.id] && restored.lyrics[track.id] == "My lyrics")
        #expect(restored.playlists.first?.trackIDs == [track.id])
        #expect(restored.current.id == track.id && restored.current.filename == track.filename)
        #expect(try Data(contentsOf: copied) == original)
        #expect(fixture.player().current.genre == "Rock; Alternative")
        await restored.refreshFLACMetadata()
        #expect(restored.analytics.days.first?.plays == 1)
    }

    @Test func nativeTagsHandleAliasesMissingValuesAndMalformedLengths() throws {
        let fixture = MusicPlayerTests.Fixture(seed: false); defer { fixture.clean() }
        let input = fixture.documents.appendingPathComponent("tags.flac")
        try taggedFLAC(["ARTIST= ", "ALBUM ARTIST= Ensemble ", "TITLE=One=Two", "DATE=unknown", "YEAR=2001", "GENRE=", "ignored=value"], at: input)
        let metadata = try #require(FLACMetadata.read(at: input))
        let result = metadata.applying(to: Track.demos[0])
        #expect(result.artist == "Ensemble" && result.title == "One=Two" && result.year == "2001")
        #expect(result.genre == nil && result.album == Track.demos[0].album)
        try flac(blocks: [], at: input)
        let untagged = try #require(FLACMetadata.read(at: input)).applying(to: Track.demos[0])
        #expect(untagged.title == Track.demos[0].title && untagged.genre == nil)
        // Declared vendor size exceeds the available comment data.
        try (Data("fLaC".utf8) + Data([0x84, 0, 0, 4, 255, 255, 255, 255])).write(to: input)
        #expect(FLACMetadata.read(at: input) == nil)
        try (Data("fLaC".utf8) + Data([0x84, 255, 255, 255])).write(to: input)
        #expect(FLACMetadata.read(at: input) == nil)
    }

    private func png(_ color: UIColor) throws -> Data {
        try #require(UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }.pngData())
    }
    private func integer(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    private func picture(_ data: Data, type: UInt32 = 3, mime: String = "image/png") -> Data {
        integer(type) + integer(UInt32(mime.utf8.count)) + Data(mime.utf8) + integer(0)
        + integer(40) + integer(40) + integer(24) + integer(0) + integer(UInt32(data.count)) + data
    }
    private func flac(blocks: [Data], at url: URL) throws {
        let source = try #require(Bundle(for: FLACFixtureBundle.self).url(forResource: "silence", withExtension: "flac"))
        var data = try Data(contentsOf: source)
        var offset = 4
        while offset + 4 <= data.count {
            let last = data[offset] & 128 != 0
            let length = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            if last {
                if !blocks.isEmpty {
                    data[offset] &= 127
                    var metadata = Data()
                    for (index, block) in blocks.enumerated() {
                        metadata.append(index == blocks.count - 1 ? 0x86 : 0x06)
                        metadata.append(integer(UInt32(block.count)).suffix(3))
                        metadata.append(block)
                    }
                    data.insert(contentsOf: metadata, at: offset + 4 + length)
                }
                try data.write(to: url); return
            }
            offset += 4 + length
        }
        Issue.record("Invalid test fixture")
    }

    @Test func frontCoverImportsAndRecoversForExistingLibraryWithoutRecopyingAudio() async throws {
        let fixture = MusicPlayerTests.Fixture(seed: false); defer { fixture.clean() }
        let input = fixture.documents.appendingPathComponent("cover.FLAC")
        let front = try png(.green), back = try png(.red)
        try flac(blocks: [picture(back, type: 4), picture(front)], at: input)
        #expect(EmbeddedArtwork.flacPicture(at: input) == front)
        let player = fixture.player()
        await player.importFiles([input])
        var track = try #require(player.tracks.first)
        #expect(player.error == nil)
        #expect(track.artworkFilename != nil)
        #expect(player.current.id == track.id)
        let copiedURL = try #require(player.url(for: track))
        #expect(try Data(contentsOf: copiedURL) == Data(contentsOf: input))
        let decoder = try AVAudioFile(forReading: copiedURL)
        #expect(decoder.processingFormat.sampleRate == 96_000)
        #expect(decoder.processingFormat.channelCount == 2)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 1_024))
        try decoder.read(into: buffer)
        #expect(buffer.frameLength == 1_024)
        player.play()
        #expect(player.isPlaying && player.error == nil)
        player.pause()
        let source = try #require(player.artworkSource(for: track))
        let loaded = await ArtworkLoader().load(source)
        #expect(loaded?.tint.green ?? 0 > 0.9)

        // Earlier versions could save unusable metadata as an image sidecar.
        track.artworkFilename = "broken.artwork"
        try Data("not a JPEG".utf8).write(to: fixture.documents.appendingPathComponent("broken.artwork"))
        try LibraryRepository(documents: fixture.documents).saveSynchronously(LibraryState(importedTracks: [track], currentID: track.id))
        let restored = fixture.player()
        let recoveredSource = try #require(restored.artworkSource(for: restored.current))
        let recovered = await ArtworkLoader().load(recoveredSource)
        #expect(recovered?.tint.green ?? 0 > 0.9)
        #expect(restored.tracks.count == 1)
        #expect(restored.current.filename == track.filename)
        track.artworkFilename = nil
        let withoutSidecar = try #require(restored.artworkSource(for: track))
        #expect(await ArtworkLoader().load(withoutSidecar) != nil)
    }

    @Test func malformedMissingAndLinkedPicturesDoNotCrashOrFetchURLs() throws {
        let fixture = MusicPlayerTests.Fixture(seed: false); defer { fixture.clean() }
        let input = fixture.documents.appendingPathComponent("metadata.flac")
        try flac(blocks: [], at: input)
        #expect(EmbeddedArtwork.flacPicture(at: input) == nil)
        let valid = try png(.blue)
        try flac(blocks: [Data([0, 0, 0]), picture(Data("https://example.com/art.png".utf8), mime: "-->"), picture(valid)], at: input)
        #expect(EmbeddedArtwork.flacPicture(at: input) == valid)
        try (Data("fLaC".utf8) + Data([0x86, 0xFF, 0xFF, 0xFF])).write(to: input)
        #expect(EmbeddedArtwork.flacPicture(at: input) == nil)
        #expect(!EmbeddedArtwork.isImage(Data("invalid".utf8)))
    }
}
