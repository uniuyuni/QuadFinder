import Foundation
import Testing
@testable import QuadFinder

@Suite("Pane interaction policies")
struct PaneInteractionTests {
    @Test func dividerKeepsLargeHitTargetWithoutOccupyingLayout() {
        #expect(DividerMetrics.visibleThickness == 2)
        #expect(DividerMetrics.pointerHitThickness >= 8)
        #expect(DividerMetrics.pointerHitThickness > DividerMetrics.visibleThickness)
    }

    @Test func contextClickKeepsWholeSelectionOnlyWhenClickedInsideIt() {
        let a = URL(fileURLWithPath: "/a")
        let b = URL(fileURLWithPath: "/b")
        let c = URL(fileURLWithPath: "/c")
        #expect(PaneSelectionPolicy.contextTargets(clicked: b, selection: [a, b]) == [a, b])
        #expect(PaneSelectionPolicy.contextTargets(clicked: c, selection: [a, b]) == [c])
    }

    @Test func shiftRangeWorksInBothDirections() {
        let urls = (0..<5).map { URL(fileURLWithPath: "/\($0)") }
        #expect(PaneSelectionPolicy.range(anchor: urls[1], clicked: urls[3], orderedItems: urls) == Set(urls[1...3]))
        #expect(PaneSelectionPolicy.range(anchor: urls[3], clicked: urls[1], orderedItems: urls) == Set(urls[1...3]))
    }

    @MainActor
    @Test func columnNavigationDropsStaleRightColumns() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = base.appendingPathComponent("first")
        let second = base.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let rootItems = [
            FileItem(url: first, isDirectory: true, size: nil, modificationDate: nil, isUbiquitous: false, cloudDownloadStatus: nil),
            FileItem(url: second, isDirectory: true, size: nil, modificationDate: nil, isUbiquitous: false, cloudDownloadStatus: nil)
        ]
        let model = ColumnBrowserModel()
        model.setRoot(url: base, items: rootItems)
        model.select(rootItems[0], in: 0, bookmark: nil)
        await model.waitForLoad()
        #expect(model.levels.count == 2)
        model.select(rootItems[1], in: 0, bookmark: nil)
        await model.waitForLoad()
        #expect(model.levels.count == 2)
        #expect(model.levels[1].directoryURL == second)
    }

    @MainActor
    @Test func columnRefreshUpdatesAlreadyVisibleChildDirectory() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let child = base.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let childItem = FileItem(url: child, isDirectory: true, size: nil,
                                 modificationDate: nil, isUbiquitous: false,
                                 cloudDownloadStatus: nil)
        let model = ColumnBrowserModel(fileSystem: FileSystemService(listingCache: DirectoryListingCache()))
        model.setRoot(url: base, items: [childItem])
        model.select(childItem, in: 0, bookmark: nil)
        await model.waitForLoad()
        #expect(model.levels[1].items.isEmpty)

        let added = child.appendingPathComponent("visible.txt")
        try Data("visible".utf8).write(to: added)
        // DirectoryMonitoringCenter reports the displayed root for descendant
        // FSEvents, so root notification must refresh every visible column.
        model.reloadVisibleDirectories(changedURL: base, rootURL: base,
                                       showsHiddenFiles: false, bookmark: nil)
        await model.waitForRefresh()
        #expect(model.levels[1].items.contains { FileURLIdentity.isSame($0.url, added) })

        try FileManager.default.removeItem(at: added)
        model.reloadVisibleDirectories(changedURL: child, rootURL: base,
                                       showsHiddenFiles: false, bookmark: nil)
        await model.waitForRefresh()
        #expect(!model.levels[1].items.contains { FileURLIdentity.isSame($0.url, added) })
    }

    @MainActor
    @Test func continuousColumnEventsStillPublishFinalChildSnapshot() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let child = base.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let childItem = FileItem(url: child, isDirectory: true, size: nil,
                                 modificationDate: nil, isUbiquitous: false,
                                 cloudDownloadStatus: nil)
        let model = ColumnBrowserModel(fileSystem: FileSystemService(listingCache: DirectoryListingCache()))
        model.setRoot(url: base, items: [childItem])
        model.select(childItem, in: 0, bookmark: nil)
        await model.waitForLoad()
        let final = child.appendingPathComponent("final.txt")
        try Data("final".utf8).write(to: final)

        for _ in 0..<60 {
            model.reloadVisibleDirectories(changedURL: base, rootURL: base,
                                           showsHiddenFiles: false, bookmark: nil)
            try await Task.sleep(for: .milliseconds(5))
        }
        await model.waitForRefresh()
        #expect(model.levels[1].items.contains { FileURLIdentity.isSame($0.url, final) })
    }
}
