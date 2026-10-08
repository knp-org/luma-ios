import AVFoundation
import MediaPlayer
import Observation
import SwiftUI

@MainActor @Observable
final class MusicPlayer: NSObject, AVAudioPlayerDelegate {
    let visualizer = AudioVisualizer()
    private(set) var tracks: [Track] = []
    private(set) var current = Track.empty
    private(set) var isPlaying = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var shuffle = false
    private(set) var favorites: Set<String> = []
    private(set) var playlists: [Playlist] = []
    private(set) var lyrics: [String: String] = [:]
    private(set) var recentIDs: [String] = []
    private(set) var queue: [QueueEntry] = []
    private(set) var contextName = "All music"
    private(set) var sleepDeadline: Date?
    private(set) var sleepAtEndOfTrack = false
    private(set) var analytics = ListeningAnalytics()
    var error: String?
    var notice: String?
    private(set) var importing = false
    var repeatMode: RepeatMode = .off { didSet { gaplessScheduler.cancel(); persist(); updateRemoteModes() } }
    var volume: Float = 1 { didSet { applyGain(); persist() } }
    var replayGain: ReplayGainMode = .off { didSet { applyGain(); persist() } }
    var gapless = true { didSet { gaplessScheduler.cancel(); persist() } }
    private(set) var importCompleted = 0
    private(set) var importTotal = 0
    private(set) var importFilename = ""
    private(set) var refreshingMetadata = false
    private(set) var outputSampleRate: Double = 0
    private(set) var outputName = "Not active"
    private(set) var bluetoothOutput = false
    var storageIssue: String?
    @ObservationIgnored private var storageLocked = false
    var canRetrySave: Bool { !storageLocked }
    @ObservationIgnored private var saveRevision = 0
    @ObservationIgnored private let gaplessScheduler = GaplessScheduler()
    @ObservationIgnored let repository: LibraryRepository
    var playbackRate: Float = 1 {
        willSet { accountPlayback() }
        didSet { gaplessScheduler.cancel(); audioEndDeviceTime = nil; audio?.rate = playbackRate; persist(); updateNowPlaying() }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let documentsURL: URL
    @ObservationIgnored private let useSystemIntegration: Bool
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var audio: AVAudioPlayer?
    @ObservationIgnored private var audioEndDeviceTime: TimeInterval?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var contextIDs: [String] = []
    @ObservationIgnored private var history: [String] = []
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var lastSaved: Date = .distantPast
    @ObservationIgnored private var lockScreenArtwork: MPMediaItemArtwork?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var accountingPosition: TimeInterval = 0
    @ObservationIgnored private var refreshingFLACMetadata = false

    nonisolated static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    var recentTracks: [Track] { recentIDs.compactMap(track) }
    var favoriteTracks: [Track] { tracks.filter { favorites.contains($0.id) } }
    var contextTracks: [Track] { contextIDs.compactMap(track) }

    init(defaults: UserDefaults = .standard, documentsURL: URL = MusicPlayer.documents, systemIntegration: Bool = true) {
        self.repository = LibraryRepository(documents: documentsURL)
        self.defaults = defaults
        self.documentsURL = documentsURL
        self.useSystemIntegration = systemIntegration
        super.init()
        try? FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        var saved: LibraryState?
        do {
            let loaded = try repository.load()
            saved = loaded.state
            if loaded.recovered { notice = "Your library was recovered from a valid snapshot." }
            if saved == nil, let data = defaults.data(forKey: "luma.library.v2") {
                saved = try JSONDecoder().decode(LibraryState.self, from: data)
                if let saved { try repository.saveSynchronously(saved) }
            }
        } catch {
            storageLocked = true
            storageIssue = "The library could not be loaded safely. Restore a backup in Settings. Existing files are preserved. " + error.localizedDescription
        }
        // Retain the existing installation's library when upgrading the renamed app.
        var legacy: [Track] = []
        if saved == nil, let data = defaults.data(forKey: "importedTracks") {
            do { legacy = try JSONDecoder().decode([Track].self, from: data) }
            catch { storageLocked = true; storageIssue = "The older library could not be decoded. Restore a backup in Settings; original data is preserved." }
        }
        tracks += (saved?.importedTracks ?? legacy).filter { FileManager.default.fileExists(atPath: documentsURL.appendingPathComponent($0.filename).path) }
        let validIDs = Set(tracks.map(\.id))
        favorites = (saved?.favorites ?? Set(defaults.stringArray(forKey: "favorites") ?? [])).intersection(validIDs)
        playlists = (saved?.playlists ?? []).map { var list = $0; list.trackIDs = list.trackIDs.filter(validIDs.contains); return list }
        lyrics = (saved?.lyrics ?? [:]).filter { validIDs.contains($0.key) }
        recentIDs = (saved?.recentIDs ?? []).filter(validIDs.contains)
        shuffle = saved?.shuffle ?? false
        repeatMode = saved?.repeatMode ?? .off
        volume = min(1, max(0, saved?.volume ?? 1))
        playbackRate = min(2, max(0.5, saved?.rate ?? 1))
        replayGain = saved?.replayGain ?? .off
        gapless = saved?.gapless ?? true
        contextIDs = saved?.contextIDs.filter(validIDs.contains) ?? tracks.map(\.id)
        if contextIDs.isEmpty { contextIDs = tracks.map(\.id) }
        contextName = saved?.contextName ?? "All music"
        prepare(track(saved?.currentID ?? "") ?? tracks.first ?? .empty)
        if let saved {
            queue = saved.queue.filter { validIDs.contains($0.trackID) }
            if saved.currentID == current.id { seek(to: saved.elapsed) }
        } else { rebuildQueue() }
        analytics = saved?.analytics ?? ListeningAnalytics()
        analytics.removeTracks(withIDs: Set(["golden", "blue", "rose"]).subtracting(validIDs))
        if current.id.isEmpty { analytics.clearSession() }
        else if analytics.session?.track.id != current.id { analytics.begin(current) }
        accountingPosition = elapsed
        ready = true
        persist()
        if systemIntegration { configureRemoteCommands(); observeAudioSession() }
        if systemIntegration { Task { [weak self] in await self?.refreshFLACMetadata() } }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    isolated deinit {
        artworkTask?.cancel()
        ticker?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for (command, target) in remoteTargets { command.removeTarget(target) }
    }

    func track(_ id: String) -> Track? { tracks.first { $0.id == id } }
    func url(for track: Track) -> URL? { track.isImported ? documentsURL.appendingPathComponent(track.filename) : track.url }
    func artworkURL(for track: Track) -> URL? { track.artworkFilename.map { documentsURL.appendingPathComponent($0) } }
    func artworkSource(for track: Track) -> ArtworkSource? {
        let flac = track.isImported && track.filename.lowercased().hasSuffix(".flac") ? url(for: track) : nil
        guard let sourceURL = artworkURL(for: track) ?? flac else { return nil }
        return ArtworkSource(url: sourceURL, fallbackFLAC: flac)
    }
    func tracks(in playlist: Playlist) -> [Track] { playlist.trackIDs.compactMap(track) }

    /// Repairs older imports off the main actor and keeps IDs, playback, and user data intact.
    func refreshFLACMetadata(force: Bool = false) async {
        guard !refreshingFLACMetadata else { return }
        refreshingFLACMetadata = true; refreshingMetadata = true
        defer { refreshingFLACMetadata = false; refreshingMetadata = false }
        let pending = tracks.filter { $0.isImported && $0.filename.lowercased().hasSuffix(".flac") && (force || ($0.flacMetadataVersion ?? 0) < FLACMetadata.version) }
        guard !pending.isEmpty else { return }
        let directory = documentsURL
        let updates = await Task.detached(priority: .utility) {
            pending.compactMap { track -> (String, String, FLACMetadata)? in
                guard let metadata = FLACMetadata.read(at: directory.appendingPathComponent(track.filename)) else { return nil }
                return (track.id, track.filename, metadata)
            }
        }.value
        for (id, filename, metadata) in updates {
            guard let index = tracks.firstIndex(where: { $0.id == id && $0.filename == filename }) else { continue }
            let updated = metadata.applying(to: tracks[index])
            tracks[index] = updated
            if current.id == id { current = updated }
            analytics.updateMetadata(for: updated)
        }
        if !updates.isEmpty { applyGain(); updateNowPlaying(); persist() }
        if force { notice = "Updated metadata for \(updates.count) FLAC files" }
    }

    private func prepare(_ track: Track, preloaded: AVAudioPlayer? = nil, startedAt: TimeInterval? = nil) {
        gaplessScheduler.cancel()
        audioEndDeviceTime = nil
        artworkTask?.cancel()
        accountPlayback()
        audio?.stop(); audio = nil; isPlaying = false; elapsed = 0; current = track
        visualizer.attach(nil)
        accountingPosition = 0
        duration = 0; lockScreenArtwork = nil
        guard !track.id.isEmpty else {
            analytics.clearSession(); cancelSleepTimer(); updateNowPlaying(); return
        }
        if ready { analytics.begin(track) }
        do {
            guard let url = url(for: track) else { throw CocoaError(.fileNoSuchFile) }
            let nextAudio = try preloaded ?? AVAudioPlayer(contentsOf: url)
            nextAudio.delegate = self
            nextAudio.volume = volume * replayGain.multiplier(for: track, headroomDB: replayGainHeadroom)
            nextAudio.enableRate = true
            nextAudio.rate = playbackRate
            if preloaded == nil { nextAudio.prepareToPlay() }
            audio = nextAudio
            if preloaded != nil { isPlaying = nextAudio.isPlaying; elapsed = nextAudio.currentTime }
            visualizer.attach(nextAudio)
            duration = nextAudio.duration
            if let startedAt { audioEndDeviceTime = startedAt + duration / Double(playbackRate) }
            if preloaded != nil {
                recentIDs.removeAll { $0 == track.id }; recentIDs.insert(track.id, at: 0)
                recentIDs = Array(recentIDs.prefix(50))
            }
            if let index = tracks.firstIndex(where: { $0.id == track.id }) { tracks[index].length = duration }
            if useSystemIntegration {
                let artwork = ImageRenderer(content: AlbumArtwork(style: track.style).frame(width: 400, height: 400)).uiImage
                lockScreenArtwork = artwork.map { image in MPMediaItemArtwork(boundsSize: image.size) { _ in image } }
                if let source = artworkSource(for: track) {
                    artworkTask = Task { [weak self] in
                        guard let asset = await ArtworkLoader.shared.load(source), !Task.isCancelled,
                              let self, self.current.id == track.id else { return }
                        self.lockScreenArtwork = MPMediaItemArtwork(boundsSize: asset.image.size) { _ in asset.image }
                        self.updateNowPlaying()
                    }
                }
            }
        } catch {
            duration = 0
            self.error = "This track couldn’t be opened. Try importing a supported audio file."
        }
        updateNowPlaying()
    }

    func select(_ track: Track, within collection: [Track]? = nil, named name: String = "All music") {
        let collection = collection ?? tracks
        contextIDs = collection.map(\.id)
        contextName = name
        if !contextIDs.contains(track.id) { contextIDs.insert(track.id, at: 0) }
        history = []
        if current.id != track.id || audio == nil { prepare(track) }
        rebuildQueue()
        play()
    }

    func playCollection(_ collection: [Track], named name: String, shuffled: Bool = false) {
        guard !collection.isEmpty else { return }
        shuffle = shuffled
        select(shuffled ? collection.randomElement()! : collection[0], within: collection, named: name)
        updateRemoteModes()
    }

    func play() {
        guard let audio else { return }
        if isPlaying, audio.isPlaying { persist(); return }
        if let sleepDeadline, sleepDeadline <= Date() { cancelSleepTimer() }
        do {
            if useSystemIntegration {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                // Prefer the source rate without preventing playback on routes that
                // require conversion. iOS and the connected hardware choose the actual rate.
                let sourceRate = audio.format.sampleRate
                if sourceRate.isFinite, sourceRate > 0 {
                    try? session.setPreferredSampleRate(sourceRate)
                }
                try session.setActive(true)
                updateOutputRoute()
            }
            if audio.currentTime >= audio.duration - 0.1 {
                audio.currentTime = 0; elapsed = 0; analytics.begin(current)
            } else if analytics.session?.finished == true { analytics.begin(current) }
            accountingPosition = audio.currentTime
            audio.rate = playbackRate
            let start = audio.deviceCurrentTime + 0.02
            isPlaying = audio.play(atTime: start)
            audioEndDeviceTime = isPlaying ? start + (audio.duration - audio.currentTime) / Double(playbackRate) : nil
            if isPlaying {
                recentIDs.removeAll { $0 == current.id }
                recentIDs.insert(current.id, at: 0)
                recentIDs = Array(recentIDs.prefix(50))
            }
            updateNowPlaying(); persist()
        } catch { self.error = "Audio playback couldn’t start. Please try again." }
    }

    func pause() { gaplessScheduler.cancel(); audioEndDeviceTime = nil; accountPlayback(); audio?.pause(); isPlaying = false; elapsed = audio?.currentTime ?? elapsed; updateNowPlaying(); persist() }
    func toggle() { isPlaying ? pause() : play() }
    func seek(to value: TimeInterval) {
        guard value.isFinite else { return }
        gaplessScheduler.cancel()
        audioEndDeviceTime = nil
        accountPlayback()
        elapsed = min(max(value, 0), duration)
        audio?.currentTime = elapsed
        visualizer.reset()
        accountingPosition = elapsed
        updateNowPlaying(); persist()
    }

    private func rebuildQueue(preservingManual: Bool = false) {
        let manual = preservingManual ? queue.filter(\.manuallyAdded) : []
        let remaining: [String]
        if shuffle { remaining = contextIDs.filter { $0 != current.id }.shuffled() }
        else if let index = contextIDs.firstIndex(of: current.id) { remaining = Array(contextIDs.dropFirst(index + 1)) }
        else { remaining = contextIDs }
        queue = manual + remaining.map { QueueEntry(trackID: $0) }
        persist()
    }

    func setShuffle(_ enabled: Bool) {
        shuffle = enabled
        rebuildQueue(preservingManual: true)
        updateRemoteModes()
    }

    func next(automatic: Bool = false) {
        if automatic && sleepAtEndOfTrack { pause(); cancelSleepTimer(); return }
        if automatic && repeatMode == .one {
            let start = gaplessScheduler.scheduledTime
            if let preloaded = gaplessScheduler.take(for: current.id) {
                prepare(current, preloaded: preloaded, startedAt: start); persist()
            } else { seek(to: 0); play() }
            return
        }
        if queue.isEmpty {
            if automatic && repeatMode == .off { pause(); return }
            let ids = shuffle ? contextIDs.shuffled() : contextIDs
            queue = ids.map { QueueEntry(trackID: $0) }
        }
        guard !queue.isEmpty else { pause(); return }
        let entry = queue.removeFirst()
        guard let track = track(entry.trackID) else { next(automatic: automatic); return }
        history.append(current.id)
        history = Array(history.suffix(100))
        let shouldPlay = isPlaying || automatic
        let start = automatic ? gaplessScheduler.scheduledTime : nil
        let preloaded = automatic ? gaplessScheduler.take(for: track.id) : nil
        prepare(track, preloaded: preloaded, startedAt: preloaded == nil ? nil : start)
        if shouldPlay && preloaded == nil { play() } else { persist() }
    }

    func previous() {
        if elapsed > 3 { seek(to: 0); return }
        let previousID: String?
        if let last = history.popLast() { previousID = last }
        else if let index = contextIDs.firstIndex(of: current.id), index > 0 { previousID = contextIDs[index - 1] }
        else { previousID = nil }
        guard let previousID, let track = track(previousID) else { seek(to: 0); return }
        queue.insert(QueueEntry(trackID: current.id), at: 0)
        let shouldPlay = isPlaying
        prepare(track)
        if shouldPlay { play() } else { persist() }
    }

    func playQueued(_ entry: QueueEntry) {
        guard let index = queue.firstIndex(where: { $0.id == entry.id }), let track = track(entry.trackID) else { return }
        history.append(current.id)
        queue.removeFirst(index + 1)
        prepare(track); play()
    }
    func enqueue(_ track: Track, next: Bool) {
        let entry = QueueEntry(trackID: track.id, manuallyAdded: true)
        if next { queue.insert(entry, at: 0) } else { queue.append(entry) }
        notice = next ? "Playing next: \(track.title)" : "Added to queue"
        persist()
    }
    func moveQueue(from offsets: IndexSet, to index: Int) { queue.move(fromOffsets: offsets, toOffset: index); persist() }
    func removeQueue(at offsets: IndexSet) { queue.remove(atOffsets: offsets); persist() }
    func clearQueue() { queue = []; persist() }
    func cycleRepeat() { repeatMode = switch repeatMode { case .off: .all; case .all: .one; case .one: .off } }

    func toggleFavorite(_ track: Track) {
        if favorites.contains(track.id) { favorites.remove(track.id) } else { favorites.insert(track.id) }
        persist(); updateRemoteModes()
    }
    func clearHistory() { recentIDs = []; persist() }

    @discardableResult
    func createPlaylist(name: String, description: String = "", trackIDs: [String] = []) -> Playlist? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var seen: Set<String> = []
        let playlist = Playlist(name: name, description: description, trackIDs: trackIDs.filter { track($0) != nil && seen.insert($0).inserted })
        playlists.append(playlist); persist()
        return playlist
    }
    func updatePlaylist(_ id: String, name: String, description: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = name; playlists[index].description = description; persist()
    }
    func add(_ tracks: [Track], to playlistID: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        for track in tracks where !playlists[index].trackIDs.contains(track.id) { playlists[index].trackIDs.append(track.id) }
        persist()
    }
    func removeFromPlaylist(_ id: String, at offsets: IndexSet) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].trackIDs.remove(atOffsets: offsets); persist()
    }
    func moveInPlaylist(_ id: String, from offsets: IndexSet, to destination: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].trackIDs.move(fromOffsets: offsets, toOffset: destination); persist()
    }
    func deletePlaylist(_ id: String) { playlists.removeAll { $0.id == id }; persist() }

    func setLyrics(_ text: String, for track: Track) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { lyrics.removeValue(forKey: track.id) } else { lyrics[track.id] = text }
        persist()
    }
    func importLyrics(_ url: URL, for track: Track) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 2_000_000, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            setLyrics(text, for: track)
        } catch { self.error = "Couldn’t read these lyrics. Choose a UTF-8 or UTF-16 text or LRC file." }
    }

    func setSleepTimer(minutes: Int? = nil, endOfTrack: Bool = false) {
        sleepDeadline = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        sleepAtEndOfTrack = endOfTrack
        gaplessScheduler.cancel(); scheduleGapless()
    }
    func cancelSleepTimer() { sleepDeadline = nil; sleepAtEndOfTrack = false; scheduleGapless() }
    func tick(now: Date = Date()) {
        if let sleepDeadline, now >= sleepDeadline { pause(); cancelSleepTimer(); notice = "Sleep timer finished" }
        guard isPlaying else { return }
        accountPlayback(at: now)
        elapsed = audio?.currentTime ?? elapsed
        if now.timeIntervalSince(lastSaved) > 5 { persist(); lastSaved = now }
    }

    private func accountPlayback(ending: Bool = false, at date: Date = Date()) {
        guard ready, isPlaying, let audio else { return }
        let position = ending ? duration : audio.currentTime
        let delta = position - accountingPosition
        guard delta > 0, delta.isFinite, playbackRate > 0 else { return }
        // AVAudioPlayer can reset its position before its finish callback is delivered.
        // Only explicit seeks/new tracks may move the accounting cursor backwards.
        accountingPosition = position
        analytics.record(seconds: delta / Double(playbackRate), mediaSeconds: delta, duration: duration, at: date)
    }

    func resetAnalytics() {
        analytics.reset(); if !current.id.isEmpty { analytics.begin(current) }
        accountingPosition = audio?.currentTime ?? elapsed
        persist()
    }

    func removeImportedTrack(_ track: Track) {
        removeImportedTracks(withIDs: [track.id])
    }

    /// Only successfully deleted (or already missing) copies leave the library.
    @discardableResult
    func removeImportedTracks(withIDs ids: Set<String>) -> Set<String> {
        let candidates = tracks.filter { $0.isImported && ids.contains($0.id) }
        var removed = Set<String>()
        var failed = 0
        for track in candidates {
            do {
                if let url = url(for: track), FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                removed.insert(track.id)
                if let artworkURL = artworkURL(for: track) { try? FileManager.default.removeItem(at: artworkURL) }
            } catch { failed += 1 }
        }
        if !removed.isEmpty {
            tracks.removeAll { removed.contains($0.id) }
            favorites.subtract(removed)
            lyrics = lyrics.filter { !removed.contains($0.key) }
            recentIDs.removeAll { removed.contains($0) }
            contextIDs.removeAll { removed.contains($0) }
            history.removeAll { removed.contains($0) }
            queue.removeAll { removed.contains($0.trackID) }
            for index in playlists.indices { playlists[index].trackIDs.removeAll { removed.contains($0) } }
            if removed.contains(current.id) {
                prepare(tracks.first ?? .empty)
                contextIDs = tracks.map(\.id); contextName = "All music"; rebuildQueue()
            }
            persist()
        }
        if failed > 0 { error = "Couldn’t delete \(failed) song(s). They remain in your library. Please try again." }
        return removed
    }

    func importFiles(_ urls: [URL]) async {
        guard !importing, !storageLocked else { return }
        importing = true
        importCompleted = 0; importTotal = urls.count; importFilename = "Checking existing files…"
        await indexExistingAudio()
        defer { importing = false }
        var failed = 0, added = 0, duplicates = 0
        for url in urls {
            importFilename = url.lastPathComponent
            defer { importCompleted += 1 }
            do {
                let destination = documentsURL
                let style = tracks.count % 3
                let hashes = Set(tracks.compactMap(\.contentHash))
                let outcome = try await Task.detached(priority: .userInitiated) { try await AudioImporter.importFile(url, to: destination, style: style, knownHashes: hashes) }.value
                guard let result = outcome else {
                    duplicates += 1; continue
                }
                added += 1
                tracks.append(result.track)
                if let text = result.lyrics, !text.isEmpty { lyrics[result.track.id] = text }
                if current.id.isEmpty {
                    prepare(result.track); contextIDs = tracks.map(\.id); contextName = "All music"; rebuildQueue()
                } else if contextName == "All music" { contextIDs.append(result.track.id); queue.append(QueueEntry(trackID: result.track.id)) }
                persist()
            } catch { failed += 1 }
        }
        if failed > 0 { error = "Couldn’t import \(failed) file(s). Choose unprotected FLAC, MP3, M4A, WAV, AIFF, or another supported audio format." }
        notice = "Added \(added) · Skipped \(duplicates) duplicate(s) · Failed \(failed)"
    }

    var libraryState: LibraryState {
        LibraryState(analytics: analytics, importedTracks: tracks.filter(\.isImported), favorites: favorites, playlists: playlists, lyrics: lyrics, recentIDs: recentIDs, currentID: current.id, elapsed: elapsed, contextIDs: contextIDs, contextName: contextName, queue: queue, shuffle: shuffle, repeatMode: repeatMode, rate: playbackRate, volume: volume, replayGain: replayGain, gapless: gapless)
    }
    func restoreBackup(_ backup: LibraryBackup, recoveredTracks: [Track] = []) {
        pause()
        let available = tracks + recoveredTracks.filter { recovered in !tracks.contains { $0.id == recovered.id } }
        let mapping = backup.mapping(to: available)
        var state = libraryState
        state.importedTracks = available
        state.playlists = backup.library.playlists.map { playlist in
            var result = playlist
            var seen = Set<String>()
            result.trackIDs = playlist.trackIDs.compactMap { mapping[$0] }.filter { seen.insert($0).inserted }
            return result
        }
        state.favorites = Set(backup.library.favorites.compactMap { mapping[$0] })
        state.lyrics = [:]
        for (id, text) in backup.library.lyrics { if let id = mapping[id] { state.lyrics[id] = text } }
        state.recentIDs = backup.library.recentIDs.compactMap { mapping[$0] }
        var restored = backup.library.analytics ?? ListeningAnalytics()
        restored.restoreLinks(mapping, tracks: available)
        if !current.id.isEmpty { restored.begin(current) }
        state.analytics = restored
        do {
            try repository.restore(state)
            tracks = available
            if current.id.isEmpty, let first = tracks.first { prepare(first); contextIDs = tracks.map(\.id); rebuildQueue() }
            playlists = state.playlists; favorites = state.favorites; lyrics = state.lyrics
            recentIDs = state.recentIDs; analytics = restored
            if analytics.session == nil, !current.id.isEmpty { analytics.begin(current) }
            storageLocked = false; storageIssue = nil
            notice = "Restored backup; matched \(mapping.count) songs"
            updateNowPlaying(); persist()
        } catch { self.error = "Couldn’t restore the backup. " + error.localizedDescription }
    }
    func persist() {
        guard ready else { return }
        applyGain()
        scheduleGapless()
        guard !storageLocked else { return }
        saveRevision += 1
        let revision = saveRevision
        repository.save(libraryState) { [weak self] message in
            Task { @MainActor in
                guard let self, self.saveRevision == revision else { return }
                self.storageIssue = message.map { "Couldn’t save the library. Free some storage and tap Retry save in Settings. " + $0 }
            }
        }
    }
    func saveForBackground() {
        let token = UIApplication.shared.beginBackgroundTask(withName: "Save Luma library")
        persist()
        let repository = repository
        Task {
            await Task.detached(priority: .utility) { repository.flush() }.value
            if token != .invalid { UIApplication.shared.endBackgroundTask(token) }
        }
    }
    var replayGainHeadroom: Double {
        guard replayGain != .off else { return 0 }
        return tracks.compactMap { replayGain == .album ? ($0.replayGainAlbumDB ?? $0.replayGainTrackDB) : $0.replayGainTrackDB }
            .filter(\.isFinite).reduce(0) { max($0, min(30, $1)) }
    }
    private func applyGain() { audio?.volume = volume * replayGain.multiplier(for: current, headroomDB: replayGainHeadroom) }
    private func scheduleGapless() {
        guard ready, gapless, isPlaying, !sleepAtEndOfTrack, let audio else { gaplessScheduler.cancel(); return }
        if queue.isEmpty, repeatMode == .all {
            queue = (shuffle ? contextIDs.shuffled() : contextIDs).map { QueueEntry(trackID: $0) }
        }
        let candidate = repeatMode == .one ? current : queue.first.flatMap { track($0.trackID) }
        guard let candidate, let url = url(for: candidate) else { gaplessScheduler.cancel(); return }
        gaplessScheduler.schedule(candidate, url: url, after: audio, volume: volume * replayGain.multiplier(for: candidate, headroomDB: replayGainHeadroom), rate: playbackRate, endTime: audioEndDeviceTime)
    }
    func updateOutputRoute() {
        guard useSystemIntegration else { return }
        let session = AVAudioSession.sharedInstance()
        outputSampleRate = session.sampleRate
        outputName = session.currentRoute.outputs.map(\.portName).joined(separator: ", ")
        bluetoothOutput = session.currentRoute.outputs.contains { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType) }
    }
    func indexExistingAudio() async {
        let pending = tracks.filter { $0.isImported && $0.contentHash == nil }
        let directory = documentsURL
        let hashes = await Task.detached(priority: .utility) {
            pending.compactMap { track -> (String, String)? in
                guard let hash = try? AudioFileIdentity.hash(directory.appendingPathComponent(track.filename)) else { return nil }
                return (track.id, hash)
            }
        }.value
        for (id, hash) in hashes {
            if let index = tracks.firstIndex(where: { $0.id == id }) { tracks[index].contentHash = hash }
        }
        if !hashes.isEmpty { persist() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.audio === player else { return }
            if flag {
                self.accountPlayback(ending: true)
                self.analytics.finish(at: Date())
                self.next(automatic: true)
            } else { self.pause(); self.error = "Playback stopped because this audio file could not be decoded." }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.pause(); self?.error = "This audio file could not be decoded." }
    }

    private func observeAudioSession() {
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue { self.resumeAfterInterruption = self.isPlaying; self.pause() }
                else if self.resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { self.resumeAfterInterruption = false; self.play() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self else { return }
                self.updateOutputRoute()
                self.gaplessScheduler.cancel()
                self.audioEndDeviceTime = nil
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self.pause() }
                else { self.scheduleGapless() }
            }
        })
    }

    private func updateNowPlaying() {
        guard useSystemIntegration else { return }
        guard !current.id.isEmpty else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist, MPMediaItemPropertyAlbumTitle: current.album, MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0, MPNowPlayingInfoPropertyDefaultPlaybackRate: playbackRate, MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue]
        if let lockScreenArtwork { info[MPMediaItemPropertyArtwork] = lockScreenArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        updateRemoteModes()
    }
    private func updateRemoteModes() {
        guard useSystemIntegration, ready else { return }
        let center = MPRemoteCommandCenter.shared()
        center.changeRepeatModeCommand.currentRepeatType = repeatMode == .off ? .off : (repeatMode == .one ? .one : .all)
        center.changeShuffleModeCommand.currentShuffleType = shuffle ? .items : .off
        center.likeCommand.isActive = favorites.contains(current.id)
    }
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        let actions: [(MPRemoteCommand, @MainActor () -> Void)] = [
            (center.playCommand, { [weak self] in self?.play() }),
            (center.pauseCommand, { [weak self] in self?.pause() }),
            (center.togglePlayPauseCommand, { [weak self] in self?.toggle() }),
            (center.nextTrackCommand, { [weak self] in self?.next() }),
            (center.previousTrackCommand, { [weak self] in self?.previous() }),
            (center.likeCommand, { [weak self] in if let self { self.toggleFavorite(self.current) } })
        ]
        for (command, action) in actions {
            command.isEnabled = true
            let target = command.addTarget { _ in Task { @MainActor in action() }; return .success }
            remoteTargets.append((command, target))
        }
        center.likeCommand.localizedTitle = "Favorite"
        let positionTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let value = event.positionTime
            Task { @MainActor in self?.seek(to: value) }; return .success
        }
        remoteTargets.append((center.changePlaybackPositionCommand, positionTarget))
        let repeatTarget = center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let value = event.repeatType
            Task { @MainActor in self?.repeatMode = value == .off ? .off : (value == .one ? .one : .all) }; return .success
        }
        remoteTargets.append((center.changeRepeatModeCommand, repeatTarget))
        let shuffleTarget = center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let value = event.shuffleType != .off
            Task { @MainActor in self?.setShuffle(value) }; return .success
        }
        remoteTargets.append((center.changeShuffleModeCommand, shuffleTarget))
        updateRemoteModes()
    }
}

