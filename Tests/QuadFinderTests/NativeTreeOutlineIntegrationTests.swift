import AppKit
import SwiftUI
import Testing
@testable import QuadFinder

@Suite("Native tree selection and drag integration")
struct NativeTreeOutlineIntegrationTests {
    @MainActor private func treeView(rows: [TreeRow], expanded: Set<URL>, selection: Binding<Set<URL>>) -> NativeTreeOutlineView {
        NativeTreeOutlineView(
            paneID: UUID(), currentDirectory: URL(fileURLWithPath: "/tmp"), rows: rows, expandedURLs: expanded, selection: selection,
            activate: {}, open: { _ in }, toggle: { _ in }, receiveDrop: { _, _, _, _ in }, trashDropped: { _ in }
        )
    }

    @Test @MainActor func groupedSortStateIsVisibleInTreeHeader() throws {
        let view = NativeTreeOutlineView(
            paneID: UUID(), currentDirectory: URL(fileURLWithPath: "/tmp"), rows: [],
            selection: .constant([]), activate: {}, open: { _ in }, toggle: { _ in },
            receiveDrop: { _, _, _, _ in }, trashDropped: { _ in },
            sortDescriptor: FileSortDescriptor(field: .modificationDate, ascending: true, foldersFirst: true)
        )
        let coordinator = view.makeCoordinator()
        let scroll = NativeTreeOutlineView.makeScrollView(coordinator: coordinator)
        let outline = try #require(scroll.documentView as? NativeFileNSOutlineView)
        coordinator.reload(outline)
        let column = try #require(outline.tableColumn(withIdentifier: NativeFileColumn.modificationDate.identifier))
        #expect(column.title == NativeFileColumn.modificationDate.title)
        #expect(column.headerToolTip == L10n.format("フォルダ優先・%@", L10n.tr("昇順")))
        #expect(outline.indicatorImage(in: column)?.accessibilityDescription == column.headerToolTip)
    }

