import AppKit
import SwiftUI
import Testing
@testable import QuadFinder

@Suite("Native tree selection and drag integration")
struct NativeTreeOutlineIntegrationTests {
    @Test @MainActor func selectionAndDragWriterShareOutlineOwner() throws {
        let urls = (0..<2).map { URL(fileURLWithPath: "/tmp/native-tree-\($0)") }
        let rows = urls.enumerated().map {
            TreeRow(item: FileItem(url: $0.element, isDirectory: false, size: 1,
                                   modificationDate: nil, isUbiquitous: false,
                                   cloudDownloadStatus: nil), depth: $0.offset)
        }
        var selected = Set<URL>()
        let view = NativeTreeOutlineView(
            paneID: UUID(), rows: rows,
            selection: Binding(get: { selected }, set: { selected = $0 }),
            activate: {}, open: { _ in }, toggle: { _ in }, receiveDrop: { _, _ in }, trashDropped: { _ in }
        )
        let coordinator = view.makeCoordinator()
        let scroll = NativeTreeOutlineView.makeScrollView(coordinator: coordinator)
        let outline = try #require(scroll.documentView as? NativeFileNSOutlineView)
        #expect(outline.usesAlternatingRowBackgroundColors)
        outline.reloadData()
        outline.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        coordinator.outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification, object: outline))
        #expect(selected == Set(urls))
        let item = coordinator.outlineView(outline, child: 0, ofItem: nil)
        let writer = try #require(coordinator.outlineView(outline, pasteboardWriterForItem: item) as? NSPasteboardItem)
        #expect(NativeFileDragPasteboard.payloads(from: [writer]).first?.url == urls[0])
    }
}