private enum AudioImporter {
    struct Result: Sendable { var track: Track; var lyrics: String? }
    static func importFile(_ url: URL, to directory: URL, style: Int, knownHashes: Set<String>) async throws -> Result? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let contentHash = try AudioFileIdentity.hash(url)
        if knownHashes.contains(contentHash) { return nil }
        let id = UUID().uuidString
        let filename = id + "." + url.pathExtension
        let destination = directory.appendingPathComponent(filename)
        let artworkURL = directory.appendingPathComponent(id + ".artwork")
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            let copiedHash = try AudioFileIdentity.hash(destination)
            if knownHashes.contains(copiedHash) { try FileManager.default.removeItem(at: destination); return nil }
            let validator = try AVAudioPlayer(contentsOf: destination)
            guard validator.duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let asset = AVURLAsset(url: destination)
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            var track = Track(id: id, title: url.deletingPathExtension().lastPathComponent, artist: "Unknown artist", album: "Imported audio", style: style, filename: filename, isImported: true, length: validator.duration, addedAt: Date())
            if let data = EmbeddedArtwork.flacPicture(at: destination) {
                try data.write(to: artworkURL, options: .atomic)
                track.artworkFilename = artworkURL.lastPathComponent
            }
            for item in metadata {
                if item.commonKey == .commonKeyArtwork {
                    if track.artworkFilename == nil, let data = try? await item.load(.dataValue), EmbeddedArtwork.isImage(data) {
                        try data.write(to: artworkURL, options: .atomic)
                        track.artworkFilename = artworkURL.lastPathComponent
                    }
                    continue
                }
                guard let value = try? await item.load(.stringValue) else { continue }
                switch item.commonKey {
                case .commonKeyTitle: track.title = value
                case .commonKeyArtist: track.artist = value
                case .commonKeyAlbumName: track.album = value
                default: break
                }
            }
            track.contentHash = copiedHash
            track.sampleRate = validator.format.sampleRate
            track.channels = validator.numberOfChannels
            if let file = try? AVAudioFile(forReading: destination) {
                let bits = Int(file.fileFormat.streamDescription.pointee.mBitsPerChannel)
                if bits > 0 { track.bitDepth = bits }
            }
            if let native = FLACMetadata.read(at: destination) { track = native.applying(to: track) }
            return Result(track: track, lyrics: try? await asset.load(.lyrics))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: artworkURL)
            throw error
        }
    }
}
