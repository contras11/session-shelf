import Foundation
import CSQLite3

/// OpenCodeの公開会話テーブルだけを読む、読み取り専用アダプタです。
public enum OpenCodeRepository {
    struct Row { let values: [String: String?] }

    static func scan(database: URL) throws -> [SessionSummary] {
        let sessions = try query(database, "SELECT id, project_id, parent_id, slug, directory, title, time_created, time_updated, time_compacting, time_archived FROM session")
        return sessions.compactMap { row in
            guard let id = row.values["id"] ?? nil else { return nil }
            let updated = date(row.values["time_updated"] ?? nil) ?? .distantPast
            let title = value(row, "title") ?? value(row, "slug") ?? id
            let compacting = value(row, "time_compacting")
            let archived = value(row, "time_archived")
            let protected = compacting != nil || (Date().timeIntervalSince(updated) < 1800)
            let reason = compacting != nil ? "OpenCodeが圧縮処理中" : (protected ? "更新直後のセッション" : nil)
            return SessionSummary(id: "opencode:\(id)", tool: .openCode, title: title, date: updated, byteCount: 0, project: value(row, "directory") ?? value(row, "project_id"), overview: archived != nil ? "OpenCodeアーカイブ済みセッション" : "OpenCodeセッション", sourceURL: database, deletionURL: database, isProtected: protected, protectionReason: reason)
        }.sorted { $0.date > $1.date }
    }

