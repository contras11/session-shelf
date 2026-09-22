import SwiftUI

struct RawLogView: View {
    let text: String
    @State private var wrapsLines = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Toggle(isOn: $wrapsLines) {
                    Label("折り返す", systemImage: "text.justify.left")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(wrapsLines ? "右端で折り返しています" : "横スクロールで表示しています")
                .accessibilityIdentifier("rawLog.wrapLines")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if wrapsLines {
                ScrollView(.vertical) {
                    rawText
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                ScrollView([.horizontal, .vertical]) {
                    rawText
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var rawText: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(16)
    }
}
