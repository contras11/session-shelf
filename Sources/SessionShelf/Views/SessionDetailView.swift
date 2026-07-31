import SessionShelfCore
import SwiftUI

struct SessionDetailView: View {
    @ObservedObject var store: SessionShelfStore

    enum DetailTab: String, CaseIterable, Identifiable {
        case conversation = "会話"
        case plan = "プラン"
        case operations = "操作履歴"
        case files = "変更したファイル"
        case raw = "生ログ"
        var id: String { rawValue }
    }

    var body: some View {
        if let session = store.selectedSession {
            VStack(spacing: 0) {
                DetailHeader(session: session, selectedCount: store.selectedSessionIDs.count)
                Divider()
                content(for: session)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if session.isSupported, store.detail != nil {
                        Picker("表示", selection: $store.selectedDetailTab) {
                            ForEach(availableTabs(for: session, detail: store.detail)) { tab in
                                Text(tab.rawValue).tag(tab.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 360)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    toolbarAction(for: session)
                }
            }
        } else {
            ContentUnavailableView(
                "セッションを選択",
                systemImage: "books.vertical",
                description: Text("左の一覧から内容を確認するセッションを選んでください")
            )
        }
    }

    @ViewBuilder
    private func content(for session: SessionSummary) -> some View {
        if store.isLoadingDetail {
            Spacer()
            ProgressView("ログを読み込み中…")
            Spacer()
        } else if !session.isSupported {
            ContentUnavailableView(
                "未対応の保存形式",
                systemImage: "doc.questionmark",
                description: Text(session.overview)
            )
        } else if let detail = store.detail {
            VStack(spacing: 0) {
                if detail.wasTruncated {
                    Label("大きなログのため表示を一部省略しています", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(.quaternary.opacity(0.4))
                }
                tabContent(detail, session: session)
            }
        } else {
            ContentUnavailableView("内容を表示できません", systemImage: "doc.text.magnifyingglass")
        }
    }

    @ViewBuilder
    private func toolbarAction(for session: SessionSummary) -> some View {
        if store.selectedSessionIDs.count > 1, !store.eligibleSelectedSessions.isEmpty {
            Button(role: .destructive) {
                store.requestTrashForSelection()
            } label: {
                Label("\(store.eligibleSelectedSessions.count)件をゴミ箱へ", systemImage: "trash")
            }
            .help("選択中の削除可能なログをまとめてゴミ箱へ移します")
        } else if store.selectedSessionIDs.count > 1 {
            Label("削除できません", systemImage: "lock.fill")
                .foregroundStyle(.orange)
                .help("選択したログはすべて保護中または未対応です")
        } else if session.isProtected {
            Label("保護対象", systemImage: "lock.fill")
                .foregroundStyle(.orange)
                .help(session.protectionReason ?? "保護対象のためゴミ箱へ移せません")
        } else if session.isSupported {
            Button(role: .destructive) {
                store.requestTrash([session])
            } label: {
                Label("ゴミ箱へ", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ detail: SessionDetail, session: SessionSummary) -> some View {
        let fallback: DetailTab = session.kind == .plan ? .plan : .conversation
        switch DetailTab(rawValue: store.selectedDetailTab) ?? fallback {
        case .conversation:
            ConversationView(entries: detail.conversation)
        case .plan:
            if let document = detail.planDocument {
                PlanDocumentView(
                    document: document,
                    sessionTitle: session.title,
                    sessionOverview: session.overview
                )
            } else {
                ContentUnavailableView("プランがありません", systemImage: "doc.text")
            }
        case .operations:
            OperationsView(entries: detail.operations)
        case .files:
            ChangedFilesView(files: detail.changedFiles)
        case .raw:
            RawLogView(text: detail.rawLog)
        }
    }

    private func availableTabs(for session: SessionSummary, detail: SessionDetail?) -> [DetailTab] {
        if session.kind == .plan { return [.plan, .raw] }
        var tabs: [DetailTab] = [.conversation]
        if detail?.planDocument != nil { tabs.append(.plan) }
        tabs.append(contentsOf: [.operations, .files, .raw])
        return tabs
    }
}

private struct DetailHeader: View {
    let session: SessionSummary
    let selectedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.title)
                .font(.title2.bold())
                .textSelection(.enabled)
            HStack(spacing: 8) {
                MetaChip(
                    systemImage: "calendar",
                    text: session.date.formatted(.dateTime.year().month().day().hour().minute())
                )
                MetaChip(systemImage: "doc", text: session.byteCount.formatted(.byteCount(style: .file)))
                if let project = session.project {
                    MetaChip(systemImage: "folder", text: project)
                }
                if session.isProtected {
                    MetaChip(systemImage: "lock.fill", text: session.protectionReason ?? "保護対象", tint: .orange)
                }
                if selectedCount > 1 {
                    MetaChip(systemImage: "checkmark.circle", text: "\(selectedCount)件選択中")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
