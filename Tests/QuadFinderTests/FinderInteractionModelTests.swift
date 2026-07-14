import AppKit
import Foundation
import Testing
@testable import QuadFinder

@Suite("Finder interaction models")
struct FinderInteractionModelTests {
    @Test @MainActor func sidebarUsesCompactFinderDensity() {
        #expect(PersistentFinderSidebarView.compactRowHeight == 24)
        #expect(SidebarMetrics.iconSize == 16)
        #expect(SidebarMetrics.fontSize == 13)
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func contextActionsHaveFinderLikeEnablement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let model = FinderContextActionModel(context: FinderContext(
            selectedURLs: [folder], clickedURL: folder, currentDirectory: root,
            otherPaneCount: 1, clipboardContainsFiles: true
        ))

        #expect(model.isEnabled(.open))
        #expect(model.isEnabled(.quickLook))
        #expect(model.isEnabled(.openInNewTab))
        #expect(model.isEnabled(.openInOtherPane))
        #expect(model.isEnabled(.rename))
        #expect(model.isEnabled(.paste))
        #expect(!model.isEnabled(.showPackageContents))
    }

    @Test func emptyContextOnlyAllowsNewFolderAndAvailablePaste() {
        let root = URL(fileURLWithPath: "/tmp")
        let model = FinderContextActionModel(context: FinderContext(
            selectedURLs: [], clickedURL: nil, currentDirectory: root,
            otherPaneCount: 0, clipboardContainsFiles: true
        ))
        #expect(model.isEnabled(.newFolder))
        #expect(model.isEnabled(.paste))
        #expect(!model.isEnabled(.open))
        #expect(!model.isEnabled(.trash))
        #expect(!model.isEnabled(.rename))
    }

    @Test func securityScopeContainmentRejectsSiblingAndPrefixCollision() {
        let access = SecurityScopeAccess()
        let root = URL(fileURLWithPath: "/tmp/allowed")
        #expect(access.contains(scopeURL: root, requestedURL: root.appendingPathComponent("child")))
        #expect(access.contains(scopeURL: root, requestedURL: root))
        #expect(!access.contains(scopeURL: root, requestedURL: URL(fileURLWithPath: "/tmp/allowed-other")))
        #expect(!access.contains(scopeURL: root, requestedURL: URL(fileURLWithPath: "/tmp/sibling")))
    }

    @Test func sandboxDetectionUsesSignedEntitlementValueOnly() {
        #expect(!AppSecurityEnvironment.from(entitlements: [:]).isSandboxed)
        #expect(!AppSecurityEnvironment.from(entitlements: ["com.apple.security.app-sandbox": false]).isSandboxed)
        #expect(AppSecurityEnvironment.from(entitlements: ["com.apple.security.app-sandbox": true]).isSandboxed)
    }

    @Test func nonSandboxAccessDoesNotRejectAnInvalidOrUnrelatedBookmark() async throws {
        let environment = AppSecurityEnvironment(isSandboxed: false)
        let requested = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        var session = SecurityScopeSession(environment: environment)
        try session.add(bookmark: Data("not-a-bookmark".utf8), requestedURLs: [requested])
        let result = try await SecurityScopeAccess(environment: environment).withAccess(
            to: requested, bookmark: Data("not-a-bookmark".utf8)
        ) { $0.standardizedFileURL }
        #expect(result == requested.standardizedFileURL)
    }

    @Test func sandboxBookmarkFailureDoesNotMaskTheRealFileOperationResult() async throws {
        let environment = AppSecurityEnvironment(isSandboxed: true)
        let requested = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        let result = try await SecurityScopeAccess(environment: environment).withAccess(
            to: requested, bookmark: Data("not-a-bookmark".utf8)
        ) { _ in "operation-ran" }
        #expect(result == "operation-ran")
    }

