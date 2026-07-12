import AppKit
import SwiftUI
import Testing
@testable import QuadFinder

@Suite("Native table selection and drag integration")
struct NativeFileTableIntegrationTests {
    @Test @MainActor func selectionAndDragWriterRemainOwnedBySameTable() throws {
        let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/native-table-\($0)") }
        let items = urls.map { FileItem(url: $0, isDirectory: false, size: 1, modificationDate: nil, isUbiquitous: false, cloudDownloadStatus: nil) }
        var selected = Set<URL>()
        let browser = NativeFileTableView(
            paneID: UUID(), items: items,
            selection: Binding(get: { selected }, set: { selected = $0 }),
            activate: {}, open: { _ in }, receiveDrop: { _, _ in }, trashDropped: { _ in }
        )
        let coordinator = browser.makeCoordinator()
        let scroll = NativeFileTableView.makeScrollView(coordinator: coordinator)
        let table = try #require(scroll.documentView as? NativeFileNSTableView)
        #expect(table.usesAlternatingRowBackgroundColors)

        coordinator.commitSelection(IndexSet([0, 2]))
        #expect(selected == Set([urls[0], urls[2]]))

        let first = try #require(coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem)
        let third = try #require(coordinator.tableView(table, pasteboardWriterForRow: 2) as? NSPasteboardItem)
        #expect(NativeFileDragPasteboard.payloads(from: [first, third]).map(\.url) == [urls[0], urls[2]])

        coordinator.commitSelection(IndexSet(integer: 1))
        #expect(selected == [urls[1]])
    }
}
