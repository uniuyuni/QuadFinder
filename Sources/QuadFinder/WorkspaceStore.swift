import AppKit
import Foundation
import SwiftUI

@MainActor
final class WorkspaceStore: ObservableObject {
    static let windowScopePolicy = WindowScopePolicy.singleWindow
    @Published private(set) var state: WorkspaceState
    @Published var error: UserFacingError?
    @Published var pendingDrop: PendingDrop?
    @Published var pendingTransfer: PendingTransfer?
    @Published var transferPlanner: TransferPlanController?
    @Published var pendingTrash: PendingTrashRequest?
    @Published private(set) var paneNotifications: [UUID: String] = [:]

    private let persistence: any WorkspacePersisting
    private let fileSystem: FileSystemService
    private let directoryMonitor = DirectoryMonitoringCenter()
    let operationQueue: FileOperationQueue
    let paneSets: PaneSetStore
    let comparisonController: ComparisonController
    let operationHistory: OperationHistoryStore
    private var linkTasks: [Task<Void, Never>] = []
    private var linkGeneration = UUID()
    private var linkEventTokens: [String: UUID] = [:]
    private(set) var recentlyClosedPane: (pane: PaneState, slot: PaneSlot)?

    struct PendingDrop: Identifiable {
        let id = UUID()
        let sourcePaneID: UUID?
        let targetPaneID: UUID
        let sourceURLs: [URL]
        let targetDirectoryURL: URL
        let sourceAccessBookmark: Data?
        let targetAccessBookmark: Data?
        let clipboardCutReceipt: ClipboardCutReceipt?
    }

    struct DestinationCandidate: Identifiable, Equatable {
        let paneID: UUID
        let paneNumber: Int
        let directoryURL: URL
        let accessBookmark: Data?
        var id: UUID { paneID }
        var folderName: String { directoryURL.lastPathComponent.isEmpty ? "/" : directoryURL.lastPathComponent }
    }

    struct PendingTransfer: Identifiable {
        let id = UUID()
        let kind: FileOperationKind
        let sourcePaneID: UUID
        let sourceURLs: [URL]
        let sourceAccessBookmark: Data?
        let destinations: [DestinationCandidate]
    }

    init(
        persistence: any WorkspacePersisting = FileWorkspacePersistence(),
        fileSystem: FileSystemService = FileSystemService(),
        operationQueue: FileOperationQueue? = nil,
        paneSets: PaneSetStore? = nil,
        comparisonController: ComparisonController? = nil
    ) {
        self.persistence = persistence
        self.fileSystem = fileSystem
        let history = OperationHistoryStore()
        self.operationHistory = history
        self.operationQueue = operationQueue ?? FileOperationQueue(fileSystem: fileSystem, history: history)
        self.paneSets = paneSets ?? PaneSetStore()
        self.comparisonController = comparisonController ?? ComparisonController()
        do {
            var restored = try persistence.load() ?? .initial()
            restored.normalize()
            self.state = restored
        } catch {
            self.state = .initial()
            self.error = UserFacingError(title: L10n.tr("状態を復元できませんでした"), message: error.localizedDescription)
        }
        directoryMonitor.update(urls: Set(state.panes.map(\.currentURL)))
        DragModifierTracker.shared.start()
    }

    func undoLastFileOperation() {
        guard let entry = operationHistory.nextUndo else { return }
        guard confirmLargeHistoryOperationIfNeeded(entry, verb: L10n.tr("取り消し")) else { return }
        enqueueHistoryReplay(entry, direction: .undo)
    }

    func redoLastFileOperation() {
        guard let entry = operationHistory.nextRedo else { return }
        guard confirmLargeHistoryOperationIfNeeded(entry, verb: L10n.tr("やり直し")) else { return }
        enqueueHistoryReplay(entry, direction: .redo)
    }

    private func enqueueHistoryReplay(_ entry: OperationHistoryEntry, direction: HistoryReplayPlan.Direction) {
        guard let pane = activePane else { return }
        operationQueue.enqueue(PendingFileOperation(kind: .move, sourcePaneID: nil, targetPaneID: pane.id,
            sourceURLs: [], targetDirectoryURL: pane.currentURL, targetAccessBookmark: pane.accessBookmark,
            historyReplay: .init(entryID: entry.id, direction: direction)))
    }

