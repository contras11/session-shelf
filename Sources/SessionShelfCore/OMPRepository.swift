import Foundation

struct OMPSessionFile: Hashable {
    let jsonl: URL
    let stem: String
    let encodedProject: String

    init?(url: URL, sessionsRoot: URL, fileManager: FileManager) {
        let file = url.standardizedFileURL
        let projectDirectory = file.deletingLastPathComponent()
        guard projectDirectory.deletingLastPathComponent().standardizedFileURL.path == sessionsRoot.standardizedFileURL.path,
              projectDirectory.standardizedFileURL.path != sessionsRoot.standardizedFileURL.path else { return nil }
        let name = file.lastPathComponent
        guard file.pathExtension.lowercased() == "jsonl", !name.hasPrefix(".") else { return nil }
        guard name.wholeMatch(of: #/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.jsonl$/#) != nil else { return nil }
        if (try? fileManager.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            return nil
        }
        jsonl = file
        stem = file.deletingPathExtension().lastPathComponent
        encodedProject = projectDirectory.lastPathComponent
    }

    func logsDirectory(fileManager: FileManager) -> URL? {
        let sibling = jsonl.deletingPathExtension()
        guard (try? fileManager.attributesOfItem(atPath: sibling.path)[.type] as? FileAttributeType) == .typeDirectory else {
            return nil
        }
        return sibling.standardizedFileURL
    }
}

enum OMPRepository {
    static func sessionsRoot(home: URL) -> URL {
        home.appendingPathComponent(".omp/agent/sessions", isDirectory: true)
    }

    /// 観測した符号化: realpath の先頭スラッシュを外し、`/` を `-` に置換して `--` で囲む。
    static func decodeProject(_ encoded: String, fileManager: FileManager = .default) -> String? {
        if encoded == "-" { return nil }
        guard encoded.count >= 4, encoded.hasPrefix("--"), encoded.hasSuffix("--") else { return encoded }
        let inner = String(encoded.dropFirst(2).dropLast(2))
        if let existing = longestExistingPath(inner, fileManager: fileManager) { return existing }
        return "/" + inner.replacingOccurrences(of: "-", with: "/")
    }

    /// `-` は `/` にもフォルダ名のハイフンにもなる。各階層で、残りの文字列に一致する最長の実在フォルダ名を選ぶ。
    private static func longestExistingPath(_ inner: String, fileManager: FileManager) -> String? {
        var current = "/"
        var rest = inner[...]
        while !rest.isEmpty {
            guard let names = try? fileManager.contentsOfDirectory(atPath: current) else { return nil }
            guard let match = names.filter({ name in
                rest == name[...] || rest.hasPrefix(name + "-")
            }).max(by: { $0.count < $1.count }) else { return nil }
            current = URL(fileURLWithPath: current).appendingPathComponent(match).path
            if rest == match[...] {
                rest = rest[rest.endIndex...]
            } else {
                let next = rest.index(rest.startIndex, offsetBy: match.count + 1)
                rest = rest[next...]
            }
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: current, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return current
    }

    static func scan(
        home: URL,
        fileManager: FileManager,
        modifiedDate: (URL) -> Date,
        isRecentlyModified: (URL) -> Bool,
        liveProjects: Set<String>
    ) -> [SessionSummary] {
        let root = sessionsRoot(home: home)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var sessions: [SessionSummary] = []
        for directory in children(of: root, fileManager: fileManager) {
            for candidate in children(of: directory, fileManager: fileManager) {
                guard let file = OMPSessionFile(url: candidate, sessionsRoot: root, fileManager: fileManager) else { continue }
                let parsed = try? LogParsing.parseJSONL(at: file.jsonl, tool: .omp, byteLimit: LogLimits.listBytes)
                let logs = file.logsDirectory(fileManager: fileManager)
                let project = decodeProject(file.encodedProject, fileManager: fileManager)
                let live = project.map { liveProjects.contains(LiveSessions.canonicalPath($0)) } ?? false
                let recent = isRecentlyModified(file.jsonl) || logs.map(isRecentlyModified) == true
                let protected = live || recent
                sessions.append(SessionSummary(
                    id: "omp:\(file.jsonl.path)",
                    tool: .omp,
                    title: parsed?.title ?? "名称未設定のセッション",
                    date: modifiedDate(file.jsonl),
                    byteCount: Int64((try? file.jsonl.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                    project: project,
                    overview: parsed?.overview ?? "会話の概要を取得できませんでした",
                    sourceURL: file.jsonl,
                    relatedURLs: logs.map { [$0] } ?? [],
                    isProtected: protected,
                    protectionReason: live ? LiveSessions.reason : (recent ? "更新中の可能性があるセッション" : nil)
                ))
            }
        }
        return sessions
    }

    static func isAllowedDeletionURL(_ url: URL, home: URL, fileManager: FileManager) -> Bool {
        OMPSessionFile(url: url, sessionsRoot: sessionsRoot(home: home), fileManager: fileManager) != nil
    }

    static func isAllowedRelatedURL(_ url: URL, for session: SessionSummary, home: URL, fileManager: FileManager) -> Bool {
        guard let file = OMPSessionFile(url: session.sourceURL, sessionsRoot: sessionsRoot(home: home), fileManager: fileManager),
              let logs = file.logsDirectory(fileManager: fileManager) else { return false }
        return logs.path == url.standardizedFileURL.path
    }

    private static func children(of directory: URL, fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])) ?? []
    }
}

/// `parentId` はファイル内のレコード連鎖で、親セッションではない。
enum OMPRecordParser {
    static func parse(_ object: [String: Any], into result: inout ParsedLog) {
        switch object["type"] as? String {
        case "title":
            if result.title == nil, let title = object["title"] as? String, !title.isEmpty { result.title = title }
        case "title_change":
            if let title = object["title"] as? String, !title.isEmpty { result.title = title }
        case "message":
            let message = object["message"] as? [String: Any] ?? [:]
            let timestamp = LogParsing.date(object["timestamp"] ?? message["timestamp"])
            parseMessage(message, timestamp: timestamp, into: &result)
        default:
            break
        }
    }

