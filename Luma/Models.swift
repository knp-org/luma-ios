import Foundation

struct Track: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var style: Int
    var filename: String
    var isImported = false
    var length: TimeInterval? = nil
    var addedAt: Date? = nil
    var artworkFilename: String? = nil
    var albumArtist: String? = nil
    var genre: String? = nil
    var year: String? = nil
    var flacMetadataVersion: Int? = nil
    var trackNumber: Int? = nil
    var discNumber: Int? = nil
    var contentHash: String? = nil
    var sampleRate: Double? = nil
    var bitDepth: Int? = nil
    var channels: Int? = nil
    var replayGainTrackDB: Double? = nil
    var replayGainAlbumDB: Double? = nil
    var replayGainTrackPeak: Double? = nil
    var replayGainAlbumPeak: Double? = nil

    var albumGroupingArtist: String { albumArtist?.isEmpty == false ? albumArtist! : artist }
    var albumKey: String { albumGroupingArtist + "\u{0}" + album }
    var genres: [String] { (genre ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    func matches(_ query: String) -> Bool {
        query.isEmpty || [title, artist, album, albumArtist ?? "", genre ?? "", year ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(query)
    }
    static func albumOrder(_ lhs: Track, _ rhs: Track) -> Bool {
        if (lhs.discNumber ?? 1) != (rhs.discNumber ?? 1) { return (lhs.discNumber ?? 1) < (rhs.discNumber ?? 1) }
        if (lhs.trackNumber ?? Int.max) != (rhs.trackNumber ?? Int.max) { return (lhs.trackNumber ?? Int.max) < (rhs.trackNumber ?? Int.max) }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    var url: URL? {
        isImported ? MusicPlayer.documents.appendingPathComponent(filename) : Bundle.main.url(forResource: filename, withExtension: "wav")
    }
    static let empty = Track(id: "", title: "No song selected", artist: "", album: "", style: 0, filename: "")
}

struct Playlist: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    var description = ""
    var trackIDs: [String] = []
    var createdAt = Date()
}

struct QueueEntry: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var trackID: String
    var manuallyAdded = false
}

enum RepeatMode: String, Codable, CaseIterable {
    case off, all, one
    var symbol: String { self == .one ? "repeat.1" : "repeat" }
    var label: String {
        switch self { case .off: "Repeat off"; case .all: "Repeat all"; case .one: "Repeat one" }
    }
}

enum TrackSort: String, CaseIterable {
    case title = "Title", artist = "Artist", album = "Album", added = "Recently added"
    func apply(to tracks: [Track]) -> [Track] {
        tracks.sorted { a, b in
            switch self {
            case .title: a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .artist: (a.artist + a.title).localizedStandardCompare(b.artist + b.title) == .orderedAscending
            case .album: a.albumKey == b.albumKey ? Track.albumOrder(a, b) : a.albumKey.localizedStandardCompare(b.albumKey) == .orderedAscending
            case .added: (a.addedAt ?? .distantPast) > (b.addedAt ?? .distantPast)
            }
        }
    }
}

struct LibraryState: Codable {
    var analytics: ListeningAnalytics? = nil
    var importedTracks: [Track] = []
    var favorites: Set<String> = []
    var playlists: [Playlist] = []
    var lyrics: [String: String] = [:]
    var recentIDs: [String] = []
    var currentID = ""
    var elapsed: Double = 0
    var contextIDs: [String] = []
    var contextName = "All music"
    var queue: [QueueEntry] = []
    var shuffle = false
    var repeatMode: RepeatMode = .off
    var rate: Float = 1
    var volume: Float = 1
    var replayGain: ReplayGainMode? = nil
    var gapless: Bool? = nil
}

enum ReplayGainMode: String, Codable, CaseIterable {
    case off = "Off", track = "Track", album = "Album"
    func multiplier(for song: Track, headroomDB: Double = 0) -> Float {
        guard self != .off else { return 1 }
        let db = self == .album ? (song.replayGainAlbumDB ?? song.replayGainTrackDB) : song.replayGainTrackDB
        let peak = self == .album ? (song.replayGainAlbumPeak ?? song.replayGainTrackPeak) : song.replayGainTrackPeak
        guard let db, db.isFinite else { return 1 }
        var gain = pow(10, min(30, max(-60, db - headroomDB)) / 20)
        if let peak, peak.isFinite, peak > 0 { gain = min(gain, 1 / peak) }
        // Shared headroom makes positive and negative tags relative without digital clipping.
        return Float(min(1, max(0, gain)))
    }
}

struct LyricLine: Identifiable, Equatable {
    var id: Int
    var time: TimeInterval?
    var text: String
}

struct LyricsDocument {
    let lines: [LyricLine]
    var isSynchronized: Bool { lines.contains { $0.time != nil } }

    init(_ text: String) {
        let timestamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#)
        let offsetPattern = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)
        let nsText = text as NSString
        let offsetMatch = offsetPattern.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length))
        let offset = offsetMatch.flatMap { Double(nsText.substring(with: $0.range(at: 1))) }.map { $0 / 1000 } ?? 0
        var timed: [(Double, String)] = []
        var plain: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let ns = line as NSString
            let matches = timestamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty {
                if !line.hasPrefix("[") { plain.append(line) }
                continue
            }
            let content = timestamp.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length), withTemplate: "").trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                guard seconds < 60 else { continue }
                let fraction = match.range(at: 3).location == NSNotFound ? 0 : Double("0." + ns.substring(with: match.range(at: 3))) ?? 0
                timed.append((max(0, minutes * 60 + seconds + fraction + offset), content))
            }
        }
        if timed.isEmpty {
            lines = plain.enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
        } else {
            lines = timed.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
        }
    }

    func activeLine(at time: TimeInterval) -> Int? { lines.last(where: { ($0.time ?? .infinity) <= time })?.id }
}

func formattedTime(_ interval: TimeInterval) -> String {
    guard interval.isFinite else { return "0:00" }
    let seconds = max(0, Int(interval))
    return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
}
