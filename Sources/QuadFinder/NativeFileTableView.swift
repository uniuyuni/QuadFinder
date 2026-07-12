import AppKit
import SwiftUI

/// A Finder-style browser whose selection and drag session are both owned by
/// NSTableView.  Do not add SwiftUI gestures or event monitors around this view.
struct NativeFileTableView: NSViewRepresentable {
    let paneID: UUID
    let items: [FileItem]
    @Binding var selection: Set<URL>
    let activate: () -> Void
    let open: (FileItem) -> Void
    let receiveDrop: ([URL], UUID?) -> Void
    let trashDropped: ([URL]) -> Void
    var contextMenu: NativeFinderContextMenuConfiguration? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(coordinator: context.coordinator)
    }

    @MainActor static func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let table = NativeFileNSTableView()
        table.owner = coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 18
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.headerView = nil
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.openSelected)
        table.registerForDraggedTypes([.fileURL, NativeFileDragPasteboard.paneItemType])
        table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: true)
        table.setDraggingSourceOperationMask([.copy, .move, .delete, .link], forLocal: false)

        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = scroll.documentView as? NativeFileNSTableView else { return }
        context.coordinator.reload(table)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeFileTableView
        weak var table: NativeFileNSTableView?
        private var applyingSelection = false
        private var contextClickedURL: URL?

        init(_ parent: NativeFileTableView) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.items.indices.contains(row) else { return nil }
            let item = parent.items[row]
            let id = NSUserInterfaceItemIdentifier("NativeFileCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id)
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.textField?.stringValue = item.name
            cell.toolTip = item.url.path
            return cell
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView(frame: .zero)
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingMiddle
            text.font = .systemFont(ofSize: 11.5)
            cell.imageView = image
            cell.textField = text
            cell.addSubview(image)
            cell.addSubview(text)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 14), image.heightAnchor.constraint(equalToConstant: 14),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table else { return }
            commitSelection(table.selectedRowIndexes)
        }

        func commitSelection(_ indexes: IndexSet) {
            guard !applyingSelection else { return }
            parent.activate()
            parent.selection = Set(indexes.compactMap {
                parent.items.indices.contains($0) ? parent.items[$0].url : nil
            })
        }

        func applySelection(to table: NSTableView) {
            let indexes = IndexSet(parent.items.indices.filter { parent.selection.contains(parent.items[$0].url) })
            guard indexes != table.selectedRowIndexes else { return }
            applyingSelection = true
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            applyingSelection = false
        }

        func reload(_ table: NSTableView) {
            applyingSelection = true
            table.reloadData()
            let indexes = IndexSet(parent.items.indices.filter { parent.selection.contains(parent.items[$0].url) })
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            applyingSelection = false
        }

        func dragEnded(_ session: NSDraggingSession, operation: NSDragOperation) {
            guard operation.contains(.delete) else { return }
            let urls = (session.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
            if !urls.isEmpty { parent.trashDropped(urls) }
        }

        @objc func openSelected() {
            guard let table, table.clickedRow >= 0, parent.items.indices.contains(table.clickedRow) else { return }
            parent.open(parent.items[table.clickedRow])
        }

        func menu(for row: Int) -> NSMenu? {
            guard let table, parent.items.indices.contains(row), let configuration = parent.contextMenu else { return nil }
            if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            let clicked = parent.items[row].url
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

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.items.indices.contains(row) else { return nil }
            return NativeFileDragPasteboard.item(for: .init(sourcePaneID: parent.paneID, url: parent.items[row].url))
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            tableView.setDropRow(-1, dropOperation: .on)
            let urls = NativeFileDragPasteboard.urls(from: info.draggingPasteboard)
            return FinderDragOperationPolicy.operation(sourceURLs: urls,
                targetDirectory: parent.items.first?.url.deletingLastPathComponent() ?? URL(fileURLWithPath: "/"),
                modifiers: NSEvent.modifierFlags)
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
            let payloads = NativeFileDragPasteboard.payloads(from: info.draggingPasteboard.pasteboardItems ?? [])
            let all = Array(Set(urls + payloads.map(\.url)))
            guard !all.isEmpty else { return false }
            let source = payloads.first.map(\.sourcePaneID)
            parent.receiveDrop(all, source)
            return true
        }
    }
}

@MainActor final class NativeFileNSTableView: NSTableView {
    weak var owner: NativeFileTableView.Coordinator?

    override func mouseDown(with event: NSEvent) {
        owner?.parent.activate()
        super.mouseDown(with: event) // AppKit owns click, modifiers and drag threshold.
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? owner?.menu(for: row) : nil
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
