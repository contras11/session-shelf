import CSQLite3
import Foundation
import XCTest
@testable import SessionShelfCore
@testable import SessionShelf

final class OpenCodeRepositoryTests: XCTestCase {
    func testV2の一覧と親子関係と実行中保護を読み取る() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        try fixture.execute("INSERT INTO session_v2 VALUES('child','project','s1','child','/tmp/project','子',1000,2000,NULL,NULL,1,'src')")
        let sessions = fixture.repository.scan(.openCode).sessions
        XCTAssertEqual(sessions.count, 2)
        let child = try XCTUnwrap(sessions.first { $0.id == "opencode:child" })
        XCTAssertEqual(child.lineage?.parentSessionID, "s1")
        XCTAssertEqual(child.project, "/tmp/project/src")
        XCTAssertTrue(child.isProtected)
        XCTAssertFalse(try fixture.session().isProtected)
    }

    func testV2の本文と思考と操作結果を順序どおり表示し検索する() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        try fixture.message("assistant", seq: 2, data: ["content": [
            ["type": "reasoning", "text": "匿名の思考"],
            ["type": "text", "text": "回答です"],
            ["type": "tool", "name": "edit", "state": ["status": "completed", "input": ["path": "App.swift"], "content": [["type": "text", "text": "編集成功"]]]],
            ["type": "tool", "name": "read", "state": ["status": "error", "input": ["path": "/tmp/read-only.txt"], "error": ["message": "匿名エラー"]]],
            ["type": "tool", "name": "shell", "state": ["status": "running", "input": ["command": "echo fixture"]]]
        ], "snapshot": ["files": ["Extra.swift"]]], created: 1000)
        try fixture.message("user", seq: 1, data: ["text": "検索用の質問"], created: 9000)
        try fixture.message("system", seq: 3, data: ["text": "匿名の設定"])
        try fixture.message("synthetic", seq: 4, data: ["text": "補助情報"])
        try fixture.message("shell", seq: 5, data: ["command": "false", "status": "exited", "exit": 1, "output": ["output": "失敗出力", "cursor": 12, "size": 12, "truncated": false]])
        let session = try fixture.session()
        let detail = try fixture.repository.loadDetail(for: session)
        XCTAssertEqual(detail.conversation.first?.text, "検索用の質問")
        XCTAssertTrue(detail.conversation.contains { $0.kind == .thinking && $0.text == "匿名の思考" })
        XCTAssertTrue(detail.conversation.contains { if case .context = $0.kind { return $0.text == "匿名の設定" }; return false })
        XCTAssertTrue(detail.conversation.contains { $0.kind == .toolResult(result: .success) && $0.text.contains("編集成功") })
        XCTAssertTrue(detail.conversation.contains { $0.kind == .toolResult(result: .failure) && $0.text.contains("匿名エラー") })
        XCTAssertEqual(detail.operations.map(\.result), [.success, .failure, .unknown, .failure])
        XCTAssertTrue(detail.conversation.contains { $0.text == "失敗出力" })
        XCTAssertEqual(Set(detail.changedFiles.map(\.path)), ["/tmp/project/App.swift", "/tmp/project/Extra.swift"])
        XCTAssertNotNil(SessionBodySearch.previews(for: [session], query: "検索用")[session.id])
        XCTAssertFalse(detail.wasTruncated)
    }

    func testV2の生ログは選択した会話だけを含み未知形式と破損JSONを保持する() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        try fixture.message("user", seq: 1, data: ["text": "読める本文"])
        try fixture.message("future", seq: 2, data: ["text": "未知形式の目印"])
        try fixture.execute("INSERT INTO session_message VALUES('broken','s1','assistant',3,1000,1000,'{broken'); CREATE TABLE credential(data TEXT); INSERT INTO credential VALUES('認証テーブルの目印'); INSERT INTO session_message VALUES('other','other','user',1,1000,1000,'{\"text\":\"別セッションの目印\"}')")
        let detail = try fixture.repository.loadDetail(for: fixture.session())
        XCTAssertTrue(detail.conversation.contains { $0.text == "読める本文" })
        XCTAssertTrue(detail.rawLog.contains("未知形式の目印"))
        XCTAssertTrue(detail.rawLog.contains("{broken"))
        XCTAssertFalse(detail.rawLog.contains("認証テーブルの目印"))
        XCTAssertFalse(detail.rawLog.contains("別セッションの目印"))
    }

    func testV1とV2が残るDBではV2だけを表示し削除後に旧行を復活させない() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        try fixture.execute(OpenCodeFixture.v1Schema + "INSERT INTO session VALUES('legacy','p',NULL,'s','/tmp','旧履歴',1000,1000,NULL,NULL)")
        XCTAssertEqual(fixture.repository.scan(.openCode).sessions.map(\.id), ["opencode:s1"])
        try fixture.execute("DELETE FROM session_v2")
        XCTAssertTrue(fixture.repository.scan(.openCode).sessions.isEmpty)
    }

    func test不完全なV2からV1へ戻らず未対応として保護する() throws {
        for table in ["session_v2", "session_message"] {
            let fixture = try OpenCodeFixture(version: 1)
            defer { fixture.remove() }
            try fixture.execute("CREATE TABLE \(table)(id TEXT)")
            let shelf = fixture.repository.scan(.openCode)
            if case .unsupportedFormat = shelf.status {} else { XCTFail("不完全なv2を対応済みと扱った") }
            XCTAssertTrue(shelf.sessions.isEmpty)
        }
    }

    func test必要な列の欠損を一覧の段階で検出する() throws {
        for statement in ["ALTER TABLE session_v2 DROP COLUMN time_suspended", "ALTER TABLE session_message DROP COLUMN seq"] {
            let fixture = try OpenCodeFixture()
            defer { fixture.remove() }
            try fixture.execute(statement)
            if case .unsupportedFormat = fixture.repository.scan(.openCode).status {} else { XCTFail(statement) }
        }
    }

    func testV1の補助テーブルsession_messageをV2と誤判定しない() throws {
        let fixture = try OpenCodeFixture(version: 1)
        defer { fixture.remove() }
        try fixture.execute("CREATE TABLE session_message(id TEXT,session_id TEXT REFERENCES session(id),type TEXT,seq INTEGER,time_created INTEGER,time_updated INTEGER,data TEXT)")
        XCTAssertEqual(fixture.repository.scan(.openCode).sessions.map(\.id), ["opencode:s1"])
    }

    func test大きな本文と生ログの省略を詳細へ伝える() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        try fixture.message("user", seq: 1, data: ["text": String(repeating: "あ", count: 750_000)])
        let detail = try fixture.repository.loadDetail(for: fixture.session())
        XCTAssertTrue(detail.wasTruncated, "生ログだけの省略も伝える")
        XCTAssertLessThanOrEqual(detail.rawLog.utf8.count, 2_001_000)
        try fixture.message("user", seq: 2, data: ["text": String(repeating: "x", count: 8_000_001)])
        XCTAssertTrue(try fixture.repository.loadDetail(for: fixture.session()).wasTruncated)
    }

    func test件数上限で会話と生ログの読み込みを止める() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        try fixture.execute("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<5005) INSERT INTO session_message SELECT 'm'||x,'s1','user',x,1000,1000,'{\"text\":\"匿名本文\"}' FROM n")
        let detail = try fixture.repository.loadDetail(for: fixture.session())
        XCTAssertTrue(detail.wasTruncated)
        XCTAssertLessThanOrEqual(detail.conversation.count, 5000)
    }

    func testV1とV2のCLI引数を選びDBを直接変更しない() throws {
        for version in [1, 2] {
            let fixture = try OpenCodeFixture(version: version)
            defer { fixture.remove() }
            let cli = try fixture.cli(version: version)
            let repository = SessionRepository(homeDirectory: fixture.home, openCodeExecutables: [cli])
            let session = try fixture.session()
            let before = try Data(contentsOf: fixture.database)
            try repository.delete(session, mode: session.deletionMode)
            let expected = version == 2 ? "session\ndelete\n--standalone\ns1\n" : "session\ndelete\ns1\n"
            XCTAssertEqual(try String(contentsOf: fixture.record, encoding: .utf8), expected)
            XCTAssertEqual(try Data(contentsOf: fixture.database), before)
        }
    }

    func testCLIの不一致と不明なバージョンでは削除しない() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let session = try fixture.session()
        for version in [1, 3, 0] {
            let cli = try fixture.cli(version: version)
            let repository = SessionRepository(homeDirectory: fixture.home, openCodeExecutables: [cli])
            XCTAssertThrowsError(try repository.delete(session, mode: session.deletionMode))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.record.path))
        }
    }

    func testCLIの保存先を検証したDBの場所へ固定する() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let cli = try fixture.cli(version: 2)
        let destination = fixture.home.appendingPathComponent("cli-data-root")
        let script = try String(contentsOf: cli, encoding: .utf8) + "printf '%s\\n%s' \"$XDG_DATA_HOME\" \"$OPENCODE_DB\" > '\(destination.path)'\n"
        try script.write(to: cli, atomically: false, encoding: .utf8)
        let session = try fixture.session()
        try SessionRepository(homeDirectory: fixture.home, openCodeExecutables: [cli]).delete(session, mode: session.deletionMode)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), fixture.home.appendingPathComponent(".local/share").path + "\n" + fixture.database.path)
    }

    func testV1の多数メッセージでも先頭の本文を上限まで残す() throws {
        let fixture = try OpenCodeFixture(version: 1)
        defer { fixture.remove() }
        try fixture.execute("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<5005) INSERT INTO message SELECT 'm'||x,'s1',x,x,'{\"role\":\"user\"}' FROM n; INSERT INTO part SELECT id,id,'s1',time_created,time_updated,'{\"type\":\"text\",\"text\":\"先頭の匿名本文\"}' FROM message")
        let session = try fixture.session()
        let detail = try fixture.repository.loadDetail(for: session)
        XCTAssertEqual(detail.conversation.count, 5000)
        XCTAssertEqual(detail.conversation.first?.text, "先頭の匿名本文")
        XCTAssertTrue(detail.wasTruncated)
        XCTAssertNotNil(SessionBodySearch.previews(for: [session], query: "先頭の匿名本文")[session.id])
    }

    func test巨大な値はSQLite側で取得を拒否し件数予算がなければ行を進めない() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        try fixture.message("user", seq: 1, data: ["text": String(repeating: "x", count: 2_000_000)])
        let db = try OpenCodeDatabase(fixture.database)
        var budget = OpenCodeDatabase.Budget(bytes: 64_000)
        XCTAssertTrue(try db.rows("SELECT data FROM session_message", budget: &budget).isEmpty)
        XCTAssertEqual(budget.bytes, 64_000, "巨大な値をSwiftへコピーしない")
        XCTAssertTrue(budget.wasTruncated)
        var noEntries = OpenCodeDatabase.Budget(bytes: 64_000, entries: 0)
        XCTAssertTrue(try db.rows("SELECT json_extract(data, '$') FROM session_message", budget: &noEntries).isEmpty)
        XCTAssertTrue(noEntries.wasTruncated)
    }

    func test削除直前の更新と圧縮と実行中と新しい子を再確認する() throws {
        for change in ["time_updated=2000", "time_compacting=1", "time_suspended=1", "time_updated=\(Int(Date().timeIntervalSince1970 * 1000))"] {
            let fixture = try OpenCodeFixture()
            defer { fixture.remove() }
            let session = try fixture.session()
            let cli = try fixture.cli(version: 2, onVersion: "/usr/bin/sqlite3 '\(fixture.database.path)' 'UPDATE session_v2 SET \(change)'\n")
            let repository = SessionRepository(homeDirectory: fixture.home, openCodeExecutables: [cli])
            XCTAssertThrowsError(try repository.delete(session, mode: session.deletionMode), change)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.record.path))
        }
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let session = try fixture.session()
        let cli = try fixture.cli(version: 2)
        try fixture.execute("INSERT INTO session_v2 VALUES('child','project','s1','child','/tmp','子',1000,1000,NULL,NULL,NULL,NULL)")
        let repository = SessionRepository(homeDirectory: fixture.home, openCodeExecutables: [cli])
        XCTAssertThrowsError(try repository.delete(session, mode: session.deletionMode))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.record.path))
    }

    func test許可外のDBとシンボリックリンクを削除に使わない() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let session = try fixture.session()
        let cli = try fixture.cli(version: 2)
        let outside = fixture.home.appendingPathComponent("outside.db")
        try FileManager.default.moveItem(at: fixture.database, to: outside)
        let forged = SessionSummary(id: session.id, tool: .openCode, title: "匿名", date: session.date, byteCount: 0, project: nil, overview: "", sourceURL: outside)
        let repository = SessionRepository(homeDirectory: fixture.home, openCodeExecutables: [cli])
        XCTAssertThrowsError(try repository.delete(forged, mode: forged.deletionMode))
        try FileManager.default.createSymbolicLink(at: fixture.database, withDestinationURL: outside)
        XCTAssertThrowsError(try repository.delete(session, mode: session.deletionMode))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.record.path))
    }

    func testCLI確認中にDBがシンボリックリンクへ変わっても削除しない() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let session = try fixture.session()
        let outside = fixture.home.appendingPathComponent("outside.db")
        let cli = try fixture.cli(version: 2, onVersion: "/bin/mv '\(fixture.database.path)' '\(outside.path)'\n/bin/ln -s '\(outside.path)' '\(fixture.database.path)'\n")
        let repository = SessionRepository(homeDirectory: fixture.home, openCodeExecutables: [cli])
        XCTAssertThrowsError(try repository.delete(session, mode: session.deletionMode))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.record.path))
    }
}

