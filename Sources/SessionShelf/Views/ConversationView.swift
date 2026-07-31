import Foundation
import SessionShelfCore
import SwiftUI

struct ConversationView: View {
    let entries: [ConversationEntry]
    @StateObject private var viewState = ConversationViewState()

    private var hasInternalContext: Bool {
        entries.contains { entry in
            if case .context = entry.kind { return true }
            return false
        }
    }

    private var internalContextCount: Int {
        entries.reduce(into: 0) { count, entry in
            if case .context = entry.kind { count += 1 }
        }
    }

    private var displayItems: [ConversationDisplayItem] {
        ConversationDisplayItem.group(
            entries,
            showsInternalContext: viewState.showsInternalContext
        )
    }

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("会話がありません", systemImage: "bubble.left.and.bubble.right")
        } else {
            VStack(spacing: 0) {
                if hasInternalContext {
                    HStack {
                        Spacer()
                        Toggle(isOn: $viewState.showsInternalContext) {
                            Label("内部情報 \(internalContextCount)件", systemImage: "gearshape")
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("システム指示や実行環境など、会話以外の情報を表示します")
                        .accessibilityIdentifier("conversation.showInternalContext")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
                    Divider()
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(displayItems) { item in
                            switch item {
                            case .message(let entry):
                                MessageBubble(entry: entry)
                            case .context(let entry, let label):
                                ContextBlock(label: label, entry: entry)
                            case .operations(let id, let entries):
                                OperationGroup(id: id, entries: entries)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

private enum ConversationDisplayItem: Identifiable {
    case message(ConversationEntry)
    case context(ConversationEntry, label: String)
    case operations(id: UUID, entries: [ConversationEntry])

    var id: UUID {
        switch self {
        case .message(let entry), .context(let entry, _): entry.id
        case .operations(let id, _): id
        }
    }

    static func group(
        _ entries: [ConversationEntry],
        showsInternalContext: Bool
    ) -> [ConversationDisplayItem] {
        let visible = entries.filter { entry in
            guard case .context = entry.kind else { return true }
            return showsInternalContext
        }
        var items: [ConversationDisplayItem] = []
        var pendingOperations: [ConversationEntry] = []

        func flushOperations() {
            guard let first = pendingOperations.first else { return }
            items.append(.operations(id: first.id, entries: pendingOperations))
            pendingOperations.removeAll(keepingCapacity: true)
        }

        for entry in visible {
            switch entry.kind {
            case .toolCall, .toolResult:
                pendingOperations.append(entry)
            case .message:
                flushOperations()
                items.append(.message(entry))
            case .context(let label):
                flushOperations()
                items.append(.context(entry, label: label))
            }
        }
        flushOperations()
        return items
    }
}

private struct MessageBubble: View {
    let entry: ConversationEntry

    private var isUser: Bool { entry.speaker == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 48) }
            avatar
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(entry.speaker.label)
                        .font(.caption.bold())
                    if let timestamp = entry.timestamp {
                        Text(timestamp, format: .dateTime.hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                ForEach(Array(MessageBlockParser.parse(entry.text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .prose(let text):
                        MarkdownContentView(text: text, compact: true)
                    case .code(let language, let text):
                        CollapsibleCodeBlock(language: language, text: text)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: 760, alignment: .leading)
            .background(
                bubbleColor,
                in: RoundedRectangle(cornerRadius: Theme.Layout.bubbleCornerRadius, style: .continuous)
            )
            if !isUser { Spacer(minLength: 48) }
        }
    }

    private var avatar: some View {
        Image(systemName: Theme.speakerSymbol(entry.speaker))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: Theme.Layout.avatarSize, height: Theme.Layout.avatarSize)
            .background(Theme.speakerColor(entry.speaker).gradient, in: Circle())
    }

    private var bubbleColor: Color {
        switch entry.speaker {
        case .user: Color.accentColor.opacity(0.12)
        case .assistant: Color.secondary.opacity(0.10)
        case .system: Color.secondary.opacity(0.06)
        }
    }

}

private struct OperationGroup: View {
    let id: UUID
    let entries: [ConversationEntry]
    @StateObject private var disclosureState = DisclosureState()

    var body: some View {
        DisclosureGroup(isExpanded: $disclosureState.isExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().padding(.vertical, 8) }
                    OperationDetail(entry: entry)
                }
            }
            .padding(.top, 10)
        } label: {
            Label("操作 \(entries.count)件", systemImage: "terminal")
                .font(.subheadline.weight(.medium))
        }
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("操作 \(entries.count)件")
        .accessibilityValue(disclosureState.isExpanded ? "展開中" : "折りたたみ中")
    }
}

private struct OperationDetail: View {
    let entry: ConversationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                if case .toolResult(let result) = entry.kind {
                    ResultBadge(result: result)
                }
                Spacer(minLength: 8)
                if let timestamp = entry.timestamp {
                    Text(timestamp, format: .dateTime.hour().minute().second())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(entry.text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: String {
        switch entry.kind {
        case .toolCall(let name):
            return isCommand(name) ? "コマンド: \(name)" : "ツール: \(name)"
        case .toolResult: return "実行結果"
        default: return "操作"
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .toolCall(let name): return isCommand(name) ? "terminal" : "wrench.and.screwdriver"
        case .toolResult(let result): return result == .failure ? "xmark.octagon" : "checkmark.circle"
        default: return "gearshape"
        }
    }

    private func isCommand(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("exec") || lower.contains("shell") || lower.contains("command") || lower.contains("bash")
    }
}

private struct ContextBlock: View {
    let label: String
    let entry: ConversationEntry
    @StateObject private var disclosureState = DisclosureState()

    var body: some View {
        DisclosureGroup(isExpanded: $disclosureState.isExpanded) {
            Text(entry.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        } label: {
            Label(label, systemImage: "gearshape")
                .font(.subheadline.weight(.medium))
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel(label)
        .accessibilityValue(disclosureState.isExpanded ? "展開中" : "折りたたみ中")
    }
}

struct CollapsibleCodeBlock: View {
    let language: String?
    let text: String
    @StateObject private var disclosureState = DisclosureState()

    private var title: String {
        guard let language, !language.isEmpty else { return "コード" }
        let shellLanguages = ["sh", "shell", "bash", "zsh", "fish", "console", "terminal"]
        return shellLanguages.contains(language.lowercased()) ? "コマンド（\(language)）" : "コード（\(language)）"
    }

    var body: some View {
        DisclosureGroup(title, isExpanded: $disclosureState.isExpanded) {
            Text(text.isEmpty ? "（空のブロック）" : text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
        .font(.subheadline.weight(.medium))
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityValue(disclosureState.isExpanded ? "展開中" : "折りたたみ中")
    }
}

private final class ConversationViewState: ObservableObject {
    @Published var showsInternalContext = false
}

private final class DisclosureState: ObservableObject {
    @Published var isExpanded = false
}
