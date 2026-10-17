import Foundation

/// OpenCode v1/v2の会話テーブルを既存の画面モデルへ変換します。
public enum OpenCodeRepository {
    static func scan(database: URL) throws -> [SessionSummary] {
        let db = try OpenCodeDatabase(database)
        return try db.rows("SELECT \(db.sessionColumns) FROM \(db.format.sessionTable)").compactMap { row in
            guard let id = row["id"] else { return nil }
            let updated = OpenCodeDatabase.date(row["time_updated"]) ?? .distantPast
            let reason = OpenCodeDatabase.protectionReason(row)
            return SessionSummary(
                id: "opencode:\(id)", tool: .openCode,
                title: row["title"] ?? row["slug"] ?? id, date: updated, byteCount: 0,
                project: projectPath(row) ?? row["project_id"],
                overview: row["time_archived"] != nil ? "OpenCodeアーカイブ済みセッション" : "OpenCodeセッション",
                sourceURL: database, lineage: SessionLineage(sessionID: id, parentSessionID: row["parent_id"]),
                isProtected: reason != nil, protectionReason: reason
            )
        }.sorted { $0.date > $1.date }
    }

    static func loadDetail(session: SessionSummary, byteLimit: Int = LogLimits.detailBytes) throws -> ParsedLog {
        let db = try OpenCodeDatabase(session.sourceURL)
        let id = OpenCodeDatabase.quoted(providerID(session))
        var result = ParsedLog(title: session.title, project: session.project, overview: session.overview)
        var budget = OpenCodeDatabase.Budget(bytes: byteLimit)
        if db.format == .v2 {
            let row = try db.rows("SELECT directory, path FROM session_v2 WHERE id=\(id)").first ?? [:]
            let base = projectPath(row)
            let messages = try db.rows("SELECT type, time_created, data FROM session_message WHERE session_id=\(id) ORDER BY seq ASC", budget: &budget)
            for message in messages {
                guard let object = json(message["data"]) else { continue }
                appendV2(message, object: object, base: base, snapshotBase: row["directory"], into: &result)
            }
        } else {
            let parts = try db.rows("SELECT message.data AS message_data, message.time_created, part.data FROM message JOIN part ON part.message_id=message.id AND part.session_id=message.session_id WHERE message.session_id=\(id) ORDER BY message.time_created ASC, message.id ASC, part.time_created ASC, part.id ASC", budget: &budget)
            for part in parts {
                guard let object = json(part["message_data"]), let p = json(part["data"]) else { continue }
                let speaker = (object["role"] as? String).flatMap(Speaker.init(rawValue:)) ?? .system
                let timestamp = OpenCodeDatabase.date(part["time_created"])
                if p["type"] as? String == "text", let text = p["text"] as? String {
                    appendText(text, speaker: speaker, timestamp: timestamp, into: &result)
                }
                if p["type"] as? String == "tool", let name = p["tool"] as? String {
                    appendTool(name: name, state: p["state"] as? [String: Any] ?? [:], timestamp: timestamp, base: nil, into: &result)
                }
            }
        }
        result.wasTruncated = result.wasTruncated || budget.wasTruncated
        return result
    }

