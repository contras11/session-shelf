import SessionShelfCore
import SwiftUI

struct ContentView: View {
    @StateObject private var store = SessionShelfStore()
    @ObservedObject var sidebarPreferences: SidebarPreferences

    var body: some View {
        NavigationSplitView {
            ToolSidebar(store: store, preferences: sidebarPreferences)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } content: {
            Group {
                if store.isStoragePresented {
                    StorageListView(store: store)
                } else {
                    SessionListView(store: store)
                }
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 480)
        } detail: {
            if store.isStoragePresented {
                StorageDetailView(store: store)
            } else {
                SessionDetailView(store: store)
            }
        }
        .task {
            store.reload()
            store.reloadStorage()
            store.reconcileSidebarSelection(visibleTools: sidebarPreferences.visibleTools)
        }
        .onChange(of: sidebarPreferences.visibleTools) { _, visibleTools in
            store.reconcileSidebarSelection(visibleTools: visibleTools)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionShelfReload)) { _ in
            if store.isStoragePresented {
                store.reloadStorage()
            } else {
                store.reload()
            }
        }
        .alert("Session Shelf", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("閉じる", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog(
            trashDialogTitle,
            isPresented: Binding(
                get: { store.trashRequest != nil },
                set: { if !$0 { store.trashRequest = nil } }
            ),
            titleVisibility: .visible,
            presenting: store.trashRequest
        ) { request in
            Button(trashButtonTitle(for: request), role: .destructive) {
                store.confirmTrash(request)
            }
            .disabled(store.isDeletingSessions)
            Button("キャンセル", role: .cancel) { store.trashRequest = nil }
        } message: { request in
            Text(trashMessage(for: request))
        }
        .confirmationDialog(
            storageTrashDialogTitle,
            isPresented: Binding(
                get: { store.storageTrashRequest != nil },
                set: { if !$0 { store.storageTrashRequest = nil } }
            ),
            titleVisibility: .visible,
            presenting: store.storageTrashRequest
        ) { request in
            Button(storageTrashButtonTitle(for: request), role: .destructive) {
                store.confirmStorageTrash(request)
            }
            .disabled(store.isDeletingStorage)
            Button("キャンセル", role: .cancel) { store.storageTrashRequest = nil }
        } message: { request in
            Text(storageTrashMessage(for: request))
        }
    }

    private var trashDialogTitle: String {
        guard let request = store.trashRequest else { return "ゴミ箱へ移しますか？" }
        if request.sessions.contains(where: { $0.tool == .openCode }) { return "OpenCodeセッションを完全に削除しますか？" }
        return request.sessions.count == 1
            ? "このセッションをゴミ箱へ移しますか？"
            : "選択した\(request.sessions.count)件をゴミ箱へ移しますか？"
    }

    private func trashButtonTitle(for request: TrashRequest) -> String {
        if request.sessions.contains(where: { $0.tool == .openCode }) {
            return request.eligible.count == 1 ? "完全に削除" : "\(request.eligible.count)件を完全に削除"
        }
        return request.eligible.count == 1 ? "ゴミ箱へ移す" : "\(request.eligible.count)件をゴミ箱へ移す"
    }

    private func trashMessage(for request: TrashRequest) -> String {
        if request.sessions.contains(where: { $0.tool == .openCode }) {
            var parts = ["ゴミ箱へ移らず復元できません。公式OpenCode CLIで完全に削除します。"]
            if request.excludedCount > 0 {
                parts.append("\(request.excludedCount)件は保護中または未対応のため除外します。")
            }
            return parts.joined()
        }
        var parts: [String] = []
        if request.eligible.contains(where: includesRelatedFiles) {
            let relatedCount = request.eligible.reduce(0) { $0 + $1.relatedURLs.count }
            if relatedCount > 0 {
                parts.append("会話ログと関連ファイル\(relatedCount)件もゴミ箱へ移します。")
            } else {
                parts.append("会話ログと、同じセッションの関連ファイルもゴミ箱へ移します。")
            }
        }
        parts.append("完全削除は行いません。macOSのゴミ箱から戻せます。")
        if request.excludedCount > 0 {
            parts.append("\(request.excludedCount)件は保護中または未対応のため除外します。")
        }
        return parts.joined()
    }

    private func includesRelatedFiles(_ session: SessionSummary) -> Bool {
        !session.relatedURLs.isEmpty
            || session.deletionURL.standardizedFileURL != session.sourceURL.standardizedFileURL
    }

    private var storageTrashDialogTitle: String {
        guard let request = store.storageTrashRequest else { return "ゴミ箱へ移しますか？" }
        if request.requiresStrongWarning {
            return request.eligible.count == 1
                ? "失われる可能性があるデータを移しますか？"
                : "失われる可能性がある\(request.eligible.count)件を移しますか？"
        }
        return request.eligible.count == 1
            ? "この項目をゴミ箱へ移しますか？"
            : "選択した\(request.eligible.count)件をゴミ箱へ移しますか？"
    }

    private func storageTrashButtonTitle(for request: StorageTrashRequest) -> String {
        request.eligible.count == 1 ? "内容を理解してゴミ箱へ移す" : "\(request.eligible.count)件をゴミ箱へ移す"
    }

    private func storageTrashMessage(for request: StorageTrashRequest) -> String {
        var parts: [String] = []
        if request.requiresStrongWarning {
            parts.append("「要確認」の項目には、再生成できない画像や診断記録が含まれる可能性があります。")
        } else {
            parts.append("必要になったデータは各ツールが再取得または再作成します。")
        }
        if request.excludedCount > 0 {
            parts.append("\(request.excludedCount)件は保護対象のため除外します。")
        }
        parts.append("完全削除は行いません。macOSのゴミ箱から戻せます。")
        return parts.joined()
    }
}
