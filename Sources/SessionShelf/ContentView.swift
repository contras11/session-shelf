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
        }
        .onChange(of: sidebarPreferences.visibleTools, initial: true) { _, visibleTools in
            store.applyToolVisibility(visibleTools)
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
        .sheet(item: $store.trashRequest) { request in
            SessionDeletePreviewSheet(
                request: request,
                isDeleting: store.isDeletingSessions,
                onConfirm: { store.confirmTrash(request) },
                onCancel: { store.trashRequest = nil }
            )
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
