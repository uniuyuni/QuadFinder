import AppKit
import SwiftUI

/// Tree presentation whose click selection and drag session are both owned by
/// one NSOutlineView. The rows are already flattened by TreeBrowserModel so an
/// asynchronous expansion can reload without manufacturing unstable node IDs.
struct NativeTreeOutlineView: NSViewRepresentable {
    let paneID: UUID
    let rows: [TreeRow]
    @Binding var selection: Set<URL>
    let activate: () -> Void
    let open: (FileItem) -> Void
    let toggle: (FileItem) -> Void
    let receiveDrop: ([URL], UUID?) -> Void
    let trashDropped: ([URL]) -> Void
    var sortDescriptor: FileSortDescriptor? = nil
    var selectSort: ((FileSortField) -> Void)? = nil
    var contextMenu: NativeFinderContextMenuConfiguration? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(coordinator: context.coordinator)
    }

    @MainActor static func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let outline = NativeFileNSOutlineView()
        outline.owner = coordinator
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.usesAlternatingRowBackgroundColors = true
        outline.rowHeight = 18
        outline.intercellSpacing = .zero
        outline.headerView = NSTableHeaderView()
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.openSelected)
        outline.registerForDraggedTypes([.fileURL, NativeFileDragPasteboard.paneItemType])
        outline.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy, .move, .delete, .link], forLocal: false)
        configureNativeFileColumns(on: outline, paneID: coordinator.parent.paneID, mode: "tree")
        outline.outlineTableColumn = outline.tableColumn(withIdentifier: NativeFileColumn.name.identifier)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let outline = scroll.documentView as? NativeFileNSOutlineView else { return }
        context.coordinator.reload(outline)
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: NativeTreeOutlineView
        weak var outline: NativeFileNSOutlineView?
        private var applyingSelection = false
        private var contextClickedURL: URL?
        init(_ parent: NativeTreeOutlineView) { self.parent = parent }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            item == nil ? parent.rows.count : 0
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            parent.rows[index] as AnyObject
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let row = item as? TreeRow else { return nil }
            guard let kind = tableColumn.flatMap({ NativeFileColumn(rawValue: $0.identifier.rawValue) }) else { return nil }
            let id = NSUserInterfaceItemIdentifier("TreeCell.\(kind.rawValue)")
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id, kind: kind)
            if kind == .name { cell.imageView?.image = NSWorkspace.shared.icon(forFile: row.item.url.path) }
            cell.textField?.stringValue = text(for: row.item, column: kind)
            cell.textField?.toolTip = row.item.url.path
            cell.constraints.first(where: { $0.identifier == "TreeIndent" })?.constant = CGFloat(row.depth * 14 + 20)
            if kind == .name, let button = cell.viewWithTag(91) as? NSButton {
                button.isHidden = !row.item.isDirectory || row.item.isSymbolicLink
                button.identifier = .init(row.item.url.absoluteString)
                button.frame.origin.x = CGFloat(row.depth * 14 + 2)
            }
            return cell
        }

        private func text(for item: FileItem, column: NativeFileColumn) -> String {
            switch column { case .name: item.name; case .size: NativeFileMetadataText.size(item); case .modificationDate: NativeFileMetadataText.modified(item); case .cloud: NativeFileMetadataText.cloud(item) }
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier, kind: NativeFileColumn) -> NSTableCellView {
            let cell = NSTableCellView(); cell.identifier = id
            let text = NSTextField(labelWithString: ""); text.translatesAutoresizingMaskIntoConstraints = false; text.font = .systemFont(ofSize: 11.5)
            cell.textField = text; cell.addSubview(text)
            if kind == .name {
                let button = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!, target: self, action: #selector(toggleRow(_:)))
                button.isBordered = false; button.tag = 91; button.frame = NSRect(x: 2, y: 2, width: 14, height: 14); cell.addSubview(button)
                let image = NSImageView(); image.translatesAutoresizingMaskIntoConstraints = false; cell.imageView = image; cell.addSubview(image)
                let indent = image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 20); indent.identifier = "TreeIndent"
                NSLayoutConstraint.activate([indent, image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 14), image.heightAnchor.constraint(equalToConstant: 14), text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5)])
            } else { text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true }
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4).isActive = true
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
            text.alignment = kind == .size ? .right : .left
            return cell
        }

        private func metadataLabel(tag: Int, alignment: NSTextAlignment = .left) -> NSTextField {
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false; label.tag = tag
            label.font = .systemFont(ofSize: 11.5); label.textColor = .secondaryLabelColor
            label.alignment = alignment; label.lineBreakMode = .byTruncatingTail
            return label
        }

        @objc private func toggleRow(_ sender: NSButton) {
            guard let raw = sender.identifier?.rawValue, let url = URL(string: raw),
                  let row = parent.rows.first(where: { $0.item.url == url }) else { return }
            parent.toggle(row.item)
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let outline else { return }
            parent.activate()
            parent.selection = Set(outline.selectedRowIndexes.compactMap { parent.rows.indices.contains($0) ? parent.rows[$0].item.url : nil })
        }
        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let key = outlineView.sortDescriptors.first?.key, let column = NativeFileColumn(rawValue: key) else { return }
            parent.selectSort?(column.sortField)
        }
        func outlineViewColumnDidResize(_ notification: Notification) {
            guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  let kind = NativeFileColumn(rawValue: column.identifier.rawValue) else { return }
            NativeColumnWidthStore().save(column.width, paneID: parent.paneID, mode: "tree", column: kind)
        }
        func applySelection() {
            guard let outline else { return }
            let indexes = IndexSet(parent.rows.indices.filter { parent.selection.contains(parent.rows[$0].item.url) })
            applyingSelection = true; outline.selectRowIndexes(indexes, byExtendingSelection: false); applyingSelection = false
        }
        func reload(_ outline: NSOutlineView) {
            for column in outline.tableColumns { outline.setIndicatorImage(nil, in: column) }
            if let sort = parent.sortDescriptor,
               let kind = NativeFileColumn.allCases.first(where: { $0.sortField == sort.field }),
               let column = outline.tableColumn(withIdentifier: kind.identifier) {
                outline.setIndicatorImage(NSImage(named: sort.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"), in: column)
            }
            applyingSelection = true
            outline.reloadData()
            let indexes = IndexSet(parent.rows.indices.filter { parent.selection.contains(parent.rows[$0].item.url) })
            outline.selectRowIndexes(indexes, byExtendingSelection: false)
            applyingSelection = false
        }
        func dragEnded(_ session: NSDraggingSession, operation: NSDragOperation) {
            guard operation.contains(.delete) else { return }
            let urls = (session.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
            if !urls.isEmpty { parent.trashDropped(urls) }
        }
        @objc func openSelected() {
            guard let outline, outline.clickedRow >= 0, parent.rows.indices.contains(outline.clickedRow) else { return }
            parent.open(parent.rows[outline.clickedRow].item)
        }
        func menu(for row: Int) -> NSMenu? {
            guard let outline, parent.rows.indices.contains(row), let configuration = parent.contextMenu else { return nil }
            if !outline.selectedRowIndexes.contains(row) { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            let clicked = parent.rows[row].item.url
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
        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let row = item as? TreeRow else { return nil }
            return NativeFileDragPasteboard.item(for: .init(sourcePaneID: parent.paneID, url: row.item.url))
        }
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            let urls = NativeFileDragPasteboard.urls(from: info.draggingPasteboard)
            return FinderDragOperationPolicy.operation(sourceURLs: urls,
                targetDirectory: parent.rows.first?.item.url.deletingLastPathComponent() ?? URL(fileURLWithPath: "/"),
                modifiers: NSEvent.modifierFlags)
        }
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            let pasteboard = info.draggingPasteboard
            let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
            let payloads = NativeFileDragPasteboard.payloads(from: pasteboard.pasteboardItems ?? [])
            let all = Array(Set(urls + payloads.map(\.url)))
            guard !all.isEmpty else { return false }
            parent.receiveDrop(all, payloads.first?.sourcePaneID)
            return true
        }
    }
}

@MainActor final class NativeFileNSOutlineView: NSOutlineView {
    weak var owner: NativeTreeOutlineView.Coordinator?
    override func mouseDown(with event: NSEvent) { owner?.parent.activate(); super.mouseDown(with: event) }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? owner?.menu(for: row) : nil
    }
    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        NativeFileDragOperationPolicy.mask(isInsideApplication: context == .withinApplication, modifiers: NSEvent.modifierFlags)
    }
    override func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }
    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        owner?.dragEnded(session, operation: operation)
    }
}
