import Foundation

public enum SessionBodySearch {
    public static func previews(for sessions: [SessionSummary], query: String) -> [String: String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [:] }
        var hits: [String: String] = [:]
        for session in sessions {
            guard session.isSupported, let preview = preview(in: text(for: session), query: needle) else { continue }
            hits[session.id] = preview
        }
        return hits
    }

    static func preview(in text: String, query: String) -> String? {
        let folded = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = folded.range(of: query, options: [.caseInsensitive]) else { return nil }
        let start = folded.index(range.lowerBound, offsetBy: -48, limitedBy: folded.startIndex) ?? folded.startIndex
        let end = folded.index(range.upperBound, offsetBy: 48, limitedBy: folded.endIndex) ?? folded.endIndex
        var snippet = folded[start..<end].trimmingCharacters(in: .whitespaces)
        if start != folded.startIndex { snippet = "…" + snippet }
        if end != folded.endIndex { snippet += "…" }
        return snippet
    }

    private static func text(for session: SessionSummary) -> String {
        let parsed: ParsedLog?
        switch (session.tool, session.kind) {
        case (.grokBuildCLI, _):
            parsed = try? LogParsing.parseGrokDirectory(session.sourceURL, byteLimit: LogLimits.listBytes)
        case (.openCode, _):
            parsed = try? OpenCodeRepository.loadDetail(session: session)
        case (.cursorDesktop, .plan):
            parsed = try? LogParsing.parseMarkdown(at: session.sourceURL, byteLimit: LogLimits.listBytes)
        default:
            parsed = try? LogParsing.parseJSONL(at: session.sourceURL, tool: session.tool, byteLimit: LogLimits.listBytes)
        }
        return parsed?.conversation.map(\.text).joined(separator: "\n") ?? ""
    }
}