    @Test @MainActor func getInfoInNonSandboxRetriesRealURLDespiteInvalidStoredBookmark() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = GetInfoModel()
        model.load(urls: [root], bookmark: Data("stale-security-scope".utf8))
        await model.waitForLoad()
        #expect(model.errorMessage == nil)
        #expect(model.items.map(\.url) == [root])
    }

    @Test func symbolicLinkInNonSandboxIgnoresInvalidSourceAndTargetBookmarks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: false)
        let source = sourceDirectory.appendingPathComponent("item")
        try Data("x".utf8).write(to: source)
        let created = try SymbolicLinkService().createLinks(.init(
            sourceURLs: [source], targetDirectoryURL: targetDirectory,
            sourceAccessBookmark: Data("wrong-source".utf8),
            targetAccessBookmark: Data("wrong-target".utf8)
        ))
        #expect(created.count == 1)
        #expect((try? created[0].resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
    }

    @Test func createFolderChoosesUnusedNameWithoutOverwrite() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("名称未設定フォルダ"), withIntermediateDirectories: false)
        let created = try FinderActionService().createFolder(in: root)
        #expect(created.lastPathComponent == "名称未設定フォルダ 2")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("名称未設定フォルダ").path))
    }

    @Test @MainActor func trashRunsImmediatelyWithoutConfirmation() throws {
        let store = WorkspaceStore(persistence: MemoryWorkspacePersistence(storage: .init()))
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("trash-me")
        try Data().write(to: url)
        store.prepareTrash([url], origin: .contextMenu)
        #expect(store.pendingTrash == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test @MainActor func directoryEventsDebounceAndExposeLatestToken() async throws {
        final class Capture: @unchecked Sendable { var values: [(URL, UUID)] = [] }
        let capture = Capture()
        let monitor = DirectoryMonitoringCenter(debounceDuration: .milliseconds(120)) { url, token in
            capture.values.append((url, token))
        }
        let url = URL(fileURLWithPath: "/tmp/watched")
        monitor.receiveEvent(for: url)
        try await Task.sleep(for: .milliseconds(30))
        monitor.receiveEvent(for: url)
        let deadline = ContinuousClock.now + .seconds(1)
        while capture.values.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(capture.values.count == 1)
        #expect(capture.values.first?.0 == url.standardizedFileURL)
    }

    @Test @MainActor func removedDirectoryCancelsPendingDebouncedNotification() async throws {
        final class Capture: @unchecked Sendable { var values: [URL] = [] }
        let capture = Capture()
        let url = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let monitor = DirectoryMonitoringCenter(debounceDuration: .milliseconds(100)) { url, _ in
            capture.values.append(url)
        }
        monitor.update(urls: [url])
        monitor.receiveEvent(for: url)
        monitor.update(urls: [])
        try await Task.sleep(for: .milliseconds(150))
        #expect(capture.values.isEmpty)
        monitor.stop()
    }

    @Test @MainActor func externalDirectoryChangesReloadVisibleListing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PaneBrowserModel(paneID: UUID(),
                                     fileSystem: FileSystemService(listingCache: DirectoryListingCache()))
        model.load(url: directory, showsHiddenFiles: false, bookmark: nil)
        let initialDeadline = ContinuousClock.now + .seconds(2)
        while model.isLoading, ContinuousClock.now < initialDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.items.isEmpty)

        let monitor = DirectoryMonitoringCenter(debounceDuration: .milliseconds(40)) { url, _ in
            model.reloadAfterDirectoryChange(url: url, showsHiddenFiles: false, bookmark: nil)
        }
        monitor.update(urls: [directory])
        let added = directory.appendingPathComponent("external.txt")
        try Data("first".utf8).write(to: added)
        let createDeadline = ContinuousClock.now + .seconds(3)
        while !model.items.contains(where: { $0.name == added.lastPathComponent }), ContinuousClock.now < createDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(model.items.contains(where: { $0.name == added.lastPathComponent }))

        try Data(repeating: 0x41, count: 4096).write(to: added)
        let writeDeadline = ContinuousClock.now + .seconds(3)
        while model.items.first(where: { $0.name == added.lastPathComponent })?.size != 4096,
              ContinuousClock.now < writeDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(model.items.first(where: { $0.name == added.lastPathComponent })?.size == 4096)

        try FileManager.default.removeItem(at: added)
        let deleteDeadline = ContinuousClock.now + .seconds(3)
        while model.items.contains(where: { $0.name == added.lastPathComponent }), ContinuousClock.now < deleteDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!model.items.contains(where: { $0.name == added.lastPathComponent }))
        monitor.stop()
        model.cancel()
    }

    @Test @MainActor func fseventsRouteOnlyToTheAffectedDisplayedDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = root.appendingPathComponent("left", isDirectory: true)
        let right = root.appendingPathComponent("right", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        let affected = DirectoryMonitoringCenter.affectedRoots(
            observed: [left, right], eventPaths: [left.appendingPathComponent("changed.txt")]
        )

        #expect(affected == [FileURLIdentity.canonical(left)])
    }

    @Test @MainActor func continuousEventsDoNotStarveTheFinalDirectorySnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PaneBrowserModel(paneID: UUID(),
            fileSystem: FileSystemService(listingCache: DirectoryListingCache()))
        model.load(url: directory, showsHiddenFiles: false, bookmark: nil)
        while model.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        let added = directory.appendingPathComponent("during-burst.txt")
        try Data("visible".utf8).write(to: added)

        let burst = Task { @MainActor in
            for _ in 0..<60 {
                model.reloadAfterDirectoryChange(url: directory, showsHiddenFiles: false, bookmark: nil)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        try await Task.sleep(for: .milliseconds(350))
        #expect(model.items.contains(where: { $0.name == added.lastPathComponent }))
        await burst.value
        let deadline = ContinuousClock.now + .seconds(2)
        while model.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isLoading)
        #expect(model.items.contains(where: { $0.name == added.lastPathComponent }))
        model.cancel()
    }

    @Test @MainActor func completedMoveRefreshesBothSourceAndTargetPaneSnapshots() async throws {
        final class Capture: @unchecked Sendable { var urls: [URL] = [] }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let sourceURL = sourceDirectory.appendingPathComponent("move-me.txt")
        try Data("move".utf8).write(to: sourceURL)
        let sourceModel = PaneBrowserModel(paneID: UUID(),
            fileSystem: FileSystemService(listingCache: DirectoryListingCache()))
        let targetModel = PaneBrowserModel(paneID: UUID(),
            fileSystem: FileSystemService(listingCache: DirectoryListingCache()))
        sourceModel.load(url: sourceDirectory, showsHiddenFiles: false, bookmark: nil)
        targetModel.load(url: targetDirectory, showsHiddenFiles: false, bookmark: nil)
        while sourceModel.isLoading || targetModel.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sourceModel.items.contains(where: { $0.name == sourceURL.lastPathComponent }))
        #expect(targetModel.items.isEmpty)

        let capture = Capture()
        let token = NotificationCenter.default.addObserver(forName: .quadFinderDirectoryDidChange,
                                                            object: nil, queue: .main) { note in
            if let url = note.object as? URL { capture.urls.append(url) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let queue = FileOperationQueue(fileSystem: FileSystemService(listingCache: DirectoryListingCache()))
        queue.enqueue(PendingFileOperation(kind: .move, sourcePaneID: sourceModel.paneID,
            targetPaneID: targetModel.paneID, sourceURLs: [sourceURL], targetDirectoryURL: targetDirectory))
        await queue.waitUntilIdle()
        #expect(queue.jobs.first?.status == .succeeded)
        #expect(capture.urls.contains(where: { FileURLIdentity.isSame($0, sourceDirectory) }))
        #expect(capture.urls.contains(where: { FileURLIdentity.isSame($0, targetDirectory) }))

        for changed in capture.urls {
            sourceModel.reloadAfterDirectoryChange(url: changed, showsHiddenFiles: false, bookmark: nil)
            targetModel.reloadAfterDirectoryChange(url: changed, showsHiddenFiles: false, bookmark: nil)
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while (sourceModel.items.contains(where: { $0.name == sourceURL.lastPathComponent }) ||
               !targetModel.items.contains(where: { $0.name == sourceURL.lastPathComponent })) &&
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!sourceModel.items.contains(where: { $0.name == sourceURL.lastPathComponent }))
        #expect(targetModel.items.contains(where: { $0.name == sourceURL.lastPathComponent }))
        #expect(!sourceModel.isLoading)
        #expect(!targetModel.isLoading)
        sourceModel.cancel(); targetModel.cancel()
    }

    @Test @MainActor func quickLookSelectionLifecycleIsReloadable() {
        let presenter = QuickLookPresenter.shared
        let first = URL(fileURLWithPath: "/tmp/first")
        let second = URL(fileURLWithPath: "/tmp/second")
        presenter.beginSession([first])
        let revision = presenter.selectionRevision
        presenter.replaceSelection([second])
        #expect(presenter.isSessionActive)
        #expect(presenter.previewedURLs == [second])
        #expect(presenter.selectionRevision == revision + 1)
        presenter.close()
        #expect(!presenter.isSessionActive)
        #expect(presenter.previewedURLs.isEmpty)
    }
}

