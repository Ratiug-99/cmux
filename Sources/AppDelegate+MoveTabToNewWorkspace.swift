import Foundation
import CmuxSettings
import Bonsplit
import Combine

struct SurfaceNewWorkspaceMoveResult {
    let sourceWindowId: UUID
    let sourceWorkspaceId: UUID
    let destinationWindowId: UUID?
    let destinationWorkspaceId: UUID
    let surfaceId: UUID
    let paneId: UUID?
}

@MainActor
extension AppDelegate {
    func canMoveSurfaceToNewWorkspace(panelId: UUID) -> Bool {
        guard let source = locateSurface(surfaceId: panelId),
              let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }),
              sourceWorkspace.panels[panelId] != nil else {
            return false
        }
        return sourceWorkspace.panels.count > 1
    }

    func canMoveBonsplitTabToNewWorkspace(tabId: UUID) -> Bool {
        guard let located = locateBonsplitSurface(tabId: tabId) else { return false }
        return canMoveSurfaceToNewWorkspace(panelId: located.panelId)
    }

    func canMoveBonsplitTab(tabId: UUID, toWorkspace targetWorkspaceId: UUID) -> Bool {
        guard locateContainerSurface(tabId: tabId) != nil,
              let destination = workspaceFor(tabId: targetWorkspaceId) else { return false }
        return destination.surfaceOwnershipPolicy.rejection(for: machineOwningBonsplitTab(tabId)) == nil
    }

    func workspaceMoveTargets(forSurface panelId: UUID) -> [WorkspaceMoveTarget] {
        guard let source = locateSurface(surfaceId: panelId) else { return [] }
        return workspaceMoveTargets(
            excludingWorkspaceId: source.workspaceId,
            referenceWindowId: source.windowId
        )
    }

    func workspaceMoveTargets(forBonsplitTab tabId: UUID) -> [WorkspaceMoveTarget] {
        guard let located = locateBonsplitSurface(tabId: tabId) else { return [] }
        return workspaceMoveTargets(
            excludingWorkspaceId: located.workspaceId,
            referenceWindowId: located.windowId
        )
    }

    @discardableResult
    func moveBonsplitTabToNewWorkspace(
        tabId: UUID,
        destinationManager: TabManager? = nil,
        title: String? = nil,
        focus: Bool = true,
        focusWindow: Bool = true,
        placementOverride: WorkspacePlacement? = nil,
        insertionIndexOverride: Int? = nil
    ) -> SurfaceNewWorkspaceMoveResult? {
        guard let located = locateBonsplitSurface(tabId: tabId) else { return nil }
        return moveSurfaceToNewWorkspace(
            panelId: located.panelId,
            destinationManager: destinationManager,
            title: title,
            focus: focus,
            focusWindow: focusWindow,
            placementOverride: placementOverride,
            insertionIndexOverride: insertionIndexOverride
        )
    }

    @discardableResult
    func moveSurfaceToNewWorkspace(
        panelId: UUID,
        destinationManager: TabManager? = nil,
        title: String? = nil,
        focus: Bool = true,
        focusWindow: Bool = true,
        placementOverride: WorkspacePlacement? = nil,
        insertionIndexOverride: Int? = nil
    ) -> SurfaceNewWorkspaceMoveResult? {
        guard let source = locateSurface(surfaceId: panelId),
              let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }),
              let sourcePanel = sourceWorkspace.panels[panelId],
              sourceWorkspace.panels.count > 1 else {
            return nil
        }

        let targetManager = destinationManager ?? source.tabManager
        let hasExplicitTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if !hasExplicitTitle {
            source.tabManager.flushPendingPanelTitleUpdatesForWorkspaceSnapshot()
        }
        let destinationTitle = titleForDetachedWorkspace(
            explicitTitle: title,
            workspace: sourceWorkspace,
            panelId: panelId,
            panel: sourcePanel
        )
        let sourcePane = sourceWorkspace.paneId(forPanelId: panelId)
        let sourceIndex = sourceWorkspace.indexInPane(forPanelId: panelId)
        let activationIntent = focusIntentForNewWorkspaceMove(panel: sourcePanel)
        guard let detached = sourceWorkspace.detachSurface(panelId: panelId) else { return nil }

        guard let destinationWorkspace = targetManager.addWorkspace(
            fromDetachedSurface: detached,
            title: destinationTitle,
            titleSource: hasExplicitTitle ? .user : .auto,
            select: false,
            placementOverride: placementOverride,
            insertionIndexOverride: insertionIndexOverride,
            focusIntent: activationIntent
        ) else {
            rollbackDetachedSurface(
                detached,
                to: sourceWorkspace,
                sourcePane: sourcePane,
                sourceIndex: sourceIndex,
                focus: focus
            )
            return nil
        }

        cleanupEmptySourceWorkspaceAfterSurfaceMove(
            sourceWorkspace: sourceWorkspace,
            sourceManager: source.tabManager,
            sourceWindowId: source.windowId
        )

        if focus {
            let destinationWindowId = focusWindow ? windowId(for: targetManager) : nil
            if let destinationWindowId {
                _ = focusMainWindow(windowId: destinationWindowId)
            }
            targetManager.focusTab(
                destinationWorkspace.id,
                surfaceId: panelId,
                suppressFlash: true,
                focusIntent: activationIntent
            )
            if let destinationWindowId {
                reassertCrossWindowSurfaceMoveFocusIfNeeded(
                    destinationWindowId: destinationWindowId,
                    sourceWindowId: source.windowId,
                    destinationWorkspaceId: destinationWorkspace.id,
                    destinationPanelId: panelId,
                    destinationManager: targetManager
                )
            }
        }

        return SurfaceNewWorkspaceMoveResult(
            sourceWindowId: source.windowId,
            sourceWorkspaceId: source.workspaceId,
            destinationWindowId: windowId(for: targetManager),
            destinationWorkspaceId: destinationWorkspace.id,
            surfaceId: panelId,
            paneId: destinationWorkspace.paneId(forPanelId: panelId)?.id
        )
    }

    private func focusIntentForNewWorkspaceMove(panel: any Panel) -> PanelFocusIntent {
        if panel is BrowserPanel {
            // Moving a browser tab into a standalone workspace should expose browser chrome,
            // even if web content was the last in-panel responder before the drag.
            return .browser(.addressBar)
        }
        return panel.preferredFocusIntentForActivation()
    }

    private func titleForDetachedWorkspace(
        explicitTitle: String?,
        workspace: Workspace,
        panelId: UUID,
        panel: any Panel
    ) -> String {
        let trimmedTitle = explicitTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle, !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        let fallbackTitle = workspace.panelTitle(panelId: panelId) ?? panel.displayTitle
        let trimmedFallbackTitle = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallbackTitle.isEmpty {
            return trimmedFallbackTitle
        }

        return String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
    }
}

