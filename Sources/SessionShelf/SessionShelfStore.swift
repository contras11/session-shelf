import Foundation
import SessionShelfCore

struct TrashRequest: Identifiable {
    let id = UUID()
    let sessions: [SessionSummary]
    let plan: DeletionPlan

    var eligible: [SessionSummary] {
        sessions.filter { $0.isSupported && !$0.isProtected }
    }

    var excludedCount: Int { sessions.count - eligible.count }
    var subagentCount: Int { sessions.filter { $0.lineage?.isSubagent == true }.count }
    var rootSessionCount: Int { sessions.count - subagentCount }
    var totalByteCount: Int64 { plan.totalByteCount }
    var usesOpenCodeCLI: Bool { sessions.contains { $0.tool == .openCode } }
}

enum SidebarDestination: Hashable {
    case tool(AITool)
    case storage(StorageToolFilter)
}

enum StorageFilter: String, CaseIterable, Identifiable {
    case all = "すべて"
    case regeneratable = "再生成可能"
    case reviewRequired = "要確認"
    case protected = "保護"

    var id: String { rawValue }

    func includes(_ item: StorageItem) -> Bool {
        switch self {
        case .all: true
        case .regeneratable: item.safety == .regeneratable
        case .reviewRequired: item.safety == .reviewRequired
        case .protected: item.safety == .protected
        }
    }
}

enum StorageToolFilter: Hashable, Identifiable {
    case all
    case tool(AITool)

    static var allCases: [StorageToolFilter] {
        [.all] + AITool.allCases.map(StorageToolFilter.tool)
    }

    var id: String {
        switch self {
        case .all: "all"
        case .tool(let tool): tool.id
        }
    }

    var title: String {
        switch self {
        case .all: "すべて"
        case .tool(let tool): tool.displayName
        }
    }

    func includes(_ item: StorageItem) -> Bool {
        switch self {
        case .all: true
        case .tool(let tool): item.tool == tool
        }
    }
}

struct StorageTrashRequest: Identifiable {
    let id = UUID()
    let items: [StorageItem]

    var eligible: [StorageItem] { items.filter { $0.safety != .protected } }
    var excludedCount: Int { items.count - eligible.count }
    var requiresStrongWarning: Bool { eligible.contains { $0.safety == .reviewRequired } }
}

private struct SessionDeletionResult: Sendable {
    let succeeded: Set<String>
    let failures: [(title: String, reason: String)]
}

@MainActor
final class SessionShelfStore: ObservableObject {
    @Published var shelves: [ToolShelf] = []
    @Published var selectedDestination: SidebarDestination? = .tool(.codex) {
        didSet {
            guard oldValue != selectedDestination else { return }
            if let filter = selectedDestination?.storageFilter {
                lastStorageToolFilter = filter
            }
            if oldValue?.tool != selectedDestination?.tool { clearSelection() }
            if oldValue?.storageFilter != selectedDestination?.storageFilter {
                reconcileStorageSelection(visibleItems: visibleStorageItems)
            }
        }
    }
    @Published var selectedSessionIDs: Set<String> = []
    @Published var selectedSession: SessionSummary?
    @Published var detail: SessionDetail?
    @Published var isScanning = false
    @Published var isLoadingDetail = false
    @Published var errorMessage: String?
    @Published var trashRequest: TrashRequest?
    @Published var searchText = ""
    @Published var selectedDetailTab = "会話"
    @Published var storageReport = StorageScanReport(items: [])
    @Published var isScanningStorage = false
    @Published var storageFilter: StorageFilter = .all
    @Published var storageSearchText = ""
    @Published var selectedStorageItemIDs: Set<String> = []
    @Published var selectedStorageItem: StorageItem?
    @Published var storageTrashRequest: StorageTrashRequest?
    @Published var isDeletingSessions = false
    @Published var isDeletingStorage = false
    @Published private(set) var isPreparingTrash = false
    @Published private(set) var lastStorageToolFilter: StorageToolFilter = .all
    @Published private(set) var visibleTools: [AITool] = AITool.allCases

    private let repository: SessionRepository
    private let storageRepository: StorageRepository
    private let deleteSession: @Sendable (SessionSummary, SessionDeletionMode) throws -> Void
    private var trashPlanGeneration = UUID()
    private var scanGeneration = UUID()
    private var storageScanGeneration = UUID()
    private var storageScanTask: Task<Void, Never>?
    private var detailGeneration = UUID()
    private var selectionState = SessionSelectionState()
    private var storageSelectionState = SessionSelectionState()

