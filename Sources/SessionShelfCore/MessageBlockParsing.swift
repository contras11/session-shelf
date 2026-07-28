import Foundation

public enum MessageBlock: Equatable, Sendable {
    case prose(String)
    case code(language: String?, text: String)
}

public enum MessageBlockParser {
    public static func parse(_ text: String) -> [MessageBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MessageBlock] = []
        var prose: [String] = []
        var code: [String] = []
        var activeFence: Character?
        var activeFenceLength = 0
        var language: String?

        func flushProse() {
            guard !prose.isEmpty else { return }
            blocks.append(.prose(prose.joined(separator: "\n")))
            prose.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            blocks.append(.code(language: language, text: code.joined(separator: "\n")))
            code.removeAll(keepingCapacity: true)
            activeFence = nil
            activeFenceLength = 0
            language = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = activeFence {
                if isFenceLine(trimmed, character: fence, minimumLength: activeFenceLength) {
                    flushCode()
                } else {
                    code.append(line)
                }
            } else if let opening = openingFence(in: trimmed) {
                flushProse()
                activeFence = opening.character
                activeFenceLength = opening.length
                language = opening.language
            } else {
                prose.append(line)
            }
        }

        // 壊れたログでも残りを捨てず、閉じられていないフェンスをコードとして表示する。
        if activeFence != nil { flushCode() }
        flushProse()
        return blocks.isEmpty ? [.prose(text)] : blocks
    }

    private static func openingFence(in line: String) -> (character: Character, length: Int, language: String?)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let length = line.prefix { $0 == first }.count
        guard length >= 3 else { return nil }
        let remainder = String(line.dropFirst(length)).trimmingCharacters(in: .whitespaces)
        return (first, length, remainder.isEmpty ? nil : remainder)
    }

    private static func isFenceLine(_ line: String, character: Character, minimumLength: Int) -> Bool {
        let count = line.prefix { $0 == character }.count
        guard count >= minimumLength else { return false }
        return line.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty
    }
}
