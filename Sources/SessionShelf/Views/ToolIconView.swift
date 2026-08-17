import AppKit
import SessionShelfCore
import SwiftUI

struct ToolIconView: View {
    let tool: AITool
    let size: CGFloat

    var body: some View {
        Group {
            if let image = Self.image(for: tool) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size <= 22 ? 2 : 3)
                    .background(.white, in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .stroke(.black.opacity(0.08), lineWidth: 0.5)
                    }
            } else {
                Image(systemName: tool.symbolName)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
                    .background(
                        Theme.toolColor(tool).gradient,
                        in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static func image(for tool: AITool) -> NSImage? {
        let name = tool.iconAssetName
        let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "ToolIcons")
            ?? Bundle.module.url(forResource: name, withExtension: "png")
        return url.flatMap(NSImage.init(contentsOf:))
    }
}

private extension AITool {
    var iconAssetName: String {
        switch self {
        case .codex: "codex"
        case .claudeCode: "claude-code"
        case .cursorDesktop, .cursorCLI: "cursor"
        case .grokBuildCLI: "grok-build"
        case .openCode: "opencode"
        }
    }
}
