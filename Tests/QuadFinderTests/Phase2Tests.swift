import Foundation
import Testing
@testable import QuadFinder

private struct LegacyPane: Codable {
    let id: UUID
    let currentURL: URL
    let backwardHistory: [URL]
    let forwardHistory: [URL]
    let selectedURLs: Set<URL>
    let viewStyle: FileViewStyle
    let showsHiddenFiles: Bool
    let scrollAnchor: URL?
    let accessBookmark: Data?
}

private struct LegacyWorkspace: Codable {
    let version: Int
    let panes: [LegacyPane]
    let slots: [PaneSlot: UUID]
    let activePaneID: UUID
    let previousActivePaneID: UUID?
    let layout: PaneLayout
    let verticalRatio: Double
    let horizontalRatio: Double
    let maximizedPaneID: UUID?
}

@MainActor
struct Phase2StateTests {
    private func makeStore(
        queue: FileOperationQueue? = nil,
        paneSets: PaneSetStore? = nil
    ) -> WorkspaceStore {
        WorkspaceStore(
            persistence: MemoryWorkspacePersistence(storage: .init()),
            operationQueue: queue,
            paneSets: paneSets
        )
    }

    @Test func migratesV1WorkspaceIntoOneIndependentTab() throws {
        let paneID = UUID()
        let root = URL(fileURLWithPath: "/tmp/legacy")
        let selected = root.appendingPathComponent("selected")
        let legacy = LegacyWorkspace(
            version: 1,
            panes: [LegacyPane(
                id: paneID,
                currentURL: root,
                backwardHistory: [URL(fileURLWithPath: "/tmp/before")],
                forwardHistory: [URL(fileURLWithPath: "/tmp/after")],
                selectedURLs: [selected],
                viewStyle: .columns,
                showsHiddenFiles: true,
                scrollAnchor: selected,
                accessBookmark: Data("legacy-bookmark".utf8)
            )],
            slots: [.topLeft: paneID],
            activePaneID: paneID,
            previousActivePaneID: nil,
            layout: .single,
            verticalRatio: 0.42,
            horizontalRatio: 0.58,
            maximizedPaneID: nil
        )

        var migrated = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(legacy))
        migrated.normalize()