private final class MemorySidebarPreferences: SidebarPreferences, @unchecked Sendable {
    var storage: [String: Data] = [:]
    var writeCount = 0
    func sidebarData(forKey key: String) -> Data? { storage[key] }
    func setSidebarData(_ data: Data?, forKey key: String) { storage[key] = data; writeCount += 1 }
}

@Suite("Sidebar drop routing")
struct SidebarDropResolverTests {
    private let folder = URL(fileURLWithPath: "/tmp/folder", isDirectory: true)
    private let file = URL(fileURLWithPath: "/tmp/file.txt")
    private let target = URL(fileURLWithPath: "/Volumes/USB/target", isDirectory: true)

    @Test func destinationRowsAlwaysRouteToFilesystemOperations() {
        #expect(SidebarDropResolver.resolve(zone: .directory(target), urls: [file],
                                            isDirectory: { _ in false }) == .transfer(target: target))
        #expect(SidebarDropResolver.resolve(zone: .directory(target), urls: [folder],
                                            isDirectory: { _ in true }) == .transfer(target: target))
        #expect(SidebarDropResolver.resolve(zone: .trash, urls: [file]) == .trash)
    }

    @Test func onlyFolderURLsCanBeAddedAtFavoritesInsertionGaps() {
        #expect(SidebarDropResolver.resolve(zone: .favoritesInsertion(2), urls: [folder],
                                            isDirectory: { $0 == folder }) ==
                .addFavorites(urls: [folder], index: 2))
        #expect(SidebarDropResolver.resolve(zone: .favoritesInsertion(2), urls: [file],
                                            isDirectory: { _ in false }) == .reject)
        #expect(SidebarDropResolver.resolve(zone: .unavailable, urls: [folder],
                                            isDirectory: { _ in true }) == .reject)
    }

    @Test func privateFavoritePayloadReordersOnlyInInsertionZone() {
        let id = UUID()
        #expect(SidebarDropResolver.resolve(zone: .favoritesInsertion(3), urls: [],
                                            favoriteID: id) == .reorderFavorite(id: id, index: 3))
        #expect(SidebarDropResolver.resolve(zone: .directory(target), urls: [],
                                            favoriteID: id) == .reject)
    }

    @Test func favoriteRowUsesItsWholeUpperAndLowerHalvesForReordering() {
        #expect(SidebarFavoriteDropPlacement.insertionIndex(
            row: 3, pointerY: 13, rowHeight: 14
        ) == 3)
        #expect(SidebarFavoriteDropPlacement.insertionIndex(
            row: 3, pointerY: 1, rowHeight: 14
        ) == 4)
        #expect(SidebarFavoriteDropPlacement.insertionIndex(
            row: 0, pointerY: 7, rowHeight: 14
        ) == 0)
    }

    @Test func externalFolderDropHasStableInsertionEdgesAndRowCenter() {
        #expect(SidebarFavoriteDropPlacement.externalInsertionIndex(
            row: 2, pointerY: 17, rowHeight: 18
        ) == 2)
        #expect(SidebarFavoriteDropPlacement.externalInsertionIndex(
            row: 2, pointerY: 1, rowHeight: 18
        ) == 3)
        #expect(SidebarFavoriteDropPlacement.externalInsertionIndex(
            row: 2, pointerY: 9, rowHeight: 18
        ) == nil)
    }

    @Test func nativeFavoritePasteboardRoundTripsWithoutFileURL() throws {
        let id = UUID()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("FavoriteTest.\(UUID())"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(try JSONEncoder().encode(SidebarFavoriteDragPayload(id: id)),
                     forType: SidebarDraggingPasteboard.favoriteType)
        pasteboard.writeObjects([item])
        let content = SidebarDraggingPasteboard.contents(from: pasteboard)
        #expect(content.favoriteID == id)
        #expect(content.urls.isEmpty)
        #expect(item.availableType(from: [.fileURL]) == nil)
    }

    @Test func destinationOperationUsesFinderModifierAndVolumeMatrix() {
        #expect(FinderDragOperationPolicy.operation(modifiers: [], sameVolume: true) == .move)
        #expect(FinderDragOperationPolicy.operation(modifiers: [.option], sameVolume: true) == .copy)
        #expect(FinderDragOperationPolicy.operation(modifiers: [.command, .option], sameVolume: true) == .link)
        #expect(FinderDragOperationPolicy.operation(modifiers: [], sameVolume: false) == .copy)
        #expect(FinderDragOperationPolicy.operation(modifiers: [.command], sameVolume: false) == .move)
        #expect(FinderDragOperationPolicy.operation(modifiers: [.command, .option], sameVolume: false) == .link)
    }
}

