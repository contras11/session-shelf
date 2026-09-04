import Foundation

public struct SessionTreeNode: Identifiable, Hashable, Sendable {
    public let session: SessionSummary
    public let children: [SessionTreeNode]
    public let isOrphan: Bool

    public var id: String { session.id }
    public var outlineChildren: [SessionTreeNode]? { children.isEmpty ? nil : children }
    public var descendantCount: Int {
        children.reduce(0) { $0 + 1 + $1.descendantCount }
    }
    public var displayOrder: [SessionSummary] {
        [session] + children.flatMap(\.displayOrder)
    }

    public init(session: SessionSummary, children: [SessionTreeNode] = [], isOrphan: Bool = false) {
        self.session = session
        self.children = children
        self.isOrphan = isOrphan
    }
}

/// 保存形式ごとのIDを使い、表示と削除で共有する親子構造を組み立てます。
public enum SessionHierarchy {
    public static func roots(from sessions: [SessionSummary]) -> [SessionTreeNode] {
        let byProviderID = Dictionary(
            sessions.compactMap { session in
                session.lineage.map { ($0.sessionID, session) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let childrenByParent = childrenByParentID(sessions)

        func makeNode(_ session: SessionSummary, ancestors: Set<String>) -> SessionTreeNode {
            let nextAncestors = ancestors.union([session.id])
            // 壊れた循環参照で一覧全体が消えたり、再帰が止まらなくなったりするのを防ぎます。
            let children = (childrenByParent[session.lineage?.sessionID ?? ""] ?? [])
                .filter { !nextAncestors.contains($0.id) }
                .sorted { $0.date > $1.date }
                .map { makeNode($0, ancestors: nextAncestors) }
            let parentMissing = session.lineage?.parentSessionID.map { byProviderID[$0] == nil } ?? false
            return SessionTreeNode(session: session, children: children, isOrphan: parentMissing)
        }

        var rootNodes = sessions
            .filter { session in
                guard let parentID = session.lineage?.parentSessionID else { return true }
                return byProviderID[parentID] == nil
            }
            .sorted { $0.date > $1.date }
            .map { makeNode($0, ancestors: []) }
        var represented = Set(rootNodes.flatMap(\.displayOrder).map(\.id))

        // 親子IDが循環していて根を決められない場合も、親なしとして一覧へ残します。
        for session in sessions where !represented.contains(session.id) {
            let node = makeNode(session, ancestors: [])
            rootNodes.append(SessionTreeNode(session: node.session, children: node.children, isOrphan: true))
            represented.formUnion(node.displayOrder.map(\.id))
        }
        return rootNodes
    }

    public static func deletionOrder(
        startingAt seeds: [SessionSummary],
        in sessions: [SessionSummary]
    ) -> [SessionSummary] {
        let childrenByParent = childrenByParentID(sessions)
        var visited: Set<String> = []
        var result: [SessionSummary] = []

        func appendSubtree(_ session: SessionSummary) {
            guard visited.insert(session.id).inserted else { return }
            for child in childrenByParent[session.lineage?.sessionID ?? ""] ?? [] {
                appendSubtree(child)
            }
            result.append(session)
        }

        for seed in seeds { appendSubtree(seed) }
        return result
    }

    public static func hasBlockedMemberInFamily(_ sessions: [SessionSummary]) -> Bool {
        let providerIDs = Set(sessions.compactMap { $0.lineage?.sessionID })
        let containsFamily = sessions.contains { session in
            guard let parentID = session.lineage?.parentSessionID else { return false }
            return providerIDs.contains(parentID)
        }
        return containsFamily && sessions.contains { !$0.isSupported || $0.isProtected }
    }

    private static func childrenByParentID(_ sessions: [SessionSummary]) -> [String: [SessionSummary]] {
        Dictionary(grouping: sessions.compactMap { session -> (String, SessionSummary)? in
            guard let parentID = session.lineage?.parentSessionID else { return nil }
            return (parentID, session)
        }, by: \.0).mapValues { $0.map(\.1) }
    }
}
