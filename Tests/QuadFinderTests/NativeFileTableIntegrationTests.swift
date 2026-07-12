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
            activate: {}, open: { _ in }, receiveDrop: { _, _ in }, trashDropped: { _ in },
            showsHeader: true
        )
        let coordinator = browser.makeCoordinator()
        let scroll = NativeFileTableView.makeScrollView(coordinator: coordinator)
        let table = try #require(scroll.documentView as? NativeFileNSTableView)
        #expect(table.usesAlternatingRowBackgroundColors)
        #expect(table.tableColumns.map(\.identifier.rawValue) == NativeFileColumn.allCases.map(\.rawValue))
        let sizeColumn = try #require(table.tableColumn(withIdentifier: NativeFileColumn.size.identifier))
        let modifiedColumn = try #require(table.tableColumn(withIdentifier: NativeFileColumn.modificationDate.identifier))
        let sizeCell = coordinator.tableView(table, viewFor: sizeColumn, row: 0) as? NSTableCellView
        let modifiedCell = coordinator.tableView(table, viewFor: modifiedColumn, row: 0) as? NSTableCellView
        #expect(sizeCell?.textField?.stringValue != "")
        #expect(modifiedCell?.textField?.stringValue == "—")

        coordinator.commitSelection(IndexSet([0, 2]))
        #expect(selected == Set([urls[0], urls[2]]))

        let first = try #require(coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem)
        let third = try #require(coordinator.tableView(table, pasteboardWriterForRow: 2) as? NSPasteboardItem)
        #expect(NativeFileDragPasteboard.payloads(from: [first, third]).map(\.url) == [urls[0], urls[2]])

        coordinator.commitSelection(IndexSet(integer: 1))
        #expect(selected == [urls[1]])
    }

    @Test @MainActor func nativeHeaderSortAndResizableWidthPersistence() throws {
        let suite = "NativeColumnWidthTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = NativeColumnWidthStore(defaults: defaults)
        let paneID = UUID()
        store.save(160, paneID: paneID, mode: "list", column: .name)
        #expect(store.width(paneID: paneID, mode: "list", column: .name) == 160)
        store.save(1, paneID: paneID, mode: "list", column: .size)
        #expect(store.width(paneID: paneID, mode: "list", column: .size) == NativeFileColumn.size.minimumWidth)

        var selectedField: FileSortField?
        let browser = NativeFileTableView(paneID: paneID, items: [], selection: .constant([]), activate: {}, open: { _ in }, receiveDrop: { _, _ in }, trashDropped: { _ in }, showsHeader: true, selectSort: { selectedField = $0 })
        let coordinator = browser.makeCoordinator(); let scroll = NativeFileTableView.makeScrollView(coordinator: coordinator)
        let table = try #require(scroll.documentView as? NativeFileNSTableView)
        #expect(table.headerView != nil)
        #expect(table.tableColumns.allSatisfy { $0.resizingMask.contains(.userResizingMask) })
        table.sortDescriptors = [NSSortDescriptor(key: NativeFileColumn.size.rawValue, ascending: true)]
        coordinator.tableView(table, sortDescriptorsDidChange: [])
        #expect(selectedField == .size)
    }
}
