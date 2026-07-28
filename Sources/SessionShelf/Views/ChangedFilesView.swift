import Foundation
import SessionShelfCore
import SwiftUI

struct ChangedFilesView: View {
    let files: [ChangedFile]

    var body: some View {
        if files.isEmpty {
            ContentUnavailableView("変更ファイルを特定できませんでした", systemImage: "doc.badge.ellipsis")
        } else {
            List(files) { file in
                Label {
                    Text(file.path)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: Self.iconName(for: file.path))
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    private static func iconName(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift", "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "java", "c", "cc", "cpp", "h", "hpp":
            "chevron.left.forwardslash.chevron.right"
        case "md", "markdown", "txt", "pdf":
            "doc.text"
        case "json", "jsonl", "yaml", "yml", "toml", "xml", "plist":
            "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg":
            "photo"
        default:
            "doc"
        }
    }
}
