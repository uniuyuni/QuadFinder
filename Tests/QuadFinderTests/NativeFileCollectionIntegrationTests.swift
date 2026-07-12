import AppKit
import SwiftUI
import Testing
@testable import QuadFinder

@Suite("Native icon selection and drag integration")
struct NativeFileCollectionIntegrationTests {
    @Test @MainActor func selectionAndDragWriterRemainOwnedBySameCollection() throws {
        let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/native-icon-\($0)") }
        let items = urls.map { FileItem(url: $0, isDirectory: false, size: 1,
                                       modificationDate: nil, isUbiquitous: false,
                                       cloudDownloadStatus: nil) }
        var selected = Set<URL>()
        let browser = NativeFileCollectionView(
            paneID: UUID(), items: items,
            selection: Binding(get: { selected }, set: { selected = $0 }),
            activate: {}, open: { _ in }, receiveDrop: { _, _ in }, trashDropped: { _ in },
            isClipboardMarked: { _ in false }
        )
        let coordinator = browser.makeCoordinator()
        let collection = NativeFileNSCollectionView()
        collection.dataSource = coordinator
        collection.delegate = coordinator
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        coordinator.collection = collection

        let paths = Set([IndexPath(item: 0, section: 0), IndexPath(item: 2, section: 0)])
        coordinator.commitSelection(paths)
        #expect(selected == Set([urls[0], urls[2]]))

        let first = try #require(coordinator.collectionView(collection, pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)) as? NSPasteboardItem)
        let third = try #require(coordinator.collectionView(collection, pasteboardWriterForItemAt: IndexPath(item: 2, section: 0)) as? NSPasteboardItem)
        #expect(NativeFileDragPasteboard.payloads(from: [first, third]).map(\.url) == [urls[0], urls[2]])

        coordinator.commitSelection([IndexPath(item: 1, section: 0)])
        #expect(selected == [urls[1]])
    }
}
