import Foundation
import SQLite3
import CryptoKit

/// All encoding and SQLite I/O share a serial worker, including reads during relaunch.
/// Transactions retain the previous valid snapshot; a separate recovery file covers DB damage.
final class LibraryRepository: @unchecked Sendable {
    private static let worker = DispatchQueue(label: "studio.luma.library-storage", qos: .utility)
    let directory: URL
    private let revisionLock = NSLock()
    private var revision = 0
    var databaseURL: URL { directory.appendingPathComponent("Library.sqlite") }
    private var recoveryURL: URL { directory.appendingPathComponent("Recovery.json") }
    fileprivate struct Snapshot: Codable {
        let payload: Data
        let checksum: String
        static let invalid = Snapshot(payload: Data(), checksum: "invalid")
        private init(payload: Data, checksum: String) { self.payload = payload; self.checksum = checksum }
        init(_ state: LibraryState) throws {
            payload = try JSONEncoder().encode(state)
            checksum = Self.digest(payload)
        }
        static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func decoded() throws -> LibraryState {
            guard checksum == Self.digest(payload) else { throw StorageError("The saved library checksum is invalid.") }
            return try JSONDecoder().decode(LibraryState.self, from: payload)
        }
    }
    struct StorageError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    init(documents: URL) { directory = documents.appendingPathComponent(".Luma", isDirectory: true) }

    func load() throws -> (state: LibraryState?, recovered: Bool) {
        try Self.worker.sync {
            do {
                return try connection { db in
                    for slot in ["current", "previous"] {
                        if let snapshot = try read(slot, db: db), let state = try? snapshot.decoded() {
                            if slot == "previous" { try write(snapshot, slot: "current", db: db) }
                            return (state, slot == "previous")
                        }
                    }
                    if try read("current", db: db) != nil { throw StorageError("The saved library could not be decoded.") }
                    return (nil, false)
                }
            } catch {
                // Never replace damaged data with an empty library. Preserve it for recovery.
                guard let data = try? Data(contentsOf: recoveryURL),
                      let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                      let state = try? snapshot.decoded() else { throw error }
                try archiveDamagedDatabase()
                try saveNow(state)
                return (state, true)
            }
        }
    }

    func save(_ state: LibraryState, completion: @escaping @Sendable (String?) -> Void) {
        let request = revisionLock.withLock { revision += 1; return revision }
        Self.worker.async {
            guard self.revisionLock.withLock({ self.revision == request }) else { return }
            do { try self.saveNow(state); completion(nil) }
            catch { completion(error.localizedDescription) }
        }
    }
    func saveSynchronously(_ state: LibraryState) throws { try Self.worker.sync { try saveNow(state) } }
    func flush() { Self.worker.sync {} }
    /// Explicit backup restoration can recover an unreadable database without deleting it.
    func restore(_ state: LibraryState) throws {
        try Self.worker.sync { try archiveDamagedDatabase(); try saveNow(state) }
    }

    private func saveNow(_ state: LibraryState) throws {
        let snapshot = try Snapshot(state)
        try connection { db in
            try execute("BEGIN IMMEDIATE", db: db)
            do {
                if let current = try read("current", db: db), (try? current.decoded()) != nil {
                    try write(current, slot: "previous", db: db)
                }
                try write(snapshot, slot: "current", db: db)
                try execute("COMMIT", db: db)
            } catch { try? execute("ROLLBACK", db: db); throw error }
        }
        try JSONEncoder().encode(snapshot).write(to: recoveryURL, options: .atomic)
    }

    private func connection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw StorageError("Luma couldn’t open its library database. Check available device storage.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3_000)
        try execute("PRAGMA synchronous=FULL", db: db)
        try execute("CREATE TABLE IF NOT EXISTS snapshots (slot TEXT PRIMARY KEY, payload BLOB NOT NULL)", db: db)
        return try body(db)
    }
    private func execute(_ sql: String, db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StorageError(String(cString: sqlite3_errmsg(db))) }
    }
    private func read(_ slot: String, db: OpaquePointer) throws -> Snapshot? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM snapshots WHERE slot = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StorageError(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, slot, -1, transient)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw StorageError("Couldn’t read the saved library.") }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        // An invalid envelope can still fall back to the previous slot.
        return (try? JSONDecoder().decode(Snapshot.self, from: data)) ?? Snapshot.invalid
    }
    private func write(_ snapshot: Snapshot, slot: String, db: OpaquePointer) throws {
        let data = try JSONEncoder().encode(snapshot)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO snapshots (slot, payload) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StorageError(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, slot, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StorageError(String(cString: sqlite3_errmsg(db))) }
    }
    private func archiveDamagedDatabase() throws {
        let name = "Library-preserved-\(UUID().uuidString).sqlite"
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.moveItem(at: source, to: directory.appendingPathComponent(name + suffix))
            }
        }
    }
}
