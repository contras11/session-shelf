import Foundation

enum LogLimits {
    static let listBytes = 384_000
    static let detailBytes = 8_000_000
    static let rawBytes = 2_000_000
    static let maximumEntries = 5_000
}

struct ParsedLog {
    var title: String?
    var project: String?
    var overview: String?
    var conversation: [ConversationEntry] = []
    var operations: [OperationEntry] = []
    var changedFiles: Set<ChangedFile> = []
    var wasTruncated = false
}

enum LogParsing {
    static func parseJSONL(at url: URL, tool: AITool, byteLimit: Int = LogLimits.detailBytes) throws -> ParsedLog {
        let (text, truncated) = try readText(at: url, byteLimit: byteLimit)
        var result = ParsedLog()
        result.wasTruncated = truncated

        let lines = text.split(whereSeparator: \ .isNewline)
        for line in lines.prefix(LogLimits.maximumEntries) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            switch tool {
            case .codex:
                parseCodex(object, into: &result)
            case .claudeCode:
                parseClaude(object, into: &result)
            case .cursorCLI:
                parseCursorCLI(object, into: &result)
            case .grokBuildCLI:
                parseGrok(object, into: &result)
            case .cursorDesktop:
                break
            }
        }
        if lines.count > LogLimits.maximumEntries {
            result.wasTruncated = true
        }
        finish(&result)
        return result
    }

    static func parseMarkdown(at url: URL, byteLimit: Int = LogLimits.detailBytes) throws -> ParsedLog {
        let (text, truncated) = try readText(at: url, byteLimit: byteLimit)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let heading = lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let title = heading.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedLog(
            title: title ?? url.deletingPathExtension().lastPathComponent,
            overview: excerpt(cleanText),
            conversation: [ConversationEntry(speaker: .assistant, text: cleanText)],
            wasTruncated: truncated
        )
    }

    static func parseGrokDirectory(_ directory: URL, byteLimit: Int = LogLimits.detailBytes) throws -> ParsedLog {
        var result = ParsedLog()
        let summaryURL = directory.appendingPathComponent("summary.json")
        if let data = try? Data(contentsOf: summaryURL),
           let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result.title = summary["generated_title"] as? String
            result.overview = summary["session_summary"] as? String
            if let info = summary["info"] as? [String: Any] {
                result.project = info["cwd"] as? String ?? info["working_directory"] as? String
            }
        }

        let chatURL = directory.appendingPathComponent("chat_history.jsonl")
        if FileManager.default.fileExists(atPath: chatURL.path) {
            let parsed = try parseJSONL(at: chatURL, tool: .grokBuildCLI, byteLimit: byteLimit)
            merge(parsed, into: &result)
        }
        let planURL = directory.appendingPathComponent("plan.md")
        if FileManager.default.fileExists(atPath: planURL.path),
           let plan = try? parseMarkdown(at: planURL, byteLimit: byteLimit) {
            if !plan.conversation.isEmpty {
                result.conversation.append(ConversationEntry(speaker: .assistant, text: "【プラン】\n\(plan.conversation[0].text)"))
            }
            result.wasTruncated = result.wasTruncated || plan.wasTruncated
        }
        finish(&result)
        return result
    }

    static func rawText(for summary: SessionSummary) throws -> (String, Bool) {
        var isDirectory: ObjCBool = false
        let sourceIsDirectory = FileManager.default.fileExists(atPath: summary.sourceURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
        if summary.tool == .grokBuildCLI, sourceIsDirectory {
            let names = ["summary.json", "chat_history.jsonl", "events.jsonl", "plan.md"]
            var blocks: [String] = []
            var truncated = false
            for name in names {
                let url = summary.sourceURL.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let remaining = max(1, LogLimits.rawBytes - blocks.reduce(0) { $0 + $1.utf8.count })
                let part = try readText(at: url, byteLimit: remaining)
                blocks.append("===== \(name) =====\n\(part.0)")
                truncated = truncated || part.1
                if remaining <= 1 { break }
            }
            return (blocks.joined(separator: "\n\n"), truncated)
        }
        return try readText(at: summary.sourceURL, byteLimit: LogLimits.rawBytes)
    }

    private static func parseCodex(_ object: [String: Any], into result: inout ParsedLog) {
        let type = object["type"] as? String
        let payload = object["payload"] as? [String: Any] ?? [:]
        let timestamp = date(object["timestamp"] ?? payload["timestamp"])

        if type == "session_meta" {
            result.project = payload["cwd"] as? String
            return
        }

        if type == "response_item" {
            let payloadType = payload["type"] as? String
            if payloadType == "message", let speaker = speaker(payload["role"] as? String) {
                parseMessageContent(
                    payload["content"],
                    speaker: speaker,
                    timestamp: timestamp,
                    into: &result
                )
            } else if payloadType == "function_call" || payloadType == "custom_tool_call" {
                let name = payload["name"] as? String ?? payload["tool_name"] as? String ?? "ツール"
                let input = payload["arguments"] ?? payload["input"]
                let arguments = text(from: input)
                addToolCall(name: name, detail: arguments, timestamp: timestamp, into: &result)
                addOperation(name: name, detail: arguments, result: .unknown, timestamp: timestamp, into: &result)
                if isEditTool(name) { collectPaths(in: input as Any, into: &result.changedFiles) }
            } else if payloadType == "function_call_output" || payloadType == "custom_tool_call_output" {
                let output = text(from: payload["output"])
                let operationResult: OperationResult = output.lowercased().contains("error") ? .failure : .success
                addToolResult(output, result: operationResult, timestamp: timestamp, into: &result)
                result.operations.append(OperationEntry(category: .other, summary: "ツールの実行結果", result: operationResult, timestamp: timestamp))
            }
        } else if type == "event_msg" {
            let eventType = payload["type"] as? String
            if eventType == "user_message" {
                addNormalizedText(text(from: payload["message"]), speaker: .user, timestamp: timestamp, into: &result)
            } else if eventType == "agent_message" {
                addConversation(cleanVisibleText(text(from: payload["message"])), speaker: .assistant, timestamp: timestamp, into: &result)
            }
        }
    }

    private static func parseClaude(_ object: [String: Any], into result: inout ParsedLog) {
        let type = object["type"] as? String ?? ""
        let timestamp = date(object["timestamp"])
        if result.project == nil { result.project = object["cwd"] as? String }

        if type == "ai-title", let title = object["title"] as? String {
            result.title = title
        }
        guard type == "user" || type == "assistant" else { return }
        let message = object["message"] as? [String: Any] ?? [:]
        let role = speaker(message["role"] as? String) ?? (type == "user" ? .user : .assistant)
        if let content = message["content"] as? [[String: Any]] {
            for block in content {
                let blockType = block["type"] as? String
                if blockType == "text" {
                    addConversation(block["text"] as? String ?? "", speaker: role, timestamp: timestamp, into: &result)
                } else if blockType == "tool_use" {
                    let name = block["name"] as? String ?? "ツール"
                    let detail = text(from: block["input"])
                    addToolCall(name: name, detail: detail, timestamp: timestamp, into: &result)
                    addOperation(
                        name: name,
                        detail: detail,
                        result: .unknown,
                        timestamp: timestamp,
                        into: &result
                    )
                    if isEditTool(name) { collectPaths(in: block["input"] as Any, into: &result.changedFiles) }
                } else if blockType == "tool_result" {
                    let failed = block["is_error"] as? Bool ?? false
                    addToolResult(
                        text(from: block["content"]),
                        result: failed ? .failure : .success,
                        timestamp: timestamp,
                        into: &result
                    )
                    result.operations.append(OperationEntry(category: .other, summary: "ツールの実行結果", result: failed ? .failure : .success, timestamp: timestamp))
                }
            }
        } else {
            addConversation(text(from: message["content"]), speaker: role, timestamp: timestamp, into: &result)
        }
    }

    private static func parseCursorCLI(_ object: [String: Any], into result: inout ParsedLog) {
        guard let role = speaker(object["role"] as? String) else { return }
        let value = object["message"] ?? object["content"]
        let embeddedTimestamp = firstEmbeddedTimestamp(in: value)
        parseMessageContent(
            value,
            speaker: role,
            timestamp: date(object["timestamp"]) ?? embeddedTimestamp,
            into: &result
        )
    }

    private static func parseGrok(_ object: [String: Any], into result: inout ParsedLog) {
        let type = (object["type"] as? String ?? "").lowercased()
        let timestamp = date(object["ts"] ?? object["timestamp"])
        if type.contains("user") {
            addConversation(text(from: object["content"]), speaker: .user, timestamp: timestamp, into: &result)
        } else if type.contains("assistant") || type.contains("model") {
            addConversation(text(from: object["content"]), speaker: .assistant, timestamp: timestamp, into: &result)
            if let calls = object["tool_calls"] as? [Any] {
                for call in calls {
                    let dictionary = call as? [String: Any] ?? [:]
                    let name = dictionary["name"] as? String ?? dictionary["tool_name"] as? String ?? "ツール"
                    let detail = text(from: dictionary["arguments"] ?? dictionary["input"])
                    addToolCall(name: name, detail: detail, timestamp: timestamp, into: &result)
                    addOperation(
                        name: name,
                        detail: detail,
                        result: .unknown,
                        timestamp: timestamp,
                        into: &result
                    )
                    if isEditTool(name) {
                        collectPaths(in: dictionary["arguments"] ?? dictionary["input"] as Any, into: &result.changedFiles)
                    }
                }
            }
        } else if type.contains("tool") {
            let failed = (object["status"] as? String)?.lowercased() == "failed" || object["error"] != nil
            let output = text(from: object["content"] ?? object["output"] ?? object["error"])
            addToolResult(output, result: failed ? .failure : .success, timestamp: timestamp, into: &result)
            result.operations.append(OperationEntry(category: .other, summary: "ツールの実行結果", result: failed ? .failure : .success, timestamp: timestamp))
        }
        collectPaths(in: object, into: &result.changedFiles)
    }

    private static func merge(_ source: ParsedLog, into target: inout ParsedLog) {
        target.title = target.title ?? source.title
        target.project = target.project ?? source.project
        target.overview = target.overview ?? source.overview
        target.conversation.append(contentsOf: source.conversation)
        target.operations.append(contentsOf: source.operations)
        target.changedFiles.formUnion(source.changedFiles)
        target.wasTruncated = target.wasTruncated || source.wasTruncated
    }

    private static func finish(_ result: inout ParsedLog) {
        // Codexでは同一発言が数ミリ秒ずれてresponse_itemとevent_msgへ二重記録される。
        // 通常発言と内部情報だけを近接時刻で重複除去し、複数の同じ操作結果は保持する。
        var seenMessageTimes: [String: TimeInterval?] = [:]
        result.conversation = result.conversation.filter { entry in
            switch entry.kind {
            case .message, .context:
                let signature = "\(entry.kind)\u{1F}\(entry.speaker.rawValue)\u{1F}\(entry.text)"
                let timestamp = entry.timestamp?.timeIntervalSince1970
                if let previous = seenMessageTimes[signature] {
                    if previous == nil && timestamp == nil { return false }
                    if let previous, let timestamp, abs(timestamp - previous) < 1 { return false }
                }
                seenMessageTimes[signature] = timestamp
                return true
            case .toolCall, .toolResult:
                return true
            }
        }
        if result.title?.isEmpty != false,
           let first = result.conversation.first(where: { $0.kind == .message && $0.speaker == .user })?.text {
            result.title = excerpt(first, maximum: 72)
        }
        if result.overview?.isEmpty != false {
            let relevant = result.conversation.filter { $0.kind == .message }.prefix(3).map(\.text).joined(separator: " ")
            result.overview = excerpt(relevant)
        }
    }

    private static func addConversation(
        _ raw: String,
        speaker: Speaker,
        timestamp: Date?,
        into result: inout ParsedLog
    ) {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        result.conversation.append(ConversationEntry(speaker: speaker, text: clean, timestamp: timestamp))
    }

    private static func parseMessageContent(
        _ value: Any?,
        speaker: Speaker,
        timestamp: Date?,
        into result: inout ParsedLog
    ) {
        if let string = value as? String {
            if speaker == .system {
                addContext(string, label: contextLabel(for: string), timestamp: timestamp, into: &result)
            } else if speaker == .user {
                addNormalizedText(string, speaker: speaker, timestamp: timestamp, into: &result)
            } else {
                addConversation(cleanVisibleText(string), speaker: speaker, timestamp: timestamp, into: &result)
            }
            return
        }

        if let dictionary = value as? [String: Any] {
            if let content = dictionary["content"] {
                parseMessageContent(content, speaker: speaker, timestamp: timestamp, into: &result)
            } else if let text = dictionary["text"] as? String {
                parseMessageContent(text, speaker: speaker, timestamp: timestamp, into: &result)
            } else {
                addUnknownContext(dictionary, timestamp: timestamp, into: &result)
            }
            return
        }

        guard let blocks = value as? [Any] else {
            let fallback = text(from: value)
            if !fallback.isEmpty { addContext(fallback, label: "未対応データ", timestamp: timestamp, into: &result) }
            return
        }

        for block in blocks {
            guard let dictionary = block as? [String: Any] else {
                if let string = block as? String {
                    parseMessageContent(string, speaker: speaker, timestamp: timestamp, into: &result)
                }
                continue
            }
            let blockType = (dictionary["type"] as? String ?? "").lowercased()
            switch blockType {
            case "text", "input_text", "output_text":
                parseMessageContent(dictionary["text"], speaker: speaker, timestamp: timestamp, into: &result)
            case "tool_use":
                let name = dictionary["name"] as? String ?? "ツール"
                let input = dictionary["input"] ?? dictionary["arguments"]
                let detail = text(from: input)
                addToolCall(name: name, detail: detail, timestamp: timestamp, into: &result)
                addOperation(name: name, detail: detail, result: .unknown, timestamp: timestamp, into: &result)
                if isEditTool(name) { collectPaths(in: input as Any, into: &result.changedFiles) }
            case "tool_result":
                let failed = dictionary["is_error"] as? Bool ?? false
                let output = text(from: dictionary["content"] ?? dictionary["output"])
                addToolResult(output, result: failed ? .failure : .success, timestamp: timestamp, into: &result)
                result.operations.append(OperationEntry(
                    category: .other,
                    summary: "ツールの実行結果",
                    result: failed ? .failure : .success,
                    timestamp: timestamp
                ))
            case "input_image", "image":
                addContext("添付画像", label: "添付画像", timestamp: timestamp, into: &result)
            default:
                // 未知形式は捨てず、生ログへ移動しなくても確認できる内部情報として保持する。
                addUnknownContext(dictionary, timestamp: timestamp, into: &result)
            }
        }
    }

    private struct NormalizedUserText {
        let visible: String?
        let context: String?
        let timestamp: Date?
    }

    private static func addNormalizedText(
        _ raw: String,
        speaker: Speaker,
        timestamp: Date?,
        into result: inout ParsedLog
    ) {
        let normalized = normalizeUserText(raw)
        let resolvedTimestamp = timestamp ?? normalized.timestamp
        if let context = normalized.context, !context.isEmpty {
            addContext(context, label: contextLabel(for: context), timestamp: resolvedTimestamp, into: &result)
        }
        if let visible = normalized.visible, !visible.isEmpty {
            addConversation(visible, speaker: speaker, timestamp: resolvedTimestamp, into: &result)
        }
    }

    private static func normalizeUserText(_ raw: String) -> NormalizedUserText {
        var working = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let embeddedTimestamp = embeddedTimestamp(in: working)
        working = removingTag(named: "timestamp", from: working).trimmingCharacters(in: .whitespacesAndNewlines)

        if let query = content(ofTag: "user_query", in: working) {
            let context = removingTag(named: "user_query", from: working).trimmingCharacters(in: .whitespacesAndNewlines)
            return NormalizedUserText(
                visible: cleanVisibleText(query),
                context: context.isEmpty ? nil : context,
                timestamp: embeddedTimestamp
            )
        }

        if (working.hasPrefix("<realtime_delegation>") || working.hasPrefix("<codex_delegation>")),
           let input = content(ofTag: "input", in: working) {
            let context = removingTag(named: "input", from: working).trimmingCharacters(in: .whitespacesAndNewlines)
            return NormalizedUserText(
                visible: cleanVisibleText(input),
                context: context.isEmpty ? nil : context,
                timestamp: embeddedTimestamp
            )
        }

        let requestMarkers = ["## My request for Codex:", "## My request:"]
        for marker in requestMarkers {
            if let range = working.range(of: marker) {
                let context = String(working[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let visible = String(working[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return NormalizedUserText(
                    visible: cleanVisibleText(visible),
                    context: context.isEmpty ? nil : context,
                    timestamp: embeddedTimestamp
                )
            }
        }

        if isInternalContext(working) {
            return NormalizedUserText(visible: nil, context: working, timestamp: embeddedTimestamp)
        }
        return NormalizedUserText(visible: cleanVisibleText(working), context: nil, timestamp: embeddedTimestamp)
    }

    private static func cleanVisibleText(_ raw: String) -> String {
        let cleanedLines = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.trimmingCharacters(in: .whitespaces) != "[REDACTED]" }
            .map { line in
                line.replacingOccurrences(
                    of: #"^\[(STATUS|COMPLETE)\]\s*"#,
                    with: "",
                    options: .regularExpression
                )
            }
            .joined(separator: "\n")
        return cleanedLines
            .replacingOccurrences(of: "<proposed_plan>", with: "")
            .replacingOccurrences(of: "</proposed_plan>", with: "")
            .replacingOccurrences(of: "::codex-realtime-inline{}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isInternalContext(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "<recommended_plugins>",
            "# AGENTS.md instructions",
            "<environment_context>",
            "<app-context>",
            "<realtime_conversation>",
            "<realtime_delegation>",
            "<codex_delegation>",
            "<manually_attached_skills>",
            "<cursor_commands>",
            "# Applications mentioned by the user:"
        ]
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    private static func contextLabel(for text: String) -> String {
        if text.contains("<recommended_plugins>") { return "利用可能な連携" }
        if text.contains("# AGENTS.md instructions") { return "プロジェクト指示" }
        if text.contains("<environment_context>") { return "実行環境" }
        if text.contains("<app-context>") { return "アプリ情報" }
        if text.contains("# Applications mentioned by the user:") || text.contains("<appshot") { return "画面情報" }
        if text.contains("<realtime_delegation>") { return "音声セッション情報" }
        if text.contains("<codex_delegation>") { return "委譲情報" }
        if text.contains("<manually_attached_skills>") { return "スキル情報" }
        if text.contains("<cursor_commands>") { return "Cursorコマンド" }
        return "内部情報"
    }

    private static func addContext(
        _ raw: String,
        label: String,
        timestamp: Date?,
        into result: inout ParsedLog
    ) {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        result.conversation.append(ConversationEntry(
            speaker: .system,
            text: clean,
            timestamp: timestamp,
            kind: .context(label: label)
        ))
    }

    private static func addUnknownContext(_ value: [String: Any], timestamp: Date?, into result: inout ParsedLog) {
        let fallback = text(from: value)
        if !fallback.isEmpty { addContext(fallback, label: "未対応データ", timestamp: timestamp, into: &result) }
    }

    private static func content(ofTag tag: String, in text: String) -> String? {
        guard let opening = text.range(of: "<\(tag)>"),
              let closing = text.range(of: "</\(tag)>", range: opening.upperBound..<text.endIndex)
        else { return nil }
        return String(text[opening.upperBound..<closing.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingTag(named tag: String, from text: String) -> String {
        guard let opening = text.range(of: "<\(tag)>"),
              let closing = text.range(of: "</\(tag)>", range: opening.upperBound..<text.endIndex)
        else { return text }
        var copy = text
        copy.removeSubrange(opening.lowerBound..<closing.upperBound)
        return copy
    }

    private static func firstEmbeddedTimestamp(in value: Any?) -> Date? {
        if let string = value as? String { return embeddedTimestamp(in: string) }
        if let dictionary = value as? [String: Any] {
            return firstEmbeddedTimestamp(in: dictionary["content"] ?? dictionary["text"])
        }
        if let array = value as? [Any] {
            for item in array {
                if let timestamp = firstEmbeddedTimestamp(in: item) { return timestamp }
            }
        }
        return nil
    }

    private static func embeddedTimestamp(in text: String) -> Date? {
        guard let value = content(ofTag: "timestamp", in: text) else { return nil }
        let pattern = #"\s*\(UTC([+-]\d{1,2})\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let fullRange = Range(match.range(at: 0), in: value),
              let offsetRange = Range(match.range(at: 1), in: value),
              let offsetHours = Int(value[offsetRange])
        else { return nil }

        let dateText = String(value[..<fullRange.lowerBound])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: offsetHours * 3_600)
        formatter.dateFormat = "EEEE, MMM d, yyyy, h:mm a"
        return formatter.date(from: dateText)
    }

    private static func addToolCall(
        name: String,
        detail: String,
        timestamp: Date?,
        into result: inout ParsedLog
    ) {
        let clean = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        result.conversation.append(ConversationEntry(
            speaker: .system,
            text: clean.isEmpty ? "入力なし" : clean,
            timestamp: timestamp,
            kind: .toolCall(name: name)
        ))
    }

    private static func addToolResult(
        _ output: String,
        result operationResult: OperationResult,
        timestamp: Date?,
        into result: inout ParsedLog
    ) {
        let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
        result.conversation.append(ConversationEntry(
            speaker: .system,
            text: clean.isEmpty ? "出力なし" : clean,
            timestamp: timestamp,
            kind: .toolResult(result: operationResult)
        ))
    }

    private static func addOperation(
        name: String,
        detail: String,
        result operationResult: OperationResult,
        timestamp: Date?,
        into result: inout ParsedLog
    ) {
        let lower = name.lowercased()
        let category: OperationCategory
        if lower.contains("read") || lower.contains("search") || lower.contains("find") || lower.contains("grep") || lower.contains("list") {
            category = .investigation
        } else if lower.contains("edit") || lower.contains("write") || lower.contains("patch") || lower.contains("delete") {
            category = .edit
        } else if lower.contains("test") || lower.contains("build") {
            category = .test
        } else if lower.contains("exec") || lower.contains("shell") || lower.contains("command") || lower.contains("bash") {
            category = .command
        } else {
            category = .other
        }
        let cleanDetail = excerpt(detail.replacingOccurrences(of: "\n", with: " "), maximum: 140)
        let summary = cleanDetail.isEmpty ? "\(name)を実行" : "\(name): \(cleanDetail)"
        result.operations.append(OperationEntry(category: category, summary: summary, result: operationResult, timestamp: timestamp))
    }

    private static func isEditTool(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("edit") || lower.contains("write") || lower.contains("patch") || lower.contains("delete")
    }

    private static func collectPaths(in value: Any, into paths: inout Set<ChangedFile>) {
        if let dictionary = value as? [String: Any] {
            for (key, item) in dictionary {
                let normalized = key.lowercased()
                if ["path", "file", "file_path", "filepath"].contains(normalized),
                   let path = item as? String,
                   looksLikePath(path) {
                    paths.insert(ChangedFile(path: path))
                }
                collectPaths(in: item, into: &paths)
            }
        } else if let array = value as? [Any] {
            for item in array { collectPaths(in: item, into: &paths) }
        }
    }

    private static func looksLikePath(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count < 1_000 && (value.hasPrefix("/") || value.contains("/")) && !value.contains("\n")
    }

    private static func speaker(_ raw: String?) -> Speaker? {
        switch raw?.lowercased() {
        case "user", "human": .user
        case "assistant", "ai", "model": .assistant
        case "system", "developer": .system
        default: nil
        }
    }

    private static func text(from value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let array = value as? [Any] {
            return array.compactMap { item -> String? in
                if let dictionary = item as? [String: Any] {
                    let type = dictionary["type"] as? String
                    if type == "text" || type == "input_text" || type == "output_text" {
                        return dictionary["text"] as? String
                    }
                    return dictionary["content"] as? String
                }
                return item as? String
            }.joined(separator: "\n")
        }
        if let dictionary = value as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return ""
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = value as? TimeInterval {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
        }
        guard let string = value as? String else { return nil }
        if let numeric = Double(string) {
            return Date(timeIntervalSince1970: numeric > 10_000_000_000 ? numeric / 1_000 : numeric)
        }
        return ISO8601DateFormatter().date(from: string)
    }

    static func excerpt(_ text: String, maximum: Int = 180) -> String {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maximum else { return collapsed }
        return String(collapsed.prefix(maximum)) + "…"
    }

    static func readText(at url: URL, byteLimit: Int) throws -> (String, Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SessionShelfError.unreadable(url.lastPathComponent)
        }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        let truncated = data.count > byteLimit
        let limited = truncated ? data.prefix(byteLimit) : data[...]
        // 途中で切れたUTF-8の末尾は、復元可能な範囲だけ表示する。
        let text = String(decoding: limited, as: UTF8.self)
        return (text, truncated)
    }
}