    private static func appendV2(_ row: OpenCodeDatabase.Row, object: [String: Any], base: String?, snapshotBase: String?, into result: inout ParsedLog) {
        let timestamp = OpenCodeDatabase.date(row["time_created"])
        switch row["type"] {
        case "user":
            if let text = object["text"] as? String { appendText(text, speaker: .user, timestamp: timestamp, into: &result) }
        case "assistant":
            for content in object["content"] as? [[String: Any]] ?? [] {
                switch content["type"] as? String {
                case "text":
                    if let text = content["text"] as? String { appendText(text, speaker: .assistant, timestamp: timestamp, into: &result) }
                case "reasoning":
                    if let text = content["text"] as? String, !text.isEmpty {
                        result.conversation.append(ConversationEntry(speaker: .assistant, text: text, timestamp: timestamp, kind: .thinking))
                    }
                case "tool":
                    if let name = content["name"] as? String {
                        appendTool(name: name, state: content["state"] as? [String: Any] ?? [:], timestamp: timestamp, base: base, into: &result)
                    }
                default: break
                }
            }
            let snapshot = object["snapshot"] as? [String: Any]
            for path in snapshot?["files"] as? [String] ?? [] {
                if let path = absolutePath(path, base: snapshotBase) { result.changedFiles.insert(ChangedFile(path: path)) }
            }
        case "system", "synthetic", "skill", "compaction":
            if let text = object["text"] as? String ?? object["summary"] as? String, !text.isEmpty {
                result.conversation.append(ConversationEntry(speaker: .system, text: text, timestamp: timestamp, kind: .context(label: row["type"] == "compaction" ? "圧縮の要約" : "OpenCodeの内部情報")))
            }
        case "shell":
            let status = object["status"] as? String
            let exit = object["exit"] as? Int
            let outcome: OperationResult = status == "exited" && exit == 0 ? .success : (status == "timeout" || status == "killed" || (status == "exited" && exit != nil) ? .failure : .unknown)
            let command = object["command"] as? String ?? "shell"
            result.operations.append(OperationEntry(category: .command, summary: command, result: outcome, timestamp: timestamp))
            result.conversation.append(ConversationEntry(speaker: .assistant, text: command, timestamp: timestamp, kind: .toolCall(name: "shell")))
            if let output = object["output"] as? [String: Any], let text = output["output"] as? String {
                result.conversation.append(ConversationEntry(speaker: .assistant, text: text, timestamp: timestamp, kind: .toolResult(result: outcome)))
                if output["truncated"] as? Bool == true { result.wasTruncated = true }
            }
        default: break
        }
    }

    private static func appendText(_ text: String, speaker: Speaker, timestamp: Date?, into result: inout ParsedLog) {
        let (clean, controls) = splitControlText(text)
        if !clean.isEmpty { result.conversation.append(ConversationEntry(speaker: speaker, text: clean, timestamp: timestamp)) }
        for control in controls {
            let summary = "\(control.name) \(control.args)"
            result.operations.append(OperationEntry(category: category(control.name), summary: summary, result: .unknown, timestamp: timestamp))
            result.conversation.append(ConversationEntry(speaker: .assistant, text: summary, timestamp: timestamp, kind: .toolCall(name: control.name)))
        }
    }

