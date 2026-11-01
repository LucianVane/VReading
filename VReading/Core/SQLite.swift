import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

typealias Row = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int64 { (self[k] as? Int64) ?? Int64((self[k] as? Double) ?? 0) }
    func dbl(_ k: String) -> Double { (self[k] as? Double) ?? Double((self[k] as? Int64) ?? 0) }
}

/// 轻量 SQLite 封装
final class SQLiteDB {
    private var db: OpaquePointer?

    init(path: String, readonly: Bool = false) throws {
        let flags = (readonly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            throw ReaderError.invalidFile(String(localized: "Cannot open database \(path)"))
        }
    }

    deinit { sqlite3_close(db) }

    var lastError: String { String(cString: sqlite3_errmsg(db)) }

    func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("SQL error: \(lastError) in \(sql.prefix(120))")
        }
    }

    private func prepare(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQL prepare error: \(lastError) in \(sql.prefix(120))")
            return nil
        }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Data:
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            default: sqlite3_bind_text(stmt, idx, "\(a!)", -1, SQLITE_TRANSIENT)
            }
        }
        return stmt
    }

    @discardableResult
    func run(_ sql: String, _ args: Any?...) -> Bool { run(sql, args: args) }

    @discardableResult
    func run(_ sql: String, args: [Any?]) -> Bool {
        guard let stmt = prepare(sql, args) else { return false }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            print("SQL step error: \(lastError) in \(sql.prefix(120))")
            return false
        }
        return true
    }

    func query(_ sql: String, _ args: Any?...) -> [Row] { query(sql, args: args) }

    func query(_ sql: String, args: [Any?]) -> [Row] {
        guard let stmt = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        let cols = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: Row = [:]
            for c in 0..<cols {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, c)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, c))
                case SQLITE_BLOB:
                    if let p = sqlite3_column_blob(stmt, c) {
                        row[name] = Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, c)))
                    }
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    func scalar(_ sql: String, _ args: Any?...) -> Int64 {
        query(sql, args: args).first?.values.first.flatMap { ($0 as? Int64) ?? Int64(($0 as? Double) ?? 0) } ?? 0
    }

    var userVersion: Int {
        get { Int(scalar("PRAGMA user_version")) }
        set { exec("PRAGMA user_version = \(newValue)") }
    }

    func transaction(_ body: () -> Void) {
        exec("BEGIN")
        body()
        exec("COMMIT")
    }
}
