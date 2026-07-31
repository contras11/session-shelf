import Foundation

enum PlanDocumentParser {
    static func parse(_ text: String) -> PlanDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closingIndex = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            return PlanDocument(
                title: firstHeading(in: normalized),
                overview: nil,
                tasks: [],
                body: normalized.trimmingCharacters(in: .whitespacesAndNewlines),
                isProject: nil
            )
        }

        let metadataLines = Array(lines[1..<closingIndex])
        let body = lines[(closingIndex + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var title: String?
        var overview: String?
        var isProject: Bool?
        var tasks: [PlanTask] = []
        var usedTaskIDs: Set<String> = []
        var currentTask: (id: String?, content: String?, status: PlanTaskStatus)?
        var isInTodos = false

        func finishTask() {
            guard let task = currentTask, let content = task.content, !content.isEmpty else {
                currentTask = nil
                return
            }
            let baseID = task.id ?? "task-\(tasks.count + 1)"
            var uniqueID = baseID
            var suffix = 2
            while usedTaskIDs.contains(uniqueID) {
                uniqueID = "\(baseID)-\(suffix)"
                suffix += 1
            }
            usedTaskIDs.insert(uniqueID)
            tasks.append(PlanTask(id: uniqueID, content: content, status: task.status))
            currentTask = nil
        }

        func applyTaskField(_ field: String) {
            if field.hasPrefix("id:") {
                currentTask?.id = scalar(after: "id:", in: field)
            } else if field.hasPrefix("content:") {
                currentTask?.content = scalar(after: "content:", in: field)
            } else if field.hasPrefix("status:") {
                currentTask?.status = taskStatus(scalar(after: "status:", in: field))
            }
        }

        for line in metadataLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isTopLevel = line.first.map { !$0.isWhitespace } ?? false
            if isTopLevel {
                if isInTodos { finishTask() }
                isInTodos = trimmed == "todos:"
                if trimmed.hasPrefix("name:") {
                    title = scalar(after: "name:", in: trimmed)
                } else if trimmed.hasPrefix("overview:") {
                    overview = scalar(after: "overview:", in: trimmed)
                } else if trimmed.hasPrefix("isProject:") {
                    let value = scalar(after: "isProject:", in: trimmed)?.lowercased()
                    isProject = value == "true" ? true : value == "false" ? false : nil
                }
                continue
            }

            guard isInTodos else { continue }
            if trimmed.hasPrefix("- ") {
                finishTask()
                currentTask = (nil, nil, .unknown)
                applyTaskField(String(trimmed.dropFirst(2)))
            } else if currentTask != nil {
                applyTaskField(trimmed)
            }
        }
        finishTask()

        return PlanDocument(
            title: title ?? firstHeading(in: body),
            overview: overview ?? firstParagraph(in: body),
            tasks: tasks,
            body: body,
            isProject: isProject
        )
    }

    private static func scalar(after prefix: String, in line: String) -> String? {
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func taskStatus(_ raw: String?) -> PlanTaskStatus {
        switch raw?.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "completed", "complete", "done": .completed
        case "in_progress", "progress", "started": .inProgress
        case "pending", "todo", "not_started": .pending
        default: .unknown
        }
    }

    private static func firstHeading(in text: String) -> String? {
        for block in MarkdownDocumentParser.parse(text) {
            if case .heading(_, let heading) = block, !heading.isEmpty { return heading }
        }
        return nil
    }

    private static func firstParagraph(in text: String) -> String? {
        let blocks = MarkdownDocumentParser.parse(text)
        for block in blocks {
            if case .paragraph(let paragraph) = block, !paragraph.isEmpty { return paragraph }
        }
        return nil
    }
}

public enum MarkdownDocumentParser {
    public static func parse(_ text: String) -> [MarkdownDocumentBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var result: [MarkdownDocumentBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }

            if let fence = openingFence(trimmed) {
                var code: [String] = []
                index += 1
                while index < lines.count,
                      !isClosingFence(lines[index].trimmingCharacters(in: .whitespaces), fence: fence) {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                result.append(.code(language: fence.language, text: code.joined(separator: "\n")))
                continue
            }

            if let heading = heading(trimmed) {
                result.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                result.append(.divider)
                index += 1
                continue
            }

            if index + 1 < lines.count, isTableSeparator(lines[index + 1]), line.contains("|") {
                let headers = tableCells(line)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                result.append(.table(headers: headers, rows: rows))
                continue
            }

            if unorderedItem(line) != nil {
                var items: [DocumentListItem] = []
                while index < lines.count, let item = unorderedItem(lines[index]) {
                    items.append(item)
                    index += 1
                }
                result.append(.unorderedList(items))
                continue
            }

            if orderedItem(line) != nil {
                var items: [DocumentListItem] = []
                while index < lines.count, let item = orderedItem(lines[index]) {
                    items.append(item)
                    index += 1
                }
                result.append(.orderedList(items))
                continue
            }

            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count {
                    let value = lines[index].trimmingCharacters(in: .whitespaces)
                    guard value.hasPrefix(">") else { break }
                    quote.append(String(value.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                result.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            var paragraph: [String] = [trimmed]
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty { break }
                if heading(next) != nil || openingFence(next) != nil || isDivider(next)
                    || unorderedItem(lines[index]) != nil || orderedItem(lines[index]) != nil
                    || next.hasPrefix(">") || (index + 1 < lines.count && isTableSeparator(lines[index + 1])) {
                    break
                }
                paragraph.append(next)
                index += 1
            }
            result.append(.paragraph(paragraph.joined(separator: " ")))
        }
        return result
    }

    private struct Fence { let character: Character; let length: Int; let language: String? }

    private static func openingFence(_ line: String) -> Fence? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let length = line.prefix { $0 == first }.count
        guard length >= 3 else { return nil }
        let value = line.dropFirst(length).trimmingCharacters(in: .whitespaces)
        return Fence(character: first, length: length, language: value.isEmpty ? nil : value)
    }

    private static func isClosingFence(_ line: String, fence: Fence) -> Bool {
        let count = line.prefix { $0 == fence.character }.count
        return count >= fence.length && line.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        return (level, line.dropFirst(level).trimmingCharacters(in: .whitespaces))
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func unorderedItem(_ line: String) -> DocumentListItem? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let trimmed = line.dropFirst(leading.count)
        guard trimmed.count >= 2, let marker = trimmed.first, ["-", "*", "+"].contains(marker), trimmed.dropFirst().first == " " else { return nil }
        var text = String(trimmed.dropFirst(2))
        var checked: Bool?
        if text.hasPrefix("[ ] ") { checked = false; text = String(text.dropFirst(4)) }
        if text.lowercased().hasPrefix("[x] ") { checked = true; text = String(text.dropFirst(4)) }
        return DocumentListItem(text: text, level: indentationLevel(String(leading)), isChecked: checked)
    }

    private static func orderedItem(_ line: String) -> DocumentListItem? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let trimmed = line.dropFirst(leading.count)
        guard let dot = trimmed.firstIndex(of: "."), !trimmed[..<dot].isEmpty,
              trimmed[..<dot].allSatisfy(\.isNumber), trimmed.index(after: dot) < trimmed.endIndex,
              trimmed[trimmed.index(after: dot)] == " " else { return nil }
        let text = String(trimmed[trimmed.index(dot, offsetBy: 2)...])
        return DocumentListItem(text: text, level: indentationLevel(String(leading)))
    }

    private static func indentationLevel(_ leading: String) -> Int {
        leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