// MARK: - Depott Grid

/// Depott: any workspace can host several agents as a tiled Grid.
///
/// A workspace becomes a Grid when an agent joins it (context menu or drag from
/// the sidebar). Each Grid is observed: its sidebar name is kept as
/// "▦ name · name", and once it is down to one surface - however that
/// happened - it reverts to that agent's own name and stops being a Grid.
/// Agents leaving a Grid get their original workspace name back.
@MainActor
final class DepottGridStore {
    static let shared = DepottGridStore()
    var gridWorkspaceIds: Set<UUID> = []
    /// Most recently used Grid (target for context-menu "Add to Grid").
    var lastGridWorkspaceId: UUID?
    /// Display name of each agent as it was before joining.
    var memberNameByPanelId: [UUID: String] = [:]
    /// Grid each member belongs to.
    var gridIdByPanelId: [UUID: UUID] = [:]
    /// Custom title the agent's workspace had before joining (only when set).
    var originalCustomTitleByPanelId: [UUID: String] = [:]
    var observers: [UUID: AnyCancellable] = [:]
    var pendingReconcile: Set<UUID> = []
}

@MainActor
extension AppDelegate {
    static var depottGridSymbol: String { "\u{25A6}" }

    func depottIsGridWorkspace(_ workspaceId: UUID, in tabManager: TabManager) -> Bool {
        DepottGridStore.shared.gridWorkspaceIds.contains(workspaceId)
            && tabManager.tabs.contains(where: { $0.id == workspaceId })
    }

