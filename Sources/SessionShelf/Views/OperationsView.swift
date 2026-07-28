import SessionShelfCore
import SwiftUI

struct OperationsView: View {
    let entries: [OperationEntry]

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("操作履歴がありません", systemImage: "wrench.and.screwdriver")
        } else {
            List(entries) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: Theme.categorySymbol(entry.category))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: Theme.Layout.categoryIconSize, height: Theme.Layout.categoryIconSize)
                        .background(Theme.categoryColor(entry.category).gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.summary)
                            .textSelection(.enabled)
                        if let timestamp = entry.timestamp {
                            Text(timestamp, format: .dateTime.hour().minute().second())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    ResultBadge(result: entry.result)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
    }
}