    private static func parseMessage(_ message: [String: Any], timestamp: Date?, into result: inout ParsedLog) {
        let content = message["content"]
        switch (message["role"] as? String)?.lowercased() {
        case "user":
            LogParsing.addNormalizedText(LogParsing.text(from: content), speaker: .user, timestamp: timestamp, into: &result)
        case "assistant":
            parseAssistantContent(content, timestamp: timestamp, into: &result)
        case "toolresult":
            let failed = message["isError"] as? Bool ?? false
            let output = LogParsing.text(from: content)
            LogParsing.addToolResult(output, result: failed ? .failure : .success, timestamp: timestamp, into: &result)
            result.operations.append(OperationEntry(category: .other, summary: "ツールの実行結果", result: failed ? .failure : .success, timestamp: timestamp))
        case "developer":
            LogParsing.addContext(LogParsing.text(from: content), label: "開発者指示", timestamp: timestamp, into: &result)
        default:
            break
        }
    }

    private static func parseAssistantContent(_ content: Any?, timestamp: Date?, into result: inout ParsedLog) {
        if let string = content as? String {
            LogParsing.addConversation(string, speaker: .assistant, timestamp: timestamp, into: &result)
            return
        }
        for block in content as? [[String: Any]] ?? [] {
            switch (block["type"] as? String)?.lowercased() {
            case "text":
                LogParsing.addConversation(block["text"] as? String ?? "", speaker: .assistant, timestamp: timestamp, into: &result)
            case "thinking":
                LogParsing.addThinking(block["thinking"] as? String ?? "", timestamp: timestamp, into: &result)
            case "toolcall":
                let name = block["name"] as? String ?? "ツール"
                let arguments = block["arguments"] ?? block["input"]
                let detail = LogParsing.text(from: arguments)
                LogParsing.addToolCall(name: name, detail: detail, timestamp: timestamp, into: &result)
                LogParsing.addOperation(name: name, detail: detail, result: .unknown, timestamp: timestamp, into: &result)
                if LogParsing.isEditTool(name) { LogParsing.collectPaths(in: arguments as Any, into: &result.changedFiles) }
            default:
                break
            }
        }
    }
}
