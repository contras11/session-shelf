import SessionShelfCore
import SwiftUI

struct MetaChip: View {
    let systemImage: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }
}

struct KindBadge: View {
    let kind: SessionKind

    var body: some View {
        Text(kind.rawValue)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

struct ResultBadge: View {
    let result: OperationResult

    var body: some View {
        Text(result.rawValue)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.resultColor(result))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.resultColor(result).opacity(0.15), in: Capsule())
    }
}
