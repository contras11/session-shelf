import AppKit
import Foundation

public struct SessionRepository: @unchecked Sendable {
    public let homeDirectory: URL
    private let fileManager: FileManager

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.fileManager = .default
    }

    public func scanAll() -> [ToolShelf] {
        AITool.allCases.map(scan)
    }

    public func scan(_ tool: AITool) -> ToolShelf {
        switch tool {
        case .codex: scanCodex()
        case .claudeCode: scanClaude()
        case .cursorDesktop: scanCursorDesktop()
        case .cursorCLI: scanCursorCLI()
        case .grokBuildCLI: scanGrok()
        }
    }

    public func loadDetail(for session: SessionSummary) throws -> SessionDetail {
        guard session.isSupported else {
            throw SessionShelfError.unsupported(session.overview)
        }
        let parsed: ParsedLog
        switch (session.tool, session.kind) {
        case (.cursorDesktop, .plan):
            parsed = try LogParsing.parseMarkdown(at: session.sourceURL)
        case (.grokBuildCLI, _):
            parsed = try LogParsing.parseGrokDirectory(session.sourceURL)
        default:
            parsed = try LogParsing.parseJSONL(at: session.sourceURL, tool: session.tool)
        }
        let raw = try LogParsing.rawText(for: session)
        return SessionDetail(
            conversation: parsed.conversation,
            operations: parsed.operations,
            changedFiles: parsed.changedFiles.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            rawLog: raw.0,
            wasTruncated: parsed.wasTruncated || raw.1
        )
    }

    public func moveToTrash(_ session: SessionSummary) throws {
        if session.isProtected {
            throw SessionShelfError.protectedItem(session.protectionReason ?? "作業中または設定データ")
        }
        guard session.isSupported, isAllowedDeletionURL(session.deletionURL, for: session.tool) else {
            throw SessionShelfError.outsideAllowedLocation
        }
        var resultingURL: NSURL?
        try fileManager.trashItem(at: session.deletionURL, resultingItemURL: &resultingURL)
    }

    public func candidatePaths(for tool: AITool) -> [String] {
        let home = homeDirectory.path
        return switch tool {
        case .codex:
            ["\(home)/.codex/sessions", "\(home)/.codex/archived_sessions"]
        case .claudeCode:
            ["\(home)/.claude/projects", "\(home)/.claude/sessions"]
        case .cursorDesktop:
            ["\(home)/.cursor/plans", "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"]
        case .cursorCLI:
            ["\(home)/.cursor/projects/*/agent-transcripts", "\(home)/.cursor/chats"]
        case .grokBuildCLI:
            ["\(home)/.grok/sessions"]
        }
    }

    private func scanCodex() -> ToolShelf {
        let roots = [
            homeDirectory.appendingPathComponent(".codex/sessions"),
            homeDirectory.appendingPathComponent(".codex/archived_sessions")
        ]
        var sessions: [SessionSummary] = []
        for root in roots where exists(root) {
            let archived = root.lastPathComponent == "archived_sessions"
            for url in files(under: root, extensions: ["jsonl"]) {
                sessions.append(makeJSONSummary(at: url, tool: .codex, activeProtection: !archived))
            }
        }
        return shelf(.codex, sessions: sessions)
    }

    private func scanClaude() -> ToolShelf {
        let roots = [
            homeDirectory.appendingPathComponent(".claude/projects"),
            homeDirectory.appendingPathComponent(".claude/sessions")
        ]
        var sessions: [SessionSummary] = []
        for root in roots where exists(root) {
            for url in files(under: root, extensions: ["jsonl"])
            where !url.path.contains("/subagents/") {
                sessions.append(makeJSONSummary(at: url, tool: .claudeCode, activeProtection: true))
            }
        }
        return shelf(.claudeCode, sessions: sessions)
    }

    private func scanCursorDesktop() -> ToolShelf {
        let plans = homeDirectory.appendingPathComponent(".cursor/plans")
        var sessions: [SessionSummary] = []
        if exists(plans) {
            for url in files(under: plans, extensions: ["md"]) {
                let parsed = try? LogParsing.parseMarkdown(at: url, byteLimit: LogLimits.listBytes)
                sessions.append(SessionSummary(
                    id: "cursor-plan:\(url.path)",
                    tool: .cursorDesktop,
                    kind: .plan,
                    title: parsed?.title ?? url.deletingPathExtension().lastPathComponent,
                    date: modifiedDate(url),
                    byteCount: size(url),
                    project: nil,
                    overview: parsed?.overview ?? "CursorのプランMarkdown",
                    sourceURL: url,
                    isProtected: isRecentlyModified(url),
                    protectionReason: isRecentlyModified(url) ? "更新直後のプラン" : nil
                ))
            }
        }

        let database = homeDirectory.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        if exists(database) {
            sessions.append(SessionSummary(
                id: "cursor-desktop-database",
                tool: .cursorDesktop,
                title: "Cursor Desktop 会話データ",
                date: modifiedDate(database),
                byteCount: size(database),
                project: nil,
                overview: "未対応の保存形式（Cursor内部SQLite）。設定・状態データを含むため保護しています。",
                sourceURL: database,
                isSupported: false,
                isProtected: true,
                protectionReason: "設定・状態データを含むSQLite"
            ))
        }
        return shelf(.cursorDesktop, sessions: sessions)
    }

    private func scanCursorCLI() -> ToolShelf {
        let projects = homeDirectory.appendingPathComponent(".cursor/projects")
        let chats = homeDirectory.appendingPathComponent(".cursor/chats")
        var sessions: [SessionSummary] = []
        if exists(projects) {
            for url in files(under: projects, extensions: ["jsonl"])
            where url.path.contains("/agent-transcripts/") && !url.path.contains("/subagents/") {
                sessions.append(makeJSONSummary(at: url, tool: .cursorCLI, activeProtection: true))
            }
        }
        if exists(chats) {
            for database in files(under: chats, extensions: ["db"]) where database.lastPathComponent == "store.db" {
                let sessionDirectory = database.deletingLastPathComponent()
                let meta = cursorMeta(in: sessionDirectory)
                sessions.append(SessionSummary(
                    id: "cursor-cli-db:\(sessionDirectory.path)",
                    tool: .cursorCLI,
                    title: meta.title ?? "Cursor CLI 会話データ",
                    date: meta.date ?? modifiedDate(database),
                    byteCount: directorySize(sessionDirectory),
                    project: meta.cwd,
                    overview: "未対応の保存形式（Cursor CLI内部SQLite）。安全のため削除対象外です。",
                    sourceURL: database,
                    deletionURL: sessionDirectory,
                    isSupported: false,
                    isProtected: true,
                    protectionReason: "内部SQLiteと付随状態を含むため"
                ))
            }
        }
        return shelf(.cursorCLI, sessions: sessions)
    }

    private func scanGrok() -> ToolShelf {
        let root = homeDirectory.appendingPathComponent(".grok/sessions")
        guard exists(root) else { return shelf(.grokBuildCLI, sessions: []) }
        var sessions: [SessionSummary] = []
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent == "summary.json" else { continue }
            let directory = url.deletingLastPathComponent()
            let parsed = try? LogParsing.parseGrokDirectory(directory, byteLimit: LogLimits.listBytes)
            let protected = isRecentlyModified(url)
            sessions.append(SessionSummary(
                id: "grok:\(directory.path)",
                tool: .grokBuildCLI,
                title: parsed?.title ?? "Grok Build セッション",
                date: modifiedDate(url),
                byteCount: directorySize(directory),
                project: parsed?.project ?? decodedProject(from: directory.deletingLastPathComponent().lastPathComponent),
                overview: parsed?.overview ?? "Grok Build CLIのセッション",
                sourceURL: directory,
                deletionURL: directory,
                isProtected: protected,
                protectionReason: protected ? "更新中の可能性があるセッション" : nil
            ))
            enumerator?.skipDescendants()
        }
        return shelf(.grokBuildCLI, sessions: sessions)
    }

    private func makeJSONSummary(at url: URL, tool: AITool, activeProtection: Bool) -> SessionSummary {
        let parsed = try? LogParsing.parseJSONL(at: url, tool: tool, byteLimit: LogLimits.listBytes)
        let project = parsed?.project ?? inferredProject(from: url, tool: tool)
        let protected = activeProtection && isRecentlyModified(url)
        return SessionSummary(
            id: "\(tool.rawValue):\(url.path)",
            tool: tool,
            title: parsed?.title ?? "名称未設定のセッション",
            date: modifiedDate(url),
            byteCount: size(url),
            project: project,
            overview: parsed?.overview ?? "会話の概要を取得できませんでした",
            sourceURL: url,
            isProtected: protected,
            protectionReason: protected ? "更新中の可能性があるセッション" : nil
        )
    }

    private func shelf(_ tool: AITool, sessions: [SessionSummary]) -> ToolShelf {
        let sorted = sessions.sorted { $0.date > $1.date }
        let candidates = candidatePaths(for: tool)
        let anyPathExists = candidates.contains { candidate in
            let concrete = candidate.replacingOccurrences(of: "/*/agent-transcripts", with: "")
            return fileManager.fileExists(atPath: concrete)
        }
        let status: DetectionStatus
        if !sorted.isEmpty {
            status = .detected(count: sorted.count)
        } else if anyPathExists {
            status = .unsupportedFormat(details: "保存場所はありますが、対応するセッションを読み取れませんでした")
        } else {
            status = .notDetected
        }
        return ToolShelf(tool: tool, status: status, candidatePaths: candidates, sessions: sorted)
    }

    private func files(under root: URL, extensions: Set<String>) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var urls: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if extensions.contains(url.pathExtension.lowercased()) { urls.append(url) }
        }
        return urls
    }

    private func cursorMeta(in directory: URL) -> (title: String?, cwd: String?, date: Date?) {
        let url = directory.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }
        let milliseconds = object["updatedAtMs"] as? Double
        return (
            object["title"] as? String,
            object["cwd"] as? String,
            milliseconds.map { Date(timeIntervalSince1970: $0 / 1_000) }
        )
    }

    private func inferredProject(from url: URL, tool: AITool) -> String? {
        switch tool {
        case .claudeCode:
            let projectFolder = url.deletingLastPathComponent().lastPathComponent
            return decodedProject(from: projectFolder)
        case .cursorCLI:
            let components = url.pathComponents
            guard let index = components.firstIndex(of: "projects"), components.indices.contains(index + 1) else { return nil }
            return decodedProject(from: components[index + 1])
        default:
            return nil
        }
    }

    private func decodedProject(from encoded: String) -> String? {
        if let decoded = encoded.removingPercentEncoding, decoded.hasPrefix("/") { return decoded }
        guard encoded.hasPrefix("-") || encoded.hasPrefix("Users-") else { return nil }
        let components = encoded.split(separator: "-").map(String.init)
        guard !components.isEmpty else { return nil }

        // ディレクトリ名中のハイフンを破壊しないよう、実在する名前を各階層で最長一致させる。
        var resolved: [String] = []
        var index = 0
        while index < components.count {
            let base = "/" + resolved.joined(separator: "/") + (resolved.isEmpty ? "" : "/")
            var matched = false
            var end = components.count
            while end > index {
                let candidate = components[index..<end].joined(separator: "-")
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: base + candidate, isDirectory: &isDirectory), isDirectory.boolValue {
                    resolved.append(candidate)
                    index = end
                    matched = true
                    break
                }
                end -= 1
            }
            if !matched {
                resolved.append(contentsOf: components[index...])
                index = components.count
            }
        }
        let decoded = "/" + resolved.joined(separator: "/")
        // 実在しないパスしか組み立てられない場合は、推測で壊すより元のフォルダ名を表示する。
        return fileManager.fileExists(atPath: decoded) ? decoded : encoded
    }

    private func exists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }

    private func modifiedDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    private func isRecentlyModified(_ url: URL) -> Bool {
        Date().timeIntervalSince(modifiedDate(url)) < 30 * 60
    }

    private func isAllowedDeletionURL(_ url: URL, for tool: AITool) -> Bool {
        let item = url.standardizedFileURL.path
        let roots: [URL]
        switch tool {
        case .codex:
            roots = [homeDirectory.appendingPathComponent(".codex/sessions"), homeDirectory.appendingPathComponent(".codex/archived_sessions")]
        case .claudeCode:
            roots = [homeDirectory.appendingPathComponent(".claude/projects"), homeDirectory.appendingPathComponent(".claude/sessions")]
        case .cursorDesktop:
            roots = [homeDirectory.appendingPathComponent(".cursor/plans")]
        case .cursorCLI:
            roots = [homeDirectory.appendingPathComponent(".cursor/projects")]
        case .grokBuildCLI:
            roots = [homeDirectory.appendingPathComponent(".grok/sessions")]
        }
        return roots.contains { root in
            let base = root.standardizedFileURL.path + "/"
            return item.hasPrefix(base) && item != root.standardizedFileURL.path
        }
    }
}
