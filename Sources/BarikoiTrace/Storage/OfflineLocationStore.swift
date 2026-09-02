import Foundation
import SQLite3

/// Durable offline location queue — mirrors `OfflineLocationDb`/`OfflineLocationDao`/
/// `OfflineLocationEntity` (Room) from the Kotlin SDK: one table, raw JSON blob
/// rows, batch-of-100 read/delete. Raw SQLite3 rather than GRDB to keep the
/// package's only external dependency the MQTT client — swap freely if the
/// team prefers a higher-level wrapper.
///
/// Durability is the whole point: an in-memory-only buffer loses every
/// queued fix on process death, which on iOS is routine rather than
/// exceptional. Every row here survives app termination.
public final class OfflineLocationStore {
    public static let shared = OfflineLocationStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.barikoi.trace.offlinequeue")

    /// `path` is exposed for testing (e.g. `":memory:"`); production callers
    /// should use `.shared`, which persists to the app's Application Support
    /// directory.
    public init(path: String? = nil) {
        openDatabase(customPath: path)
        createTableIfNeeded()
    }

    private func openDatabase(customPath: String?) {
        let path: String
        if let customPath {
            path = customPath
        } else {
            let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            let dir = urls.first ?? FileManager.default.temporaryDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            path = dir.appendingPathComponent("barikoi_trace_offline.sqlite").path
        }
        if sqlite3_open(path, &db) != SQLITE_OK {
            db = nil
        }
    }

    private func createTableIfNeeded() {
        guard let db else { return }
        sqlite3_exec(
            db,
            "CREATE TABLE IF NOT EXISTS offline_location (id INTEGER PRIMARY KEY AUTOINCREMENT, json TEXT NOT NULL);",
            nil, nil, nil
        )
    }

    public func insert(json: String) {
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "INSERT INTO offline_location (json) VALUES (?);", -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, (json as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
    }

    public func count() -> Int {
        queue.sync {
            guard let db else { return 0 }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM offline_location;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    public func batch(limit: Int = 100) -> [(id: Int64, json: String)] {
        queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT id, json FROM offline_location ORDER BY id ASC LIMIT \(limit);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

            var rows: [(id: Int64, json: String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                guard let cString = sqlite3_column_text(stmt, 1) else { continue }
                rows.append((id, String(cString: cString)))
            }
            return rows
        }
    }

    /// Returns whether the delete actually ran. `@discardableResult` keeps the
    /// existing call sites valid, but `TraceManager`'s flush loop checks it:
    /// a silently-failing delete (locked or corrupt DB) left `count()` above
    /// zero and spun that loop forever.
    @discardableResult
    public func deleteBatch(limit: Int = 100) -> Bool {
        queue.sync {
            guard let db else { return false }
            let sql = "DELETE FROM offline_location WHERE id IN (SELECT id FROM offline_location ORDER BY id ASC LIMIT \(limit));"
            return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
        }
    }
}
