import AppKit
import Foundation
import Testing
@testable import QuadFinder

@Suite("Drag intents and tree view")
struct DragTreeTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func trashPrioritySuppressesSymbolicLinkIntent() {
        #expect(DropIntent.resolve(modifiers: [.command, .option], isTrashTarget: true) == .trash)
        #expect(DropIntent.resolve(modifiers: [.command, .option], isTrashTarget: false) == .symbolicLink)
        #expect(DropIntent.resolve(modifiers: [.option], isTrashTarget: false) == .transfer)
    }

    @Test func symbolicLinkPreflightIsAtomicAndDestinationIsAbsolute() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let other = root.appendingPathComponent("other")
        let target = root.appendingPathComponent("target", isDirectory: true)
        try Data("a".utf8).write(to: source); try Data("b".utf8).write(to: other)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try SymbolicLinkService().createLinks(SymbolicLinkRequest(sourceURLs: [source], targetDirectoryURL: target, sourceAccessBookmark: nil, targetAccessBookmark: nil))
        let link = target.appendingPathComponent("source")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == source.standardizedFileURL.path)

        let conflict = target.appendingPathComponent("other")
        try Data().write(to: conflict)
        let third = root.appendingPathComponent("third"); try Data().write(to: third)
        #expect(throws: FinderActionError.self) {
            try SymbolicLinkService().createLinks(SymbolicLinkRequest(sourceURLs: [third, other], targetDirectoryURL: target, sourceAccessBookmark: nil, targetAccessBookmark: nil))
        }
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("third").path))
    }

    @Test func modifierResolverUsesLiveEventThenTrackedAndDoesNotInventStickyFlags() {
        #expect(DropModifierResolver.resolve(current: [.command], tracked: [.command, .option]) == [.command])
        #expect(DropModifierResolver.resolve(current: [], tracked: [.command, .option]).contains([.command, .option]))
        #expect(DropModifierResolver.resolve(current: nil, tracked: []).isEmpty)
    }

    @Test func symbolicLinkRejectsTargetInsideSourceDirectory() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("folder", isDirectory: true)
        let inside = source.appendingPathComponent("inside", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        #expect(throws: FileSystemError.self) {
            try SymbolicLinkService().createLinks(SymbolicLinkRequest(
                sourceURLs: [source], targetDirectoryURL: inside,
                sourceAccessBookmark: nil, targetAccessBookmark: nil
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: inside.appendingPathComponent("folder").path))
    }

    @Test @MainActor func treeExpandsArbitraryDepthAndSymlinkDoesNotExpand() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let fs = FileSystemService()
        let roots = try await fs.listDirectory(root, showsHiddenFiles: true, bypassCache: true)
        let folderItem = try #require(roots.first { $0.url.standardizedFileURL == folder.standardizedFileURL })
        let linkItem = try #require(roots.first { $0.url.standardizedFileURL == link.standardizedFileURL })
        #expect(linkItem.isSymbolicLink)
        let model = TreeBrowserModel(fileSystem: fs)
        model.toggle(folderItem, showsHiddenFiles: true, bookmark: nil)
        await model.waitForLoad(folderItem.url)
        let nestedItem = try #require(model.rows(rootItems: roots).first { $0.item.url.standardizedFileURL == nested.standardizedFileURL }?.item)
        model.toggle(nestedItem, showsHiddenFiles: true, bookmark: nil)
        await model.waitForLoad(nestedItem.url)
        #expect(model.expanded.contains(folderItem.url))
        #expect(model.expanded.contains(nestedItem.url))
        model.toggle(linkItem, showsHiddenFiles: true, bookmark: nil)
        #expect(!model.expanded.contains(linkItem.url))
        model.toggle(folderItem, showsHiddenFiles: true, bookmark: nil)
        #expect(!model.expanded.contains(folderItem.url))
    }

    @Test @MainActor func treeRefreshUpdatesExpandedChildDirectory() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileSystem = FileSystemService(listingCache: DirectoryListingCache())
        let roots = try await fileSystem.listDirectory(root, showsHiddenFiles: false, bypassCache: true)
        let folderItem = try #require(roots.first { FileURLIdentity.isSame($0.url, folder) })
        let model = TreeBrowserModel(fileSystem: fileSystem)
        model.toggle(folderItem, showsHiddenFiles: false, bookmark: nil)
        await model.waitForLoad(folder)

        let added = folder.appendingPathComponent("visible.txt")
        try Data("visible".utf8).write(to: added)
        model.reloadExpandedDirectories(changedURL: root, rootURL: root,
                                        showsHiddenFiles: false, bookmark: nil)
        await model.waitForRefresh()
        #expect(model.rows(rootItems: roots).contains { FileURLIdentity.isSame($0.item.url, added) })

        try FileManager.default.removeItem(at: added)
        model.reloadExpandedDirectories(changedURL: folder, rootURL: root,
                                        showsHiddenFiles: false, bookmark: nil)
        await model.waitForRefresh()
        #expect(!model.rows(rootItems: roots).contains { FileURLIdentity.isSame($0.item.url, added) })
    }

    @Test @MainActor func continuousTreeEventsStillPublishFinalExpandedSnapshot() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileSystem = FileSystemService(listingCache: DirectoryListingCache())
        let roots = try await fileSystem.listDirectory(root, showsHiddenFiles: false, bypassCache: true)
        let folderItem = try #require(roots.first { FileURLIdentity.isSame($0.url, folder) })
        let model = TreeBrowserModel(fileSystem: fileSystem)
        model.toggle(folderItem, showsHiddenFiles: false, bookmark: nil)
        await model.waitForLoad(folderItem.url)
        let final = folder.appendingPathComponent("final.txt")
        try Data("final".utf8).write(to: final)

        for _ in 0..<60 {
            model.reloadExpandedDirectories(changedURL: root, rootURL: root,
                                            showsHiddenFiles: false, bookmark: nil)
            try await Task.sleep(for: .milliseconds(5))
        }
        await model.waitForRefresh()
        #expect(model.rows(rootItems: roots).contains { FileURLIdentity.isSame($0.item.url, final) })
    }

    @Test func treeViewStyleRoundTripsAndOldStateStillDecodes() throws {
        var tab = TabState(currentURL: URL(fileURLWithPath: "/tmp")); tab.viewStyle = .tree
        let decoded = try JSONDecoder().decode(TabState.self, from: JSONEncoder().encode(tab))
        #expect(decoded.viewStyle == .tree)
    }
}

