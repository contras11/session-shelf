import AppKit
import Foundation

public struct StorageRepository: @unchecked Sendable {
    public typealias CancellationCheck = @Sendable () -> Bool

    fileprivate struct Measurement {
        let byteCount: Int64
        let fileCount: Int
        let modifiedAt: Date
        let containsSymbolicLink: Bool
        let issue: String?
    }

    fileprivate struct Classification {
        let category: StorageCategory
        let safety: StorageSafety
        let title: String
        let explanation: String
        let impact: String
        let reason: String
    }

    public let homeDirectory: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.fileManager = .default
        self.now = now
    }

    public func scanAll(shouldCancel: @escaping CancellationCheck = { false }) -> StorageScanReport {
        var items: [StorageItem] = []
        var issues: [StorageScanIssue] = []

        for tool in AITool.allCases {
            if shouldCancel() { return StorageScanReport(items: items, issues: issues, wasCancelled: true) }
            let root = storageRoot(for: tool)
            guard fileManager.fileExists(atPath: root.path) else { continue }
            for candidate in candidates(in: root, tool: tool) {
                if shouldCancel() { return StorageScanReport(items: items, issues: issues, wasCancelled: true) }
                let measurement = measure(candidate, shouldCancel: shouldCancel)
                if shouldCancel() { return StorageScanReport(items: items, issues: issues, wasCancelled: true) }
                if let issue = measurement.issue {
                    issues.append(StorageScanIssue(path: candidate.path, message: issue))
                }
                let relativePath = relativePath(of: candidate, under: root)
                var classification = StoragePolicy.classify(
                    tool: tool,
                    relativePath: relativePath,
                    url: candidate,
                    modifiedAt: measurement.modifiedAt,
                    containsSymbolicLink: measurement.containsSymbolicLink,
                    now: now(),
                    homeDirectory: homeDirectory,
                    fileManager: fileManager
                )
                if measurement.issue != nil {
                    classification = Classification(
                        category: .unknown,
                        safety: .protected,
                        title: candidate.lastPathComponent,
                        explanation: "一部の内容を確認できなかったデータです。",
                        impact: "Session Shelfからは削除できません。",
                        reason: "容量と内容を完全に確認できないため保護しています"
                    )
                }
                items.append(StorageItem(
                    id: "\(tool.rawValue):\(candidate.standardizedFileURL.path)",
                    tool: tool,
                    category: classification.category,
                    safety: classification.safety,
                    title: classification.title,
                    explanation: classification.explanation,
                    deletionImpact: classification.impact,
                    safetyReason: classification.reason,
                    byteCount: measurement.byteCount,
                    fileCount: measurement.fileCount,
                    modifiedAt: measurement.modifiedAt,
                    location: candidate.standardizedFileURL,
                    containsSymbolicLink: measurement.containsSymbolicLink
                ))
            }
        }

        return StorageScanReport(
            items: items.sorted {
                if $0.byteCount != $1.byteCount { return $0.byteCount > $1.byteCount }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            },
            issues: issues
        )
    }

    public func moveToTrash(_ item: StorageItem) throws {
        guard item.safety != .protected else {
            throw SessionShelfError.protectedItem(item.safetyReason)
        }
        let root = storageRoot(for: item.tool)
        guard isStrictDescendant(item.location, of: root), !isToolRoot(item.location) else {
            throw SessionShelfError.outsideAllowedLocation
        }
        let measurement = measure(item.location, shouldCancel: { false })
        guard measurement.issue == nil else {
            throw SessionShelfError.protectedItem("内容を完全に確認できないため")
        }
        let current = StoragePolicy.classify(
            tool: item.tool,
            relativePath: relativePath(of: item.location, under: root),
            url: item.location,
            modifiedAt: measurement.modifiedAt,
            containsSymbolicLink: measurement.containsSymbolicLink,
            now: now(),
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        guard current.safety == item.safety,
              measurement.byteCount == item.byteCount,
              measurement.fileCount == item.fileCount,
              abs(measurement.modifiedAt.timeIntervalSince(item.modifiedAt)) < 0.001 else {
            throw SessionShelfError.storageItemChanged
        }
        guard current.safety != .protected else {
            throw SessionShelfError.protectedItem(current.reason)
        }
        var resultingURL: NSURL?
        try fileManager.trashItem(at: item.location, resultingItemURL: &resultingURL)
    }

    private func storageRoot(for tool: AITool) -> URL {
        switch tool {
        case .codex: homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        case .claudeCode: homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        case .cursorDesktop, .cursorCLI: homeDirectory.appendingPathComponent(".cursor", isDirectory: true)
        case .grokBuildCLI: homeDirectory.appendingPathComponent(".grok", isDirectory: true)
        }
    }

    private func candidates(in root: URL, tool: AITool) -> [URL] {
        var topLevel = children(of: root)
        if tool == .cursorDesktop {
            let cliOwned: Set<String> = ["projects", "chats", "ai-tracking"]
            topLevel = topLevel.filter { !cliOwned.contains($0.lastPathComponent) }
        } else if tool == .cursorCLI {
            let cliOwned: Set<String> = ["projects", "chats", "ai-tracking"]
            topLevel = topLevel.filter { cliOwned.contains($0.lastPathComponent) }
        }
        var result: [URL] = []
        for child in topLevel {
            let name = child.lastPathComponent
            if tool == .codex, name == ".tmp" {
                result.append(contentsOf: codexTemporaryCandidates(in: child))
            } else if tool == .codex, name == "plugins" {
                result.append(contentsOf: children(of: child))
            } else if tool == .claudeCode, name == "plugins" {
                result.append(contentsOf: children(of: child))
            } else if (tool == .cursorDesktop || tool == .cursorCLI), name == "plugins" {
                result.append(contentsOf: children(of: child))
            } else if tool == .grokBuildCLI, name == "downloads" {
                result.append(contentsOf: children(of: child))
            } else {
                result.append(child)
            }
        }
        return result
    }

    private func codexTemporaryCandidates(in temporaryRoot: URL) -> [URL] {
        var result: [URL] = []
        for child in children(of: temporaryRoot) {
            if child.lastPathComponent == "bundled-marketplaces" {
                result.append(contentsOf: children(of: child))
            } else {
                result.append(child)
            }
        }
        return result
    }

    private func children(of directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )) ?? []
    }

    private func measure(_ url: URL, shouldCancel: CancellationCheck) -> Measurement {
        var byteCount: Int64 = 0
        var fileCount = 0
        var modifiedAt = modificationDate(url)
        var containsSymbolicLink = isSymbolicLink(url)
        var issue: String?

        if containsSymbolicLink {
            return Measurement(byteCount: 0, fileCount: 1, modifiedAt: modifiedAt, containsSymbolicLink: true, issue: nil)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return Measurement(byteCount: 0, fileCount: 0, modifiedAt: .distantPast, containsSymbolicLink: false, issue: "項目が見つかりません")
        }
        if !isDirectory.boolValue {
            byteCount = allocatedSize(url)
            fileCount = 1
            return Measurement(byteCount: byteCount, fileCount: fileCount, modifiedAt: modifiedAt, containsSymbolicLink: false, issue: nil)
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey
        ]
        let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            // アプリバンドルも実際に容量を使うため、中身を省略せず集計する。
            options: [],
            errorHandler: { _, error in
                issue = error.localizedDescription
                return true
            }
        )
        while let child = enumerator?.nextObject() as? URL {
            if shouldCancel() { break }
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else {
                issue = issue ?? "一部の項目を確認できませんでした"
                continue
            }
            if values.isSymbolicLink == true {
                containsSymbolicLink = true
                enumerator?.skipDescendants()
                continue
            }
            if let date = values.contentModificationDate, date > modifiedAt { modifiedAt = date }
            if values.isRegularFile == true {
                byteCount += Int64(values.fileAllocatedSize ?? values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                fileCount += 1
            }
        }
        return Measurement(
            byteCount: byteCount,
            fileCount: fileCount,
            modifiedAt: modifiedAt,
            containsSymbolicLink: containsSymbolicLink,
            issue: issue
        )
    }

    private func allocatedSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.fileAllocatedSize ?? values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let base = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    private func isStrictDescendant(_ url: URL, of root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path + "/"
        return path.hasPrefix(base) && path != root.standardizedFileURL.path
    }

    private func isToolRoot(_ url: URL) -> Bool {
        AITool.allCases.contains { storageRoot(for: $0).standardizedFileURL == url.standardizedFileURL }
    }
}

