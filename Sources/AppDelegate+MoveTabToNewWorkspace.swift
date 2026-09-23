import Foundation
import CmuxSettings
import Bonsplit

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

/// Depott: compose existing agents (sidebar workspaces) into one tiled Grid
/// workspace. The first agent added lends its workspace as the Grid; later
/// agents' surfaces move in as splits of the largest tile. Removing a tile
/// pops it back into its own workspace with its original name; removing the
/// last tile turns the Grid back into that agent's workspace.
@MainActor
final class DepottGridStore {
    static let shared = DepottGridStore()
    /// Grid workspace id, per tab manager (one Grid per window).
    var gridWorkspaceIdByManager: [ObjectIdentifier: UUID] = [:]
    /// Custom title the agent's workspace had before joining (only when set).
    var originalCustomTitleByPanelId: [UUID: String] = [:]
}

@MainActor
extension AppDelegate {
    static var depottGridTitle: String {
        String(localized: "depott.grid.title", defaultValue: "▦ Grid")
    }

    func depottGridWorkspace(in tabManager: TabManager) -> Workspace? {
        guard let id = DepottGridStore.shared.gridWorkspaceIdByManager[ObjectIdentifier(tabManager)] else {
            return nil
        }
        guard let grid = tabManager.tabs.first(where: { $0.id == id }) else {
            // The Grid workspace was closed by the user; forget it.
            DepottGridStore.shared.gridWorkspaceIdByManager[ObjectIdentifier(tabManager)] = nil
            return nil
        }
        return grid
    }

    func depottIsGridWorkspace(_ workspaceId: UUID, in tabManager: TabManager) -> Bool {
        depottGridWorkspace(in: tabManager)?.id == workspaceId
    }

