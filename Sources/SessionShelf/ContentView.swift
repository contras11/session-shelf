import SessionShelfCore
import SwiftUI

struct ContentView: View {
    @StateObject private var store = SessionShelfStore()

    var body: some View {
        NavigationSplitView {
            ToolSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } content: {
            SessionListView(store: store)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 480)
        } detail: {
            SessionDetailView(store: store)
        }
        .task { store.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .sessionShelfReload)) { _ in
            store.reload()
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
            Button("キャンセル", role: .cancel) { store.trashRequest = nil }
        } message: { request in
            Text(trashMessage(for: request))
        }
    }

    private var trashDialogTitle: String {
        guard let request = store.trashRequest else { return "ゴミ箱へ移しますか？" }
        return request.sessions.count == 1
            ? "このセッションをゴミ箱へ移しますか？"
            : "選択した\(request.sessions.count)件をゴミ箱へ移しますか？"
    }

    private func trashButtonTitle(for request: TrashRequest) -> String {
        request.eligible.count == 1 ? "ゴミ箱へ移す" : "\(request.eligible.count)件をゴミ箱へ移す"
    }

    private func trashMessage(for request: TrashRequest) -> String {
        let recovery = "完全削除は行いません。macOSのゴミ箱から戻せます。"
        guard request.excludedCount > 0 else { return recovery }
        return "\(request.excludedCount)件は保護中または未対応のため除外します。\(recovery)"
    }
}