    /// Grid the context menu adds to: the selected workspace if it is a Grid,
    /// otherwise the most recently used Grid in this window.
    func depottGridWorkspace(in tabManager: TabManager) -> Workspace? {
        let store = DepottGridStore.shared
        if let selected = tabManager.selectedTab, store.gridWorkspaceIds.contains(selected.id) {
            return selected
        }
        if let last = store.lastGridWorkspaceId, store.gridWorkspaceIds.contains(last) {
            return tabManager.tabs.first(where: { $0.id == last })
        }
        return nil
    }

    private func depottDisplayName(of workspace: Workspace) -> String {
        let name = (workspace.customTitle ?? workspace.title).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab") : name
    }

    /// Records a surface as a member of `grid`, remembering how to restore it.
    private func depottRecordMember(panelId: UUID, name: String, originalCustomTitle: String?, gridId: UUID) {
        let store = DepottGridStore.shared
        store.memberNameByPanelId[panelId] = name
        store.gridIdByPanelId[panelId] = gridId
        if let originalCustomTitle { store.originalCustomTitleByPanelId[panelId] = originalCustomTitle }
    }

    /// Turns `workspace` into a Grid (its current surfaces become members).
    private func depottMakeGrid(_ workspace: Workspace, tabManager: TabManager) {
        let store = DepottGridStore.shared
        store.lastGridWorkspaceId = workspace.id
        guard !store.gridWorkspaceIds.contains(workspace.id) else { return }
        let name = depottDisplayName(of: workspace)
        for panelId in workspace.panels.keys {
            depottRecordMember(panelId: panelId, name: name, originalCustomTitle: workspace.customTitle, gridId: workspace.id)
        }
        store.gridWorkspaceIds.insert(workspace.id)
        store.observers[workspace.id] = workspace.objectWillChange.sink { [weak self, weak tabManager] _ in
            guard let self, let tabManager else { return }
            self.depottScheduleReconcile(gridId: workspace.id, tabManager: tabManager)
        }
    }

    private func depottForgetGrid(_ gridId: UUID) {
        let store = DepottGridStore.shared
        store.gridWorkspaceIds.remove(gridId)
        store.observers[gridId] = nil
        if store.lastGridWorkspaceId == gridId { store.lastGridWorkspaceId = nil }
        for (panelId, owner) in store.gridIdByPanelId where owner == gridId {
            store.gridIdByPanelId[panelId] = nil
            store.memberNameByPanelId[panelId] = nil
            store.originalCustomTitleByPanelId[panelId] = nil
        }
    }

    private func depottScheduleReconcile(gridId: UUID, tabManager: TabManager) {
        guard DepottGridStore.shared.pendingReconcile.insert(gridId).inserted else { return }
        DispatchQueue.main.async { [weak self, weak tabManager] in
            DepottGridStore.shared.pendingReconcile.remove(gridId)
            guard let self, let tabManager else { return }
            self.depottReconcile(gridId: gridId, tabManager: tabManager)
        }
    }

