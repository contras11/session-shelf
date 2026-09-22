import Foundation
import SessionShelfCore
import XCTest
@testable import SessionShelf

private enum UnexpectedDeletionError: Error {
    case failed
}

private final class DeletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [String] = []
    let failures: [String: Error]

    init(failures: [String: Error] = [:]) {
        self.failures = failures
    }

    func delete(_ session: SessionSummary, mode: SessionDeletionMode) throws {
        lock.lock()
        invocations.append(session.id)
        lock.unlock()

        if let error = failures[session.id] {
            throw error
        }
        try FileManager.default.removeItem(at: session.deletionURL)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations.count
    }
}

@MainActor
final class SessionDeletionTests: XCTestCase {
    func test削除を非同期実行して二重送信を拒否し部分成功を反映する() async throws {
        let fixture = try makeFixture(names: ["success", "known-failure", "unknown-failure"])
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let sessions = fixture.repository.scan(.codex).sessions
        let known = try XCTUnwrap(sessions.first { $0.sourceURL.deletingPathExtension().lastPathComponent == "known-failure" })
        let unknown = try XCTUnwrap(sessions.first { $0.sourceURL.deletingPathExtension().lastPathComponent == "unknown-failure" })
        let recorder = DeletionRecorder(failures: [
            known.id: SessionShelfError.storageItemChanged,
            unknown.id: UnexpectedDeletionError.failed
        ])
        let store = makeStore(repository: fixture.repository, sessions: sessions, recorder: recorder)
        let request = TrashRequest(sessions: sessions, plan: fixture.repository.deletionPlan(for: sessions))
        XCTAssertEqual(request.plan.items.count, sessions.count)
        XCTAssertTrue(request.plan.items.allSatisfy { $0.kind == .sessionLog })

        store.confirmTrash(request)
        XCTAssertTrue(store.isDeletingSessions)
        store.confirmTrash(request)
        await waitForDeletion(in: store)

        XCTAssertEqual(recorder.count, sessions.count)
        XCTAssertEqual(
            store.selectedShelf?.sessions.map { $0.sourceURL.deletingPathExtension().lastPathComponent }.sorted(),
            ["known-failure", "unknown-failure"]
        )
        XCTAssertEqual(store.selectedSessionIDs.count, 2)
        XCTAssertTrue(store.errorMessage?.contains("確認後に内容が変わったため") == true)
        XCTAssertTrue(store.errorMessage?.contains("予期しないエラー") == true)
    }

    func test全件失敗では一覧と選択を保持する() async throws {
        let fixture = try makeFixture(names: ["first", "second"])
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let sessions = fixture.repository.scan(.codex).sessions
        let failures = Dictionary(uniqueKeysWithValues: sessions.map {
            ($0.id, SessionShelfError.outsideAllowedLocation as Error)
        })
        let recorder = DeletionRecorder(failures: failures)
        let store = makeStore(repository: fixture.repository, sessions: sessions, recorder: recorder)

        store.confirmTrash(TrashRequest(sessions: sessions, plan: fixture.repository.deletionPlan(for: sessions)))
        await waitForDeletion(in: store)

        XCTAssertEqual(Set(store.selectedShelf?.sessions.map(\.id) ?? []), Set(sessions.map(\.id)))
        XCTAssertEqual(store.selectedSessionIDs, Set(sessions.map(\.id)))
        XCTAssertTrue(store.errorMessage?.hasPrefix("2件をゴミ箱へ移せませんでした") == true)
    }

    private func makeStore(
        repository: SessionRepository,
        sessions: [SessionSummary],
        recorder: DeletionRecorder
    ) -> SessionShelfStore {
        let store = SessionShelfStore(
            repository: repository,
            deleteSession: recorder.delete
        )
        store.shelves = [ToolShelf(
            tool: .codex,
            status: .detected(count: sessions.count),
            candidatePaths: [],
            sessions: sessions
        )]
        store.selectedDestination = .tool(.codex)
        store.updateSelection(Set(sessions.map(\.id)), visibleSessions: sessions)
        return store
    }

    private func makeFixture(names: [String]) throws -> (home: URL, repository: SessionRepository) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionShelfTests-\(UUID().uuidString)", isDirectory: true)
        let directory = home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names {
            let contents = "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/tmp/project\"}}\n"
            try contents.write(
                to: directory.appendingPathComponent("\(name).jsonl"),
                atomically: true,
                encoding: .utf8
            )
        }
        return (home, SessionRepository(homeDirectory: home, openCodeExecutables: []))
    }

    private func waitForDeletion(in store: SessionShelfStore) async {
        for _ in 0..<200 {
            if !store.isDeletingSessions, !store.isScanning { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("セッション削除と再読込が完了しませんでした")
    }
}
