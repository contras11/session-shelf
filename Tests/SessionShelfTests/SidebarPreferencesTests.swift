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
        XCTAssertTrue(preferences.orderedTools.contains(.omp))
        XCTAssertTrue(preferences.isVisible(.omp))
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
        store.applyToolVisibility([.claudeCode, .openCode])
        XCTAssertEqual(store.selectedDestination, .tool(.claudeCode))
        XCTAssertEqual(store.visibleTools, [.claudeCode, .openCode])

        store.selectedDestination = .storage(.tool(.openCode))
        store.applyToolVisibility([.claudeCode])
        XCTAssertEqual(store.selectedDestination, .storage(.all))

        store.selectedDestination = .tool(.claudeCode)
        store.applyToolVisibility([])
        XCTAssertEqual(store.selectedDestination, .storage(.all))
    }

    func test非表示ツールはストレージ集計から外れる() {
        let store = SessionShelfStore()
        let now = Date()
        func item(_ tool: AITool, _ bytes: Int64) -> StorageItem {
            StorageItem(
                id: "\(tool.rawValue):fixture", tool: tool, category: .cache, safety: .regeneratable,
                title: tool.displayName, explanation: "", deletionImpact: "", safetyReason: "",
                byteCount: bytes, fileCount: 1, modifiedAt: now, location: URL(fileURLWithPath: "/tmp/\(tool.rawValue)")
            )
        }
        store.storageReport = StorageScanReport(items: [item(.codex, 100), item(.omp, 50)])
        XCTAssertEqual(store.storageTotalByteCount(for: .all), 150)

        store.applyToolVisibility([.codex])
        XCTAssertEqual(store.storageTotalByteCount(for: .all), 100)
        XCTAssertEqual(store.storageItems(for: .tool(.omp)), [])
        XCTAssertEqual(store.storageReport.items.count, 2)
    }

    func testアイコン素材があるサービスの公式アイコンを読める() {
        for tool in AITool.allCases {
            if tool.iconAssetName == nil {
                XCTAssertNil(ToolIconView.image(for: tool))
                continue
            }
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
