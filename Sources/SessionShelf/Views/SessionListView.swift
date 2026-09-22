import SessionShelfCore
import SwiftUI

struct SessionListView: View {
    @ObservedObject var store: SessionShelfStore
    @State private var collapsedProjects: Set<String> = []

    private var sections: [ProjectSection] {
        SessionHierarchy.projectSections(from: nodes)
    }

    private var nodes: [SessionTreeNode] {
        guard let sessions = store.selectedShelf?.sessions else { return [] }
        let roots = SessionHierarchy.roots(from: sessions)
        guard !store.searchText.isEmpty else { return roots }
        return roots.compactMap(filtering)
    }

    private var sessions: [SessionSummary] {
        nodes.flatMap(\.displayOrder)
    }

    private func filtering(_ node: SessionTreeNode) -> SessionTreeNode? {
        let session = node.session
        let matches = session.title.localizedCaseInsensitiveContains(store.searchText)
            || session.overview.localizedCaseInsensitiveContains(store.searchText)
            || (session.project?.localizedCaseInsensitiveContains(store.searchText) ?? false)
            || (session.lineage?.displayName.localizedCaseInsensitiveContains(store.searchText) ?? false)
            || store.bodySearchPreviews[session.id] != nil
        if matches { return node }
        let matchingChildren = node.children.compactMap(filtering)
        guard !matchingChildren.isEmpty else { return nil }
        return SessionTreeNode(session: session, children: matchingChildren, isOrphan: node.isOrphan)
    }

    var body: some View {
        Group {
            if store.isScanning && store.shelves.isEmpty {
                ProgressView("ローカルの保存場所を確認中…")
            } else if let shelf = store.selectedShelf, sessions.isEmpty {
                if store.searchText.isEmpty {
                    DetectionEmptyView(shelf: shelf)
                } else {
                    ContentUnavailableView.search(text: store.searchText)
                }
            } else {
                List(selection: Binding(
                    get: { store.selectedSessionIDs },
                    set: { ids in store.updateSelection(ids, visibleSessions: sessions) }
                )) {
                    let sections = sections
                    if sections.count > 1 {
                        ForEach(sections) { section in
                            DisclosureGroup(isExpanded: Binding(
                                get: { !collapsedProjects.contains(section.id) },
                                set: { expanded in
                                    if expanded { collapsedProjects.remove(section.id) } else { collapsedProjects.insert(section.id) }
                                }
                            )) {
                                outline(section.roots)
                            } label: {
                                ProjectHeader(section: section)
                            }
                        }
                    } else {
                        outline(nodes)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(store.selectedTool?.displayName ?? "セッション")
        .searchable(text: $store.searchText, prompt: "タイトル・プロジェクト・本文を検索")
        .onChange(of: store.searchText) { _, _ in
            store.scheduleBodySearch()
        }
        .onChange(of: store.selectedTool) { _, _ in
            collapsedProjects.removeAll()
            store.scheduleBodySearch()
        }
        .onChange(of: sessions.map(\.id)) { _, _ in
            // 検索で見えなくなった項目を一括削除へ混ぜない。
            store.reconcileSelection(visibleSessions: sessions)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.isDeletingSessions {
                    ProgressView()
                        .controlSize(.small)
                        .help("セッションを削除しています")
                } else if store.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .help("保存場所を再確認しています")
                }
                Button {
                    store.reload()
                } label: {
                    Label("再読み込み", systemImage: "arrow.clockwise")
                }
                .disabled(store.isScanning)
            }
        }
    }

    private func outline(_ roots: [SessionTreeNode]) -> some View {
        OutlineGroup(roots, children: \.outlineChildren) { node in
            SessionRow(node: node, bodyPreview: store.bodySearchPreviews[node.session.id])
                .tag(node.session.id)
                .contextMenu {
                    let candidates = store.trashCandidates(for: node.session)
                    let eligibleCount = candidates.filter { $0.isSupported && !$0.isProtected }.count
                    if SessionHierarchy.hasBlockedMemberInFamily(candidates) {
                        Button("親子の一部が保護中") {}
                            .disabled(true)
                    } else if eligibleCount > 0 {
                        Button(
                            node.session.tool == .openCode ? (eligibleCount == 1 ? "完全に削除" : "\(eligibleCount)件を完全に削除") : (eligibleCount == 1 ? "ゴミ箱へ移す" : "\(eligibleCount)件をゴミ箱へ移す"),
                            role: .destructive
                        ) {
                            store.requestTrash(candidates)
                        }
                        .disabled(store.isDeletingSessions || store.isPreparingTrash)
                    }
                }
        }
    }
}

private struct ProjectHeader: View {
    let section: ProjectSection

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: section.project == nil ? "questionmark.folder" : "folder")
                .foregroundStyle(.secondary)
            Text(section.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .help(section.project ?? "プロジェクト未設定")
            Spacer(minLength: 8)
            Text("\(section.sessionCount)件")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(section.totalByteCount.formatted(.byteCount(style: .file)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(section.latestDate.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct DetectionEmptyView: View {
    let shelf: ToolShelf

    var body: some View {
        ContentUnavailableView {
            Label(shelf.status.label, systemImage: "externaldrive.badge.questionmark")
        } description: {
            VStack(spacing: 8) {
                if case .unsupportedFormat(let details) = shelf.status { Text(details) }
                Text("想定パス候補")
                    .font(.caption.bold())
                ForEach(shelf.candidatePaths, id: \.self) { path in
                    Text(path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct SessionRow: View {
    let node: SessionTreeNode
    var bodyPreview: String?

    private var session: SessionSummary { node.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if node.descendantCount > 0 {
                    Text("サブ \(node.descendantCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                KindBadge(kind: session.kind)
            }
            Text(session.overview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let bodyPreview {
                Text(bodyPreview)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                MetaChip(systemImage: "clock", text: session.date.formatted(.relative(presentation: .named)))
                MetaChip(systemImage: "doc", text: session.byteCount.formatted(.byteCount(style: .file)))
                if let project = session.project {
                    MetaChip(systemImage: "folder", text: project)
                }
                if session.lineage?.isSubagent == true {
                    MetaChip(systemImage: "person.2", text: session.lineage?.displayName ?? "サブエージェント")
                }
                if node.isOrphan {
                    MetaChip(systemImage: "link.badge.plus", text: "親なし", tint: .orange)
                }
                if session.isProtected {
                    MetaChip(systemImage: "lock.fill", text: "保護", tint: .orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
