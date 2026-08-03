import Foundation
import SessionShelfCore

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): message }
    }
}

@main
struct SessionShelfChecks {
    static func main() throws {
        if CommandLine.arguments.contains("--scan-local") {
            try scanLocalMachine()
            return
        }
        var completed = 0
        try checkCodex(); completed += 1
        try checkClaudeAndCursorSeparation(); completed += 1
        try checkCursorPlan(); completed += 1
        try checkGrok(); completed += 1
        try checkProtection(); completed += 1
        try checkTrashRemovesFromScan(); completed += 1
        try checkMessageBlocks(); completed += 1
        try checkMarkdownDocument(); completed += 1
        try checkMultipleSelection(); completed += 1
        try checkStorageClassification(); completed += 1
        try checkStorageDeletionGuards(); completed += 1
        try checkStorageCancellation(); completed += 1
        print("Session Shelf: \(completed)件の検証に成功")
    }

    private static func scanLocalMachine() throws {
        let repository = SessionRepository()
        for shelf in repository.scanAll() {
            let supported = shelf.sessions.filter(\.isSupported)
            if let first = supported.first {
                _ = try repository.loadDetail(for: first)
            }
            print("\(shelf.tool.displayName): \(shelf.status.label)、本文確認 \(supported.isEmpty ? "対象なし" : "成功")")
        }
        let storage = StorageRepository().scanAll()
        for tool in AITool.allCases {
            let items = storage.items.filter { $0.tool == tool }
            let bytes = items.reduce(0) { $0 + $1.byteCount }
            let deletable = items.filter { $0.safety != .protected }.count
            print("\(tool.displayName)ストレージ: \(bytes.formatted(.byteCount(style: .file)))、整理候補\(deletable)件")
        }
        print("ストレージ確認エラー: \(storage.issues.count)件")
    }

    private static func checkCodex() throws {
        try withTemporaryHome { home in
            let session = home.appendingPathComponent(".codex/sessions/2026/07/27/sample.jsonl")
            try writeJSONLines([
                ["type": "session_meta", "payload": ["cwd": "/tmp/MyProject"]],
                ["type": "response_item", "payload": [
                    "type": "message", "role": "developer",
                    "content": [["type": "input_text", "text": "<app-context>\n内部のアプリ情報\n</app-context>"]]
                ]],
                ["type": "response_item", "payload": [
                    "type": "message", "role": "user",
                    "content": [
                        ["type": "input_text", "text": "<recommended_plugins>\n連携候補\n</recommended_plugins>"],
                        ["type": "input_text", "text": "# AGENTS.md instructions\n\n<INSTRUCTIONS>日本語で応答</INSTRUCTIONS>"],
                        ["type": "input_text", "text": "<environment_context>\n<cwd>/tmp/MyProject</cwd>\n</environment_context>"]
                    ]
                ]],
                ["type": "response_item", "payload": [
                    "type": "message", "role": "user",
                    "content": [[
                        "type": "input_text",
                        "text": "# Applications mentioned by the user:\n\n<appshot app=\"Sample\">画面情報</appshot>\n\n## My request for Codex:\n一覧画面を作ってください"
                    ]]
                ]],
                ["type": "response_item", "payload": [
                    "type": "message", "role": "user",
                    "content": [[
                        "type": "input_text",
                        "text": "<realtime_delegation>\n<input>音声で依頼しました</input>\n<transcript_delta>内部の文字起こし</transcript_delta>\n</realtime_delegation>"
                    ]]
                ]],
                ["type": "response_item", "payload": [
                    "type": "message", "role": "assistant",
                    "content": [["type": "output_text", "text": "[STATUS] 確認しています\n\n[REDACTED]"]]
                ]],
                ["type": "response_item", "payload": [
                    "type": "function_call", "name": "apply_patch",
                    "arguments": ["file_path": "/tmp/MyProject/App.swift"]
                ]],
                ["type": "response_item", "payload": ["type": "function_call_output", "output": "success"]]
            ], to: session)
            let repository = SessionRepository(homeDirectory: home)
            let shelf = repository.scan(.codex)
            try require(shelf.sessions.count == 1, "Codexの件数が不正")
            let item = shelf.sessions[0]
            try require(item.project == "/tmp/MyProject", "Codexのプロジェクト抽出に失敗")
            try require(item.title == "一覧画面を作ってください", "Codexのタイトル抽出に失敗")
            try require(!item.overview.contains("app-context"), "Codexの概要に内部情報が混入")
            let detail = try repository.loadDetail(for: item)
            try require(detail.operations.contains { $0.category == .edit }, "Codexの編集操作抽出に失敗")
            try require(detail.changedFiles.map(\.path) == ["/tmp/MyProject/App.swift"], "変更ファイル抽出に失敗")
            try require(
                detail.conversation.filter {
                    if case .context = $0.kind { return true }
                    return false
                }.count == 6,
                "Codexの内部情報を会話から分離できない"
            )
            try require(
                detail.conversation.first { $0.kind == .message && $0.speaker == .user }?.text == "一覧画面を作ってください",
                "Codexの画面情報から依頼本文を抽出できない"
            )
            try require(
                detail.conversation.contains { $0.kind == .message && $0.text == "音声で依頼しました" },
                "Codexの委譲情報から依頼本文を抽出できない"
            )
            try require(
                detail.conversation.contains { $0.kind == .message && $0.text == "確認しています" },
                "Codexの状態接頭辞を表示文から除去できない"
            )
            try require(
                detail.conversation.suffix(3).map(\.kind) == [
                    .message,
                    .toolCall(name: "apply_patch"),
                    .toolResult(result: .success)
                ],
                "Codexのツール入出力を会話順に保持できない"
            )
        }
    }

