import SessionShelfCore
import SwiftUI

enum Theme {
    enum Layout {
        static let iconTileSize: CGFloat = 28
        static let iconTileCornerRadius: CGFloat = 7
        static let categoryIconSize: CGFloat = 22
        static let avatarSize: CGFloat = 24
        static let bubbleCornerRadius: CGFloat = 14
    }

    static func toolColor(_ tool: AITool) -> Color {
        switch tool {
        case .codex: .green
        case .claudeCode: .orange
        case .cursorDesktop: .blue
        case .cursorCLI: .indigo
        case .grokBuildCLI: .purple
        }
    }

    static func statusColor(_ status: DetectionStatus) -> Color {
        switch status {
        case .detected: .secondary
        case .notDetected: .orange
        case .unsupportedFormat: .red
        }
    }

    static func categoryColor(_ category: OperationCategory) -> Color {
        switch category {
        case .investigation: .blue
        case .edit: .orange
        case .test: .green
        case .command: .purple
        case .other: .gray
        }
    }

    static func categorySymbol(_ category: OperationCategory) -> String {
        switch category {
        case .investigation: "magnifyingglass"
        case .edit: "pencil"
        case .test: "checkmark.circle"
        case .command: "terminal"
        case .other: "wrench"
        }
    }

    static func resultColor(_ result: OperationResult) -> Color {
        switch result {
        case .success: .green
        case .failure: .red
        case .unknown: .secondary
        }
    }

    static func speakerColor(_ speaker: Speaker) -> Color {
        switch speaker {
        case .user: .accentColor
        case .assistant: .secondary
        case .system: .gray
        }
    }

    static func speakerSymbol(_ speaker: Speaker) -> String {
        switch speaker {
        case .user: "person.fill"
        case .assistant: "sparkles"
        case .system: "gearshape.fill"
        }
    }

    static func storageSafetyColor(_ safety: StorageSafety) -> Color {
        switch safety {
        case .regeneratable: .green
        case .reviewRequired: .orange
        case .protected: .secondary
        }
    }

    static func storageSafetySymbol(_ safety: StorageSafety) -> String {
        switch safety {
        case .regeneratable: "arrow.triangle.2.circlepath"
        case .reviewRequired: "exclamationmark.triangle.fill"
        case .protected: "lock.fill"
        }
    }
}
