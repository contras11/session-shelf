import Foundation
import SessionShelfCore
import SwiftUI

@MainActor
final class SidebarPreferences: ObservableObject {
    static let orderKey = "sidebar.toolOrder.v1"
    static let hiddenKey = "sidebar.hiddenTools.v1"

    @Published private(set) var orderedTools: [AITool]
    @Published private(set) var hiddenTools: Set<AITool>

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        orderedTools = Self.sanitizedOrder(defaults.stringArray(forKey: Self.orderKey))
        hiddenTools = Self.sanitizedHiddenTools(defaults.stringArray(forKey: Self.hiddenKey))
    }

    var visibleTools: [AITool] {
        orderedTools.filter { !hiddenTools.contains($0) }
    }

    func isVisible(_ tool: AITool) -> Bool {
        !hiddenTools.contains(tool)
    }

    func setVisible(_ isVisible: Bool, for tool: AITool) {
        if isVisible {
            hiddenTools.remove(tool)
        } else {
            hiddenTools.insert(tool)
        }
        persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        orderedTools.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func reset() {
        orderedTools = AITool.allCases
        hiddenTools = []
        defaults.removeObject(forKey: Self.orderKey)
        defaults.removeObject(forKey: Self.hiddenKey)
    }

    static func sanitizedOrder(_ rawValues: [String]?) -> [AITool] {
        var seen: Set<AITool> = []
        var result: [AITool] = []

        for rawValue in rawValues ?? [] {
            guard let tool = AITool(rawValue: rawValue), seen.insert(tool).inserted else { continue }
            result.append(tool)
        }
        result.append(contentsOf: AITool.allCases.filter { seen.insert($0).inserted })
        return result
    }

    static func sanitizedHiddenTools(_ rawValues: [String]?) -> Set<AITool> {
        Set((rawValues ?? []).compactMap(AITool.init(rawValue:)))
    }

    private func persist() {
        defaults.set(orderedTools.map(\.rawValue), forKey: Self.orderKey)
        defaults.set(hiddenTools.map(\.rawValue).sorted(), forKey: Self.hiddenKey)
    }
}
