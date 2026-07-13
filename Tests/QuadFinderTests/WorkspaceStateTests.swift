import Foundation
import Testing
@testable import QuadFinder

@MainActor
struct WorkspaceStateTests {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(persistence: MemoryWorkspacePersistence(storage: .init()))
    }

    @Test func addsAtMostFourIndependentPanes() {
        let store = makeStore()
        store.addPane()
        store.addPane()
        store.addPane()
        store.addPane()

        #expect(store.state.panes.count == 4)
        #expect(store.state.layout == .grid)
        #expect(Set(store.state.panes.map(\.id)).count == 4)
        #expect(store.state.slots.count == 4)
    }

    @Test func paneIdentityIsIndependentFromSlotWhenSwapping() {
        let store = makeStore()
        let first = store.state.activePaneID
        store.addPane()
        let second = store.state.activePaneID
        let firstURL = URL(fileURLWithPath: "/tmp/first")
        let secondURL = URL(fileURLWithPath: "/tmp/second")
        store.navigate(paneID: first, to: firstURL)
        store.navigate(paneID: second, to: secondURL)

        let firstSlot = store.state.slots.first { $0.value == first }!.key
        let secondSlot = store.state.slots.first { $0.value == second }!.key
        store.swapActive(with: first)

        #expect(store.state.slots[firstSlot] == second)
        #expect(store.state.slots[secondSlot] == first)
        #expect(store.pane(id: first)?.currentURL == firstURL)
        #expect(store.pane(id: second)?.currentURL == secondURL)
    }

    @Test func closingAndRestoringPreservesPaneStateOnce() {
        let store = makeStore()
        store.addPane()
        let id = store.state.activePaneID
        let url = URL(fileURLWithPath: "/tmp/restored")
        store.navigate(paneID: id, to: url)
        store.updatePane(id: id) { $0.selectedURLs = [url.appendingPathComponent("item")] }

        store.closeActivePane()
        #expect(store.state.panes.count == 1)
        store.restoreClosedPane()

        #expect(store.state.panes.count == 2)
        #expect(store.pane(id: id)?.currentURL == url)
        #expect(store.pane(id: id)?.selectedURLs.count == 1)
        #expect(store.recentlyClosedPane == nil)
    }

    @Test func historiesRemainIndependent() {
        let store = makeStore()
        let first = store.state.activePaneID
        store.addPane()
        let second = store.state.activePaneID
        store.navigate(paneID: first, to: URL(fileURLWithPath: "/tmp/a"))
        store.navigate(paneID: second, to: URL(fileURLWithPath: "/tmp/b"))
        store.goBack(paneID: first)

        #expect(store.pane(id: first)?.currentURL == FileManager.default.homeDirectoryForCurrentUser)
        #expect(store.pane(id: second)?.currentURL == URL(fileURLWithPath: "/tmp/b"))
        #expect(store.pane(id: second)?.backwardHistory.count == 1)
    }

    @Test func successfulEjectRelocatesEveryAffectedPaneOnly() {
        let store = makeStore()
        let first = store.state.activePaneID
        store.addPane()
        let second = store.state.activePaneID
        store.addPane()
        let unaffected = store.state.activePaneID
        let volume = URL(fileURLWithPath: "/Volumes/USB")
        let home = URL(fileURLWithPath: "/tmp/test-home")
        store.navigate(paneID: first, to: volume.appendingPathComponent("one"))
        store.navigate(paneID: second, to: volume.appendingPathComponent("two/deep"))
        store.navigate(paneID: unaffected, to: URL(fileURLWithPath: "/Volumes/USB-other/keep"))
        store.updatePane(id: first) { $0.accessBookmark = Data([1]); $0.selectedURLs = [volume] }

        store.relocatePanesAfterEject(of: volume, homeURL: home)

        #expect(store.pane(id: first)?.currentURL == home)
        #expect(store.pane(id: second)?.currentURL == home)
        #expect(store.pane(id: first)?.accessBookmark == nil)
        #expect(store.pane(id: first)?.selectedURLs.isEmpty == true)
        #expect(store.pane(id: unaffected)?.currentURL.path == "/Volumes/USB-other/keep")
    }

    @Test func ejectContainmentUsesComponentBoundaries() {
        #expect(WorkspaceStore.contains(URL(fileURLWithPath: "/Volumes/USB/folder"), in: URL(fileURLWithPath: "/Volumes/USB")))
        #expect(!WorkspaceStore.contains(URL(fileURLWithPath: "/Volumes/USB-Backup/folder"), in: URL(fileURLWithPath: "/Volumes/USB")))
    }

    @Test func ratiosAreClamped() {
        let store = makeStore()
        store.setRatios(vertical: -1, horizontal: 2)
        #expect(store.state.verticalRatio == 0.2)
        #expect(store.state.horizontalRatio == 0.8)
    }

    @Test func allPaneCountsNormalizeAndAcceptAllEightLayouts() {
        let expected: [(Int, [PaneLayout])] = [
            (1, [.single]),
            (2, [.vertical, .horizontal]),
            (3, [.leading, .trailing, .top, .bottom]),
            (4, [.grid])
        ]
        for (count, layouts) in expected {
            let store = makeStore()
            while store.state.panes.count < count { store.addPane() }
            for layout in layouts {
                store.setLayout(layout)
                #expect(store.state.layout == layout)
                #expect(store.state.orderedPaneIDs.count == count)
            }
        }
    }

    @Test func closingInactivePaneKeepsActivePane() {
        let store = makeStore()
        let inactive = store.state.activePaneID
        store.addPane()
        store.addPane()
        let active = store.state.activePaneID

        store.closePane(inactive)

        #expect(store.state.activePaneID == active)
        #expect(store.state.panes.count == 2)
    }

    @Test func directionalAndNumberActivationFollowSlots() {
        let store = makeStore()
        store.addPane()
        store.addPane()
        store.addPane()
        let ids = store.state.orderedPaneIDs

        store.activatePane(number: 1)
        store.activateDirection(horizontal: 1, vertical: 0)
        #expect(store.state.activePaneID == ids[1])
        store.activateDirection(horizontal: 0, vertical: 1)
        #expect(store.state.activePaneID == ids[3])
        store.activatePane(number: 3)
        #expect(store.state.activePaneID == ids[2])
    }

    @Test func malformedSlotsAreNormalizedWithoutLosingValidPanes() {
        var p1 = PaneState(currentURL: URL(fileURLWithPath: "/tmp/1"))
        p1.tabs = []
        p1.activeTabID = UUID()
        let p2 = PaneState(currentURL: URL(fileURLWithPath: "/tmp/2"))
        let p3 = PaneState(currentURL: URL(fileURLWithPath: "/tmp/3"))
        let malformed = WorkspaceState(
            panes: [p1, p2, p3],
            slots: [.topLeft: p1.id, .topRight: p1.id, .bottomRight: UUID()],
            activePaneID: UUID(),
            previousActivePaneID: UUID(),
            layout: .grid,
            verticalRatio: -4,
            horizontalRatio: 9,
            maximizedPaneID: UUID()
        )
        let storage = MemoryWorkspacePersistence.Storage()
        storage.state = malformed
        let store = WorkspaceStore(persistence: MemoryWorkspacePersistence(storage: storage))

        #expect(store.state.panes.count == 3)
        #expect(store.state.slots.count == 3)
        #expect(Set(store.state.slots.values).count == 3)
        #expect(store.state.layout == .leading)
        #expect(store.state.panes.contains { $0.id == store.state.activePaneID })
        #expect(store.state.maximizedPaneID == nil)
    }

    @Test func dropSourceIsExplicitAndExternalDropDoesNotBorrowActivePermission() throws {
        let store = makeStore()
        let sourceID = store.state.activePaneID
        let bookmark = Data("bookmark-marker".utf8)
        store.updatePane(id: sourceID) { $0.accessBookmark = bookmark }
        store.addPane()
        let targetID = store.state.activePaneID
        let draggedURL = URL(fileURLWithPath: "/tmp/item")

        store.prepareDrop(sourcePaneID: sourceID, targetPaneID: targetID, urls: [draggedURL])
        let internalDrop = try #require(store.operationQueue.jobs.last?.operation)
        #expect(internalDrop.sourcePaneID == sourceID)
        #expect(internalDrop.sourceAccessBookmark == bookmark)

        store.prepareDrop(sourcePaneID: nil, targetPaneID: targetID, urls: [draggedURL])
        let externalDrop = try #require(store.operationQueue.jobs.last?.operation)
        #expect(externalDrop.sourcePaneID == nil)
        #expect(externalDrop.sourceAccessBookmark == nil)
    }

    @Test func sidebarFolderDropQueuesAgainstRowURLWithoutChangingPaneDestination() throws {
        let store = makeStore()
        let sourceID = store.state.activePaneID
        let sourceBookmark = Data("source-bookmark".utf8)
        store.updatePane(id: sourceID) { $0.accessBookmark = sourceBookmark }
        let paneDirectory = store.pane(id: sourceID)!.currentURL
        let sidebarDirectory = URL(fileURLWithPath: "/tmp/sidebar-destination", isDirectory: true)
        let targetBookmark = Data("target-bookmark".utf8)
        let draggedURL = URL(fileURLWithPath: "/tmp/sidebar-source.txt")

        store.prepareSidebarDrop(sourcePaneID: sourceID, targetDirectoryURL: sidebarDirectory,
                                 targetAccessBookmark: targetBookmark, urls: [draggedURL])

        let operation = try #require(store.operationQueue.jobs.last?.operation)
        #expect(operation.targetDirectoryURL == sidebarDirectory)
        #expect(operation.targetAccessBookmark == targetBookmark)
        #expect(operation.sourceAccessBookmark == sourceBookmark)
        #expect(store.pane(id: sourceID)?.currentURL == paneDirectory)
    }

    @Test func dividerRatioUsesActualContainerExtent() {
        #expect(DividerMath.updatedRatio(start: 0.5, translation: 100, containerExtent: 1000) == 0.6)
        #expect(DividerMath.updatedRatio(start: 0.5, translation: -50, containerExtent: 500) == 0.4)
    }

    @Test func persistenceRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("workspace.json")
        let persistence = FileWorkspacePersistence(fileURL: url)
        var state = WorkspaceState.initial(homeURL: URL(fileURLWithPath: "/tmp"))
        state.verticalRatio = 0.37
        try persistence.save(state)
        let loaded = try persistence.load()
        let restored = try #require(loaded)
        #expect(restored == state)
        try? FileManager.default.removeItem(at: directory)
    }
}