    static func loadDetail(session: SessionSummary) throws -> ParsedLog {
        let id = session.id.replacingOccurrences(of: "opencode:", with: "")
        var result = ParsedLog(title: session.title, project: session.project, overview: session.overview)
        let messages = try query(session.sourceURL, "SELECT id, time_created, data FROM message WHERE session_id = '\(sql(id))' ORDER BY time_created ASC")
        for message in messages {
            guard let dataString = message.values["data"] ?? nil, let data = dataString.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let speaker: Speaker = (object["role"] as? String).flatMap(Speaker.init(rawValue:)) ?? .system
            let timestamp = date(message.values["time_created"] ?? nil)
            let parts = try query(session.sourceURL, "SELECT data FROM part WHERE message_id = '\(sql(value(message, "id") ?? ""))' ORDER BY time_created ASC")
            for part in parts {
                guard let raw = value(part, "data"), let pdata = raw.data(using: .utf8), let p = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any], let type = p["type"] as? String else { continue }
                if type == "text", let text = p["text"] as? String {
                    let (clean, controls) = splitControlText(text)
                    if !clean.isEmpty { result.conversation.append(ConversationEntry(speaker: speaker, text: clean, timestamp: timestamp)) }
                    for control in controls {
                        let category: OperationCategory = ["write", "patch", "edit"].contains(where: control.name.lowercased().contains) ? .edit : (["read", "glob", "grep"].contains(where: control.name.lowercased().contains) ? .investigation : .command)
                        result.operations.append(OperationEntry(category: category, summary: "\(control.name) \(control.args)", result: .unknown, timestamp: timestamp))
                        result.conversation.append(ConversationEntry(speaker: .assistant, text: "\(control.name) \(control.args)", timestamp: timestamp, kind: .toolCall(name: control.name)))
                    }
                }
                if type == "tool", let name = p["tool"] as? String {
                    let state = p["state"] as? [String: Any] ?? [:]
                    let status = state["status"] as? String
                    let outcome: OperationResult = status == "completed" ? .success : (status == "error" ? .failure : .unknown)
                    let summary = "\(name)\(summaryText(state["input"] ?? state["output"]))"
                    let lower = name.lowercased()
                    let category: OperationCategory = ["write", "patch", "edit"].contains(where: lower.contains) ? .edit : (["read", "search"].contains(where: lower.contains) ? .investigation : .command)
                    result.operations.append(OperationEntry(category: category, summary: summary, result: outcome, timestamp: timestamp))
                    result.conversation.append(ConversationEntry(speaker: .assistant, text: summary, timestamp: timestamp, kind: .toolCall(name: name)))
                    if let output = state["output"] { result.conversation.append(ConversationEntry(speaker: .assistant, text: summaryText(output), timestamp: timestamp, kind: .toolResult(result: outcome))) }
                    extractPaths(state["input"], into: &result.changedFiles)
                    extractPaths(state["output"], into: &result.changedFiles)
                }
            }
        }
        result.wasTruncated = false
        return result
    }

    private static func summaryText(_ value: Any?) -> String {
        guard let value else { return "" }
        let text: String
        if let string = value as? String { text = string } else if let data = try? JSONSerialization.data(withJSONObject: value), let encoded = String(data: data, encoding: .utf8) { text = encoded } else { return "" }
        let clipped = text.count > 180 ? String(text.prefix(180)) + "…" : text
        return clipped.isEmpty ? "" : " (\(clipped))"
    }

    private static func extractPaths(_ value: Any?, into files: inout Set<ChangedFile>) {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if ["path", "file", "file_path"].contains(key.lowercased()), let path = child as? String, path.hasPrefix("/") { files.insert(ChangedFile(path: path)) }
                extractPaths(child, into: &files)
            }
        } else if let array = value as? [Any] { for child in array { extractPaths(child, into: &files) } }
    }

    private static func splitControlText(_ text: String) -> (String, [(name: String, args: String)]) {
        let pattern = #"(?s)(\d{2})❺([A-Za-z0-9_-]+)\s+noneauta(.*?)(?=\d{2}❺|<\|eos\|>|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (text.replacingOccurrences(of: "<|eos|>", with: ""), []) }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard let first = matches.first, let firstRange = Range(first.range, in: text) else { return (text.replacingOccurrences(of: "<|eos|>", with: ""), []) }
        let prefix = String(text[..<firstRange.lowerBound])
        let controls = matches.compactMap { match -> (String, String)? in
            guard let nameRange = Range(match.range(at: 2), in: text), let argRange = Range(match.range(at: 3), in: text) else { return nil }
            return (String(text[nameRange]), String(text[argRange]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var normalized = controls
        if text.contains("❺grep") && !normalized.contains(where: { $0.0 == "grep" }) { normalized.append(("grep", "")) }
        return (prefix.replacingOccurrences(of: "<|eos|>", with: ""), normalized)
    }

    public static func raw(session: SessionSummary) throws -> String {
        let id = session.id.replacingOccurrences(of: "opencode:", with: "")
        let tables = ["session": "SELECT id, project_id, title, time_created, time_updated FROM session WHERE id = '\(sql(id))'", "message": "SELECT id, session_id, time_created, time_updated, data FROM message WHERE session_id = '\(sql(id))'", "part": "SELECT id, message_id, session_id, time_created, time_updated, data FROM part WHERE session_id = '\(sql(id))'"]
        var blocks: [String] = []
        for (name, statement) in tables { let rows = try query(session.sourceURL, statement); blocks.append("===== \(name) =====\n" + rows.map { row in String(data: (try? JSONSerialization.data(withJSONObject: row.values.compactMapValues { $0 })) ?? Data(), encoding: .utf8) ?? "{}" }.joined(separator: "\n")) }
        return blocks.joined(separator: "\n")
    }

    static func delete(sessionID: String, database: URL, expectedUpdated: Date, executables: [URL]) throws {
        let rows = try query(database, "SELECT id, time_updated, time_compacting FROM session WHERE id = '\(sql(sessionID))'")
        guard let row = rows.first, value(row, "id") == sessionID else { throw SessionShelfError.unreadable("OpenCodeセッションが見つかりません") }
        guard let updated = date(value(row, "time_updated")), abs(updated.timeIntervalSince(expectedUpdated)) < 0.001 else { throw SessionShelfError.storageItemChanged }
        guard value(row, "time_compacting") == nil, Date().timeIntervalSince(updated) >= 1800 else { throw SessionShelfError.protectedItem("更新直後または圧縮中のセッション") }
        guard let executable = executables.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw SessionShelfError.unreadable("OpenCode公式CLIが見つかりません") }
        let process = Process(); process.executableURL = executable; process.arguments = ["session", "delete", sessionID]
        let errorPipe = Pipe(); process.standardError = errorPipe
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SessionShelfError.unreadable("OpenCode CLIが削除に失敗しました") }
    }

    private static func sql(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "''") }
    private static func value(_ row: Row, _ key: String) -> String? { row.values[key] ?? nil }
    private static func date(_ value: String?) -> Date? { guard let value, let number = Double(value) else { return nil }; return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number) }

    private static func query(_ url: URL, _ sql: String) throws -> [Row] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { throw SessionShelfError.unreadable("OpenCode DBを開けません") }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw SessionShelfError.unsupported("OpenCodeのスキーマが未対応です") }
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        var resultCode = SQLITE_ROW
        while resultCode == SQLITE_ROW {
            resultCode = sqlite3_step(statement)
            if resultCode != SQLITE_ROW { break }
            var values: [String: String?] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard let name = sqlite3_column_name(statement, index) else { continue }
                values[String(cString: name)] = sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(statement, index))
            }
            rows.append(Row(values: values))
        }
        guard resultCode == SQLITE_DONE else { throw SessionShelfError.unreadable("OpenCode DBの読み取りに失敗しました") }
        return rows
    }
}