    /// Largest pane in the Grid and the axis to split it along (its longer side),
    /// so successive adds form a grid (2x2 at four tiles) instead of a strip.
    private func depottSplitTarget(in grid: Workspace) -> (pane: PaneID?, orientation: SplitOrientation) {
        let panes = grid.bonsplitController.layoutSnapshot().panes
        guard let biggest = panes.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            return (nil, .horizontal)
        }
        let pane = grid.bonsplitController.allPaneIds.first(where: { $0.id.uuidString == biggest.paneId })
        let orientation: SplitOrientation = biggest.frame.width >= biggest.frame.height ? .horizontal : .vertical
        return (pane, orientation)
    }

    /// Adds the given workspaces' focused agents to the Grid. Returns how many joined.
    @discardableResult
    func depottAddToGrid(workspaceIds: [UUID], tabManager: TabManager) -> Int {
        let store = DepottGridStore.shared
        var added = 0
        var lastPanelId: UUID?
        for workspaceId in workspaceIds {
            guard !depottIsGridWorkspace(workspaceId, in: tabManager),
                  let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
                  let panelId = workspace.focusedPanelId ?? workspace.panels.keys.first else {
                continue
            }
            let originalCustomTitle = workspace.customTitle

            if let grid = depottGridWorkspace(in: tabManager) {
                let target = depottSplitTarget(in: grid)
                guard moveSurface(
                    panelId: panelId,
                    toWorkspace: grid.id,
                    targetPane: target.pane,
                    splitTarget: (orientation: target.orientation, insertFirst: false),
                    focus: false,
                    focusWindow: false
                ) else { continue }
            } else if workspace.panels.count == 1 {
                // First agent with a single surface: its workspace becomes the Grid.
                store.gridWorkspaceIdByManager[ObjectIdentifier(tabManager)] = workspace.id
                tabManager.setCustomTitle(tabId: workspace.id, title: Self.depottGridTitle)
            } else {
                // First agent shares its workspace: pop its surface into a new Grid.
                guard let result = moveSurfaceToNewWorkspace(
                    panelId: panelId,
                    destinationManager: tabManager,
                    title: Self.depottGridTitle,
                    focus: false,
                    focusWindow: false
                ) else { continue }
                store.gridWorkspaceIdByManager[ObjectIdentifier(tabManager)] = result.destinationWorkspaceId
            }

            if let originalCustomTitle { store.originalCustomTitleByPanelId[panelId] = originalCustomTitle }
            lastPanelId = panelId
            added += 1
        }

        if added > 0, let grid = depottGridWorkspace(in: tabManager) {
            _ = tabManager.equalizeSplits(tabId: grid.id)
            tabManager.focusTab(grid.id, surfaceId: lastPanelId, suppressFlash: true)
        }
        return added
    }

    /// Drag & drop: a sidebar agent row dropped on a tile joins the Grid at that
    /// tile, on the side it was dropped (center = split along the tile's longer
    /// side). Dropping onto a workspace while no Grid exists makes that workspace
    /// the Grid. Drops onto a non-Grid workspace when a Grid already exists, or an
    /// agent onto itself, are rejected.
    func depottCanDropWorkspace(_ workspaceId: UUID, ontoWorkspace targetWorkspaceId: UUID) -> Bool {
        guard workspaceId != targetWorkspaceId,
              let tabManager = tabManagerFor(tabId: targetWorkspaceId),
              tabManager.tabs.contains(where: { $0.id == workspaceId }) else { return false }
        guard let grid = depottGridWorkspace(in: tabManager) else { return true }
        return grid.id == targetWorkspaceId
    }

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
              let target = tabManager.tabs.first(where: { $0.id == targetWorkspaceId }),
              let panelId = source.focusedPanelId ?? source.panels.keys.first else { return false }
        let store = DepottGridStore.shared

        if depottGridWorkspace(in: tabManager) == nil {
            // No Grid yet: the workspace being dropped onto becomes the Grid.
            if let custom = target.customTitle {
                for existing in target.panels.keys { store.originalCustomTitleByPanelId[existing] = custom }
            }
            store.gridWorkspaceIdByManager[ObjectIdentifier(tabManager)] = target.id
            tabManager.setCustomTitle(tabId: target.id, title: Self.depottGridTitle)
        }

        let split: (orientation: SplitOrientation, insertFirst: Bool)
        switch zone {
        case .left: split = (.horizontal, true)
        case .right: split = (.horizontal, false)
        case .top: split = (.vertical, true)
        case .bottom: split = (.vertical, false)
        case .center:
            let frame = target.bonsplitController.layoutSnapshot().panes
                .first(where: { $0.paneId == targetPane.id.uuidString })?.frame
            let wide = (frame?.width ?? 1) >= (frame?.height ?? 0)
            split = (wide ? .horizontal : .vertical, false)
        }

        let originalCustomTitle = source.customTitle
        guard moveSurface(
            panelId: panelId,
            toWorkspace: target.id,
            targetPane: targetPane,
            splitTarget: split,
            focus: false,
            focusWindow: false
        ) else { return false }
        if let originalCustomTitle { store.originalCustomTitleByPanelId[panelId] = originalCustomTitle }
        _ = tabManager.equalizeSplits(tabId: target.id)
        tabManager.focusTab(target.id, surfaceId: panelId, suppressFlash: true)
        return true
    }

    /// Pops one agent out of the Grid, back into its own workspace.
    @discardableResult
    func depottRemoveFromGrid(panelId: UUID, tabManager: TabManager) -> Bool {
        let store = DepottGridStore.shared
        guard let grid = depottGridWorkspace(in: tabManager), grid.panels[panelId] != nil else {
            return false
        }
        let restoreTitle = store.originalCustomTitleByPanelId[panelId]

        if grid.panels.count > 1 {
            guard moveSurfaceToNewWorkspace(
                panelId: panelId,
                destinationManager: tabManager,
                title: restoreTitle,
                focus: false,
                focusWindow: false
            ) != nil else { return false }
            store.originalCustomTitleByPanelId[panelId] = nil
            _ = tabManager.equalizeSplits(tabId: grid.id)
            return true
        }

        // Last tile: the Grid turns back into this agent's own workspace.
        if let restoreTitle {
            tabManager.setCustomTitle(tabId: grid.id, title: restoreTitle)
        } else {
            tabManager.clearCustomTitle(tabId: grid.id)
        }
        store.originalCustomTitleByPanelId[panelId] = nil
        store.gridWorkspaceIdByManager[ObjectIdentifier(tabManager)] = nil
        return true
    }

    /// Pops every agent out of the Grid.
    func depottDissolveGrid(tabManager: TabManager) {
        guard let grid = depottGridWorkspace(in: tabManager) else { return }
        for panelId in Array(grid.panels.keys) {
            _ = depottRemoveFromGrid(panelId: panelId, tabManager: tabManager)
        }
    }
}
