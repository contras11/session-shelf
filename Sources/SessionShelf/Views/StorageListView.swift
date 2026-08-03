import SessionShelfCore
import SwiftUI

struct StorageListView: View {
    @ObservedObject var store: SessionShelfStore

    var body: some View {
        VStack(spacing: 0) {
            storageSummary
            Divider()
            content
        }
        .navigationTitle("ストレージ")
        .searchable(text: $store.storageSearchText, prompt: "項目・ツールを検索")
        .onChange(of: store.visibleStorageItems.map(\.id)) { _, _ in
            store.reconcileStorageSelection(visibleItems: store.visibleStorageItems)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.isScanningStorage || store.isDeletingStorage {
                    ProgressView()
                        .controlSize(.small)
                        .help(store.isDeletingStorage ? "ゴミ箱へ移動しています" : "容量を確認しています")
                }
                Button {
                    store.reloadStorage()
                } label: {
                    Label("再読み込み", systemImage: "arrow.clockwise")
                }
                .disabled(store.isScanningStorage || store.isDeletingStorage)
            }
        }
    }

    private var storageSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SummaryCard(
                    title: "確認済み容量",
                    value: store.selectedStorageTotalByteCount.formatted(.byteCount(style: .file)),
                    systemImage: "internaldrive"
                )
                SummaryCard(
                    title: "整理できる候補",
                    value: store.selectedStorageDeletableByteCount.formatted(.byteCount(style: .file)),
                    systemImage: "trash.slash"
                )
            }
            Picker("安全度", selection: $store.storageFilter) {
                ForEach(StorageFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if store.isScanningStorage && store.storageReport.items.isEmpty {
            Spacer()
            ProgressView("AIツールの保存場所を確認中…")
            Spacer()
        } else if store.visibleStorageItems.isEmpty {
            ContentUnavailableView(
                store.storageSearchText.isEmpty ? "該当する項目はありません" : "検索結果がありません",
                systemImage: "internaldrive"
            )
        } else {
            List(selection: Binding(
                get: { store.selectedStorageItemIDs },
                set: { store.updateStorageSelection($0, visibleItems: store.visibleStorageItems) }
            )) {
                if store.storageToolFilter == .all {
                    ForEach(AITool.allCases) { tool in
                        let items = store.visibleStorageItems.filter { $0.tool == tool }
                        if !items.isEmpty {
                            Section(tool.displayName) {
                                storageRows(items)
                            }
                        }
                    }
                } else {
                    storageRows(store.visibleStorageItems)
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func storageRows(_ items: [StorageItem]) -> some View {
        ForEach(items) { item in
            StorageItemRow(item: item)
                .tag(item.id)
                .contextMenu {
                    let candidates = store.storageTrashCandidates(for: item)
                    let eligible = candidates.filter { $0.safety != .protected }
                    if !eligible.isEmpty {
                        Button(
                            eligible.count == 1 ? "ゴミ箱へ移す" : "\(eligible.count)件をゴミ箱へ移す",
                            role: .destructive
                        ) {
                            store.requestStorageTrash(candidates)
                        }
                    }
                }
        }
    }
}

private struct SummaryCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.headline.monospacedDigit())
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct StorageItemRow: View {
    let item: StorageItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title).font(.headline).lineLimit(2)
                Spacer(minLength: 8)
                Text(item.safety.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.storageSafetyColor(item.safety))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.storageSafetyColor(item.safety).opacity(0.14), in: Capsule())
            }
            Text(item.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                MetaChip(systemImage: "internaldrive", text: item.byteCount.formatted(.byteCount(style: .file)))
                MetaChip(systemImage: "doc.on.doc", text: "\(item.fileCount)個")
                MetaChip(systemImage: "tag", text: item.category.label)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title)、\(item.safety.label)、\(item.byteCount.formatted(.byteCount(style: .file)))")
    }
}
