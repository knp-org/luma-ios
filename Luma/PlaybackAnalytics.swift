import Foundation

struct ListeningDay: Codable, Identifiable, Equatable {
    var day: Date
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var plays = 0
    var completions = 0
    var seconds: Double = 0
    var albumArtist: String? = nil
    var id: String { "\(day.timeIntervalSince1970)|\(trackID)" }
}

struct ListeningSession: Codable {
    var track: Track
    var mediaSeconds: Double = 0
    var counted = false
    var finished = false
}

struct ListeningAnalytics: Codable {
    private(set) var days: [ListeningDay] = []
    private(set) var session: ListeningSession?

    mutating func begin(_ track: Track) { session = ListeningSession(track: track) }

    /// Only actual playback samples reach this method; seeks never add time.
    mutating func record(seconds: Double, mediaSeconds: Double, duration: Double, at date: Date, calendar: Calendar = .current) {
        guard seconds.isFinite, mediaSeconds.isFinite, duration.isFinite,
              seconds > 0, mediaSeconds > 0, duration > 0, var session, !session.finished else { return }
        let index = bucket(for: session.track, at: date, calendar: calendar)
        days[index].seconds += seconds
        session.mediaSeconds += mediaSeconds
        if !session.counted && session.mediaSeconds + 0.01 >= min(30, duration / 2) {
            days[index].plays += 1
            session.counted = true
        }
        self.session = session
    }

    mutating func finish(at date: Date, calendar: Calendar = .current) {
        guard var session, !session.finished else { return }
        if session.counted {
            let index = bucket(for: session.track, at: date, calendar: calendar)
            days[index].completions += 1
        }
        session.finished = true
        self.session = session
    }

    mutating func clearSession() { session = nil }
    mutating func restoreLinks(_ mapping: [String: String], tracks: [Track]) {
        session = nil
        var merged: [String: ListeningDay] = [:]
        for var day in days {
            day.trackID = mapping[day.trackID] ?? "backup-" + day.trackID
            if let track = tracks.first(where: { $0.id == day.trackID }) {
                day.title = track.title; day.artist = track.artist; day.album = track.album; day.albumArtist = track.albumArtist
            }
            if var previous = merged[day.id] {
                previous.plays += day.plays; previous.seconds += day.seconds; previous.completions += day.completions
                merged[day.id] = previous
            } else { merged[day.id] = day }
        }
        days = merged.values.sorted { $0.day < $1.day }
    }
    mutating func updateMetadata(for track: Track) {
        for index in days.indices where days[index].trackID == track.id {
            days[index].title = track.title; days[index].artist = track.artist; days[index].album = track.album; days[index].albumArtist = track.albumArtist
        }
        if session?.track.id == track.id { session?.track = track }
    }
    mutating func removeTracks(withIDs ids: Set<String>) {
        days.removeAll { ids.contains($0.trackID) }
        if let current = session, ids.contains(current.track.id) { session = nil }
    }

    mutating func reset() { days = []; session = nil }

    private mutating func bucket(for track: Track, at date: Date, calendar: Calendar) -> Int {
        let day = calendar.startOfDay(for: date)
        if let index = days.firstIndex(where: { $0.day == day && $0.trackID == track.id }) { return index }
        days.append(ListeningDay(day: day, trackID: track.id, title: track.title, artist: track.artist, album: track.album, albumArtist: track.albumArtist))
        return days.count - 1
    }

    func summary(period: AnalyticsPeriod, library: [Track], now: Date = Date(), calendar: Calendar = .current) -> AnalyticsSummary {
        let start = period.startDate(now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let filtered = days.filter { (start == nil || $0.day >= start!) && $0.day <= today }
        return AnalyticsSummary(records: filtered, library: library, period: period, now: now, calendar: calendar)
    }
}

enum AnalyticsPeriod: String, CaseIterable {
    case week = "7 days", month = "30 days", all = "All time"
    func startDate(now: Date, calendar: Calendar) -> Date? {
        guard self != .all else { return nil }
        return calendar.date(byAdding: .day, value: self == .week ? -6 : -29, to: calendar.startOfDay(for: now))
    }
}

struct RankedListening: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var trackID: String
    var plays: Int = 0
    var seconds: Double = 0
}

