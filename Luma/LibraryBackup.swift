import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct LibraryBackup: Codable {
    let version: Int
    let createdAt: Date
    let library: LibraryState
    init(library: LibraryState) { version = 1; createdAt = Date(); self.library = library }
    static func read(_ data: Data) throws -> Self {
        guard data.count <= 50_000_000 else { throw LibraryRepository.StorageError("This backup is too large.") }
        let backup = try JSONDecoder().decode(Self.self, from: data)
        guard backup.version == 1,
              Set(backup.library.importedTracks.map(\.id)).count == backup.library.importedTracks.count,
              Set(backup.library.playlists.map(\.id)).count == backup.library.playlists.count else {
            throw LibraryRepository.StorageError("This is not a supported Luma backup.")
        }
        guard (backup.library.analytics?.days ?? []).allSatisfy({ $0.plays >= 0 && $0.plays <= 1_000_000_000 && $0.completions >= 0 && $0.completions <= 1_000_000_000 && $0.seconds.isFinite && $0.seconds >= 0 && $0.seconds <= 3_153_600_000 }) else {
            throw LibraryRepository.StorageError("This backup contains invalid listening history.")
        }
        return backup
    }
    /// A portable restore links existing files; it never trusts backup file paths or copies audio.
    func mapping(to tracks: [Track]) -> [String: String] {
        var result: [String: String] = [:]
        for old in library.importedTracks {
            let candidates: [Track]
            if let hash = old.contentHash {
                candidates = tracks.filter { $0.contentHash == hash }
            } else {
                candidates = tracks.filter { $0.id == old.id || ($0.title == old.title && $0.artist == old.artist && $0.album == old.album && abs(($0.length ?? 0) - (old.length ?? 0)) < 1) }
            }
            if candidates.count == 1 { result[old.id] = candidates[0].id }
        }
        return result
    }

    /// Reconnect intact local copies after database damage; never follow a path from a backup.
    func localCopies(in directory: URL, existing: [Track]) async -> [Track] {
        let candidates = library.importedTracks.filter { old in
            old.isImported && !existing.contains(where: { $0.id == old.id }) &&
            !old.filename.isEmpty && old.filename == URL(fileURLWithPath: old.filename).lastPathComponent
        }
        return await Task.detached(priority: .utility) {
            candidates.compactMap { old -> Track? in
                let url = directory.appendingPathComponent(old.filename)
                guard let hash = try? AudioFileIdentity.hash(url), old.contentHash == nil || hash == old.contentHash,
                      let decoder = try? AVAudioPlayer(contentsOf: url), decoder.duration > 0 else { return nil }
                var track = old; track.contentHash = hash
                if let image = track.artworkFilename, image != URL(fileURLWithPath: image).lastPathComponent { track.artworkFilename = nil }
                return track
            }
        }.value
    }
}

struct LibraryBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(_ backup: LibraryBackup) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        data = try encoder.encode(backup)
    }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data(); _ = try LibraryBackup.read(data) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct LibraryBackupView: View {
    @Environment(MusicPlayer.self) private var player
    @State private var exporting = false
    @State private var importing = false
    @State private var preparing = false
    @State private var document: LibraryBackupDocument?
    @State private var pending: LibraryBackup?
    @State private var recoveredTracks: [Track] = []
    @State private var confirm = false
    var body: some View {
        Section {
            if let issue = player.storageIssue {
                Text(issue).font(.footnote).foregroundStyle(.secondary)
                if player.canRetrySave { Button("Retry save") { player.persist() } }
            }
            Button(preparing ? "Preparing backup…" : "Export library backup") {
                preparing = true
                Task {
                    await player.indexExistingAudio()
                    do { document = try LibraryBackupDocument(LibraryBackup(library: player.libraryState)); exporting = true }
                    catch { player.error = error.localizedDescription }
                    preparing = false
                }
            }.disabled(preparing || player.importing)
            Button("Restore library backup") { importing = true }.disabled(preparing || player.importing)
        } header: { Text("Backup and recovery") } footer: {
            Text("Backups contain playlists, favorites, lyrics, and listening history. Audio files are not included. Import your music before restoring on another device.")
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Luma-backup") { result in
            if case .failure(let error) = result { player.error = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 50_000_000 else { throw LibraryRepository.StorageError("This backup is too large.") }
                let backup = try LibraryBackup.read(Data(contentsOf: url))
                preparing = true
                Task {
                    await player.indexExistingAudio()
                    recoveredTracks = await backup.localCopies(in: player.documentsURL, existing: player.tracks)
                    pending = backup; confirm = true; preparing = false
                }
            } catch { player.error = error.localizedDescription }
        }
        .alert("Restore this backup?", isPresented: $confirm) {
            Button("Restore", role: .destructive) {
                if let pending { player.restoreBackup(pending, recoveredTracks: recoveredTracks) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            if let pending {
                let matched = pending.mapping(to: player.tracks + recoveredTracks).count
                Text("Replace playlists, favorites, lyrics, and listening history. \(matched) of \(pending.library.importedTracks.count) songs match your library. Unmatched playlist songs are omitted; historical counts are retained. Audio files stay unchanged.")
            }
        }
    }
}
