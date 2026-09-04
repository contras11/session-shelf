import AppKit
import Foundation
import CSQLite3

public struct SessionRepository: @unchecked Sendable {
    public let homeDirectory: URL
    private let fileManager: FileManager
    private let openCodeExecutables: [URL]
    private let openCodeDeletionTimeout: TimeInterval

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        openCodeExecutables: [URL]? = nil,
        executableSearchPath: String? = ProcessInfo.processInfo.environment["PATH"],
        openCodeDeletionTimeout: TimeInterval = 15
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.fileManager = .default
        self.openCodeExecutables = OpenCodeExecutableLocator.candidates(
            explicitExecutables: openCodeExecutables,
            searchPath: executableSearchPath
        )
        self.openCodeDeletionTimeout = openCodeDeletionTimeout
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
        case .openCode: scanOpenCode()
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
        case (.openCode, _):
            parsed = try OpenCodeRepository.loadDetail(session: session)
        default:
            parsed = try LogParsing.parseJSONL(at: session.sourceURL, tool: session.tool)
        }
        let raw: (String, Bool) = session.tool == .openCode ? (try OpenCodeRepository.raw(session: session), false) : (try LogParsing.rawText(for: session))
        return SessionDetail(
            conversation: parsed.conversation,
            operations: parsed.operations,
            changedFiles: parsed.changedFiles.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            rawLog: raw.0,
            wasTruncated: parsed.wasTruncated || raw.1,
            planDocument: parsed.planDocument
        )
    }

    public func moveToTrash(_ session: SessionSummary) throws {
        guard session.tool != .openCode else { throw SessionShelfError.protectedItem("OpenCodeは公式CLIによる完全削除のみ対応しています") }
        if session.isProtected {
            throw SessionShelfError.protectedItem(session.protectionReason ?? "作業中または設定データ")
        }
        guard session.isSupported, isAllowedDeletionURL(session.deletionURL, for: session.tool) else {
            throw SessionShelfError.outsideAllowedLocation
        }
        try validatePrimaryDeletionTarget(session)
        var pending: [URL] = []
        for related in session.relatedURLs {
            guard exists(related) else { continue }
            guard isAllowedRelatedURL(related, for: session) else {
                throw SessionShelfError.outsideAllowedLocation
            }
            try validateRelatedDeletionTarget(related)
            pending.append(related)
        }
        if session.deletionURL.standardizedFileURL != observedURL(for: session).standardizedFileURL {
            try validateFreshness(session.deletionURL, expectedDate: nil)
        }
        for related in pending {
            guard exists(related) else { continue }
            try trash(related)
        }
        try trash(session.deletionURL)
    }

    public func delete(_ session: SessionSummary, mode: SessionDeletionMode) throws {
        guard mode == session.deletionMode else { throw SessionShelfError.protectedItem("削除対象の状態が変わりました") }
        guard session.tool == .openCode, case .openCodeCLI(let id) = mode else { return try moveToTrash(session) }
        let db = session.sourceURL
        try OpenCodeRepository.delete(
            sessionID: id,
            database: db,
            expectedUpdated: session.date,
            executables: openCodeExecutables,
            timeout: openCodeDeletionTimeout
        )
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
        case .openCode:
            ["\(home)/.local/share/opencode/opencode.db"]
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

    private func scanOpenCode() -> ToolShelf {
        let db = homeDirectory.appendingPathComponent(".local/share/opencode/opencode.db")
        guard exists(db) else { return shelf(.openCode, sessions: []) }
        do { return shelf(.openCode, sessions: try OpenCodeRepository.scan(database: db)) }
        catch { return ToolShelf(tool: .openCode, status: .unsupportedFormat(details: "OpenCode DBを安全に読み取れませんでした"), candidatePaths: candidatePaths(for: .openCode), sessions: []) }
    }

    private func makeJSONSummary(at url: URL, tool: AITool, activeProtection: Bool) -> SessionSummary {
        let parsed = try? LogParsing.parseJSONL(at: url, tool: tool, byteLimit: LogLimits.listBytes)
        let project = parsed?.project ?? inferredProject(from: url, tool: tool)
        let protected = activeProtection && isRecentlyModified(url)
        let deletionURL = cursorCLIDeletionURL(for: url, tool: tool)
        let related = relatedURLs(for: url, tool: tool)
        let bytes: Int64
        if let deletionURL, deletionURL.standardizedFileURL != url.standardizedFileURL {
            bytes = itemSize(deletionURL)
        } else {
            bytes = size(url) + related.reduce(0) { $0 + itemSize($1) }
        }
        return SessionSummary(
            id: "\(tool.rawValue):\(url.path)",
            tool: tool,
            title: parsed?.title ?? "名称未設定のセッション",
            date: modifiedDate(url),
            byteCount: bytes,
            project: project,
            overview: parsed?.overview ?? "会話の概要を取得できませんでした",
            sourceURL: url,
            deletionURL: deletionURL,
            relatedURLs: related,
            lineage: parsed?.lineage,
            isProtected: protected,
            protectionReason: protected ? "更新中の可能性があるセッション" : nil
        )
    }

    private func cursorCLIDeletionURL(for url: URL, tool: AITool) -> URL? {
        guard tool == .cursorCLI else { return nil }
        let directory = url.deletingLastPathComponent()
        guard directory.lastPathComponent != "agent-transcripts",
              isAllowedDeletionURL(directory, for: .cursorCLI) else {
            return url
        }
        return directory
    }

    private func relatedURLs(for url: URL, tool: AITool) -> [URL] {
        switch tool {
        case .claudeCode:
            return claudeRelatedURLs(for: url)
        case .codex:
            return codexRelatedURLs(for: url)
        default:
            return []
        }
    }

    private func claudeRelatedURLs(for url: URL) -> [URL] {
        let uuid = url.deletingPathExtension().lastPathComponent
        guard !uuid.isEmpty else { return [] }
        var related: [URL] = []
        let sibling = url.deletingPathExtension()
        if exists(sibling), sibling.standardizedFileURL != url.standardizedFileURL {
            related.append(sibling.standardizedFileURL)
        }
        for folder in ["file-history", "session-env", "tasks"] {
            let extra = homeDirectory.appendingPathComponent(".claude/\(folder)/\(uuid)")
            if exists(extra) {
                related.append(extra.standardizedFileURL)
            }
        }
        return related
    }

    private func codexRelatedURLs(for url: URL) -> [URL] {
        guard let threadID = codexThreadID(from: url) else { return [] }
        let snapshots = homeDirectory.appendingPathComponent(".codex/shell_snapshots")
        guard exists(snapshots) else { return [] }
        let children = (try? fileManager.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        )) ?? []
        return children.filter { child in
            let name = child.lastPathComponent
            return name == threadID || name.hasPrefix(threadID + ".")
        }.map(\.standardizedFileURL)
    }

    private func codexThreadID(from url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let regex = try? NSRegularExpression(
            pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        ) else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.matches(in: name, range: range).last,
              let matchRange = Range(match.range, in: name) else { return nil }
        return String(name[matchRange])
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
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
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

    private func itemSize(_ url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        return isDirectory.boolValue ? directorySize(url) : size(url)
    }

    private func observedURL(for session: SessionSummary) -> URL {
        if session.tool == .grokBuildCLI {
            return session.sourceURL.appendingPathComponent("summary.json")
        }
        return session.sourceURL
    }

    private func validatePrimaryDeletionTarget(_ session: SessionSummary) throws {
        let observed = observedURL(for: session)
        guard exists(observed) else { throw SessionShelfError.unreadable("削除対象が見つかりません") }
        try validateFreshness(observed, expectedDate: session.date)
    }

    private func validateRelatedDeletionTarget(_ url: URL) throws {
        try validateFreshness(url, expectedDate: nil)
    }

    private func validateFreshness(_ url: URL, expectedDate: Date?) throws {
        if isSymbolicLink(url) {
            throw SessionShelfError.protectedItem("シンボリックリンクを含むため")
        }
        let current = modifiedDate(url)
        if let expectedDate, abs(current.timeIntervalSince(expectedDate)) >= 0.001 {
            throw SessionShelfError.storageItemChanged
        }
        if Date().timeIntervalSince(current) < 30 * 60 {
            throw SessionShelfError.protectedItem("更新中の可能性があるセッション")
        }
    }

    private func trash(_ url: URL) throws {
        if isSymbolicLink(url) {
            throw SessionShelfError.protectedItem("シンボリックリンクを含むため")
        }
        var resultingURL: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private func isStrictDescendant(_ url: URL, of root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path + "/"
        return path.hasPrefix(base) && path != root.standardizedFileURL.path
    }

    private func isAllowedRelatedURL(_ url: URL, for session: SessionSummary) -> Bool {
        let item = url.standardizedFileURL
        switch session.tool {
        case .claudeCode:
            let uuid = session.sourceURL.deletingPathExtension().lastPathComponent
            guard item.lastPathComponent == uuid else { return false }
            let sibling = session.sourceURL.deletingPathExtension().standardizedFileURL
            if item == sibling {
                return isAllowedDeletionURL(item, for: .claudeCode)
            }
            let extraRoots = ["file-history", "session-env", "tasks"].map {
                homeDirectory.appendingPathComponent(".claude/\($0)", isDirectory: true).standardizedFileURL
            }
            return extraRoots.contains { root in
                item.deletingLastPathComponent().standardizedFileURL == root && isStrictDescendant(item, of: root)
            }
        case .codex:
            let snapshots = homeDirectory.appendingPathComponent(".codex/shell_snapshots", isDirectory: true).standardizedFileURL
            return item.deletingLastPathComponent().standardizedFileURL == snapshots && isStrictDescendant(item, of: snapshots)
        default:
            return false
        }
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
        case .openCode:
            return false
        }
        return roots.contains { root in
            let base = root.standardizedFileURL.path + "/"
            return item.hasPrefix(base) && item != root.standardizedFileURL.path
        }
    }
}

enum OpenCodeExecutableLocator {
    private static let fixedPaths = [
        "/opt/homebrew/bin/opencode",
        "/usr/local/bin/opencode",
        "/opt/local/bin/opencode"
    ]

    static func candidates(explicitExecutables: [URL]?, searchPath: String?) -> [URL] {
        if let explicitExecutables {
            return unique(explicitExecutables)
        }

        var candidates: [URL] = []
        if let searchPath {
            for component in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
                let directory = String(component)
                // 空要素や相対パスを現在ディレクトリとして解釈しない。
                guard directory.hasPrefix("/") else { continue }
                candidates.append(
                    URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent("opencode", isDirectory: false)
                )
            }
        }
        candidates.append(contentsOf: fixedPaths.map(URL.init(fileURLWithPath:)))
        return unique(candidates)
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
    }
}