@Suite("File sorting")
struct FileSortingTests {
    @Test func tabSortDefaultsWhenDecodingOldStateAndPersists() throws {
        struct LegacyTab: Codable {
            let id: UUID; let currentURL: URL; let backwardHistory: [URL]; let forwardHistory: [URL]
            let selectedURLs: Set<URL>; let viewStyle: FileViewStyle; let showsHiddenFiles: Bool
        }
        let legacy = LegacyTab(id: UUID(), currentURL: URL(fileURLWithPath: "/tmp"), backwardHistory: [],
                               forwardHistory: [], selectedURLs: [], viewStyle: .tree, showsHiddenFiles: false)
        var tab = try JSONDecoder().decode(TabState.self, from: JSONEncoder().encode(legacy))
        #expect(tab.sortDescriptor == FileSortDescriptor())
        tab.sortDescriptor.select(.size)
        let restored = try JSONDecoder().decode(TabState.self, from: JSONEncoder().encode(tab))
        #expect(restored.sortDescriptor.field == .size)
        #expect(restored.sortDescriptor.ascending)
    }

    @Test func sortingOrdersNameSizeAndDirection() {
        let a = FileItem(url: URL(fileURLWithPath: "/tmp/b"), isDirectory: false, size: 2,
                         modificationDate: nil, isUbiquitous: false, cloudDownloadStatus: nil, isSymbolicLink: false)
        let b = FileItem(url: URL(fileURLWithPath: "/tmp/a"), isDirectory: false, size: 9,
                         modificationDate: nil, isUbiquitous: false, cloudDownloadStatus: nil, isSymbolicLink: false)
        #expect(FileSortDescriptor().sorted([a, b]).map(\.name) == ["a", "b"])
        var descriptor = FileSortDescriptor(field: .size, ascending: true)
        #expect(descriptor.sorted([a, b]).map(\.size) == [2, 9])
        descriptor.select(.size)
        #expect(descriptor.sorted([a, b]).map(\.size) == [9, 2])
    }

