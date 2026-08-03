import SessionShelfCore
import SwiftUI

struct StorageDetailView: View {
    @ObservedObject var store: SessionShelfStore

    var body: some View {
        if let item = store.selectedStorageItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(item)
                    infoSection(
                        title: "これは何ですか？",
                        systemImage: "questionmark.circle",
                        text: item.explanation
                    )
                    infoSection(
                        title: "削除するとどうなりますか？",
                        systemImage: "arrow.right.circle",
                        text: item.deletionImpact
                    )
                    infoSection(
                        title: "この判定の理由",
                        systemImage: "checkmark.shield",
                        text: item.safetyReason
                    )
                    metadata(item)
                    if !store.storageReport.issues.isEmpty {
                        Label(
                            "確認できなかった場所が\(store.storageReport.issues.count)件あります。表示容量には含まれない場合があります。",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    toolbarAction(item)
                }
            }
        } else {
            ContentUnavailableView(
                "ストレージ項目を選択",
                systemImage: "internaldrive",
                description: Text("左の一覧から用途と安全性を確認する項目を選んでください")
            )
        }
    }

    private func header(_ item: StorageItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title).font(.title2.bold()).textSelection(.enabled)
                Spacer()
                Label(item.safety.label, systemImage: Theme.storageSafetySymbol(item.safety))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.storageSafetyColor(item.safety))
            }
            HStack(spacing: 8) {
                MetaChip(systemImage: "internaldrive", text: item.byteCount.formatted(.byteCount(style: .file)))
                MetaChip(systemImage: "doc.on.doc", text: "\(item.fileCount)個")
                MetaChip(systemImage: "tag", text: item.category.label)
                if store.selectedStorageItemIDs.count > 1 {
                    MetaChip(systemImage: "checkmark.circle", text: "\(store.selectedStorageItemIDs.count)件選択中")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func infoSection(title: String, systemImage: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage).font(.headline)
            Text(text).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metadata(_ item: StorageItem) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("ツール").foregroundStyle(.secondary)
                Text(item.tool.displayName)
            }
            GridRow {
                Text("最終更新").foregroundStyle(.secondary)
                Text(item.modifiedAt.formatted(.dateTime.year().month().day().hour().minute()))
            }
            GridRow(alignment: .top) {
                Text("場所").foregroundStyle(.secondary)
                Text(item.location.path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func toolbarAction(_ item: StorageItem) -> some View {
        if store.selectedStorageItemIDs.count > 1, !store.eligibleSelectedStorageItems.isEmpty {
            Button(role: .destructive) {
                store.requestStorageTrashForSelection()
            } label: {
                Label("\(store.eligibleSelectedStorageItems.count)件をゴミ箱へ", systemImage: "trash")
            }
            .help("保護対象を除き、選択した項目をゴミ箱へ移します")
            .disabled(store.isDeletingStorage)
        } else if item.safety == .protected {
            Label("保護対象", systemImage: "lock.fill")
                .foregroundStyle(.orange)
                .help(item.safetyReason)
        } else {
            Button(role: .destructive) {
                store.requestStorageTrash([item])
            } label: {
                Label("ゴミ箱へ", systemImage: "trash")
            }
            .disabled(store.isDeletingStorage)
        }
    }
}