struct DailyActivity: Identifiable {
    var day: Date
    var plays: Int
    var seconds: Double
    var id: Date { day }
}

struct AnalyticsSummary {
    let totalPlays: Int
    let listeningSeconds: Double
    let completedPlays: Int
    let uniqueTracks: Int
    let activeDays: Int
    let mostPlayed: [RankedListening]
    let leastPlayed: [RankedListening]
    let artists: [RankedListening]
    let albums: [RankedListening]
    let activity: [DailyActivity]

    init(records: [ListeningDay], library: [Track], period: AnalyticsPeriod, now: Date, calendar: Calendar) {
        totalPlays = records.reduce(0) { $0 + $1.plays }
        listeningSeconds = records.reduce(0) { $0 + $1.seconds }
        completedPlays = records.reduce(0) { $0 + $1.completions }
        uniqueTracks = Set(records.filter { $0.plays > 0 }.map(\.trackID)).count
        activeDays = Set(records.filter { $0.seconds > 0 }.map(\.day)).count
        var trackTotals: [String: RankedListening] = [:]
        var artistTotals: [String: RankedListening] = [:]
        var albumTotals: [String: RankedListening] = [:]
        for record in records {
            var track = trackTotals[record.trackID] ?? RankedListening(id: record.trackID, title: record.title, subtitle: record.artist, trackID: record.trackID)
            track.plays += record.plays; track.seconds += record.seconds
            trackTotals[record.trackID] = track
            var artist = artistTotals[record.artist] ?? RankedListening(id: record.artist, title: record.artist, subtitle: "Artist", trackID: record.trackID)
            artist.plays += record.plays; artist.seconds += record.seconds
            artistTotals[record.artist] = artist
            let albumArtist = record.albumArtist ?? record.artist
            let albumKey = albumArtist + "\u{0}" + record.album
            var album = albumTotals[albumKey] ?? RankedListening(id: albumKey, title: record.album, subtitle: albumArtist, trackID: record.trackID)
            album.plays += record.plays; album.seconds += record.seconds
            albumTotals[albumKey] = album
        }
        let rank: (RankedListening, RankedListening) -> Bool = { lhs, rhs in
            if lhs.plays != rhs.plays { return lhs.plays > rhs.plays }
            if lhs.seconds != rhs.seconds { return lhs.seconds > rhs.seconds }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        mostPlayed = trackTotals.values.filter { $0.plays > 0 }.sorted(by: rank)
        artists = artistTotals.values.filter { $0.plays > 0 }.sorted(by: rank)
        albums = albumTotals.values.filter { $0.plays > 0 }.sorted(by: rank)
        leastPlayed = library.map { track in
            trackTotals[track.id] ?? RankedListening(id: track.id, title: track.title, subtitle: track.artist, trackID: track.id)
        }.sorted { lhs, rhs in
            if lhs.plays != rhs.plays { return lhs.plays < rhs.plays }
            if lhs.seconds != rhs.seconds { return lhs.seconds < rhs.seconds }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        let chartDays = period == .week ? 7 : 30
        activity = (0..<chartDays).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - chartDays + 1, to: calendar.startOfDay(for: now)) else { return nil }
            let dayRecords = records.filter { calendar.isDate($0.day, inSameDayAs: date) }
            return DailyActivity(day: date, plays: dayRecords.reduce(0) { $0 + $1.plays }, seconds: dayRecords.reduce(0) { $0 + $1.seconds })
        }
    }
}

func listeningTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0m" }
    if seconds < 60 { return "\(Int(seconds))s" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h \(minutes % 60)m"
}