enum StoragePolicy {
    fileprivate static func classify(
        tool: AITool,
        relativePath: String,
        url: URL,
        modifiedAt: Date,
        containsSymbolicLink: Bool,
        now: Date,
        homeDirectory: URL,
        fileManager: FileManager
    ) -> StorageRepository.Classification {
        let path = relativePath.replacingOccurrences(of: "\\", with: "/")
        let components = path.split(separator: "/").map(String.init)
        let name = url.lastPathComponent

        if containsSymbolicLink {
            return protected(.unknown, title: knownTitle(for: path, name: name), explanation: "内部に別の場所を参照するリンクがあります。", reason: "リンク先を誤って変更しないため保護しています")
        }
        if now.timeIntervalSince(modifiedAt) < 30 * 60 {
            return protected(.applicationData, title: knownTitle(for: path, name: name), explanation: "直近30分以内に更新されています。", reason: "使用中または更新中の可能性があります")
        }

        switch tool {
        case .codex:
            return classifyCodex(path: path, components: components, name: name, modifiedAt: modifiedAt, now: now)
        case .claudeCode:
            return classifyClaude(path: path, name: name)
        case .cursorDesktop, .cursorCLI:
            return classifyCursor(path: path, name: name)
        case .grokBuildCLI:
            return classifyGrok(
                path: path,
                name: name,
                url: url,
                modifiedAt: modifiedAt,
                now: now,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
        }
    }

    private static func classifyCodex(path: String, components: [String], name: String, modifiedAt: Date, now: Date) -> StorageRepository.Classification {
        if path == "cache" || path == "plugins/cache" {
            return regeneratable(.cache, title: "Codexのキャッシュ", explanation: "一覧やプラグイン情報をすばやく表示するための再取得可能なデータです。")
        }
        if path.hasPrefix(".tmp/plugins-backup-") || path.contains(".tmp/bundled-marketplaces/") && name.contains(".staging-") {
            guard now.timeIntervalSince(modifiedAt) >= 7 * 24 * 60 * 60 else {
                return protected(.temporary, title: "Codexの新しい一時データ", explanation: "更新処理で作られた一時データです。", reason: "作成から7日未満のため保護しています")
            }
            return regeneratable(.temporary, title: "Codexの古い一時バックアップ", explanation: "更新処理後に残ったstagingまたはbackupです。")
        }
        if components.count == 1, name.hasPrefix("..codex-global-state.json.tmp-") {
            guard now.timeIntervalSince(modifiedAt) >= 7 * 24 * 60 * 60 else {
                return protected(.temporary, title: "Codexの新しい状態一時ファイル", explanation: "状態保存中に作られた一時ファイルです。", reason: "作成から7日未満のため保護しています")
            }
            return regeneratable(.temporary, title: "Codexの古い状態一時ファイル", explanation: "完了しなかった状態保存の残りと考えられるファイルです。")
        }
        if path == "generated_images" {
            return review(.generatedOutput, title: "Codexの生成画像", explanation: "画像生成で作成された元画像です。", impact: "ゴミ箱へ移すと、別の場所へ保存していない画像はCodexから参照できなくなる場合があります。")
        }
        if path == "log" || path == "logs" || path == "shell_snapshots" {
            return review(.diagnostic, title: "Codexの診断・シェル記録", explanation: "調査やシェル復元に使われる補助記録です。", impact: "過去の診断や一部のシェル状態を確認できなくなる場合があります。")
        }
        return protectedCategory(for: path, name: name)
    }

    private static func classifyClaude(path: String, name: String) -> StorageRepository.Classification {
        if path == "cache" || path == "plugins/cache" || name == "stats-cache.json" {
            return regeneratable(.cache, title: "Claude Codeのキャッシュ", explanation: "再取得または再作成できる補助データです。")
        }
        if path == "debug" || path == "shell-snapshots" || path == "backups" || path == "paste-cache" {
            return review(.diagnostic, title: "Claude Codeの補助記録", explanation: "診断、復元、貼り付け履歴などに使われる記録です。", impact: "過去の診断や復元に利用できなくなる場合があります。")
        }
        return protectedCategory(for: path, name: name)
    }

    private static func classifyCursor(path: String, name: String) -> StorageRepository.Classification {
        if path == "plugins/cache" || name == "statsig-cache.json" {
            return regeneratable(.cache, title: "Cursorのキャッシュ", explanation: "再取得または再作成できる補助データです。")
        }
        if path == "debug-logs" || path == "ai-tracking" {
            return review(.diagnostic, title: "Cursorの診断記録", explanation: "不具合調査や利用状況確認のための補助記録です。", impact: "過去の診断情報を確認できなくなる場合があります。")
        }
        return protectedCategory(for: path, name: name)
    }

    private static func classifyGrok(
        path: String,
        name: String,
        url: URL,
        modifiedAt: Date,
        now: Date,
        homeDirectory: URL,
        fileManager: FileManager
    ) -> StorageRepository.Classification {
        if path == "marketplace-cache" {
            return regeneratable(.cache, title: "Grokのマーケットプレイスキャッシュ", explanation: "プラグイン情報を再取得することで作り直せるデータです。")
        }
        if path.hasPrefix("downloads/") {
            let currentLink = homeDirectory.appendingPathComponent(".grok/bin/grok")
            let target = try? fileManager.destinationOfSymbolicLink(atPath: currentLink.path)
            let resolvedTarget = target.map { targetPath -> URL in
                if targetPath.hasPrefix("/") { return URL(fileURLWithPath: targetPath).standardizedFileURL }
                return currentLink.deletingLastPathComponent().appendingPathComponent(targetPath).standardizedFileURL
            }
            if resolvedTarget == url.standardizedFileURL || name == "grok-macos-aarch64" {
                return protected(.applicationData, title: "現在のGrok実行ファイル", explanation: "現在Grokの起動に使われている実行ファイルです。", reason: "削除するとGrokを起動できなくなるため保護しています")
            }
            guard name.hasPrefix("grok-") && now.timeIntervalSince(modifiedAt) >= 7 * 24 * 60 * 60 else {
                return protected(.applicationData, title: "Grokのダウンロードデータ", explanation: "Grok本体または更新用のデータです。", reason: "現行版との関係を安全に確認できないため保護しています")
            }
            return regeneratable(.cache, title: "以前のGrok実行ファイル", explanation: "現在参照されていない旧バージョンのダウンロードです。")
        }
        if path == "logs" || path == "memtrace" {
            return review(.diagnostic, title: "Grokの診断ログ", explanation: "不具合調査や動作確認に使われる記録です。", impact: "過去の診断情報を確認できなくなる場合があります。")
        }
        return protectedCategory(for: path, name: name)
    }

    private static func protectedCategory(for path: String, name: String) -> StorageRepository.Classification {
        let lower = path.lowercased()
        if lower.contains("auth") || lower.contains("config") || lower.contains("state") || lower.hasSuffix(".sqlite") || lower.hasSuffix(".db") {
            return protected(.configuration, title: knownTitle(for: path, name: name), explanation: "認証、設定、またはアプリ状態を含む可能性があります。", reason: "ログイン情報や設定を失わないため保護しています")
        }
        if lower.contains("skill") || lower.contains("plugin") || lower.contains("extension") || lower.contains("agent") || lower.contains("prompt") || lower.contains("rule") {
            return protected(.customization, title: knownTitle(for: path, name: name), explanation: "追加した機能やカスタマイズを含む可能性があります。", reason: "ユーザーが追加した内容を失わないため保護しています")
        }
        if lower.contains("session") || lower.contains("chat") || lower.contains("history") || lower.contains("attachment") {
            return protected(.conversation, title: knownTitle(for: path, name: name), explanation: "会話履歴または会話に添付されたデータです。", reason: "会話画面で内容を確認して個別に整理してください")
        }
        if lower.contains("worktree") || lower.contains("memory") {
            return protected(.applicationData, title: knownTitle(for: path, name: name), explanation: "作業ファイルまたは継続利用する記憶データを含む可能性があります。", reason: "作業内容を失わないため保護しています")
        }
            return protected(.unknown, title: knownTitle(for: path, name: name), explanation: "用途を安全に特定できないデータです。", reason: "未知形式のため削除対象にしません")
    }

    private static func regeneratable(_ category: StorageCategory, title: String, explanation: String) -> StorageRepository.Classification {
        StorageRepository.Classification(
            category: category,
            safety: .regeneratable,
            title: title,
            explanation: explanation,
            impact: "必要になればツールが再取得または再作成します。初回表示が遅くなる場合があります。",
            reason: "既知の再生成可能な保存場所です"
        )
    }

    private static func review(_ category: StorageCategory, title: String, explanation: String, impact: String) -> StorageRepository.Classification {
        StorageRepository.Classification(
            category: category,
            safety: .reviewRequired,
            title: title,
            explanation: explanation,
            impact: impact,
            reason: "再生成できない情報を含む可能性があるため、内容を理解してから判断してください"
        )
    }

    private static func protected(_ category: StorageCategory, title: String, explanation: String, reason: String) -> StorageRepository.Classification {
        StorageRepository.Classification(
            category: category,
            safety: .protected,
            title: title,
            explanation: explanation,
            impact: "Session Shelfからは削除できません。",
            reason: reason
        )
    }

    private static func readableName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }

    private static func knownTitle(for path: String, name: String) -> String {
        let lower = path.lowercased()
        if name == "sessions" { return "会話履歴" }
        if name == "archived_sessions" { return "アーカイブ済みの会話履歴" }
        if name == "generated_images" { return "生成画像" }
        if name == "worktrees" { return "作業用worktree" }
        if name == "shell_snapshots" || name == "shell-snapshots" { return "シェル状態の記録" }
        if name == "attachments" { return "会話の添付ファイル" }
        if name == "skills" { return "ユーザー追加スキル" }
        if name == "extensions" { return "インストール済み拡張機能" }
        if name == ".plugin-appserver" { return "プラグイン実行基盤" }
        if name == "plugins" || lower.hasSuffix("/plugins") { return "インストール済みプラグイン" }
        if name == "cache" { return "リンクを含むキャッシュ" }
        if lower.contains("auth") { return "認証情報" }
        if lower.contains("config") { return "ツール設定" }
        if lower.contains("sqlite") || lower.hasSuffix(".db") { return "内部データベース" }
        if lower.contains("memory") { return "継続利用するメモリ" }
        return readableName(name)
    }
}
