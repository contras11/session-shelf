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
        try checkMultipleSelection(); completed += 1
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
            try write("# 新機能の計画\n\n1. 一覧を作る", to: plan)
            let repository = SessionRepository(homeDirectory: home)
            let shelf = repository.scan(.cursorDesktop)
            try require(shelf.sessions.first?.kind == .plan, "Cursorプランを検出できない")
            let item = try requireValue(shelf.sessions.first, "Cursorプランがない")
            try require(try repository.loadDetail(for: item).conversation[0].text.contains("一覧を作る"), "Cursorプランを読めない")
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
                ["type": "user", "content": "実装してください"],
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
            try require(detail.conversation.count == 5, "Grok会話の抽出に失敗")
            try require(
                detail.conversation.map(\.kind) == [
                    .message,
                    .message,
                    .toolCall(name: "shell"),
                    .toolResult(result: .success),
                    .message
                ],
                "Grokのツール入出力を会話順に保持できない"
            )
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
