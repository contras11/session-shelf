import SessionShelfCore
import SwiftUI

struct ToolSidebar: View {
    @ObservedObject var store: SessionShelfStore

    var body: some View {
        List(selection: $store.selectedTool) {
            Section("ツール") {
                ForEach(AITool.allCases) { tool in
                    ToolRow(tool: tool, shelf: store.shelves.first { $0.tool == tool })
                        .tag(tool)
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