        #expect(migrated.version == WorkspaceState.currentVersion)
        #expect(migrated.panes[0].tabs.count == 1)
        #expect(migrated.panes[0].currentURL == root)
        #expect(migrated.panes[0].backwardHistory.count == 1)
        #expect(migrated.panes[0].forwardHistory.count == 1)
        #expect(migrated.panes[0].selectedURLs == [selected])
        #expect(migrated.panes[0].viewStyle == .columns)
        #expect(migrated.panes[0].showsHiddenFiles)
        #expect(migrated.moduleSettings.operationQueue.context == .window)
    }

    @Test func tabsKeepIndependentNavigationSelectionAndSettings() throws {
        let store = makeStore()
        let paneID = store.state.activePaneID
        let firstTab = try #require(store.activePane?.activeTabID)
        let firstURL = URL(fileURLWithPath: "/tmp/first-tab")
        store.navigate(paneID: paneID, to: firstURL)
        store.updatePane(id: paneID) {
            $0.selectedURLs = [firstURL.appendingPathComponent("one")]
            $0.viewStyle = .columns
        }
        store.addTab(to: paneID)
        let secondTab = try #require(store.activePane?.activeTabID)
        let secondURL = URL(fileURLWithPath: "/tmp/second-tab")
        store.navigate(paneID: paneID, to: secondURL)
        store.updatePane(id: paneID) { $0.viewStyle = .icons }

        store.selectTab(firstTab, in: paneID)
        #expect(store.activePane?.currentURL == firstURL)
        #expect(store.activePane?.selectedURLs.count == 1)
        #expect(store.activePane?.viewStyle == .columns)
        store.selectTab(secondTab, in: paneID)
        #expect(store.activePane?.currentURL == secondURL)
        #expect(store.activePane?.selectedURLs.isEmpty == true)
        #expect(store.activePane?.viewStyle == .icons)
    }

    @Test func tabAddCloseMoveAndCopyPreserveRules() throws {
        let store = makeStore()
        let sourcePane = store.state.activePaneID
        let originalTab = try #require(store.activePane?.activeTabID)
        store.closeTab(originalTab, in: sourcePane)
        #expect(store.pane(id: sourcePane)?.tabs.count == 1)

        store.addTab(to: sourcePane)
        let movingTab = try #require(store.pane(id: sourcePane)?.activeTabID)
        let movingURL = URL(fileURLWithPath: "/tmp/moving-tab")
        store.navigate(paneID: sourcePane, to: movingURL)
        store.addPane()
        let targetPane = store.state.activePaneID

        store.transferTab(movingTab, from: sourcePane, to: targetPane, copy: true)
        let copied = try #require(store.pane(id: targetPane)?.tabs.last)
        #expect(copied.id != movingTab)
        #expect(copied.currentURL == movingURL)
        #expect(store.pane(id: sourcePane)?.tabs.contains { $0.id == movingTab } == true)

        store.transferTab(movingTab, from: sourcePane, to: targetPane, copy: false)
        #expect(store.pane(id: sourcePane)?.tabs.count == 1)
        #expect(store.pane(id: targetPane)?.tabs.contains { $0.id == movingTab } == true)
        store.transferTab(originalTab, from: sourcePane, to: targetPane, copy: false)
        #expect(store.pane(id: sourcePane)?.tabs.count == 1)
        store.closePane(sourcePane)
        #expect(store.pane(id: targetPane)?.tabs.count == 3)
    }

    @Test func closingAndRestoringPanePreservesAllTabs() throws {
        let store = makeStore()
        store.addPane()
        let paneID = store.state.activePaneID
        let firstTab = try #require(store.activePane?.activeTabID)
        store.navigate(paneID: paneID, to: URL(fileURLWithPath: "/tmp/pane-tab-one"))
        store.addTab(to: paneID)
        let secondTab = try #require(store.activePane?.activeTabID)
        store.navigate(paneID: paneID, to: URL(fileURLWithPath: "/tmp/pane-tab-two"))

        store.closePane(paneID)
        store.restoreClosedPane()

        let restored = try #require(store.pane(id: paneID))
        #expect(restored.tabs.map(\.id) == [firstTab, secondTab])
        #expect(restored.tabs.map(\.currentURL.path) == ["/tmp/pane-tab-one", "/tmp/pane-tab-two"])
        #expect(restored.activeTabID == secondTab)
    }

    @Test func destinationCandidatesAreExplicitAndFrozenWhenChosen() async throws {
        let operatorStub = ScriptedFileOperator()
        let queue = FileOperationQueue(fileSystem: operatorStub)
        let store = makeStore(queue: queue)
        let source = store.state.activePaneID
        let item = URL(fileURLWithPath: "/tmp/source-item")
        store.updatePane(id: source) { $0.selectedURLs = [item] }
        store.addPane()
        let second = store.state.activePaneID
        store.navigate(paneID: second, to: URL(fileURLWithPath: "/tmp/destination-two"))
        store.addPane()
        let third = store.state.activePaneID
        store.navigate(paneID: third, to: URL(fileURLWithPath: "/tmp/destination-three"))
        store.activate(source)

        store.prepareExplicitTransfer(kind: .copy)
        let pending = try #require(store.pendingTransfer)
        #expect(pending.destinations.map(\.paneNumber) == [2, 3])
        #expect(pending.destinations[0].directoryURL.path == "/tmp/destination-two")
        store.navigate(paneID: second, to: URL(fileURLWithPath: "/tmp/changed-after-choice"))
        store.confirmExplicitTransfer(to: second)

        #expect(queue.jobs.first?.operation.targetDirectoryURL.path == "/tmp/destination-two")
        #expect(queue.jobs.first?.operation.sourceURLs == [item])
        await queue.waitUntilIdle()
    }

    @Test func singleDestinationQueuesImmediatelyWithRequestedMoveKind() async {
        let operatorStub = ScriptedFileOperator()
        let queue = FileOperationQueue(fileSystem: operatorStub)
        let store = makeStore(queue: queue)
        let source = store.state.activePaneID
        let item = URL(fileURLWithPath: "/tmp/move-source")
        store.updatePane(id: source) { $0.selectedURLs = [item] }
        store.addPane()
        let target = store.state.activePaneID
        store.navigate(paneID: target, to: URL(fileURLWithPath: "/tmp/only-target"))
        store.activate(source)

        store.prepareExplicitTransfer(kind: .move)

        #expect(store.pendingTransfer == nil)
        #expect(queue.jobs.count == 1)
        #expect(queue.jobs[0].operation.kind == .move)
        #expect(queue.jobs[0].operation.targetPaneID == target)
        await queue.waitUntilIdle()
    }

    @Test func moduleContextsNormalizeActivePinnedAndWindow() {
        let store = makeStore()
        store.addPane()
        let pinned = store.state.activePaneID
        store.updateModuleSettings {
            $0.selectionInfo.isVisible = true
            $0.selectionInfo.context = .pinned(pinned)
            $0.operationQueue.context = .active
        }
        #expect(store.state.moduleSettings.selectionInfo.context == .pinned(pinned))
        #expect(store.state.moduleSettings.operationQueue.context == .window)

        store.closePane(pinned)
        #expect(store.state.moduleSettings.selectionInfo.context == .active)
    }
}