@Suite("Native Favorites table integration")
struct NativeSidebarFavoritesIntegrationTests {
    @Test @MainActor func clickingSelectedFavoriteNavigatesNewActivePaneWithoutSelectionChange() {
        let workspace = WorkspaceStore(persistence: MemoryWorkspacePersistence(storage: .init()))
        let paneA = workspace.state.activePaneID
        workspace.addPane()
        let paneB = workspace.state.activePaneID
        let store = SidebarStore(preferences: MemorySidebarPreferences(),
                                 home: URL(fileURLWithPath: "/tmp/home"))
        defer { store.stopObservingMounts() }
        let view = NativeSidebarFavoritesView(
            store: store,
            navigate: {
                workspace.navigate(paneID: workspace.state.activePaneID, to: $0.url)
            },
            perform: { _, _, _, _ in }
        )
        let coordinator = NativeSidebarFavoritesView.Coordinator(parent: view)
        let table = SidebarFavoritesTableView()
        table.dataSource = coordinator
        table.delegate = coordinator
        table.addTableColumn(NSTableColumn(identifier: .init("favorite")))
        coordinator.table = table
        table.reselectedRow = { coordinator.navigate(toRow: $0) }
        table.reloadData()

        workspace.activate(paneA)
        table.selectRowIndexes([0], byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        #expect(workspace.pane(id: paneA)?.currentURL == store.favorites[0].url)

        let elsewhere = URL(fileURLWithPath: "/tmp/elsewhere")
        workspace.navigate(paneID: paneB, to: elsewhere)
        workspace.activate(paneB)
        table.completePrimaryClick(row: 0, wasSelected: true, clickCount: 1, dragBegan: false)

        #expect(workspace.pane(id: paneB)?.currentURL == store.favorites[0].url)
        #expect(workspace.pane(id: paneA)?.currentURL == store.favorites[0].url)
        #expect(table.selectedRow == 0)
    }

    @Test @MainActor func selectedFavoriteDragDoesNotTriggerRepeatedClickNavigation() {
        let table = SidebarFavoritesTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("favorite")))
        table.selectRowIndexes([0], byExtendingSelection: false)
        var repeatedRows: [Int] = []
        table.reselectedRow = { repeatedRows.append($0) }
        table.completePrimaryClick(row: 0, wasSelected: true, clickCount: 1, dragBegan: true)
        #expect(repeatedRows.isEmpty)
    }

    @Test @MainActor func nativeContainerHeightIsDeterministicForEveryFavoriteCount() {
        let table = SidebarFavoritesTableView()
        table.rowHeight = NativeSidebarFavoritesView.rowHeight
        table.intercellSpacing = .zero
        let container = SidebarFavoritesContainerView(tableView: table)

        for count in [0, 1, 5, 20] {
            container.rowCount = count
            #expect(container.contentHeight == CGFloat(count) * SidebarMetrics.rowHeight)
            #expect(container.intrinsicContentSize.height == CGFloat(count) * SidebarMetrics.rowHeight)
        }
    }

    @Test @MainActor func nativeContainerPinsRowsTopLeadingAndTracksWidth() throws {
        let store = SidebarStore(preferences: MemorySidebarPreferences(),
                                 home: URL(fileURLWithPath: "/tmp/home"))
        defer { store.stopObservingMounts() }
        let view = NativeSidebarFavoritesView(store: store, navigate: { _ in }, perform: { _, _, _, _ in })
        let coordinator = NativeSidebarFavoritesView.Coordinator(parent: view)
        let table = SidebarFavoritesTableView()
        table.rowHeight = SidebarMetrics.rowHeight
        table.intercellSpacing = .zero
        table.headerView = nil
        table.delegate = coordinator
        table.dataSource = coordinator
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("favorite"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        coordinator.table = table
        let container = SidebarFavoritesContainerView(tableView: table)
        container.rowCount = store.favorites.count
        table.reloadData()

        for width in [90.0, 180.0, 360.0] {
            container.frame = NSRect(x: 0, y: 0, width: width, height: container.contentHeight)
            container.layoutSubtreeIfNeeded()
            #expect(table.frame.minX == 0)
            #expect(abs(column.width - width) < 0.01)
            let firstRowInContainer = container.convert(table.rect(ofRow: 0), from: table)
            #expect(abs(firstRowInContainer.minY) < 0.01)
            #expect(firstRowInContainer.minX == 0)
            #expect(firstRowInContainer.width >= width)
        }

        let cell = try #require(coordinator.tableView(table, viewFor: column, row: 0) as? SidebarFavoriteCellView)
        cell.frame = NSRect(x: 0, y: 0, width: 180, height: SidebarMetrics.rowHeight)
        cell.layoutSubtreeIfNeeded()
        let image = cell.iconView
        let text = cell.titleField
        #expect(image.frame.minX == SidebarMetrics.horizontalInset)
        #expect(image.frame.size == NSSize(width: 16, height: 16))
        #expect(abs(image.frame.midY - cell.bounds.midY) < 0.01)
        #expect(text.frame.minX == SidebarMetrics.horizontalInset + SidebarMetrics.iconSize + SidebarMetrics.itemSpacing)
        #expect(abs(text.frame.midY - cell.bounds.midY) < 0.01)
        #expect(text.frame.maxX <= cell.bounds.maxX - SidebarMetrics.trailingInset)
    }

    @Test @MainActor func favoriteIconsPreserveColorAndRemainVisibleAcrossAppearances() throws {
        let home = SidebarFavorite(name: "ホーム", url: URL(fileURLWithPath: "/tmp/home"), isDefault: true)
        let custom = SidebarFavorite(name: "制作", url: URL(fileURLWithPath: "/tmp/custom"), isDefault: false)

        #expect(SidebarFavoriteIcon.treatment(for: home) == .systemSymbol)
        #expect(SidebarFavoriteIcon.symbolName(for: home) == "house.fill")
        #expect(SidebarFavoriteIcon.image(for: home).isTemplate)
        #expect(SidebarFavoriteIcon.treatment(for: custom) == .workspaceIcon)
        #expect(SidebarFavoriteIcon.symbolName(for: custom) == nil)
        #expect(!SidebarFavoriteIcon.image(for: custom).isTemplate)

        let cell = SidebarFavoriteCellView(frame: NSRect(x: 0, y: 0, width: 180,
                                                          height: SidebarMetrics.rowHeight))
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            cell.appearance = NSAppearance(named: appearanceName)
            cell.configure(icon: SidebarFavoriteIcon.image(for: home), treatment: .systemSymbol,
                           selected: false, accessibilityLabel: home.name)
            // System symbols are palette-coloured and made non-template before
            // being placed in the source-list cell.  Keeping contentTintColor
            // nil is intentional: source-list vibrancy can otherwise override
            // the tint and draw the reusable cell as a black silhouette.
            #expect(cell.iconView.contentTintColor == nil)
            #expect(cell.iconView.image?.isTemplate == false)
            let unselectedImage = cell.iconView.image
            cell.setSelected(true)
            #expect(cell.iconView.contentTintColor == nil)
            #expect(cell.iconView.image?.isTemplate == false)
            #expect(cell.iconView.image !== unselectedImage)
            cell.configure(icon: SidebarFavoriteIcon.image(for: custom), treatment: .workspaceIcon,
                           selected: false, accessibilityLabel: custom.name)
            #expect(cell.iconView.contentTintColor == nil)
            #expect(cell.iconView.image?.isTemplate == false)
        }
    }

    @Test @MainActor func nativeTablePublishesPrivateReorderPayloadForEveryRow() throws {
        let store = SidebarStore(preferences: MemorySidebarPreferences(),
                                 home: URL(fileURLWithPath: "/tmp/home"))
        defer { store.stopObservingMounts() }
        let view = NativeSidebarFavoritesView(
            store: store,
            navigate: { _ in },
            perform: { _, _, _, _ in }
        )
        let coordinator = NativeSidebarFavoritesView.Coordinator(parent: view)
        let table = SidebarFavoritesTableView()
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator

        #expect(coordinator.numberOfRows(in: table) == store.favorites.count)
        let writer = try #require(coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem)
        let data = try #require(writer.data(forType: SidebarDraggingPasteboard.favoriteType))
        let payload = try JSONDecoder().decode(SidebarFavoriteDragPayload.self, from: data)
        #expect(payload.id == store.favorites[0].id)
        #expect(writer.availableType(from: [.fileURL]) == nil)
    }

    @Test @MainActor func nativeTableReloadKeepsFavoriteIdentitySelected() {
        let store = SidebarStore(preferences: MemorySidebarPreferences(),
                                 home: URL(fileURLWithPath: "/tmp/home"))
        defer { store.stopObservingMounts() }
        let view = NativeSidebarFavoritesView(store: store, navigate: { _ in }, perform: { _, _, _, _ in })
        let coordinator = NativeSidebarFavoritesView.Coordinator(parent: view)
        let table = SidebarFavoritesTableView()
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("favorite")))
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let selectedID = store.favorites[1].id

        store.moveFavorite(id: selectedID, toOffset: 4)
        coordinator.reloadPreservingSelection()
        #expect(table.selectedRow == store.favorites.firstIndex(where: { $0.id == selectedID }))
    }

    @Test @MainActor func twentyRapidEarlierAndLaterReordersStayUniqueAndPersist() {
        let preferences = MemorySidebarPreferences()
        let home = URL(fileURLWithPath: "/tmp/home")
        var store: SidebarStore? = SidebarStore(preferences: preferences, home: home)
        let movedID = store!.favorites[1].id
        let count = store!.favorites.count
        for cycle in 0..<20 {
            store!.moveFavorite(id: movedID, toOffset: cycle.isMultiple(of: 2) ? count : 0)
            #expect(store!.favorites.count == count)
            #expect(Set(store!.favorites.map(\.id)).count == count)
        }
        let expectedOrder = store!.favorites.map(\.id)
        store!.stopObservingMounts()
        store = SidebarStore(preferences: preferences, home: home)
        #expect(store!.favorites.map(\.id) == expectedOrder)
        store!.stopObservingMounts()
    }

    @Test func nativeDropPlansNeverConfuseRowTransferAndInsertion() {
        let favoriteID = UUID()
        let folder = URL(fileURLWithPath: "/tmp/folder", isDirectory: true)
        let file = URL(fileURLWithPath: "/tmp/file")
        let target = URL(fileURLWithPath: "/tmp/target", isDirectory: true)
        #expect(SidebarDropResolver.resolve(zone: .favoritesInsertion(2), urls: [],
                                            favoriteID: favoriteID) == .reorderFavorite(id: favoriteID, index: 2))
        #expect(SidebarDropResolver.resolve(zone: .directory(target), urls: [folder],
                                            isDirectory: { _ in true }) == .transfer(target: target))
        #expect(SidebarDropResolver.resolve(zone: .favoritesInsertion(2), urls: [folder],
                                            isDirectory: { _ in true }) == .addFavorites(urls: [folder], index: 2))
        #expect(SidebarDropResolver.resolve(zone: .favoritesInsertion(2), urls: [file],
                                            isDirectory: { _ in false }) == .reject)
    }
}