    /// Keeps a Grid's name in sync with its members, dissolves it at one
    /// surface, and restores names of agents that left it.
    func depottReconcile(gridId: UUID, tabManager: TabManager) {
        let store = DepottGridStore.shared
        guard let grid = tabManager.tabs.first(where: { $0.id == gridId }) else {
            depottForgetGrid(gridId)
            return
        }

        // Members that left (native drag-out, closed, moved): restore their name.
        for (panelId, owner) in store.gridIdByPanelId where owner == gridId && grid.panels[panelId] == nil {
            if let custom = store.originalCustomTitleByPanelId[panelId],
               let located = locateSurface(surfaceId: panelId),
               let landed = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
               !store.gridWorkspaceIds.contains(landed.id),
               landed.panels.count == 1 {
                located.tabManager.setCustomTitle(tabId: landed.id, title: custom)
            }
            store.gridIdByPanelId[panelId] = nil
            store.memberNameByPanelId[panelId] = nil
            store.originalCustomTitleByPanelId[panelId] = nil
        }

        if grid.panels.count <= 1 {
            // Down to one agent: the Grid becomes that agent's workspace again.
            if let remaining = grid.panels.keys.first, let custom = store.originalCustomTitleByPanelId[remaining] {
                tabManager.setCustomTitle(tabId: grid.id, title: custom)
            } else {
                tabManager.clearCustomTitle(tabId: grid.id)
            }
            depottForgetGrid(gridId)
            return
        }

        let names = grid.sidebarOrderedPanelIds().compactMap { panelId -> String? in
            guard let panel = grid.panels[panelId] else { return nil }
            let raw = store.memberNameByPanelId[panelId] ?? grid.panelTitle(panelId: panelId) ?? panel.displayTitle
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed.count > 18 ? String(trimmed.prefix(17)) + "\u{2026}" : trimmed
        }
        let title = "\(Self.depottGridSymbol) " + names.joined(separator: " \u{00B7} ")
        if grid.customTitle != title {
            tabManager.setCustomTitle(tabId: grid.id, title: title)
        }
    }

