import SessionShelfCore
import SwiftUI

struct SessionListView: View {
    @ObservedObject var store: SessionShelfStore

    private var sessions: [SessionSummary] {
        guard let sessions = store.selectedShelf?.sessions else { return [] }
        guard !store.searchText.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(store.searchText)
                || $0.overview.localizedCaseInsensitiveContains(store.searchText)
                || ($0.project?.localizedCaseInsensitiveContains(store.searchText) ?? false)
        }
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
                    ForEach(sessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                            .contextMenu {
                                let candidates = store.trashCandidates(for: session)
                                let eligibleCount = candidates.filter { $0.isSupported && !$0.isProtected }.count
                                if eligibleCount > 0 {
                                    Button(
                                        eligibleCount == 1 ? "ゴミ箱へ移す" : "\(eligibleCount)件をゴミ箱へ移す",
                                        role: .destructive
                                    ) {
                                        store.requestTrash(candidates)
                                    }
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(store.selectedTool?.displayName ?? "セッション")
        .searchable(text: $store.searchText, prompt: "タイトル・プロジェクトを検索")
        .onChange(of: sessions.map(\.id)) { _, _ in
            // 検索で見えなくなった項目を一括削除へ混ぜない。
            store.reconcileSelection(visibleSessions: sessions)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.isScanning {
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
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                KindBadge(kind: session.kind)
            }
            Text(session.overview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                MetaChip(systemImage: "clock", text: session.date.formatted(.relative(presentation: .named)))
                MetaChip(systemImage: "doc", text: session.byteCount.formatted(.byteCount(style: .file)))
                if let project = session.project {
                    MetaChip(systemImage: "folder", text: project)
                }
                if session.isProtected {
                    MetaChip(systemImage: "lock.fill", text: "保護", tint: .orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