struct FileSystemServiceTests {
    @Test func copyUsesFrozenDestinationAndRejectsConflicts() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDir = base.appendingPathComponent("source")
        let targetDir = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let source = sourceDir.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: source)
        let operation = PendingFileOperation(kind: .copy, sourcePaneID: UUID(), targetPaneID: UUID(), sourceURLs: [source], targetDirectoryURL: targetDir)

        try await FileSystemService().perform(operation)
        #expect(FileManager.default.fileExists(atPath: targetDir.appendingPathComponent("note.txt").path))
        await #expect(throws: FileSystemError.self) { try await FileSystemService().perform(operation) }
        try? FileManager.default.removeItem(at: base)
    }

    @Test func moveSucceeds() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let sourceDir = base.appendingPathComponent("source")
        let targetDir = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let source = sourceDir.appendingPathComponent("move.txt")
        try Data("move".utf8).write(to: source)
        let operation = PendingFileOperation(kind: .move, sourcePaneID: nil, targetPaneID: UUID(), sourceURLs: [source], targetDirectoryURL: targetDir)

        try await FileSystemService().perform(operation)

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: targetDir.appendingPathComponent("move.txt").path))
    }

    @Test func conflictIsPreflightedBeforeAnySourceIsCopied() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let sourceDir = base.appendingPathComponent("source")
        let targetDir = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let first = sourceDir.appendingPathComponent("first.txt")
        let second = sourceDir.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        try Data("existing".utf8).write(to: targetDir.appendingPathComponent("second.txt"))
        let operation = PendingFileOperation(kind: .copy, sourcePaneID: nil, targetPaneID: UUID(), sourceURLs: [first, second], targetDirectoryURL: targetDir)

        var rejectedConflict = false
        do { try await FileSystemService().perform(operation) }
        catch let error as FileSystemError {
            if case .destinationConflict = error { rejectedConflict = true }
        }

        #expect(rejectedConflict)
        #expect(!FileManager.default.fileExists(atPath: targetDir.appendingPathComponent("first.txt").path))
    }

    @Test func copyingDirectoryIntoItselfDirectlyAndThroughSymlinkIsRejected() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        let inside = source.appendingPathComponent("inside")
        let link = base.appendingPathComponent("inside-link")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inside)
        for destination in [inside, link] {
            let operation = PendingFileOperation(kind: .copy, sourcePaneID: nil, targetPaneID: UUID(), sourceURLs: [source], targetDirectoryURL: destination)
            var rejectedSelfCopy = false
            do { try await FileSystemService().perform(operation) }
            catch let error as FileSystemError {
                if case .sourceInsideDestination = error { rejectedSelfCopy = true }
            }
            #expect(rejectedSelfCopy)
            #expect(!FileManager.default.fileExists(atPath: inside.appendingPathComponent("source").path))
        }
    }
}
