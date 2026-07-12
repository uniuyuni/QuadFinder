import Foundation
import Testing
@testable import QuadFinder

@Suite("Finder interaction models")
struct FinderInteractionModelTests {
    @Test @MainActor func sidebarUsesCompactFinderDensity() {
        #expect(PersistentFinderSidebarView.compactRowHeight == 14)
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