    @Test func repeatedColumnSelectionCyclesAllFourModesAndNewColumnResets() {
        var descriptor = FileSortDescriptor()
        #expect((descriptor.ascending, descriptor.foldersFirst) == (true, false))
        descriptor.select(.name)
        #expect((descriptor.ascending, descriptor.foldersFirst) == (false, false))
        descriptor.select(.name)
        #expect((descriptor.ascending, descriptor.foldersFirst) == (true, true))
        descriptor.select(.name)
        #expect((descriptor.ascending, descriptor.foldersFirst) == (false, true))
        descriptor.select(.name)
        #expect((descriptor.ascending, descriptor.foldersFirst) == (true, false))

        descriptor.select(.modificationDate)
        #expect(descriptor.field == .modificationDate)
        #expect((descriptor.ascending, descriptor.foldersFirst) == (true, false))
    }

    @Test func legacyDescriptorWithoutFolderGroupingDecodesAsMixed() throws {
        let oldJSON = Data(#"{"field":"size","ascending":false}"#.utf8)
        let descriptor = try JSONDecoder().decode(FileSortDescriptor.self, from: oldJSON)
        #expect(descriptor.field == .size)
        #expect(!descriptor.ascending)
        #expect(!descriptor.foldersFirst)

        let restored = try JSONDecoder().decode(
            FileSortDescriptor.self,
            from: JSONEncoder().encode(FileSortDescriptor(field: .cloud, ascending: false, foldersFirst: true))
        )
        #expect(restored == FileSortDescriptor(field: .cloud, ascending: false, foldersFirst: true))
    }

    @Test func foldersFirstKeepsRealFoldersAboveFilesAndPackagesForEveryFieldAndDirection() {
        let base = URL(fileURLWithPath: "/tmp/four-sort-modes")
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        let folderA = FileItem(url: base.appendingPathComponent("a-folder"), isDirectory: true, size: 1,
                               modificationDate: early, isUbiquitous: true, cloudDownloadStatus: "a")
        let folderZ = FileItem(url: base.appendingPathComponent("z-folder"), isDirectory: true, size: 8,
                               modificationDate: late, isUbiquitous: true, cloudDownloadStatus: "z")
        let fileB = FileItem(url: base.appendingPathComponent("b-file"), isDirectory: false, size: 2,
                             modificationDate: early, isUbiquitous: true, cloudDownloadStatus: "b")
        let packageY = FileItem(url: base.appendingPathComponent("y-package.app"), isDirectory: true, size: 7,
                                modificationDate: late, isUbiquitous: true, cloudDownloadStatus: "y",
                                isPackage: true)
        let items = [packageY, folderZ, fileB, folderA]

        for field in FileSortField.allCases {
            for ascending in [true, false] {
                let result = FileSortDescriptor(field: field, ascending: ascending, foldersFirst: true).sorted(items)
                #expect(result.prefix(2).allSatisfy { $0.isDirectory && !$0.isPackage })
                #expect(result.suffix(2).allSatisfy { !$0.isDirectory || $0.isPackage })
                switch field {
                case .name:
                    #expect(result.map(\.name) == (ascending
                        ? ["a-folder", "z-folder", "b-file", "y-package.app"]
                        : ["z-folder", "a-folder", "y-package.app", "b-file"]))
                case .size:
                    #expect(result.map(\.size) == (ascending ? [1, 8, 2, 7] : [8, 1, 7, 2]))
                case .modificationDate:
                    #expect(result.map(\.modificationDate) == (ascending ? [early, late, early, late] : [late, early, late, early]))
                case .cloud:
                    #expect(result.map(\.cloudDownloadStatus) == (ascending ? ["a", "z", "b", "y"] : ["z", "a", "y", "b"]))
                }
            }
        }
    }
}
