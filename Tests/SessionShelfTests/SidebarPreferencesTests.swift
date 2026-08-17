import SessionShelfCore
import XCTest
@testable import SessionShelf

@MainActor
final class SidebarPreferencesTests: XCTestCase {
    func test設定を保存して再読込できる() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = SidebarPreferences(defaults: defaults)
        preferences.setVisible(false, for: .codex)
        preferences.move(fromOffsets: IndexSet(integer: 5), toOffset: 0)

        let restored = SidebarPreferences(defaults: defaults)
        XCTAssertEqual(restored.orderedTools.first, .openCode)
        XCTAssertFalse(restored.isVisible(.codex))
        XCTAssertEqual(restored.visibleTools, restored.orderedTools.filter { $0 != .codex })
    }

    func test不正な順序を補正して新規項目を末尾へ追加する() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["openCode", "unknown", "openCode", "codex"], forKey: SidebarPreferences.orderKey)
        defaults.set(["unknown", "claudeCode"], forKey: SidebarPreferences.hiddenKey)

        let preferences = SidebarPreferences(defaults: defaults)
        XCTAssertEqual(preferences.orderedTools.prefix(2), [.openCode, .codex])
        XCTAssertEqual(Set(preferences.orderedTools), Set(AITool.allCases))
        XCTAssertEqual(preferences.orderedTools.count, AITool.allCases.count)
        XCTAssertEqual(preferences.hiddenTools, [.claudeCode])
    }

    func test初期設定へ戻せる() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = SidebarPreferences(defaults: defaults)
        preferences.setVisible(false, for: .cursorCLI)
        preferences.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        preferences.reset()

        XCTAssertEqual(preferences.orderedTools, AITool.allCases)
        XCTAssertTrue(preferences.hiddenTools.isEmpty)
        XCTAssertNil(defaults.object(forKey: SidebarPreferences.orderKey))
        XCTAssertNil(defaults.object(forKey: SidebarPreferences.hiddenKey))
    }

    func test非表示になった選択項目を安全な表示先へ移す() {
        let store = SessionShelfStore()
        store.selectedDestination = .tool(.codex)
        store.reconcileSidebarSelection(visibleTools: [.claudeCode, .openCode])
        XCTAssertEqual(store.selectedDestination, .tool(.claudeCode))

        store.selectedDestination = .storage(.tool(.openCode))
        store.reconcileSidebarSelection(visibleTools: [.claudeCode])
        XCTAssertEqual(store.selectedDestination, .storage(.all))

        store.selectedDestination = .tool(.claudeCode)
        store.reconcileSidebarSelection(visibleTools: [])
        XCTAssertEqual(store.selectedDestination, .storage(.all))
    }

    func test全サービスの公式アイコンを読める() {
        for tool in AITool.allCases {
            XCTAssertNotNil(ToolIconView.image(for: tool), "\(tool.displayName)のアイコンを読み込めません")
        }
    }

    private func makeDefaults() -> (String, UserDefaults) {
        let suiteName = "SessionShelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