    /// Largest pane and the axis to split it along, so adds form a grid.
    private func depottSplitTarget(in grid: Workspace) -> (pane: PaneID?, orientation: SplitOrientation) {
        let panes = grid.bonsplitController.layoutSnapshot().panes
        guard let biggest = panes.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            return (nil, .horizontal)
        }
        let pane = grid.bonsplitController.allPaneIds.first(where: { $0.id.uuidString == biggest.paneId })
        return (pane, biggest.frame.width >= biggest.frame.height ? .horizontal : .vertical)
    }

    /// Moves `source`'s focused agent into `grid` and records it.
    private func depottJoin(
        _ source: Workspace,
        grid: Workspace,
        targetPane: PaneID?,
        split: (orientation: SplitOrientation, insertFirst: Bool)
    ) -> UUID? {
        guard let panelId = source.focusedPanelId ?? source.panels.keys.first else { return nil }
        let name = depottDisplayName(of: source)
        let originalCustomTitle = source.customTitle
        guard moveSurface(
            panelId: panelId,
            toWorkspace: grid.id,
            targetPane: targetPane,
            splitTarget: split,
            focus: false,
            focusWindow: false
        ) else { return nil }
        depottRecordMember(panelId: panelId, name: name, originalCustomTitle: originalCustomTitle, gridId: grid.id)
        return panelId
    }

    private func depottFinishJoin(grid: Workspace, focusPanelId: UUID?, tabManager: TabManager) {
        _ = tabManager.equalizeSplits(tabId: grid.id)
        depottReconcile(gridId: grid.id, tabManager: tabManager)
        tabManager.focusTab(grid.id, surfaceId: focusPanelId, suppressFlash: true)
    }

    /// Context menu: adds workspaces' agents to the current Grid (or turns the
    /// first one into a Grid when none exists yet). Returns how many joined.
    @discardableResult
    func depottAddToGrid(workspaceIds: [UUID], tabManager: TabManager) -> Int {
        var added = 0
        var lastPanelId: UUID?
        var grid = depottGridWorkspace(in: tabManager)
        for workspaceId in workspaceIds {
            guard let source = tabManager.tabs.first(where: { $0.id == workspaceId }),
                  source.id != grid?.id,
                  !depottIsGridWorkspace(source.id, in: tabManager) else { continue }
            guard let existingGrid = grid else {
                // First agent: its workspace becomes the Grid.
                depottMakeGrid(source, tabManager: tabManager)
                grid = source
                lastPanelId = source.focusedPanelId
                added += 1
                continue
            }
            let target = depottSplitTarget(in: existingGrid)
            if let panelId = depottJoin(source, grid: existingGrid, targetPane: target.pane,
                                        split: (target.orientation, false)) {
                lastPanelId = panelId
                added += 1
            }
        }
        if added > 0, let grid {
            depottFinishJoin(grid: grid, focusPanelId: lastPanelId, tabManager: tabManager)
        }
        return added
    }

    /// Drag & drop: any agent row may be dropped on any other workspace's tile.
    func depottCanDropWorkspace(_ workspaceId: UUID, ontoWorkspace targetWorkspaceId: UUID) -> Bool {
        guard workspaceId != targetWorkspaceId,
              let tabManager = tabManagerFor(tabId: targetWorkspaceId),
              let source = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return false }
        return !source.panels.isEmpty
    }

    /// Drag & drop: joins the dropped agent at `targetPane`, on the drop side
    /// (center = split along the tile's longer side). The target becomes a Grid.
    @discardableResult
    func depottDropWorkspaceIntoGrid(
        workspaceId: UUID,
        targetWorkspaceId: UUID,
        targetPane: PaneID,
        zone: DropZone
    ) -> Bool {
        guard depottCanDropWorkspace(workspaceId, ontoWorkspace: targetWorkspaceId),
              let tabManager = tabManagerFor(tabId: targetWorkspaceId),
              let source = tabManager.tabs.first(where: { $0.id == workspaceId }),
              let target = tabManager.tabs.first(where: { $0.id == targetWorkspaceId }) else { return false }

        let split: (orientation: SplitOrientation, insertFirst: Bool)
        switch zone {
        case .left: split = (.horizontal, true)
        case .right: split = (.horizontal, false)
        case .top: split = (.vertical, true)
        case .bottom: split = (.vertical, false)
        case .center:
            let frame = target.bonsplitController.layoutSnapshot().panes
                .first(where: { $0.paneId == targetPane.id.uuidString })?.frame
            split = ((frame?.width ?? 1) >= (frame?.height ?? 0) ? .horizontal : .vertical, false)
        }

        depottMakeGrid(target, tabManager: tabManager)
        guard let panelId = depottJoin(source, grid: target, targetPane: targetPane, split: split) else {
            depottReconcile(gridId: target.id, tabManager: tabManager)
            return false
        }
        depottFinishJoin(grid: target, focusPanelId: panelId, tabManager: tabManager)
        return true
    }

    /// Pops one agent out of its Grid into its own workspace (original name).
    @discardableResult
    func depottRemoveFromGrid(panelId: UUID, tabManager: TabManager) -> Bool {
        let store = DepottGridStore.shared
        guard let gridId = store.gridIdByPanelId[panelId],
              let grid = tabManager.tabs.first(where: { $0.id == gridId }),
              grid.panels[panelId] != nil else { return false }
        if grid.panels.count > 1 {
            guard moveSurfaceToNewWorkspace(
                panelId: panelId,
                destinationManager: tabManager,
                title: store.originalCustomTitleByPanelId[panelId],
                focus: false,
                focusWindow: false
            ) != nil else { return false }
        }
        depottReconcile(gridId: gridId, tabManager: tabManager)
        return true
    }

    /// Pops every agent out of a Grid.
    func depottDissolveGrid(gridId: UUID, tabManager: TabManager) {
        guard let grid = tabManager.tabs.first(where: { $0.id == gridId }) else { return }
        for panelId in grid.sidebarOrderedPanelIds().dropFirst() {
            _ = depottRemoveFromGrid(panelId: panelId, tabManager: tabManager)
        }
        depottReconcile(gridId: gridId, tabManager: tabManager)
    }
}
