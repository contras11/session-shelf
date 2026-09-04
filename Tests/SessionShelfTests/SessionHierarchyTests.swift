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

    private func session(
        id: String,
        providerID: String,
        parentID: String? = nil,
        isProtected: Bool = false
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            tool: .codex,
            title: id,
            date: .distantPast,
            byteCount: 1,
            project: nil,
            overview: id,
            sourceURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
            lineage: SessionLineage(sessionID: providerID, parentSessionID: parentID),
            isProtected: isProtected
        )
    }
}