private enum StubFailure: Error { case intentional }

private actor ScriptedFileOperator: FileOperating {
    private var completedTargets: [String] = []

    func perform(_ operation: PendingFileOperation) async throws {
        let name = operation.targetDirectoryURL.lastPathComponent
        if name == "slow" { try await Task.sleep(for: .milliseconds(80)) }
        if name == "fail" { throw StubFailure.intentional }
        try Task.checkCancellation()
        completedTargets.append(name)
    }

    func completed() -> [String] { completedTargets }
}

@MainActor
struct OperationQueueTests {
    private func operation(target: String, source: String = "source") -> PendingFileOperation {
        PendingFileOperation(
            kind: .copy,
            sourcePaneID: UUID(),
            targetPaneID: UUID(),
            sourceURLs: [URL(fileURLWithPath: "/tmp/\(source)")],
            targetDirectoryURL: URL(fileURLWithPath: "/tmp/\(target)")
        )
    }

    @Test func queueRunsSeriallyAndKeepsCompletedHistory() async {
        let stub = ScriptedFileOperator()
        let queue = FileOperationQueue(fileSystem: stub)
        queue.enqueue(operation(target: "one"))
        queue.enqueue(operation(target: "two"))
        await queue.waitUntilIdle()

        #expect(await stub.completed() == ["one", "two"])
        #expect(queue.jobs.map(\.status) == [.succeeded, .succeeded])
        queue.clearCompleted()
        #expect(queue.jobs.isEmpty)
    }

    @Test func queuedCancellationIsCertainAndFailureDoesNotStopNextJob() async {
        let stub = ScriptedFileOperator()
        let queue = FileOperationQueue(fileSystem: stub)
        queue.enqueue(operation(target: "slow"))
        let cancelledID = queue.enqueue(operation(target: "cancelled"))
        queue.enqueue(operation(target: "fail"))
        queue.enqueue(operation(target: "after-failure"))
        queue.cancel(cancelledID)
        await queue.waitUntilIdle()

        #expect(queue.jobs.first { $0.id == cancelledID }?.status == .cancelled)
        #expect(queue.jobs.map(\.status) == [.succeeded, .cancelled, .failed, .succeeded])
        #expect(await stub.completed() == ["slow", "after-failure"])
    }

    @Test func runningCancellationIsBestEffortAndReachesCancelledState() async {
        let stub = ScriptedFileOperator()
        let queue = FileOperationQueue(fileSystem: stub)
        let id = queue.enqueue(operation(target: "slow"))
        while queue.jobs.first?.status == .queued { await Task.yield() }
        queue.cancel(id)
        await queue.waitUntilIdle()

        #expect(queue.jobs.first?.status == .cancelled)
        #expect(await stub.completed().isEmpty)
    }
}

@MainActor
struct PaneSetStoreTests {
    @Test func savesAppliesDeletesAndIsolatesCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paneSets = PaneSetStore(directoryURL: directory)
        var savedState = WorkspaceState.initial(homeURL: URL(fileURLWithPath: "/tmp/saved"))
        let second = PaneState(currentURL: URL(fileURLWithPath: "/tmp/second"))
        savedState.panes.append(second)
        savedState.slots[.topRight] = second.id
        savedState.layout = .vertical
        let saved = try paneSets.save(name: "Two panes", workspace: savedState)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("broken.json"))

        paneSets.reload()
        #expect(paneSets.sets.count == 1)
        #expect(paneSets.loadErrors.count == 1)

        let store = WorkspaceStore(
            persistence: MemoryWorkspacePersistence(storage: .init()),
            paneSets: paneSets
        )
        store.applyPaneSet(saved.id)
        #expect(store.state.panes.count == 2)
        #expect(store.state.layout == .vertical)

        store.deletePaneSet(saved.id)
        #expect(paneSets.sets.isEmpty)
    }
}
