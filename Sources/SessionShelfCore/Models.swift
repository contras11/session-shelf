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

public enum StorageCategory: String, CaseIterable, Codable, Sendable {
    case cache
    case temporary
    case generatedOutput
    case diagnostic
    case conversation
    case applicationData
    case customization
    case configuration
    case unknown

    public var label: String {
        switch self {
        case .cache: "キャッシュ"
        case .temporary: "一時ファイル"
        case .generatedOutput: "生成物"
        case .diagnostic: "診断ログ"
        case .conversation: "会話履歴"
        case .applicationData: "アプリの動作データ"
        case .customization: "カスタマイズ"
        case .configuration: "設定・認証"
        case .unknown: "未対応データ"
        }
    }
}

public enum StorageSafety: Int, CaseIterable, Codable, Comparable, Sendable {
    case regeneratable = 0
    case reviewRequired = 1
    case protected = 2

    public static func < (lhs: StorageSafety, rhs: StorageSafety) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .regeneratable: "再生成可能"
        case .reviewRequired: "要確認"
        case .protected: "保護"
        }
    }
}

public struct StorageItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let tool: AITool
    public let category: StorageCategory
    public let safety: StorageSafety
    public let title: String
    public let explanation: String
    public let deletionImpact: String
    public let safetyReason: String
    public let byteCount: Int64
    public let fileCount: Int
    public let modifiedAt: Date
    public let location: URL
    public let containsSymbolicLink: Bool

    public init(
        id: String,
        tool: AITool,
        category: StorageCategory,
        safety: StorageSafety,
        title: String,
        explanation: String,
        deletionImpact: String,
        safetyReason: String,
        byteCount: Int64,
        fileCount: Int,
        modifiedAt: Date,
        location: URL,
        containsSymbolicLink: Bool = false
    ) {
        self.id = id
        self.tool = tool
        self.category = category
        self.safety = safety
        self.title = title
        self.explanation = explanation
        self.deletionImpact = deletionImpact
        self.safetyReason = safetyReason
        self.byteCount = byteCount
        self.fileCount = fileCount
        self.modifiedAt = modifiedAt
        self.location = location
        self.containsSymbolicLink = containsSymbolicLink
    }
}

public struct StorageScanIssue: Identifiable, Equatable, Sendable {
    public let path: String
    public let message: String
    public var id: String { path }

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public struct StorageScanReport: Equatable, Sendable {
    public let items: [StorageItem]
    public let issues: [StorageScanIssue]
    public let wasCancelled: Bool

    public init(items: [StorageItem], issues: [StorageScanIssue] = [], wasCancelled: Bool = false) {
        self.items = items
        self.issues = issues
        self.wasCancelled = wasCancelled
    }

    public var totalByteCount: Int64 { items.reduce(0) { $0 + $1.byteCount } }
    public var deletableByteCount: Int64 {
        items.filter { $0.safety != .protected }.reduce(0) { $0 + $1.byteCount }
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

public enum PlanTaskStatus: String, Equatable, Sendable {
    case pending
    case inProgress
    case completed
    case unknown

    public var label: String {
        switch self {
        case .pending: "未着手"
        case .inProgress: "進行中"
        case .completed: "完了"
        case .unknown: "状態不明"
        }
    }
}

public struct PlanTask: Identifiable, Equatable, Sendable {
    public let id: String
    public let content: String
    public let status: PlanTaskStatus

    public init(id: String, content: String, status: PlanTaskStatus) {
        self.id = id
        self.content = content
        self.status = status
    }
}

public struct PlanDocument: Equatable, Sendable {
    public let title: String?
    public let overview: String?
    public let tasks: [PlanTask]
    public let body: String
    public let isProject: Bool?

    public init(title: String?, overview: String?, tasks: [PlanTask], body: String, isProject: Bool?) {
        self.title = title
        self.overview = overview
        self.tasks = tasks
        self.body = body
        self.isProject = isProject
    }
}

public struct DocumentListItem: Equatable, Sendable {
    public let text: String
    public let level: Int
    public let isChecked: Bool?

    public init(text: String, level: Int = 0, isChecked: Bool? = nil) {
        self.text = text
        self.level = level
        self.isChecked = isChecked
    }
}

public enum MarkdownDocumentBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([DocumentListItem])
    case orderedList([DocumentListItem])
    case quote(String)
    case table(headers: [String], rows: [[String]])
    case code(language: String?, text: String)
    case divider
}

public struct SessionDetail: Sendable {
    public let conversation: [ConversationEntry]
    public let operations: [OperationEntry]
    public let changedFiles: [ChangedFile]
    public let rawLog: String
    public let wasTruncated: Bool
    public let planDocument: PlanDocument?

    public init(
        conversation: [ConversationEntry],
        operations: [OperationEntry],
        changedFiles: [ChangedFile],
        rawLog: String,
        wasTruncated: Bool,
        planDocument: PlanDocument? = nil
    ) {
        self.conversation = conversation
        self.operations = operations
        self.changedFiles = changedFiles
        self.rawLog = rawLog
        self.wasTruncated = wasTruncated
        self.planDocument = planDocument
    }
}

public enum SessionShelfError: LocalizedError, Equatable {
    case unreadable(String)
    case unsupported(String)
    case protectedItem(String)
    case outsideAllowedLocation
    case storageItemChanged
    case scanCancelled

    public var errorDescription: String? {
        switch self {
        case .unreadable(let message): "ログを読めませんでした: \(message)"
        case .unsupported(let message): "未対応の保存形式です: \(message)"
        case .protectedItem(let reason): "保護対象のため移動できません: \(reason)"
        case .outsideAllowedLocation: "許可されたセッション保存場所の外にあるため移動できません"
        case .storageItemChanged: "確認後に内容が変わったため、安全のため移動を中止しました"
        case .scanCancelled: "ストレージの確認を中止しました"
        }
    }
}
