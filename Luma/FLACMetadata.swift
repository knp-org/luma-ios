import Foundation

/// Native Vorbis comments. Only bounded metadata blocks are read; audio is never rewritten.
struct FLACMetadata: Sendable {
    static let version = 2
    private var fields: [String: [String]] = [:]
    private var sampleRate: Double?
    private var bitDepth: Int?
    private var channels: Int?

    private func value(_ keys: String...) -> String? {
        for key in keys {
            if let values = fields[key], !values.isEmpty { return values.joined(separator: "; ") }
        }
        return nil
    }

    func applying(to track: Track) -> Track {
        var result = track
        result.title = value("TITLE") ?? track.title
        result.albumArtist = value("ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST") ?? track.albumArtist
        result.artist = value("ARTIST", "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST", "PERFORMER") ?? track.artist
        result.album = value("ALBUM") ?? track.album
        result.genre = value("GENRE") ?? track.genre
        func number(_ keys: String...) -> Int? {
            for key in keys {
                if let raw = fields[key]?.first?.split(separator: "/").first,
                   let number = Int(raw.trimmingCharacters(in: .whitespaces)), number > 0 { return number }
            }
            return nil
        }
        func decimal(_ key: String) -> Double? {
            guard let raw = fields[key]?.first?.split(whereSeparator: { $0.isWhitespace }).first,
                  let value = Double(raw), value.isFinite else { return nil }
            return value
        }
        result.trackNumber = number("TRACKNUMBER", "TRACK") ?? track.trackNumber
        result.discNumber = number("DISCNUMBER", "DISC") ?? track.discNumber
        result.sampleRate = sampleRate ?? track.sampleRate
        result.bitDepth = bitDepth ?? track.bitDepth
        result.channels = channels ?? track.channels
        result.replayGainTrackDB = decimal("REPLAYGAIN_TRACK_GAIN")
        result.replayGainAlbumDB = decimal("REPLAYGAIN_ALBUM_GAIN")
        result.replayGainTrackPeak = decimal("REPLAYGAIN_TRACK_PEAK")
        result.replayGainAlbumPeak = decimal("REPLAYGAIN_ALBUM_PEAK")
        for key in ["DATE", "YEAR", "ORIGINALDATE", "ORIGINALYEAR"] {
            if let date = fields[key]?.first, date.count >= 4 {
                let prefix = String(date.prefix(4))
                if prefix.utf8.allSatisfy({ (48...57).contains($0) }), let year = Int(prefix), year > 0 {
                    result.year = prefix; break
                }
            }
        }
        result.flacMetadataVersion = Self.version
        return result
    }

    static func read(at url: URL) -> FLACMetadata? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        do {
            let size = try file.seekToEnd()
            try file.seek(toOffset: 0)
            guard try file.read(upToCount: 4) == Data("fLaC".utf8) else { return nil }
            var metadata = FLACMetadata()
            for _ in 0..<1_024 {
                let offset = try file.offset()
                guard offset + 4 <= size, offset < 64_000_000,
                      let header = try file.read(upToCount: 4), header.count == 4 else { return nil }
                let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
                let end = offset + 4 + UInt64(length)
                guard end <= size, end <= 64_000_000 else { return nil }
                if header[0] & 0x7F == 0, length == 34 {
                    guard let data = try file.read(upToCount: length), data.count == length else { return nil }
                    let packed = data[10..<18].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    let rate = Int(packed >> 44)
                    if rate > 0 { metadata.sampleRate = Double(rate) }
                    metadata.channels = Int((packed >> 41) & 7) + 1
                    metadata.bitDepth = Int((packed >> 36) & 31) + 1
                } else if header[0] & 0x7F == 4 {
                    guard length <= 4_000_000, let data = try file.read(upToCount: length), data.count == length,
                          let comments = comments(in: data) else { return nil }
                    for (key, values) in comments {
                        for value in values where !(metadata.fields[key] ?? []).contains(value) {
                            metadata.fields[key, default: []].append(value)
                        }
                    }
                } else { try file.seek(toOffset: end) }
                if header[0] & 0x80 != 0 { return metadata }
            }
            return nil
        } catch { return nil }
    }

    private static func comments(in data: Data) -> [String: [String]]? {
        var reader = Reader(data: data)
        guard let vendorSize = reader.integer(), reader.bytes(vendorSize) != nil,
              let count = reader.integer(), count <= 10_000 else { return nil }
        let supported: Set<String> = ["TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST", "PERFORMER", "GENRE", "DATE", "YEAR", "ORIGINALDATE", "ORIGINALYEAR", "TRACKNUMBER", "TRACK", "DISCNUMBER", "DISC", "REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_ALBUM_GAIN", "REPLAYGAIN_TRACK_PEAK", "REPLAYGAIN_ALBUM_PEAK"]
        var fields: [String: [String]] = [:]
        for _ in 0..<count {
            guard let length = reader.integer(), let bytes = reader.bytes(length) else { return nil }
            guard let comment = String(data: bytes, encoding: .utf8), let separator = comment.firstIndex(of: "=") else { continue }
            let key = comment[..<separator].uppercased()
            guard supported.contains(key) else { continue }
            let value = comment[comment.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.contains("\0"), value.utf8.count <= 16_384 else { continue }
            if !(fields[key] ?? []).contains(value) { fields[key, default: []].append(value) }
        }
        return fields
    }

    private struct Reader {
        let data: Data
        var offset = 0
        mutating func bytes(_ count: Int) -> Data? {
            guard count >= 0, count <= data.count - offset else { return nil }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        mutating func integer() -> Int? {
            bytes(4).map { bytes in Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24 }
        }
    }
}
