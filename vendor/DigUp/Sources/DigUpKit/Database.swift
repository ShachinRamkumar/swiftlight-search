import Foundation
#if canImport(SQLite3)
import SQLite3   // the system's (3.51 on macOS 26, FTS5 built in)
#else
import CSQLite   // the amalgamation in Vendor/sqlite, with FTS5 (scripts/fetch-vendor.sh)
#endif

/// A thin wrapper over SQLite. One connection, used from one thread.
public final class Database {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    let handle: OpaquePointer
    private var tracksShadowText = false
    private var changedText = Set<Int64>()
    private var flushingText = false

    public init(path: String, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(db)
            throw Failure(message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        if readOnly {
            try execute("PRAGMA query_only=ON;")
            return
        }
        var empty = false
        try query("PRAGMA page_count") { empty = $0.int(0) == 0 }
        if empty { try execute("PRAGMA page_size=16384;") }
        // Two processes opening a new index at once (a shell starts its search and index helpers together): the switch
        // to WAL can fail at once with "database is locked" rather than wait (SQLite's rule against deadlocks), so it's
        // tried again for up to five seconds.
        var tries = 0
        while true {
            do {
                try execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;")
                break
            } catch where sqlite3_errcode(db) == SQLITE_BUSY && tries < 50 {
                tries += 1
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    deinit {
        sqlite3_update_hook(handle, nil, nil)
        sqlite3_close_v2(handle)
    }

    func trackShadowTextChanges() {
        tracksShadowText = true
        // SQLite forbids triggers on FTS5 shadow tables. The hook records their row
        // changes; query flushes invalidation inside the same write transaction.
        sqlite3_update_hook(handle, { context, _, _, table, row in
            guard let context, let table, String(cString: table) == "fts_content" else { return }
            Unmanaged<Database>.fromOpaque(context).takeUnretainedValue().changedText.insert(row)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func flushTextChanges() throws {
        guard !flushingText, !changedText.isEmpty else { return }
        let ids = changedText.sorted()
        changedText.removeAll()
        flushingText = true
        defer { flushingText = false }
        for start in stride(from: 0, to: ids.count, by: 500) {
            let list = ids[start..<min(start + 500, ids.count)].map(String.init).joined(separator: ",")
            try run("DELETE FROM embedding_inputs WHERE segment IN (\(list))")
            try run("DELETE FROM embedding_failures WHERE segment IN (\(list))")
        }
    }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw Failure(message: "\(message) (in: \(sql.prefix(120)))")
        }
        try flushTextChanges()
    }

    /// Runs `sql` with `values` bound and calls `row` for each result row.
    public func query(_ sql: String, _ values: [SQLValue] = [], row: (Statement) throws -> Void = { _ in }) throws {
        let statement = try Statement(self, sql)
        try statement.bind(values)
        let atomic = tracksShadowText && !flushingText && !statement.isReadOnly && sqlite3_get_autocommit(handle) != 0
        if atomic { try execute("SAVEPOINT digup_shadow_text") }
        do {
            while try statement.step() { try row(statement) }
            try flushTextChanges()
            if atomic { try execute("RELEASE digup_shadow_text") }
        } catch {
            changedText.removeAll()
            if atomic { try? execute("ROLLBACK TO digup_shadow_text; RELEASE digup_shadow_text") }
            throw error
        }
    }

    public func run(_ sql: String, _ values: [SQLValue] = []) throws { try query(sql, values) }

    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        let nested = sqlite3_get_autocommit(handle) == 0
        let savepoint = "digup_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try execute(nested ? "SAVEPOINT \(savepoint)" : "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute(nested ? "RELEASE \(savepoint)" : "COMMIT")
            return result
        } catch {
            if nested {
                try? execute("ROLLBACK TO \(savepoint)")
                try? execute("RELEASE \(savepoint)")
            } else { try? execute("ROLLBACK") }
            throw error
        }
    }

    public var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }
    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }
}

public enum SQLValue {
    case int(Int64), double(Double), text(String), blob(Data), null

    static func optional(_ text: String?) -> SQLValue { text.map { .text($0) } ?? .null }
    static func optional(_ number: Double?) -> SQLValue { number.map { .double($0) } ?? .null }
}

public final class Statement {
    private let statement: OpaquePointer
    private let db: Database
    var isReadOnly: Bool { sqlite3_stmt_readonly(statement) != 0 }

    init(_ db: Database, _ sql: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Database.Failure(message: "\(db.errorMessage) (in: \(sql.prefix(160)))")
        }
        self.statement = statement
        self.db = db
    }

    deinit { sqlite3_finalize(statement) }

    func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .int(let number): status = sqlite3_bind_int64(statement, index, number)
            case .double(let number): status = sqlite3_bind_double(statement, index, number)
            case .text(let text): status = sqlite3_bind_text(statement, index, text, Int32(text.utf8.count), transient)
            case .blob(let data):
                status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw Database.Failure(message: db.errorMessage) }
        }
    }

    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw Database.Failure(message: db.errorMessage)
        }
    }

    public func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    public func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    public func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

    public func text(_ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map {
            String(decoding: UnsafeBufferPointer(start: $0, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
        }
    }

    public func blob(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}

/// SQLITE_TRANSIENT: SQLite copies bound text/blobs, so Swift's temporary buffers are safe to pass.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