    private func confirmLargeHistoryOperationIfNeeded(_ entry: OperationHistoryEntry, verb: String) -> Bool {
        guard LargeHistoryOperationPolicy.requiresConfirmation(entry) else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.format("大きな操作を%@ますか？", verb)
        alert.informativeText = L10n.format("%1$@（%2$lld項目、%3$@）", entry.summary, Int64(entry.itemCount), ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file))
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: L10n.tr("キャンセル"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func reloadAllPanes() {
        for url in Set(state.panes.map(\.currentURL)) {
            NotificationCenter.default.post(name: .quadFinderDirectoryDidChange, object: url)
        }
    }

    var activePane: PaneState? { pane(id: state.activePaneID) }
    var canAddPane: Bool { state.panes.count < 4 }
    var canClosePane: Bool { state.panes.count > 1 }

    func pane(id: UUID) -> PaneState? { state.panes.first { $0.id == id } }

    func paneID(in slot: PaneSlot) -> UUID? { state.slots[slot] }

    func updatePane(id: UUID, _ change: (inout PaneState) -> Void) {
        guard let index = state.panes.firstIndex(where: { $0.id == id }) else { return }
        change(&state.panes[index])
        save()
    }

    func addTab(to paneID: UUID) {
        updatePane(id: paneID) { pane in
            var tab = TabState(currentURL: pane.currentURL)
            tab.viewStyle = pane.viewStyle
            tab.showsHiddenFiles = pane.showsHiddenFiles
            tab.accessBookmark = pane.accessBookmark
            pane.tabs.append(tab)
            pane.activeTabID = tab.id
        }
        if paneID == state.activePaneID { reloadQuickLookForActivePane() }
    }

    func selectTab(_ tabID: UUID, in paneID: UUID) {
        updatePane(id: paneID) { pane in
            guard pane.tabs.contains(where: { $0.id == tabID }) else { return }
            pane.activeTabID = tabID
        }
        if paneID == state.activePaneID { reloadQuickLookForActivePane() }
    }

    func closeTab(_ tabID: UUID, in paneID: UUID) {
        updatePane(id: paneID) { pane in
            guard pane.tabs.count > 1, let index = pane.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            let wasActive = pane.activeTabID == tabID
            pane.tabs.remove(at: index)
            if wasActive { pane.activeTabID = pane.tabs[min(index, pane.tabs.count - 1)].id }
        }
        if paneID == state.activePaneID { reloadQuickLookForActivePane() }
    }

    func transferTab(_ tabID: UUID, from sourcePaneID: UUID, to targetPaneID: UUID, copy: Bool) {
        guard sourcePaneID != targetPaneID,
              let sourceIndex = state.panes.firstIndex(where: { $0.id == sourcePaneID }),
              let targetIndex = state.panes.firstIndex(where: { $0.id == targetPaneID }),
              let tabIndex = state.panes[sourceIndex].tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if !copy && state.panes[sourceIndex].tabs.count == 1 { return }
        var tab = state.panes[sourceIndex].tabs[tabIndex]
        if copy { tab.id = UUID() }
        state.panes[targetIndex].tabs.append(tab)
        state.panes[targetIndex].activeTabID = tab.id
        if !copy {
            state.panes[sourceIndex].tabs.remove(at: tabIndex)
            if state.panes[sourceIndex].activeTabID == tabID {
                state.panes[sourceIndex].activeTabID = state.panes[sourceIndex].tabs[min(tabIndex, state.panes[sourceIndex].tabs.count - 1)].id
            }
        }
        state.activePaneID = targetPaneID
        reloadQuickLookForActivePane()
        save()
    }

    func activate(_ id: UUID) {
        guard state.activePaneID != id, pane(id: id) != nil else { return }
        state.previousActivePaneID = state.activePaneID
        state.activePaneID = id
        QuickLookPresenter.shared.reloadSelection(
            (pane(id: id)?.selectedURLs ?? []).sorted { $0.path < $1.path }
        )
        save()
    }

    func activateNext(reverse: Bool = false) {
        let ids = state.orderedPaneIDs
        guard let current = ids.firstIndex(of: state.activePaneID), !ids.isEmpty else { return }
        let delta = reverse ? -1 : 1
        activate(ids[(current + delta + ids.count) % ids.count])
    }

    func activatePane(number: Int) {
        let ids = state.orderedPaneIDs
        guard ids.indices.contains(number - 1) else { return }
        activate(ids[number - 1])
    }

    func activateDirection(horizontal: Int, vertical: Int) {
        guard let currentSlot = state.slots.first(where: { $0.value == state.activePaneID })?.key else { return }
        let coordinates: [PaneSlot: (Int, Int)] = [
            .topLeft: (0, 0), .topRight: (1, 0), .bottomLeft: (0, 1), .bottomRight: (1, 1)
        ]
        guard let origin = coordinates[currentSlot] else { return }
        let candidates = state.slots.keys.compactMap { slot -> (PaneSlot, Int)? in
            guard let point = coordinates[slot] else { return nil }
            let dx = point.0 - origin.0
            let dy = point.1 - origin.1
            guard (horizontal == 0 || dx.signum() == horizontal.signum()),
                  (vertical == 0 || dy.signum() == vertical.signum()),
                  (horizontal == 0 || dx != 0), (vertical == 0 || dy != 0) else { return nil }
            return (slot, abs(dx) + abs(dy))
        }
        if let slot = candidates.min(by: { $0.1 < $1.1 })?.0, let id = state.slots[slot] { activate(id) }
    }

    func addPane() {
        guard canAddPane, let source = activePane else { return }
        var pane = PaneState(currentURL: source.currentURL)
        pane.viewStyle = source.viewStyle
        pane.showsHiddenFiles = source.showsHiddenFiles
        pane.accessBookmark = source.accessBookmark
        let freeSlot = PaneSlot.allCases.first { state.slots[$0] == nil } ?? .bottomRight
        state.panes.append(pane)
        state.slots[freeSlot] = pane.id
        state.previousActivePaneID = state.activePaneID
        state.activePaneID = pane.id
        state.layout = WorkspaceState.defaultLayout(for: state.panes.count, preferred: state.layout)
        state.maximizedPaneID = nil
        state.normalize()
        reloadQuickLookForActivePane()
        save()
    }

    func closeActivePane() { closePane(state.activePaneID) }

    func closePane(_ id: UUID) {
        guard canClosePane,
              let paneIndex = state.panes.firstIndex(where: { $0.id == id }),
              let slot = state.slots.first(where: { $0.value == id })?.key else { return }
        let wasActive = state.activePaneID == id
        let visualIDs = state.orderedPaneIDs
        let closedVisualIndex = visualIDs.firstIndex(of: id) ?? 0
        recentlyClosedPane = (state.panes[paneIndex], slot)
        state.panes.remove(at: paneIndex)
        state.slots[slot] = nil
        compactSlots()
        if wasActive {
            let remaining = state.orderedPaneIDs
            state.activePaneID = remaining[min(closedVisualIndex, remaining.count - 1)]
        }
        if state.previousActivePaneID == id { state.previousActivePaneID = nil }
        state.layout = WorkspaceState.defaultLayout(for: state.panes.count, preferred: state.layout)
        state.maximizedPaneID = nil
        state.normalize()
        reloadQuickLookForActivePane()
        save()
    }

    func restoreClosedPane() {
        guard canAddPane, let closed = recentlyClosedPane else { return }
        let slot = state.slots[closed.slot] == nil ? closed.slot : (PaneSlot.allCases.first { state.slots[$0] == nil } ?? .bottomRight)
        state.panes.append(closed.pane)
        state.slots[slot] = closed.pane.id
        state.activePaneID = closed.pane.id
        state.layout = WorkspaceState.defaultLayout(for: state.panes.count, preferred: state.layout)
        recentlyClosedPane = nil
        reloadQuickLookForActivePane()
        save()
    }

    func setLayout(_ layout: PaneLayout) {
        let valid: Bool = switch state.panes.count {
        case 1: layout == .single
        case 2: layout == .vertical || layout == .horizontal
        case 3: [.leading, .trailing, .top, .bottom].contains(layout)
        default: layout == .grid
        }
        guard valid else { return }
        state.layout = layout
        save()
    }

    func setRatios(vertical: Double? = nil, horizontal: Double? = nil) {
        if let vertical { state.verticalRatio = min(max(vertical, 0.2), 0.8) }
        if let horizontal { state.horizontalRatio = min(max(horizontal, 0.2), 0.8) }
        save()
    }

    func resetRatios() { setRatios(vertical: 0.5, horizontal: 0.5) }

    func toggleMaximize() {
        state.maximizedPaneID = state.maximizedPaneID == nil ? state.activePaneID : nil
        save()
    }

    func swapActive(with target: UUID) {
        guard target != state.activePaneID,
              let activeSlot = state.slots.first(where: { $0.value == state.activePaneID })?.key,
              let targetSlot = state.slots.first(where: { $0.value == target })?.key else { return }
        state.slots[activeSlot] = target
        state.slots[targetSlot] = state.activePaneID
        save()
    }

    func navigate(paneID: UUID, to url: URL, recordHistory: Bool = true, bookmark: Data? = nil, propagateLinks: Bool = true) {
        let previousURL = pane(id: paneID)?.currentURL
        updatePane(id: paneID) { pane in
            if recordHistory, pane.currentURL != url {
                pane.backwardHistory.append(pane.currentURL)
                pane.forwardHistory.removeAll()
            }
            pane.currentURL = url
            pane.selectedURLs.removeAll()
            if let bookmark { pane.accessBookmark = bookmark }
        }
        if paneID == state.activePaneID { QuickLookPresenter.shared.reloadSelection([]) }
        var recentInfo: [String: Any] = ["kind": SidebarRecentItem.Kind.folder.rawValue]
        if let accessBookmark = pane(id: paneID)?.accessBookmark { recentInfo["bookmark"] = accessBookmark }
        NotificationCenter.default.post(
            name: .quadFinderRecentAccess, object: url,
            userInfo: recentInfo
        )
        if propagateLinks, let previousURL,
           url.deletingLastPathComponent().standardizedFileURL == previousURL.standardizedFileURL {
            propagateRelativeNavigation(from: paneID, childName: url.lastPathComponent)
        }
    }

    /// A successfully ejected volume must not leave panes pointing at a path
    /// that can no longer be enumerated. Move every affected active tab home.
    func relocatePanesAfterEject(of volumeURL: URL,
                                 homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let affected = state.panes.filter { Self.contains($0.currentURL, in: volumeURL) }.map(\.id)
        for paneID in affected {
            updatePane(id: paneID) { pane in
                pane.backwardHistory.append(pane.currentURL)
                pane.forwardHistory.removeAll()
                pane.currentURL = homeURL
                pane.selectedURLs.removeAll()
                pane.scrollAnchor = nil
                pane.accessBookmark = nil
            }
            NotificationCenter.default.post(name: .quadFinderDirectoryDidChange, object: homeURL)
        }
        if affected.contains(state.activePaneID) { QuickLookPresenter.shared.reloadSelection([]) }
    }

    static func contains(_ candidate: URL, in ancestor: URL) -> Bool {
        func components(_ url: URL) -> [String] {
            url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        }
        let root = components(ancestor)
        let child = components(candidate)
        return child.count >= root.count && Array(child.prefix(root.count)) == root
    }

    func setSelection(_ urls: Set<URL>, in paneID: UUID, propagateLinks: Bool = true) {
        updatePane(id: paneID) { $0.selectedURLs = urls }
        if paneID == state.activePaneID {
            QuickLookPresenter.shared.reloadSelection(urls.sorted { $0.path < $1.path })
        }
        if propagateLinks { propagateSelection(from: paneID, names: Set(urls.map(\.lastPathComponent))) }
    }

    func setPaneLinkGroup(_ paneIDs: Set<UUID>, followsNavigation: Bool, followsSelection: Bool) {
        linkGeneration = UUID()
        linkEventTokens.removeAll()
        let valid = paneIDs.intersection(Set(state.panes.map(\.id)))
        state.paneLinkGroup = valid.count >= 2
            ? PaneLinkGroup(paneIDs: valid, followsRelativeNavigation: followsNavigation, followsSelection: followsSelection)
            : nil
        save()
    }

    func clearPaneLinkGroup() {
        linkGeneration = UUID()
        linkEventTokens.removeAll()
        state.paneLinkGroup = nil
        save()
    }

    func waitForLinkPropagation() async {
        let tasks = linkTasks
        for task in tasks { await task.value }
        linkTasks.removeAll()
    }

    func setComparisonTarget(_ targetPaneID: UUID) {
        guard targetPaneID != state.activePaneID, pane(id: targetPaneID) != nil else { return }
        let source = state.activePaneID
        updateModuleSettings {
            $0.comparison.isVisible = true
            $0.comparison.context = .pair(source, targetPaneID)
        }
    }

    func startComparison(usesChecksums: Bool) {
        guard case .pair(let sourceID, let targetID) = state.moduleSettings.comparison.context,
              let source = pane(id: sourceID), let target = pane(id: targetID) else {
            error = UserFacingError(title: L10n.tr("比較対象がありません"), message: L10n.tr("アクティブペインと比較する別ペインを選択してください。"))
            return
        }
        comparisonController.start(ComparisonRequest(
            sourcePaneID: sourceID,
            targetPaneID: targetID,
            sourceURL: source.currentURL.standardizedFileURL,
            targetURL: target.currentURL.standardizedFileURL,
            sourceBookmark: source.accessBookmark,
            targetBookmark: target.accessBookmark,
            usesChecksums: usesChecksums
        ))
    }

    func enqueueSync(_ plan: SyncExecutionPlan) {
        let sources = plan.actions.compactMap(\.sourceURL)
        operationQueue.enqueue(PendingFileOperation(
            kind: .sync,
            sourcePaneID: comparisonPair?.0,
            targetPaneID: comparisonPair?.1 ?? state.activePaneID,
            sourceURLs: sources,
            targetDirectoryURL: plan.targetSnapshot.directoryURL,
            sourceAccessBookmark: plan.sourceBookmark,
            targetAccessBookmark: plan.targetBookmark,
            syncPlan: plan
        ))
    }

    var comparisonPair: (UUID, UUID)? {
        if case .pair(let source, let target) = state.moduleSettings.comparison.context { return (source, target) }
        return nil
    }

    func goBack(paneID: UUID) {
        updatePane(id: paneID) { pane in
            guard let url = pane.backwardHistory.popLast() else { return }
            pane.forwardHistory.append(pane.currentURL)
            pane.currentURL = url
            pane.selectedURLs.removeAll()
        }
        if paneID == state.activePaneID { QuickLookPresenter.shared.reloadSelection([]) }
    }

    func goForward(paneID: UUID) {
        updatePane(id: paneID) { pane in
            guard let url = pane.forwardHistory.popLast() else { return }
            pane.backwardHistory.append(pane.currentURL)
            pane.currentURL = url
            pane.selectedURLs.removeAll()
        }
        if paneID == state.activePaneID { QuickLookPresenter.shared.reloadSelection([]) }
    }

    func goUp(paneID: UUID) {
        guard let pane = pane(id: paneID) else { return }
        navigate(paneID: paneID, to: pane.currentURL.deletingLastPathComponent())
    }

    func prepareDrop(sourcePaneID: UUID?, targetPaneID: UUID, urls: [URL]) {
        guard let target = pane(id: targetPaneID), !urls.isEmpty else { return }
        if let sourcePaneID, pane(id: sourcePaneID) == nil { return }
        prepareDrop(
            sourcePaneID: sourcePaneID,
            targetPaneID: targetPaneID,
            targetDirectoryURL: target.currentURL,
            targetAccessBookmark: target.accessBookmark,
            urls: urls
        )
    }

    /// Drops onto a folder row while retaining the owning pane for progress,
    /// history and security-scoped access.
    func prepareDrop(sourcePaneID: UUID?, targetPaneID: UUID,
                     targetDirectoryURL: URL, urls: [URL], intent: FinderDropIntent? = nil) {
        guard let target = pane(id: targetPaneID), !urls.isEmpty else { return }
        if let sourcePaneID, pane(id: sourcePaneID) == nil { return }
        prepareDrop(
            sourcePaneID: sourcePaneID,
            targetPaneID: targetPaneID,
            targetDirectoryURL: targetDirectoryURL,
            targetAccessBookmark: target.accessBookmark,
            urls: urls,
            intent: intent
        )
    }

    /// Finder-style destination used by sidebar rows.  A sidebar target does
    /// not have to be open in a pane; the active pane ID is retained only as
    /// the operation's UI owner while the actual destination URL/bookmark are
    /// carried independently.
    func prepareSidebarDrop(sourcePaneID: UUID?, targetDirectoryURL: URL,
                            targetAccessBookmark: Data?, urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let sourcePaneID, pane(id: sourcePaneID) == nil { return }
        prepareDrop(
            sourcePaneID: sourcePaneID,
            targetPaneID: state.activePaneID,
            targetDirectoryURL: targetDirectoryURL,
            targetAccessBookmark: targetAccessBookmark,
            urls: urls
        )
    }

    private func prepareDrop(sourcePaneID: UUID?, targetPaneID: UUID,
                             targetDirectoryURL: URL, targetAccessBookmark: Data?,
                             urls: [URL], intent explicitIntent: FinderDropIntent? = nil) {
        let intent = explicitIntent ?? {
            let modifiers = DropModifierResolver.resolve(
                current: NSApp?.currentEvent?.modifierFlags,
                tracked: DragModifierTracker.shared.trackedFlags
            )
            return FinderDropIntent(FinderDragOperationPolicy.operation(
                sourceURLs: urls, targetDirectory: targetDirectoryURL, modifiers: modifiers
            ))
        }()
        if intent == .link {
            let request = SymbolicLinkRequest(
                sourceURLs: urls.map(\.standardizedFileURL),
                targetDirectoryURL: targetDirectoryURL.standardizedFileURL,
                sourceAccessBookmark: sourcePaneID.flatMap { pane(id: $0)?.accessBookmark },
                targetAccessBookmark: targetAccessBookmark
            )
            do {
                let targets = try SymbolicLinkService().createLinks(request)
                let steps = zip(request.sourceURLs, targets).compactMap { source, target -> HistoryStep? in
                    guard let fp = HistoryFingerprint.capture(target) else { return nil }
                    return .symbolicLink(source: source, target: target, targetFingerprint: fp)
                }
                operationHistory.record(.init(kind: .symbolicLink, summary: L10n.format("%lld個のシンボリックリンクを作成", Int64(steps.count)), steps: steps, itemCount: steps.count,
                                              sourceBookmark: request.sourceAccessBookmark, targetBookmark: request.targetAccessBookmark))
                NotificationCenter.default.post(name: .quadFinderDirectoryDidChange, object: targetDirectoryURL)
            } catch let partial as PartialOperationFailure {
                if partial.outcome.completedItems == 0, isPermissionFailure(partial.underlying) {
                    retrySymbolicLinkAfterAuthorization(request, sourcePaneID: sourcePaneID, targetPaneID: targetPaneID)
                    DragModifierTracker.shared.reset()
                    return
                }
                if !partial.outcome.historySteps.isEmpty {
                    operationHistory.record(.init(kind: .symbolicLink,
                        summary: L10n.format("%lld個のシンボリックリンクを作成（一部完了）", Int64(partial.outcome.historySteps.count)),
                        steps: partial.outcome.historySteps, itemCount: partial.outcome.completedItems,
                        sourceBookmark: request.sourceAccessBookmark, targetBookmark: request.targetAccessBookmark))
                }
                report(L10n.tr("シンボリックリンクを作成できません"), error: partial.underlying)
            } catch {
                if isPermissionFailure(error) {
                    retrySymbolicLinkAfterAuthorization(request, sourcePaneID: sourcePaneID, targetPaneID: targetPaneID)
                } else {
                    report(L10n.tr("シンボリックリンクを作成できません"), error: error)
                }
            }
            DragModifierTracker.shared.reset()
            return
        }
        DragModifierTracker.shared.reset()
        pendingDrop = PendingDrop(
            sourcePaneID: sourcePaneID,
            targetPaneID: targetPaneID,
            sourceURLs: urls.map(\.standardizedFileURL),
            targetDirectoryURL: targetDirectoryURL.standardizedFileURL,
            sourceAccessBookmark: sourcePaneID.flatMap { pane(id: $0)?.accessBookmark },
            targetAccessBookmark: targetAccessBookmark,
            clipboardCutReceipt: nil
        )
        // Finder performs the operation selected by volume and live modifier
        // state immediately. Only an actual name conflict opens the planner.
        performPendingDrop(as: intent == .move ? .move : .copy)
    }

    /// A permission failure may require two independent grants. Each panel is
    /// shown at most once and the operation is retried exactly once, preventing
    /// a denied source/target pair from entering an infinite prompt loop.
    private func retrySymbolicLinkAfterAuthorization(
        _ request: SymbolicLinkRequest, sourcePaneID: UUID?, targetPaneID: UUID
    ) {
        let sourceRequirements = request.sourceURLs.map { $0.deletingLastPathComponent() }
        guard let sourceGrant = requestFolderGrant(
            covering: sourceRequirements, initialURL: sourceRequirements.first,
            message: L10n.tr("シンボリックリンク元を含むフォルダを選択してください。")
        ) else { return }

        let access = SecurityScopeAccess()
        let targetGrant: (url: URL, bookmark: Data?)
        if access.contains(scopeURL: sourceGrant.url, requestedURL: request.targetDirectoryURL) {
            targetGrant = sourceGrant
        } else {
            guard let grant = requestFolderGrant(
                covering: [request.targetDirectoryURL], initialURL: request.targetDirectoryURL,
                message: L10n.tr("シンボリックリンクの作成先フォルダを選択してください。")
            ) else { return }
            targetGrant = grant
        }

        if let sourcePaneID { updatePane(id: sourcePaneID) { $0.accessBookmark = sourceGrant.bookmark } }
        updatePane(id: targetPaneID) { $0.accessBookmark = targetGrant.bookmark }
        let retried = SymbolicLinkRequest(
            sourceURLs: request.sourceURLs, targetDirectoryURL: request.targetDirectoryURL,
            sourceAccessBookmark: sourceGrant.bookmark, targetAccessBookmark: targetGrant.bookmark
        )
        do {
            let targets = try SymbolicLinkService().createLinks(retried)
            let steps = zip(retried.sourceURLs, targets).compactMap { source, target -> HistoryStep? in
                guard let fingerprint = HistoryFingerprint.capture(target) else { return nil }
                return .symbolicLink(source: source, target: target, targetFingerprint: fingerprint)
            }
            operationHistory.record(.init(
                kind: .symbolicLink, summary: L10n.format("%lld個のシンボリックリンクを作成", Int64(steps.count)), steps: steps,
                itemCount: steps.count, sourceBookmark: retried.sourceAccessBookmark,
                targetBookmark: retried.targetAccessBookmark
            ))
            NotificationCenter.default.post(name: .quadFinderDirectoryDidChange, object: retried.targetDirectoryURL)
        } catch {
            // This is the one permitted retry. Surface the real Cocoa/POSIX
            // failure without requesting authorization again.
            report(L10n.tr("シンボリックリンクを作成できません"), error: error)
        }
    }

    private func requestFolderGrant(
        covering requestedURLs: [URL], initialURL: URL?, message: String
    ) -> (url: URL, bookmark: Data?)? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = initialURL
        panel.prompt = L10n.tr("許可")
        panel.message = message
        guard panel.runModal() == .OK, let grantedURL = panel.url else { return nil }
        guard requestedURLs.allSatisfy({ SecurityScopeAccess().contains(scopeURL: grantedURL, requestedURL: $0) }) else {
            report(L10n.tr("フォルダを使用できません"), error: CocoaError(.fileReadNoPermission,
                userInfo: [NSLocalizedDescriptionKey: L10n.tr("選択したフォルダには対象が含まれていません。")] ))
            return nil
        }
        return (grantedURL, try? FileSystemService.bookmark(for: grantedURL))
    }

