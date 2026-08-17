import SessionShelfCore
import SwiftUI

struct SidebarSettingsView: View {
    @ObservedObject var preferences: SidebarPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("サイドバー")
                .font(.title2.weight(.semibold))
            Text("表示するサービスを選び、ドラッグして並び替えられます。設定は次回起動後も保持されます。")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach(preferences.orderedTools) { tool in
                    HStack(spacing: 10) {
                        ToolIconView(tool: tool, size: 28)
                        Toggle(
                            tool.displayName,
                            isOn: Binding(
                                get: { preferences.isVisible(tool) },
                                set: { preferences.setVisible($0, for: tool) }
                            )
                        )
                        .toggleStyle(.checkbox)
                    }
                    .padding(.vertical, 3)
                    .accessibilityElement(children: .combine)
                }
                .onMove(perform: preferences.move)
            }
            .listStyle(.inset)

            HStack {
                Text("非表示にしてもログの検出・読み取り対象は変わりません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("初期設定に戻す") {
                    preferences.reset()
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
    }
}
