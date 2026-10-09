import Foundation
import Testing
@testable import Luma

@Suite(.serialized)
struct LyricsServiceTests {
    private let query = LyricsQuery(title: "Silver & Moon + Light?", artist: "Luma / Sessions", album: "", duration: 48)
    private let records = """
    [
      {"id":1,"trackName":"Silver","artistName":"Luma","albumName":"Live","duration":120,"instrumental":false,"plainLyrics":"A silver line","syncedLyrics":null},
      {"id":2,"trackName":"Silver","artistName":"Luma","albumName":"Studio","duration":48,"instrumental":false,"plainLyrics":"A silver line","syncedLyrics":"[00:00.00]A silver line\\n[00:10.00]Across the sky"},
      {"id":3,"trackName":"Silver","artistName":"Luma","albumName":"Instrumental","duration":48,"instrumental":true,"plainLyrics":null,"syncedLyrics":null}
    ]
    """

    private func client(status: Int = 200, body: String = "[]", headers: [String: String] = ["Content-Type": "application/json"], error: URLError? = nil) -> LRCLIBClient {
        LyricsURLProtocol.requestCount = 0
        LyricsURLProtocol.handler = { request in
            if let error { throw error }
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, Data(body.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LyricsURLProtocol.self]
        return LRCLIBClient(session: URLSession(configuration: configuration), contact: "https://example.com/luma-test")
    }

    @Test func requestEncodesMetadataAndIdentifiesClient() throws {
        let request = try LRCLIBClient.request(for: query, contact: "https://example.com/luma-test")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(components.host == "lrclib.net")
        #expect(components.path == "/api/search")
        #expect(items["track_name"] == query.title)
        #expect(items["artist_name"] == query.artist)
        #expect(items["album_name"] == nil)
        #expect(components.percentEncodedQuery?.contains("%2B") == true)
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Luma v1.0.1 (https://example.com/luma-test)")
    }

    @Test func resultsPreferMatchingDurationAndTimedLyrics() async throws {
        let matches = try await client(body: records).search(query)
        #expect(matches.map(\.id) == [2, 3, 1])
        #expect(matches[0].isSynchronized)
        #expect(matches[0].text?.contains("[00:10.00]") == true)
        #expect(matches[1].text == nil)
        #expect(matches[1].format == "Instrumental")
        #expect(matches[2].text == "A silver line")
    }

    @Test func emptySearchAndNotFoundAreNotErrors() async throws {
        #expect(try await client().search(query).isEmpty)
        #expect(try await client(status: 404).search(query).isEmpty)
    }

    @Test(arguments: [429, 503]) func honorsServerRetryAfterAcrossSearches(status: Int) async throws {
        let client = client(status: status, body: "Please wait", headers: ["Retry-After": "60", "Content-Type": "text/plain"])
        for _ in 0..<2 {
            do { _ = try await client.search(query); Issue.record("Expected cooldown") }
            catch LyricsSearchError.retryLater(let until) { #expect(until.timeIntervalSinceNow > 50) }
        }
        #expect(LyricsURLProtocol.requestCount == 1)
    }

    @Test func parsesBothRetryAfterFormats() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(LRCLIBClient.retryDate("30", fallback: 60, now: now) == now.addingTimeInterval(30))
        #expect(LRCLIBClient.retryDate("Thu, 01 Jan 1970 00:01:00 GMT", fallback: 5, now: now) == now.addingTimeInterval(60))
        #expect(LRCLIBClient.retryDate("invalid", fallback: 60, now: now) == now.addingTimeInterval(60))
    }

    @Test func malformedAndNonJSONResponsesHaveUsefulErrors() async throws {
        for (body, type) in [("bad JSON", "application/json"), ("[]", "text/html")] {
            do { _ = try await client(body: body, headers: ["Content-Type": type]).search(query); Issue.record("Expected invalid response") }
            catch LyricsSearchError.invalidResponse {}
        }
    }

    @Test func handlesOfflineTimeoutAndCancellation() async throws {
        do { _ = try await client(error: URLError(.notConnectedToInternet)).search(query); Issue.record("Expected offline error") }
        catch LyricsSearchError.offline {}
        do { _ = try await client(error: URLError(.timedOut)).search(query); Issue.record("Expected timeout") }
        catch LyricsSearchError.timeout {}
        do { _ = try await client(error: URLError(.cancelled)).search(query); Issue.record("Expected cancellation") }
        catch is CancellationError {}
    }

    @Test func emptyTitleAndMissingClientIdentityMakeNoRequest() async throws {
        let client = client()
        do { _ = try await client.search(LyricsQuery(title: "  ", artist: "", album: "", duration: nil)); Issue.record("Expected empty title") }
        catch LyricsSearchError.emptyTitle {}
        do { _ = try await LRCLIBClient(contact: "").search(query); Issue.record("Expected configuration error") }
        catch LyricsSearchError.configuration {}
        #expect(LyricsURLProtocol.requestCount == 0)
    }
}

private final class LyricsURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requestCount = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
