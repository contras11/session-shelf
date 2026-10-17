import CSQLite3
import Foundation

/// 会話用テーブルの構造を確認し、元DBを変更せずに読み取ります。
final class OpenCodeDatabase {
    enum Format: Int {
        case v1 = 1, v2 = 2
        var sessionTable: String { self == .v2 ? "session_v2" : "session" }
    }

    struct Budget {
        var bytes: Int
        var entries: Int = LogLimits.maximumEntries
        var wasTruncated = false
    }

    typealias Row = [String: String]
    private var connection: OpaquePointer?
    private(set) var format: Format = .v1
    var sessionColumns: String {
        "id, project_id, parent_id, slug, directory, title, time_created, time_updated, time_compacting, time_archived" + (format == .v2 ? ", time_suspended, path" : "")
    }

    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            connection = nil
            throw SessionShelfError.unreadable("OpenCode DBを開けません")
        }
        do {
            sqlite3_busy_timeout(connection, 250)
            let tables = Set(try rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"] })
            // 移行後の旧テーブルには削除済みの履歴が残るため、v2と合算しません。
            let messageReferences = tables.contains("session_message") ? try rows("PRAGMA foreign_key_list(session_message)") : []
            let legacyProjection = messageReferences.contains { $0["table"] == "session" }
            format = tables.contains("session_v2") || (tables.contains("session_message") && !legacyProjection) ? .v2 : .v1
            var required: [String: Set<String>] = [
                format.sessionTable: ["id", "project_id", "parent_id", "slug", "directory", "title", "time_created", "time_updated", "time_compacting", "time_archived"]
            ]
            if format == .v2 {
                required[format.sessionTable]?.formUnion(["time_suspended", "path"])
                required["session_message"] = ["id", "session_id", "type", "seq", "time_created", "time_updated", "data"]
            } else {
                required["message"] = ["id", "session_id", "time_created", "time_updated", "data"]
                required["part"] = ["id", "message_id", "session_id", "time_created", "time_updated", "data"]
            }
            for (table, columns) in required {
                let found = Set(try rows("PRAGMA table_info(\(table))").compactMap { $0["name"] })
                guard columns.isSubset(of: found) else { throw SessionShelfError.unsupported("OpenCodeのスキーマが未対応です") }
            }
        } catch {
            sqlite3_close(connection)
            connection = nil
            throw error
        }
    }

    deinit { sqlite3_close(connection) }

    func rows(_ sql: String) throws -> [Row] {
        var budget = Budget(bytes: .max, entries: .max)
        return try rows(sql, budget: &budget)
    }

    func rows(_ sql: String, budget: inout Budget) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SessionShelfError.unsupported("OpenCodeのスキーマが未対応です")
        }
        defer { sqlite3_finalize(statement) }
        let originalLimit = sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, -1)
        defer { sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, originalLimit) }
        var result: [Row] = []
        while true {
            guard budget.entries > 0, budget.bytes > 0 else { budget.wasTruncated = true; return result }
            // Swiftへコピーする前に、SQLite自身が巨大な値の取得を拒否します。
            sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, Int32(min(Int(originalLimit), budget.bytes)))
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            if code == SQLITE_TOOBIG { budget.wasTruncated = true; return result }
            guard code == SQLITE_ROW else { throw SessionShelfError.unreadable("OpenCode DBの読み取りに失敗しました") }
            budget.entries -= 1
            var row: Row = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard sqlite3_column_type(statement, index) != SQLITE_NULL,
                      let name = sqlite3_column_name(statement, index),
                      let text = sqlite3_column_text(statement, index) else { continue }
                let count = Int(sqlite3_column_bytes(statement, index))
                let kept = min(count, budget.bytes)
                row[String(cString: name)] = String(decoding: UnsafeBufferPointer(start: text, count: kept), as: UTF8.self)
                budget.bytes -= kept
                if kept < count { budget.wasTruncated = true; break }
            }
            result.append(row)
            if budget.wasTruncated { return result }
        }
    }

    static func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
    static func protectionReason(_ row: Row) -> String? {
        if row["time_compacting"] != nil { return "OpenCodeが圧縮処理中" }
        if row["time_suspended"] != nil { return "OpenCodeが実行中または再開待ち" }
        guard let updated = date(row["time_updated"]) else { return "更新日時を確認できないセッション" }
        return Date().timeIntervalSince(updated) < 1800 ? "更新直後のセッション" : nil
    }

    static func date(_ value: String?) -> Date? {
        guard let value, let number = Double(value), number.isFinite else { return nil }
        return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
    }
}
