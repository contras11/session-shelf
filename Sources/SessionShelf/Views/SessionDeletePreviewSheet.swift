import SessionShelfCore
import SwiftUI

struct SessionDeletePreviewSheet: View {
    let request: TrashRequest
    let isDeleting: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var items: [DeletionPlan.Item] {
        request.plan.items.sorted { $0.byteCount > $1.byteCount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                Section("移動または削除する項目 \(request.plan.fileCount)件") {
                    ForEach(items) { item in
                        PlanItemRow(item: item)
                    }
                }
                if !request.plan.exclusions.isEmpty {
                    Section("除外する項目 \(request.plan.exclusions.count)件") {
                        ForEach(request.plan.exclusions, id: \.sessionID) { exclusion in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.orange)
                                Text(exclusion.sessionTitle)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(exclusion.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("キャンセル", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isDeleting || request.plan.items.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 420, idealHeight: 520)
    }

    private var title: String {
        if request.usesOpenCodeCLI { return "OpenCodeセッションを完全に削除しますか？" }
        if request.rootSessionCount > 0, request.subagentCount > 0 {
            return "親セッションとサブエージェントをゴミ箱へ移しますか？"
        }
        if request.rootSessionCount == 0, request.subagentCount > 0 {
            return request.subagentCount == 1
                ? "このサブエージェントをゴミ箱へ移しますか？"
                : "選択した\(request.subagentCount)件のサブエージェントをゴミ箱へ移しますか？"
        }
        return request.sessions.count == 1
            ? "このセッションをゴミ箱へ移しますか？"
            : "選択した\(request.sessions.count)件をゴミ箱へ移しますか？"
    }

    private var summary: String {
        let size = request.totalByteCount.formatted(.byteCount(style: .file))
        var parts = ["セッション\(request.eligible.count)件、\(request.plan.fileCount)項目、合計\(size)。"]
        if request.subagentCount > 0 {
            parts.append("親セッション\(request.rootSessionCount)件とサブエージェント\(request.subagentCount)件を子から順に処理します。")
        }
        if request.usesOpenCodeCLI {
            parts.append("OpenCodeはゴミ箱へ移らず、公式CLIで完全に削除します。復元できません。")
        }
        return parts.joined()
    }

    private var footnote: String {
        request.usesOpenCodeCLI
            ? "OpenCode以外の項目はmacOSのゴミ箱から戻せます。削除直前に更新時刻とリンクを再確認します。"
            : "完全削除は行いません。macOSのゴミ箱から戻せます。削除直前に更新時刻とリンクを再確認します。"
    }

    private var confirmTitle: String {
        let count = request.eligible.count
        if request.usesOpenCodeCLI {
            return count == 1 ? "完全に削除" : "\(count)件を完全に削除"
        }
        return count == 1 ? "ゴミ箱へ移す" : "\(count)件をゴミ箱へ移す"
    }
}

private struct PlanItemRow: View {
    let item: DeletionPlan.Item

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(item.kind == .openCodeCLI ? .red : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.subheadline.weight(.medium))
                    Text(item.sessionTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(item.kind == .openCodeCLI ? .red : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 8)
            Text(item.byteCount.formatted(.byteCount(style: .file)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var label: String {
        switch item.kind {
        case .sessionLog: item.isDirectory ? "会話ディレクトリ" : "会話ログ"
        case .companionDirectory: item.tool == .omp ? "bashログ" : "付随フォルダ"
        case .relatedDirectory: "関連フォルダ"
        case .relatedFile: "関連ファイル"
        case .shellSnapshot: "シェル状態の記録"
        case .openCodeCLI: "OpenCode CLIで完全削除"
        }
    }

    private var detail: String {
        if let location = item.location { return location.path }
        let sessionID = item.sessionID.replacingOccurrences(of: "opencode:", with: "")
        return "opencode session delete \(sessionID)（ゴミ箱を経由せず、復元できません）"
    }

    private var symbol: String {
        switch item.kind {
        case .openCodeCLI: "exclamationmark.triangle.fill"
        case .shellSnapshot: "terminal"
        default: item.isDirectory ? "folder" : "doc.text"
        }
    }
}
