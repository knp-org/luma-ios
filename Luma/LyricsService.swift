import Foundation

struct LyricsQuery: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval?
}

struct LyricsMatch: Decodable, Identifiable, Sendable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: Double
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?

    var isSynchronized: Bool { !instrumental && LyricsDocument(syncedLyrics ?? "").isSynchronized }
    var text: String? {
        guard !instrumental else { return nil }
        let candidate = isSynchronized ? syncedLyrics : plainLyrics ?? syncedLyrics
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
    var format: String { instrumental ? "Instrumental" : isSynchronized ? "Time-synced" : text == nil ? "No lyrics" : "Plain text" }
}

protocol LyricsSearching: Sendable {
    func search(_ query: LyricsQuery) async throws -> [LyricsMatch]
}

enum LyricsSearchError: LocalizedError {
    case configuration, emptyTitle, busy, retryLater(Date), offline, timeout, unavailable, invalidResponse

    var errorDescription: String? {
        switch self {
        case .configuration: "Online lyrics aren’t configured for this build. You can still paste lyrics or import a file."
        case .emptyTitle: "Enter a song title to search."
        case .busy: "Another lyrics search is finishing. Please try again shortly."
        case .retryLater(let date): "LRCLIB is busy. Try again in \(max(1, Int(ceil(date.timeIntervalSinceNow)))) seconds."
        case .offline: "You’re offline. Connect to the internet and try again. Your saved lyrics are still available."
        case .timeout: "The lyrics search timed out. Please try again."
        case .unavailable: "LRCLIB is temporarily unavailable. Please try again later."
        case .invalidResponse: "LRCLIB returned a response Luma couldn’t read. Please try again later."
        }
    }
}

/// The shared client serializes requests and retains server cooldowns across sheets.
actor LRCLIBClient: LyricsSearching {
    private let session: URLSession
    private let contact: String
    private var busy = false
    private var retryAfter = Date.distantPast
    private var nextRequest = Date.distantPast

    init(session: URLSession = .shared, contact: String = Bundle.main.object(forInfoDictionaryKey: "LumaLyricsContact") as? String ?? "") {
        self.session = session
        self.contact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func search(_ query: LyricsQuery) async throws -> [LyricsMatch] {
        guard !contact.isEmpty, !contact.contains(where: { $0.isNewline }) else { throw LyricsSearchError.configuration }
        let request = try Self.request(for: query, contact: contact)
        guard !busy else { throw LyricsSearchError.busy }
        guard Date() >= retryAfter else { throw LyricsSearchError.retryLater(retryAfter) }
        busy = true
        defer { busy = false; nextRequest = Date().addingTimeInterval(0.3) }
        do {
            let delay = nextRequest.timeIntervalSinceNow
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw LyricsSearchError.invalidResponse }
            if response.statusCode == 429 || response.statusCode == 503 {
                retryAfter = Self.retryDate(response.value(forHTTPHeaderField: "Retry-After"), fallback: response.statusCode == 429 ? 60 : 5)
                throw LyricsSearchError.retryLater(retryAfter)
            }
            if response.statusCode == 404 { return [] }
            guard (200..<300).contains(response.statusCode) else { throw LyricsSearchError.unavailable }
            guard response.mimeType == "application/json", data.count <= 2_000_000 else { throw LyricsSearchError.invalidResponse }
            guard let matches = try? JSONDecoder().decode([LyricsMatch].self, from: data) else { throw LyricsSearchError.invalidResponse }
            // Keep matching versions near the top; the user always chooses the result.
            return matches.sorted { lhs, rhs in
                if let duration = query.duration, duration.isFinite, duration > 0 {
                    let left = abs(lhs.duration - duration), right = abs(rhs.duration - duration)
                    if left != right { return left < right }
                }
                if lhs.isSynchronized != rhs.isSynchronized { return lhs.isSynchronized }
                return lhs.id < rhs.id
            }
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost: throw LyricsSearchError.offline
            case .timedOut: throw LyricsSearchError.timeout
            default: throw LyricsSearchError.unavailable
            }
        }
    }

    nonisolated static func request(for query: LyricsQuery, contact: String) throws -> URLRequest {
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LyricsSearchError.emptyTitle }
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "track_name", value: title)]
        for (name, value) in [("artist_name", query.artist), ("album_name", query.album)] {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { components.queryItems?.append(URLQueryItem(name: name, value: value)) }
        }
        // Form-style query decoding treats a literal '+' as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Luma v1.0.1 (\(contact))", forHTTPHeaderField: "User-Agent")
        return request
    }

    nonisolated static func retryDate(_ header: String?, fallback: TimeInterval, now: Date = Date()) -> Date {
        if let header, let seconds = Double(header), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let header, let date = formatter.date(from: header) { return max(now, date) }
        return now.addingTimeInterval(fallback)
    }
}