@Suite("Sidebar persistence")
struct SidebarStoreTests {
    private actor EjectRecorder {
        var urls: [URL] = []
        func record(_ url: URL) { urls.append(url) }
    }
    private struct LegacySidebarState: Codable {
        let favorites: [SidebarFavorite]
        let isVisible: Bool
        let width: Double
    }

    @Test @MainActor func legacyDefaultWidthMigratesOnceButCustomWidthIsPreserved() throws {
        let key = "QuadFinder.Sidebar.v1"
        let home = URL(fileURLWithPath: "/tmp/home")
        for (legacyWidth, expected) in [(190.0, 100.0), (175.0, 175.0)] {
            let preferences = MemorySidebarPreferences()
            preferences.storage[key] = try JSONEncoder().encode(LegacySidebarState(
                favorites: SidebarStore.defaultFavorites(home: home), isVisible: true, width: legacyWidth
            ))
            var store: SidebarStore? = SidebarStore(preferences: preferences, home: home)
            #expect(store?.width == expected)
            store?.isVisible = false
            store = SidebarStore(preferences: preferences, home: home)
            #expect(store?.width == expected)
            store?.stopObservingMounts()
        }
    }

    @Test @MainActor func freshDefaultAndTransientHiddenWidth() {
        let preferences = MemorySidebarPreferences()
        let store = SidebarStore(preferences: preferences, home: URL(fileURLWithPath: "/tmp/home"))
        #expect(store.width == 100)
        store.setWidth(220)
        store.isVisible = false
        #expect(store.width == 220)
        store.isVisible = true
        #expect(store.width == 220)
        store.stopObservingMounts()
    }
    @Test @MainActor func defaultsCustomBookmarkOrderingRemovalAndAppearancePersist() {
        let preferences = MemorySidebarPreferences()
        let home = URL(fileURLWithPath: "/tmp/home")
        var store: SidebarStore? = SidebarStore(preferences: preferences, home: home)
        #expect(store?.favorites.map(\.name) == ["ホーム", "デスクトップ", "書類", "ダウンロード", "ゴミ箱"])
        let custom = URL(fileURLWithPath: "/tmp/custom")
        let bookmark = Data([1, 2, 3])
        store?.addCustom(name: "Custom", url: custom, bookmark: bookmark)
        let customID = store!.favorites.last!.id
        store?.move(fromOffsets: IndexSet(integer: 5), toOffset: 0)
        store?.isVisible = false
        store?.setWidth(999)
        store = SidebarStore(preferences: preferences, home: home)
        #expect(store?.favorites.first?.bookmark == bookmark)
        #expect(store?.isVisible == false)
        #expect(store?.width == 360)
        store?.remove(id: customID)
        #expect(!store!.favorites.contains { $0.id == customID })
        let defaultID = store!.favorites.first!.id
        store?.remove(id: defaultID)
        #expect(store!.favorites.contains { $0.id == defaultID })
        store?.stopObservingMounts()
    }