    private func isPermissionFailure(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain, value.code == Int(EACCES) || value.code == Int(EPERM) { return true }
        if value.domain == NSCocoaErrorDomain,
           value.code == CocoaError.fileReadNoPermission.rawValue || value.code == CocoaError.fileWriteNoPermission.rawValue { return true }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionFailure(underlying) }
        return false
    }

    func performPendingDrop(as kind: FileOperationKind) {
        guard let drop = pendingDrop else { return }
        pendingDrop = nil
        // Finder treats a move back into the item's current directory as a
        // successful no-op. Do not mis-route that harmless case to the name
        // conflict planner. Mixed drags still execute their non-no-op items.
        let effectiveSources = kind == .move ? drop.sourceURLs.filter {
            !FileURLIdentity.isSame($0.deletingLastPathComponent(), drop.targetDirectoryURL)
        } : drop.sourceURLs
        guard !effectiveSources.isEmpty else { return }
        let operation = PendingFileOperation(
            kind: kind,
            sourcePaneID: drop.sourcePaneID,
            targetPaneID: drop.targetPaneID,
            sourceURLs: effectiveSources,
            targetDirectoryURL: drop.targetDirectoryURL,
            sourceAccessBookmark: drop.sourceAccessBookmark,
            targetAccessBookmark: drop.targetAccessBookmark,
            clipboardCutReceipt: kind == .move ? drop.clipboardCutReceipt : nil
        )
        if hasDestinationConflict(sourceURLs: effectiveSources, targetDirectoryURL: drop.targetDirectoryURL) {
            presentTransferPlanner(TransferPlanRequest(
                kind: kind, sourceURLs: effectiveSources, targetDirectoryURL: drop.targetDirectoryURL,
                sourceAccessBookmark: drop.sourceAccessBookmark, targetAccessBookmark: drop.targetAccessBookmark
            ), sourcePaneID: drop.sourcePaneID, targetPaneID: drop.targetPaneID,
               clipboardCutReceipt: kind == .move ? drop.clipboardCutReceipt : nil)
        } else {
            operationQueue.enqueue(operation)
        }
    }

    func prepareExplicitTransfer(kind: FileOperationKind) {
        guard let source = activePane, !source.selectedURLs.isEmpty else {
            error = UserFacingError(title: L10n.tr("項目が選択されていません"), message: L10n.tr("アクティブペインでコピーまたは移動する項目を選択してください。"))
            return
        }
        let destinations = destinationCandidates(excluding: source.id)
        guard !destinations.isEmpty else {
            error = UserFacingError(title: L10n.tr("コピー先がありません"), message: L10n.tr("別のペインを追加してください。"))
            return
        }
        let transfer = PendingTransfer(
            kind: kind,
            sourcePaneID: source.id,
            sourceURLs: source.selectedURLs.map(\.standardizedFileURL),
            sourceAccessBookmark: source.accessBookmark,
            destinations: destinations
        )
        if destinations.count == 1 {
            enqueue(transfer, destination: destinations[0])
        } else {
            pendingTransfer = transfer
        }
    }

    func confirmExplicitTransfer(to paneID: UUID) {
        guard let transfer = pendingTransfer,
              let destination = transfer.destinations.first(where: { $0.paneID == paneID }) else { return }
        pendingTransfer = nil
        enqueue(transfer, destination: destination)
    }

    func destinationCandidates(excluding paneID: UUID) -> [DestinationCandidate] {
        state.orderedPaneIDs.enumerated().compactMap { index, id in
            guard id != paneID, let pane = pane(id: id) else { return nil }
            return DestinationCandidate(
                paneID: id,
                paneNumber: index + 1,
                directoryURL: pane.currentURL.standardizedFileURL,
                accessBookmark: pane.accessBookmark
            )
        }
    }

    func savePaneSet(named name: String) {
        do { _ = try paneSets.save(name: name, workspace: state) }
        catch { report(L10n.tr("ペインセットを保存できません"), error: error) }
    }

    func applyPaneSet(_ id: UUID) {
        guard var restored = paneSets.sets.first(where: { $0.id == id })?.workspace else { return }
        restored.normalize()
        state = restored
        recentlyClosedPane = nil
        reloadQuickLookForActivePane()
        save()
    }

    func deletePaneSet(_ id: UUID) {
        do { try paneSets.delete(id) }
        catch { report(L10n.tr("ペインセットを削除できません"), error: error) }
    }

    func updateModuleSettings(_ change: (inout ModuleSettings) -> Void) {
        change(&state.moduleSettings)
        state.normalize()
        save()
    }

    func report(_ title: String, error: Error) {
        self.error = UserFacingError(title: title, message: error.localizedDescription)
    }

    func save() {
        directoryMonitor.update(urls: Set(state.panes.map(\.currentURL)))
        do { try persistence.save(state) }
        catch { self.error = UserFacingError(title: L10n.tr("状態を保存できませんでした"), message: error.localizedDescription) }
    }

    private func compactSlots() {
        let ids = PaneSlot.allCases.compactMap { state.slots[$0] }
        state.slots.removeAll()
        for (slot, id) in zip(PaneSlot.allCases, ids) { state.slots[slot] = id }
    }

    private func enqueue(_ transfer: PendingTransfer, destination: DestinationCandidate) {
        if hasDestinationConflict(sourceURLs: transfer.sourceURLs, targetDirectoryURL: destination.directoryURL) {
            presentTransferPlanner(TransferPlanRequest(
                kind: transfer.kind, sourceURLs: transfer.sourceURLs,
                targetDirectoryURL: destination.directoryURL,
                sourceAccessBookmark: transfer.sourceAccessBookmark,
                targetAccessBookmark: destination.accessBookmark
            ), sourcePaneID: transfer.sourcePaneID, targetPaneID: destination.paneID,
               clipboardCutReceipt: nil)
            return
        }
        operationQueue.enqueue(PendingFileOperation(
            kind: transfer.kind,
            sourcePaneID: transfer.sourcePaneID,
            targetPaneID: destination.paneID,
            sourceURLs: transfer.sourceURLs,
            targetDirectoryURL: destination.directoryURL,
            sourceAccessBookmark: transfer.sourceAccessBookmark,
            targetAccessBookmark: destination.accessBookmark
        ))
    }

    private func hasDestinationConflict(sourceURLs: [URL], targetDirectoryURL: URL) -> Bool {
        sourceURLs.contains {
            FileManager.default.fileExists(
                atPath: targetDirectoryURL.appendingPathComponent($0.lastPathComponent).path
            )
        }
    }

    private func presentTransferPlanner(
        _ request: TransferPlanRequest,
        sourcePaneID: UUID?,
        targetPaneID: UUID,
        clipboardCutReceipt: ClipboardCutReceipt?
    ) {
        transferPlanner = TransferPlanController(
            request: request,
            queue: operationQueue,
            sourcePaneID: sourcePaneID,
            targetPaneID: targetPaneID,
            clipboardCutReceipt: clipboardCutReceipt
        )
    }

    private func propagateRelativeNavigation(from sourcePaneID: UUID, childName: String) {
        guard let group = state.paneLinkGroup,
              group.followsRelativeNavigation,
              group.paneIDs.contains(sourcePaneID) else { return }
        let generation = linkGeneration
        let eventKey = "navigation:\(sourcePaneID.uuidString)"
        let eventToken = UUID()
        linkEventTokens[eventKey] = eventToken
        let destinations = group.paneIDs.subtracting([sourcePaneID]).compactMap { id in
            pane(id: id).map { (id, $0.currentURL.appendingPathComponent(childName, isDirectory: true), $0.accessBookmark) }
        }
        let task = Task { [weak self] in
            for (id, candidate, bookmark) in destinations {
                guard let self else { return }
                let exists = await self.resourceExists(candidate, bookmark: bookmark, requiresDirectory: true)
                guard self.linkGeneration == generation, self.linkEventTokens[eventKey] == eventToken else { return }
                if exists {
                    self.navigate(paneID: id, to: candidate, propagateLinks: false)
                    self.paneNotifications[id] = nil
                } else {
                    self.paneNotifications[id] = L10n.format("リンク先に「%@」がありません", childName)
                }
            }
        }
        linkTasks.append(task)
    }

    private func propagateSelection(from sourcePaneID: UUID, names: Set<String>) {
        guard !names.isEmpty,
              let group = state.paneLinkGroup,
              group.followsSelection,
              group.paneIDs.contains(sourcePaneID) else { return }
        let generation = linkGeneration
        let eventKey = "selection:\(sourcePaneID.uuidString)"
        let eventToken = UUID()
        linkEventTokens[eventKey] = eventToken
        let destinations = group.paneIDs.subtracting([sourcePaneID]).compactMap { id in
            pane(id: id).map { (id, $0.currentURL, $0.accessBookmark) }
        }
        let task = Task { [weak self] in
            for (id, directory, bookmark) in destinations {
                let urls = names.map { directory.appendingPathComponent($0) }
                guard let self else { return }
                let checks = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                    for url in urls { group.addTask { await self.resourceExists(url, bookmark: bookmark, requiresDirectory: false) } }
                    var values: [Bool] = []
                    for await value in group { values.append(value) }
                    return values
                }
                let allExist = checks.allSatisfy { $0 }
                guard self.linkGeneration == generation, self.linkEventTokens[eventKey] == eventToken else { return }
                if allExist {
                    self.setSelection(Set(urls), in: id, propagateLinks: false)
                    self.paneNotifications[id] = nil
                } else {
                    self.paneNotifications[id] = L10n.tr("リンク先に対応する選択項目がありません")
                }
            }
        }
        linkTasks.append(task)
    }

    private func resourceExists(_ url: URL, bookmark: Data?, requiresDirectory: Bool) async -> Bool {
        await Task.detached {
            var scopedURL: URL?
            var started = false
            if let bookmark {
                scopedURL = try? FileSystemService.resolveBookmark(bookmark)
                started = scopedURL?.startAccessingSecurityScopedResource() == true
            }
            defer { if started { scopedURL?.stopAccessingSecurityScopedResource() } }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && (!requiresDirectory || isDirectory.boolValue)
        }.value
    }

    private func reloadQuickLookForActivePane() {
        QuickLookPresenter.shared.reloadSelection(
            (activePane?.selectedURLs ?? []).sorted { $0.path < $1.path }
        )
    }
}

extension Notification.Name {
    static let quadFinderDirectoryDidChange = Notification.Name("QuadFinderDirectoryDidChange")
    static let quadFinderRecentAccess = Notification.Name("QuadFinderRecentAccess")
}