    private static func appendTool(name: String, state: [String: Any], timestamp: Date?, base: String?, into result: inout ParsedLog) {
        let status = state["status"] as? String
        let outcome: OperationResult = status == "completed" ? .success : (status == "error" ? .failure : .unknown)
        let kind = category(name)
        let summary = name + summaryText(state["input"] ?? state["output"])
        result.operations.append(OperationEntry(category: kind, summary: summary, result: outcome, timestamp: timestamp))
        result.conversation.append(ConversationEntry(speaker: .assistant, text: summary, timestamp: timestamp, kind: .toolCall(name: name)))
        let content = state["content"] as? [[String: Any]] ?? []
        var output = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        if let legacy = state["output"] { output = summaryText(legacy) }
        if let error = state["error"] as? [String: Any], let message = error["message"] as? String {
            output = [output, message].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if !output.isEmpty { result.conversation.append(ConversationEntry(speaker: .assistant, text: output, timestamp: timestamp, kind: .toolResult(result: outcome))) }
        if kind == .edit {
            extractPaths(state["input"], base: base, into: &result.changedFiles)
            extractPaths(state["output"], base: base, into: &result.changedFiles)
        }
    }

    private static func category(_ name: String) -> OperationCategory {
        let lower = name.lowercased()
        if ["write", "patch", "edit"].contains(where: lower.contains) { return .edit }
        return ["read", "search", "glob", "grep"].contains(where: lower.contains) ? .investigation : .command
    }

    private static func summaryText(_ value: Any?) -> String {
        guard let value else { return "" }
        let text: String
        if let string = value as? String { text = string }
        else if let data = try? JSONSerialization.data(withJSONObject: value), let encoded = String(data: data, encoding: .utf8) { text = encoded }
        else { return "" }
        let clipped = text.count > 180 ? String(text.prefix(180)) + "…" : text
        return clipped.isEmpty ? "" : " (\(clipped))"
    }

    private static func extractPaths(_ value: Any?, base: String?, into files: inout Set<ChangedFile>) {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if ["path", "file", "file_path", "filepath"].contains(key.lowercased()), let path = child as? String,
                   let path = absolutePath(path, base: base) { files.insert(ChangedFile(path: path)) }
                extractPaths(child, base: base, into: &files)
            }
        } else if let array = value as? [Any] {
            for child in array { extractPaths(child, base: base, into: &files) }
        }
    }

    private static func absolutePath(_ path: String, base: String?) -> String? {
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL.path }
        guard let base, base.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(path).standardizedFileURL.path
    }

    private static func projectPath(_ row: OpenCodeDatabase.Row) -> String? {
        guard let directory = row["directory"], !directory.isEmpty else { return nil }
        guard let subpath = row["path"], !subpath.isEmpty else { return directory }
        return absolutePath(subpath, base: directory)
    }

    private static func json(_ text: String?) -> [String: Any]? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func providerID(_ session: SessionSummary) -> String {
        session.id.hasPrefix("opencode:") ? String(session.id.dropFirst("opencode:".count)) : session.id
    }

    private static func splitControlText(_ text: String) -> (String, [(name: String, args: String)]) {
        let matches = text.matches(of: #/(?s)(\d{2})❺([A-Za-z0-9_-]+)\s+noneauta(.*?)(?=\d{2}❺|<\|eos\|>|$)/#)
        guard let first = matches.first else { return (text.replacingOccurrences(of: "<|eos|>", with: ""), []) }
        let prefix = String(text[..<first.range.lowerBound])
        var controls = matches.map { (String($0.output.2), String($0.output.3).trimmingCharacters(in: .whitespacesAndNewlines)) }
        if text.contains("❺grep") && !controls.contains(where: { $0.0 == "grep" }) { controls.append(("grep", "")) }
        return (prefix.replacingOccurrences(of: "<|eos|>", with: ""), controls)
    }

    public static func raw(session: SessionSummary) throws -> String { try rawLog(session: session).text }

    static func rawLog(session: SessionSummary) throws -> (text: String, wasTruncated: Bool) {
        let db = try OpenCodeDatabase(session.sourceURL)
        let id = OpenCodeDatabase.quoted(providerID(session))
        let tables = db.format == .v2 ? ["session_v2", "session_message"] : ["session", "message", "part"]
        var budget = OpenCodeDatabase.Budget(bytes: LogLimits.rawBytes)
        var blocks: [String] = []
        for table in tables {
            let key = table == db.format.sessionTable ? "id" : "session_id"
            let columns: String
            if table == db.format.sessionTable { columns = "id, project_id, parent_id, directory, title, time_created, time_updated" }
            else { columns = db.format == .v2 ? "id, session_id, type, seq, time_created, time_updated, data" : (table == "part" ? "id, message_id, session_id, time_created, time_updated, data" : "id, session_id, time_created, time_updated, data") }
            let order = table == "session_message" ? " ORDER BY seq ASC" : " ORDER BY time_created ASC, id ASC"
            let rows = try db.rows("SELECT \(columns) FROM \(table) WHERE \(key)=\(id)\(order)", budget: &budget)
            let lines = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) }
            blocks.append("===== \(table) =====\n" + lines.joined(separator: "\n"))
            if budget.wasTruncated { break }
        }
        let raw = blocks.joined(separator: "\n")
        let encoded = Data(raw.utf8)
        let truncated = budget.wasTruncated || encoded.count > LogLimits.rawBytes
        let text = String(decoding: encoded.prefix(LogLimits.rawBytes), as: UTF8.self)
        return (text, truncated)
    }

}