    @Test @MainActor func internalFavoriteReorderDoesNotDuplicateRows() {
        let store = SidebarStore(preferences: MemorySidebarPreferences(), home: URL(fileURLWithPath: "/tmp/home"))
        defer { store.stopObservingMounts() }
        let originalCount = store.favorites.count
        let id = store.favorites[1].id
        store.moveFavorite(id: id, toOffset: 4)
        #expect(store.favorites.count == originalCount)
        #expect(store.favorites[3].id == id)
        #expect(Set(store.favorites.map(\.id)).count == originalCount)
    }

    @Test @MainActor func defaultFavoriteReorderPersistsAcrossReload() {
        let preferences = MemorySidebarPreferences()
        let home = URL(fileURLWithPath: "/tmp/home")
        var store: SidebarStore? = SidebarStore(preferences: preferences, home: home)
        let id = store!.favorites[0].id
        store!.moveFavorite(id: id, toOffset: 4)
        #expect(store!.favorites[3].id == id)
        store!.stopObservingMounts()
        store = SidebarStore(preferences: preferences, home: home)
        #expect(store!.favorites[3].id == id)
        #expect(store!.favorites[3].isDefault)
        store!.stopObservingMounts()
    }

    @Test @MainActor func widthDragUsesFixedOriginClampsAndPersistsOnlyOnce() {
        let preferences = MemorySidebarPreferences()
        let store = SidebarStore(preferences: preferences, home: URL(fileURLWithPath: "/tmp/home"))
        defer { store.stopObservingMounts() }
        let baselineWrites = preferences.writeCount
        #expect(store.beginWidthDrag() == 100)
        store.updateWidthDrag(translation: 20)
        #expect(store.width == 120)
        store.updateWidthDrag(translation: 30)
        #expect(store.width == 130) // fixed origin, not cumulative 150
        store.updateWidthDrag(translation: 1_000)
        #expect(store.width == SidebarStore.maximumWidth)
        store.updateWidthDrag(translation: -1_000)
        #expect(store.width == SidebarStore.minimumWidth)
        #expect(preferences.writeCount == baselineWrites)
        store.endWidthDrag()
        #expect(preferences.writeCount == baselineWrites + 1)
    }

