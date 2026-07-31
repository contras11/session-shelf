import SessionShelfCore
import SwiftUI

struct PlanDocumentView: View {
    let document: PlanDocument
    let sessionTitle: String
    let sessionOverview: String

    private var completedTaskCount: Int {
        document.tasks.filter { $0.status == .completed }.count
    }

    private var overview: String? {
        let value = document.overview ?? sessionOverview
        return value.isEmpty ? nil : value
    }

    private var blocks: [MarkdownDocumentBlock] {
        var parsed = MarkdownDocumentParser.parse(document.body)
        if case .heading(let level, let text) = parsed.first,
           level == 1,
           normalized(text) == normalized(sessionTitle) || normalized(text) == normalized(document.title ?? "") {
            parsed.removeFirst()
        }
        return parsed
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if overview != nil || !document.tasks.isEmpty {
                    summary
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("plan.document")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let overview {
                Text(inlineMarkdown(overview))
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .accessibilityLabel("概要。\(overview)")
            }
            if !document.tasks.isEmpty {
                Divider()
                HStack {
                    Label("タスク", systemImage: "checklist")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("\(completedTaskCount) / \(document.tasks.count) 完了")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(document.tasks) { task in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: taskSymbol(task.status))
                                .foregroundStyle(taskColor(task.status))
                                .accessibilityHidden(true)
                            Text(inlineMarkdown(task.content))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(task.status.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(task.content)、\(task.status.label)")
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private func taskSymbol(_ status: PlanTaskStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.lefthalf.filled"
        case .pending: "circle"
        case .unknown: "questionmark.circle"
        }
    }

    private func taskColor(_ status: PlanTaskStatus) -> Color {
        switch status {
        case .completed: .green
        case .inProgress: .blue
        case .pending, .unknown: .secondary
        }
    }
}

struct MarkdownContentView: View {
    let text: String
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 18) {
            ForEach(Array(MarkdownDocumentParser.parse(text).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, compact: compact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownDocumentBlock
    var compact = false

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 8 : 2)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .unorderedList(let items):
            list(items, ordered: false)
        case .orderedList(let items):
            list(items, ordered: true)
        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3)
                Text(inlineMarkdown(text))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
        case .table(let headers, let rows):
            table(headers: headers, rows: rows)
        case .code(let language, let text):
            CollapsibleCodeBlock(language: language, text: text)
        case .divider:
            Divider()
        }
    }

    private func list(_ items: [DocumentListItem], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let checked = item.isChecked {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(checked ? Color.green : Color.secondary)
                            .accessibilityHidden(true)
                    } else {
                        Text(ordered ? "\(index + 1)." : "•")
                            .foregroundStyle(.secondary)
                    }
                    Text(inlineMarkdown(item.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(item.level) * 18)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(listAccessibilityLabel(item, index: index, ordered: ordered))
            }
        }
    }

    private func table(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        Text(inlineMarkdown(header))
                            .font(.subheadline.bold())
                            .padding(.vertical, 8)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(headers.indices, id: \.self) { column in
                            Text(inlineMarkdown(column < row.count ? row[column] : ""))
                                .padding(.vertical, 7)
                                .textSelection(.enabled)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
            .padding(.horizontal, 12)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private func headingFont(_ level: Int) -> Font {
        if compact {
            return switch level {
            case 1: .title2.bold()
            case 2: .title3.bold()
            default: .headline
            }
        }
        return switch level {
        case 1: .title.bold()
        case 2: .title2.bold()
        case 3: .title3.bold()
        default: .headline
        }
    }

    private func listAccessibilityLabel(_ item: DocumentListItem, index: Int, ordered: Bool) -> String {
        if let checked = item.isChecked {
            return "\(checked ? "完了" : "未完了")、\(item.text)"
        }
        return ordered ? "\(index + 1)番、\(item.text)" : item.text
    }
}

func inlineMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}
