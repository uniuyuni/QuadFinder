import AppKit
import SwiftUI

/// Finder-style icon browser. AppKit exclusively owns selection, click/drag
/// disambiguation, pasteboard production and drop negotiation.
struct NativeFileCollectionView: NSViewRepresentable {
    let paneID: UUID
    let items: [FileItem]
    @Binding var selection: Set<URL>
    let activate: () -> Void
    let open: (FileItem) -> Void
    let receiveDrop: ([URL], UUID?) -> Void
    let trashDropped: ([URL]) -> Void
    let isClipboardMarked: (URL) -> Bool
    var contextMenu: NativeFinderContextMenuConfiguration? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 92, height: 84)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        let collection = NativeFileNSCollectionView()
        collection.owner = context.coordinator
        collection.collectionViewLayout = layout
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.register(NativeFileCollectionItem.self,
                            forItemWithIdentifier: NativeFileCollectionItem.identifier)
        collection.registerForDraggedTypes([.fileURL, NativeFileDragPasteboard.paneItemType])
        collection.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: true)
        collection.setDraggingSourceOperationMask([.copy, .move, .delete, .link], forLocal: false)

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.collection = collection
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let collection = nsView.documentView as? NSCollectionView else { return }
        context.coordinator.reload(collection)
    }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: NativeFileCollectionView
        weak var collection: NSCollectionView?
        private var applyingSelection = false
        private var contextClickedURL: URL?

        init(_ parent: NativeFileCollectionView) { self.parent = parent }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.items.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let viewItem = collectionView.makeItem(withIdentifier: NativeFileCollectionItem.identifier, for: indexPath)
            guard let cell = viewItem as? NativeFileCollectionItem,
                  parent.items.indices.contains(indexPath.item) else { return viewItem }
            let item = parent.items[indexPath.item]
            cell.configure(item: item, dimmed: parent.isClipboardMarked(item.url))
            return cell
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged(collectionView) }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged(collectionView) }

        private func selectionChanged(_ collectionView: NSCollectionView) {
            commitSelection(collectionView.selectionIndexPaths)
        }

        func commitSelection(_ indexPaths: Set<IndexPath>) {
            guard !applyingSelection else { return }
            parent.activate()
            parent.selection = Set(indexPaths.compactMap {
                parent.items.indices.contains($0.item) ? parent.items[$0.item].url : nil
            })
        }

        func applySelection(to collectionView: NSCollectionView) {
            let desired = Set(parent.items.indices.compactMap {
                parent.selection.contains(parent.items[$0].url) ? IndexPath(item: $0, section: 0) : nil
            })
            guard desired != collectionView.selectionIndexPaths else { return }
            applyingSelection = true
            collectionView.selectionIndexPaths = desired
            applyingSelection = false
        }

        func reload(_ collectionView: NSCollectionView) {
            applyingSelection = true
            collectionView.reloadData()
            collectionView.selectionIndexPaths = Set(parent.items.indices.compactMap {
                parent.selection.contains(parent.items[$0].url) ? IndexPath(item: $0, section: 0) : nil
            })
            applyingSelection = false
        }

        func dragEnded(_ session: NSDraggingSession, operation: NSDragOperation) {
            guard operation.contains(.delete) else { return }
            let urls = (session.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
            if !urls.isEmpty { parent.trashDropped(urls) }
        }

        func open(at point: NSPoint) {
            guard let collection, let path = collection.indexPathForItem(at: point),
                  parent.items.indices.contains(path.item) else { return }
            parent.open(parent.items[path.item])
        }

        func menu(at point: NSPoint) -> NSMenu? {
            guard let collection, let path = collection.indexPathForItem(at: point),
                  parent.items.indices.contains(path.item), let configuration = parent.contextMenu else { return nil }
            if !collection.selectionIndexPaths.contains(path) { collection.selectionIndexPaths = [path]; selectionChanged(collection) }
            let clicked = parent.items[path.item].url
            contextClickedURL = clicked
            return makeNativeFinderContextMenu(clickedURL: clicked, selection: parent.selection,
                                               configuration: configuration, target: self,
                                               action: #selector(performMenuAction(_:)))
        }

        @objc private func performMenuAction(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let action = FinderContextAction(rawValue: raw),
                  let clicked = contextClickedURL,
                  let configuration = parent.contextMenu else { return }
            configuration.perform(action, clicked, parent.selection)
        }

        func collectionView(_ collectionView: NSCollectionView,
                            pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard parent.items.indices.contains(indexPath.item) else { return nil }
            return NativeFileDragPasteboard.item(for: .init(sourcePaneID: parent.paneID,
                                                             url: parent.items[indexPath.item].url))
        }

        func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                            proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            dropOperation.pointee = .on
            let urls = NativeFileDragPasteboard.urls(from: draggingInfo.draggingPasteboard)
            return FinderDragOperationPolicy.operation(sourceURLs: urls,
                targetDirectory: parent.items.first?.url.deletingLastPathComponent() ?? URL(fileURLWithPath: "/"),
                modifiers: NSEvent.modifierFlags)
        }

        func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                            indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
            let pasteboard = draggingInfo.draggingPasteboard
            let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
            let payloads = NativeFileDragPasteboard.payloads(from: pasteboard.pasteboardItems ?? [])
            let all = Array(Set(urls + payloads.map(\.url)))
            guard !all.isEmpty else { return false }
            parent.receiveDrop(all, payloads.first?.sourcePaneID)
            return true
        }
    }
}

@MainActor final class NativeFileNSCollectionView: NSCollectionView {
    weak var owner: NativeFileCollectionView.Coordinator?

    override func mouseDown(with event: NSEvent) {
        owner?.parent.activate()
        let point = convert(event.locationInWindow, from: nil)
        if indexPathForItem(at: point) == nil, !event.modifierFlags.contains([.command, .shift]) {
            deselectAll(nil)
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            owner?.open(at: convert(event.locationInWindow, from: nil))
        }
        super.mouseUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.menu(at: convert(event.locationInWindow, from: nil))
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        NativeFileDragOperationPolicy.mask(isInsideApplication: context == .withinApplication,
                                           modifiers: NSEvent.modifierFlags)
    }

    override func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }
    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        owner?.dragEnded(session, operation: operation)
    }
}

@MainActor final class NativeFileCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("NativeFileCollectionItem")
    private let background = NSBox()

    override func loadView() {
        view = NSView()
        background.boxType = .custom
        background.cornerRadius = 6
        background.borderWidth = 0
        background.translatesAutoresizingMaskIntoConstraints = false
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: "")
        text.alignment = .center
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 2
        text.font = .systemFont(ofSize: 11)
        text.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(background); view.addSubview(image); view.addSubview(text)
        imageView = image; textField = text
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor), background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            background.topAnchor.constraint(equalTo: view.topAnchor), background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            image.topAnchor.constraint(equalTo: view.topAnchor, constant: 5), image.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            image.widthAnchor.constraint(equalToConstant: 44), image.heightAnchor.constraint(equalToConstant: 44),
            text.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 3), text.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            text.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3)
        ])
    }

    func configure(item: FileItem, dimmed: Bool) {
        imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
        textField?.stringValue = item.name
        view.alphaValue = dimmed ? 0.5 : 1
        view.toolTip = item.url.path
        updateSelection()
    }

    override var isSelected: Bool { didSet { updateSelection() } }
    private func updateSelection() {
        background.fillColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.25) : .clear
    }
}