    @Test @MainActor func widthDragUsesStableGlobalCoordinateWhenHandleMoves() {
        let preferences = MemorySidebarPreferences()
        let store = SidebarStore(preferences: preferences, home: URL(fileURLWithPath: "/tmp/home"))
        defer { store.stopObservingMounts() }
        let baselineWrites = preferences.writeCount
        // The handle's local origin may move with width, but absolute pointer X is monotonic.
        store.updateWidthDrag(screenX: 505, startScreenX: 500)
        #expect(store.width == 105)
        store.updateWidthDrag(screenX: 510, startScreenX: 505)
        #expect(store.width == 110)
        store.updateWidthDrag(screenX: 515, startScreenX: 510)
        #expect(store.width == 115)
        #expect(preferences.writeCount == baselineWrites)
        store.endWidthDrag()
        #expect(preferences.writeCount == baselineWrites + 1)
    }

    @Test @MainActor func recentFoldersAndFilesAreDeduplicatedCappedAndPersisted() {
        let preferences = MemorySidebarPreferences()
        let home = URL(fileURLWithPath: "/tmp/home")
        var store: SidebarStore? = SidebarStore(preferences: preferences, home: home)
        for index in 0..<22 {
            store?.recordRecent(URL(fileURLWithPath: "/tmp/item-\(index)"), kind: index.isMultiple(of: 2) ? .folder : .file,
                                date: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(store?.recents.count == 20)
        #expect(store?.recents.first?.url.path == "/tmp/item-21")
        store?.recordRecent(URL(fileURLWithPath: "/tmp/item-10"), kind: .file)
        #expect(store?.recents.first?.url.path == "/tmp/item-10")
        #expect(store?.recents.filter { $0.url.path == "/tmp/item-10" }.count == 1)
        store = SidebarStore(preferences: preferences, home: home)
        #expect(store?.recents.first?.url.path == "/tmp/item-10")
        store?.clearRecents()
        #expect(store?.recents.isEmpty == true)
        store?.stopObservingMounts()
    }

    @Test @MainActor func ejectUsesDeviceURLOnlyForEjectableDevices() async throws {
        let store = SidebarStore(preferences: MemorySidebarPreferences(), home: URL(fileURLWithPath: "/tmp/home"))
        defer { store.stopObservingMounts() }
        let recorder = EjectRecorder()
        let removable = SidebarLocation(section: .devices, name: "USB",
                                        url: URL(fileURLWithPath: "/Volumes/USB"),
                                        systemImage: "externaldrive", isEjectable: true)
        try await store.eject(removable) { url in await recorder.record(url) }
        #expect(await recorder.urls == [removable.url])

        let internalDisk = SidebarLocation(section: .devices, name: "Macintosh HD",
                                           url: URL(fileURLWithPath: "/"),
                                           systemImage: "internaldrive")
        await #expect(throws: CocoaError.self) {
            try await store.eject(internalDisk) { _ in Issue.record("internal volume must not eject") }
        }
    }

    @Test @MainActor func ejectFailureIsActionableAndAlwaysClearsBusyState() async {
        let store = SidebarStore(preferences: MemorySidebarPreferences(), home: URL(fileURLWithPath: "/tmp/home"))
        defer { store.stopObservingMounts() }
        let device = SidebarLocation(section: .devices, name: "USB",
                                     url: URL(fileURLWithPath: "/Volumes/USB"),
                                     systemImage: "externaldrive", isEjectable: true)
        do {
            try await store.eject(device) { _ in throw CocoaError(.fileWriteVolumeReadOnly) }
            Issue.record("eject failure must be reported")
        } catch let error as SidebarEjectError {
            #expect(error.errorDescription?.contains("USB") == true)
            #expect(error.errorDescription?.contains("使用中") == true)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(!store.ejectingDeviceIDs.contains(device.id))
    }
}
