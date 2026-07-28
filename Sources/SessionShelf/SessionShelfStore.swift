import Foundation
import SessionShelfCore

struct TrashRequest: Identifiable {
    let id = UUID()
    let sessions: [SessionSummary]

    var eligible: [SessionSummary] {
        sessions.filter { $0.isSupported && !$0.isProtected }
    }

    var excludedCount: Int { sessions.count - eligible.count }
}

@MainActor
final class SessionShelfStore: ObservableObject {
    @Published var shelves: [ToolShelf] = []
    @Published var selectedTool: AITool? = .codex {
        didSet {
            guard oldValue != selectedTool else { return }
            clearSelection()
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

    private let repository: SessionRepository
    private var scanGeneration = UUID()
    private var detailGeneration = UUID()
    private var selectionState = SessionSelectionState()

    init(repository: SessionRepository = SessionRepository()) {
        self.repository = repository
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
            if selectedTool == nil { selectedTool = .codex }
            reconcileSelection(visibleSessions: selectedShelf?.sessions ?? [])
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

    private func setFocusedSession(_ session: SessionSummary?) {
        guard selectedSession?.id != session?.id else { return }
        // 選択解除時にも世代を進め、削除前の読み込み結果が戻らないようにする。
        let generation = UUID()
        detailGeneration = generation
        selectedSession = session
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
        selectedSessionIDs.contains(session.id) ? selectedSessions : [session]
    }

    func requestTrash(_ sessions: [SessionSummary]) {
        let unique = Dictionary(grouping: sessions, by: \.id).compactMap(\.value.first)
        let request = TrashRequest(sessions: unique)
        guard !request.eligible.isEmpty else {
            errorMessage = "選択したログは保護中または未対応のため、ゴミ箱へ移せません"
            return
        }
        trashRequest = request
    }

    func requestTrashForSelection() {
        requestTrash(selectedSessions)
    }

    func confirmTrash(_ request: TrashRequest) {
        trashRequest = nil
        var succeeded: Set<String> = []
        var failures: [(SessionSummary, Error)] = []

        for session in request.eligible {
            do {
                try repository.moveToTrash(session)
                succeeded.insert(session.id)
            } catch {
                failures.append((session, error))
            }
        }

        if !succeeded.isEmpty {
            removeFromShelves(ids: succeeded)
            let remainingSelection = selectedSessionIDs.subtracting(succeeded)
            updateSelection(remainingSelection, visibleSessions: selectedShelf?.sessions ?? [])
        }

        if !failures.isEmpty {
            let examples = failures.prefix(3).map { $0.0.title }.joined(separator: "、")
            errorMessage = "\(failures.count)件をゴミ箱へ移せませんでした: \(examples)"
        }
        reload()
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
}