    @Test @MainActor func selectionAndDragWriterShareOutlineOwner() throws {
        let urls = (0..<2).map { URL(fileURLWithPath: "/tmp/native-tree-\($0)") }
        let rows = urls.enumerated().map {
            TreeRow(item: FileItem(url: $0.element, isDirectory: false, size: 1,
                                   modificationDate: nil, isUbiquitous: false,
                                   cloudDownloadStatus: nil), depth: $0.offset)
        }
        var selected = Set<URL>()
        let view = NativeTreeOutlineView(
            paneID: UUID(), currentDirectory: URL(fileURLWithPath: "/tmp"), rows: rows,
            selection: Binding(get: { selected }, set: { selected = $0 }),
            activate: {}, open: { _ in }, toggle: { _ in }, receiveDrop: { _, _, _, _ in }, trashDropped: { _ in }
        )
        let coordinator = view.makeCoordinator()
        let scroll = NativeTreeOutlineView.makeScrollView(coordinator: coordinator)
        let outline = try #require(scroll.documentView as? NativeFileNSOutlineView)
        #expect(outline.usesAlternatingRowBackgroundColors)
        #expect(outline.headerView != nil)
        #expect(outline.tableColumns.map(\.identifier.rawValue) == NativeFileColumn.allCases.map(\.rawValue))
        #expect(outline.outlineTableColumn?.identifier == NativeFileColumn.name.identifier)
        outline.reloadData()
        let firstRow = try #require(coordinator.outlineView(outline, child: 0, ofItem: nil) as? TreeRow)
        let sizeCell = try #require(coordinator.outlineView(outline, viewFor: outline.tableColumn(withIdentifier: NativeFileColumn.size.identifier), item: firstRow) as? NSTableCellView)
        let modifiedCell = try #require(coordinator.outlineView(outline, viewFor: outline.tableColumn(withIdentifier: NativeFileColumn.modificationDate.identifier), item: firstRow) as? NSTableCellView)
        #expect(sizeCell.textField?.stringValue != "")
        #expect(modifiedCell.textField?.stringValue == "—")
        outline.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        coordinator.outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification, object: outline))
        #expect(selected == Set(urls))
        let item = coordinator.outlineView(outline, child: 0, ofItem: nil)
        let writer = try #require(coordinator.outlineView(outline, pasteboardWriterForItem: item) as? NSPasteboardItem)
        #expect(NativeFileDragPasteboard.payloads(from: [writer]).first?.url == urls[0])
    }

    @Test @MainActor func disclosureReflectsExpandedStateAfterReloadAndCollapse() throws {
        let folderURL = URL(fileURLWithPath: "/tmp/native-tree-folder", isDirectory: true)
        let folder = FileItem(url: folderURL, isDirectory: true, size: nil,
                              modificationDate: nil, isUbiquitous: false,
                              cloudDownloadStatus: nil)
        let rows = [TreeRow(item: folder, depth: 0)]
        var selected = Set<URL>()
        let binding = Binding(get: { selected }, set: { selected = $0 })
        var view = treeView(rows: rows, expanded: [], selection: binding)
        let coordinator = view.makeCoordinator()
        let scroll = NativeTreeOutlineView.makeScrollView(coordinator: coordinator)
        let outline = try #require(scroll.documentView as? NativeFileNSOutlineView)
        outline.reloadData()

        func disclosure() throws -> NSButton {
            let row = coordinator.outlineView(outline, child: 0, ofItem: nil)
            let cell = try #require(coordinator.outlineView(
                outline,
                viewFor: outline.tableColumn(withIdentifier: NativeFileColumn.name.identifier),
                item: row
            ) as? NSTableCellView)
            return try #require(cell.viewWithTag(91) as? NSButton)
        }

        #expect(try disclosure().accessibilityValue() as? String == "閉じています")
        view = treeView(rows: rows, expanded: [folderURL], selection: binding)
        coordinator.parent = view
        coordinator.reload(outline)
        #expect(try disclosure().accessibilityValue() as? String == "展開中")

        coordinator.reload(outline)
        #expect(try disclosure().accessibilityValue() as? String == "展開中")

        view = treeView(rows: rows, expanded: [], selection: binding)
        coordinator.parent = view
        coordinator.reload(outline)
        #expect(try disclosure().accessibilityValue() as? String == "閉じています")
    }

    @Test @MainActor func doubleClickUsesClickedRowAndDisclosureNeverOpensSelection() throws {
        let selectedURL = URL(fileURLWithPath: "/tmp/previously-selected.txt")
        let folderURL = URL(fileURLWithPath: "/tmp/clicked-folder", isDirectory: true)
        let leafURL = URL(fileURLWithPath: "/tmp/clicked-leaf.txt")
        let rows = [
            TreeRow(item: FileItem(url: selectedURL, isDirectory: false, size: 1,
                                   modificationDate: nil, isUbiquitous: false,
                                   cloudDownloadStatus: nil), depth: 0),
            TreeRow(item: FileItem(url: folderURL, isDirectory: true, size: nil,
                                   modificationDate: nil, isUbiquitous: false,
                                   cloudDownloadStatus: nil), depth: 0),
            TreeRow(item: FileItem(url: leafURL, isDirectory: false, size: 1,
                                   modificationDate: nil, isUbiquitous: false,
                                   cloudDownloadStatus: nil), depth: 0)
        ]
        var selected: Set<URL> = [selectedURL]
        var opened: [URL] = []
        let view = NativeTreeOutlineView(
            paneID: UUID(), currentDirectory: URL(fileURLWithPath: "/tmp"), rows: rows, selection: Binding(get: { selected }, set: { selected = $0 }),
            activate: {}, open: { opened.append($0.url) }, toggle: { _ in },
            receiveDrop: { _, _, _, _ in }, trashDropped: { _ in }
        )
        let coordinator = view.makeCoordinator()
        let scroll = NativeTreeOutlineView.makeScrollView(coordinator: coordinator)
        let outline = try #require(scroll.documentView as? NativeFileNSOutlineView)
        coordinator.reload(outline)
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 180)
        scroll.layoutSubtreeIfNeeded(); outline.layoutSubtreeIfNeeded()
        let nameColumn = outline.column(withIdentifier: NativeFileColumn.name.identifier)
        let sizeColumn = outline.column(withIdentifier: NativeFileColumn.size.identifier)
        let folderCell = try #require(outline.view(atColumn: nameColumn, row: 1, makeIfNecessary: true) as? NSTableCellView)
        let sizeCell = try #require(outline.view(atColumn: sizeColumn, row: 1, makeIfNecessary: true))
        outline.layoutSubtreeIfNeeded(); folderCell.layoutSubtreeIfNeeded()

        let disclosure = try #require(folderCell.viewWithTag(91))
        coordinator.openDoubleClicked(at: folderCell.convert(NSPoint(x: disclosure.frame.midX, y: disclosure.frame.midY), to: outline))
        #expect(opened.isEmpty, "disclosure")
        coordinator.openDoubleClicked(at: folderCell.convert(NSPoint(x: disclosure.frame.maxX + 2, y: disclosure.frame.midY), to: outline))
        #expect(opened.isEmpty, "indentation")
        coordinator.openDoubleClicked(at: folderCell.convert(NSPoint(x: folderCell.bounds.maxX - 8, y: folderCell.bounds.midY), to: outline))
        #expect(opened.isEmpty, "trailing whitespace")
        coordinator.openDoubleClicked(at: sizeCell.convert(NSPoint(x: sizeCell.bounds.midX, y: sizeCell.bounds.midY), to: outline))
        #expect(opened.isEmpty, "metadata")
        coordinator.openDoubleClicked(at: NSPoint(x: 10, y: outline.bounds.maxY + 40))
        #expect(opened.isEmpty)
        #expect(outline.selectedRow == 0)

        let image = try #require(folderCell.imageView)
        coordinator.openDoubleClicked(at: folderCell.convert(NSPoint(x: image.frame.midX, y: image.frame.midY), to: outline))
        #expect(opened == [folderURL])
        #expect(!opened.contains(selectedURL))
    }

    @Test func tabMenuUsesOnlyNativeIndicatorAndKeepsAccessibleName() {
        #expect(TabMenuPresentation.customIndicatorSymbol == nil)
        #expect(TabMenuPresentation.accessibilityLabel == "タブ操作")
    }
}
