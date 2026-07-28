import Foundation

public enum AITool: String, CaseIterable, Identifiable, Codable, Sendable {
    case codex
    case claudeCode
    case cursorDesktop
    case cursorCLI
    case grokBuildCLI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .cursorDesktop: "Cursor Desktop"
        case .cursorCLI: "Cursor CLI"
        case .grokBuildCLI: "Grok Build CLI"
        }
    }

    public var symbolName: String {
        switch self {
        case .codex: "terminal"
        case .claudeCode: "sparkles"
        case .cursorDesktop: "cursorarrow.rays"
        case .cursorCLI: "chevron.left.forwardslash.chevron.right"
        case .grokBuildCLI: "hammer"
        }
    }
}

public enum DetectionStatus: Equatable, Sendable {
    case detected(count: Int)
    case notDetected
    case unsupportedFormat(details: String)

    public var label: String {
        switch self {
        case .detected(let count): "\(count)件"
        case .notDetected: "未検出"
        case .unsupportedFormat: "未対応の保存形式"
        }
    }
}

public struct ToolShelf: Identifiable, Equatable, Sendable {
    public let tool: AITool
    public let status: DetectionStatus
    public let candidatePaths: [String]
    public let sessions: [SessionSummary]

    public var id: AITool { tool }

    public init(tool: AITool, status: DetectionStatus, candidatePaths: [String], sessions: [SessionSummary]) {
        self.tool = tool
        self.status = status
        self.candidatePaths = candidatePaths
        self.sessions = sessions
    }
}

public enum SessionKind: String, Sendable {
    case conversation = "会話"
    case plan = "プラン"
}

public struct SessionSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let tool: AITool
    public let kind: SessionKind
    public let title: String
    public let date: Date
    public let byteCount: Int64
    public let project: String?
    public let overview: String
    public let sourceURL: URL
    public let deletionURL: URL
    public let isSupported: Bool
    public let isProtected: Bool
    public let protectionReason: String?

    public init(
        id: String,
        tool: AITool,
        kind: SessionKind = .conversation,
        title: String,
        date: Date,
        byteCount: Int64,
        project: String?,
        overview: String,
        sourceURL: URL,
        deletionURL: URL? = nil,
        isSupported: Bool = true,
        isProtected: Bool = false,
        protectionReason: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.kind = kind
        self.title = title
        self.date = date
        self.byteCount = byteCount
        self.project = project
        self.overview = overview
        self.sourceURL = sourceURL
        self.deletionURL = deletionURL ?? sourceURL
        self.isSupported = isSupported
        self.isProtected = isProtected
        self.protectionReason = protectionReason
    }
}

public enum Speaker: String, Sendable {
    case user
    case assistant
    case system

    public var label: String {
        switch self {
        case .user: "あなた"
        case .assistant: "AI"
        case .system: "システム"
        }
    }
}

public struct ConversationEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let speaker: Speaker
    public let text: String
    public let timestamp: Date?
    public let kind: ConversationEntryKind

    public init(
        id: UUID = UUID(),
        speaker: Speaker,
        text: String,
        timestamp: Date? = nil,
        kind: ConversationEntryKind = .message
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
        self.kind = kind
    }
}

public enum ConversationEntryKind: Equatable, Sendable {
    case message
    case context(label: String)
    case toolCall(name: String)
    case toolResult(result: OperationResult)
}

public enum OperationCategory: String, Sendable {
    case investigation = "調査"
    case edit = "編集"
    case test = "テスト"
    case command = "コマンド"
    case other = "操作"
}

public enum OperationResult: String, Sendable {
    case success = "成功"
    case failure = "失敗"
    case unknown = "結果不明"
}

public struct OperationEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let category: OperationCategory
    public let summary: String
    public let result: OperationResult
    public let timestamp: Date?

    public init(id: UUID = UUID(), category: OperationCategory, summary: String, result: OperationResult, timestamp: Date? = nil) {
        self.id = id
        self.category = category
        self.summary = summary
        self.result = result
        self.timestamp = timestamp
    }
}

public struct ChangedFile: Identifiable, Hashable, Sendable {
    public let path: String
    public var id: String { path }

    public init(path: String) { self.path = path }
}

public struct SessionDetail: Sendable {
    public let conversation: [ConversationEntry]
    public let operations: [OperationEntry]
    public let changedFiles: [ChangedFile]
    public let rawLog: String
    public let wasTruncated: Bool

    public init(
        conversation: [ConversationEntry],
        operations: [OperationEntry],
        changedFiles: [ChangedFile],
        rawLog: String,
        wasTruncated: Bool
    ) {
        self.conversation = conversation
        self.operations = operations
        self.changedFiles = changedFiles
        self.rawLog = rawLog
        self.wasTruncated = wasTruncated
    }
}

public enum SessionShelfError: LocalizedError, Equatable {
    case unreadable(String)
    case unsupported(String)
    case protectedItem(String)
    case outsideAllowedLocation

    public var errorDescription: String? {
        switch self {
        case .unreadable(let message): "ログを読めませんでした: \(message)"
        case .unsupported(let message): "未対応の保存形式です: \(message)"
        case .protectedItem(let reason): "保護対象のため移動できません: \(reason)"
        case .outsideAllowedLocation: "許可されたセッション保存場所の外にあるため移動できません"
        }
    }
}
