import SessionShelfCore
import SwiftUI

struct ToolSidebar: View {
    @ObservedObject var store: SessionShelfStore
    @State private var isStorageExpanded = true

    var body: some View {
        List(selection: $store.selectedDestination) {
            Section("ツール") {
                ForEach(AITool.allCases) { tool in
                    ToolRow(tool: tool, shelf: store.shelves.first { $0.tool == tool })
                        .tag(SidebarDestination.tool(tool))
                }
            }

            Section("整理") {
                DisclosureGroup(isExpanded: $isStorageExpanded) {
                    ForEach(StorageToolFilter.allCases) { filter in
                        StorageSidebarRow(
                            filter: filter,
                            totalByteCount: store.storageTotalByteCount(for: filter),
                            deletableByteCount: store.storageDeletableByteCount(for: filter),
                            isSelected: store.selectedDestination == .storage(filter)
                        )
                        .tag(SidebarDestination.storage(filter))
                    }
                } label: {
                    HStack {
                        Label("ストレージ", systemImage: "internaldrive")
                            .foregroundStyle(.primary)
                        Spacer()
                        if store.isScanningStorage {
                            ProgressView().controlSize(.small)
                        } else if store.storageReport.totalByteCount > 0 {
                            Text(store.storageReport.totalByteCount.formatted(.byteCount(style: .file)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("プライバシー") {
                Label("完全ローカル", systemImage: "lock.shield")
                    .font(.callout)
                Text("ログの本文を外部へ送信しません。検索と概要生成もこのMac内で完結します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Session Shelf")
    }
}

private struct StorageSidebarRow: View {
    let filter: StorageToolFilter
    let totalByteCount: Int64
    let deletableByteCount: Int64
    let isSelected: Bool

    private var symbolName: String {
        switch filter {
        case .all: "square.grid.2x2"
        case .tool(let tool): tool.symbolName
        }
    }

    private var tint: Color {
        switch filter {
        case .all: .cyan
        case .tool(let tool): Theme.toolColor(tool)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(filter.title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
            Spacer(minLength: 6)
            Text(totalByteCount.formatted(.byteCount(style: .file)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(filter.title)、確認済み\(totalByteCount.formatted(.byteCount(style: .file)))、整理候補\(deletableByteCount.formatted(.byteCount(style: .file)))"
        )
        .accessibilityValue(isSelected ? "選択中" : "未選択")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ToolRow: View {
    let tool: AITool
    let shelf: ToolShelf?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tool.symbolName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: Theme.Layout.iconTileSize, height: Theme.Layout.iconTileSize)
                .background(
                    Theme.toolColor(tool).gradient,
                    in: RoundedRectangle(cornerRadius: Theme.Layout.iconTileCornerRadius, style: .continuous)
                )
            Text(tool.displayName)
                .lineLimit(1)
            Spacer()
            statusView
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusView: some View {
        if let status = shelf?.status {
            switch status {
            case .detected(let count):
                Text(count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            case .notDetected, .unsupportedFormat:
                HStack(spacing: 4) {
                    Circle()
                        .fill(Theme.statusColor(status))
                        .frame(width: 6, height: 6)
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
