import Foundation

/// 一覧の複数選択と、詳細へ表示する最後の選択を一貫して管理する。
package struct SessionSelectionState: Equatable, Sendable {
    package private(set) var selectedIDs: Set<String> = []
    package private(set) var focusedID: String?
    private var selectionOrder: [String] = []

    package init() {}

    @discardableResult
    package mutating func update(
        to requestedIDs: Set<String>,
        orderedIDs: [String]
    ) -> String? {
        let allowed = Set(orderedIDs)
        let newSelection = requestedIDs.intersection(allowed)
        let previousSelection = selectedIDs
        let previousFocus = focusedID
        let added = newSelection.subtracting(previousSelection)

        selectedIDs = newSelection
        selectionOrder.removeAll { !newSelection.contains($0) }

        let nextFocus: String?
        if newSelection.isEmpty {
            nextFocus = nil
        } else if newSelection.count == 1 {
            nextFocus = newSelection.first
        } else if added.count == 1 {
            nextFocus = added.first
        } else if added.count > 1 {
            nextFocus = rangeEndpoint(
                among: added,
                previousFocus: previousFocus,
                orderedIDs: orderedIDs
            )
        } else if let previousFocus, newSelection.contains(previousFocus) {
            nextFocus = previousFocus
        } else {
            nextFocus = selectionOrder.last ?? orderedIDs.last { newSelection.contains($0) }
        }

        let orderedAdded = orderedIDs.filter { added.contains($0) && $0 != nextFocus }
        selectionOrder.append(contentsOf: orderedAdded)
        if let nextFocus {
            selectionOrder.removeAll { $0 == nextFocus }
            selectionOrder.append(nextFocus)
        }
        focusedID = nextFocus
        return nextFocus
    }

    @discardableResult
    package mutating func reconcile(orderedIDs: [String]) -> String? {
        update(to: selectedIDs, orderedIDs: orderedIDs)
    }

    package mutating func clear() {
        selectedIDs.removeAll()
        selectionOrder.removeAll()
        focusedID = nil
    }

    private func rangeEndpoint(
        among added: Set<String>,
        previousFocus: String?,
        orderedIDs: [String]
    ) -> String? {
        guard let previousFocus,
              let previousIndex = orderedIDs.firstIndex(of: previousFocus)
        else {
            return orderedIDs.last { added.contains($0) }
        }
        return added.max { lhs, rhs in
            guard let lhsIndex = orderedIDs.firstIndex(of: lhs),
                  let rhsIndex = orderedIDs.firstIndex(of: rhs)
            else { return false }
            return abs(lhsIndex - previousIndex) < abs(rhsIndex - previousIndex)
        }
    }
}