    private static func checkClaudeAndCursorSeparation() throws {
        try withTemporaryHome { home in
            try writeJSONLines([
                ["type": "user", "cwd": "/tmp/Claude", "message": ["role": "user", "content": "Claudeの質問"]],
                ["type": "assistant", "cwd": "/tmp/Claude", "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "確認します"],
                        ["type": "tool_use", "name": "Bash", "input": ["command": "swift test"]]
                    ]
                ]],
                ["type": "user", "cwd": "/tmp/Claude", "message": [
                    "role": "user",
                    "content": [["type": "tool_result", "content": "成功", "is_error": false]]
                ]]
            ], to: home.appendingPathComponent(".claude/projects/-tmp-Claude/sample.jsonl"))
            try writeJSONLines([
                ["role": "user", "message": [
                    "content": [[
                        "type": "text",
                        "text": "<timestamp>Monday, Jul 6, 2026, 2:36 PM (UTC+9)</timestamp>\n<user_query>\nCursor CLIの質問\n</user_query>"
                    ]]
                ]],
                ["role": "assistant", "message": [
                    "content": [
                        ["type": "text", "text": "確認します。\n\n[REDACTED]"],
                        ["type": "tool_use", "name": "Shell", "input": ["command": "swift test"]]
                    ]
                ]],
                ["role": "user", "message": [
                    "content": [["type": "tool_result", "content": "成功", "is_error": false]]
                ]]
            ], to: home.appendingPathComponent(".cursor/projects/Users-test-Demo/agent-transcripts/abc/abc.jsonl"))
            let repository = SessionRepository(homeDirectory: home)
            let claudeItem = try requireValue(repository.scan(.claudeCode).sessions.first, "Claude Codeを検出できない")
            let claudeDetail = try repository.loadDetail(for: claudeItem)
            try require(
                claudeDetail.conversation.map(\.kind) == [
                    .message,
                    .message,
                    .toolCall(name: "Bash"),
                    .toolResult(result: .success)
                ],
                "Claude Codeのツール入出力を会話順に保持できない"
            )
            let cursorItem = try requireValue(repository.scan(.cursorCLI).sessions.first, "Cursor CLIを検出できない")
            try require(cursorItem.title == "Cursor CLIの質問", "Cursor CLIのタイトルからラッパーを除去できない")
            try require(!cursorItem.overview.contains("{\"content\""), "Cursor CLIの概要にJSONが露出")
            let cursorDetail = try repository.loadDetail(for: cursorItem)
            try require(
                cursorDetail.conversation.map(\.kind) == [
                    .message,
                    .message,
                    .toolCall(name: "Shell"),
                    .toolResult(result: .success)
                ],
                "Cursor CLIの入れ子データを会話順に分解できない"
            )
            try require(cursorDetail.conversation[0].timestamp != nil, "Cursor CLIの埋め込み日時を抽出できない")
            try require(cursorDetail.conversation[1].text == "確認します。", "Cursor CLIの表示文から保存用マーカーを除去できない")
            try require(repository.scan(.cursorDesktop).sessions.isEmpty, "Cursor DesktopとCLIが混在")
        }
    }

    private static func checkCursorPlan() throws {
        try withTemporaryHome { home in
            let plan = home.appendingPathComponent(".cursor/plans/feature.plan.md")
            try write("""
            ---
            name: 新機能の計画
            overview: 一覧を読みやすくする。
            todos:
              - id: task-3
                content: 一覧を作る
                status: completed
              - id: verify
                content: 表示を確認する
                status: pending
              - content: IDなしでも保持する
                status: in_progress
            isProject: false
            ---

            # 新機能の計画

            ## 方針

            - 一覧を作る
            """, to: plan)
            let plainPlan = home.appendingPathComponent(".cursor/plans/plain.plan.md")
            try write("# Front matterなし\n\n本文を保持する。", to: plainPlan)
            let brokenPlan = home.appendingPathComponent(".cursor/plans/broken.plan.md")
            try write("---\nname: 閉じタグなし\n# 本文も保持", to: brokenPlan)
            let codeOnlyPlan = home.appendingPathComponent(".cursor/plans/script.plan.md")
            try write("```sh\n# これはタイトルではない\necho hello\n```", to: codeOnlyPlan)
            let repository = SessionRepository(homeDirectory: home)
            let shelf = repository.scan(.cursorDesktop)
            let item = try requireValue(shelf.sessions.first { $0.sourceURL.lastPathComponent == plan.lastPathComponent }, "Cursorプランがない")
            try require(item.kind == .plan, "Cursorプランを検出できない")
            try require(item.title == "新機能の計画", "front matterからタイトルを抽出できない")
            try require(item.overview == "一覧を読みやすくする。", "front matterから概要を抽出できない")
            let detail = try repository.loadDetail(for: item)
            try require(detail.conversation.isEmpty, "Cursorプランが会話へ混入")
            try require(detail.planDocument?.tasks.count == 3, "Cursorプランのタスクを抽出できない")
            try require(detail.planDocument?.tasks.map(\.status) == [.completed, .pending, .inProgress], "タスク状態の抽出に失敗")
            try require(detail.planDocument?.tasks.last?.id == "task-3-2", "IDなしタスクへ重複しない識別子を付けられない")
            try require(detail.planDocument?.body.contains("## 方針") == true, "Markdown本文を保持できない")

            let plainItem = try requireValue(shelf.sessions.first { $0.sourceURL.lastPathComponent == plainPlan.lastPathComponent }, "front matterなしプランがない")
            try require(try repository.loadDetail(for: plainItem).planDocument?.body.contains("本文を保持する") == true, "front matterなし本文を読めない")
            let brokenItem = try requireValue(shelf.sessions.first { $0.sourceURL.lastPathComponent == brokenPlan.lastPathComponent }, "壊れたfront matterのプランがない")
            try require(try repository.loadDetail(for: brokenItem).planDocument?.body.hasPrefix("---") == true, "壊れたfront matterで内容を失った")
            let codeOnlyItem = try requireValue(shelf.sessions.first { $0.sourceURL.lastPathComponent == codeOnlyPlan.lastPathComponent }, "コードだけのプランがない")
            try require(codeOnlyItem.title == "script.plan", "コード内コメントをプランタイトルとして誤認")
        }
    }

    private static func checkGrok() throws {
        try withTemporaryHome { home in
            let directory = home.appendingPathComponent(".grok/sessions/%2Ftmp%2FGrok/abc", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let summary: [String: Any] = [
                "generated_title": "Grokの作業",
                "session_summary": "ローカルアプリを実装",
                "info": ["cwd": "/tmp/Grok"]
            ]
            try JSONSerialization.data(withJSONObject: summary).write(to: directory.appendingPathComponent("summary.json"))
            try writeJSONLines([
                ["type": "system", "content": "Grokのシステム指示"],
                ["type": "user", "content": [["type": "text", "text": "<user_info>\nWorkspace: /tmp/Grok\n</user_info>"]]],
                ["type": "user", "synthetic_reason": "system_reminder", "content": [["type": "text", "text": "<system-reminder>\n内部の通知\n</system-reminder>"]]],
                ["type": "user", "content": [["type": "text", "text": "<user_query>\n実装してください\n</user_query>"]]],
                [
                    "type": "assistant",
                    "content": "確認します",
                    "tool_calls": [["name": "shell", "arguments": ["command": "swift test"]]]
                ],
                ["type": "tool_result", "content": "成功", "status": "completed"],
                ["type": "assistant", "content": "実装しました"]
            ], to: directory.appendingPathComponent("chat_history.jsonl"))
            let repository = SessionRepository(homeDirectory: home)
            let shelf = repository.scan(.grokBuildCLI)
            try require(shelf.sessions.first?.title == "Grokの作業", "Grokのタイトル抽出に失敗")
            let item = try requireValue(shelf.sessions.first, "Grokを検出できない")
            let detail = try repository.loadDetail(for: item)
            try require(detail.conversation.count == 8, "Grok会話の抽出に失敗")
            try require(
                detail.conversation.map(\.kind) == [
                    .context(label: "システム指示"),
                    .context(label: "実行環境"),
                    .context(label: "システム通知"),
                    .message,
                    .message,
                    .toolCall(name: "shell"),
                    .toolResult(result: .success),
                    .message
                ],
                "Grokのツール入出力を会話順に保持できない"
            )
            try require(
                detail.conversation.first { $0.kind == .message && $0.speaker == .user }?.text == "実装してください",
                "Grokのuser_queryから依頼本文を抽出できない"
            )
            try require(!item.overview.contains("system-reminder"), "Grokの概要に内部情報が混入")
        }
    }

    private static func checkProtection() throws {
        try withTemporaryHome { home in
            let session = home.appendingPathComponent(".codex/sessions/sample.jsonl")
            try writeJSONLines([
                ["type": "response_item", "payload": ["type": "message", "role": "user", "content": "作業中"]]
            ], to: session)
            let repository = SessionRepository(homeDirectory: home)
            let item = try requireValue(repository.scan(.codex).sessions.first, "保護テストのセッションがない")
            try require(item.isProtected, "更新直後のセッションが保護されない")
            do {
                try repository.moveToTrash(item)
                throw CheckFailure.failed("保護対象をゴミ箱へ移動できてしまった")
            } catch SessionShelfError.protectedItem {
                // 期待どおり
            }
        }
    }

    private static func checkTrashRemovesFromScan() throws {
        try withTemporaryHome { home in
            let session = home.appendingPathComponent(".codex/sessions/sample-one.jsonl")
            let secondSession = home.appendingPathComponent(".codex/sessions/sample-two.jsonl")
            let protectedSession = home.appendingPathComponent(".codex/sessions/working.jsonl")
            try writeJSONLines([
                ["type": "response_item", "payload": ["type": "message", "role": "user", "content": "古い作業1"]]
            ], to: session)
            try writeJSONLines([
                ["type": "response_item", "payload": ["type": "message", "role": "user", "content": "古い作業2"]]
            ], to: secondSession)
            try writeJSONLines([
                ["type": "response_item", "payload": ["type": "message", "role": "user", "content": "作業中"]]
            ], to: protectedSession)
            // 30分以内の更新は保護対象になるため、更新日時を過去に戻す
            for url in [session, secondSession] {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
                    ofItemAtPath: url.path
                )
            }
            let repository = SessionRepository(homeDirectory: home)
            let items = repository.scan(.codex).sessions
            let deletable = items.filter { !$0.isProtected }
            try require(deletable.count == 2, "一括削除テストの対象件数が不正")
            try require(items.count == 3, "保護対象を含む検証データを検出できない")
            for item in deletable { try repository.moveToTrash(item) }
            try require(!FileManager.default.fileExists(atPath: session.path), "ゴミ箱移動後もファイルが残っている")
            try require(!FileManager.default.fileExists(atPath: secondSession.path), "一括削除した2件目が残っている")
            try require(FileManager.default.fileExists(atPath: protectedSession.path), "保護対象まで削除された")
            let remaining = repository.scan(.codex).sessions
            try require(remaining.count == 1 && remaining[0].isProtected, "一括削除後の保護対象が一覧に残らない")
        }
    }

    private static func checkMessageBlocks() throws {
        let blocks = MessageBlockParser.parse("""
        説明です。
        ```bash
        swift test
        ```
        続きです。
        ```swift
        let value = 1
        ```
        """)
        try require(blocks == [
            .prose("説明です。"),
            .code(language: "bash", text: "swift test"),
            .prose("続きです。"),
            .code(language: "swift", text: "let value = 1")
        ], "コードフェンスの分割に失敗")

        let unfinished = MessageBlockParser.parse("前文\n~~~zsh\necho hello")
        try require(
            unfinished == [.prose("前文"), .code(language: "zsh", text: "echo hello")],
            "閉じられていないコードフェンスを保持できない"
        )
    }

    private static func checkMarkdownDocument() throws {
        let blocks = MarkdownDocumentParser.parse("""
        # 見出し

        段落です。

        - 項目
        - [x] 完了項目

        1. 最初
        2. 次

        > 引用です

        | 観点 | 結果 |
        | --- | --- |
        | 表示 | 成功 |

        ```swift
        let value = 1
        ```
        """)
        try require(blocks.contains(.heading(level: 1, text: "見出し")), "Markdown見出しを解析できない")
        try require(blocks.contains(.paragraph("段落です。")), "Markdown段落を解析できない")
        try require(blocks.contains(.unorderedList([
            DocumentListItem(text: "項目"),
            DocumentListItem(text: "完了項目", isChecked: true)
        ])), "Markdownチェック項目を解析できない")
        try require(blocks.contains(.orderedList([
            DocumentListItem(text: "最初"),
            DocumentListItem(text: "次")
        ])), "Markdown番号付きリストを解析できない")
        try require(blocks.contains(.quote("引用です")), "Markdown引用を解析できない")
        try require(blocks.contains(.table(headers: ["観点", "結果"], rows: [["表示", "成功"]])), "Markdown表を解析できない")
        try require(blocks.contains(.code(language: "swift", text: "let value = 1")), "Markdownコードを解析できない")
    }

    private static func checkMultipleSelection() throws {
        let ordered = ["a", "b", "c", "d"]
        var selection = SessionSelectionState()

        try require(
            selection.update(to: ["b"], orderedIDs: ordered) == "b",
            "単一選択を詳細表示へ反映できない"
        )
        try require(
            selection.update(to: ["b", "d"], orderedIDs: ordered) == "d",
            "Command追加した最後の項目を表示できない"
        )
        try require(
            selection.update(to: Set(ordered), orderedIDs: ordered) == "a",
            "Shift範囲選択の終点を表示できない"
        )
        try require(
            selection.update(to: ["a", "b", "c"], orderedIDs: ordered) == "a",
            "表示中の項目が残る選択解除でフォーカスを維持できない"
        )
        try require(
            selection.update(to: ["b", "c"], orderedIDs: ordered) == "c",
            "表示中の項目を外した際に直前の選択へ戻れない"
        )
        try require(
            selection.reconcile(orderedIDs: ["b"]) == "b" && selection.selectedIDs == ["b"],
            "検索または再読み込み後に選択を絞り込めない"
        )
        selection.clear()
        try require(selection.focusedID == nil && selection.selectedIDs.isEmpty, "ツール切替時に選択を解除できない")
    }

    private static func checkStorageClassification() throws {
        try withTemporaryHome { home in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            let oldDate = now.addingTimeInterval(-10 * 24 * 60 * 60)
            let recentDate = now.addingTimeInterval(-10 * 60)

            let codexCache = home.appendingPathComponent(".codex/cache/catalog.json")
            let codexBackup = home.appendingPathComponent(".codex/.tmp/plugins-backup-old/repo/data.bin")
            let codexStaging = home.appendingPathComponent(".codex/.tmp/bundled-marketplaces/openai-bundled.staging-old/data.bin")
            let codexRecentBackup = home.appendingPathComponent(".codex/.tmp/plugins-backup-new/data.bin")
            let generatedImage = home.appendingPathComponent(".codex/generated_images/sample/image.png")
            let auth = home.appendingPathComponent(".codex/auth.json")
            let worktree = home.appendingPathComponent(".codex/worktrees/sample/App.swift")
            for url in [codexCache, codexBackup, codexStaging, generatedImage, auth, worktree] {
                try write("fixture", to: url)
                try setTreeModificationDate(oldDate, from: url, through: home)
            }
            try write("fixture", to: codexRecentBackup)
            try setTreeModificationDate(recentDate, from: codexRecentBackup, through: home)

            let claudeCache = home.appendingPathComponent(".claude/cache/models.json")
            let claudeDebug = home.appendingPathComponent(".claude/debug/old.log")
            let cursorCache = home.appendingPathComponent(".cursor/statsig-cache.json")
            let cursorTracking = home.appendingPathComponent(".cursor/ai-tracking/old.log")
            let cursorProject = home.appendingPathComponent(".cursor/projects/sample/agent.jsonl")
            for url in [claudeCache, claudeDebug, cursorCache, cursorTracking, cursorProject] {
                try write("fixture", to: url)
                try setTreeModificationDate(oldDate, from: url, through: home)
            }

            let currentGrok = home.appendingPathComponent(".grok/downloads/grok-macos-aarch64")
            let oldGrok = home.appendingPathComponent(".grok/downloads/grok-0.1.0-macos-aarch64")
            try write("current", to: currentGrok)
            try write("old", to: oldGrok)
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".grok/bin"),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                atPath: home.appendingPathComponent(".grok/bin/grok").path,
                withDestinationPath: "../downloads/grok-macos-aarch64"
            )
            for url in [currentGrok, oldGrok] {
                try setTreeModificationDate(oldDate, from: url, through: home)
            }

            let repository = StorageRepository(homeDirectory: home, now: { now })
            let report = repository.scanAll()
            try require(!report.wasCancelled, "通常のストレージ走査が中止扱いになった")
            try require(storageItem(in: report, suffix: ".codex/cache")?.safety == .regeneratable, "Codexキャッシュを再生成可能に分類できない")
            try require(storageItem(in: report, suffix: "plugins-backup-old")?.safety == .regeneratable, "古いCodexバックアップを分類できない")
            try require(storageItem(in: report, suffix: "openai-bundled.staging-old")?.safety == .regeneratable, "古いCodex stagingを分類できない")
            try require(storageItem(in: report, suffix: "plugins-backup-new")?.safety == .protected, "新しい一時データを保護できない")
            try require(storageItem(in: report, suffix: ".codex/generated_images")?.safety == .reviewRequired, "生成画像を要確認に分類できない")
            try require(storageItem(in: report, suffix: ".codex/auth.json")?.safety == .protected, "認証情報を保護できない")
            try require(storageItem(in: report, suffix: ".codex/worktrees")?.safety == .protected, "worktreeを保護できない")
            try require(storageItem(in: report, suffix: ".claude/cache")?.safety == .regeneratable, "Claudeキャッシュを分類できない")
            try require(storageItem(in: report, suffix: ".claude/debug")?.safety == .reviewRequired, "Claude診断ログを分類できない")
            try require(storageItem(in: report, suffix: ".cursor/statsig-cache.json")?.safety == .regeneratable, "Cursorキャッシュを分類できない")
            try require(storageItem(in: report, suffix: ".cursor/ai-tracking")?.tool == .cursorCLI, "Cursor CLI所有データをDesktopと重複させている")
            try require(report.items.filter { $0.location.path.hasSuffix(".cursor/projects") }.count == 1, "Cursor保存領域を二重集計している")
            try require(storageItem(in: report, suffix: "grok-macos-aarch64")?.safety == .protected, "現在のGrok実行ファイルを保護できない")
            try require(storageItem(in: report, suffix: "grok-0.1.0-macos-aarch64")?.safety == .regeneratable, "以前のGrok実行ファイルを分類できない")
        }
    }

    private static func checkStorageDeletionGuards() throws {
        try withTemporaryHome { home in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            let oldDate = now.addingTimeInterval(-10 * 24 * 60 * 60)
            let cacheFile = home.appendingPathComponent(".codex/cache/value.bin")
            let backupFile = home.appendingPathComponent(".codex/.tmp/plugins-backup-delete/value.bin")
            try write("cache", to: cacheFile)
            try write("backup", to: backupFile)
            for url in [cacheFile, backupFile] {
                try setTreeModificationDate(oldDate, from: url, through: home)
            }
            let link = home.appendingPathComponent(".codex/unknown-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)

            let repository = StorageRepository(homeDirectory: home, now: { now })
            let report = repository.scanAll()
            let cache = try requireValue(storageItem(in: report, suffix: ".codex/cache"), "削除検証用キャッシュがない")
            let backup = try requireValue(storageItem(in: report, suffix: "plugins-backup-delete"), "削除検証用バックアップがない")
            let linked = try requireValue(storageItem(in: report, suffix: ".codex/unknown-link"), "リンクを検出できない")
            try require(linked.safety == .protected, "リンク経由の項目を保護できない")

            try write("changed", to: cacheFile.deletingLastPathComponent().appendingPathComponent("new.bin"))
            do {
                try repository.moveToTrash(cache)
                throw CheckFailure.failed("確認後に変化したキャッシュを移動できてしまった")
            } catch SessionShelfError.storageItemChanged {
                // 期待どおり
            }

            try repository.moveToTrash(backup)
            try require(!FileManager.default.fileExists(atPath: backup.location.path), "安全判定済みバックアップをゴミ箱へ移せない")

            let outside = StorageItem(
                id: "outside",
                tool: .codex,
                category: .cache,
                safety: .regeneratable,
                title: "範囲外",
                explanation: "fixture",
                deletionImpact: "fixture",
                safetyReason: "fixture",
                byteCount: 0,
                fileCount: 0,
                modifiedAt: oldDate,
                location: home.appendingPathComponent("outside")
            )
            do {
                try repository.moveToTrash(outside)
                throw CheckFailure.failed("許可ルート外を移動できてしまった")
            } catch SessionShelfError.outsideAllowedLocation {
                // 期待どおり
            }
        }
    }

    private static func checkStorageCancellation() throws {
        try withTemporaryHome { home in
            try write("fixture", to: home.appendingPathComponent(".codex/cache/item"))
            let report = StorageRepository(homeDirectory: home).scanAll(shouldCancel: { true })
            try require(report.wasCancelled && report.items.isEmpty, "ストレージ走査を中止できない")
        }
    }

    private static func storageItem(in report: StorageScanReport, suffix: String) -> StorageItem? {
        report.items.first { $0.location.path.hasSuffix(suffix) }
    }

    private static func setTreeModificationDate(_ date: Date, from file: URL, through home: URL) throws {
        var current = file
        while current.path.hasPrefix(home.path), current != home {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: current.path)
            current.deleteLastPathComponent()
        }
    }

    private static func withTemporaryHome(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("SessionShelfChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }

    private static func writeJSONLines(_ objects: [[String: Any]], to url: URL) throws {
        let text = try objects.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }.joined(separator: "\n")
        try write(text, to: url)
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckFailure.failed(message) }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw CheckFailure.failed(message) }
        return value
    }
}