@MainActor
final class OpenCodeDeletionFlowTests: XCTestCase {
    func test親の選択から子を展開して保護中の子がいれば全体を拒否する() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        try fixture.execute("INSERT INTO session_v2 VALUES('child','project','s1','child','/tmp','子',1000,1000,NULL,NULL,NULL,NULL)")
        let store = SessionShelfStore(repository: fixture.repository)
        store.shelves = [fixture.repository.scan(.openCode)]
        store.selectedDestination = .tool(.openCode)
        let parent = try fixture.session()
        store.updateSelection([parent.id], visibleSessions: store.selectedShelf?.sessions ?? [])
        store.requestTrashForSelection()
        for _ in 0..<200 where store.isPreparingTrash { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.trashRequest?.sessions.map(\.id), ["opencode:child", "opencode:s1"])
        store.trashRequest = nil
        try fixture.execute("UPDATE session_v2 SET time_suspended=1 WHERE id='child'")
        store.shelves = [fixture.repository.scan(.openCode)]
        store.requestTrash([parent])
        XCTAssertNil(store.trashRequest)
        XCTAssertFalse(store.isPreparingTrash)
        XCTAssertTrue(store.errorMessage?.contains("保護中") == true)
    }

    func test子のCLI削除が失敗した後に親をCLIへ渡さない() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        try fixture.execute("INSERT INTO session_v2 VALUES('child','project','s1','child','/tmp','子',1000,1000,NULL,NULL,NULL,NULL)")
        let cli = try fixture.cli(version: 2)
        let script = try String(contentsOf: cli, encoding: .utf8) + "exit 1\n"
        try script.write(to: cli, atomically: false, encoding: .utf8)
        let repository = SessionRepository(homeDirectory: fixture.home, openCodeExecutables: [cli])
        let store = SessionShelfStore(repository: repository)
        let shelf = repository.scan(.openCode)
        store.shelves = [shelf]
        store.selectedDestination = .tool(.openCode)
        let order = SessionHierarchy.deletionOrder(startingAt: [try fixture.session()], in: shelf.sessions)
        store.confirmTrash(TrashRequest(sessions: order, plan: repository.deletionPlan(for: order)))
        for _ in 0..<500 where store.isDeletingSessions || store.isScanning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try String(contentsOf: fixture.record, encoding: .utf8), "session\ndelete\n--standalone\nchild\n")
        XCTAssertEqual(store.selectedShelf?.sessions.count, 2)
        XCTAssertTrue(store.errorMessage?.hasPrefix("2件を完全に削除できませんでした") == true)
    }
}