    init(
        repository: SessionRepository = SessionRepository(),
        storageRepository: StorageRepository = StorageRepository(),
        deleteSession: (@Sendable (SessionSummary, SessionDeletionMode) throws -> Void)? = nil
    ) {
        self.repository = repository
        self.storageRepository = storageRepository
        self.deleteSession = deleteSession ?? { session, mode in
            try repository.delete(session, mode: mode)
        }
    }

    var selectedTool: AITool? { selectedDestination?.tool }
    var isStoragePresented: Bool { selectedDestination?.storageFilter != nil }
    var storageToolFilter: StorageToolFilter {
        selectedDestination?.storageFilter ?? lastStorageToolFilter
    }

    func applyToolVisibility(_ tools: [AITool]) {
        visibleTools = tools
        switch selectedDestination {
        case .tool(let tool) where !visibleTools.contains(tool):
            selectedDestination = visibleTools.first.map(SidebarDestination.tool) ?? .storage(.all)
        case .storage(.tool(let tool)) where !visibleTools.contains(tool):
            selectedDestination = .storage(.all)
        default:
            break
        }
    }

    var selectedShelf: ToolShelf? {
        shelves.first { $0.tool == selectedTool }
    }

    var selectedSessions: [SessionSummary] {
        selectedShelf?.sessions.filter { selectedSessionIDs.contains($0.id) } ?? []
    }

    var eligibleSelectedSessions: [SessionSummary] {
        selectedSessions.filter { $0.isSupported && !$0.isProtected }
    }

    var visibleStorageItems: [StorageItem] {
        storageReport.items.filter { item in
            visibleTools.contains(item.tool)
                && storageToolFilter.includes(item)
                && storageFilter.includes(item)
                && (storageSearchText.isEmpty
                    || item.title.localizedCaseInsensitiveContains(storageSearchText)
                    || item.explanation.localizedCaseInsensitiveContains(storageSearchText)
                    || item.tool.displayName.localizedCaseInsensitiveContains(storageSearchText))
        }
    }

    var storageItemsForSelectedTool: [StorageItem] {
        storageItems(for: storageToolFilter)
    }

    var selectedStorageTotalByteCount: Int64 {
        storageItemsForSelectedTool.reduce(0) { $0 + $1.byteCount }
    }

    var selectedStorageDeletableByteCount: Int64 {
        storageItemsForSelectedTool
            .filter { $0.safety != .protected }
            .reduce(0) { $0 + $1.byteCount }
    }

    func storageItems(for filter: StorageToolFilter) -> [StorageItem] {
        storageReport.items.filter { visibleTools.contains($0.tool) && filter.includes($0) }
    }

    func storageTotalByteCount(for filter: StorageToolFilter) -> Int64 {
        storageItems(for: filter).reduce(0) { $0 + $1.byteCount }
    }

    func storageDeletableByteCount(for filter: StorageToolFilter) -> Int64 {
        storageItems(for: filter)
            .filter { $0.safety != .protected }
            .reduce(0) { $0 + $1.byteCount }
    }

    var selectedStorageItems: [StorageItem] {
        storageReport.items.filter { selectedStorageItemIDs.contains($0.id) }
    }

    var eligibleSelectedStorageItems: [StorageItem] {
        selectedStorageItems.filter { $0.safety != .protected }
    }

