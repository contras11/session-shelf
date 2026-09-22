import Foundation
import SessionShelfCore
import XCTest

final class SessionHierarchyTests: XCTestCase {
    func test親子を階層化して親の削除候補を子孫優先で並べる() {
        let parent = session(id: "parent", providerID: "provider-parent")
        let child = session(id: "child", providerID: "provider-child", parentID: "provider-parent")
        let grandchild = session(id: "grandchild", providerID: "provider-grandchild", parentID: "provider-child")
        let orphan = session(id: "orphan", providerID: "provider-orphan", parentID: "missing-parent")
        let sessions = [parent, child, grandchild, orphan]

        let roots = SessionHierarchy.roots(from: sessions)
        XCTAssertEqual(Set(roots.map(\.id)), ["parent", "orphan"])
        XCTAssertEqual(roots.first { $0.id == "parent" }?.descendantCount, 2)
        XCTAssertEqual(roots.first { $0.id == "orphan" }?.isOrphan, true)
        XCTAssertEqual(
            SessionHierarchy.deletionOrder(startingAt: [parent], in: sessions).map(\.id),
            ["grandchild", "child", "parent"]
        )
    }

    func test保護中の子がある親セッションは削除対象にできない() {
        let parent = session(id: "parent", providerID: "provider-parent")
        let child = session(
            id: "child",
            providerID: "provider-child",
            parentID: "provider-parent",
            isProtected: true
        )

        XCTAssertTrue(SessionHierarchy.hasBlockedMemberInFamily([child, parent]))
        XCTAssertFalse(SessionHierarchy.hasBlockedMemberInFamily([child]))

        let protectedParent = session(
            id: "protected-parent",
            providerID: "provider-protected-parent",
            isProtected: true
        )
        let deletableChild = session(
            id: "deletable-child",
            providerID: "provider-deletable-child",
            parentID: "provider-protected-parent"
        )
        XCTAssertTrue(SessionHierarchy.hasBlockedMemberInFamily([deletableChild, protectedParent]))
    }

    func test循環した親子関係も一覧から消えず親なしとして表示する() {
        let first = session(id: "first", providerID: "provider-first", parentID: "provider-second")
        let second = session(id: "second", providerID: "provider-second", parentID: "provider-first")

        let roots = SessionHierarchy.roots(from: [first, second])

        XCTAssertFalse(roots.isEmpty)
        XCTAssertEqual(Set(roots.flatMap(\.displayOrder).map(\.id)), ["first", "second"])
        XCTAssertTrue(roots[0].isOrphan)
    }

    func testプロジェクト区分は根だけを束ねて子を分割しない() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let parent = session(id: "parent", providerID: "p", project: "/tmp/alpha", date: base)
        let child = session(id: "child", providerID: "c", parentID: "p", project: "/tmp/other", date: base.addingTimeInterval(10))
        let beta = session(id: "beta", providerID: "b", project: "/tmp/beta", date: base.addingTimeInterval(100))
        let none = session(id: "none", providerID: "n", project: nil, date: base.addingTimeInterval(1_000))
        let sameName = session(id: "same", providerID: "s", project: "/var/beta", date: base.addingTimeInterval(5))

        let sections = SessionHierarchy.projectSections(from: SessionHierarchy.roots(from: [parent, child, beta, none, sameName]))

        XCTAssertEqual(sections.map(\.project), ["/tmp/beta", "/tmp/alpha", "/var/beta", nil])
        XCTAssertEqual(sections.map(\.displayName), ["/tmp/beta", "alpha", "/var/beta", "プロジェクト未設定"])
        let alpha = sections.first { $0.project == "/tmp/alpha" }
        XCTAssertEqual(alpha?.sessionCount, 2)
        XCTAssertEqual(alpha?.totalByteCount, 2)
        XCTAssertEqual(alpha?.latestDate, base.addingTimeInterval(10))
        XCTAssertNil(sections.first { $0.project == "/tmp/other" })
        XCTAssertEqual(SessionHierarchy.projectSections(from: SessionHierarchy.roots(from: [parent, child])).count, 1)
    }

    private func session(
        id: String,
        providerID: String,
        parentID: String? = nil,
        project: String? = nil,
        date: Date = .distantPast,
        isProtected: Bool = false
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            tool: .codex,
            title: id,
            date: date,
            byteCount: 1,
            project: project,
            overview: id,
            sourceURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
            lineage: SessionLineage(sessionID: providerID, parentSessionID: parentID),
            isProtected: isProtected
        )
    }
}