private struct OpenCodeFixture {
    let home: URL
    let database: URL
    let version: Int
    var record: URL { home.appendingPathComponent("args") }
    var repository: SessionRepository { SessionRepository(homeDirectory: home, openCodeExecutables: []) }

    static let v1Schema = "CREATE TABLE session(id TEXT PRIMARY KEY,project_id TEXT,parent_id TEXT,slug TEXT,directory TEXT,title TEXT,time_created INTEGER,time_updated INTEGER,time_compacting INTEGER,time_archived INTEGER); CREATE TABLE message(id TEXT,session_id TEXT,time_created INTEGER,time_updated INTEGER,data TEXT); CREATE TABLE part(id TEXT,message_id TEXT,session_id TEXT,time_created INTEGER,time_updated INTEGER,data TEXT);"

    init(version: Int = 2) throws {
        self.version = version
        home = FileManager.default.temporaryDirectory.appendingPathComponent("SessionShelf-OpenCode-\(UUID().uuidString)", isDirectory: true)
        database = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        if version == 1 {
            try execute(Self.v1Schema + "INSERT INTO session VALUES('s1','project',NULL,'slug','/tmp/project','匿名v1',1000,1000,NULL,NULL)")
        } else {
            try execute("CREATE TABLE session_v2(id TEXT PRIMARY KEY,project_id TEXT,parent_id TEXT,slug TEXT,directory TEXT,title TEXT,time_created INTEGER,time_updated INTEGER,time_compacting INTEGER,time_archived INTEGER,time_suspended INTEGER,path TEXT); CREATE TABLE session_message(id TEXT PRIMARY KEY,session_id TEXT,type TEXT,seq INTEGER,time_created INTEGER,time_updated INTEGER,data TEXT); INSERT INTO session_v2 VALUES('s1','project',NULL,'slug','/tmp/project','匿名v2',1000,1000,NULL,NULL,NULL,NULL)")
        }
    }

    func execute(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw NSError(domain: "fixture", code: 1) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    func message(_ type: String, seq: Int, data: [String: Any], created: Int = 1000) throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        try execute("INSERT INTO session_message VALUES('m\(seq)','s1','\(type)',\(seq),\(created),1000,'\(json)')")
    }

    func session() throws -> SessionSummary { try XCTUnwrap(repository.scan(.openCode).sessions.first { $0.id == "opencode:s1" }) }

    func cli(version: Int, onVersion: String = "") throws -> URL {
        let url = home.appendingPathComponent("opencode")
        let output = version == 0 ? "unknown" : "opencode v\(version).0.32"
        let script = "#!/bin/sh\nif [ \"$1\" = '--version' ]; then\n\(onVersion)printf '%s\\n' '\(output)'\nexit 0\nfi\nprintf '%s\\n' \"$@\" > '\(record.path)'\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}