    func reload() {
        let generation = UUID()
        scanGeneration = generation
        isScanning = true
        let repository = repository
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                repository.scanAll()
            }.value
            guard scanGeneration == generation else { return }
            shelves = result
            isScanning = false
            if selectedDestination == nil {
                selectedDestination = visibleTools.first.map(SidebarDestination.tool) ?? .storage(.all)
            }
            reconcileSelection(visibleSessions: selectedShelf?.sessions ?? [])
        }
    }

    func reloadStorage() {
        storageScanTask?.cancel()
        let generation = UUID()
        storageScanGeneration = generation
        isScanningStorage = true
        let storageRepository = storageRepository
        storageScanTask = Task {
            let worker = Task.detached(priority: .utility) {
                storageRepository.scanAll {
                    Task.isCancelled
                }
            }
            let report = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard storageScanGeneration == generation else { return }
            storageReport = report
            isScanningStorage = false
            reconcileStorageSelection(visibleItems: visibleStorageItems)
            storageScanTask = nil
        }
    }

    func select(_ session: SessionSummary?) {
        guard let session else {
            clearSelection()
            return
        }
        updateSelection([session.id], visibleSessions: selectedShelf?.sessions ?? [session])
    }

    func updateSelection(_ ids: Set<String>, visibleSessions: [SessionSummary]) {
        let focusedID = selectionState.update(to: ids, orderedIDs: visibleSessions.map(\.id))
        selectedSessionIDs = selectionState.selectedIDs
        setFocusedSession(visibleSessions.first { $0.id == focusedID })
    }

    func reconcileSelection(visibleSessions: [SessionSummary]) {
        let focusedID = selectionState.reconcile(orderedIDs: visibleSessions.map(\.id))
        selectedSessionIDs = selectionState.selectedIDs
        setFocusedSession(visibleSessions.first { $0.id == focusedID })
    }

    func clearSelection() {
        selectionState.clear()
        selectedSessionIDs.removeAll()
        setFocusedSession(nil)
    }

    func updateStorageSelection(_ ids: Set<String>, visibleItems: [StorageItem]) {
        let focusedID = storageSelectionState.update(to: ids, orderedIDs: visibleItems.map(\.id))
        selectedStorageItemIDs = storageSelectionState.selectedIDs
        selectedStorageItem = visibleItems.first { $0.id == focusedID }
    }

    func reconcileStorageSelection(visibleItems: [StorageItem]) {
        let focusedID = storageSelectionState.reconcile(orderedIDs: visibleItems.map(\.id))
        selectedStorageItemIDs = storageSelectionState.selectedIDs
        selectedStorageItem = visibleItems.first { $0.id == focusedID }
    }

    private func setFocusedSession(_ session: SessionSummary?) {
        guard selectedSession?.id != session?.id else { return }
        // 選択解除時にも世代を進め、削除前の読み込み結果が戻らないようにする。
        let generation = UUID()
        detailGeneration = generation
        selectedSession = session
        selectedDetailTab = session?.kind == .plan ? "プラン" : "会話"
        detail = nil
        errorMessage = nil
        isLoadingDetail = false
        guard let session, session.isSupported else { return }
        isLoadingDetail = true
        let repository = repository
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try repository.loadDetail(for: session)
                }.value
                guard detailGeneration == generation, selectedSession?.id == session.id else { return }
                detail = loaded
            } catch {
                guard detailGeneration == generation else { return }
                errorMessage = error.localizedDescription
            }
            if detailGeneration == generation { isLoadingDetail = false }
        }
    }

    func trashCandidates(for session: SessionSummary) -> [SessionSummary] {
        let seeds = selectedSessionIDs.contains(session.id) ? selectedSessions : [session]
        return SessionHierarchy.deletionOrder(
            startingAt: seeds,
            in: selectedShelf?.sessions ?? seeds
        )
    }

    func requestTrash(_ sessions: [SessionSummary]) {
        guard !isDeletingSessions, !isPreparingTrash else { return }
        var seen: Set<String> = []
        let unique = sessions.filter { seen.insert($0.id).inserted }
        if SessionHierarchy.hasBlockedMemberInFamily(unique) {
            errorMessage = "親子セッションの一部が保護中または未対応のため、まとめて削除できません"
            return
        }
        guard unique.contains(where: { $0.isSupported && !$0.isProtected }) else {
            errorMessage = unique.contains { $0.tool == .openCode } ? "選択したOpenCodeは完全に削除できません" : "選択したログは保護中または未対応のため、ゴミ箱へ移せません"
            return
        }
        let generation = UUID()
        trashPlanGeneration = generation
        isPreparingTrash = true
        let repository = repository
        Task {
            let plan = await Task.detached(priority: .userInitiated) {
                repository.deletionPlan(for: unique)
            }.value
            guard trashPlanGeneration == generation else { return }
            isPreparingTrash = false
            trashRequest = TrashRequest(sessions: unique, plan: plan)
        }
    }

    func requestTrashForSelection() {
        requestTrash(selectedSessions)
    }

    func confirmTrash(_ request: TrashRequest) {
        guard !isDeletingSessions else { return }
        trashRequest = nil
        isDeletingSessions = true
        let deleteSession = deleteSession
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var succeeded: Set<String> = []
                var failures: [(title: String, reason: String)] = []
                for session in request.eligible {
                    do {
                        try deleteSession(session, session.deletionMode)
                        succeeded.insert(session.id)
                    } catch {
                        failures.append((session.title, Self.userFacingDeletionReason(for: error)))
                    }
                }
                return SessionDeletionResult(succeeded: succeeded, failures: failures)
            }.value

            if !result.succeeded.isEmpty {
                removeFromShelves(ids: result.succeeded)
                let remainingSelection = selectedSessionIDs.subtracting(result.succeeded)
                updateSelection(remainingSelection, visibleSessions: selectedShelf?.sessions ?? [])
            }

            if !result.failures.isEmpty {
                let examples = result.failures.prefix(3)
                    .map { "\($0.title)（\($0.reason)）" }
                    .joined(separator: "、")
                let action = request.sessions.contains { $0.tool == .openCode }
                    ? "完全に削除できませんでした"
                    : "ゴミ箱へ移せませんでした"
                errorMessage = "\(result.failures.count)件を\(action): \(examples)"
            }
            isDeletingSessions = false
            reload()
        }
    }

    func storageTrashCandidates(for item: StorageItem) -> [StorageItem] {
        selectedStorageItemIDs.contains(item.id) ? selectedStorageItems : [item]
    }

    func requestStorageTrash(_ items: [StorageItem]) {
        guard !isDeletingStorage else { return }
        let unique = Dictionary(grouping: items, by: \.id).compactMap(\.value.first)
        let request = StorageTrashRequest(items: unique)
        guard !request.eligible.isEmpty else {
            errorMessage = "選択した項目は保護されているため、ゴミ箱へ移せません"
            return
        }
        storageTrashRequest = request
    }

    func requestStorageTrashForSelection() {
        requestStorageTrash(selectedStorageItems)
    }

    func confirmStorageTrash(_ request: StorageTrashRequest) {
        guard !isDeletingStorage else { return }
        storageTrashRequest = nil
        isDeletingStorage = true
        storageScanTask?.cancel()
        storageScanGeneration = UUID()
        let storageRepository = storageRepository
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var succeeded: Set<String> = []
                var failures: [(StorageItem, String)] = []
                for item in request.eligible {
                    do {
                        try storageRepository.moveToTrash(item)
                        succeeded.insert(item.id)
                    } catch {
                        failures.append((item, error.localizedDescription))
                    }
                }
                return (succeeded, failures)
            }.value
            if !result.0.isEmpty {
                storageReport = StorageScanReport(
                    items: storageReport.items.filter { !result.0.contains($0.id) },
                    issues: storageReport.issues,
                    wasCancelled: storageReport.wasCancelled
                )
                updateStorageSelection(
                    selectedStorageItemIDs.subtracting(result.0),
                    visibleItems: visibleStorageItems
                )
            }
            if !result.1.isEmpty {
                let examples = result.1.prefix(3).map { $0.0.title }.joined(separator: "、")
                errorMessage = "\(result.1.count)件をゴミ箱へ移せませんでした: \(examples)"
            }
            isDeletingStorage = false
            reloadStorage()
        }
    }

    private func removeFromShelves(ids: Set<String>) {
        shelves = shelves.map { shelf in
            let remaining = shelf.sessions.filter { !ids.contains($0.id) }
            guard remaining.count != shelf.sessions.count else { return shelf }
            let status: DetectionStatus = remaining.isEmpty ? .notDetected : .detected(count: remaining.count)
            return ToolShelf(
                tool: shelf.tool,
                status: status,
                candidatePaths: shelf.candidatePaths,
                sessions: remaining
            )
        }
    }

    nonisolated private static func userFacingDeletionReason(for error: Error) -> String {
        guard let error = error as? SessionShelfError else {
            return "予期しないエラー"
        }
        return error.localizedDescription
    }
}

private extension SidebarDestination {
    var tool: AITool? {
        if case .tool(let tool) = self { return tool }
        return nil
    }

    var storageFilter: StorageToolFilter? {
        if case .storage(let filter) = self { return filter }
        return nil
    }
}
